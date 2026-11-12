import Foundation
import AppKit
import Combine

/// Observable authentication & model catalog state for the "Claude Account" provider.
@MainActor
final class ClaudeAuthStore: ObservableObject {
    static let shared = ClaudeAuthStore()

    enum Status: Equatable {
        case checking
        case cliMissing
        case signedOut
        case signingIn(authURL: URL?)
        case signedIn(email: String?, plan: String?, orgName: String?)
        case failed(String)

        var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    static let builtInModels = [
        "sonnet",
        "haiku",
        "opus",
        "claude-sonnet-5-5",
        "claude-haiku-5-5",
        "claude-opus-5-5",
    ]

    @Published fileprivate(set) var status: Status = .checking
    @Published fileprivate(set) var availableModels: [String] = ClaudeAuthStore.builtInModels

    private init() {}

    func refresh() async {
        if ClaudeAccountClient.findBinary() == nil {
            status = .cliMissing
            return
        }
        do {
            let snapshot = try await ClaudeAccountClient.shared.accountSnapshot()
            if snapshot.isSignedIn {
                status = .signedIn(email: snapshot.email, plan: snapshot.plan, orgName: snapshot.orgName)
                let settings = AppSettings.shared
                if settings.providerID == Providers.claudeAccountID,
                   settings.model.trimmed.isEmpty || settings.model.lowercased().hasPrefix("gpt-") {
                    settings.model = Providers.preset(Providers.claudeAccountID).defaultModel
                }
            } else {
                status = .signedOut
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func signIn() async {
        guard ClaudeAccountClient.findBinary() != nil else {
            status = .cliMissing
            return
        }
        status = .signingIn(authURL: nil)
        do {
            try await ClaudeAccountClient.shared.runBrowserLogin { url in
                Task { @MainActor in
                    if case .signingIn = self.status {
                        self.status = .signingIn(authURL: url)
                    }
                }
            }
            await refresh()
        } catch is CancellationError {
            await refresh()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func cancelSignIn() async {
        await ClaudeAccountClient.shared.cancelBrowserLogin()
        await refresh()
    }

    func signOut() async {
        do {
            try await ClaudeAccountClient.shared.logout()
            status = .signedOut
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

struct ClaudeAccountSnapshot: Sendable {
    var isSignedIn: Bool
    var email: String?
    var plan: String?
    var orgName: String?
}

/// Thread-safe JSONL line splitter for Claude CLI pipes.
private final class ClaudePipeLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        buffer.append(data)
        while let idx = buffer.firstIndex(of: 0x0A) {
            let slice = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            if let line = String(data: slice, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                lines.append(line)
            }
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }
}

/// Official Claude subscription integration via Anthropic's documented `claude` CLI (`auth` + `-p --output-format stream-json`).
/// Never accesses Keychain or `~/.claude` credential files directly; all OAuth & inference stay inside the official `claude` binary.
actor ClaudeAccountClient {
    static let shared = ClaudeAccountClient()

    private var loginProcess: Process?
    private var loginCancelled = false
    private var isSignedInCached: Bool?
    private var standbySession: WarmClaudeSession?
    private var isSpawningStandby = false

    fileprivate nonisolated static let standbySystemPrompt =
        "You are ScreenLocalizer. Strictly follow all task and language instructions provided in the user message and output ONLY the requested response text. Do not invoke any tools or commands, and do not insert hidden Unicode directional formatting characters."

    private lazy var emptyWorkspaceURL: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("screenlocalizer-claude-workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated static func findBinary() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":").map(String.init) where !dir.isEmpty {
                candidates.append("\(dir)/claude")
            }
        }
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    nonisolated static func sanitizedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Ensure Claude subscription OAuth is used (not an inherited API key) and prevent nested-session errors.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    // MARK: Auth management

    func accountSnapshot() async throws -> ClaudeAccountSnapshot {
        guard let binary = Self.findBinary() else { throw LLMError.missingClaudeCLI }
        let output = try await runShortCommand(binary: binary, arguments: ["auth", "status", "--json"])
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start <= end,
              let data = String(output[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ClaudeAccountSnapshot(isSignedIn: false, email: nil, plan: nil, orgName: nil)
        }
        let loggedIn = (json["loggedIn"] as? Bool) ?? false
        isSignedInCached = loggedIn
        if !loggedIn {
            standbySession?.terminate()
            standbySession = nil
        } else {
            let preferredModel = await MainActor.run { AppSettings.shared.model }
            ensureStandby(requestedModel: preferredModel)
        }
        let email = json["email"] as? String
        let plan = json["subscriptionType"] as? String
        let orgName = json["orgName"] as? String
        return ClaudeAccountSnapshot(isSignedIn: loggedIn, email: email, plan: plan, orgName: orgName)
    }

    /// Pre-spawns a warm `claude --input-format stream-json` process in the background so the next translation starts in ~0ms.
    func prewarm(requestedModel: String) async {
        guard Self.findBinary() != nil else { return }
        if isSignedInCached == nil {
            _ = try? await accountSnapshot()
        }
        guard isSignedInCached == true else { return }
        ensureStandby(requestedModel: requestedModel)
    }

    func testConnection() async throws -> [String] {
        let snapshot = try await accountSnapshot()
        guard snapshot.isSignedIn else { throw LLMError.missingClaudeLogin }
        return await MainActor.run { ClaudeAuthStore.builtInModels }
    }

    func runBrowserLogin(onAuthURL: @Sendable @escaping (URL) -> Void) async throws {
        guard let binary = Self.findBinary() else { throw LLMError.missingClaudeCLI }
        cancelBrowserLogin()
        loginCancelled = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.currentDirectoryURL = emptyWorkspaceURL
        proc.arguments = ["auth", "login", "--claudeai"]
        proc.environment = Self.sanitizedEnvironment()
        proc.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let urlScanner = ClaudePipeLineBuffer { line in
            if let url = Self.extractAuthURL(from: line) {
                onAuthURL(url)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { urlScanner.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { urlScanner.append(d) }
        }

        loginProcess = proc

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { [weak self] finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                Task {
                    await self?.finishLoginProcess(finished, continuation: continuation)
                }
            }
            do {
                try proc.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                loginProcess = nil
                continuation.resume(throwing: LLMError.claude(error.localizedDescription))
            }
        }
    }

    private func finishLoginProcess(_ finished: Process, continuation: CheckedContinuation<Void, Error>) {
        if loginProcess === finished { loginProcess = nil }
        if loginCancelled {
            continuation.resume(throwing: CancellationError())
        } else if finished.terminationStatus == 0 {
            continuation.resume()
        } else {
            continuation.resume(throwing: LLMError.claude(L("Claude sign-in was cancelled or failed.")))
        }
    }

    func cancelBrowserLogin() {
        loginCancelled = true
        if let proc = loginProcess, proc.isRunning {
            proc.terminate()
        }
        loginProcess = nil
    }

    func logout() async throws {
        guard let binary = Self.findBinary() else { throw LLMError.missingClaudeCLI }
        standbySession?.terminate()
        standbySession = nil
        isSignedInCached = false
        _ = try await runShortCommand(binary: binary, arguments: ["auth", "logout"])
    }

    func shutdown() {
        cancelBrowserLogin()
        standbySession?.terminate()
        standbySession = nil
    }

    // MARK: Streaming chat (`claude -p --output-format stream-json`)

    nonisolated func streamChat(model: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let procRef = LockedProcessReference()
            let task = Task {
                do {
                    try await self.performStream(model: model, messages: messages, procRef: procRef, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable reason in
                task.cancel()
                if case .cancelled = reason {
                    procRef.terminate()
                }
            }
        }
    }

    private func performStream(
        model: String,
        messages: [ChatMessage],
        procRef: LockedProcessReference,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let binary = Self.findBinary() else { throw LLMError.missingClaudeCLI }
        try Task.checkCancellation()

        // Skip spawning `claude auth status` on every translation once sign-in has been verified.
        if isSignedInCached != true {
            let snapshot = try await accountSnapshot()
            guard snapshot.isSignedIn else {
                isSignedInCached = false
                await MainActor.run { ClaudeAuthStore.shared.status = .signedOut }
                throw LLMError.missingClaudeLogin
            }
            isSignedInCached = true
        }

        let effectiveModel = Self.resolveModel(model)
        if effectiveModel != model.trimmed {
            await MainActor.run {
                if AppSettings.shared.providerID == Providers.claudeAccountID {
                    AppSettings.shared.model = effectiveModel
                }
            }
        }

        let (systemPrompt, userPrompt) = Self.buildPrompts(from: messages)
        let combinedPrompt = "\(systemPrompt)\n\n---\n\n\(userPrompt)"

        let session: WarmClaudeSession
        if let warm = standbySession, warm.isUsable(for: effectiveModel) {
            standbySession = nil
            session = warm
        } else {
            standbySession?.terminate()
            standbySession = nil
            session = try WarmClaudeSession(binary: binary, workspace: emptyWorkspaceURL, model: effectiveModel)
        }

        // Immediately begin warming the next standby process in parallel while this turn streams.
        ensureStandby(requestedModel: effectiveModel)

        do {
            try await session.execute(combinedPrompt: combinedPrompt, procRef: procRef, continuation: continuation)
        } catch let err as LLMError {
            if case .missingClaudeLogin = err {
                isSignedInCached = false
                standbySession?.terminate()
                standbySession = nil
                await MainActor.run { ClaudeAuthStore.shared.status = .signedOut }
            }
            throw err
        }
    }

    private nonisolated static func resolveModel(_ requested: String) -> String {
        let trimmed = requested.trimmed
        if trimmed.isEmpty || trimmed.lowercased().hasPrefix("gpt-") {
            return Providers.preset(Providers.claudeAccountID).defaultModel
        }
        return trimmed
    }

    private func ensureStandby(requestedModel: String) {
        guard isSignedInCached == true, !isSpawningStandby, let binary = Self.findBinary() else { return }
        let effectiveModel = Self.resolveModel(requestedModel)
        if let current = standbySession {
            if current.isUsable(for: effectiveModel) { return }
            current.terminate()
            standbySession = nil
        }
        isSpawningStandby = true
        defer { isSpawningStandby = false }
        standbySession = try? WarmClaudeSession(binary: binary, workspace: emptyWorkspaceURL, model: effectiveModel)
    }

    fileprivate nonisolated static func processStreamJSONLine(
        _ line: String,
        onDelta: (String) -> Void,
        onResult: (Bool, String) -> Void
    ) {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "stream_event":
            if let event = obj["event"] as? [String: Any],
               (event["type"] as? String) == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               (delta["type"] as? String) == "text_delta",
               let text = delta["text"] as? String {
                let clean = stripHiddenBiDi(text)
                if !clean.isEmpty { onDelta(clean) }
            }

        case "result":
            let isError = (obj["is_error"] as? Bool) ?? false
            let resultText = (obj["result"] as? String) ?? ""
            onResult(isError, stripHiddenBiDi(resultText))

        default:
            break
        }
    }

    // MARK: Helpers

    private func runShortCommand(binary: String, arguments: [String]) async throws -> String {
        let workspace = emptyWorkspaceURL
        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binary)
            proc.currentDirectoryURL = workspace
            proc.arguments = arguments
            proc.environment = Self.sanitizedEnvironment()
            proc.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            proc.terminationHandler = { _ in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: outStr.isEmpty ? errStr : outStr)
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: LLMError.claude(error.localizedDescription))
            }
        }
    }

    private nonisolated static func buildPrompts(from messages: [ChatMessage]) -> (system: String, user: String) {
        let systemParts = messages.filter { $0.role == "system" }.map(\.content)
        var system = systemParts.joined(separator: "\n\n")
        system += "\n\nIMPORTANT: Respond directly with the requested text only. Do not invoke any tools or commands, and do not insert hidden Unicode directional formatting characters."

        let conversation = messages.filter { $0.role != "system" }
        if conversation.count <= 1 {
            return (system, conversation.first?.content ?? "")
        }

        var transcript: [String] = []
        for (idx, msg) in conversation.enumerated() {
            let isLast = idx == conversation.count - 1
            if isLast && msg.role == "user" {
                transcript.append("Follow-up question:\n\(msg.content)")
            } else if msg.role == "user" {
                transcript.append("User:\n\(msg.content)")
            } else {
                transcript.append("Assistant:\n\(msg.content)")
            }
        }
        return (system, transcript.joined(separator: "\n\n---\n\n"))
    }

    private nonisolated static func stripHiddenBiDi(_ text: String) -> String {
        text.replacingOccurrences(
            of: "[\\u200E\\u200F\\u202A-\\u202E\\u2066-\\u2069]",
            with: "",
            options: .regularExpression
        )
    }

    private nonisolated static func extractAuthURL(from text: String) -> URL? {
        guard let range = text.range(of: "https://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+", options: .regularExpression) else {
            return nil
        }
        return URL(string: String(text[range]))
    }

    fileprivate nonisolated static func mapErrorMessage(_ message: String) -> LLMError {
        let lower = message.lowercased()
        if lower.contains("not logged in") || lower.contains("unauthorized") || lower.contains("please run /login") || lower.contains("auth login") || lower.contains("401") {
            return .missingClaudeLogin
        }
        return .claude(message)
    }
}

/// Pre-spawned `claude -p --input-format stream-json` process that eliminates the 1.5–3s CLI cold boot.
private final class WarmClaudeSession: @unchecked Sendable {
    let model: String
    let createdAt: Date

    private let lock = NSLock()
    private let process: Process
    private let inPipe: Pipe
    private let outPipe: Pipe
    private let errPipe: Pipe
    private var parser: ClaudePipeLineBuffer?

    private var streamContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var doneContinuation: CheckedContinuation<Void, Error>?
    private var procRef: LockedProcessReference?
    private var bufferedDeltas: [String] = []
    private var yieldedAny = false
    private var errorMessage: String?
    private var stderrData = Data()
    private var terminated = false
    private var exitStatus: Int32 = 0

    init(binary: String, workspace: URL, model: String) throws {
        self.model = model
        self.createdAt = Date()
        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: binary)
        proc.currentDirectoryURL = workspace
        proc.environment = ClaudeAccountClient.sanitizedEnvironment()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--safe-mode",
            "--disable-slash-commands",
            "--no-chrome",
            "--strict-mcp-config",
            "--tools", "",
            "--no-session-persistence",
            "--permission-prompts", "none",
            "--effort", "low",
            "--model", model,
            "--system-prompt", ClaudeAccountClient.standbySystemPrompt,
        ]

        self.process = proc
        self.inPipe = stdinPipe
        self.outPipe = stdoutPipe
        self.errPipe = stderrPipe

        let lineParser = ClaudePipeLineBuffer { [weak self] line in
            self?.handleLine(line)
        }
        self.parser = lineParser

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { lineParser.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.appendStderr(data) }
        }
        proc.terminationHandler = { [weak self] finished in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty {
                lineParser.append(remaining)
                lineParser.append(Data([0x0A]))
            }
            self?.handleTermination(status: finished.terminationStatus)
        }

        do {
            try proc.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw LLMError.claude(error.localizedDescription)
        }
    }

    func isUsable(for requestedModel: String) -> Bool {
        lock.lock()
        let alive = !terminated && process.isRunning
        lock.unlock()
        return alive && model == requestedModel && Date().timeIntervalSince(createdAt) < 480
    }

    func terminate() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? inPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func execute(
        combinedPrompt: String,
        procRef: LockedProcessReference,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let payloadObj: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": combinedPrompt]],
            ],
        ]
        var lineData = try JSONSerialization.data(withJSONObject: payloadObj)
        lineData.append(0x0A)

        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            procRef.set(process)
            if Task.isCancelled {
                procRef.terminate()
                done.resume(throwing: CancellationError())
                return
            }

            var earlyFinish: Result<Void, Error>?
            var pending: [String] = []

            lock.lock()
            self.procRef = procRef
            self.streamContinuation = continuation
            pending = bufferedDeltas
            bufferedDeltas.removeAll()
            if terminated {
                earlyFinish = buildCompletionResultLocked()
            } else {
                self.doneContinuation = done
            }
            lock.unlock()

            for delta in pending { continuation.yield(delta) }

            if let earlyFinish {
                done.resume(with: earlyFinish)
                return
            }

            do {
                try inPipe.fileHandleForWriting.write(contentsOf: lineData)
                try? inPipe.fileHandleForWriting.close()
            } catch {
                lock.lock()
                let waiter = doneContinuation
                doneContinuation = nil
                lock.unlock()
                procRef.terminate()
                waiter?.resume(throwing: LLMError.claude(error.localizedDescription))
            }
        }
    }

    private func handleLine(_ line: String) {
        ClaudeAccountClient.processStreamJSONLine(
            line,
            onDelta: { delta in
                var cont: AsyncThrowingStream<String, Error>.Continuation?
                lock.lock()
                yieldedAny = true
                if let attached = streamContinuation {
                    cont = attached
                } else {
                    bufferedDeltas.append(delta)
                }
                lock.unlock()
                cont?.yield(delta)
            },
            onResult: { isError, resultText in
                var fallbackYield: (AsyncThrowingStream<String, Error>.Continuation, String)?
                lock.lock()
                if isError {
                    errorMessage = resultText.isEmpty ? L("Claude request failed.") : resultText
                } else if !yieldedAny, !resultText.isEmpty {
                    yieldedAny = true
                    if let attached = streamContinuation {
                        fallbackYield = (attached, resultText)
                    } else {
                        bufferedDeltas.append(resultText)
                    }
                }
                lock.unlock()
                if let (cont, text) = fallbackYield { cont.yield(text) }
            }
        )
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        if stderrData.count < 4096 { stderrData.append(data) }
        lock.unlock()
    }

    private func handleTermination(status: Int32) {
        var waiter: CheckedContinuation<Void, Error>?
        var result: Result<Void, Error> = .success(())
        lock.lock()
        terminated = true
        exitStatus = status
        waiter = doneContinuation
        doneContinuation = nil
        if waiter != nil {
            result = buildCompletionResultLocked()
        }
        lock.unlock()
        waiter?.resume(with: result)
    }

    private func buildCompletionResultLocked() -> Result<Void, Error> {
        if procRef?.wasCancelled == true {
            return .failure(CancellationError())
        }
        if let err = errorMessage {
            return .failure(ClaudeAccountClient.mapErrorMessage(err))
        }
        if exitStatus != 0 && !yieldedAny {
            let stderrText = (String(data: stderrData.prefix(800), encoding: .utf8) ?? "").trimmed
            let msg = stderrText.isEmpty ? L("Claude request failed.") : stderrText
            return .failure(ClaudeAccountClient.mapErrorMessage(msg))
        }
        return .success(())
    }
}

private final class LockedProcessReference: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func set(_ proc: Process) {
        lock.lock()
        process = proc
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate, proc.isRunning {
            proc.terminate()
        }
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let proc = process
        process = nil
        lock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }
}

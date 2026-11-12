import Foundation
import AppKit
import Combine

/// Observable authentication & model catalog state for the "ChatGPT Account" provider.
@MainActor
final class ChatGPTAuthStore: ObservableObject {
    static let shared = ChatGPTAuthStore()

    enum Status: Equatable {
        case checking
        case cliMissing
        case signedOut
        case signingIn(loginID: String?, authURL: URL?)
        case signedIn(email: String?, plan: String?, workspace: String?)
        case failed(String)

        var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    @Published fileprivate(set) var status: Status = .checking
    @Published fileprivate(set) var availableModels: [String] = []

    private init() {}

    func refresh() async {
        if ChatGPTAccountClient.findBinary() == nil {
            status = .cliMissing
            availableModels = []
            return
        }
        do {
            let snapshot = try await ChatGPTAccountClient.shared.accountSnapshot()
            apply(snapshot)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func signIn() async {
        guard ChatGPTAccountClient.findBinary() != nil else {
            status = .cliMissing
            return
        }
        do {
            let result = try await ChatGPTAccountClient.shared.startBrowserLogin()
            status = .signingIn(loginID: result.loginID, authURL: result.authURL)
            if let url = result.authURL {
                NSWorkspace.shared.open(url)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func cancelSignIn() async {
        if case .signingIn(let loginID, _) = status {
            await ChatGPTAccountClient.shared.cancelBrowserLogin(loginID: loginID)
        }
        await refresh()
    }

    func signOut() async {
        do {
            try await ChatGPTAccountClient.shared.logout()
            status = .signedOut
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    fileprivate func handleLoginCompleted(success: Bool, error: String?) {
        Task { @MainActor in
            if success {
                await refresh()
            } else {
                status = .failed(error ?? L("Sign-in was cancelled or failed."))
            }
        }
    }

    private func apply(_ snapshot: ChatGPTAccountSnapshot) {
        if snapshot.isSignedIn {
            status = .signedIn(email: snapshot.email, plan: snapshot.plan, workspace: snapshot.workspace)
        } else {
            status = .signedOut
        }
        if !snapshot.models.isEmpty {
            availableModels = snapshot.models
            let settings = AppSettings.shared
            if settings.providerID == Providers.chatGPTAccountID, !snapshot.models.contains(settings.model) {
                settings.model = Providers.bestModel(from: snapshot.models, provider: settings.provider, current: settings.model)
            }
        }
    }
}

struct ChatGPTAccountSnapshot: Sendable {
    var isSignedIn: Bool
    var email: String?
    var plan: String?
    var workspace: String?
    var models: [String]
}

/// Thread-safe line accumulator for `FileHandle.readabilityHandler`.
private final class PipeLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                onLine(line)
            }
        }
    }
}

/// Official ChatGPT subscription bridge powered by OpenAI's `codex app-server` JSON-RPC protocol.
/// Never reads private credential files directly; all auth, token refresh, and inference go through `codex app-server`.
actor ChatGPTAccountClient {
    static let shared = ChatGPTAccountClient()

    private struct ModelMeta: Sendable {
        let id: String
        let isDefault: Bool
        let hidden: Bool
        let defaultEffort: String
        let supportedEfforts: [String]
    }

    private struct TurnHandlers {
        let onDelta: @Sendable (String) -> Void
        let onComplete: @Sendable (Result<Void, Error>) -> Void
        var yieldedAnyDelta = false
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var lineContinuation: AsyncStream<String>.Continuation?
    private var lineConsumerTask: Task<Void, Never>?
    private var isInitialized = false
    private var initializeWaiters: [CheckedContinuation<Void, Error>] = []
    private var isInitializing = false

    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var activeTurns: [String: TurnHandlers] = [:]
    private var cachedModels: [ModelMeta] = []
    private var isSignedInCached: Bool?
    private var standbyThread: (id: String, model: String, systemInstructions: String, createdAt: Date)?
    private var isCreatingStandby = false

    private lazy var emptyWorkspaceURL: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("screenlocalizer-chatgpt-workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Locates the official `codex` executable bundled with ChatGPT.app, Codex.app, Homebrew, or ~/.local/bin.
    nonisolated static func findBinary() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
        ]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":").map(String.init) where !dir.isEmpty {
                candidates.append("\(dir)/codex")
            }
        }
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: Public API

    func accountSnapshot() async throws -> ChatGPTAccountSnapshot {
        try await ensureStarted()
        let accountRes = try await sendRequest(method: "account/read", params: ["refreshToken": false])
        let account = accountRes["account"] as? [String: Any]
        let isSignedIn = account != nil
        isSignedInCached = isSignedIn
        if !isSignedIn { standbyThread = nil }
        let email = account?["email"] as? String
        let plan = account?["planType"] as? String
        let workspace = account?["workspaceName"] as? String

        var modelIDs: [String] = []
        if isSignedIn {
            let metas = (try? await fetchModels(force: true)) ?? cachedModels
            modelIDs = metas.filter { !$0.hidden }.map(\.id)
            if modelIDs.isEmpty { modelIDs = metas.map(\.id) }
        }
        return ChatGPTAccountSnapshot(isSignedIn: isSignedIn, email: email, plan: plan, workspace: workspace, models: modelIDs)
    }

    /// Pre-starts `codex app-server` and prepares a warm ephemeral thread for the default mode so the next shortcut skips `thread/start`.
    func prewarm(requestedModel: String, defaultMessages: [ChatMessage]) async {
        guard Self.findBinary() != nil else { return }
        do {
            try await ensureStarted()
            if isSignedInCached == nil {
                let accountRes = try await sendRequest(method: "account/read", params: ["refreshToken": false])
                isSignedInCached = (accountRes["account"] is [String: Any])
            }
            guard isSignedInCached == true else { return }
            let metas = (try? await fetchModels(force: false)) ?? cachedModels
            let effectiveModel = resolveModel(requestedModel, metas: metas)
            let (systemInstructions, _) = Self.buildTurnPrompts(from: defaultMessages)
            await ensureStandbyThread(model: effectiveModel, systemInstructions: systemInstructions)
        } catch {
            // Best-effort background warmup only.
        }
    }

    func testConnection() async throws -> [String] {
        let snapshot = try await accountSnapshot()
        guard snapshot.isSignedIn else { throw LLMError.missingChatGPTLogin }
        return snapshot.models
    }

    func startBrowserLogin() async throws -> (loginID: String?, authURL: URL?) {
        try await ensureStarted()
        let res = try await sendRequest(method: "account/login/start", params: [
            "type": "chatgpt",
            "useHostedLoginSuccessPage": true,
        ])
        let loginID = res["loginId"] as? String
        let urlString = res["authUrl"] as? String
        return (loginID, urlString.flatMap(URL.init(string:)))
    }

    func cancelBrowserLogin(loginID: String?) async {
        guard let loginID, isInitialized else { return }
        _ = try? await sendRequest(method: "account/login/cancel", params: ["loginId": loginID])
    }

    func logout() async throws {
        try await ensureStarted()
        _ = try await sendRequest(method: "account/logout", params: NSNull())
        isSignedInCached = false
        standbyThread = nil
        cachedModels = []
    }

    nonisolated func streamChat(model: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let state = LockedTurnReference()
            let task = Task {
                do {
                    try await self.performStream(
                        requestedModel: model,
                        messages: messages,
                        allowModelFallback: true,
                        turnRef: state,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable reason in
                task.cancel()
                if case .cancelled = reason, let ids = state.take() {
                    Task { await self.interruptTurn(threadID: ids.threadID, turnID: ids.turnID) }
                }
            }
        }
    }

    func shutdown() {
        teardownProcess(error: CancellationError())
    }

    // MARK: Streaming implementation

    private func performStream(
        requestedModel: String,
        messages: [ChatMessage],
        allowModelFallback: Bool,
        turnRef: LockedTurnReference,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        try await ensureStarted()
        try Task.checkCancellation()

        // Skip redundant account/read RPC on the hot path once sign-in has already been verified.
        if isSignedInCached != true {
            let accountRes = try await sendRequest(method: "account/read", params: ["refreshToken": false])
            guard accountRes["account"] is [String: Any] else {
                isSignedInCached = false
                await MainActor.run { ChatGPTAuthStore.shared.status = .signedOut }
                throw LLMError.missingChatGPTLogin
            }
            isSignedInCached = true
        }

        let metas = cachedModels.isEmpty ? ((try? await fetchModels(force: false)) ?? []) : cachedModels
        let effectiveModel = resolveModel(requestedModel, metas: metas)
        if effectiveModel != requestedModel.trimmed {
            let chosen = effectiveModel
            await MainActor.run {
                if AppSettings.shared.providerID == Providers.chatGPTAccountID {
                    AppSettings.shared.model = chosen
                }
            }
        }

        let effort = preferredEffort(for: effectiveModel, in: metas)
        let (systemInstructions, userPrompt) = Self.buildTurnPrompts(from: messages)

        let threadID: String
        if let warm = standbyThread,
           warm.model == effectiveModel,
           warm.systemInstructions == systemInstructions,
           Date().timeIntervalSince(warm.createdAt) < 540 {
            standbyThread = nil
            threadID = warm.id
        } else {
            threadID = try await startEphemeralThread(model: effectiveModel, systemInstructions: systemInstructions)
        }

        // Replenish a warm standby thread in the background for the next shortcut press.
        Task { await self.ensureStandbyThread(model: effectiveModel, systemInstructions: systemInstructions) }

        try Task.checkCancellation()

        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                activeTurns[threadID] = TurnHandlers(
                    onDelta: { chunk in
                        let clean = Self.stripHiddenBiDi(chunk)
                        if !clean.isEmpty { continuation.yield(clean) }
                    },
                    onComplete: { result in
                        done.resume(with: result)
                    }
                )

                Task {
                    do {
                        let turnRes = try await self.sendRequest(method: "turn/start", params: [
                            "threadId": threadID,
                            "disabledPluginIds": [],
                            "effort": effort,
                            "input": [["type": "text", "text": userPrompt, "text_elements": []]],
                        ])
                        if let turn = turnRes["turn"] as? [String: Any],
                           let turnID = turn["id"] as? String {
                            turnRef.set(threadID: threadID, turnID: turnID)
                            if Task.isCancelled {
                                await self.interruptTurn(threadID: threadID, turnID: turnID)
                            }
                        }
                    } catch {
                        if let handler = self.activeTurns.removeValue(forKey: threadID) {
                            handler.onComplete(.failure(error))
                        }
                    }
                }
            }
        } catch let err as LLMError {
            if case .missingChatGPTLogin = err {
                isSignedInCached = false
                standbyThread = nil
                await MainActor.run { ChatGPTAuthStore.shared.status = .signedOut }
            }
            if case .chatGPT(let message) = err, allowModelFallback && Self.looksLikeUnsupportedModel(message) {
                let metasRefreshed = (try? await fetchModels(force: true)) ?? []
                let fallbackPool = metasRefreshed.filter { !$0.hidden && $0.id != effectiveModel }.map(\.id)
                if let fallback = fallbackPool.first {
                    await MainActor.run {
                        if AppSettings.shared.providerID == Providers.chatGPTAccountID {
                            AppSettings.shared.model = fallback
                        }
                    }
                    try await performStream(
                        requestedModel: fallback,
                        messages: messages,
                        allowModelFallback: false,
                        turnRef: turnRef,
                        continuation: continuation
                    )
                    return
                }
            }
            throw err
        }
    }

    private func resolveModel(_ requestedModel: String, metas: [ModelMeta]) -> String {
        let visibleIDs = metas.filter { !$0.hidden }.map(\.id)
        let allIDs = metas.map(\.id)
        let candidatePool = visibleIDs.isEmpty ? allIDs : visibleIDs
        let trimmedRequested = requestedModel.trimmed
        if !candidatePool.isEmpty && (trimmedRequested.isEmpty || !allIDs.contains(trimmedRequested)) {
            let preset = Providers.preset(Providers.chatGPTAccountID)
            return Providers.bestModel(from: candidatePool, provider: preset, current: trimmedRequested)
        }
        return trimmedRequested.isEmpty ? Providers.preset(Providers.chatGPTAccountID).defaultModel : trimmedRequested
    }

    private func startEphemeralThread(model: String, systemInstructions: String) async throws -> String {
        let threadRes = try await sendRequest(method: "thread/start", params: [
            "model": model,
            "cwd": emptyWorkspaceURL.path,
            "ephemeral": true,
            "sandbox": "read-only",
            "approvalPolicy": "never",
            "baseInstructions": systemInstructions,
        ])
        guard let thread = threadRes["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw LLMError.chatGPT(L("Failed to start a ChatGPT session."))
        }
        return threadID
    }

    private func ensureStandbyThread(model: String, systemInstructions: String) async {
        guard isInitialized, !isCreatingStandby else { return }
        if let existing = standbyThread,
           existing.model == model,
           existing.systemInstructions == systemInstructions,
           Date().timeIntervalSince(existing.createdAt) < 480 {
            return
        }
        isCreatingStandby = true
        defer { isCreatingStandby = false }
        if let id = try? await startEphemeralThread(model: model, systemInstructions: systemInstructions) {
            standbyThread = (id: id, model: model, systemInstructions: systemInstructions, createdAt: Date())
        }
    }

    private func interruptTurn(threadID: String, turnID: String) async {
        guard isInitialized else { return }
        _ = try? await sendRequest(method: "turn/interrupt", params: [
            "threadId": threadID,
            "turnId": turnID,
        ])
    }

    private func fetchModels(force: Bool) async throws -> [ModelMeta] {
        if !force && !cachedModels.isEmpty { return cachedModels }
        let res = try await sendRequest(method: "model/list", params: [:])
        let rows = (res["data"] as? [[String: Any]]) ?? []
        let parsed: [ModelMeta] = rows.compactMap { row in
            guard let id = (row["id"] as? String) ?? (row["model"] as? String) else { return nil }
            let isDefault = (row["isDefault"] as? Bool) ?? false
            let hidden = (row["hidden"] as? Bool) ?? false
            let defaultEffort = (row["defaultReasoningEffort"] as? String) ?? "low"
            let effortsRaw = (row["supportedReasoningEfforts"] as? [[String: Any]]) ?? []
            let efforts = effortsRaw.compactMap { $0["reasoningEffort"] as? String }
            return ModelMeta(id: id, isDefault: isDefault, hidden: hidden, defaultEffort: defaultEffort, supportedEfforts: efforts)
        }
        if !parsed.isEmpty {
            cachedModels = parsed
            let visible = parsed.filter { !$0.hidden }.map(\.id)
            await MainActor.run {
                if !visible.isEmpty { ChatGPTAuthStore.shared.availableModels = visible }
            }
        }
        return parsed
    }

    private func preferredEffort(for modelID: String, in metas: [ModelMeta]) -> String {
        if let meta = metas.first(where: { $0.id == modelID }) {
            if meta.supportedEfforts.contains("none") { return "none" }
            if meta.supportedEfforts.contains("minimal") { return "minimal" }
            if meta.supportedEfforts.contains("low") { return "low" }
            return meta.defaultEffort
        }
        return "low"
    }

    private nonisolated static func buildTurnPrompts(from messages: [ChatMessage]) -> (system: String, user: String) {
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

    private nonisolated static func looksLikeUnsupportedModel(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not supported") || lower.contains("model metadata") || lower.contains("model_not_found")
    }

    // MARK: Process & JSON-RPC transport

    private func ensureStarted() async throws {
        if isInitialized, let process, process.isRunning { return }
        if isInitializing {
            try await withCheckedThrowingContinuation { waiter in
                initializeWaiters.append(waiter)
            }
            return
        }

        guard let binaryPath = Self.findBinary() else {
            throw LLMError.missingCodexCLI
        }

        isInitializing = true
        do {
            try spawnProcess(at: binaryPath)
            _ = try await sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "ScreenLocalizer",
                        "title": "ScreenLocalizer",
                        "version": AppInfo.version,
                    ],
                    "capabilities": NSNull(),
                ],
                allowUninitialized: true
            )
            try sendNotification(method: "initialized", params: [:])
            isInitialized = true
            isInitializing = false
            let waiters = initializeWaiters
            initializeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        } catch {
            isInitializing = false
            let waiters = initializeWaiters
            initializeWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: error) }
            teardownProcess(error: error)
            throw error
        }
    }

    private func spawnProcess(at binaryPath: String) throws {
        teardownProcess(error: CancellationError())

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.currentDirectoryURL = emptyWorkspaceURL
        proc.arguments = [
            "-c", "mcp_servers={}",
            "-c", "project_doc_max_bytes=0",
            "--enable", "skip_host_skill_discovery",
            "--disable", "apps",
            "--disable", "shell_tool",
            "--disable", "unified_exec",
            "--disable", "browser_use",
            "--disable", "computer_use",
            "--disable", "view_image",
            "--disable", "sleep_tool",
            "--disable", "tool_suggest",
            "--disable", "skill_search",
            "app-server", "--stdio",
        ]

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [currentPath]).filter { !$0.isEmpty }.joined(separator: ":")
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let (lineStream, continuation) = AsyncStream.makeStream(of: String.self)
        let consumerTask = Task { [weak self] in
            for await line in lineStream {
                guard let self else { break }
                await self.handleIncomingLine(line)
            }
        }
        let lineBuffer = PipeLineBuffer { line in
            continuation.yield(line)
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                lineBuffer.append(data)
            }
        }
        // Drain stderr quietly so the pipe buffer can never block the child process.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        proc.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            Task { await self.handleProcessTerminated(terminated) }
        }

        do {
            try proc.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            consumerTask.cancel()
            throw LLMError.chatGPT(error.localizedDescription)
        }

        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        self.lineContinuation = continuation
        self.lineConsumerTask = consumerTask
    }

    private func handleProcessTerminated(_ terminated: Process) {
        guard process === terminated else { return }
        teardownProcess(error: LLMError.chatGPT(L("The ChatGPT local service stopped unexpectedly. Try again.")))
    }

    private func teardownProcess(error: Error) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        lineContinuation?.finish()
        lineContinuation = nil
        lineConsumerTask?.cancel()
        lineConsumerTask = nil
        try? stdinHandle?.close()
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdinHandle = nil
        stdoutPipe = nil
        stderrPipe = nil
        isInitialized = false
        standbyThread = nil

        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, cont) in pending { cont.resume(throwing: error) }

        let turns = activeTurns
        activeTurns.removeAll()
        for (_, handler) in turns { handler.onComplete(.failure(error)) }
    }

    private func sendRequest(method: String, params: Any, allowUninitialized: Bool = false) async throws -> [String: Any] {
        guard allowUninitialized || isInitialized else { throw LLMError.chatGPT(L("ChatGPT service is not initialized.")) }
        let id = nextRequestID
        nextRequestID += 1

        var payload: [String: Any] = ["id": id, "method": method]
        if !(params is NSNull) {
            payload["params"] = params
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            do {
                try writeJSONLine(payload)
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try writeJSONLine(["method": method, "params": params])
    }

    private func writeJSONLine(_ object: [String: Any]) throws {
        guard let handle = stdinHandle else {
            throw LLMError.chatGPT(L("ChatGPT connection is closed."))
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func handleIncomingLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // 1. JSON-RPC Response
        if let id = msg["id"] as? Int, msg["method"] == nil {
            guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
            if let err = msg["error"] as? [String: Any] {
                let message = (err["message"] as? String) ?? L("Unknown ChatGPT error.")
                continuation.resume(throwing: Self.mapErrorMessage(message))
            } else {
                let result = (msg["result"] as? [String: Any]) ?? [:]
                continuation.resume(returning: result)
            }
            return
        }

        // 2. Server-to-client Request (auto-decline any unexpected approval prompt in read-only mode)
        if let reqID = msg["id"], let method = msg["method"] as? String {
            if method.contains("Approval") {
                try? writeJSONLine(["id": reqID, "result": ["decision": "decline"]])
            }
            return
        }

        // 3. Server Notification
        guard let method = msg["method"] as? String,
              let params = msg["params"] as? [String: Any] else { return }

        switch method {
        case "item/agentMessage/delta":
            if let threadID = params["threadId"] as? String,
               let delta = params["delta"] as? String,
               !delta.isEmpty,
               var handler = activeTurns[threadID] {
                handler.yieldedAnyDelta = true
                activeTurns[threadID] = handler
                handler.onDelta(delta)
            }

        case "item/completed":
            if let threadID = params["threadId"] as? String,
               let handler = activeTurns[threadID],
               !handler.yieldedAnyDelta,
               let item = params["item"] as? [String: Any],
               (item["type"] as? String) == "agentMessage",
               let text = item["text"] as? String,
               !text.isEmpty {
                var updated = handler
                updated.yieldedAnyDelta = true
                activeTurns[threadID] = updated
                updated.onDelta(text)
            }

        case "turn/completed":
            guard let threadID = params["threadId"] as? String,
                  let handler = activeTurns.removeValue(forKey: threadID) else { return }
            let turn = params["turn"] as? [String: Any]
            let status = (turn?["status"] as? String) ?? "completed"
            if status == "completed" {
                handler.onComplete(.success(()))
            } else if status == "interrupted" {
                handler.onComplete(.failure(CancellationError()))
            } else {
                let errObj = turn?["error"] as? [String: Any]
                let message = (errObj?["message"] as? String) ?? L("ChatGPT request failed.")
                handler.onComplete(.failure(Self.mapErrorMessage(message)))
            }

        case "account/login/completed":
            let success = (params["success"] as? Bool) ?? false
            let errText = params["error"] as? String
            Task { @MainActor in
                ChatGPTAuthStore.shared.handleLoginCompleted(success: success, error: errText)
            }

        case "account/updated":
            Task { @MainActor in
                await ChatGPTAuthStore.shared.refresh()
            }

        default:
            break
        }
    }

    private nonisolated static func mapErrorMessage(_ message: String) -> LLMError {
        let lower = message.lowercased()
        if lower.contains("unauthorized") || lower.contains("not logged in") || lower.contains("authentication") || lower.contains("401") {
            return .missingChatGPTLogin
        }
        return .chatGPT(message)
    }
}

private final class LockedTurnReference: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: (threadID: String, turnID: String)?

    func set(threadID: String, turnID: String) {
        lock.lock()
        ids = (threadID, turnID)
        lock.unlock()
    }

    func take() -> (threadID: String, turnID: String)? {
        lock.lock()
        defer { lock.unlock() }
        let current = ids
        ids = nil
        return current
    }
}

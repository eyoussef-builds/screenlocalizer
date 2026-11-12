import Foundation

struct LLMConfig {
    var providerID: String = "openai"
    var baseURL: String
    var apiKey: String?
    var model: String
    var requiresKey: Bool
}

enum LLMError: LocalizedError {
    case missingKey
    case missingChatGPTLogin
    case missingCodexCLI
    case chatGPT(String)
    case missingClaudeLogin
    case missingClaudeCLI
    case claude(String)
    case invalidURL
    case http(Int, String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return L("No API key yet. Add your key in Settings → AI.")
        case .missingChatGPTLogin:
            return L("Not signed in to ChatGPT yet. Sign in from Settings → AI.")
        case .missingCodexCLI:
            return L("Install the official ChatGPT macOS app or Codex CLI to sign in with ChatGPT. Check Settings → AI.")
        case .chatGPT(let message):
            return message
        case .missingClaudeLogin:
            return L("Not signed in to Claude yet. Sign in from Settings → AI.")
        case .missingClaudeCLI:
            return L("Install Claude Code CLI to sign in with your Claude account. Check Settings → AI.")
        case .claude(let message):
            return message
        case .invalidURL:
            return L("The API base URL is not valid. Check Settings → AI.")
        case .http(let code, let message):
            let detail = message.isEmpty ? "" : "\n\(message)"
            switch code {
            case 401: return L("The API key was rejected. Check it in Settings → AI.") + detail
            case 404: return L("Model or endpoint not found. Check the model name in Settings → AI.") + detail
            case 429: return L("Rate limit reached or no credit left on this API account.") + detail
            default: return LF("The AI service returned an error (HTTP %d).", code) + detail
            }
        case .network(let message):
            return L("Couldn't reach the AI service. Check your internet connection.") + "\n" + message
        }
    }

    var isMissingKey: Bool {
        switch self {
        case .missingKey, .missingChatGPTLogin, .missingCodexCLI, .missingClaudeLogin, .missingClaudeCLI, .http(401, _):
            return true
        default:
            return false
        }
    }
}

/// Bounded in-memory LRU cache for recent mode outputs so re-selecting the same text returns in 0ms.
final class TranslationCache: @unchecked Sendable {
    static let shared = TranslationCache()

    private let lock = NSLock()
    private let capacity = 64
    private var entries: [String: String] = [:]
    private var order: [String] = []

    private init() {}

    @MainActor
    static func makeKey(mode: Mode, source: String, settings: AppSettings) -> String {
        let glossarySig = settings.glossary
            .map { "\($0.term.trimmed)=\($0.rendering.trimmed)" }
            .joined(separator: ";")
        return [
            settings.providerID,
            settings.model.trimmed,
            settings.targetLanguage.trimmed,
            mode.rawValue,
            settings.customInstructions.trimmed,
            glossarySig,
            source.trimmed,
        ].joined(separator: "\u{001F}")
    }

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = entries[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return value
    }

    func set(_ value: String, for key: String) {
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else { return }
        lock.lock()
        if entries[key] != nil, let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        } else if order.count >= capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        entries[key] = value
        order.append(key)
        lock.unlock()
    }
}

/// Minimal client for OpenAI-compatible APIs (OpenAI, OpenRouter, Groq, Ollama, LM Studio, …).
enum LLMClient {
    private static let fastSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private static let warmLock = NSLock()
    private static var lastHTTPWarmupByHost: [String: Date] = [:]

    /// Predictively wakes the active provider runtime or warms TLS/HTTP2 connections before the user clicks.
    @MainActor
    static func prewarmActiveProvider() {
        let settings = AppSettings.shared
        let providerID = settings.providerID
        let model = settings.model
        if providerID == Providers.chatGPTAccountID {
            let defaultMsgs = Prompts.messages(mode: settings.defaultMode, source: "warmup", context: SourceContext(), settings: settings)
            Task { await ChatGPTAccountClient.shared.prewarm(requestedModel: model, defaultMessages: defaultMsgs) }
            return
        }
        if providerID == Providers.claudeAccountID {
            Task { await ClaudeAccountClient.shared.prewarm(requestedModel: model) }
            return
        }
        let config = settings.llmConfig
        if config.requiresKey && (config.apiKey ?? "").isEmpty { return }
        guard let modelsURL = url(config.baseURL, "/models"), let host = modelsURL.host else { return }
        warmLock.lock()
        let last = lastHTTPWarmupByHost[host] ?? .distantPast
        let shouldWarm = Date().timeIntervalSince(last) > 45
        if shouldWarm { lastHTTPWarmupByHost[host] = Date() }
        warmLock.unlock()
        guard shouldWarm, var req = try? request(modelsURL, config: config) else { return }
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        Task.detached(priority: .utility) {
            _ = try? await fastSession.data(for: req)
        }
    }

    static func url(_ base: String, _ path: String) -> URL? {
        var trimmed = base.trimmed
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed + path), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    private static func request(_ url: URL, config: LLMConfig) throws -> URLRequest {
        if config.requiresKey && (config.apiKey ?? "").isEmpty { throw LLMError.missingKey }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if url.host?.contains("openrouter.ai") == true {
            req.setValue(AppInfo.repoURL.absoluteString, forHTTPHeaderField: "HTTP-Referer")
            req.setValue("ScreenLocalizer", forHTTPHeaderField: "X-Title")
        }
        return req
    }

    // MARK: Chat (streaming)

    static func streamChat(config: LLMConfig, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        if config.providerID == Providers.chatGPTAccountID {
            return ChatGPTAccountClient.shared.streamChat(model: config.model, messages: messages)
        }
        if config.providerID == Providers.claudeAccountID {
            return ClaudeAccountClient.shared.streamChat(model: config.model, messages: messages)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(config: config, messages: messages, tuned: true, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func performStream(config: LLMConfig, messages: [ChatMessage], tuned: Bool,
                                      continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let url = url(config.baseURL, "/chat/completions") else { throw LLMError.invalidURL }
        var req = try request(url, config: config)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        if tuned { body.merge(tuning(for: config, url: url)) { _, new in new } }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await fastSession.bytes(for: req)
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            throw LLMError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 32_000 { break }
            }
            let message = errorMessage(from: data)
            // Some models reject temperature / reasoning settings; retry once without them.
            if status == 400 && tuned && looksLikeParameterError(message) {
                try await performStream(config: config, messages: messages, tuned: false, continuation: continuation)
                return
            }
            throw LLMError.http(status, message)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = object["error"] as? [String: Any] {
                throw LLMError.http(status, error["message"] as? String ?? "")
            }
            if let choices = object["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                continuation.yield(content)
            }
        }
    }

    /// Reasoning models (GPT-5 family, o-series) reject `temperature`; give them minimal reasoning for speed instead.
    private static func tuning(for config: LLMConfig, url: URL) -> [String: Any] {
        let model = config.model.lowercased()
        let name = model.split(separator: "/").last.map(String.init) ?? model
        let reasoning = name.hasPrefix("gpt-5") || name.hasPrefix("gpt-6") || name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4")
        if reasoning {
            if url.host == "api.openai.com" && !name.contains("chat") { return ["reasoning_effort": "minimal"] }
            return [:]
        }
        return ["temperature": 0.3]
    }

    private static func looksLikeParameterError(_ message: String) -> Bool {
        let l = message.lowercased()
        return ["temperature", "reasoning", "unsupported", "unrecognized", "not supported", "unknown parameter", "invalid value"].contains { l.contains($0) }
    }

    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = object["error"] as? String { return message }
            if let message = object["message"] as? String { return message }
        }
        return String(data: data.prefix(400), encoding: .utf8)?.trimmed ?? ""
    }

    // MARK: Models & connection test

    static func listModels(config: LLMConfig) async throws -> [String] {
        if config.providerID == Providers.chatGPTAccountID {
            return try await ChatGPTAccountClient.shared.testConnection()
        }
        if config.providerID == Providers.claudeAccountID {
            return try await ClaudeAccountClient.shared.testConnection()
        }
        guard let url = url(config.baseURL, "/models") else { throw LLMError.invalidURL }
        var req = try request(url, config: config)
        req.timeoutInterval = 20
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await fastSession.data(for: req) } catch { throw LLMError.network(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.http(status, errorMessage(from: data)) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = (object?["data"] as? [[String: Any]]) ?? (object?["models"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
    }

    /// Returns the provider's models (possibly empty if it has no /models endpoint) after a successful round trip.
    static func testConnection(config: LLMConfig) async throws -> [String] {
        do {
            return try await listModels(config: config)
        } catch LLMError.http(let code, _) where code == 404 || code == 405 {
            var reply = ""
            for try await chunk in streamChat(config: config, messages: [ChatMessage(role: "user", content: "Reply with: OK")]) {
                reply += chunk
                if reply.count > 4 { break }
            }
            return []
        }
    }

    // MARK: Text to speech (OpenAI)

    static func speech(config: LLMConfig, text: String, voice: String) async throws -> Data {
        guard let url = url(config.baseURL, "/audio/speech") else { throw LLMError.invalidURL }
        for model in ["gpt-4o-mini-tts", "tts-1"] {
            var req = try request(url, config: config)
            req.httpMethod = "POST"
            req.timeoutInterval = 90
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "input": text, "voice": voice, "response_format": "mp3",
            ])
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await URLSession.shared.data(for: req) } catch { throw LLMError.network(error.localizedDescription) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return data }
            if model == "tts-1" || !(status == 400 || status == 404) { throw LLMError.http(status, errorMessage(from: data)) }
        }
        throw LLMError.http(0, "")
    }
}

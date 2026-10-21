import Foundation

struct LLMConfig {
    var baseURL: String
    var apiKey: String?
    var model: String
    var requiresKey: Bool
}

enum LLMError: LocalizedError {
    case missingKey
    case invalidURL
    case http(Int, String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return L("No API key yet. Add your key in Settings → AI.")
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
        if case .missingKey = self { return true }
        if case .http(401, _) = self { return true }
        return false
    }
}

/// Minimal client for OpenAI-compatible APIs (OpenAI, OpenRouter, Groq, Ollama, LM Studio, …).
enum LLMClient {
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
        AsyncThrowingStream { continuation in
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
            (bytes, response) = try await URLSession.shared.bytes(for: req)
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
        guard let url = url(config.baseURL, "/models") else { throw LLMError.invalidURL }
        var req = try request(url, config: config)
        req.timeoutInterval = 20
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: req) } catch { throw LLMError.network(error.localizedDescription) }
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

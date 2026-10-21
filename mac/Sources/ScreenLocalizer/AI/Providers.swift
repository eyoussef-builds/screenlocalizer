import Foundation

struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let needsKey: Bool
    let keyURL: String?
    let defaultModel: String
    /// Models to prefer, in order, when the provider's model list is fetched.
    let preferredModels: [String]
}

enum Providers {
    static let openAIBase = "https://api.openai.com/v1"

    static let all: [ProviderPreset] = [
        .init(id: "openai", name: "OpenAI", baseURL: openAIBase, needsKey: true,
              keyURL: "https://platform.openai.com/api-keys", defaultModel: "gpt-5-mini",
              preferredModels: ["gpt-5-mini", "gpt-5-nano", "gpt-4.1-mini", "gpt-4o-mini", "gpt-5", "gpt-4.1", "gpt-4o"]),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", needsKey: true,
              keyURL: "https://openrouter.ai/keys", defaultModel: "openai/gpt-5-mini",
              preferredModels: ["openai/gpt-5-mini", "openai/gpt-4.1-mini", "openai/gpt-4o-mini"]),
        .init(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", needsKey: true,
              keyURL: "https://console.groq.com/keys", defaultModel: "llama-3.3-70b-versatile",
              preferredModels: ["llama-3.3-70b-versatile"]),
        .init(id: "ollama", name: "Ollama (local)", baseURL: "http://localhost:11434/v1", needsKey: false,
              keyURL: nil, defaultModel: "llama3.2", preferredModels: []),
        .init(id: "lmstudio", name: "LM Studio (local)", baseURL: "http://localhost:1234/v1", needsKey: false,
              keyURL: nil, defaultModel: "local-model", preferredModels: []),
        .init(id: "custom", name: "Custom (OpenAI-compatible)", baseURL: "", needsKey: false,
              keyURL: nil, defaultModel: "", preferredModels: []),
    ]

    static func preset(_ id: String) -> ProviderPreset {
        all.first { $0.id == id } ?? all[0]
    }

    /// Picks the best model from a fetched list, preferring the provider's known-good choices.
    static func bestModel(from models: [String], provider: ProviderPreset, current: String) -> String {
        if models.contains(current) { return current }
        for preferred in provider.preferredModels where models.contains(preferred) {
            return preferred
        }
        let chatLike = models.filter { id in
            let l = id.lowercased()
            return !["embed", "whisper", "tts", "dall-e", "image", "moderation", "audio", "realtime", "transcribe", "search"].contains { l.contains($0) }
        }
        return chatLike.first ?? models.first ?? current
    }
}

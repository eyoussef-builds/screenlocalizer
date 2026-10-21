import Foundation
import Combine

/// All user preferences, persisted in UserDefaults. API keys are stored separately in the Keychain.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: "targetLanguage") } }
    @Published var defaultMode: Mode { didSet { defaults.set(defaultMode.rawValue, forKey: "defaultMode") } }
    @Published var customInstructions: String { didSet { defaults.set(customInstructions, forKey: "customInstructions") } }

    @Published var providerID: String { didSet { defaults.set(providerID, forKey: "providerID") } }
    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: "baseURL") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }

    @Published var floatingButtonEnabled: Bool { didSet { defaults.set(floatingButtonEnabled, forKey: "floatingButtonEnabled") } }
    @Published var clipboardAction: ClipboardAction { didSet { defaults.set(clipboardAction.rawValue, forKey: "clipboardAction") } }
    @Published var hidePanelFromCapture: Bool { didSet { defaults.set(hidePanelFromCapture, forKey: "hidePanelFromCapture") } }
    @Published var sideBySide: Bool { didSet { defaults.set(sideBySide, forKey: "sideBySide") } }
    @Published var panelFontSize: Double { didSet { defaults.set(panelFontSize, forKey: "panelFontSize") } }
    @Published var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: "historyEnabled") } }

    @Published var ttsEngine: TTSEngine { didSet { defaults.set(ttsEngine.rawValue, forKey: "ttsEngine") } }
    @Published var openAIVoice: String { didSet { defaults.set(openAIVoice, forKey: "openAIVoice") } }
    @Published var systemVoiceID: String { didSet { defaults.set(systemVoiceID, forKey: "systemVoiceID") } }

    @Published var glossary: [GlossaryEntry] { didSet { saveJSON(glossary, "glossary") } }
    @Published var hotkeys: [HotkeyAction: KeyCombo] {
        didSet {
            let raw = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
            saveJSON(raw, "hotkeys")
        }
    }

    @Published var interfaceLanguage: InterfaceLanguage {
        didSet {
            defaults.set(interfaceLanguage.rawValue, forKey: "interfaceLanguage")
            switch interfaceLanguage {
            case .system: defaults.removeObject(forKey: "AppleLanguages")
            case .en: defaults.set(["en"], forKey: "AppleLanguages")
            case .ar: defaults.set(["ar"], forKey: "AppleLanguages")
            }
        }
    }

    private init() {
        let d = UserDefaults.standard
        onboardingDone = d.bool(forKey: "onboardingDone")
        targetLanguage = d.string(forKey: "targetLanguage") ?? Languages.guessDefault()
        defaultMode = Mode(rawValue: d.string(forKey: "defaultMode") ?? "") ?? .translate
        customInstructions = d.string(forKey: "customInstructions") ?? ""

        let provider = d.string(forKey: "providerID") ?? "openai"
        providerID = provider
        baseURL = d.string(forKey: "baseURL") ?? Providers.preset(provider).baseURL
        model = d.string(forKey: "model") ?? Providers.preset(provider).defaultModel

        floatingButtonEnabled = d.object(forKey: "floatingButtonEnabled") as? Bool ?? true
        clipboardAction = ClipboardAction(rawValue: d.string(forKey: "clipboardAction") ?? "") ?? .off
        hidePanelFromCapture = d.object(forKey: "hidePanelFromCapture") as? Bool ?? true
        sideBySide = d.object(forKey: "sideBySide") as? Bool ?? false
        panelFontSize = d.object(forKey: "panelFontSize") as? Double ?? 16
        historyEnabled = d.object(forKey: "historyEnabled") as? Bool ?? true

        ttsEngine = TTSEngine(rawValue: d.string(forKey: "ttsEngine") ?? "") ?? (provider == "openai" ? .openai : .system)
        openAIVoice = d.string(forKey: "openAIVoice") ?? "alloy"
        systemVoiceID = d.string(forKey: "systemVoiceID") ?? ""

        glossary = AppSettings.loadJSON([GlossaryEntry].self, "glossary") ?? []
        if let raw = AppSettings.loadJSON([String: KeyCombo].self, "hotkeys") {
            var map: [HotkeyAction: KeyCombo] = [:]
            for (key, combo) in raw { if let action = HotkeyAction(rawValue: key) { map[action] = combo } }
            hotkeys = map
        } else {
            hotkeys = KeyCombo.defaults
        }
        interfaceLanguage = InterfaceLanguage(rawValue: d.string(forKey: "interfaceLanguage") ?? "") ?? .system
    }

    var provider: ProviderPreset { Providers.preset(providerID) }

    var apiKey: String? { Keychain.get(providerID) }

    func setAPIKey(_ key: String) {
        Keychain.set(key, for: providerID)
        objectWillChange.send()
    }

    func selectProvider(_ id: String) {
        let preset = Providers.preset(id)
        providerID = id
        if !preset.baseURL.isEmpty || id == "custom" { baseURL = preset.baseURL }
        if !preset.defaultModel.isEmpty { model = preset.defaultModel }
    }

    var llmConfig: LLMConfig {
        LLMConfig(baseURL: baseURL, apiKey: apiKey, model: model, requiresKey: provider.needsKey)
    }

    /// OpenAI credentials for text-to-speech, which only OpenAI provides.
    var speechConfig: LLMConfig? {
        if DebugHooks.enabled, let override = DebugHooks.ttsOverride { return override }
        if providerID == "openai", let key = apiKey { return LLMConfig(baseURL: baseURL, apiKey: key, model: model, requiresKey: true) }
        if let key = Keychain.get("openai") { return LLMConfig(baseURL: Providers.openAIBase, apiKey: key, model: model, requiresKey: true) }
        return nil
    }

    private func saveJSON<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

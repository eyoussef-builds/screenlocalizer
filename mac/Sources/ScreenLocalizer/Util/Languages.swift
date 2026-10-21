import Foundation

struct TargetLanguage: Identifiable, Hashable {
    /// English name; this is what goes into the prompt.
    let id: String
    let native: String
    let rtl: Bool
    let speechCode: String
}

enum Languages {
    static let all: [TargetLanguage] = [
        .init(id: "Arabic", native: "العربية", rtl: true, speechCode: "ar-SA"),
        .init(id: "Egyptian Arabic", native: "العربية (المصرية)", rtl: true, speechCode: "ar-SA"),
        .init(id: "English", native: "English", rtl: false, speechCode: "en-US"),
        .init(id: "French", native: "Français", rtl: false, speechCode: "fr-FR"),
        .init(id: "Spanish", native: "Español", rtl: false, speechCode: "es-ES"),
        .init(id: "German", native: "Deutsch", rtl: false, speechCode: "de-DE"),
        .init(id: "Portuguese", native: "Português", rtl: false, speechCode: "pt-BR"),
        .init(id: "Italian", native: "Italiano", rtl: false, speechCode: "it-IT"),
        .init(id: "Turkish", native: "Türkçe", rtl: false, speechCode: "tr-TR"),
        .init(id: "Persian", native: "فارسی", rtl: true, speechCode: "fa-IR"),
        .init(id: "Urdu", native: "اردو", rtl: true, speechCode: "ur-PK"),
        .init(id: "Hebrew", native: "עברית", rtl: true, speechCode: "he-IL"),
        .init(id: "Hindi", native: "हिन्दी", rtl: false, speechCode: "hi-IN"),
        .init(id: "Indonesian", native: "Bahasa Indonesia", rtl: false, speechCode: "id-ID"),
        .init(id: "Russian", native: "Русский", rtl: false, speechCode: "ru-RU"),
        .init(id: "Chinese (Simplified)", native: "简体中文", rtl: false, speechCode: "zh-CN"),
        .init(id: "Japanese", native: "日本語", rtl: false, speechCode: "ja-JP"),
        .init(id: "Korean", native: "한국어", rtl: false, speechCode: "ko-KR"),
    ]

    static func find(_ name: String) -> TargetLanguage? {
        all.first { $0.id.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func isRTL(_ name: String) -> Bool {
        if let lang = find(name) { return lang.rtl }
        let lower = name.lowercased()
        return ["arab", "عرب", "persian", "farsi", "urdu", "hebrew", "pashto", "kurdish"].contains { lower.contains($0) }
    }

    static func speechCode(_ name: String) -> String {
        find(name)?.speechCode ?? (isRTL(name) ? "ar-SA" : "en-US")
    }

    /// Best guess for a first-launch default: the first preferred system language that isn't English.
    static func guessDefault() -> String {
        let map: [String: String] = [
            "ar": "Arabic", "fr": "French", "es": "Spanish", "de": "German", "pt": "Portuguese",
            "it": "Italian", "tr": "Turkish", "fa": "Persian", "ur": "Urdu", "he": "Hebrew",
            "hi": "Hindi", "id": "Indonesian", "ru": "Russian", "zh": "Chinese (Simplified)",
            "ja": "Japanese", "ko": "Korean",
        ]
        for code in Locale.preferredLanguages {
            let base = String(code.prefix(2))
            if let name = map[base] { return name }
        }
        return "Arabic"
    }
}

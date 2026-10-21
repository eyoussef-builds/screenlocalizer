import Foundation

enum Mode: String, CaseIterable, Codable, Identifiable {
    case translate, explain, simplify, summarize, script, post

    var id: String { rawValue }

    var label: String {
        switch self {
        case .translate: return L("Translate")
        case .explain: return L("Explain")
        case .simplify: return L("Simplify")
        case .summarize: return L("Summarize")
        case .script: return L("Video Script")
        case .post: return L("Social Post")
        }
    }

    var symbol: String {
        switch self {
        case .translate: return "character.book.closed"
        case .explain: return "lightbulb"
        case .simplify: return "face.smiling"
        case .summarize: return "list.bullet"
        case .script: return "video"
        case .post: return "text.bubble"
        }
    }
}

enum SourceOrigin: String, Codable {
    case selection, ocr, paste, clipboard, floating

    var label: String {
        switch self {
        case .selection: return L("Selected text")
        case .ocr: return L("Screen capture")
        case .paste: return L("Paste box")
        case .clipboard: return L("Clipboard")
        case .floating: return L("Selected text")
        }
    }

    var symbol: String {
        switch self {
        case .selection, .floating: return "text.cursor"
        case .ocr: return "viewfinder"
        case .paste: return "doc.on.clipboard"
        case .clipboard: return "clipboard"
        }
    }
}

enum ClipboardAction: String, CaseIterable, Identifiable {
    case off, button, translate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return L("Do nothing")
        case .button: return L("Show the translate button")
        case .translate: return L("Translate immediately")
        }
    }
}

enum TTSEngine: String, CaseIterable, Identifiable {
    case system, openai
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L("macOS voice (free, offline)")
        case .openai: return L("OpenAI voice (natural, uses your key)")
        }
    }
}

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, en, ar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L("Same as macOS")
        case .en: return "English"
        case .ar: return "العربية"
        }
    }
}

struct GlossaryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var term: String
    var rendering: String
}

struct ChatTurn: Codable, Identifiable, Equatable {
    var id = UUID()
    var question: String
    var answer: String
}

struct ChatMessage: Equatable {
    var role: String
    var content: String
}

import Foundation

/// Looks up a UI string in Localizable.strings (English text is the key).
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized format string, e.g. LF("%d items", 3).
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

import AppKit

// macOS only mirrors an app's layout for a right-to-left language when the whole system uses it.
// When Arabic (or another RTL language) is chosen just for this app, ask AppKit to mirror it too.
// AppKit reads this from the app's own preferences domain, not from registered defaults.
let defaults = UserDefaults.standard
let rtl = Bundle.main.preferredLocalizations.first
    .map { Locale.Language(identifier: $0).characterDirection == .rightToLeft } ?? false
if rtl {
    defaults.set(true, forKey: "AppleTextDirection")
    defaults.set(true, forKey: "rtlLayoutApplied")
} else if defaults.bool(forKey: "rtlLayoutApplied") {
    defaults.removeObject(forKey: "AppleTextDirection")
    defaults.removeObject(forKey: "rtlLayoutApplied")
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // NSApplication holds its delegate weakly; this local lives as long as run() does.
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

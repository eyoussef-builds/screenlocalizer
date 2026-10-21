import AppKit
import SwiftUI

enum AppWindowKind: Hashable {
    case settings, history, onboarding
}

enum SettingsTab: String, Hashable {
    case general, ai, triggers, glossary, voice, permissions, about
}

final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
}

/// Opens the app's regular windows and shows the Dock icon only while one of them is open.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var windows: [AppWindowKind: NSWindow] = [:]

    func show(_ kind: AppWindowKind, tab: SettingsTab? = nil) {
        if let tab { SettingsNavigation.shared.tab = tab }
        let window = windows[kind] ?? make(kind)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ kind: AppWindowKind) {
        windows[kind]?.close()
    }

    var hasVisibleWindow: Bool { windows.values.contains { $0.isVisible } }

    private func make(_ kind: AppWindowKind) -> NSWindow {
        let window: NSWindow
        switch kind {
        case .settings:
            window = makeWindow(SettingsView(), title: L("ScreenLocalizer Settings"), size: NSSize(width: 660, height: 720))
            window.identifier = NSUserInterfaceItemIdentifier("settings")
        case .history:
            window = makeWindow(HistoryView(), title: L("ScreenLocalizer History"), size: NSSize(width: 920, height: 620))
            window.setFrameAutosaveName("HistoryWindow")
        case .onboarding:
            window = makeWindow(OnboardingView(), title: L("Welcome to ScreenLocalizer"), size: NSSize(width: 620, height: 560))
            window.styleMask.remove(.resizable)
        }
        windows[kind] = window
        return window
    }

    private func makeWindow<V: View>(_ view: V, title: String, size: NSSize) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { self.updateActivationPolicy() }
    }

    private func updateActivationPolicy() {
        if !hasVisibleWindow { NSApp.setActivationPolicy(.accessory) }
    }
}

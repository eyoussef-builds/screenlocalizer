import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusMenuBuilder = StatusMenuBuilder()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainMenu.install()
        setupStatusItem()

        let settings = AppSettings.shared
        HotkeyManager.shared.onAction = { action in
            Task { @MainActor in
                switch action {
                case .translateSelection: Actions.translateSelection()
                case .captureScreen: Actions.captureScreen()
                case .pasteBox: Actions.openPasteBox()
                }
            }
        }
        HotkeyManager.shared.registerAll(settings.hotkeys)
        settings.$hotkeys.dropFirst().sink { combos in
            DispatchQueue.main.async { HotkeyManager.shared.registerAll(combos) }
        }.store(in: &cancellables)

        HistoryStore.shared.load()
        SelectionWatcher.shared.start()
        ClipboardWatcher.shared.start()

        if !settings.onboardingDone || CommandLine.arguments.contains("--onboarding") {
            WindowManager.shared.show(.onboarding)
        }
        DebugHooks.run()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !WindowManager.shared.hasVisibleWindow { WindowManager.shared.show(.history) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "ScreenLocalizer")
                ?? NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "ScreenLocalizer")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "ScreenLocalizer"
        }
        let menu = NSMenu()
        menu.delegate = statusMenuBuilder
        // AppKit won't start tracking an empty menu, so fill it once now; the delegate refreshes it on every open.
        statusMenuBuilder.menuNeedsUpdate(menu)
        item.menu = menu
        statusItem = item
    }

    func openStatusMenu() {
        statusItem?.button?.performClick(nil)
    }

    // MARK: Menu actions

    @objc func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotkeyAction(rawValue: raw) else { return }
        // Let the menu close and focus return to the previous app before reading its selection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            switch action {
            case .translateSelection: Actions.translateSelection()
            case .captureScreen: Actions.captureScreen()
            case .pasteBox: Actions.openPasteBox()
            }
        }
    }

    @objc func showLastResult() { PanelController.shared.showLast() }
    @objc func showSettings() { WindowManager.shared.show(.settings) }
    @objc func showHistory() { WindowManager.shared.show(.history) }
    @objc func showPermissions() { WindowManager.shared.show(.settings, tab: .permissions) }
    @objc func showAbout() { WindowManager.shared.show(.settings, tab: .about) }
    @objc func checkForUpdates() { NSWorkspace.shared.open(AppInfo.releasesURL) }

    @objc func selectDefaultMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = Mode(rawValue: raw) {
            AppSettings.shared.defaultMode = mode
        }
    }

    @objc func toggleFloatingButton() {
        AppSettings.shared.floatingButtonEnabled.toggle()
        if !AppSettings.shared.floatingButtonEnabled { FloatingButton.shared.hide(reason: .interaction) }
    }

    @objc func toggleCapturePrivacy() {
        AppSettings.shared.hidePanelFromCapture.toggle()
        PanelController.shared.refreshCapturePrivacy()
    }
}

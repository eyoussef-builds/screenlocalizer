import AppKit

/// Standard app menu + Edit menu. Even as a menu bar app this is what makes ⌘C/⌘V/⌘A work in text fields.
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("About ScreenLocalizer"), action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Settings…"), action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: L("History…"), action: #selector(AppDelegate.showHistory), keyEquivalent: "y")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Hide ScreenLocalizer"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit ScreenLocalizer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: L("Window"))
        window.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }
}

/// The menu shown from the menu bar icon; rebuilt every time it opens so it reflects current settings.
final class StatusMenuBuilder: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if DebugHooks.enabled { NSLog("ScreenLocalizer: status menu opened with \(menu.items.count) items") }
    }

    func menuDidClose(_ menu: NSMenu) {
        if DebugHooks.enabled { NSLog("ScreenLocalizer: status menu closed") }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = AppSettings.shared

        for action in HotkeyAction.allCases {
            let title: String
            switch action {
            case .translateSelection: title = L("Translate Selection")
            case .captureScreen: title = L("Capture Text from Screen…")
            case .pasteBox: title = L("Paste Box")
            }
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.menuAction(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            if let combo = settings.hotkeys[action], !combo.menuKeyEquivalent.isEmpty {
                item.keyEquivalent = combo.menuKeyEquivalent
                item.keyEquivalentModifierMask = combo.cocoaModifiers
            }
            menu.addItem(item)
        }
        let last = NSMenuItem(title: L("Show Last Result"), action: #selector(AppDelegate.showLastResult), keyEquivalent: "")
        last.isEnabled = PanelController.shared.session != nil
        menu.addItem(last)

        menu.addItem(.separator())
        let modeItem = NSMenuItem(title: L("Default Mode"), action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in Mode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(AppDelegate.selectDefaultMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = settings.defaultMode == mode ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let floating = NSMenuItem(title: L("Floating Button on Selection"), action: #selector(AppDelegate.toggleFloatingButton), keyEquivalent: "")
        floating.state = settings.floatingButtonEnabled ? .on : .off
        menu.addItem(floating)
        let privacy = NSMenuItem(title: L("Hide Panel from Screen Recordings"), action: #selector(AppDelegate.toggleCapturePrivacy), keyEquivalent: "")
        privacy.state = settings.hidePanelFromCapture ? .on : .off
        menu.addItem(privacy)

        if !AX.isTrusted || !ScreenOCR.hasPermission {
            menu.addItem(.separator())
            menu.addItem(withTitle: L("⚠️ Grant Permissions…"), action: #selector(AppDelegate.showPermissions), keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: L("History…"), action: #selector(AppDelegate.showHistory), keyEquivalent: "")
        menu.addItem(withTitle: L("Settings…"), action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: L("Check for Updates…"), action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit ScreenLocalizer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = NSApp.delegate
        }
        for item in modeMenu.items { item.target = NSApp.delegate }
    }
}

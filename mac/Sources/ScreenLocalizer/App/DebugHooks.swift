import AppKit
import ServiceManagement

/// Test automation hooks. Active only when launched with SCREENLOCALIZER_DEBUG=1 in the environment,
/// so a normal launch from Finder or at login never listens for these commands.
@MainActor
enum DebugHooks {
    static let notification = Notification.Name(AppInfo.bundleID + ".debug")
    private static var observer: NSObjectProtocol?

    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["SCREENLOCALIZER_DEBUG"] == "1" }

    static func run() {
        guard enabled, observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { handle(command) }
        }
        NSLog("ScreenLocalizer debug hooks enabled")
    }

    private static func handle(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        switch name {
        case "present":
            let center = NSScreen.main.map { NSRect(x: $0.frame.midX - 200, y: $0.frame.midY + 150, width: 1, height: 1) }
            Actions.present(text: arg, origin: .paste, anchor: center, appName: nil, windowTitle: nil)
        case "translateSelection": Actions.translateSelection()
        case "captureScreen": Actions.captureScreen()
        case "pasteBox": Actions.openPasteBox()
        case "mode": if let mode = Mode(rawValue: arg) { PanelController.shared.session?.run(mode) }
        case "ask": PanelController.shared.session?.ask(arg)
        case "close": PanelController.shared.close()
        case "settings": WindowManager.shared.show(.settings, tab: SettingsTab(rawValue: arg) ?? .general)
        case "history": WindowManager.shared.show(.history)
        case "onboarding": WindowManager.shared.show(.onboarding)
        case "closeWindows":
            for window in NSApp.windows where window.isVisible && !(window is FloatingPanel) { window.close() }
        case "speak": Speaker.shared.speak(arg)
        case "set": applySetting(arg)
        case "statusMenu": (NSApp.delegate as? AppDelegate)?.openStatusMenu()
        case "keyset": AppSettings.shared.setAPIKey(arg)
        case "keydel": Keychain.delete(AppSettings.shared.providerID)
        case "keyreload": Keychain.clearCache()
        case "loginItem":
            if arg == "on" || arg == "off" { LoginItem.set(arg == "on") }
            let status: String
            switch SMAppService.mainApp.status {
            case .enabled: status = "enabled"
            case .notRegistered: status = "notRegistered"
            case .requiresApproval: status = "requiresApproval"
            case .notFound: status = "notFound"
            @unknown default: status = "unknown"
            }
            try? status.write(toFile: "/tmp/screenlocalizer-loginitem.txt", atomically: true, encoding: .utf8)
        case "copytest":
            Task { @MainActor in
                let text = await SelectionReader.copySelection() ?? "<nil>"
                try? text.write(toFile: "/tmp/screenlocalizer-copytest.txt", atomically: true, encoding: .utf8)
            }
        case "floating":
            // "floating:text" at the mouse, or "floating:x,y|text" at an AppKit screen point.
            var point = NSEvent.mouseLocation
            var text = arg
            if let bar = arg.firstIndex(of: "|") {
                let coords = arg[..<bar].split(separator: ",").compactMap { Double($0) }
                if coords.count == 2 { point = NSPoint(x: coords[0], y: coords[1]) }
                text = String(arg[arg.index(after: bar)...])
            }
            FloatingButton.shared.show(at: point, text: text, appName: "Debug", windowTitle: nil)
        case "dump": dump(to: arg)
        default: NSLog("ScreenLocalizer debug: unknown command \(command)")
        }
    }

    private static func applySetting(_ assignment: String) {
        let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let s = AppSettings.shared
        let value = parts[1]
        switch parts[0] {
        case "model": s.model = value
        case "baseURL": s.baseURL = value
        case "targetLanguage": s.targetLanguage = value
        case "clipboardAction": s.clipboardAction = ClipboardAction(rawValue: value) ?? .off
        case "ttsEngine": s.ttsEngine = TTSEngine(rawValue: value) ?? .system
        case "defaultMode": s.defaultMode = Mode(rawValue: value) ?? .translate
        case "hidePanelFromCapture": s.hidePanelFromCapture = value == "1"; PanelController.shared.refreshCapturePrivacy()
        case "floatingButtonEnabled": s.floatingButtonEnabled = value == "1"
        case "sideBySide": s.sideBySide = value == "1"
        case "provider": s.selectProvider(value)
        case "panelFontSize": s.panelFontSize = Double(value) ?? 16
        case "glossary":
            s.glossary = value.split(separator: ";").compactMap { pair in
                let kv = pair.split(separator: ">", maxSplits: 1).map(String.init)
                return kv.count == 2 ? GlossaryEntry(term: kv[0], rendering: kv[1]) : nil
            }
        case "openAIKeyForTTS":
            // Test-only: route OpenAI speech to the current base URL without touching the Keychain.
            ttsOverride = LLMConfig(baseURL: s.baseURL, apiKey: value, model: s.model, requiresKey: false)
        default: NSLog("ScreenLocalizer debug: unknown setting \(parts[0])")
        }
    }

    /// When set (debug only), read-aloud uses this config instead of the Keychain-backed OpenAI one.
    nonisolated(unsafe) static var ttsOverride: LLMConfig?

    private static func dump(to path: String) {
        var info: [String: Any] = [:]
        if let session = PanelController.shared.session {
            info["mode"] = session.mode.rawValue
            info["source"] = session.source
            info["streaming"] = session.isStreaming
            info["error"] = session.error ?? ""
            var outputs: [String: String] = [:]
            for (mode, text) in session.outputs { outputs[mode.rawValue] = text }
            info["outputs"] = outputs
            info["turns"] = session.turns.map { ["q": $0.question, "a": $0.answer] }
        }
        info["panelVisible"] = PanelController.shared.isVisible
        info["activationPolicy"] = NSApp.activationPolicy() == .regular ? "regular" : "accessory"
        info["windows"] = NSApp.windows.filter(\.isVisible).map { window -> [String: Any] in
            ["title": window.title, "class": String(describing: type(of: window)), "frame": NSStringFromRect(window.frame),
             "number": window.windowNumber, "sharingType": window.sharingType.rawValue, "isKey": window.isKeyWindow]
        }
        info["historyCount"] = HistoryStore.shared.entries.count
        info["axTrusted"] = AX.isTrusted
        info["screenCapture"] = ScreenOCR.hasPermission
        info["hotkeyFailures"] = HotkeyManager.shared.failed.map(\.rawValue)
        info["speaking"] = Speaker.shared.isSpeaking || Speaker.shared.isLoading
        info["speechError"] = Speaker.shared.lastError ?? ""
        info["layoutDirection"] = NSApp.userInterfaceLayoutDirection == .rightToLeft ? "rtl" : "ltr"
        info["appIsActive"] = NSApp.isActive
        info["apiKeyLength"] = AppSettings.shared.apiKey?.count ?? 0
        info["hotkeys"] = Dictionary(uniqueKeysWithValues: AppSettings.shared.hotkeys.map { ($0.key.rawValue, $0.value.display) })
        if let focused = AX.value(AX.systemWide, kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            AXUIElementGetPid(focused as! AXUIElement, &pid)
            info["keyboardFocusApp"] = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        }
        info["preferredLocalization"] = Bundle.main.preferredLocalizations.first ?? ""
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path.isEmpty ? "/tmp/screenlocalizer-dump.json" : path))
        }
    }
}

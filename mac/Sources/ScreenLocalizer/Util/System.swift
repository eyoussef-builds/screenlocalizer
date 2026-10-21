import AppKit
import ServiceManagement

enum Permissions {
    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// After an update macOS can keep an old, switched-on row that no longer matches the app, so
    /// clear ScreenLocalizer's own Accessibility entry before asking again.
    static func requestAccessibility() {
        if !AX.isTrusted { resetOwnEntry(service: "Accessibility") }
        AX.requestTrust()
        openAccessibilitySettings()
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openScreenRecordingSettings() }
    }

    /// Clears both of ScreenLocalizer's own privacy entries and asks for them again.
    /// Screen Recording isn't reset by the normal Grant button: a fresh approval only shows
    /// up after a relaunch, and resetting it then would throw that approval away.
    static func resetAndRequest() {
        resetOwnEntry(service: "Accessibility")
        resetOwnEntry(service: "ScreenCapture")
        AX.requestTrust()
        CGRequestScreenCaptureAccess()
        openAccessibilitySettings()
    }

    private static func resetOwnEntry(service: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, AppInfo.bundleID]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("ScreenLocalizer: login item change failed: \(error.localizedDescription)")
            return false
        }
    }
}

enum AppRelauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

enum AppInfo {
    static let bundleID = "me.eyoussef.screenlocalizer"
    static let websiteURL = URL(string: "https://eyoussef.me")!
    static let repoURL = URL(string: "https://github.com/eyoussef-builds/screenlocalizer")!
    static let releasesURL = URL(string: "https://github.com/eyoussef-builds/screenlocalizer/releases/latest")!
    static let privacyURL = URL(string: "https://github.com/eyoussef-builds/screenlocalizer/blob/main/PRIVACY.md")!

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
}

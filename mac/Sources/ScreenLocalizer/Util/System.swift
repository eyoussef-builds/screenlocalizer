import AppKit
import ServiceManagement

enum Permissions {
    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func requestAccessibility() {
        AX.requestTrust()
        openAccessibilitySettings()
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openScreenRecordingSettings() }
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

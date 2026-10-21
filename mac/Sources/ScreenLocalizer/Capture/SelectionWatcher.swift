import AppKit

/// Watches mouse selections in every app and shows the floating «Translate / Explain» button (PopClip-style).
@MainActor
final class SelectionWatcher {
    static let shared = SelectionWatcher()

    private var monitors: [Any] = []
    private var downPoint: NSPoint = .zero
    private var dragged = false
    private var checkWork: DispatchWorkItem?
    private var enabledPIDs: Set<pid_t> = []

    func start() {
        guard monitors.isEmpty else { return }
        let mouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            DispatchQueue.main.async { self?.handleMouse(event) }
        }
        let other = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel, .rightMouseDown]) { _ in
            DispatchQueue.main.async { FloatingButton.shared.hide(reason: .interaction) }
        }
        monitors = [mouse, other].compactMap { $0 }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.prepare(app) }
        }
        if let front = NSWorkspace.shared.frontmostApplication { prepare(front) }
    }

    private func prepare(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != getpid(), !enabledPIDs.contains(pid), AX.isTrusted else { return }
        enabledPIDs.insert(pid)
        DispatchQueue.global(qos: .utility).async { AX.enableManualAccessibility(pid: pid) }
    }

    private func handleMouse(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            downPoint = location
            dragged = false
            checkWork?.cancel()
            if !FloatingButton.shared.contains(location) { FloatingButton.shared.hide(reason: .interaction) }
        case .leftMouseDragged:
            if hypot(location.x - downPoint.x, location.y - downPoint.y) > 6 { dragged = true }
        case .leftMouseUp:
            let multiClick = event.clickCount >= 2
            let shiftClick = event.modifierFlags.contains(.shift)
            guard dragged || multiClick || shiftClick else { return }
            // Selecting text inside ScreenLocalizer's own panel shouldn't offer to translate it again.
            if NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(downPoint) }) { return }
            scheduleCheck(at: location)
        default:
            break
        }
    }

    private func scheduleCheck(at point: NSPoint) {
        let settings = AppSettings.shared
        guard settings.floatingButtonEnabled, AX.isTrusted else { return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return }
        let appName = front.localizedName
        let pid = front.processIdentifier
        let downAt = downPoint
        // Finder drags select files, not text; only offer the button there when real text is selected.
        let allowBlindButton = front.bundleIdentifier != "com.apple.finder"

        checkWork?.cancel()
        let work = DispatchWorkItem {
            Task.detached(priority: .userInitiated) {
                var found: String?
                var textLike = false
                if let focused = AX.focusedElement() {
                    if AX.role(focused) == "AXSecureTextField" { return }
                    found = AX.selectedText(focused)?.trimmed
                }
                if allowBlindButton, found?.isEmpty ?? true, let hit = AX.element(at: downAt), let role = AX.role(hit) {
                    textLike = ["AXStaticText", "AXTextArea", "AXWebArea", "AXHeading", "AXLink"].contains(role)
                }
                let text = found
                let textLikeTarget = textLike
                let title = AX.windowTitle(pid: pid)
                await MainActor.run {
                    if let text, !text.isEmpty {
                        guard text.count <= 20_000 else { return }
                        FloatingButton.shared.show(at: point, text: text, appName: appName, windowTitle: title)
                    } else if textLikeTarget {
                        // The app doesn't expose its selection; offer the button and copy the text when clicked.
                        FloatingButton.shared.show(at: point, text: nil, appName: appName, windowTitle: title)
                    }
                }
            }
        }
        checkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

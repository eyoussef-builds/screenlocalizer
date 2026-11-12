import AppKit
import ApplicationServices

struct CapturedText {
    var text: String
    /// Selection bounds in AppKit screen coordinates, when the app reports them.
    var anchor: NSRect?
    var appName: String?
    var windowTitle: String?
}

/// Thin wrapper over the Accessibility API.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }()

    private static let pidLock = NSLock()
    private static var manualAXEnabledPIDs: Set<pid_t> = []

    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func elementValue(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let val = value(element, attribute), CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(val, to: AXUIElement.self)
    }

    static func focusedElement() -> AXUIElement? {
        elementValue(systemWide, kAXFocusedUIElementAttribute)
    }

    static func role(_ element: AXUIElement) -> String? {
        value(element, kAXRoleAttribute) as? String
    }

    static func selectedText(_ element: AXUIElement) -> String? {
        value(element, kAXSelectedTextAttribute) as? String
    }

    static func element(at point: NSPoint) -> AXUIElement? {
        var element: AXUIElement?
        let flipped = toAX(point)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(flipped.x), Float(flipped.y), &element) == .success else { return nil }
        return element
    }

    /// Screen bounds of the current selection, converted to AppKit coordinates.
    static func selectionBounds(_ element: AXUIElement) -> NSRect? {
        guard let rangeValue = value(element, kAXSelectedTextRangeAttribute) else { return nil }
        var bounds: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(bounds, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return fromAX(rect)
    }

    static func windowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        guard let window = elementValue(app, kAXFocusedWindowAttribute) else { return nil }
        return value(window, kAXTitleAttribute) as? String
    }

    /// Chromium and Electron apps (Edge, Chrome, Slack, VS Code…) only build their accessibility tree when asked.
    /// Tracks enabled PIDs so repeated shortcuts never pay synchronous IPC overhead twice for the same process.
    static func enableManualAccessibility(pid: pid_t) {
        guard pid != getpid() else { return }
        pidLock.lock()
        let inserted = manualAXEnabledPIDs.insert(pid).inserted
        pidLock.unlock()
        guard inserted else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func forgetProcess(pid: pid_t) {
        pidLock.lock()
        _ = manualAXEnabledPIDs.remove(pid)
        pidLock.unlock()
    }

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func fromAX(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toAX(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

enum SelectionReader {
    /// Reads the selected text of the frontmost app: Accessibility first, then a simulated ⌘C as fallback.
    @MainActor
    static func read(allowCopyFallback: Bool) async -> CapturedText? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let appName = frontmost?.localizedName
        let pid = frontmost?.processIdentifier

        let fromAX: (String?, NSRect?, String?) = await Task.detached(priority: .userInitiated) {
            if let pid { AX.enableManualAccessibility(pid: pid) }
            var text: String?
            var rect: NSRect?
            if let element = AX.focusedElement() {
                text = AX.selectedText(element)?.trimmed
                if let t = text, !t.isEmpty { rect = AX.selectionBounds(element) }
            }
            let title = pid.flatMap { AX.windowTitle(pid: $0) }
            return (text, rect, title)
        }.value

        if let text = fromAX.0, !text.isEmpty {
            return CapturedText(text: text, anchor: fromAX.1, appName: appName, windowTitle: fromAX.2)
        }
        guard allowCopyFallback, let copied = await copySelection(), !copied.trimmed.isEmpty else { return nil }
        return CapturedText(text: copied.trimmed, anchor: nil, appName: appName, windowTitle: fromAX.2)
    }

    /// Sends ⌘C to the frontmost app using an isolated event source, reads the clipboard at 5ms resolution,
    /// and restores the previous pasteboard asynchronously so the UI never waits on restoration.
    @MainActor
    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let before = pasteboard.changeCount
        ClipboardWatcher.shared.suppressTemporarily(for: 0.35)
        postCommandC()

        var copied: String?
        for _ in 0..<36 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                if copied == nil {
                    try? await Task.sleep(nanoseconds: 8_000_000)
                    copied = pasteboard.string(forType: .string)
                }
                break
            }
        }
        if pasteboard.changeCount != before {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                restorePasteboard(pasteboard, saved)
                ClipboardWatcher.shared.markOwnChange()
            }
        }
        ClipboardWatcher.shared.markOwnChange()
        return copied
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .privateState)
        let keyC = CGKeyCode(8)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func savePasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        let maxItemBytes = 10_000_000
        return (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type), data.count <= maxItemBytes { dict[type] = data }
            }
            return dict
        }
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

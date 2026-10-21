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
        AXUIElementSetMessagingTimeout(element, 0.4)
        return element
    }()

    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func focusedElement() -> AXUIElement? {
        guard let value = value(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        return (value as! AXUIElement)
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
                                                         rangeValue, &bounds) == .success, let bounds else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return fromAX(rect)
    }

    static func windowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let window = value(app, kAXFocusedWindowAttribute) else { return nil }
        return value(window as! AXUIElement, kAXTitleAttribute) as? String
    }

    /// Chromium and Electron apps (Edge, Chrome, Slack, VS Code…) only build their accessibility tree when asked.
    static func enableManualAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
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
        if let pid { AX.enableManualAccessibility(pid: pid) }

        let fromAX: (String?, NSRect?, String?) = await Task.detached(priority: .userInitiated) {
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

    /// Sends ⌘C to the frontmost app, reads the clipboard, then restores what was there before.
    @MainActor
    static func copySelection() async -> String? {
        // Wait (briefly) for the user to release the shortcut's modifier keys so they don't mix into ⌘C.
        for _ in 0..<40 {
            let held = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
            if held.isEmpty { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let before = pasteboard.changeCount
        postCommandC()

        var copied: String?
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pasteboard.changeCount != before {
                try? await Task.sleep(nanoseconds: 30_000_000)
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before {
            restorePasteboard(pasteboard, saved)
        }
        ClipboardWatcher.shared.markOwnChange()
        return copied
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC = CGKeyCode(8)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func savePasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { dict[type] = data } }
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

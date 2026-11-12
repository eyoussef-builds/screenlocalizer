import AppKit
import Combine

/// Optional "when I copy text" behaviour: show the floating button or translate right away.
/// Only schedules a pasteboard timer while enabled so idle battery impact is zero when set to Off.
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var suppressedUntil: Date = .distantPast

    func start() {
        guard cancellable == nil else { return }
        cancellable = AppSettings.shared.$clipboardAction
            .removeDuplicates()
            .sink { [weak self] action in
                MainActor.assumeIsolated { self?.updateTimer(for: action) }
            }
        updateTimer(for: AppSettings.shared.clipboardAction)
    }

    private func updateTimer(for action: ClipboardAction) {
        if action == .off {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardWatcher.shared.poll() }
        }
        t.tolerance = 0.08
        timer = t
    }

    /// Call after ScreenLocalizer itself writes to the clipboard so it isn't treated as a user copy.
    func markOwnChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func suppressTemporarily(for seconds: TimeInterval) {
        suppressedUntil = Date().addingTimeInterval(seconds)
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard Date() >= suppressedUntil else { return }

        let action = AppSettings.shared.clipboardAction
        guard action != .off else { return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return }
        // Ignore passwords and other concealed or transient items (password managers mark them).
        let types = pasteboard.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ||
            types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return }
        guard let text = pasteboard.string(forType: .string)?.trimmed, text.count >= 2, text.count <= 20_000 else { return }

        let point = NSEvent.mouseLocation
        let title = AX.isTrusted ? AX.windowTitle(pid: front.processIdentifier) : nil
        switch action {
        case .button:
            FloatingButton.shared.show(at: point, text: text, appName: front.localizedName, windowTitle: title, origin: .clipboard)
        case .translate:
            Actions.present(text: text, origin: .clipboard, anchor: NSRect(origin: point, size: .zero),
                            appName: front.localizedName, windowTitle: title)
        case .off:
            break
        }
    }
}

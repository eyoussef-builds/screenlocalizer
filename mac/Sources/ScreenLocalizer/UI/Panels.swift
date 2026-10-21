import AppKit
import SwiftUI

/// Hosting view that reacts to the first click even when its window isn't key (needed for non-activating panels).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Floating, non-activating panel: it stays above other apps without stealing focus from them.
final class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(size: NSSize, titled: Bool) {
        let style: NSWindow.StyleMask = titled
            ? [.nonactivatingPanel, .titled, .resizable, .closable, .fullSizeContentView]
            : [.nonactivatingPanel, .borderless]
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        if titled {
            titleVisibility = .hidden
            titlebarAppearsTransparent = true
            standardWindowButton(.closeButton)?.isHidden = true
            standardWindowButton(.miniaturizeButton)?.isHidden = true
            standardWindowButton(.zoomButton)?.isHidden = true
            isMovableByWindowBackground = false
        } else {
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
        }
    }

    override var canBecomeKey: Bool { true }

    /// The panel only becomes key when a text field is clicked (becomesKeyOnlyIfNeeded). Activating the app
    /// then guarantees keystrokes reach the panel instead of the app the user was reading.
    override func becomeKey() {
        super.becomeKey()
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { orderOut(nil) }
    }

    func applyCapturePrivacy(hidden: Bool) {
        sharingType = hidden ? .none : .readOnly
    }
}

// MARK: - Result panel controller

final class PanelState: ObservableObject {
    @Published var session: Session?
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var panel: FloatingPanel?
    let state = PanelState()
    var session: Session? { state.session }
    var isVisible: Bool { panel?.isVisible ?? false }
    /// Window number of the panel, used to keep it out of screen captures made by ScreenLocalizer itself.
    var windowNumber: Int? { panel?.windowNumber }

    private let sizeKey = "panelSize"

    private func ensurePanel() -> FloatingPanel {
        if let panel { return panel }
        let saved = NSSizeFromString(UserDefaults.standard.string(forKey: sizeKey) ?? "")
        let size = saved.width >= 340 && saved.height >= 260 ? saved : NSSize(width: 480, height: 460)
        let panel = FloatingPanel(size: size, titled: true)
        panel.minSize = NSSize(width: 340, height: 260)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        let root = PanelRootView(state: state)
        panel.contentView = FirstMouseHostingView(rootView: root)
        self.panel = panel
        return panel
    }

    func present(_ session: Session, anchor: NSRect?, autoRun: Bool = true) {
        if let old = state.session, old.id != session.id { old.cancel() }
        Speaker.shared.stop()
        let wasVisible = isVisible
        state.session = session
        let panel = ensurePanel()
        panel.applyCapturePrivacy(hidden: AppSettings.shared.hidePanelFromCapture)
        if !wasVisible { position(panel, near: anchor) }
        panel.orderFrontRegardless()
        if session.editingSource { panel.makeKey() }
        if autoRun && session.hasSource && session.outputs[session.mode] == nil { session.run(session.mode) }
    }

    func showLast() {
        guard let panel, state.session != nil else { return }
        panel.orderFrontRegardless()
    }

    func close() {
        session?.cancel()
        Speaker.shared.stop()
        panel?.orderOut(nil)
    }

    func refreshCapturePrivacy() {
        panel?.applyCapturePrivacy(hidden: AppSettings.shared.hidePanelFromCapture)
        FloatingButton.shared.refreshCapturePrivacy()
    }

    func focus() {
        panel?.makeKey()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let size = panel?.frame.size { UserDefaults.standard.set(NSStringFromSize(size), forKey: sizeKey) }
    }

    /// Places the panel next to the selection: below, above, right, then left — whichever fits on screen.
    private func position(_ panel: NSPanel, near anchor: NSRect?) {
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let target = anchor.flatMap { $0.width > 0 || $0.height > 0 ? $0 : nil } ?? NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        let center = NSPoint(x: target.midX, y: target.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 12
        let candidates = [
            NSPoint(x: target.minX, y: target.minY - gap - size.height),
            NSPoint(x: target.minX, y: target.maxY + gap),
            NSPoint(x: target.maxX + gap, y: target.maxY - size.height),
            NSPoint(x: target.minX - gap - size.width, y: target.maxY - size.height),
        ]
        var origin = candidates.first { visible.contains(NSRect(origin: $0, size: size)) } ?? candidates[0]
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
    }
}

struct PanelRootView: View {
    @ObservedObject var state: PanelState

    var body: some View {
        if let session = state.session {
            ResultView(session: session).id(session.id)
        } else {
            Color.clear
        }
    }
}

// MARK: - Floating «Translate / Explain» button

@MainActor
final class FloatingButton {
    static let shared = FloatingButton()

    enum HideReason { case interaction, timeout, used }

    private var panel: FloatingPanel?
    private var text: String?
    private var appName: String?
    private var windowTitle: String?
    private var origin: SourceOrigin = .floating
    private var anchorPoint: NSPoint = .zero
    private var hideWork: DispatchWorkItem?

    func contains(_ point: NSPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    func show(at point: NSPoint, text: String?, appName: String?, windowTitle: String?, origin: SourceOrigin = .floating) {
        guard !RegionSelector.shared.isActive else { return }
        self.text = text
        self.appName = appName
        self.windowTitle = windowTitle
        self.origin = origin
        self.anchorPoint = point

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = FirstMouseHostingView(rootView: FloatingButtonView { [weak self] in self?.activate() })
        let size = panel.contentView?.fittingSize ?? NSSize(width: 150, height: 34)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        var origin = NSPoint(x: point.x + 8, y: point.y + 14)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.applyCapturePrivacy(hidden: AppSettings.shared.hidePanelFromCapture)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide(reason: .timeout) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func hide(reason: HideReason) {
        if DebugHooks.enabled, panel?.isVisible == true { NSLog("ScreenLocalizer: floating button hidden (\(reason))") }
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    func refreshCapturePrivacy() {
        panel?.applyCapturePrivacy(hidden: AppSettings.shared.hidePanelFromCapture)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(size: NSSize(width: 150, height: 34), titled: false)
        panel.level = .popUpMenu
        return panel
    }

    private func activate() {
        hide(reason: .used)
        let anchor = NSRect(x: anchorPoint.x, y: anchorPoint.y, width: 1, height: 1)
        if let text {
            Actions.present(text: text, origin: origin, anchor: anchor, appName: appName, windowTitle: windowTitle)
            return
        }
        let appName = self.appName
        let title = windowTitle
        Task { @MainActor in
            guard let copied = await SelectionReader.copySelection()?.trimmed, !copied.isEmpty else {
                Toast.show(L("Couldn't read the selected text in this app."))
                return
            }
            Actions.present(text: copied, origin: .floating, anchor: anchor, appName: appName, windowTitle: title)
        }
    }
}

struct FloatingButtonView: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Translate / Explain")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Brand.gradient))
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
            .scaleEffect(hovering ? 1.05 : 1)
            .shadow(color: Brand.indigo.opacity(0.45), radius: 6, y: 2)
            .padding(6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Toast

@MainActor
enum Toast {
    private static var panel: FloatingPanel?
    private static var work: DispatchWorkItem?

    static func show(_ message: String, near point: NSPoint? = nil) {
        let panel = self.panel ?? FloatingPanel(size: NSSize(width: 200, height: 40), titled: false)
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ToastView(message: message))
        let size = panel.contentView?.fittingSize ?? NSSize(width: 240, height: 44)
        let location = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var origin = NSPoint(x: location.x - size.width / 2, y: location.y + 18)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.applyCapturePrivacy(hidden: AppSettings.shared.hidePanelFromCapture)
        panel.orderFrontRegardless()
        work?.cancel()
        let w = DispatchWorkItem { panel.orderOut(nil) }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: w)
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.82)))
            .padding(6)
            .fixedSize()
    }
}

enum Brand {
    static let indigo = Color(red: 0.388, green: 0.400, blue: 0.945)
    static let violet = Color(red: 0.545, green: 0.361, blue: 0.965)
    static let gradient = LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Indigo that stays readable on dark backgrounds.
    static let accentText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.74, green: 0.74, blue: 1.0, alpha: 1)
            : NSColor(calibratedRed: 0.30, green: 0.31, blue: 0.80, alpha: 1)
    })
}

/// Lays children out left to right, wrapping onto new rows when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

import AppKit
import ScreenCaptureKit
import Vision

enum ScreenOCRError: LocalizedError {
    case permission
    case displayNotFound

    var errorDescription: String? {
        switch self {
        case .permission: return L("ScreenLocalizer needs Screen Recording permission to read text from the screen.")
        case .displayNotFound: return L("Couldn't capture that part of the screen.")
        }
    }
}

enum ScreenOCR {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures `rect` (AppKit global coordinates) from `screen`, leaving ScreenLocalizer's own windows out.
    static func capture(rect: NSRect, on screen: NSScreen) async throws -> CGImage {
        guard hasPermission else {
            CGRequestScreenCaptureAccess()
            throw ScreenOCRError.permission
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenOCRError.permission
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw ScreenOCRError.displayNotFound
        }
        let ownApps = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let frame = screen.frame
        let local = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = max(1, Int(local.width * scale))
        config.height = max(1, Int(local.height * scale))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// On-device text recognition with Apple's Vision framework; keeps line order and paragraph gaps.
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            let observations = (request.results ?? []).filter { $0.topCandidates(1).first != nil }
            let sorted = observations.sorted {
                abs($0.boundingBox.midY - $1.boundingBox.midY) < min($0.boundingBox.height, $1.boundingBox.height) * 0.5
                    ? $0.boundingBox.minX < $1.boundingBox.minX
                    : $0.boundingBox.midY > $1.boundingBox.midY
            }
            var lines: [String] = []
            var previous: VNRecognizedTextObservation?
            for observation in sorted {
                guard let text = observation.topCandidates(1).first?.string else { continue }
                if let prev = previous {
                    let sameLine = abs(prev.boundingBox.midY - observation.boundingBox.midY) < min(prev.boundingBox.height, observation.boundingBox.height) * 0.5
                    if sameLine {
                        lines[lines.count - 1] += " " + text
                        previous = observation
                        continue
                    }
                    let gap = prev.boundingBox.minY - observation.boundingBox.maxY
                    if gap > prev.boundingBox.height * 0.9 { lines.append("") }
                }
                lines.append(text)
                previous = observation
            }
            return lines.joined(separator: "\n").trimmed
        }.value
    }
}

// MARK: - Region selection overlay

/// Full-screen dimmed overlay where the user drags a box around the text to read. Esc cancels.
@MainActor
final class RegionSelector {
    static let shared = RegionSelector()

    private var windows: [OverlayWindow] = []
    private var completion: ((NSRect?, NSScreen?) -> Void)?
    private var previousApp: NSRunningApplication?

    var isActive: Bool { !windows.isEmpty }

    func begin(completion: @escaping (NSRect?, NSScreen?) -> Void) {
        guard !isActive else { return }
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen) { [weak self] rect in self?.finish(rect, screen: screen) }
            windows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let target = windows.first { $0.frame.contains(mouse) } ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
    }

    private func finish(_ rect: NSRect?, screen: NSScreen) {
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if previousApp?.processIdentifier != getpid() { previousApp?.activate() }
        let done = completion
        completion = nil
        done?(rect, rect == nil ? nil : screen)
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen, onFinish: @escaping (NSRect?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)
        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] localRect in
            guard let self, let localRect else { onFinish(nil); return }
            onFinish(self.convertToScreen(localRect))
        }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

final class OverlayView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?
    private var finished = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if let rect = selection {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            NSColor(calibratedRed: 0.42, green: 0.40, blue: 0.95, alpha: 1).setStroke()
            border.stroke()
            let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
            label.draw(at: NSPoint(x: rect.minX + 4, y: rect.minY - 20),
                       withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                        .foregroundColor: NSColor.white])
        } else {
            let hint = L("Drag a box around the text to read · Esc to cancel") as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                                                        .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attrs)
            let pill = NSRect(x: bounds.midX - size.width / 2 - 18, y: bounds.maxY - 120, width: size.width + 36, height: size.height + 18)
            NSColor(calibratedRed: 0.39, green: 0.40, blue: 0.95, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            hint.draw(at: NSPoint(x: pill.minX + 18, y: pill.minY + 9), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let rect = selection, rect.width > 8, rect.height > 8 else {
            start = nil
            current = nil
            needsDisplay = true
            return
        }
        finish(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { finish(nil) }

    private func finish(_ rect: NSRect?) {
        guard !finished else { return }
        finished = true
        onFinish?(rect)
    }
}

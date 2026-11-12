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

    private actor ContentCache {
        private var cached: SCShareableContent?
        private var cachedAt: Date = .distantPast
        private var observerInstalled = false

        func invalidate() {
            cached = nil
        }

        func shareableContent(forceRefresh: Bool = false) async throws -> SCShareableContent {
            if !observerInstalled {
                observerInstalled = true
                NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { _ in
                    Task { await ScreenOCR.cache.invalidate() }
                }
            }
            if !forceRefresh, let cached, Date().timeIntervalSince(cachedAt) < 120 {
                return cached
            }
            let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cached = fresh
            cachedAt = Date()
            return fresh
        }
    }

    private static let cache = ContentCache()

    static func prewarm() {
        guard hasPermission else { return }
        Task { _ = try? await cache.shareableContent() }
    }

    /// Captures `rect` (AppKit global coordinates) from `screen`, leaving ScreenLocalizer's own windows out.
    static func capture(rect: NSRect, on screen: NSScreen) async throws -> CGImage {
        guard hasPermission else {
            CGRequestScreenCaptureAccess()
            throw ScreenOCRError.permission
        }
        return try await captureAttempt(rect: rect, on: screen, forceRefresh: false)
    }

    private static func captureAttempt(rect: NSRect, on screen: NSScreen, forceRefresh: Bool) async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await cache.shareableContent(forceRefresh: forceRefresh)
        } catch {
            throw ScreenOCRError.permission
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            if !forceRefresh { return try await captureAttempt(rect: rect, on: screen, forceRefresh: true) }
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
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            if !forceRefresh { return try await captureAttempt(rect: rect, on: screen, forceRefresh: true) }
            throw error
        }
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
            let byY = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            var rows: [[VNRecognizedTextObservation]] = []
            for obs in byY {
                if let lastRow = rows.last, let anchor = lastRow.first,
                   abs(anchor.boundingBox.midY - obs.boundingBox.midY) < min(anchor.boundingBox.height, obs.boundingBox.height) * 0.5 {
                    rows[rows.count - 1].append(obs)
                } else {
                    rows.append([obs])
                }
            }
            var lines: [String] = []
            var previousRow: [VNRecognizedTextObservation]?
            for row in rows {
                let rawStrings = row.compactMap { $0.topCandidates(1).first?.string }
                guard !rawStrings.isEmpty else { continue }
                let rtlRow = rawStrings.joined().unicodeScalars.contains { scalar in
                    (0x0590...0x08FF).contains(scalar.value) ||
                    (0xFB50...0xFDFF).contains(scalar.value) ||
                    (0xFE70...0xFEFF).contains(scalar.value)
                }
                let ordered = row.sorted {
                    rtlRow ? $0.boundingBox.maxX > $1.boundingBox.maxX : $0.boundingBox.minX < $1.boundingBox.minX
                }
                if let prev = previousRow {
                    let prevMinY = prev.map(\.boundingBox.minY).min() ?? 0
                    let prevHeight = prev.map(\.boundingBox.height).max() ?? 0
                    let currMaxY = ordered.map(\.boundingBox.maxY).max() ?? 0
                    if prevMinY - currMaxY > prevHeight * 0.9 { lines.append("") }
                }
                lines.append(ordered.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
                previousRow = ordered
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

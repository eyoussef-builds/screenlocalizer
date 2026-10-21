import AppKit

/// What each trigger does once it fires.
@MainActor
enum Actions {
    static func translateSelection() {
        guard AX.isTrusted else {
            Toast.show(L("Allow Accessibility so ScreenLocalizer can read selected text."))
            WindowManager.shared.show(.settings, tab: .permissions)
            return
        }
        let mouse = NSEvent.mouseLocation
        Task { @MainActor in
            guard let captured = await SelectionReader.read(allowCopyFallback: true) else {
                Toast.show(L("Select some text first, then press the shortcut."), near: mouse)
                return
            }
            present(text: captured.text, origin: .selection,
                    anchor: captured.anchor ?? NSRect(origin: mouse, size: .zero),
                    appName: captured.appName, windowTitle: captured.windowTitle)
        }
    }

    static func captureScreen() {
        FloatingButton.shared.hide(reason: .interaction)
        guard ScreenOCR.hasPermission else {
            CGRequestScreenCaptureAccess()
            Toast.show(L("Allow Screen Recording so ScreenLocalizer can read text from the screen."))
            WindowManager.shared.show(.settings, tab: .permissions)
            return
        }
        let sourceApp = NSWorkspace.shared.frontmostApplication
        let appName = sourceApp?.processIdentifier == getpid() ? nil : sourceApp?.localizedName
        RegionSelector.shared.begin { rect, screen in
            guard let rect, let screen else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                do {
                    let image = try await ScreenOCR.capture(rect: rect, on: screen)
                    let text = try await ScreenOCR.recognize(image)
                    guard !text.isEmpty else {
                        Toast.show(L("No text found in that area."), near: NSPoint(x: rect.midX, y: rect.midY))
                        return
                    }
                    present(text: text, origin: .ocr, anchor: rect, appName: appName, windowTitle: nil)
                } catch {
                    Toast.show(error.localizedDescription)
                    if error is ScreenOCRError { WindowManager.shared.show(.settings, tab: .permissions) }
                }
            }
        }
    }

    static func openPasteBox() {
        FloatingButton.shared.hide(reason: .interaction)
        let session = Session(source: "", origin: .paste, editingSource: true)
        PanelController.shared.present(session, anchor: nil, autoRun: false)
        NSApp.activate(ignoringOtherApps: true)
        PanelController.shared.focus()
    }

    static func present(text: String, origin: SourceOrigin, anchor: NSRect?, appName: String?, windowTitle: String?) {
        let session = Session(source: text, origin: origin, context: SourceContext(appName: appName, windowTitle: windowTitle))
        PanelController.shared.present(session, anchor: anchor)
    }
}

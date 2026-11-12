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
        ScreenOCR.prewarm()
        LLMClient.prewarmActiveProvider()
        RegionSelector.shared.begin { rect, screen in
            guard let rect, let screen else { return }
            // Paint the prewarmed panel immediately (<16ms) while Vision OCR runs in the background.
            let pending = Session(source: "", origin: .ocr, context: SourceContext(appName: appName, windowTitle: nil), isPreparing: true)
            PanelController.shared.present(pending, anchor: rect, autoRun: false)
            Task { @MainActor in
                do {
                    let image = try await ScreenOCR.capture(rect: rect, on: screen)
                    let text = try await ScreenOCR.recognize(image)
                    guard PanelController.shared.session?.id == pending.id else { return }
                    guard !text.isEmpty else {
                        PanelController.shared.close()
                        Toast.show(L("No text found in that area."), near: NSPoint(x: rect.midX, y: rect.midY))
                        return
                    }
                    pending.finishPreparingAndRun(source: text)
                } catch {
                    if PanelController.shared.session?.id == pending.id {
                        PanelController.shared.close()
                    }
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

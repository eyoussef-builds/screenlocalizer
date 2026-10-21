import SwiftUI
import AppKit

struct ResultView: View {
    @ObservedObject var session: Session
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var speaker = Speaker.shared
    @State private var question = ""
    @State private var copied = false
    @FocusState private var questionFocused: Bool
    @FocusState private var sourceFocused: Bool

    private var rtl: Bool { Languages.isRTL(settings.targetLanguage) }
    private var fontSize: CGFloat { CGFloat(settings.panelFontSize) }
    private var showSource: Bool { session.editingSource || (settings.sideBySide && session.hasSource) }

    var body: some View {
        VStack(spacing: 0) {
            header
            modeBar
            Divider().padding(.top, 8)
            GeometryReader { geo in
                if showSource {
                    if geo.size.width >= 600 {
                        HStack(spacing: 0) {
                            sourcePane.frame(width: geo.size.width * 0.44)
                            Divider()
                            resultPane
                        }
                    } else {
                        VStack(spacing: 0) {
                            sourcePane.frame(height: min(max(geo.size.height * 0.36, 90), 220))
                            Divider()
                            resultPane
                        }
                    }
                } else {
                    resultPane
                }
            }
            Divider()
            followUpBar
            footer
        }
        .background(VisualEffectBackground())
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { if session.editingSource { sourceFocused = true } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.gradient)
            Text("ScreenLocalizer").font(.system(size: 13, weight: .semibold))
            if session.isStreaming { ProgressView().controlSize(.mini).padding(.leading, 2) }
            Spacer(minLength: 8)
            privacyToggle
            iconButton(settings.sideBySide ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                       help: L("Show the original text side by side"), active: settings.sideBySide) {
                settings.sideBySide.toggle()
            }
            iconButton("minus.magnifyingglass", help: L("Smaller text")) {
                settings.panelFontSize = max(11, settings.panelFontSize - 1)
            }
            iconButton("plus.magnifyingglass", help: L("Larger text")) {
                settings.panelFontSize = min(40, settings.panelFontSize + 1)
            }
            iconButton("gearshape", help: L("Settings")) { WindowManager.shared.show(.settings) }
            iconButton("xmark", help: L("Close (Esc)")) { PanelController.shared.close() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .frame(height: 40)
    }

    private var privacyToggle: some View {
        let hidden = settings.hidePanelFromCapture
        return Button {
            settings.hidePanelFromCapture.toggle()
            PanelController.shared.refreshCapturePrivacy()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: hidden ? "eye.slash.fill" : "eye.fill").font(.system(size: 10, weight: .semibold))
                Text(hidden ? L("Private") : L("Visible")).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(hidden ? Color.white : Color.primary)
            .background(Capsule().fill(hidden ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.1))))
        }
        .buttonStyle(.plain)
        .help(hidden ? L("Hidden from screen recordings and screenshots. Click to show it in recordings.")
                     : L("Visible in screen recordings. Click to hide it from recordings."))
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .foregroundStyle(active ? Brand.indigo : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(active ? 0.1 : 0.0001)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Modes

    private var modeBar: some View {
        FlowLayout(spacing: 6) {
            ForEach(Mode.allCases) { mode in
                let selected = session.mode == mode
                Button {
                    session.run(mode)
                } label: {
                    HStack(spacing: 4) {
                        if session.streamingMode == mode {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: mode.symbol).font(.system(size: 10.5, weight: .semibold))
                        }
                        Text(mode.label).font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(selected ? Color.white : Brand.accentText)
                    .background(Capsule().fill(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.indigo.opacity(0.16))))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!session.hasSource)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    // MARK: Source

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(session.origin.label, systemImage: session.origin.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let app = session.context.appName, !app.isEmpty {
                    Text("· \(app)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if session.editingSource {
                    Button(L("Paste")) {
                        if let text = NSPasteboard.general.string(forType: .string) { session.source = text }
                    }
                    .controlSize(.small)
                    Button {
                        session.outputs = [:]
                        session.turns = []
                        session.run(session.mode, force: true)
                    } label: {
                        Label(L("Go"), systemImage: "arrow.right.circle.fill")
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!session.hasSource)
                }
            }
            if session.editingSource {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $session.source)
                        .font(.system(size: max(12, fontSize - 2)))
                        .scrollContentBackground(.hidden)
                        .focused($sourceFocused)
                    if session.source.isEmpty {
                        Text("Paste or type text here, then press ⌘↩")
                            .font(.system(size: max(12, fontSize - 2)))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            } else {
                ScrollView {
                    Text(session.source)
                        .font(.system(size: max(12, fontSize - 2)))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: Result

    private var resultPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = session.error {
                        errorView(error)
                    } else if !session.hasSource && session.editingSource {
                        placeholder(L("Results appear here."))
                    } else if session.currentOutput.isEmpty && session.streamingMode == session.mode {
                        TypingDots()
                    } else {
                        MarkdownView(text: session.currentOutput, fontSize: fontSize, rtl: rtl)
                    }
                    ForEach(session.turns) { turn in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(turn.question)
                                    .font(.system(size: max(12, fontSize - 1), weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Brand.indigo.opacity(0.12)))
                                    .textSelection(.enabled)
                                Spacer(minLength: 30)
                            }
                            if turn.answer.isEmpty {
                                TypingDots()
                            } else {
                                MarkdownView(text: turn.answer, fontSize: fontSize, rtl: rtl)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            }
            .onChange(of: session.tick) { _, _ in
                if !session.turns.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.turns.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(message).font(.system(size: 13)).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                if session.needsKey {
                    Button(L("Add API Key…")) { WindowManager.shared.show(.settings, tab: .ai) }
                        .buttonStyle(.borderedProminent)
                }
                Button(L("Try Again")) { session.run(session.mode, force: true) }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, NSApp.userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }

    // MARK: Follow-up & footer

    private var followUpBar: some View {
        HStack(spacing: 8) {
            TextField(L("Ask a follow-up question…"), text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($questionFocused)
                .onSubmit(sendQuestion)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .disabled(!session.hasSource)
            Button(action: sendQuestion) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(Brand.gradient)
            }
            .buttonStyle(.plain)
            .disabled(question.trimmed.isEmpty || !session.hasSource)
            .help(L("Send"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            footerButton(copied ? L("Copied") : L("Copy"), symbol: copied ? "checkmark" : "doc.on.doc") { copyResult() }
                .disabled(resultText.isEmpty)
            footerButton(L("Regenerate"), symbol: "arrow.clockwise") { session.run(session.mode, force: true) }
                .disabled(!session.hasSource || session.isStreaming)
            footerButton(speaker.isSpeaking || speaker.isLoading ? L("Stop") : L("Read Aloud"),
                         symbol: speaker.isSpeaking || speaker.isLoading ? "stop.fill" : "speaker.wave.2.fill") {
                speaker.toggle(resultText)
            }
            .disabled(resultText.isEmpty)
            Spacer()
            if let error = speaker.lastError {
                Image(systemName: "speaker.slash").foregroundStyle(.orange).help(error)
            }
            Text(settings.model).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11.5, weight: .medium))
        }
        .controlSize(.small)
    }

    private var resultText: String {
        var text = session.currentOutput
        for turn in session.turns where !turn.answer.isEmpty {
            text += "\n\n" + turn.question + "\n" + turn.answer
        }
        return text.trimmed
    }

    private func copyResult() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(resultText, forType: .string)
        ClipboardWatcher.shared.markOwnChange()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func sendQuestion() {
        let q = question.trimmed
        guard !q.isEmpty else { return }
        question = ""
        session.ask(q)
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * 5
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Brand.indigo)
                        .frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * max(0, sin(t - Double(i) * 0.9)))
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

import SwiftUI
import AppKit

/// Target-language picker with a free-text "Other…" option.
struct LanguagePicker: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var custom = ""
    private static let otherTag = "__other__"

    private var isKnown: Bool { Languages.find(settings.targetLanguage) != nil }

    var body: some View {
        Picker(L("Translate into"), selection: Binding(
            get: { isKnown ? settings.targetLanguage : Self.otherTag },
            set: { value in
                if value == Self.otherTag {
                    if isKnown { settings.targetLanguage = custom.trimmed.isEmpty ? "" : custom }
                } else {
                    settings.targetLanguage = value
                }
            }
        )) {
            ForEach(Languages.all) { lang in
                Text(lang.native == lang.id ? lang.id : "\(lang.native) — \(lang.id)").tag(lang.id)
            }
            Divider()
            Text("Other…").tag(Self.otherTag)
        }
        if !isKnown {
            TextField(L("Language name (in English, e.g. Swahili)"), text: $settings.targetLanguage)
        }
    }
}

/// Provider, base URL, API key, model and connection test — used by onboarding and Settings.
struct AISetupSection: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var keyDraft = ""
    @State private var showKey = false
    @State private var models: [String] = []
    @State private var testState: TestState = .idle

    enum TestState: Equatable { case idle, testing, ok(Int), failed(String) }

    var body: some View {
        Picker(L("Provider"), selection: Binding(get: { settings.providerID }, set: { id in
            settings.selectProvider(id)
            keyDraft = settings.apiKey ?? ""
            models = []
            testState = .idle
        })) {
            ForEach(Providers.all) { Text($0.name).tag($0.id) }
        }

        LabeledContent(L("API base URL")) {
            TextField("", text: $settings.baseURL, prompt: Text(verbatim: "https://api.openai.com/v1"))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .environment(\.layoutDirection, .leftToRight)
                .frame(minWidth: 280)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("API key")
            HStack {
                Group {
                    if showKey {
                        TextField("", text: $keyDraft, prompt: Text(verbatim: "sk-…"))
                    } else {
                        SecureField("", text: $keyDraft, prompt: Text(verbatim: "sk-…"))
                    }
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .environment(\.layoutDirection, .leftToRight)
                .onSubmit(saveKey)
                Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .help(L("Show or hide the key"))
                Button(L("Save Key"), action: saveKey)
                    .disabled(keyDraft.trimmed == (settings.apiKey ?? ""))
            }
        }
        if let url = settings.provider.keyURL.flatMap(URL.init(string:)) {
            Link(destination: url) { Text("Get an API key from \(settings.provider.name) ↗") }
                .font(.caption)
        }
        if !settings.provider.needsKey {
            Text("This provider runs locally or doesn't need a key; leave it empty if so.")
                .font(.caption).foregroundStyle(.secondary)
        }

        LabeledContent(L("Model")) {
            HStack {
                TextField("", text: $settings.model, prompt: Text(verbatim: "gpt-5-mini"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(minWidth: 180)
                if !models.isEmpty {
                    Menu(L("Choose")) {
                        ForEach(models, id: \.self) { model in
                            Button(model) { settings.model = model }
                        }
                    }
                    .fixedSize()
                }
            }
        }

        HStack(spacing: 10) {
            Button {
                Task { await test() }
            } label: {
                Label(L("Test Connection"), systemImage: "bolt.horizontal.circle")
            }
            .disabled(testState == .testing)
            switch testState {
            case .idle: EmptyView()
            case .testing: ProgressView().controlSize(.small)
            case .ok(let count):
                Label(count > 0 ? LF("Connected · %d models available", count) : L("Connected"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.callout).lineLimit(3).textSelection(.enabled)
            }
        }
        .onAppear { keyDraft = settings.apiKey ?? "" }
    }

    private func saveKey() {
        settings.setAPIKey(keyDraft)
        testState = .idle
    }

    private func test() async {
        if keyDraft.trimmed != (settings.apiKey ?? "") { saveKey() }
        testState = .testing
        do {
            let list = try await LLMClient.testConnection(config: settings.llmConfig)
            models = list
            if !list.isEmpty {
                settings.model = Providers.bestModel(from: list, provider: settings.provider, current: settings.model)
            }
            testState = .ok(list.count)
        } catch {
            testState = .failed(error.localizedDescription.components(separatedBy: "\n").first ?? "")
        }
    }
}

/// Live status of the two macOS permissions the app relies on.
struct PermissionsSection: View {
    @State private var accessibility = AX.isTrusted
    @State private var screen = ScreenOCR.hasPermission
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        permissionRow(granted: accessibility, title: L("Accessibility"),
                      detail: L("Reads the text you select in other apps (shortcut and floating button)."),
                      action: Permissions.requestAccessibility)
        permissionRow(granted: screen, title: L("Screen Recording"),
                      detail: L("Reads text from the part of the screen you box (OCR). Nothing is recorded or uploaded except the text."),
                      action: Permissions.requestScreenRecording)
        Text("After granting Screen Recording, macOS may ask you to quit and reopen ScreenLocalizer.")
            .font(.caption).foregroundStyle(.secondary)
        if !accessibility || !screen {
            Text("Already switched on in System Settings, but still not working? That can happen after an update. Click “Reset Permissions & Try Again”, or remove every ScreenLocalizer entry from the list with the − button and click Grant… again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button(L("Relaunch ScreenLocalizer")) { AppRelauncher.relaunch() }
            if !accessibility || !screen {
                Button(L("Reset Permissions & Try Again")) { Permissions.resetAndRequest() }
            }
        }
        .controlSize(.small)
        .onReceive(timer) { _ in
            accessibility = AX.isTrusted
            screen = ScreenOCR.hasPermission
        }
    }

    private func permissionRow(granted: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.green).font(.callout)
            } else {
                Button(L("Grant…"), action: action)
            }
        }
    }
}

/// Click, then press the new shortcut. Esc cancels, Delete removes the shortcut.
struct HotkeyRecorder: View {
    let action: HotkeyAction
    @ObservedObject var settings = AppSettings.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? L("Press shortcut…") : (settings.hotkeys[action]?.display ?? L("None")))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 110)
            }
            .environment(\.layoutDirection, .leftToRight)
            if settings.hotkeys[action] != KeyCombo.defaults[action] {
                Button { set(KeyCombo.defaults[action]) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help(L("Reset to default"))
            }
            if HotkeyManager.shared.failed.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(L("This shortcut is already used by another app. Choose a different one."))
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        HotkeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            if event.keyCode == 51 || event.keyCode == 117 { set(nil); return nil }
            if let combo = KeyCombo(event: event) { set(combo); return nil }
            NSSound.beep()
            return nil
        }
    }

    private func set(_ combo: KeyCombo?) {
        var map = settings.hotkeys
        map[action] = combo
        settings.hotkeys = map
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotkeyManager.shared.resume() }
        recording = false
    }
}

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject private var nav = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $nav.tab) {
            GeneralSettings().tabItem { Label(L("General"), systemImage: "gearshape") }.tag(SettingsTab.general)
            AISettings().tabItem { Label(L("AI"), systemImage: "sparkles") }.tag(SettingsTab.ai)
            TriggerSettings().tabItem { Label(L("Triggers"), systemImage: "keyboard") }.tag(SettingsTab.triggers)
            GlossarySettings().tabItem { Label(L("Glossary"), systemImage: "character.book.closed") }.tag(SettingsTab.glossary)
            VoiceSettings().tabItem { Label(L("Voice"), systemImage: "speaker.wave.2") }.tag(SettingsTab.voice)
            PermissionSettings().tabItem { Label(L("Permissions"), systemImage: "lock.shield") }.tag(SettingsTab.permissions)
            AboutSettings().tabItem { Label(L("About"), systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .padding(.top, 6)
        .frame(minWidth: 600, minHeight: 500)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var initialInterface = AppSettings.shared.interfaceLanguage

    var body: some View {
        Form {
            Section(L("Results")) {
                LanguagePicker()
                Picker(L("Default mode"), selection: $settings.defaultMode) {
                    ForEach(Mode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom instructions (optional)")
                    TextEditor(text: $settings.customInstructions)
                        .font(.body)
                        .frame(minHeight: 60, maxHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    Text("Example: My audience is into AI; use an energetic, simple tone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Panel")) {
                Toggle(L("Hide the result panel from screen recordings by default"), isOn: Binding(
                    get: { settings.hidePanelFromCapture },
                    set: { settings.hidePanelFromCapture = $0; PanelController.shared.refreshCapturePrivacy() }))
                Toggle(L("Show the original text side by side"), isOn: $settings.sideBySide)
                HStack {
                    Text("Text size")
                    Slider(value: $settings.panelFontSize, in: 11...40, step: 1)
                    Text("\(Int(settings.panelFontSize))").monospacedDigit().frame(width: 28)
                }
                Toggle(L("Save results to History"), isOn: $settings.historyEnabled)
            }
            Section(L("App")) {
                Picker(L("Interface language"), selection: $settings.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases) { Text($0.label).tag($0) }
                }
                if settings.interfaceLanguage != initialInterface {
                    HStack {
                        Text("Relaunch to switch the interface language.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Relaunch Now")) { AppRelauncher.relaunch() }.controlSize(.small)
                    }
                }
                Toggle(L("Open ScreenLocalizer at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        LoginItem.set(value)
                        launchAtLogin = LoginItem.isEnabled
                    }))
            }
        }
        .formStyle(.grouped)
    }
}

private struct AISettings: View {
    var body: some View {
        Form {
            Section {
                AISetupSection()
            } header: {
                Text("AI provider")
            } footer: {
                Text("Works with OpenAI and any OpenAI-compatible API (OpenRouter, Groq, Ollama, LM Studio…). Keys are stored in your macOS Keychain and sent only to the provider you choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TriggerSettings: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section(L("Keyboard shortcuts")) {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.label) { HotkeyRecorder(action: action) }
                }
                Text("Shortcuts work in every app. Click a shortcut, then press the new keys.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Floating button")) {
                Toggle(L("Show a «Translate / Explain» button when I select text"), isOn: $settings.floatingButtonEnabled)
                Text("Appears next to your selection in any app, like the browser extension. It disappears when you click elsewhere or start typing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Clipboard")) {
                Picker(L("When I copy text"), selection: $settings.clipboardAction) {
                    ForEach(ClipboardAction.allCases) { Text($0.label).tag($0) }
                }
                Text("“Translate immediately” sends every text you copy to the AI provider, which uses API credits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GlossarySettings: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                if !settings.glossary.isEmpty {
                    HStack {
                        Text("Term (e.g. agent)").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Always render as (e.g. وكيل)").frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 20)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                ForEach($settings.glossary) { $entry in
                    HStack(spacing: 8) {
                        TextField("", text: $entry.term, prompt: Text(verbatim: "agent"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .environment(\.layoutDirection, .leftToRight)
                        Image(systemName: "arrow.forward").foregroundStyle(.secondary)
                        TextField("", text: $entry.rendering, prompt: Text(verbatim: "وكيل"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button {
                            settings.glossary.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    settings.glossary.append(GlossaryEntry(term: "", rendering: ""))
                } label: {
                    Label(L("Add Term"), systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Glossary")
            } footer: {
                Text("Every result uses these renderings, so terms stay consistent across your videos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VoiceSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var speaker = Speaker.shared

    var body: some View {
        Form {
            Section(L("Read aloud")) {
                Picker(L("Voice engine"), selection: $settings.ttsEngine) {
                    ForEach(TTSEngine.allCases) { Text($0.label).tag($0) }
                }
                if settings.ttsEngine == .openai {
                    Picker(L("OpenAI voice"), selection: $settings.openAIVoice) {
                        ForEach(Speaker.openAIVoices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    if settings.speechConfig == nil {
                        Label(L("OpenAI voice needs an OpenAI API key (Settings → AI with OpenAI selected)."),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption)
                    }
                } else {
                    let voices = Speaker.voices(for: settings.targetLanguage)
                    Picker(L("macOS voice"), selection: $settings.systemVoiceID) {
                        Text("Automatic").tag("")
                        ForEach(voices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                        }
                    }
                    if voices.isEmpty {
                        Text("No macOS voice installed for this language. Add one in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(speaker.isSpeaking || speaker.isLoading ? L("Stop") : L("Test Voice")) {
                        speaker.toggle(sample)
                    }
                    if let error = speaker.lastError {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sample: String {
        Languages.isRTL(settings.targetLanguage)
            ? "مرحبًا! هذا مثال على القراءة الصوتية في ScreenLocalizer."
            : "Hello! This is a read-aloud sample from ScreenLocalizer."
    }
}

private struct PermissionSettings: View {
    var body: some View {
        Form {
            Section {
                PermissionsSection()
            } header: {
                Text("macOS permissions")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("ScreenLocalizer").font(.title.bold())
            Text(LF("Version %@ (%@)", AppInfo.version, AppInfo.build)).foregroundStyle(.secondary)
            Text("Select any text — or any part of your screen — and get it translated, explained or summarized in your language.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Made by Eslam Youssef").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                Link(destination: AppInfo.websiteURL) { Text(verbatim: "eyoussef.me ↗") }
                Link(L("Source code ↗"), destination: AppInfo.repoURL)
                Link(L("Privacy policy ↗"), destination: AppInfo.privacyURL)
                Link(L("Check for Updates ↗"), destination: AppInfo.releasesURL)
            }
            .font(.callout)
            Text("Free for personal use only.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

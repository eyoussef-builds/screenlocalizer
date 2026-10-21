import SwiftUI

struct OnboardingView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var step = 0
    @State private var launchAtLogin = true
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome
                case 1: languageStep
                case 2: aiStep
                case 3: permissionsStep
                default: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: step)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Circle().fill(i == step ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.15)))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 {
                    Button(L("Back")) { step -= 1 }
                }
                if step < steps - 1 {
                    Button(step == 0 ? L("Get Started") : L("Continue")) { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == 1 && settings.targetLanguage.trimmed.isEmpty)
                } else {
                    Button(L("Start Using ScreenLocalizer"), action: finish)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110)
            Text("Welcome to ScreenLocalizer").font(.largeTitle.bold())
            Text("Select any text — or any part of your screen — and get it translated, explained or summarized in your language.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
        }
        .padding(30)
    }

    private var languageStep: some View {
        stepLayout(title: L("Which language do you want results in?"),
                   subtitle: L("Translations, explanations and summaries will be written in this language. You can change it any time.")) {
            Form { LanguagePicker() }.formStyle(.grouped).frame(maxHeight: 160)
        }
    }

    private var aiStep: some View {
        stepLayout(title: L("Connect your AI provider"),
                   subtitle: L("ScreenLocalizer uses your own API key, so there's no subscription. OpenAI is the default; any OpenAI-compatible service works.")) {
            Form { AISetupSection() }.formStyle(.grouped)
        }
    }

    private var permissionsStep: some View {
        stepLayout(title: L("Allow access"),
                   subtitle: L("macOS asks you to approve these once. Turn ScreenLocalizer on in each list that opens.")) {
            Form { PermissionsSection() }.formStyle(.grouped)
        }
    }

    private var readyStep: some View {
        stepLayout(title: L("You're all set"), subtitle: L("ScreenLocalizer lives in your menu bar. Use it from any app:")) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        Text(settings.hotkeys[action]?.display ?? "—")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                            .environment(\.layoutDirection, .leftToRight)
                            .frame(width: 80, alignment: .leading)
                        Text(action.label)
                    }
                }
                HStack {
                    Image(systemName: "cursorarrow.and.square.on.square.dashed").frame(width: 80, alignment: .leading)
                    Text("Or just select text — a «Translate / Explain» button appears.")
                }
                Divider().padding(.vertical, 4)
                Toggle(L("Open ScreenLocalizer at login"), isOn: $launchAtLogin)
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
    }

    private func stepLayout<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.title.bold()).multilineTextAlignment(.center)
            Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            content()
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
    }

    private func finish() {
        settings.onboardingDone = true
        if launchAtLogin != LoginItem.isEnabled { LoginItem.set(launchAtLogin) }
        WindowManager.shared.close(.onboarding)
        Toast.show(LF("ScreenLocalizer is ready. Select text and press %@.",
                      settings.hotkeys[.translateSelection]?.display ?? "⌃⌥T"))
    }
}

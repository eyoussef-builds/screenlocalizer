# ScreenLocalizer for Mac

Native macOS version of the ScreenLocalizer extension: select text — or box any part of the
screen — in **any app**, and get it translated, explained, simplified, summarized, turned into a
video script or a social post, in your language.

Built for creators who read English sources and present them in another language: the result
panel can be **hidden from screen recordings**, so you read the Arabic while viewers only see the page.

## Features

| | |
|---|---|
| **Triggers** | `⌃⌥T` translate selected text · `⌃⌥O` box text on screen (OCR) · `⌃⌥V` paste box · floating «Translate / Explain» button on selection · optional "when I copy text" action |
| **Modes** | Translate · Explain · Simplify · Summarize · Video Script · Social Post, plus follow-up questions |
| **Panel** | Floating, doesn't steal focus, side-by-side original/result, adjustable text size, copy, regenerate, read aloud, Private/Visible recording toggle |
| **History** | Every result saved locally, searchable, exportable as a Markdown script |
| **Glossary** | Your term → rendering list, applied to every prompt |
| **AI** | OpenAI or any OpenAI-compatible API (OpenRouter, Groq, Ollama, LM Studio, custom). Keys live in the macOS Keychain |
| **Voice** | macOS voices (free, offline) or OpenAI text-to-speech |
| **Language** | Interface follows macOS (English / Arabic, fully right-to-left); results in any language picked at first launch |

Everything except the AI request runs on the Mac: OCR uses Apple's on-device Vision framework,
and only the text is sent, to the provider you choose.

## Build & install

Requires macOS 14+ on Apple Silicon and the Xcode Command Line Tools (Xcode itself isn't needed).

```bash
scripts/build-app.sh            # → build/ScreenLocalizer.app
scripts/build-app.sh --install  # build, copy to /Applications, launch
scripts/package-dmg.sh          # → build/ScreenLocalizer-mac.dmg
```

The build script calls `swiftc` directly. `Package.swift` is there so the project opens in Xcode
or builds with `swift build` on a healthy toolchain (SwiftPM in some Command Line Tools installs
can't link package manifests).

### First launch

Onboarding asks for the result language, the AI provider + key, and two macOS permissions:

- **Accessibility** — read selected text in other apps (shortcut + floating button).
- **Screen Recording** — read text from the screen region you box (OCR).

### Updates and permissions

macOS ties Accessibility, Screen Recording and Keychain approvals to the app's signature. Official
releases are signed with one stable self-signed certificate ("ScreenLocalizer Local Signing"), so
approvals survive updates. Builds made elsewhere are ad-hoc signed unless that machine has run
`scripts/setup-signing.sh` (once; it asks for the user's password), so macOS treats each such build as
a new app. **Settings → Permissions → Reset Permissions & Try Again** clears the app's own stale
entries (via `tccutil`) and asks again.

## Distribution

`scripts/package-dmg.sh` builds a drag-to-Applications disk image. Without an Apple Developer ID,
people see "Apple could not verify ScreenLocalizer" on first launch and allow it in System Settings →
Privacy & Security → **Open Anyway**. Signing with a Developer ID and notarizing removes that step;
no code changes are needed. The Mac App Store isn't an option for the selection features, because
sandboxed apps can't read other apps' selected text.

User guide (English / Arabic): [../README.md](../README.md) · [../README.ar.md](../README.ar.md)

## Development

```
Sources/ScreenLocalizer/
  App/       AppDelegate, menus, windows, action wiring, debug hooks
  AI/        OpenAI-compatible streaming client, prompts, providers, read-aloud
  Capture/   global shortcuts, selection reading (Accessibility + ⌘C fallback),
             floating-button watcher, clipboard watcher, screen OCR
  Store/     settings, Keychain, sessions, history
  UI/        result panel, settings, onboarding, history, shared controls
Resources/   Info.plist, AppIcon.icns, en/ar Localizable.strings
scripts/     build, package, icon, string check, mock API, signing setup
```

- **Strings:** UI text is English-keyed; `python3 -I scripts/check-strings.py` lists anything
  missing from `ar.lproj`.
- **Testing without a key:** `python3 -I scripts/mock-openai.py 8765` starts a local
  OpenAI-compatible API; set Settings → AI → Provider "Custom", base URL `http://127.0.0.1:8765/v1`.
- **Automation:** launched with `SCREENLOCALIZER_DEBUG=1`, the app accepts commands over a
  distributed notification (`me.eyoussef.screenlocalizer.debug`) — see `App/DebugHooks.swift`.
  Normal launches never listen.
- **Icon:** edit `Assets/AppIcon.html`, then `scripts/make-icon.sh`.

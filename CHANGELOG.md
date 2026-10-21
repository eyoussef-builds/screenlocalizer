# Changelog

All notable changes to ScreenLocalizer. Dates are in YYYY-MM-DD.

## [1.0.1] — 2026-10-21

### Mac app 1.0.1

- **Permissions now survive updates.** Releases are signed with a stable certificate, so macOS keeps
  Accessibility, Screen Recording and Keychain approvals across future updates. (Updating from 1.0.0
  asks one last time.)
- New **Reset Permissions & Try Again** button (Settings → Permissions and the welcome screen) that
  clears ScreenLocalizer's own outdated permission entries and asks again. **Grant…** for Accessibility
  does this automatically.
- Clearer guidance when macOS shows ScreenLocalizer more than once in its permission lists.

## [1.0.0] — 2026-10-21 — First public release

### Mac app 1.0.0 (new)

- Works in **every app**: global shortcut on selected text (`⌃⌥T`), screen text capture with
  on-device OCR (`⌃⌥O`), paste box (`⌃⌥V`), a floating «Translate / Explain» button on selection,
  and an optional "when I copy text" action.
- Modes: Translate, Explain, Simplify, Summarize, **Video Script** and **Social Post**, plus
  follow-up questions about the same text.
- Floating result panel that doesn't steal focus, with side-by-side original text, adjustable
  text size, copy, regenerate and read-aloud (macOS voices or OpenAI voices).
- **Private mode**: the panel is hidden from screen recordings and screenshots by default.
- History with search and Markdown export; glossary for consistent terminology.
- OpenAI or any OpenAI-compatible API (OpenRouter, Groq, Ollama, LM Studio, custom);
  keys stored in the macOS Keychain.
- English and Arabic interface (fully right-to-left), first-launch onboarding, launch at login.

### Browser extension 1.1.0

- Default model is now `gpt-5-mini`; newer reasoning models get the right request settings
  automatically, with one retry if a model rejects a setting.
- Settings page: the show/hide key button no longer overlaps the key.
- Added a link to this repository.

### Browser extension 1.0.0 — 2026-06-10

- Select text on any web page → «ترجم / اشرح» button → Translate, Explain, Simplify or Summarize
  in Arabic (or any language), streamed from OpenAI with your own key.
- Right-click menu and `Ctrl/⌘ + Shift + Y` shortcut.

[1.0.1]: https://github.com/eyoussef-builds/screenlocalizer/releases/tag/v1.0.1
[1.0.0]: https://github.com/eyoussef-builds/screenlocalizer/releases/tag/v1.0.0

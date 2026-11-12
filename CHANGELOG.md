# Changelog

All notable changes to ScreenLocalizer. Dates are in YYYY-MM-DD.

## [1.1.0] — 2026-11-12

### Mac app 1.1.0

- **Sign in with your ChatGPT or Claude account — no API key needed.** Choose **ChatGPT Account**
  (powered by OpenAI's official `ChatGPT` macOS app / `Codex` `app-server` protocol) or **Claude
  Account** (powered by Anthropic's official `Claude Code` CLI) during onboarding or in **Settings →
  AI** to use your personal subscription directly without creating or funding an `sk-…` API key.
  Every user signs in locally on their own Mac; no credentials are ever stored in project files.
- **Quick AI Provider switcher & active model badge.** Switch between **ChatGPT Account**, **Claude
  Account**, **OpenAI**, **OpenRouter**, **Groq**, **Ollama**, **LM Studio** and **Custom** with one
  click from the menu-bar icon (**AI Provider**), and see the active provider and model directly in
  the floating result panel's bottom bar.
- **Instant-popup speed & low-latency engine:**
  - Pre-warmed `FloatingPanel` and `FloatingButton` reuse their `NSHostingView` hierarchies across
    captures (`< 16 ms` open time).
  - Warm standby AI sessions (`WarmClaudeSession` over `stream-json` for Claude Account, warm
    ephemeral `standbyThread` + strict FIFO `AsyncStream` delta delivery for ChatGPT Account, and
    pre-warmed low-latency `URLSession` connections for API/local providers) plus a 64-entry
    thread-safe LRU translation cache (`0 ms` repeat lookups, bypassed on **Regenerate**).
  - Faster `⌃⌥T` selection capture (tightened AX IPC timeouts, off-main-thread per-PID
    `AXManualAccessibility` caching, `5 ms` pasteboard polling without the legacy `1000 ms`
    modifier-release wait, and async clipboard restore) and optimistic `< 16 ms` panel presentation
    during `⌃⌥O` Screen OCR with cached `SCShareableContent`.
  - `60fps` (`16 ms`) token coalescing with zero-delay first-token flush, `NSCache`-backed Markdown
    block rendering, event-driven `ClipboardWatcher` (zero idle CPU wakeups when off), and async
    `HistoryStore` startup loading.
- **Smarter RTL & bilingual Screen OCR (`⌃⌥O`) and reliability fixes:**
  - Vision text observations are grouped into horizontal rows by vertical overlap and ordered
    right-to-left on Arabic/Hebrew lines and left-to-right on English/Latin lines.
  - Added stream and speech race-condition guards, isolated synthetic `⌘C` events
    (`CGEventSource(.privateState)`) with a 10 MB per-item pasteboard backup cap, smooth header
    dragging (`WindowDragArea`), `NSLock`-synchronized Keychain caching, and automatic stripping of
    hidden Unicode BiDi control characters (`U+200E`, `U+200F`, `U+202A–U+202E`, `U+2066–U+2069`).

### Browser extension 1.1.0 (updated)

- Predictive Manifest V3 service-worker & TLS/HTTP2 warmup on selection pill display, in-memory
  cached settings, `60fps` `requestAnimationFrame` delta coalescing (with instant first-token
  paint), and a 50-entry LRU translation cache (bypassed on **↻ إعادة**).
- Support text selection inside `<input>` and `<textarea>` form fields, richer Markdown rendering
  (headings, numbered lists, fenced code blocks) with strict HTML escaping, immediate stream
  cancellation on mode switch/close, final SSE buffer flush, and device-local API key storage
  (`chrome.storage.local` with automatic one-time migration).

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

[1.1.0]: https://github.com/eyoussef-builds/screenlocalizer/releases/tag/v1.1.0
[1.0.1]: https://github.com/eyoussef-builds/screenlocalizer/releases/tag/v1.0.1
[1.0.0]: https://github.com/eyoussef-builds/screenlocalizer/releases/tag/v1.0.0

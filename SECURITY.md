# Security Policy · سياسة الأمان

## Supported versions

Only the latest release of the browser extension and of the Mac app receives fixes.

## Reporting a vulnerability

**Please don't open a public issue.** Email **hello@eyoussef.me** with:

- which version (extension or Mac app) and its version number,
- what the problem is and how to reproduce it,
- what could happen if someone abused it.

You'll get a reply within a few days. Please give us a reasonable time to fix the problem before
sharing it publicly. Thank you for keeping ScreenLocalizer users safe!

## The basics of how ScreenLocalizer handles secrets

- Your API key is stored only on your device: in the browser's local extension storage
  (extension) or in the macOS Keychain (Mac app). It is sent only to the AI provider you chose.
- ScreenLocalizer has no server, no account system, and no analytics.
- The Mac app's test hooks (`App/DebugHooks.swift`) are disabled unless the app is launched with
  `SCREENLOCALIZER_DEBUG=1` in its environment; normal launches never listen for them.

---

## الإبلاغ عن ثغرة أمنية

**من فضلك لا تفتح بلاغًا عامًا (Issue).** راسلنا على **hello@eyoussef.me** واذكر النسخة (الإضافة أو تطبيق
الماك) ورقم الإصدار، وما المشكلة وكيف نكرّرها، وما الضرر المحتمل. سنرد خلال أيام قليلة، ونرجو منحنا وقتًا
معقولًا للإصلاح قبل النشر العلني. شكرًا لك!

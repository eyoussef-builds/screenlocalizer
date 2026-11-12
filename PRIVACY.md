# Privacy Policy · سياسة الخصوصية

_ScreenLocalizer browser extension and Mac app · Last updated: 2026-11-12_

## English

**ScreenLocalizer does not collect, store, sell or share your personal data.** It has no server,
no account system, no analytics, no ads and no tracking.

### What leaves your device — and only when you ask

When you trigger ScreenLocalizer (button, shortcut, right-click menu, screen capture, paste box or
the optional "when I copy text" setting), the text you chose is sent **directly from your device to
the AI provider you configured** — such as your signed-in **ChatGPT** or **Claude** account on the
Mac app, or **OpenAI** (or another compatible provider) via API key — to produce the translation or
explanation. To help the AI, the request can include the name of the app and the window or page
title the text came from. The extension also includes the page address (URL).

- Your use of that provider is governed by **its** privacy policy
  (for OpenAI: <https://openai.com/policies/privacy-policy>;
  for Anthropic / Claude: <https://www.anthropic.com/legal/privacy>).
- If you turn on **"Translate immediately"** for copied text in the Mac app, everything you copy is
  sent to the provider. It is off by default.
- **Read aloud** with the OpenAI voice sends the result text to OpenAI's speech service; the macOS
  voice works entirely offline.

### What stays on your device

- **ChatGPT & Claude account sign-in (Mac app)** — handled locally on your Mac through OpenAI's
  official `codex app-server` and Anthropic's official `claude` CLI. ScreenLocalizer never reads,
  copies or uploads OAuth token files, and never embeds any personal account inside the app or
  project files.
- **Your API key** — in the browser's local extension storage (`chrome.storage.local` in the
  extension) or the macOS Keychain (Mac app). It is only ever sent to the provider you chose.
- **Settings and glossary** — in browser/app preferences on your device.
- **History** (Mac app) — `~/Library/Application Support/ScreenLocalizer/history.json`. You can turn
  it off, delete items or clear it in the History window.
- **Screen capture (OCR)** — the image of the area you box is read on your Mac by Apple's Vision
  framework. The image is never saved or uploaded; only the recognized text is sent, as above.

### macOS permissions (Mac app)

- **Accessibility** is used only to read the text you select and to copy it when an app doesn't
  share its selection.
- **Screen Recording** is used only to capture the area you draw a box around. ScreenLocalizer never
  records video.

### Contact

Questions: **hello@eyoussef.me** · <https://eyoussef.me>

---

<div dir="rtl">

## العربية

**ScreenLocalizer لا يجمع بياناتك الشخصية ولا يخزّنها ولا يبيعها ولا يشاركها.** لا يوجد خادم خاص بنا، ولا
حسابات، ولا تحليلات، ولا إعلانات، ولا تتبّع.

### ما الذي يخرج من جهازك؟ (فقط عندما تطلب أنت)

عندما تستخدم ScreenLocalizer (الزر، أو الاختصار، أو قائمة الزر الأيمن، أو التقاط الشاشة، أو صندوق اللصق، أو
خيار «عند نسخ نص»)، يُرسَل النص الذي اخترته **مباشرةً من جهازك إلى مزوّد الذكاء الاصطناعي الذي اخترته** — سواء
حسابك الشخصي في **ChatGPT** أو **Claude** على تطبيق الماك، أو **OpenAI** (أو أي مزوّد متوافق) عبر مفتاح API —
للحصول على الترجمة أو الشرح. وقد يتضمن الطلب اسم التطبيق وعنوان النافذة أو الصفحة التي جاء منها النص لمساعدة
الذكاء الاصطناعي على الفهم، وتضيف الإضافة رابط الصفحة أيضًا.

- يخضع استخدامك لهذا المزوّد لسياسة الخصوصية **الخاصة به** (سياسة OpenAI وAnthropic).
- إذا فعّلت خيار **«الترجمة فورًا»** للنصوص المنسوخة في تطبيق الماك، فسيُرسَل كل ما تنسخه. هذا الخيار مُطفأ افتراضيًا.
- **القراءة الصوتية** بصوت OpenAI ترسل النص الناتج إلى خدمة الصوت لديهم، أما صوت macOS فيعمل دون إنترنت.

### ما الذي يبقى على جهازك؟

- **تسجيل الدخول بحساب ChatGPT أو Claude (تطبيق الماك)** — يتم محليًا على جهازك عبر الأدوات الرسمية لـ OpenAI
  (`codex app-server`) وAnthropic (`claude` CLI). لا يقرأ ScreenLocalizer ملفات رموز الدخول ولا ينسخها ولا يُضمّن
  أي حساب شخصي داخل التطبيق أو ملفات المشروع.
- **مفتاح API الخاص بك** — في تخزين المتصفح المحلي على الجهاز (`chrome.storage.local` في الإضافة) أو في سلسلة
  مفاتيح macOS (تطبيق الماك)، ولا يُرسَل إلا إلى المزوّد الذي اخترته.
- **الإعدادات والمصطلحات** — في تفضيلات المتصفح أو التطبيق على جهازك.
- **السجل** (تطبيق الماك) — داخل مجلد التطبيق على جهازك، ويمكنك إيقافه أو حذف عناصره في أي وقت.
- **التقاط النص من الشاشة (OCR)** — تُقرأ صورة المنطقة التي تحددها على جهازك بواسطة تقنية Vision من Apple، ولا
  تُحفَظ الصورة ولا تُرفَع أبدًا؛ يُرسَل النص المقروء فقط.

### أذونات macOS (تطبيق الماك)

- **تسهيلات الاستخدام:** لقراءة النص الذي تحدده فقط، ونسخه عندما لا يشاركه التطبيق.
- **تسجيل الشاشة:** لالتقاط المنطقة التي ترسم حولها مربعًا فقط. ScreenLocalizer لا يسجّل فيديو أبدًا.

### للتواصل

**hello@eyoussef.me** · <https://eyoussef.me>

</div>

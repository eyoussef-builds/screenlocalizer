# Contributing to ScreenLocalizer · المساهمة في المشروع

Thank you for wanting to help! Bug reports, ideas, translations and code are all welcome.
You can write in English or Arabic.

## Ways to help

- **Report a bug or suggest an idea** — open an [issue](https://github.com/eyoussef-builds/screenlocalizer/issues/new/choose).
- **Improve a translation** — the Mac app's Arabic text lives in
  `mac/Resources/ar.lproj/Localizable.strings`. Adding a new interface language means adding
  a new `xx.lproj/Localizable.strings` file and listing it in `mac/Resources/Info.plist`.
- **Improve the docs** — `README.md` (English) and `README.ar.md` (Arabic) should always say the same thing.
- **Send code** — see below.

## Working on the code

### Browser extension (`extension/`)

Plain JavaScript, no build step.

1. Open `chrome://extensions` (or `edge://extensions`), turn on **Developer mode**,
   click **Load unpacked** and pick the `extension` folder.
2. After editing, click the ↻ reload button on the extension's card, then reload the web page.
3. Check syntax: `for f in extension/*.js; do node --check "$f"; done`

### Mac app (`mac/`)

Swift + SwiftUI/AppKit, macOS 14+, Apple Silicon. Xcode isn't required — the Command Line Tools are enough.

```bash
mac/scripts/build-app.sh                 # build mac/build/ScreenLocalizer.app
python3 mac/scripts/check-strings.py     # every UI string translated?
python3 mac/scripts/mock-openai.py 8765  # fake AI server for testing without a key
```

To test without spending API credit, start the mock server and set the app's provider to
**Custom** with base URL `http://127.0.0.1:8765/v1`. See [`mac/README.md`](mac/README.md) for the
code layout and the test hooks.

### Style

- Match the surrounding code; keep functions small and names clear.
- Every new piece of interface text needs an Arabic translation.
- Never commit API keys, personal data, or anything from your own machine.
- Screenshots carry hidden metadata (macOS even embeds your monitor's model). Run
  `python3 scripts/clean-images.py` before committing images; CI rejects images with metadata.

## Pull requests

1. Fork the repo and create a branch: `git checkout -b fix-floating-button`.
2. Make your change and test it (CI builds both the extension and the Mac app).
3. Open a pull request and fill in the checklist.

## Contribution terms (please read)

ScreenLocalizer is free for **personal use only** under the
[ScreenLocalizer Personal Use License](LICENSE): redistribution and commercial use aren't allowed,
and forks on GitHub may only be used to prepare pull requests to this repository. The maintainer may
offer commercial licenses in the future. To keep that possible, **by submitting a contribution you
agree that**:

- you wrote it (or have the right to submit it), and
- you grant the maintainer (Eslam Youssef) a perpetual, worldwide, non-exclusive, royalty-free,
  irrevocable license to use, modify, distribute, sublicense and **relicense** your contribution,
  including under commercial license terms.

You keep the copyright to your contribution.

Please also follow our [Code of Conduct](CODE_OF_CONDUCT.md).

---

## بالعربية باختصار

- **للإبلاغ عن مشكلة أو اقتراح فكرة:** افتح [Issue](https://github.com/eyoussef-builds/screenlocalizer/issues/new/choose) بالعربية أو الإنجليزية.
- **لتحسين الترجمة:** نصوص الواجهة العربية في `mac/Resources/ar.lproj/Localizable.strings`.
- **لإرسال كود:** اتبع الخطوات أعلاه، ثم افتح Pull Request.
- **شروط المساهمة:** بإرسالك مساهمة فأنت توافق على أن يستخدمها صاحب المشروع (إسلام يوسف) ويعيد ترخيصها، بما في
  ذلك تحت تراخيص تجارية مستقبلًا، مع احتفاظك بحقوق الملكية الخاصة بك.

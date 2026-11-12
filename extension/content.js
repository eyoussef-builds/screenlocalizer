// ScreenLocalizer — content script
// Shows a floating button next to selected text; clicking it opens a panel
// that translates / explains / simplifies / summarizes the selection.

(() => {
  if (window.__screenLocalizerLoaded) return;
  window.__screenLocalizerLoaded = true;

  const MAX_CHARS = 6000;
  const RTL_LANGS = ["arabic", "العربية", "hebrew", "persian", "farsi", "urdu"];

  const MODES = [
    { id: "translate", label: "ترجمة", title: "Translate" },
    { id: "explain", label: "شرح", title: "Explain (not literal)" },
    { id: "simplify", label: "تبسيط", title: "Explain like I'm a beginner" },
    { id: "summarize", label: "تلخيص", title: "Summarize" },
  ];

  let settings = {
    enabled: true,
    defaultMode: "translate",
    targetLanguage: "Arabic",
  };
  chrome.storage.sync.get(settings, (s) => Object.assign(settings, s));
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "sync") return;
    for (const k of Object.keys(changes)) {
      if (k in settings) settings[k] = changes[k].newValue;
    }
  });

  // ---------- shadow DOM host ----------
  const host = document.createElement("div");
  host.id = "screenlocalizer-host";
  host.style.cssText = "all:initial; position:fixed; z-index:2147483647; top:0; left:0; width:0; height:0;";
  const shadow = host.attachShadow({ mode: "closed" });
  (document.documentElement || document.body).appendChild(host);

  const style = document.createElement("style");
  style.textContent = `
    :host { all: initial; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    .sl-btn {
      position: fixed;
      display: flex; align-items: center; gap: 6px;
      padding: 6px 10px;
      background: linear-gradient(135deg, #6366f1, #8b5cf6);
      color: #fff;
      border: none; border-radius: 999px;
      font: 600 12.5px/1 -apple-system, "Segoe UI", system-ui, sans-serif;
      cursor: pointer;
      box-shadow: 0 4px 14px rgba(80, 70, 220, .4);
      user-select: none;
      transition: transform .12s ease;
    }
    .sl-btn:hover { transform: scale(1.06); }
    .sl-btn svg { width: 14px; height: 14px; flex: none; }
    .sl-panel {
      position: fixed;
      width: 420px; max-width: calc(100vw - 24px);
      max-height: min(560px, calc(100vh - 24px));
      display: flex; flex-direction: column;
      background: #fff; color: #1f2330;
      border: 1px solid rgba(0,0,0,.08);
      border-radius: 14px;
      box-shadow: 0 12px 40px rgba(20, 20, 60, .25);
      font: 14px/1.65 -apple-system, "Segoe UI", system-ui, "Noto Naskh Arabic", sans-serif;
      overflow: hidden;
    }
    .sl-header {
      display: flex; align-items: center; gap: 8px;
      padding: 10px 12px;
      background: linear-gradient(135deg, #6366f1, #8b5cf6);
      color: #fff;
      cursor: grab; user-select: none;
    }
    .sl-header:active { cursor: grabbing; }
    .sl-logo { width: 18px; height: 18px; flex: none; }
    .sl-title { font-weight: 700; font-size: 13.5px; flex: 1; }
    .sl-iconbtn {
      background: rgba(255,255,255,.16); border: none; color: #fff;
      width: 24px; height: 24px; border-radius: 7px; cursor: pointer;
      display: flex; align-items: center; justify-content: center;
      font-size: 13px; line-height: 1;
    }
    .sl-iconbtn:hover { background: rgba(255,255,255,.3); }
    .sl-modes {
      display: flex; gap: 6px; padding: 10px 12px 0 12px; flex-wrap: wrap;
      direction: rtl;
    }
    .sl-chip {
      border: 1px solid #d9dcf0; background: #f4f5fd; color: #4549b8;
      padding: 5px 14px; border-radius: 999px;
      font: 600 12.5px/1 inherit; font-family: inherit;
      cursor: pointer; transition: all .12s ease;
    }
    .sl-chip:hover { border-color: #8b8ff0; }
    .sl-chip.active {
      background: linear-gradient(135deg, #6366f1, #8b5cf6);
      border-color: transparent; color: #fff;
    }
    .sl-body {
      padding: 12px 14px; overflow-y: auto; flex: 1; min-height: 90px;
      font-size: 14.5px;
    }
    .sl-body[dir="rtl"] { text-align: right; }
    .sl-body p { margin: 0 0 8px; }
    .sl-body h4 { font-size: 15px; font-weight: 700; margin: 4px 0 6px; }
    .sl-body ul, .sl-body ol { margin: 0 0 8px; padding-inline-start: 20px; }
    .sl-body li { margin-bottom: 4px; }
    .sl-body hr { border: none; border-top: 1px solid #ededf5; margin: 10px 0; }
    .sl-body code {
      background: #f0f1f7; border-radius: 4px; padding: 1px 5px;
      font: 12.5px ui-monospace, "SF Mono", Menlo, monospace;
      direction: ltr; unicode-bidi: isolate;
    }
    .sl-body pre {
      background: #f0f1f7; border-radius: 8px; padding: 8px 10px; margin: 0 0 8px;
      overflow-x: auto; direction: ltr; unicode-bidi: isolate; text-align: left;
    }
    .sl-body pre code { background: none; padding: 0; }
    .sl-loading { display: flex; gap: 5px; padding: 10px 2px; }
    .sl-loading span {
      width: 7px; height: 7px; border-radius: 50%; background: #8b8ff0;
      animation: sl-pulse 1s ease-in-out infinite;
    }
    .sl-loading span:nth-child(2) { animation-delay: .15s; }
    .sl-loading span:nth-child(3) { animation-delay: .3s; }
    @keyframes sl-pulse { 0%, 100% { opacity: .25; transform: scale(.8);} 50% { opacity: 1; transform: scale(1);} }
    .sl-error { color: #c0392b; white-space: pre-wrap; font-size: 13px; }
    .sl-footer {
      display: flex; align-items: center; gap: 8px;
      padding: 8px 12px; border-top: 1px solid #ededf5;
      background: #fafafe;
    }
    .sl-footbtn {
      border: 1px solid #d9dcf0; background: #fff; color: #4549b8;
      padding: 5px 12px; border-radius: 8px;
      font: 600 12px/1 inherit; font-family: inherit; cursor: pointer;
      display: flex; align-items: center; gap: 5px;
    }
    .sl-footbtn:hover { background: #f4f5fd; }
    .sl-count { font-size: 11px; color: #9aa0b5; margin-inline-start: auto; direction: ltr; }
    @media (prefers-color-scheme: dark) {
      .sl-panel { background: #1d1f2b; color: #e8eaf2; border-color: rgba(255,255,255,.1); }
      .sl-chip { background: #262a3d; border-color: #3a3f58; color: #aeb3f5; }
      .sl-body code, .sl-body pre { background: #2a2e42; }
      .sl-body hr { border-top-color: #2a2e42; }
      .sl-footer { background: #181a24; border-top-color: #2a2e42; }
      .sl-footbtn { background: #262a3d; border-color: #3a3f58; color: #aeb3f5; }
      .sl-footbtn:hover { background: #303550; }
    }
  `;
  shadow.appendChild(style);

  const LOGO_SVG = `<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
    <path d="M4 4h11a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H9l-4 3.5V6a2 2 0 0 1 2-2z" fill="currentColor" opacity=".95"/>
    <path d="M19 9.5h.5A2.5 2.5 0 0 1 22 12v8l-3.2-2.5H14" stroke="currentColor" stroke-width="1.6" fill="none" stroke-linecap="round"/>
    <text x="9.5" y="11.6" font-size="7.5" font-weight="bold" fill="#6366f1" text-anchor="middle" font-family="sans-serif">ع</text>
  </svg>`;

  // ---------- state ----------
  let btnEl = null;
  let panelEl = null;
  let currentText = "";
  let currentMode = null;
  let requestSeq = 0;
  let activeRequestId = null;
  let port = null;
  const cache = new Map(); // mode -> finished text (for current selection)
  let streamBuffer = "";
  let rafId = null;

  function cancelStreamFrame() {
    if (rafId !== null) {
      cancelAnimationFrame(rafId);
      rafId = null;
    }
  }

  function getPort() {
    if (port) return port;
    port = chrome.runtime.connect({ name: "screenlocalizer" });
    port.onMessage.addListener(onPortMessage);
    port.onDisconnect.addListener(() => { port = null; });
    return port;
  }

  function isRTL() {
    const l = (settings.targetLanguage || "").toLowerCase();
    return RTL_LANGS.some((x) => l.includes(x));
  }

  // ---------- minimal markdown rendering ----------
  function escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }
  function renderMarkdown(text) {
    const inline = (s) =>
      escapeHtml(s)
        .replace(/`([^`]+)`/g, "<code>$1</code>")
        .replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
        .replace(/(^|[^*])\*([^*]+)\*(?!\*)/g, "$1<em>$2</em>");
    const lines = text.split("\n");
    let html = "", listTag = null, para = [], codeLines = null;
    const closeList = () => { if (listTag) { html += `</${listTag}>`; listTag = null; } };
    const flushPara = () => {
      if (para.length) { html += `<p>${para.map(inline).join("<br>")}</p>`; para = []; }
    };
    for (const raw of lines) {
      const trimmed = raw.trim();
      if (trimmed.startsWith("```")) {
        if (codeLines !== null) {
          html += `<pre><code>${escapeHtml(codeLines.join("\n"))}</code></pre>`;
          codeLines = null;
        } else {
          flushPara(); closeList();
          codeLines = [];
        }
        continue;
      }
      if (codeLines !== null) { codeLines.push(raw); continue; }
      if (/^([-*_])\1{2,}$/.test(trimmed)) { flushPara(); closeList(); html += "<hr>"; continue; }
      const heading = trimmed.match(/^#{1,6}\s+(.*)$/);
      if (heading) { flushPara(); closeList(); html += `<h4>${inline(heading[1])}</h4>`; continue; }
      const bullet = raw.match(/^\s*[-•*]\s+(.*)$/);
      if (bullet) {
        flushPara();
        if (listTag !== "ul") { closeList(); html += "<ul>"; listTag = "ul"; }
        html += `<li>${inline(bullet[1])}</li>`;
        continue;
      }
      const numbered = raw.match(/^\s*\d{1,3}[.)]\s+(.*)$/);
      if (numbered) {
        flushPara();
        if (listTag !== "ol") { closeList(); html += "<ol>"; listTag = "ol"; }
        html += `<li>${inline(numbered[1])}</li>`;
        continue;
      }
      closeList();
      if (trimmed === "") flushPara();
      else para.push(raw);
    }
    if (codeLines !== null) html += `<pre><code>${escapeHtml(codeLines.join("\n"))}</code></pre>`;
    closeList();
    flushPara();
    return html;
  }

  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text);
        return true;
      } catch (_) {}
    }
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.cssText = "position:fixed;top:-9999px;left:-9999px;opacity:0;";
    (document.body || document.documentElement).appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (_) {}
    ta.remove();
    return ok;
  }

  // ---------- floating button ----------
  function removeBtn() {
    if (btnEl) { btnEl.remove(); btnEl = null; }
  }

  function showBtn(rect) {
    removeBtn();
    // Wake the MV3 service worker & warm TLS/HTTP2 while the cursor moves toward the button.
    try { getPort().postMessage({ type: "warmup" }); } catch (_) {}
    btnEl = document.createElement("button");
    btnEl.className = "sl-btn";
    btnEl.innerHTML = `${LOGO_SVG}<span>ترجم / اشرح</span>`;
    shadow.appendChild(btnEl);
    const bw = 120, bh = 30;
    let x = rect.left + rect.width / 2 - bw / 2;
    let y = rect.bottom + 8;
    if (y + bh > window.innerHeight - 8) y = rect.top - bh - 8;
    x = Math.max(8, Math.min(x, window.innerWidth - bw - 8));
    y = Math.max(8, Math.min(y, window.innerHeight - bh - 8));
    btnEl.style.left = `${x}px`;
    btnEl.style.top = `${y}px`;
    btnEl.addEventListener("mousedown", (e) => e.stopPropagation());
    btnEl.addEventListener("click", (e) => {
      e.stopPropagation();
      const text = currentText;
      removeBtn();
      openPanel(text, rect);
    });
  }

  // ---------- panel ----------
  function closePanel() {
    cancelStreamFrame();
    if (activeRequestId && port) port.postMessage({ type: "abort" });
    activeRequestId = null;
    if (panelEl) { panelEl.remove(); panelEl = null; }
  }

  function openPanel(text, anchorRect) {
    if (!text) return;
    closePanel();
    cache.clear();
    currentText = text;

    panelEl = document.createElement("div");
    panelEl.className = "sl-panel";
    panelEl.innerHTML = `
      <div class="sl-header">
        <span class="sl-logo">${LOGO_SVG}</span>
        <span class="sl-title">ScreenLocalizer</span>
        <button class="sl-iconbtn" data-act="settings" title="Settings — الإعدادات">⚙</button>
        <button class="sl-iconbtn" data-act="close" title="Close — إغلاق">✕</button>
      </div>
      <div class="sl-modes"></div>
      <div class="sl-body" dir="${isRTL() ? "rtl" : "ltr"}"></div>
      <div class="sl-footer">
        <button class="sl-footbtn" data-act="copy" title="Copy result">📋 نسخ</button>
        <button class="sl-footbtn" data-act="retry" title="Regenerate">↻ إعادة</button>
        <span class="sl-count">${text.length.toLocaleString()} chars</span>
      </div>`;
    shadow.appendChild(panelEl);

    // position near the selection, clamped to viewport
    const pw = Math.min(420, window.innerWidth - 24);
    let x = anchorRect ? anchorRect.left : window.innerWidth / 2 - pw / 2;
    let y = anchorRect ? anchorRect.bottom + 10 : 80;
    x = Math.max(12, Math.min(x, window.innerWidth - pw - 12));
    if (y + 320 > window.innerHeight) y = Math.max(12, window.innerHeight - 380);
    panelEl.style.left = `${x}px`;
    panelEl.style.top = `${y}px`;

    // mode chips
    const modesEl = panelEl.querySelector(".sl-modes");
    for (const m of MODES) {
      const chip = document.createElement("button");
      chip.className = "sl-chip";
      chip.dataset.mode = m.id;
      chip.title = m.title;
      chip.textContent = m.label;
      chip.addEventListener("click", () => runMode(m.id));
      modesEl.appendChild(chip);
    }

    panelEl.querySelector('[data-act="close"]').addEventListener("click", closePanel);
    panelEl.querySelector('[data-act="settings"]').addEventListener("click", () => {
      chrome.runtime.sendMessage({ type: "open-options" });
    });
    let copyTimer = null;
    panelEl.querySelector('[data-act="copy"]').addEventListener("click", async (e) => {
      const btn = e.currentTarget;
      const out = cache.get(currentMode) || streamBuffer;
      if (!out) return;
      if (await copyText(out)) {
        btn.textContent = "✓ تم النسخ";
        clearTimeout(copyTimer);
        copyTimer = setTimeout(() => { if (panelEl) btn.textContent = "📋 نسخ"; }, 1500);
      }
    });
    panelEl.querySelector('[data-act="retry"]').addEventListener("click", () => {
      if (currentMode) { cache.delete(currentMode); runMode(currentMode, true); }
    });

    // drag by header
    const header = panelEl.querySelector(".sl-header");
    header.addEventListener("mousedown", (e) => {
      if (e.target.closest(".sl-iconbtn")) return;
      e.preventDefault();
      const startX = e.clientX - panelEl.offsetLeft;
      const startY = e.clientY - panelEl.offsetTop;
      const onMove = (ev) => {
        panelEl.style.left = `${Math.max(0, ev.clientX - startX)}px`;
        panelEl.style.top = `${Math.max(0, ev.clientY - startY)}px`;
      };
      const onUp = () => {
        document.removeEventListener("mousemove", onMove);
        document.removeEventListener("mouseup", onUp);
      };
      document.addEventListener("mousemove", onMove);
      document.addEventListener("mouseup", onUp);
    });
    panelEl.addEventListener("mousedown", (e) => e.stopPropagation());

    runMode(settings.defaultMode || "translate");
  }

  function setActiveChip(mode) {
    if (!panelEl) return;
    panelEl.querySelectorAll(".sl-chip").forEach((c) => {
      c.classList.toggle("active", c.dataset.mode === mode);
    });
  }

  function bodyEl() {
    return panelEl ? panelEl.querySelector(".sl-body") : null;
  }

  function runMode(mode, force = false) {
    if (!panelEl) return;
    cancelStreamFrame();
    currentMode = mode;
    setActiveChip(mode);
    const body = bodyEl();

    if (!force && cache.has(mode)) {
      body.innerHTML = renderMarkdown(cache.get(mode));
      return;
    }

    streamBuffer = "";
    body.innerHTML = `<div class="sl-loading"><span></span><span></span><span></span></div>`;

    const requestId = `req-${++requestSeq}`;
    activeRequestId = requestId;
    getPort().postMessage({
      type: "generate",
      requestId,
      mode,
      text: currentText,
      pageTitle: document.title,
      pageUrl: location.href,
      force: Boolean(force),
    });
  }

  function onPortMessage(msg) {
    if (msg.requestId !== activeRequestId || !panelEl) return;
    const body = bodyEl();
    if (msg.type === "delta") {
      const isFirstChunk = streamBuffer.length === 0;
      streamBuffer += msg.text;
      if (isFirstChunk) {
        // Render the very first delta immediately for minimum perceived TTFT.
        body.innerHTML = renderMarkdown(streamBuffer);
        body.scrollTop = body.scrollHeight;
      } else if (rafId === null) {
        rafId = requestAnimationFrame(() => {
          rafId = null;
          const b = bodyEl();
          if (!b) return;
          b.innerHTML = renderMarkdown(streamBuffer);
          b.scrollTop = b.scrollHeight;
        });
      }
    } else if (msg.type === "done") {
      cancelStreamFrame();
      if (body && streamBuffer) {
        body.innerHTML = renderMarkdown(streamBuffer);
        body.scrollTop = body.scrollHeight;
      }
      cache.set(currentMode, streamBuffer);
      activeRequestId = null;
    } else if (msg.type === "error") {
      cancelStreamFrame();
      body.innerHTML = `<div class="sl-error">${escapeHtml(msg.message)}</div>`;
      activeRequestId = null;
    }
  }

  // ---------- selection handling ----------
  function readCurrentSelection(fallbackPoint) {
    const active = document.activeElement;
    if (
      active &&
      (active.tagName === "TEXTAREA" || (active.tagName === "INPUT" && active.type !== "password")) &&
      typeof active.selectionStart === "number" &&
      active.selectionStart !== active.selectionEnd
    ) {
      const text = active.value.slice(active.selectionStart, active.selectionEnd).trim();
      const box = active.getBoundingClientRect();
      const rect = fallbackPoint
        ? { left: fallbackPoint.x, top: fallbackPoint.y - 8, bottom: fallbackPoint.y + 8, width: 1, height: 16 }
        : box;
      return { text, rect };
    }
    const sel = window.getSelection();
    const text = sel ? sel.toString().trim() : "";
    let rect = sel && sel.rangeCount ? sel.getRangeAt(0).getBoundingClientRect() : null;
    if (rect && rect.width === 0 && rect.height === 0 && fallbackPoint) {
      rect = { left: fallbackPoint.x, top: fallbackPoint.y - 8, bottom: fallbackPoint.y + 8, width: 1, height: 16 };
    }
    return { text, rect };
  }

  document.addEventListener("mouseup", (e) => {
    if (!settings.enabled) return;
    if (e.composedPath().includes(host)) return;
    const pt = { x: e.clientX, y: e.clientY };
    setTimeout(() => {
      const { text, rect } = readCurrentSelection(pt);
      if (text.length >= 3 && text.length <= MAX_CHARS && rect) {
        currentText = text;
        showBtn(rect);
      } else {
        removeBtn();
      }
    }, 10);
  });

  document.addEventListener("mousedown", (e) => {
    if (e.composedPath().includes(host)) return;
    removeBtn();
    if (panelEl) closePanel();
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { removeBtn(); closePanel(); }
  });

  window.addEventListener("scroll", removeBtn, { passive: true });

  // entry from context menu / keyboard command
  chrome.runtime.onMessage.addListener((msg) => {
    if (msg.type === "open-panel") {
      const { text: selected, rect } = readCurrentSelection(null);
      const text = selected || currentText;
      if (text && text.length <= MAX_CHARS) {
        openPanel(text, rect && (rect.width > 0 || rect.height > 0) ? rect : null);
      }
    }
  });
})();

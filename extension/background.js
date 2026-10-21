// ScreenLocalizer — background service worker
// Handles OpenAI API calls (streaming) and context-menu / keyboard entry points.

const OPENAI_URL = "https://api.openai.com/v1/chat/completions";
const DEFAULT_MODEL = "gpt-5-mini";

// Reasoning models (GPT-5 family, o-series) reject `temperature`; give them minimal reasoning for speed.
function tuningFor(model) {
  const name = (model || "").toLowerCase();
  const reasoning = /^(gpt-5|gpt-6|o1|o3|o4)/.test(name);
  if (!reasoning) return { temperature: 0.3 };
  return name.includes("chat") ? {} : { reasoning_effort: "minimal" };
}

function looksLikeParameterError(body) {
  return /temperature|reasoning|unsupported|unrecognized|not supported|unknown parameter|invalid value/i.test(body);
}

const MODE_PROMPTS = {
  translate: (lang) =>
    `You are a professional translator working inside a browser extension used by tech content creators.
Translate the user's text into ${lang}.
Rules:
- Be faithful and natural; professional written ${lang} (for Arabic: الفصحى الواضحة، ليست لهجة).
- Keep product names, model names, code, CLI commands, and well-established technical terms in English when that reads more naturally; you may add a short ${lang} gloss in parentheses the first time a term appears.
- Preserve the structure of the original (paragraphs, lists, headings).
- Output ONLY the translation. No preamble, no notes.`,

  explain: (lang) =>
    `You are an assistant inside a browser extension used by a tech content creator who presents to a ${lang}-speaking audience.
Do NOT translate the text literally. Instead, EXPLAIN it in ${lang}: what it means, what's new or important, and why the audience should care — as if the creator is explaining it on camera.
Rules:
- Clear, simple ${lang}; short paragraphs or bullet points.
- Keep technical terms, product and model names in English, with a brief ${lang} gloss in parentheses on first mention.
- If the text contains numbers, benchmarks, or comparisons, spell out what they actually mean in practice.
- No preamble like "this text talks about"; dive straight into the explanation.`,

  simplify: (lang) =>
    `You are an assistant inside a browser extension. Explain the user's text in very simple ${lang}, as if to a smart beginner with no technical background.
Rules:
- Use everyday words and, when helpful, one short real-world analogy.
- Keep it under ~150 words.
- Keep unavoidable technical terms in English with a simple ${lang} explanation in parentheses.
- No preamble; start directly.`,

  summarize: (lang) =>
    `You are an assistant inside a browser extension. Summarize the user's text in ${lang}.
Rules:
- Output 3–6 concise bullet points (use "- " bullets), most important first.
- Keep technical terms and product names in English where natural.
- No preamble, no closing sentence — bullets only.`,
};

function buildMessages(mode, text, pageTitle, pageUrl, settings) {
  const lang = settings.targetLanguage || "Arabic";
  const promptFn = MODE_PROMPTS[mode] || MODE_PROMPTS.translate;
  let system = promptFn(lang);
  if (settings.customInstructions) {
    system += `\n\nAdditional user preferences:\n${settings.customInstructions}`;
  }
  let user = "";
  if (pageTitle || pageUrl) {
    user += `Context — the text below was selected on this web page:\nTitle: ${pageTitle || "(unknown)"}\nURL: ${pageUrl || "(unknown)"}\n\n`;
  }
  user += `Text:\n"""\n${text}\n"""`;
  return [
    { role: "system", content: system },
    { role: "user", content: user },
  ];
}

async function getSettings() {
  const sync = await chrome.storage.sync.get({
    targetLanguage: "Arabic",
    model: DEFAULT_MODEL,
    customInstructions: "",
    enabled: true,
    defaultMode: "translate",
  });
  const local = await chrome.storage.local.get({ apiKey: "" });
  return { ...sync, apiKey: local.apiKey };
}

function friendlyError(status, body) {
  let apiMessage = "";
  try {
    apiMessage = JSON.parse(body)?.error?.message || "";
  } catch (_) {}
  if (status === 401)
    return "مفتاح OpenAI غير صحيح أو منتهي. افتح الإعدادات وتأكد من المفتاح.\n(Invalid API key — check it in Settings.)";
  if (status === 429)
    return "تم تجاوز حد الاستخدام أو الرصيد غير كافٍ في حساب OpenAI.\n(Rate limit or quota exceeded.)" + (apiMessage ? `\n${apiMessage}` : "");
  if (status === 404)
    return "اسم الموديل غير صحيح. تأكد من اسم الموديل في الإعدادات.\n(Model not found — check the model name in Settings.)";
  return `خطأ من OpenAI (HTTP ${status}).` + (apiMessage ? `\n${apiMessage}` : "");
}

async function streamCompletion(port, request, signal) {
  const { mode, text, pageTitle, pageUrl, requestId } = request;
  const settings = await getSettings();

  if (!settings.apiKey) {
    port.postMessage({
      type: "error",
      requestId,
      needsKey: true,
      message:
        "لم تقم بإضافة مفتاح OpenAI بعد. اضغط على أيقونة الإضافة ثم «الإعدادات» لإضافته.\n(No API key set — add it in the extension settings.)",
    });
    return;
  }

  const model = settings.model || DEFAULT_MODEL;
  const messages = buildMessages(mode, text, pageTitle, pageUrl, settings);
  const send = (tuned) =>
    fetch(OPENAI_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${settings.apiKey}`,
      },
      body: JSON.stringify({ model, stream: true, messages, ...(tuned ? tuningFor(model) : {}) }),
      signal,
    });

  let res;
  try {
    res = await send(true);
    if (res.status === 400) {
      const body = await res.clone().text().catch(() => "");
      // Some models reject temperature / reasoning settings; retry once without them.
      if (looksLikeParameterError(body)) res = await send(false);
    }
  } catch (e) {
    if (e.name === "AbortError") return;
    port.postMessage({
      type: "error",
      requestId,
      message: "تعذّر الاتصال بـ OpenAI. تحقق من اتصال الإنترنت.\n(Network error reaching OpenAI.)",
    });
    return;
  }

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    port.postMessage({ type: "error", requestId, message: friendlyError(res.status, body) });
    return;
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop(); // keep incomplete line in buffer
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("data:")) continue;
        const data = trimmed.slice(5).trim();
        if (data === "[DONE]") continue;
        try {
          const delta = JSON.parse(data)?.choices?.[0]?.delta?.content;
          if (delta) port.postMessage({ type: "delta", requestId, text: delta });
        } catch (_) {
          // ignore malformed chunks
        }
      }
    }
    port.postMessage({ type: "done", requestId });
  } catch (e) {
    if (e.name !== "AbortError") {
      port.postMessage({
        type: "error",
        requestId,
        message: "انقطع الاتصال أثناء استلام الرد. حاول مرة أخرى.\n(Connection dropped while streaming — try again.)",
      });
    }
  }
}

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "screenlocalizer") return;
  let controller = null;

  port.onMessage.addListener((msg) => {
    if (msg.type === "generate") {
      if (controller) controller.abort();
      controller = new AbortController();
      streamCompletion(port, msg, controller.signal).catch(() => {});
    } else if (msg.type === "abort") {
      if (controller) controller.abort();
      controller = null;
    }
  });

  port.onDisconnect.addListener(() => {
    if (controller) controller.abort();
    controller = null;
  });
});

// One-off messages: open options (from content script), API key test (from options page).
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === "open-options") {
    chrome.runtime.openOptionsPage();
    return;
  }
  if (msg.type === "test-key") {
    fetch("https://api.openai.com/v1/models", {
      headers: { Authorization: `Bearer ${msg.apiKey}` },
    })
      .then((r) => sendResponse({ ok: r.ok, status: r.status }))
      .catch(() => sendResponse({ ok: false, status: 0 }));
    return true; // async response
  }
});

function openPanelInTab(tab) {
  if (!tab?.id) return;
  chrome.tabs.sendMessage(tab.id, { type: "open-panel" }).catch(() => {});
}

chrome.runtime.onInstalled.addListener((details) => {
  chrome.contextMenus.create({
    id: "screenlocalizer-open",
    title: "ScreenLocalizer: ترجم أو اشرح «%s»",
    contexts: ["selection"],
  });
  if (details.reason === "install") {
    chrome.runtime.openOptionsPage();
  }
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "screenlocalizer-open") openPanelInTab(tab);
});

chrome.commands.onCommand.addListener((command, tab) => {
  if (command === "open-panel") openPanelInTab(tab);
});

// ScreenLocalizer — options page logic

const $ = (id) => document.getElementById(id);
const statusEl = $("status");

function setStatus(text, cls) {
  statusEl.textContent = text;
  statusEl.className = cls || "";
  if (text) setTimeout(() => { statusEl.textContent = ""; statusEl.className = ""; }, 4000);
}

async function load() {
  const sync = await chrome.storage.sync.get({
    targetLanguage: "Arabic",
    model: "gpt-5-mini",
    customInstructions: "",
    enabled: true,
    defaultMode: "translate",
  });
  const local = await chrome.storage.local.get({ apiKey: "" });
  $("apiKey").value = local.apiKey;
  $("model").value = sync.model;
  $("targetLanguage").value = sync.targetLanguage;
  $("defaultMode").value = sync.defaultMode;
  $("customInstructions").value = sync.customInstructions;
  $("enabled").checked = sync.enabled;
}

async function save() {
  const apiKey = $("apiKey").value.trim();
  await chrome.storage.local.set({ apiKey });
  await chrome.storage.sync.set({
    model: $("model").value.trim() || "gpt-5-mini",
    targetLanguage: $("targetLanguage").value.trim() || "Arabic",
    defaultMode: $("defaultMode").value,
    customInstructions: $("customInstructions").value.trim(),
    enabled: $("enabled").checked,
  });
  setStatus("✓ تم الحفظ", "ok");
}

async function testKey() {
  const apiKey = $("apiKey").value.trim();
  if (!apiKey) { setStatus("أدخل المفتاح أولًا", "err"); return; }
  setStatus("جارٍ الاختبار…", "");
  const res = await chrome.runtime.sendMessage({ type: "test-key", apiKey });
  if (res && res.ok) setStatus("✓ المفتاح يعمل", "ok");
  else if (res && res.status === 401) setStatus("✗ المفتاح غير صحيح", "err");
  else setStatus("✗ تعذّر الاتصال بـ OpenAI", "err");
}

$("save").addEventListener("click", save);
$("test").addEventListener("click", testKey);
$("toggleKey").addEventListener("click", () => {
  const input = $("apiKey");
  input.type = input.type === "password" ? "text" : "password";
});

load();

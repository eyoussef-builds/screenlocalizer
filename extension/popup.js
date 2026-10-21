// ScreenLocalizer — toolbar popup logic

const keyStatus = document.getElementById("keyStatus");
const enabledEl = document.getElementById("enabled");

chrome.storage.local.get({ apiKey: "" }, ({ apiKey }) => {
  if (apiKey) {
    keyStatus.textContent = "✓ مفتاح OpenAI مُضاف";
    keyStatus.className = "status ok";
  } else {
    keyStatus.textContent = "⚠ أضف مفتاح OpenAI من الإعدادات";
    keyStatus.className = "status warn";
  }
});

chrome.storage.sync.get({ enabled: true }, ({ enabled }) => {
  enabledEl.checked = enabled;
});

enabledEl.addEventListener("change", () => {
  chrome.storage.sync.set({ enabled: enabledEl.checked });
});

document.getElementById("openOptions").addEventListener("click", () => {
  chrome.runtime.openOptionsPage();
});

const CORE = "http://127.0.0.1:1380";
let geminiTabId = null;
let pollRunning = false;
let bridgeWindowId = null;
const BRIDGE_URL = "https://gemini.google.com/app?delegator_bridge=1";
const activatingTabs = new Set();
const debuggerTabs = new Set();

function isBridgeTab(tab) {
  if (!tab?.url) return false;
  try {
    const url = new URL(tab.url);
    return url.origin === "https://gemini.google.com"
      && url.pathname.startsWith("/app")
      && url.searchParams.get("delegator_bridge") === "1";
  } catch {
    return false;
  }
}

async function activateBridgeTab(tabId) {
  if (activatingTabs.has(tabId)) return;
  activatingTabs.add(tabId);
  geminiTabId = tabId;
  try {
    try {
      // Re-inject on worker restarts and missed static injection; content.js guards duplicates.
      await chrome.scripting.executeScript({ target: { tabId }, files: ["content.js"] });
      startPolling();
    } catch (error) {
      console.warn("Не удалось подключить вкладку Gemini к Delegator:", error);
    }
  } finally {
    activatingTabs.delete(tabId);
  }
}


// The bridge tab is owned by the extension: it is opened when Delegator asks
// for Gemini Web (setting on, Delegator active, Core running) and closed when
// that stops being true, so nothing here needs a manual step.
async function coreWantsBridge() {
  try {
    const response = await fetch(`${CORE}/api/gemini-web/state`, { cache: "no-store" });
    if (!response.ok) return false;
    return Boolean((await response.json()).wanted);
  } catch {
    return false;
  }
}

async function findBridgeTab() {
  const tabs = await chrome.tabs.query({ url: "https://gemini.google.com/*" });
  return tabs.find(isBridgeTab) || null;
}

async function syncBridge() {
  try {
    const wanted = await coreWantsBridge();
    const tab = await findBridgeTab();
    if (wanted && !tab) {
      const created = await chrome.windows.create({
        url: BRIDGE_URL, focused: false, state: "minimized",
      });
      bridgeWindowId = created.id ?? null;
    } else if (wanted && tab?.id != null) {
      if (geminiTabId !== tab.id) await activateBridgeTab(tab.id);
      else startPolling();
    } else if (!wanted && tab?.id != null && tab.windowId === bridgeWindowId) {
      await chrome.windows.remove(tab.windowId);
      bridgeWindowId = null;
      geminiTabId = null;
    }
  } catch (error) {
    console.warn("Не удалось синхронизировать вкладку Gemini:", error);
  }
}

chrome.alarms.create("delegator-sync", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "delegator-sync") void syncBridge();
});
chrome.runtime.onStartup.addListener(() => void syncBridge());
chrome.runtime.onInstalled.addListener(() => void syncBridge());

async function setBridgeWindowVisible(visible) {
  const tab = geminiTabId == null ? null : await chrome.tabs.get(geminiTabId).catch(() => null);
  if (!tab) return;
  // A minimized window can report a zero-size viewport; restore it for the
  // duration of a request without stealing focus, then minimize it again.
  await chrome.windows.update(tab.windowId, visible
    ? { state: "normal", focused: false, width: 1280, height: 900 }
    : { state: "minimized" });
}

async function handleDebuggerInput(message, sender) {
  const tabId = sender.tab?.id;
  if (tabId == null || !isBridgeTab(sender.tab)) {
    throw new Error("Отладочный ввод разрешён только во вкладке Gemini Bridge.");
  }

  if (message.action === "begin") {
    if (!debuggerTabs.has(tabId)) {
      await chrome.debugger.attach({ tabId }, "1.3");
      debuggerTabs.add(tabId);
    }
    return { ok: true };
  }

  if (!debuggerTabs.has(tabId)) throw new Error("Отладочная сессия Gemini не подключена.");
  if (message.action === "end") {
    await chrome.debugger.detach({ tabId });
    debuggerTabs.delete(tabId);
    return { ok: true };
  }

  if (message.action === "click") {
    const x = Number(message.x);
    const y = Number(message.y);
    if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || y < 0 || x > 10000 || y > 10000) {
      throw new Error("Некорректные координаты управления Gemini.");
    }
    await chrome.debugger.sendCommand({ tabId }, "Input.dispatchMouseEvent", {
      type: "mousePressed", x, y, button: "left", buttons: 1, clickCount: 1,
    });
    await chrome.debugger.sendCommand({ tabId }, "Input.dispatchMouseEvent", {
      type: "mouseReleased", x, y, button: "left", buttons: 0, clickCount: 1,
    });
    return { ok: true };
  }

  if (message.action === "key") {
    const keyInfo = {
      Enter: { code: "Enter", virtualKey: 13 },
      ArrowRight: { code: "ArrowRight", virtualKey: 39 },
      ArrowDown: { code: "ArrowDown", virtualKey: 40 },
      ArrowUp: { code: "ArrowUp", virtualKey: 38 },
      Home: { code: "Home", virtualKey: 36 },
      Escape: { code: "Escape", virtualKey: 27 },
    }[message.key];
    if (!keyInfo) throw new Error("Недопустимая клавиша для управления Gemini.");
    const common = {
      key: message.key,
      code: keyInfo.code,
      windowsVirtualKeyCode: keyInfo.virtualKey,
      nativeVirtualKeyCode: keyInfo.virtualKey,
    };
    await chrome.debugger.sendCommand({ tabId }, "Input.dispatchKeyEvent", { ...common, type: "keyDown" });
    await chrome.debugger.sendCommand({ tabId }, "Input.dispatchKeyEvent", { ...common, type: "keyUp" });
    return { ok: true };
  }

  if (message.action === "text") {
    if (typeof message.text !== "string" || message.text.length > 200000) {
      throw new Error("Некорректный текст для ввода в Gemini.");
    }
    await chrome.debugger.sendCommand({ tabId }, "Input.insertText", { text: message.text });
    return { ok: true };
  }

  throw new Error("Неизвестная команда управления Gemini.");
}

chrome.debugger.onDetach.addListener(({ tabId }) => debuggerTabs.delete(tabId));

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "DELEGATOR_GEMINI_DEBUGGER") {
    void handleDebuggerInput(message, sender)
      .then(sendResponse)
      .catch((error) => sendResponse({ error: error instanceof Error ? error.message : String(error) }));
    return true;
  }

  if (message?.type === "DELEGATOR_GEMINI_WINDOW" && sender.tab?.id === geminiTabId) {
    void setBridgeWindowVisible(Boolean(message.visible))
      .then(() => sendResponse({ ok: true }))
      .catch(() => sendResponse({ ok: true }));
    return true;
  }

  if (message?.type === "DELEGATOR_GEMINI_READY" && sender.tab?.id != null) {
    void activateBridgeTab(sender.tab.id);
  } else if (message?.type === "DELEGATOR_GEMINI_CLOSED" && sender.tab?.id === geminiTabId) {
    geminiTabId = null;
    if (debuggerTabs.has(sender.tab.id)) {
      void chrome.debugger.detach({ tabId: sender.tab.id }).catch(() => {});
      debuggerTabs.delete(sender.tab.id);
    }
    void syncBridge();
  }
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (isBridgeTab(tab) && (changeInfo.status === "complete" || changeInfo.url)) {
    void activateBridgeTab(tabId);
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  if (tabId === geminiTabId) {
    geminiTabId = null;
    void syncBridge();
  }
});

function startPolling() {
  if (pollRunning) return;
  pollRunning = true;
  void pollQueue().finally(() => {
    pollRunning = false;
    if (geminiTabId != null) startPolling();
  });
}

void syncBridge();

async function pollQueue() {
  while (geminiTabId != null) {
    let task = null;
    try {
      const response = await fetch(`${CORE}/api/gemini-web/next`, { cache: "no-store" });
      if (response.status === 204) continue;
      if (!response.ok) throw new Error(`Delegator Core вернул HTTP ${response.status}`);
      task = await response.json();

      const tabId = geminiTabId;
      if (tabId == null) throw new Error("Вкладка Gemini закрыта.");
      const result = await chrome.tabs.sendMessage(tabId, {
        type: "DELEGATOR_GEMINI_RUN",
        task,
      });
      await fetch(`${CORE}/api/gemini-web/result`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          request_id: task.request_id,
          text: result?.text || "",
          error: result?.error || null,
        }),
      });
    } catch (error) {
      if (task?.request_id) {
        try {
          await fetch(`${CORE}/api/gemini-web/result`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              request_id: task.request_id,
              text: "",
              error: error instanceof Error ? error.message : String(error),
            }),
          });
        } catch {
          // The Core may have restarted; the pending chat turn will time out there.
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 1200));
    }
  }
}

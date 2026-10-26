const CORE = "http://127.0.0.1:1380";
let geminiTabId = null;
let pollRunning = false;
const GROUP_TITLE = "Delegator";
const BRIDGE_URL = "https://gemini.google.com/app?delegator_bridge=1";
const activatingTabs = new Set();
const debuggerTabs = new Set();
// Puter Web: its own tab (builder.puter.com), its own queue loop. See the Puter section at the end.
const PUTER_URL = "https://builder.puter.com/?delegator_bridge=1";
let puterTabId = null;
let puterPollRunning = false;
let puterSyncing = false;

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


// The bridge tab is owned by the extension: it is opened only while Delegator
// has work for Gemini Web (a request queued, in flight, or finished a minute
// ago) and closed when that stops, so an idle Delegator leaves nothing open.
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

// Puts the tab into the "Delegator" tab group of its window (created on demand).
async function groupBridgeTab(tab) {
  try {
    const groups = await chrome.tabGroups.query({ windowId: tab.windowId, title: GROUP_TITLE });
    const groupId = await chrome.tabs.group(groups.length
      ? { tabIds: tab.id, groupId: groups[0].id }
      : { tabIds: tab.id, createProperties: { windowId: tab.windowId } });
    if (!groups.length) await chrome.tabGroups.update(groupId, { title: GROUP_TITLE, color: "blue", collapsed: true });
  } catch (error) {
    console.warn("Не удалось добавить вкладку в группу Delegator:", error);
  }
}

async function openBridgeTab() {
  const windows = await chrome.windows.getAll({ windowTypes: ["normal"] });
  const host = windows.find((w) => w.state !== "minimized") || windows[0];
  let tab;
  if (host) {
    tab = await chrome.tabs.create({ url: BRIDGE_URL, active: false, windowId: host.id });
  } else {
    // No browser window at all: open a minimized one just for the task.
    const created = await chrome.windows.create({ url: BRIDGE_URL, focused: false, state: "minimized" });
    tab = created.tabs?.[0];
  }
  if (tab?.id != null) await groupBridgeTab(tab);
}

let syncing = false;
async function syncBridge() {
  if (syncing) return;
  syncing = true;
  try {
    const wanted = await coreWantsBridge();
    const tab = await findBridgeTab();
    if (wanted && !tab) {
      await openBridgeTab();
    } else if (wanted && tab?.id != null) {
      if (geminiTabId !== tab.id) await activateBridgeTab(tab.id);
      else startPolling();
    } else if (!wanted && tab?.id != null) {
      geminiTabId = null;
      await chrome.tabs.remove(tab.id);
    }
  } catch (error) {
    console.warn("Не удалось синхронизировать вкладку Gemini:", error);
  } finally {
    syncing = false;
  }
}

// Wakes the extension the moment Delegator gets (or finishes) Gemini work, even
// with no tab open. Also tells Core the extension is alive.
async function watchDemand() {
  let known = false;
  for (;;) {
    try {
      const response = await fetch(`${CORE}/api/gemini-web/wait?known=${known ? 1 : 0}`, { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const wanted = Boolean((await response.json()).wanted);
      if (wanted !== known) {
        known = wanted;
        await syncBridge();
      }
    } catch {
      known = false;
      await new Promise((resolve) => setTimeout(resolve, 3000));
    }
  }
}

chrome.alarms.create("delegator-sync", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "delegator-sync") {
    void syncBridge();
    void syncPuter();
  }
});
chrome.runtime.onStartup.addListener(() => {
  void syncBridge();
  void syncPuter();
});
// A page opened before this version has none of visible.js: reload it once so
// the new scripts apply (the window stays where it is, minimized).
chrome.runtime.onInstalled.addListener(async () => {
  const tab = await findBridgeTab().catch(() => null);
  if (tab?.id != null) await chrome.tabs.reload(tab.id).catch(() => {});
  void syncBridge();
});

async function setBridgeWindowVisible(visible, focus = false) {
  const tab = geminiTabId == null ? null : await chrome.tabs.get(geminiTabId).catch(() => null);
  if (!tab) return;
  // The bridge is a background tab in the user's own window: never resize it.
  // Only a window the extension made itself (it holds nothing but this tab) is toggled.
  const siblings = await chrome.tabs.query({ windowId: tab.windowId });
  if (siblings.length > 1) return;
  // A minimized window can report a zero-size viewport; restore it for the
  // duration of a request without stealing focus, then minimize it again.
  await chrome.windows.update(tab.windowId, visible
    ? { state: "normal", focused: focus, drawAttention: false, width: 1280, height: 900 }
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
      // A minimized window reports a stale or tiny viewport. Emulate a normal
      // one and "focus", so the page lays out and behaves as if in front -
      // without the window ever leaving the background.
      await chrome.debugger.sendCommand({ tabId }, "Emulation.setDeviceMetricsOverride", {
        width: 1280, height: 900, deviceScaleFactor: 1, mobile: false,
      }).catch(() => {});
      await chrome.debugger.sendCommand({ tabId }, "Emulation.setFocusEmulationEnabled", { enabled: true }).catch(() => {});
    }
    return { ok: true };
  }

  if (!debuggerTabs.has(tabId)) throw new Error("Отладочная сессия Gemini не подключена.");
  if (message.action === "end") {
    await chrome.debugger.sendCommand({ tabId }, "Emulation.clearDeviceMetricsOverride").catch(() => {});
    await chrome.debugger.sendCommand({ tabId }, "Emulation.setFocusEmulationEnabled", { enabled: false }).catch(() => {});
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

  if (message?.type === "DELEGATOR_GEMINI_PHASE" && sender.tab?.id === geminiTabId) {
    void fetch(`${CORE}/api/gemini-web/phase`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ phase: String(message.phase || "").slice(0, 300) }),
    }).catch(() => {});
    return;
  }

  if (message?.type === "DELEGATOR_GEMINI_WINDOW" && sender.tab?.id === geminiTabId) {
    void setBridgeWindowVisible(Boolean(message.visible), Boolean(message.focus))
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
  if (tabId === puterTabId) {
    puterTabId = null;
    void syncPuter();
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
void watchDemand();
void syncPuter();
void watchPuterDemand();

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
          used: result?.used || null,
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

// ---- Puter Web ---------------------------------------------------------------
// The same tab-and-queue idea as Gemini, without any DOM work: the builder.puter.com
// page owns a signed-in puter.js, and `puter.ai.chat` runs inside that page (MAIN
// world). The tab is open only while Delegator has Puter work, like the Gemini tab.

function isPuterBridgeTab(tab) {
  if (!tab?.url) return false;
  try {
    const url = new URL(tab.url);
    return url.origin === "https://builder.puter.com" && url.searchParams.get("delegator_bridge") === "1";
  } catch {
    return false;
  }
}

async function findPuterTab() {
  const tabs = await chrome.tabs.query({ url: "https://builder.puter.com/*" });
  return tabs.find(isPuterBridgeTab) || null;
}

async function coreWantsPuter() {
  try {
    const response = await fetch(`${CORE}/api/puter-web/state`, { cache: "no-store" });
    if (!response.ok) return false;
    return Boolean((await response.json()).wanted);
  } catch {
    return false;
  }
}

async function syncPuter() {
  if (puterSyncing) return;
  puterSyncing = true;
  try {
    const wanted = await coreWantsPuter();
    const tab = await findPuterTab();
    if (wanted && !tab) {
      const created = await chrome.tabs.create({ url: PUTER_URL, active: false });
      puterTabId = created.id ?? null;
      if (puterTabId != null) startPuterPolling();
    } else if (wanted && tab) {
      puterTabId = tab.id;
      startPuterPolling();
    } else if (!wanted && tab) {
      puterTabId = null;
      await chrome.tabs.remove(tab.id);
    }
  } catch (error) {
    console.warn("Не удалось синхронизировать вкладку Puter:", error);
  } finally {
    puterSyncing = false;
  }
}

async function waitTabComplete(tabId, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const tab = await chrome.tabs.get(tabId).catch(() => null);
    if (!tab) throw new Error("Вкладка Puter закрыта.");
    if (tab.status === "complete") return;
    if (Date.now() > deadline) throw new Error("Страница Puter не загрузилась.");
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
}

// Runs INSIDE the Puter page (MAIN world), so `puter` is that page's own signed-in SDK.
// chrome.scripting ships only this function's source: it must not use anything from this file.
async function askPuterInPage(text, model, maxWaitMs) {
  const fail = (error) => ({ error });
  const textOf = (value) => {
    if (typeof value === "string") return value;
    if (Array.isArray(value)) return value.map((part) => textOf(part?.text ?? part)).join("");
    return "";
  };
  let timer;
  const ceiling = new Promise((resolve) => {
    timer = setTimeout(() => resolve(fail(`Puter не ответил за ${Math.round(maxWaitMs / 1000)} с.`)), maxWaitMs);
  });
  const call = (async () => {
    try {
      if (typeof puter === "undefined" || typeof puter.ai?.chat !== "function") {
        return fail("Страница Puter не загрузила puter.js.");
      }
      if (typeof puter.auth?.isSignedIn === "function" && !(await puter.auth.isSignedIn())) {
        return fail("Вы не вошли в Puter в этом Chrome: войдите на builder.puter.com.");
      }
      const response = await puter.ai.chat(text, { model });
      const reply = typeof response === "string"
        ? response
        : textOf(response?.message?.content) || textOf(response?.text);
      return reply.trim() ? { text: reply } : fail("Puter вернул пустой ответ.");
    } catch (error) {
      return fail(`Puter: ${error?.message || String(error)}`);
    }
  })();
  try {
    return await Promise.race([call, ceiling]);
  } finally {
    clearTimeout(timer);
  }
}

async function runPuterTask(task) {
  const tabId = puterTabId;
  if (tabId == null) throw new Error("Вкладка Puter закрыта.");
  await waitTabComplete(tabId, 60000);
  const [injection] = await chrome.scripting.executeScript({
    target: { tabId },
    world: "MAIN",
    func: askPuterInPage,
    args: [task.text, task.model, Number(task.max_wait_ms) || 300000],
  });
  const reply = injection?.result;
  if (!reply) throw new Error("Puter не вернул результат.");
  if (reply.error) throw new Error(reply.error);
  return reply.text;
}

function postPuterResult(body) {
  return fetch(`${CORE}/api/puter-web/result`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function startPuterPolling() {
  if (puterPollRunning) return;
  puterPollRunning = true;
  void pollPuter().finally(() => {
    puterPollRunning = false;
    if (puterTabId != null) startPuterPolling();
  });
}

async function pollPuter() {
  while (puterTabId != null) {
    let task = null;
    try {
      const response = await fetch(`${CORE}/api/puter-web/next`, { cache: "no-store" });
      if (response.status === 204) continue;
      if (!response.ok) throw new Error(`Delegator Core вернул HTTP ${response.status}`);
      task = await response.json();
      const text = await runPuterTask(task);
      await postPuterResult({ request_id: task.request_id, text, error: null });
    } catch (error) {
      if (task?.request_id) {
        await postPuterResult({
          request_id: task.request_id,
          text: "",
          error: error instanceof Error ? error.message : String(error),
        }).catch(() => {});
      }
      await new Promise((resolve) => setTimeout(resolve, 1200));
    }
  }
}

// Wakes the extension when Delegator gets (or finishes) Puter work, even with no tab open.
async function watchPuterDemand() {
  let known = false;
  for (;;) {
    try {
      const response = await fetch(`${CORE}/api/puter-web/wait?known=${known ? 1 : 0}`, { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const wanted = Boolean((await response.json()).wanted);
      if (wanted !== known) {
        known = wanted;
        await syncPuter();
      }
    } catch {
      known = false;
      await new Promise((resolve) => setTimeout(resolve, 3000));
    }
  }
}

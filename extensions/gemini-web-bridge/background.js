const CORE = "http://127.0.0.1:1380";
let geminiTabId = null;
let pollRunning = false;
const GROUP_TITLE = "Delegator";
const BRIDGE_URL = "https://gemini.google.com/app?delegator_bridge=1";
const activatingTabs = new Set();
const debuggerTabs = new Set();
// The other web doors share one mechanism: see the section at the end of this file.
const DOORS = {
  gemini: { label: "Gemini", url: "https://gemini.google.com/app", hosts: ["gemini.google.com"] },
  aistudio: { label: "AI Studio", url: "https://aistudio.google.com/prompts/new_chat", hosts: ["aistudio.google.com"], driven: true },
  kimi: { label: "Kimi", url: "https://www.kimi.ai/", hosts: ["www.kimi.ai", "kimi.ai"], driven: true },
  zai: { label: "Z.ai", url: "https://chat.z.ai/", hosts: ["chat.z.ai"], driven: true },
  qwen: { label: "Qwen", url: "https://chat.qwen.ai/", hosts: ["chat.qwen.ai"], driven: true },
  deepseek: { label: "DeepSeek", url: "https://chat.deepseek.com/", hosts: ["chat.deepseek.com"], driven: true },
  tencent: { label: "Tencent Hy", url: "https://aistudio.tencent.ai/", hosts: ["aistudio.tencent.ai"], driven: true },
  rudder: { label: "Rudder", url: "https://rudder.chat/chat", hosts: ["rudder.chat"], driven: true },
};
const doorTabs = new Map();
const doorQueues = new Map();
const doorsRunning = new Set();
let doorsSyncing = false;

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
    void syncDoors();
  }
});
chrome.runtime.onStartup.addListener(() => {
  void syncBridge();
  void syncDoors();
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

async function handleDebuggerInput(message, sender, door = false) {
  const tabId = sender.tab?.id;
  const allowed = door ? [...doorTabs.values()].includes(tabId) : isBridgeTab(sender.tab);
  if (tabId == null || !allowed) {
    throw new Error("Отладочный ввод разрешён только во вкладках Delegator.");
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
  if (message?.type === "DELEGATOR_DOOR_PHASE") {
    reportDoorPhase(message.door, message.phase);
    return;
  }

  if (message?.type === "DELEGATOR_DOOR_DEBUGGER") {
    void handleDebuggerInput(message, sender, true)
      .then(sendResponse)
      .catch((error) => sendResponse({ error: error instanceof Error ? error.message : String(error) }));
    return true;
  }

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
  for (const [door, id] of doorTabs) {
    if (id === tabId) {
      doorTabs.delete(door);
      void syncDoors();
    }
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
void syncDoors();
void watchDoors();

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
      // Another door may win while Gemini still thinks: stop rather than spend its quota on a dead turn.
      const liveness = setInterval(() => {
        fetch(`${CORE}/api/web-door/gemini/live?id=${encodeURIComponent(task.request_id)}`, { cache: "no-store" })
          .then((response) => response.json())
          .then(({ live }) => {
            if (!live) chrome.tabs.sendMessage(tabId, { type: "DELEGATOR_GEMINI_ABORT" }).catch(() => {});
          })
          .catch(() => {});
      }, 3000);
      const result = await chrome.tabs.sendMessage(tabId, {
        type: "DELEGATOR_GEMINI_RUN",
        task,
      }).finally(() => clearInterval(liveness));
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

// ---- Web doors ---------------------------------------------------------------
// One background tab per enabled site, open only while Delegator has work for it (like the Gemini
// tab), and a queue loop per tab. door.js does the page work. Every turn starts from the site's
// front page, so no earlier conversation leaks into it.

function hostOf(tab) {
  try {
    return new URL(tab.url).hostname;
  } catch {
    return "";
  }
}

function doorPatterns(door) {
  return DOORS[door].hosts.map((host) => `https://${host}/*`);
}

// A bridge tab marks itself in sessionStorage (visible.js), which outlives a service worker restart
// and a site's own redirects, where a URL parameter does not.
async function findDoorTab(door) {
  const known = doorTabs.get(door);
  if (known != null) {
    const tab = await chrome.tabs.get(known).catch(() => null);
    if (tab) return tab;
    doorTabs.delete(door);
  }
  for (const tab of await chrome.tabs.query({ url: doorPatterns(door) })) {
    const [probe] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => sessionStorage.getItem("delegatorBridge"),
    }).catch(() => [null]);
    if (probe?.result === "1") return tab;
  }
  return null;
}

async function syncDoors(wanted = null) {
  if (doorsSyncing) return;
  doorsSyncing = true;
  try {
    const list = wanted ?? await coreWantedDoors();
    for (const door of Object.keys(DOORS).filter((id) => DOORS[id].driven)) {
      const tab = await findDoorTab(door);
      // Opening is the turn's job (ensureDoorTab): this only closes what nothing wants any more.
      if (list.includes(door) && tab) {
        doorTabs.set(door, tab.id);
      } else if (!list.includes(door) && tab && !doorsRunning.has(door) && !doorQueues.get(door)?.length) {
        doorTabs.delete(door);
        await chrome.tabs.remove(tab.id).catch(() => {});
      }
    }
  } catch (error) {
    console.warn("Не удалось синхронизировать вкладки Web:", error);
  } finally {
    doorsSyncing = false;
  }
}

function bridgeUrl(door) {
  const url = new URL(DOORS[door].url);
  url.searchParams.set("delegator_bridge", "1");
  return url.href;
}

async function coreWantedDoors() {
  try {
    const response = await fetch(`${CORE}/api/web/doors`, { cache: "no-store" });
    if (!response.ok) return [];
    return (await response.json()).wanted || [];
  } catch {
    return [];
  }
}

function waitTabLoaded(tabId, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      chrome.tabs.onUpdated.removeListener(listener);
      reject(new Error("Страница не загрузилась."));
    }, timeoutMs);
    const finish = () => {
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(listener);
      resolve();
    };
    const listener = (id, info) => {
      if (id === tabId && info.status === "complete") finish();
    };
    chrome.tabs.onUpdated.addListener(listener);
    chrome.tabs.get(tabId).then((tab) => {
      if (tab.status === "complete") finish();
    }).catch(() => {});
  });
}

function reportDoorPhase(door, phase) {
  void fetch(`${CORE}/api/web-door/${door}/phase`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ phase: String(phase || "").slice(0, 300) }),
  }).catch(() => {});
}

// The loop's long poll outlives a closed tab: a turn can arrive just after the linger closed it, and
// that turn must get a new tab rather than an error.
async function ensureDoorTab(door) {
  const known = await findDoorTab(door);
  if (known?.id != null) {
    doorTabs.set(door, known.id);
    return known.id;
  }
  const created = await chrome.tabs.create({ url: bridgeUrl(door), active: false });
  doorTabs.set(door, created.id);
  await groupBridgeTab(created);
  return created.id;
}

async function runDoorTurn(door, task) {
  const tabId = await ensureDoorTab(door);
  reportDoorPhase(door, "загрузка страницы");
  await chrome.tabs.update(tabId, { url: bridgeUrl(door) });
  await new Promise((resolve) => setTimeout(resolve, 500));
  await waitTabLoaded(tabId);
  reportDoorPhase(door, "подключение драйвера");
  await chrome.scripting.executeScript({ target: { tabId }, files: ["door.js"] });
  // Another door may win while this one still thinks: tell the page to stop rather than let a dead
  // turn hold the tab and spend the site's quota.
  const liveness = setInterval(() => {
    fetch(`${CORE}/api/web-door/${door}/live?id=${encodeURIComponent(task.request_id)}`, { cache: "no-store" })
      .then((response) => response.json())
      .then(({ live }) => {
        if (!live) chrome.tabs.sendMessage(tabId, { type: "DELEGATOR_DOOR_ABORT" }).catch(() => {});
      })
      .catch(() => {});
  }, 3000);
  try {
    return await chrome.tabs.sendMessage(tabId, { type: "DELEGATOR_DOOR_RUN", door, label: DOORS[door].label, task });
  } finally {
    clearInterval(liveness);
    if (debuggerTabs.has(tabId)) {
      await chrome.debugger.detach({ tabId }).catch(() => {});
      debuggerTabs.delete(tabId);
    }
  }
}

async function postDoorResult(door, body) {
  await fetch(`${CORE}/api/web-door/${door}/result`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

// One turn at a time per tab; the poll hands turns over, and only short requests happen here.
function enqueueTurn(door, task) {
  if (!doorQueues.has(door)) doorQueues.set(door, []);
  doorQueues.get(door).push(task);
  void drainDoor(door);
}

async function drainDoor(door) {
  if (doorsRunning.has(door)) return;
  doorsRunning.add(door);
  try {
    const queue = doorQueues.get(door) || [];
    while (queue.length) {
      const task = queue.shift();
      try {
        // A turn can die waiting behind the one before it: never send it to the site then.
        const live = await fetch(`${CORE}/api/web-door/${door}/live?id=${encodeURIComponent(task.request_id)}`, { cache: "no-store" })
          .then((response) => response.json()).then((reply) => reply.live).catch(() => true);
        if (!live) continue;
        reportDoorPhase(door, "запрос получен");
        const result = await runDoorTurn(door, task);
        await postDoorResult(door, {
          request_id: task.request_id,
          text: result?.text || "",
          error: result?.error || null,
          used: result?.used || null,
        });
      } catch (error) {
        await postDoorResult(door, {
          request_id: task.request_id,
          text: "",
          error: error instanceof Error ? error.message : String(error),
        }).catch(() => {});
      }
    }
  } finally {
    doorsRunning.delete(door);
  }
}

// ---- «Войти» -----------------------------------------------------------------
// The GUI asks, the core passes it here: the site opens in front, the user signs in the usual way,
// and the sign-in is confirmed by what the PAGE shows, not by the click. Nothing is read but the
// page's own buttons, and no password, cookie or token ever passes through the extension.

function probeSignIn(door) {
  const shown = (element) => element.getClientRects().length > 0;
  const text = (element) => (element.getAttribute("aria-label") || element.innerText || "").replace(/\s+/g, " ").trim();
  if (/\/(sign_in|login|signin)/i.test(location.pathname)) return { state: "signed_out" };
  const controls = [...document.querySelectorAll("a,button,[role='button']")].filter(shown);
  if (controls.some((element) => /^(log ?in|sign ?in|sign ?up|войти|вход|登录|注册)$/i.test(text(element)))) {
    return { state: "signed_out" };
  }
  const composer = [...document.querySelectorAll("textarea,[contenteditable='true'],rich-textarea")].some(shown);
  if (!composer) return { state: "unknown" };
  const account = door === "gemini"
    ? (document.querySelector("a[aria-label*='@']")?.getAttribute("aria-label") || "")
    : "";
  return { state: "signed_in", label: account.replace(/\s+/g, " ").trim() };
}

function showSignedInToast(label) {
  const note = document.createElement("div");
  note.textContent = `Delegator: вход в ${label} подтверждён, вкладка сейчас закроется`;
  note.style.cssText = "position:fixed;top:16px;left:50%;transform:translateX(-50%);z-index:2147483647;"
    + "background:#1f7a3d;color:#fff;padding:10px 16px;border-radius:8px;font:14px sans-serif;box-shadow:0 2px 8px rgba(0,0,0,.4)";
  document.body.appendChild(note);
}

async function reportAuth(door, state, label = "") {
  await fetch(`${CORE}/api/web/auth`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ door, state, label }),
  }).catch(() => {});
}

const loginWatches = new Set();

async function openLogin(door) {
  const spec = DOORS[door];
  if (!spec || loginWatches.has(door)) return;
  loginWatches.add(door);
  try {
    const windows = await chrome.windows.getAll({ windowTypes: ["normal"] });
    const host = windows.find((entry) => entry.state !== "minimized") || windows[0];
    const tab = host
      ? await chrome.tabs.create({ url: spec.url, active: true, windowId: host.id })
      : (await chrome.windows.create({ url: spec.url, focused: true })).tabs[0];
    await chrome.windows.update(tab.windowId, { focused: true, drawAttention: true }).catch(() => {});
    await watchLogin(door, tab.id);
  } catch (error) {
    console.warn("Не удалось открыть страницу входа:", error);
    await reportAuth(door, "unknown");
  } finally {
    loginWatches.delete(door);
  }
}

// Ten minutes for a sign-in with a code from a phone. A sign-in page on another host (Google,
// Apple) is simply waited out; only the site itself can say that it let the user in.
async function watchLogin(door, tabId) {
  const deadline = Date.now() + 10 * 60 * 1000;
  let last = "signed_out";
  let signedInProbes = 0;
  while (Date.now() < deadline) {
    const tab = await chrome.tabs.get(tabId).catch(() => null);
    if (!tab) {
      await reportAuth(door, last === "signed_in" ? "signed_in" : "signed_out");
      return;
    }
    if (DOORS[door].hosts.includes(hostOf(tab)) && tab.status === "complete") {
      const [probe] = await chrome.scripting.executeScript({
        target: { tabId },
        func: probeSignIn,
        args: [door],
      }).catch(() => [null]);
      const result = probe?.result;
      signedInProbes = result?.state === "signed_in" ? signedInProbes + 1 : 0;
      if (signedInProbes >= 3) {
        await reportAuth(door, "signed_in", result.label || "");
        await chrome.scripting.executeScript({
          target: { tabId },
          func: showSignedInToast,
          args: [DOORS[door].label],
        }).catch(() => {});
        await new Promise((resolve) => setTimeout(resolve, 2500));
        await chrome.tabs.remove(tabId).catch(() => {});
        return;
      }
      if (result?.state) last = result.state;
    }
    await new Promise((resolve) => setTimeout(resolve, 1500));
  }
  await reportAuth(door, last);
}

// Chrome keeps running the old code of an unpacked extension after Delegator updates the files. One
// reload per shipped version: when this copy is loaded from another folder its version will never
// match, and an unconditional reload would loop forever.
async function reloadIfOutdated(shipped) {
  if (!shipped || shipped === chrome.runtime.getManifest().version) return;
  const { reloadedFor } = await chrome.storage.local.get("reloadedFor");
  if (reloadedFor === shipped) return;
  await chrome.storage.local.set({ reloadedFor: shipped });
  chrome.runtime.reload();
}

// Wakes the extension when Delegator gets (or finishes) work for a door, or when «Войти» is pressed.
// Also tells the core the extension is alive, whichever doors are switched on.
async function watchDoors() {
  let known = [];
  for (;;) {
    try {
      const response = await fetch(`${CORE}/api/web-door/wait?known=${encodeURIComponent(known.join(","))}`, { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const { wanted = [], login = [], turns = [], extension_version: shipped = "" } = await response.json();
      for (const door of login) void openLogin(door);
      for (const { door, ...task } of turns) enqueueTurn(door, task);
      // Reloading drops everything held in memory, so it waits for a moment with nothing in hand.
      if (!turns.length && !login.length && !doorsRunning.size && !loginWatches.size) await reloadIfOutdated(shipped);
      if (wanted.join(",") !== known.join(",")) {
        known = wanted;
        await syncDoors(wanted);
      }
    } catch {
      known = [];
      await new Promise((resolve) => setTimeout(resolve, 3000));
    }
  }
}

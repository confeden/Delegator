(() => {
  if (new URL(location.href).searchParams.get("delegator_bridge") !== "1") return;

  if (window.__delegatorGeminiBridgeLoaded) return;
  window.__delegatorGeminiBridgeLoaded = true;

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const visible = (element) => Boolean(element && element.getClientRects().length);
  const normalizedText = (element) => (element?.innerText || element?.textContent || "").replace(/\s+/g, " ").trim();
  let busy = false;

  function querySelectorAllDeep(selector) {
    const matches = [];
    const roots = [document];
    while (roots.length) {
      const root = roots.pop();
      matches.push(...root.querySelectorAll(selector));
      for (const element of root.querySelectorAll("*")) {
        if (element.shadowRoot) roots.push(element.shadowRoot);
      }
    }
    return matches;
  }

  function announceReady() {
    if (busy) return;
    chrome.runtime.sendMessage({ type: "DELEGATOR_GEMINI_READY" }).catch(() => {});
  }

  // Gemini renames and reorders its models, so everything is matched by the
  // visible text of the menu rows, never by their position or hashed ids.
  const MODEL_MATCHERS = {
    "gemini-web/3.5-flash-lite": (text) => /flash[\s-]*lite/i.test(text),
    "gemini-web/3.8-flash": (text) => /flash/i.test(text) && !/lite/i.test(text),
    "gemini-web/3.1-pro": (text) => /pro/i.test(text),
    "gemini-web/argon": (text) => /argon/i.test(text),
  };
  const REASONING_MATCHERS = {
    low: /^(низк|low)/i,
    medium: /^(средн|medium)/i,
    high: /^(высок|high)/i,
  };

  function modelIsSelected(model, label) {
    return Boolean(MODEL_MATCHERS[model]?.(label));
  }

  function findModelPicker() {
    return querySelectorAllDeep('[data-test-id="bard-mode-menu-button"],button,[role="button"]')
      .filter(visible)
      .find((element) => element.getAttribute("data-test-id") === "bard-mode-menu-button"
        || /^(Выбор режима|Select mode|Choose mode)/i.test(element.getAttribute("aria-label") || "")) || null;
  }

  function menuRows() {
    return querySelectorAllDeep('[role="menuitem"],[role="menuitemradio"],[role="option"]').filter(visible);
  }

  function findMenuRow(predicate) {
    return menuRows().find((row) => predicate(normalizedText(row))) || null;
  }

  let debuggerInputActive = false;

  async function debuggerInput(action, details = {}) {
    const result = await chrome.runtime.sendMessage({
      type: "DELEGATOR_GEMINI_DEBUGGER",
      action,
      ...details,
    });
    if (result?.error) throw new Error(result.error);
    return result;
  }

  async function trustedClick(element) {
    if (!element) throw new Error("Элемент управления Gemini не найден.");
    const rect = element.getBoundingClientRect();
    if (!rect.width || !rect.height) throw new Error("Элемент управления Gemini скрыт.");
    await debuggerInput("click", { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 });
  }

  async function trustedKey(element, key) {
    element?.focus?.();
    await debuggerInput("key", { key });
  }

  async function pressMenuKey(key) {
    await debuggerInput("key", { key });
  }

  async function startFreshChat() {
    const link = [...document.querySelectorAll('a[href*="/app"]')]
      .filter(visible)
      .find((element) => normalizedText(element) === "Новый чат");
    if (!link) throw new Error("Не найдена команда «Новый чат» в Gemini.");
    const url = new URL(link.href, location.href);
    url.searchParams.set("delegator_bridge", "1");
    link.href = url.href;
    await trustedClick(link);
    await waitFor(() => findComposer(), 10000, "Поле запроса Gemini не загрузилось.");
  }

  async function openModelMenu() {
    await pressMenuKey("Escape");
    await sleep(80);
    await trustedClick(findModelPicker());
    await waitFor(() => menuRows().length > 0, 4000, "Меню режимов Gemini не открылось.");
  }

  async function chooseModel(model) {
    const matches = MODEL_MATCHERS[model];
    if (!matches) throw new Error(`Неизвестная модель Gemini Web: ${model}`);
    const picker = findModelPicker();
    if (!picker) throw new Error("Не найден выбор модели Gemini.");
    if (modelIsSelected(model, picker.getAttribute("aria-label") || normalizedText(picker))) return;

    await openModelMenu();
    const row = findMenuRow((text) => !/^(уровень рассуждений|reasoning level)/i.test(text) && matches(text));
    if (!row) {
      const seen = menuRows().map(normalizedText).join(" | ");
      await pressMenuKey("Escape");
      throw new Error(`В меню Gemini нет модели ${model}. Сейчас доступно: ${seen || "ничего"}.`);
    }
    await trustedClick(row);
    await waitFor(
      () => modelIsSelected(model, findModelPicker()?.getAttribute("aria-label") || ""),
      5000,
      `Gemini не выбрал модель ${model}.`,
    );
  }

  async function chooseReasoning(reasoning) {
    if (!reasoning || reasoning === "auto") return;
    const wanted = REASONING_MATCHERS[reasoning];
    if (!wanted) throw new Error(`Неизвестный уровень рассуждений: ${reasoning}`);

    await openModelMenu();
    const parent = findMenuRow((text) => /уровень рассуждений|reasoning level/i.test(text));
    if (!parent) {
      // The picked model has no levels; the default is the only choice.
      await pressMenuKey("Escape");
      return;
    }
    await trustedClick(parent);
    await waitFor(() => findMenuRow((text) => wanted.test(text)), 4000, "Gemini не показал уровни рассуждений.");
    await trustedClick(findMenuRow((text) => wanted.test(text)));
    await sleep(250);
    await pressMenuKey("Escape");
  }

  function findComposer() {
    const candidates = [...document.querySelectorAll('[contenteditable="true"],textarea')]
      .filter(visible)
      .filter((element) => !element.classList.contains("ql-clipboard") && element.getAttribute("tabindex") !== "-1");
    const textboxes = candidates.filter((element) => element instanceof HTMLTextAreaElement || element.getAttribute("role") === "textbox");
    return textboxes.at(-1) || candidates.at(-1) || null;
  }

  async function waitFor(predicate, timeoutMs, errorText) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (predicate()) return;
      await sleep(100);
    }
    throw new Error(errorText);
  }

  function getAnswerNodes() {
    const responses = [...document.querySelectorAll("model-response")].filter(visible);
    if (responses.length) return responses;
    return [...document.querySelectorAll(".markdown-main-panel")].filter(visible);
  }

  function responseText(element) {
    const markdown = element.querySelector(".markdown-main-panel,.markdown");
    return (markdown?.innerText || element.innerText || "").trim();
  }

  function isGenerating() {
    return Boolean(document.querySelector(
      'button[aria-label*="Stop"],button[aria-label*="Останов"],[data-test-id*="stop-generating"]',
    ));
  }

  async function sendPrompt(text) {
    const composer = findComposer();
    if (!composer) throw new Error("Не найдено поле запроса. Убедитесь, что Gemini открыт и вы вошли в аккаунт.");
    composer.focus();
    await debuggerInput("text", { text });

    // Gemini enables and inserts the send control only after its composer state
    // has processed the input event. Looking for it synchronously can race the
    // framework update and a synthetic Enter key is not always handled.
    const sendDeadline = Date.now() + 5000;
    let sendButton = null;
    while (Date.now() < sendDeadline) {
      sendButton = [...document.querySelectorAll('button,[role="button"]')]
        .filter(visible)
        .find((element) => /отправить|send message/i.test(
          `${element.getAttribute("aria-label") || ""} ${element.getAttribute("title") || ""}`,
        ));
      if (sendButton && !sendButton.disabled && sendButton.getAttribute("aria-disabled") !== "true") break;
      sendButton = null;
      await sleep(100);
    }
    if (sendButton) await trustedClick(sendButton);
    else {
      await trustedKey(composer, "Enter");
    }
    await debuggerInput("end");
    debuggerInputActive = false;

    const deadline = Date.now() + 300000;
    let bestText = "";
    let changedAt = Date.now();
    while (Date.now() < deadline) {
      const answer = getAnswerNodes().map(responseText).filter(Boolean).at(-1) || "";
      if (answer !== bestText) {
        bestText = answer;
        changedAt = Date.now();
      }
      if (bestText && !isGenerating() && Date.now() - changedAt >= 1800) return bestText;
      await sleep(350);
    }
    throw new Error("Время ожидания ответа Gemini истекло.");
  }

  async function runTask(task) {
    const restored = window.innerWidth < 400 || window.innerHeight < 300;
    if (restored) {
      await chrome.runtime.sendMessage({ type: "DELEGATOR_GEMINI_WINDOW", visible: true }).catch(() => {});
      await sleep(800);
    }
    try {
      return await runTaskInTab(task);
    } finally {
      if (restored) await chrome.runtime.sendMessage({ type: "DELEGATOR_GEMINI_WINDOW", visible: false }).catch(() => {});
    }
  }

  async function runTaskInTab(task) {
    const result = await debuggerInput("begin");
    debuggerInputActive = Boolean(result?.ok);
    try {
      await startFreshChat();
      await chooseModel(task.model);
      await chooseReasoning(task.reasoning);
      return await sendPrompt(task.text);
    } finally {
      if (debuggerInputActive) {
        await debuggerInput("end").catch(() => {});
        debuggerInputActive = false;
      }
    }
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type !== "DELEGATOR_GEMINI_RUN") return;
    if (busy) {
      sendResponse({ error: "Вкладка Gemini уже обрабатывает другой запрос." });
      return;
    }
    busy = true;
    void runTask(message.task)
      .then((text) => sendResponse({ text }))
      .catch((error) => sendResponse({ error: error instanceof Error ? error.message : String(error) }))
      .finally(() => {
        busy = false;
        announceReady();
      });
    return true;
  });

  window.addEventListener("pagehide", () => {
    chrome.runtime.sendMessage({ type: "DELEGATOR_GEMINI_CLOSED" }).catch(() => {});
  });
  announceReady();
  window.setInterval(announceReady, 8000);
})();

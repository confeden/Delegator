(() => {
  if (new URL(location.href).searchParams.get("delegator_bridge") !== "1") return;

  if (window.__delegatorGeminiBridgeLoaded) return;
  window.__delegatorGeminiBridgeLoaded = true;

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const visible = (element) => Boolean(element && element.getClientRects().length);
  const normalizedText = (element) => (element?.innerText || element?.textContent || "").replace(/\s+/g, " ").trim();
  let busy = false;
  // Reported to the Core so a request that hangs says WHERE it hangs.
  const phase = (name) => chrome.runtime.sendMessage({ type: "DELEGATOR_GEMINI_PHASE", phase: name }).catch(() => {});

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
  // "best" walks this list from the top: the highest level the page offers.
  const REASONING_BEST_ORDER = [
    /^(максим|extra|ultra|very high|очень высок)/i,
    REASONING_MATCHERS.high,
    REASONING_MATCHERS.medium,
    REASONING_MATCHERS.low,
  ];
  const REASONING_ROW = /^(уровень рассуждений|reasoning level)/i;

  // "best" = the newest, strongest row of the page's own model menu. Rows are
  // ranked by the first version number in their name, then by tier, so the next
  // Gemini release (or a model with a name we have never seen) wins by itself.
  function modelRank(text) {
    const version = parseFloat((text.match(/\d+(?:[.,]\d+)?/) || ["0"])[0].replace(",", "."));
    if (!version && !/argon|ultra|pro|flash/i.test(text)) return -1;
    const tier = /lite/i.test(text) ? 1 : /flash/i.test(text) && !/pro|ultra|argon/i.test(text) ? 2 : 3;
    return version * 10 + tier;
  }

  // A spent quota. Gemini words it differently in every language and release, so
  // this is deliberately broad - but it is only ever applied to a menu row, a
  // notification or a SHORT answer, never to a long one that happens to say "limit".
  const QUOTA_TEXT = new RegExp([
    "(лимит|квот)[^.]{0,60}(исчерп|достигн|превыш|израсход)",
    "(исчерп|достигн|превыш|израсход)[^.]{0,60}(лимит|квот)",
    "(reached|hit|exceeded|used up)[^.]{0,40}(limit|quota)",
    "(limit|quota)[^.]{0,40}(reached|exceeded|exhausted)",
    "out of (quota|messages|prompts)",
    "(try again|come back|вернитесь|повторите)[^.]{0,40}(later|tomorrow|позже|завтра)",
    "too many requests",
  ].join("|"), "i");

  const DEAD_AFTER_MS = 120000; // no sign of life this long = frozen

  function isLimitedRow(row) {
    return row.getAttribute("aria-disabled") === "true" || row.hasAttribute("disabled")
      || QUOTA_TEXT.test(normalizedText(row));
  }

  function quotaError(detail) {
    return new Error(`QUOTA[${pickerLabel()}]: ${detail}`);
  }

  // Notifications (snackbars, alerts) that say the quota is spent.
  function quotaNotice() {
    const nodes = querySelectorAllDeep('[role="alert"],[role="status"],snack-bar-container,.snackbar,.error-message,.mat-mdc-snack-bar-label');
    for (const node of nodes) {
      const text = normalizedText(node);
      if (text && text.length < 400 && QUOTA_TEXT.test(text)) return text;
    }
    return "";
  }

  function bestModelRow() {
    let best = null;
    let bestRank = -1;
    for (const row of menuRows()) {
      const text = normalizedText(row);
      if (REASONING_ROW.test(text)) continue;
      if (isLimitedRow(row)) continue; // a spent model is not "the best one" any more
      const rank = modelRank(text);
      if (rank > bestRank) {
        best = row;
        bestRank = rank;
      }
    }
    return best;
  }

  let usedReasoning = "";

  function modelIsSelected(model, label) {
    return Boolean(MODEL_MATCHERS[model]?.(label));
  }

  function findModelPicker() {
    const buttons = querySelectorAllDeep('[data-test-id="bard-mode-menu-button"],button,[role="button"]')
      .filter(visible);
    return buttons.find((element) => element.getAttribute("data-test-id") === "bard-mode-menu-button"
        || /^(Выбор режима|Select mode|Choose mode)/i.test(element.getAttribute("aria-label") || ""))
      || buttons.find((element) => /^(mode picker|model picker|выбор модели)/i.test(element.getAttribute("aria-label") || ""))
      || null;
  }

  // The picker appears a moment after the composer does, so wait for it, and
  // when it never does say what IS on the page instead of a bare "not found".
  async function requirePicker() {
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      const picker = findModelPicker();
      if (picker) return picker;
      await sleep(200);
    }
    const seen = querySelectorAllDeep('button,[role="button"]').filter(visible)
      .map((element) => element.getAttribute("aria-label") || normalizedText(element))
      .filter(Boolean).slice(0, 14).join(" | ");
    throw new Error(`Не найден выбор модели Gemini (окно ${window.innerWidth}x${window.innerHeight}). Кнопки на странице: ${seen || "нет"}.`);
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
    // A page that holds no answer yet already IS a fresh chat (a window the
    // extension has just opened, or one it reset itself). Nothing to click.
    if (!getAnswerNodes().length && findComposer()) return;

    const isNewChat = (element) => /^(новый чат|new chat)$/i.test(
      normalizedText(element) || element.getAttribute("aria-label") || "");
    const link = [...document.querySelectorAll('a[href*="/app"],button,[role="button"],a')]
      .filter(visible)
      .find((element) => isNewChat(element)
        || /^(новый чат|new chat)/i.test(element.getAttribute("aria-label") || ""));
    if (!link) {
      const seen = [...document.querySelectorAll("a,button,[role='button']")].filter(visible)
        .map((element) => element.getAttribute("aria-label") || normalizedText(element))
        .filter(Boolean).slice(0, 14).join(" | ");
      throw new Error(`Не найдена команда «Новый чат» в Gemini (окно ${window.innerWidth}x${window.innerHeight}). На странице: ${seen || "ничего"}.`);
    }
    if (link.href) {
      const url = new URL(link.href, location.href);
      url.searchParams.set("delegator_bridge", "1");
      link.href = url.href;
    }
    await trustedClick(link);
    // The composer is on screen before AND after the switch, so it proves
    // nothing: wait until the page really is an empty chat at /app.
    await waitFor(
      () => findComposer() && !getAnswerNodes().length && /^\/app\/?$/.test(location.pathname),
      10000,
      "Gemini не открыл новый чат.",
    );
    await sleep(300);
  }

  async function openModelMenu() {
    // The first click after a page (re)load is sometimes swallowed while Gemini
    // is still wiring up its menu; try again before giving up.
    for (let attempt = 1; attempt <= 3; attempt++) {
      await pressMenuKey("Escape");
      await sleep(150);
      await trustedClick(await requirePicker());
      const deadline = Date.now() + 2500;
      while (Date.now() < deadline && menuRows().length === 0) await sleep(100);
      if (menuRows().length > 0) return;
    }
    throw new Error("Меню режимов Gemini не открылось.");
  }

  async function chooseBestModel() {
    await openModelMenu();
    const row = bestModelRow();
    if (!row) {
      const seen = menuRows().map(normalizedText).join(" | ");
      await pressMenuKey("Escape");
      throw new Error(`В меню Gemini не нашлось модели. Сейчас доступно: ${seen || "ничего"}.`);
    }
    const wanted = normalizedText(row);
    const picker = findModelPicker();
    const current = picker ? (picker.getAttribute("aria-label") || normalizedText(picker)) : "";
    // The picker's label names the model; the row may add a description to it.
    if (current && wanted.toLowerCase().includes(current.replace(/^.*?:\s*/, "").trim().toLowerCase())) {
      await pressMenuKey("Escape");
      return;
    }
    await trustedClick(row);
    await sleep(300);
  }

  async function chooseModel(model) {
    if (model === "gemini-web/best") return chooseBestModel();
    const matches = MODEL_MATCHERS[model];
    if (!matches) throw new Error(`Неизвестная модель Gemini Web: ${model}`);
    const picker = await requirePicker();
    if (modelIsSelected(model, picker.getAttribute("aria-label") || normalizedText(picker))) return;

    await openModelMenu();
    const row = findMenuRow((text) => !/^(уровень рассуждений|reasoning level)/i.test(text) && matches(text));
    if (!row) {
      const seen = menuRows().map(normalizedText).join(" | ");
      await pressMenuKey("Escape");
      throw new Error(`В меню Gemini нет модели ${model}. Сейчас доступно: ${seen || "ничего"}.`);
    }
    if (isLimitedRow(row)) {
      const why = normalizedText(row);
      await pressMenuKey("Escape");
      throw new Error(`QUOTA[${model}]: модель недоступна (${why.slice(0, 120)})`);
    }
    await trustedClick(row);
    await waitFor(
      () => modelIsSelected(model, findModelPicker()?.getAttribute("aria-label") || ""),
      5000,
      `Gemini не выбрал модель ${model}.`,
    );
  }

  async function chooseReasoning(reasoning) {
    usedReasoning = "";
    if (!reasoning || reasoning === "auto") return;
    const wanted = reasoning === "best" ? null : REASONING_MATCHERS[reasoning];
    if (reasoning !== "best" && !wanted) throw new Error(`Неизвестный уровень рассуждений: ${reasoning}`);

    await openModelMenu();
    const parent = findMenuRow((text) => /уровень рассуждений|reasoning level/i.test(text));
    if (!parent) {
      // The picked model has no levels; the default is the only choice.
      await pressMenuKey("Escape");
      return;
    }
    await trustedClick(parent);
    const levelRow = () => {
      if (wanted) return findMenuRow((text) => wanted.test(text));
      for (const pattern of REASONING_BEST_ORDER) {
        const row = findMenuRow((text) => pattern.test(text));
        if (row) return row;
      }
      return null;
    };
    await waitFor(() => levelRow(), 4000, "Gemini не показал уровни рассуждений.");
    const level = levelRow();
    usedReasoning = normalizedText(level).split(" ")[0];
    await trustedClick(level);
    await sleep(150);
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

  // innerText flattens the answer: code loses its fences ("Pythonfrom x import y"),
  // lists lose their bullets. Rebuild the markdown from the DOM instead. Reads
  // textContent, so it also works for a page that is not being painted.
  const FENCE = "`".repeat(3);

  function toMarkdown(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.textContent.replace(/\s+/g, " ");
    if (node.nodeType !== Node.ELEMENT_NODE) return "";
    const tag = node.tagName.toLowerCase();
    if (tag === "code-block" || tag === "pre") {
      const code = (node.querySelector("pre code,code") || node.querySelector("pre") || node).textContent.replace(/\n+$/, "");
      const header = node.querySelector(".code-block-decoration span,[class*='decoration'] span");
      const language = (header?.textContent || "").trim().toLowerCase();
      return "\n\n" + FENCE + (/^[\w+#.-]{1,20}$/.test(language) ? language : "") + "\n" + code + "\n" + FENCE + "\n\n";
    }
    if (tag === "br") return "\n";
    if (["script", "style", "button", "mat-icon", "svg"].includes(tag)) return "";
    const inner = [...node.childNodes].map(toMarkdown).join("");
    if (/^h[1-6]$/.test(tag)) return "\n\n" + "#".repeat(Number(tag[1])) + " " + inner.trim() + "\n\n";
    if (tag === "li") return "\n- " + inner.trim();
    if (tag === "ul" || tag === "ol") return "\n" + inner + "\n";
    if (tag === "p" || tag === "div" || tag === "table" || tag === "blockquote") return "\n\n" + inner.trim() + "\n\n";
    if (tag === "tr") return "\n" + inner;
    if (tag === "td" || tag === "th") return "| " + inner.trim() + " ";
    if (tag === "strong" || tag === "b") return inner.trim() ? "**" + inner.trim() + "**" : "";
    if (tag === "code") return inner.trim() ? "`" + inner.trim() + "`" : "";
    return inner;
  }

  // Gemini puts a visually hidden heading ("Ответ Gemini" / "Gemini said") in
  // front of every answer. Without the markdown panel the whole element is read,
  // heading included, and a bare heading looked like a finished one-word answer.
  const ANSWER_LABEL = /^\s*(ответ gemini|gemini said|gemini ответил[а-я()]*|показать ход рассуждений|show thinking)\s*/i;

  function responseText(element) {
    const markdown = element.querySelector(".markdown-main-panel,.markdown");
    const clean = (node) => toMarkdown(node).replace(/\n{3,}/g, "\n\n").trim();
    let text = clean(markdown || element);
    if (!text && markdown) text = clean(element);
    for (let i = 0; i < 3 && ANSWER_LABEL.test(text); i++) text = text.replace(ANSWER_LABEL, "").trim();
    return text;
  }

  function isGenerating() {
    return Boolean(document.querySelector(
      'button[aria-label*="Stop"],button[aria-label*="Останов"],[data-test-id*="stop-generating"]',
    ));
  }

  // A file goes in the way the page's own «Загрузить файлы» item does: its upload input gets the file
  // through a DataTransfer and a change event. Only the types that input's accept list names are sent.
  function acceptsFile(accept, name, mime) {
    const lower = name.toLowerCase();
    return accept.split(",").map((token) => token.trim().toLowerCase()).filter(Boolean).some((token) => {
      if (token.startsWith(".")) return lower.endsWith(token);
      if (token.endsWith("/*")) return mime.startsWith(token.slice(0, -1));
      return token === mime;
    });
  }

  function uploadInputs() {
    return [...document.querySelectorAll('input[type=file]')];
  }

  // The page can rename an upload: an image comes back as «blue_5c7c23.png», so the chip is matched
  // on the name's stem and extension with an optional «_hash» between them.
  function attachmentShown(name) {
    const dot = name.lastIndexOf(".");
    const stem = dot > 0 ? name.slice(0, dot) : name;
    const ext = dot > 0 ? name.slice(dot + 1) : "";
    const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const chip = new RegExp(`^${escape(stem)}(_[0-9a-f]+)?${ext ? `\\.${escape(ext)}` : ""}$`, "i");
    return [...document.querySelectorAll("div,span")]
      .some((element) => element.children.length === 0 && chip.test((element.textContent || "").trim()));
  }

  async function attachFiles(files) {
    for (const file of files) {
      if (!uploadInputs().length) {
        const trigger = [...document.querySelectorAll("button")]
          .find((button) => /Загрузка и инструменты|Upload and tools/i.test(button.getAttribute("aria-label") || ""));
        if (!trigger) throw new Error("В Gemini не найдено меню загрузки файлов.");
        trigger.click();
        const until = Date.now() + 3000;
        while (!uploadInputs().length && Date.now() < until) await sleep(100);
      }
      const input = uploadInputs().find((element) => acceptsFile(element.getAttribute("accept") || "", file.name, file.mime || ""));
      if (!input) throw new Error(`Gemini не принимает файл ${file.name}: такого типа нет в его списке загрузки.`);
      const bytes = Uint8Array.from(atob(file.data_base64), (char) => char.charCodeAt(0));
      const transfer = new DataTransfer();
      transfer.items.add(new File([bytes], file.name, { type: file.mime || "application/octet-stream" }));
      input.files = transfer.files;
      input.dispatchEvent(new Event("change", { bubbles: true }));
      void phase(`файл ${file.name}: загрузка`);
      const until = Date.now() + 60000;
      while (Date.now() < until && !attachmentShown(file.name)) await sleep(200);
      if (!attachmentShown(file.name)) throw new Error(`Gemini не принял файл ${file.name}.`);
    }
  }

  async function sendPrompt(text, maxWaitMs, files = []) {
    const composer = findComposer();
    if (!composer) throw new Error("Не найдено поле запроса. Убедитесь, что Gemini открыт и вы вошли в аккаунт.");
    composer.focus();
    // A failed earlier attempt leaves its text behind; start from an empty box.
    document.execCommand("selectAll", false);
    document.execCommand("delete", false);
    await debuggerInput("text", { text });
    if (files.length) await attachFiles(files);

    // Gemini enables and inserts the send control only after its composer state
    // has processed the input event. Looking for it synchronously can race the
    // framework update and a synthetic Enter key is not always handled.
    const findSendButton = () => [...document.querySelectorAll('button,[role="button"]')]
      .filter(visible)
      .find((element) => /отправить|send message|submit/i.test(
        `${element.getAttribute("aria-label") || ""} ${element.getAttribute("title") || ""}`,
      ));
    const enabled = (element) => element && !element.disabled && element.getAttribute("aria-disabled") !== "true";
    // «Sent» = a user bubble exists, the model started, or the composer emptied.
    const wasSent = () => document.querySelector("user-query") !== null
      || isGenerating()
      || getAnswerNodes().length > 0
      || !(findComposer()?.innerText || findComposer()?.value || "").trim();
    const waitSent = async (ms) => {
      const until = Date.now() + ms;
      while (Date.now() < until) {
        if (wasSent()) return true;
        await sleep(150);
      }
      return false;
    };

    const sendDeadline = Date.now() + 5000;
    let sendButton = null;
    while (Date.now() < sendDeadline) {
      sendButton = findSendButton();
      if (enabled(sendButton)) break;
      sendButton = null;
      await sleep(100);
    }
    void phase(`текст набран (${text.length} симв.); кнопка отправки: ${sendButton ? "есть" : "нет"}; ${pageFacts()}; ${sendFacts(sendButton)}`);

    let sent = false;
    if (sendButton) {
      await trustedClick(sendButton);
      sent = await waitSent(3000);
    }
    if (!sent) {
      void phase("отправка кликом не сработала, пробую Enter");
      composer.focus();
      await trustedKey(composer, "Enter");
      sent = await waitSent(3000);
    }
    if (!sent) {
      void phase("Enter не сработал, пробую click() по кнопке");
      const button = findSendButton();
      if (button) button.click();
      sent = await waitSent(3000);
    }
    if (!sent) {
      const label = findSendButton();
      throw new Error(`Gemini не принял запрос: ни кнопка, ни Enter не отправили его. Кнопка: ${label ? `${label.getAttribute("aria-label")} (disabled=${label.disabled})` : "не найдена"}. ${pageFacts()}; ${sendFacts(label)}`);
    }
    await debuggerInput("end");
    debuggerInputActive = false;

    void phase(`жду ответ; ${pageFacts()}`);
    // WAIT BY STATUS, NOT BY THE CLOCK. A model that is thinking shows life: the
    // reply container keeps changing (thought summaries, growing text) or the page
    // keeps its stop button lit while the text changes. While there is life, wait.
    // A model with no life at all for DEAD_AFTER_MS - nothing written, nothing
    // mutated - is frozen: report it (`SLOW`) so the Core can retry it and then move
    // to another model. MAX_WAIT is only the ceiling for a model that is alive forever.
    const sentAt = Date.now();
    const deadline = sentAt + Math.min(Math.max(Number(maxWaitMs) || 360000, 60000), 900000);
    let bestText = "";
    let changedAt = Date.now();
    let lastPhaseAt = 0;
    let lifeAt = Date.now();
    let signature = -1;
    let observed = null;
    let observer = null;
    const watch = (node) => {
      if (node === observed) return;
      observer?.disconnect();
      observed = node;
      if (node) {
        observer = new MutationObserver(() => { lifeAt = Date.now(); });
        observer.observe(node, { subtree: true, childList: true, characterData: true });
      }
    };
    try {
      while (Date.now() < deadline) {
        const nodes = getAnswerNodes();
        watch(nodes.at(-1) || null);
        // textContent includes collapsed thought panels that innerText hides.
        const sig = (nodes.at(-1)?.textContent || "").length;
        if (sig !== signature) {
          signature = sig;
          lifeAt = Date.now();
        }
        const answer = nodes.map(responseText).filter(Boolean).at(-1) || "";
        if (answer !== bestText) {
          bestText = answer;
          changedAt = Date.now();
          lifeAt = Date.now();
        }
        if (bestText && !isGenerating() && Date.now() - changedAt >= 1000) {
          // A refusal about the quota is short; a real answer is not, even if it mentions a limit.
          if (bestText.length < 600 && QUOTA_TEXT.test(bestText)) throw quotaError(bestText.slice(0, 160));
          return bestText;
        }
        const notice = bestText ? "" : quotaNotice();
        if (notice) throw quotaError(notice.slice(0, 160));
        if (Date.now() - lifeAt > DEAD_AFTER_MS) {
          throw new Error(`SLOW[${pickerLabel()}]: без признаков работы ${Math.round((Date.now() - lifeAt) / 1000)} с `
            + `(${bestText.length} симв., стоп: ${isGenerating()}); ${pageFacts()}`);
        }
        if (Date.now() - lastPhaseAt > 10000) {
          lastPhaseAt = Date.now();
          const idle = Math.round((Date.now() - lifeAt) / 1000);
          void phase(`жду ответ: ${bestText.length} симв., тишина ${idle} с; ${pageFacts()}`);
        }
        await sleep(200);
      }
    } finally {
      observer?.disconnect();
    }
    throw new Error(`SLOW[${pickerLabel()}]: предел ожидания ${Math.round((Date.now() - sentAt) / 1000)} с, модель всё ещё работала`);
  }

  async function runTask(task) {
    // Nothing here touches the window: it stays minimized and in the background.
    // visible.js makes the page believe it is visible; the viewport size is
    // emulated through the debugger when it begins (background.js).
    return runTaskInTab(task);
  }

  function pickerLabel() {
    const picker = findModelPicker();
    if (!picker) return "";
    // «Выбор режима, сейчас используется Argon» -> «Argon»
    return (picker.getAttribute("aria-label") || normalizedText(picker))
      .replace(/^.*?(?:сейчас используется|currently using|selected:)\s*/i, "")
      .replace(/^.*?:\s*/, "")
      .trim();
  }

  function describe(element) {
    if (!element) return "нет";
    return `${element.tagName.toLowerCase()}${element.id ? "#" + element.id : ""}[${(element.getAttribute("aria-label") || "").slice(0, 40)}]`;
  }

  // Facts about the page that say why no answer shows up: was the prompt typed,
  // did a user bubble appear, which answer containers exist.
  function pageFacts() {
    const count = (selector) => document.querySelectorAll(selector).length;
    const composer = findComposer();
    return [
      `композер: ${composer ? (composer.innerText || composer.value || "").trim().length : "нет"} симв.`,
      `user-query: ${count("user-query")}`,
      `model-response: ${count("model-response")}`,
      `markdown: ${count(".markdown-main-panel,.markdown")}`,
      `message-content: ${count("message-content")}`,
      `ответ: innerText ${(document.querySelector(".markdown-main-panel,.markdown")?.innerText || "").length}, textContent ${(document.querySelector(".markdown-main-panel,.markdown")?.textContent || "").length}`,
      `стоп: ${isGenerating()}`,
      `url: ${location.pathname}`,
    ].join("; ");
  }

  function sendFacts(button) {
    const rect = button ? button.getBoundingClientRect() : null;
    const top = rect ? document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2) : null;
    const editors = [...document.querySelectorAll('[contenteditable="true"],textarea')]
      .map((element) => `${element.tagName.toLowerCase()}:${visible(element) ? "v" : "h"}:${(element.innerText || element.value || "").trim().length}`);
    return [
      `кнопка: ${rect ? `${Math.round(rect.left)},${Math.round(rect.top)} ${Math.round(rect.width)}x${Math.round(rect.height)}` : "нет"}`,
      `поверх неё: ${describe(top)}`,
      `окно: ${window.innerWidth}x${window.innerHeight}, фокус: ${document.hasFocus()}, видимость: ${document.visibilityState}`,
      `поля: ${editors.join(" ")}`,
      `диалоги: ${document.querySelectorAll('[role="dialog"],mat-dialog-container').length}`,
    ].join("; ");
  }

  async function runTaskInTab(task) {
    const result = await debuggerInput("begin");
    debuggerInputActive = Boolean(result?.ok);
    try {
      void phase("новый чат");
      await startFreshChat();
      void phase(`выбор модели (${task.model})`);
      await chooseModel(task.model);
      void phase(`выбор уровня (${task.reasoning}); модель: ${pickerLabel()}`);
      await chooseReasoning(task.reasoning);
      void phase(`ввод запроса; ${pickerLabel()} · ${usedReasoning}`);
      // What the page itself shows is what answers; report it, not what was asked for.
      const used = [pickerLabel(), usedReasoning].filter(Boolean).join(" · ");
      const text = await sendPrompt(task.text, task.max_wait_ms, task.files || []);
      return { text, used };
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
      .then((result) => sendResponse({ text: result.text, used: result.used }))
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

// The driver for the non-Gemini web doors: one signed-in chat tab per site, one turn at a time.
// Injected by background.js into a tab it opened itself. Selectors live in SITES, and every one of
// them has a fallback that needs no selector, because these pages change without notice: what is
// checked is behaviour (the prompt left the composer, a new answer grew and stopped), not structure.
(() => {
  if (window.__delegatorDoorLoaded) return;
  window.__delegatorDoorLoaded = true;

  const SITES = {
    aistudio: {
      composer: "ms-prompt-box textarea,ms-chunk-input textarea,textarea[aria-label]",
      send: "ms-run-button button,button[aria-label*='Run'],button[type='submit']",
      answer: "ms-chat-turn:has([data-turn-role='Model']) .turn-content",
      user: "[data-turn-role='User']",
      strip: "ms-thought-chunk,[class*='thought'],.author-label,[class*='author'],[class*='turn-footer'],ms-chat-turn-options",
      failure: /^(error\s+)?(an internal error has occurred|failed to generate|something went wrong)/i,
      // Its Run button says Stop while a turn runs, and says nothing else that a label would show.
      running: () => {
        const button = query("ms-run-button button")[0];
        return Boolean(button) && !/\brun\b/i.test(button.innerText || "");
      },
      modelLabel: /^Gemini[\w .-]*$/i,
    },
    kimi: {
      composer: ".chat-input-editor",
      send: ".send-button-container",
      answer: ".markdown-container",
      user: ".segment-user,[class*='user-content'],[class*='user-message']",
      strip: "[class*='think'],[class*='reason']",
      modelLabel: /^K\d[\w.]*$/,
    },
    zai: {
      composer: "#chat-input",
      send: "#send-message-button",
      answer: ".chat-assistant",
      user: ".chat-user",
      strip: ".thinking-chain-container,[class*='thinking']",
      picker: '[aria-label="Select a model"]',
      models: [/GLM-5\.3(?![\w-]*flash)/i, /GLM-5(?![\w.-]*flash)/i],
    },
    qwen: {
      composer: "textarea.message-input-textarea",
      send: '[aria-label="Send"]',
      answer: ".custom-qwen-markdown",
      user: "[class*='user-message'],[class*='chat-user']",
      strip: "[class*='think'],[class*='reasoning']",
      picker: '[aria-label="Select Model"]',
      models: [/Qwen3\.8-Max/i, /Qwen[\d.]+-Max/i],
    },
    deepseek: {
      composer: "textarea",
      send: "[role='button'][class*='ds-icon-button'],button[class*='send']",
      answer: ".ds-markdown",
      user: ".ds-message:not(:has(.ds-markdown))",
      strip: "[class*='think']",
      toggles: [/^DeepThink/i],
    },
    tencent: {
      composer: "textarea.t-textarea__inner",
      send: "[class*='send']",
      answer: ".hyc-common-markdown",
      user: ".agent-chat__bubble--user,[class*='bubble--user']",
      strip: "[class*='think'],[class*='reason']",
      modelLabel: /^Hy\d[\w. -]*$/i,
    },
    rudder: {
      composer: "textarea",
      send: 'button[aria-label="Send"]',
      answer: "[class*='group/asst'] [class*='prose-th']",
      user: "[class*='group/user'] .user-text",
      strip: "[class*='think'],[class*='reason']",
    },
  };

  const LOGIN_TEXT = /^(log ?in|sign ?in|sign ?up|войти|вход|登录|注册)$/i;
  const LIMIT_TEXT = /(rate limit|too many|limit (reached|exceeded)|reached your|usage limit|try again later|upgrade to|лимит|слишком много|次数|频繁|额度|上限)/i;
  const STOP_LABEL = /(^|\b)(stop|停止|останов)/i;
  const FENCE = "`".repeat(3);
  const STABLE_MS = 7000;
  // Measured on AI Studio: a page's "Thinking" label stood for 12 s and went back as the whole answer.
  // A short "answer" that is really the site saying no. Only short text counts: a real answer may discuss limits.
  const BUSY_TEXT = /(at capacity|over capacity|try again later|switch to another model|too many requests|server is busy|服务器繁忙|稍后再试)/i;
  const THINKING_ONLY = /^(thinking|thought process|thoughts|думаю|размышления|思考中?)[\s.…]*$/i;
  const DEAD_AFTER_MS = 120000;

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const visible = (element) => Boolean(element && element.getClientRects().length);
  const labelOf = (element) => (element?.getAttribute?.("aria-label") || element?.innerText || element?.textContent || "").replace(/\s+/g, " ").trim();
  let aborted = false;
  let currentDoor = "";
  // Reported to the Core so a turn that hangs says WHERE it hangs.
  const phase = (name) => chrome.runtime.sendMessage({ type: "DELEGATOR_DOOR_PHASE", door: currentDoor, phase: name }).catch(() => {});

  function query(selector) {
    if (!selector) return [];
    try {
      return [...document.querySelectorAll(selector)].filter(visible);
    } catch {
      return [];
    }
  }

  function findComposer(site) {
    return query(site.composer)[0]
      || query("textarea,[contenteditable='true'][role='textbox'],[contenteditable='true']")[0]
      || null;
  }

  function loginWall() {
    if (/\/(sign_in|login|signin)/i.test(location.pathname)) return true;
    return query("a,button,[role='button']").some((element) => LOGIN_TEXT.test(labelOf(element)));
  }

  function limitNotice() {
    const notice = query("[role='alert'],[role='status'],[class*='toast'],[class*='notification'],[class*='limit'],[class*='error-message']")
      .map(labelOf).find((text) => text && LIMIT_TEXT.test(text));
    return notice ? notice.slice(0, 160) : "";
  }

  function isGenerating() {
    return query("button,[role='button']").some((element) => STOP_LABEL.test(element.getAttribute("aria-label") || element.getAttribute("title") || ""))
      || query("ms-run-button button,[class*='run-button']").some((element) => /^stop\b|останов/i.test((element.innerText || "").trim()))
      || query("[class*='stop-button'],[class*='stopButton'],[class*='send-button--stop']").length > 0;
  }

  // innerText flattens the answer: code loses its fences, lists their bullets. Rebuilt from the DOM.
  function toMarkdown(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.textContent.replace(/\s+/g, " ");
    if (node.nodeType !== Node.ELEMENT_NODE) return "";
    const tag = node.tagName.toLowerCase();
    const editorLines = tag !== "pre" ? node.querySelector?.(":scope > .cm-editor, :scope .cm-content") : null;
    if (tag === "pre" || (editorLines && !node.querySelector("p,li,h1,h2,h3"))) {
      // CodeMirror (.cm-line) and Monaco (.view-line, positioned, nbsp for spaces) keep one row per
      // line; their textContent has no line breaks at all.
      const monaco = [...node.querySelectorAll(".view-line")]
        .sort((a, b) => parseFloat(a.style.top || 0) - parseFloat(b.style.top || 0));
      const lines = monaco.length ? monaco : [...node.querySelectorAll(".cm-line")];
      const code = lines.length
        ? lines.map((line) => line.textContent.replace(/\u00a0/g, " ")).join("\n")
        : (node.querySelector("code") || node).textContent.replace(/\n+$/, "");
      const language = node.getAttribute("data-delegator-lang")
        || node.querySelector("[data-language]")?.getAttribute("data-language")
        || (node.querySelector("code")?.className.match(/language-([\w+#.-]+)/) || [])[1]
        || "";
      return `\n\n${FENCE}${language}\n${code}\n${FENCE}\n\n`;
    }
    if (tag === "br") return "\n";
    if (["script", "style", "button", "svg", "img"].includes(tag)) return "";
    const inner = [...node.childNodes].map(toMarkdown).join("");
    if (/^h[1-6]$/.test(tag)) return `\n\n${"#".repeat(Number(tag[1]))} ${inner.trim()}\n\n`;
    if (tag === "li") return `\n- ${inner.trim()}`;
    if (tag === "ul" || tag === "ol") return `\n${inner}\n`;
    if (["p", "div", "table", "blockquote"].includes(tag)) return `\n\n${inner.trim()}\n\n`;
    if (tag === "tr") return `\n${inner}`;
    if (tag === "td" || tag === "th") return `| ${inner.trim()} `;
    if (tag === "strong" || tag === "b") return inner.trim() ? `**${inner.trim()}**` : "";
    if (tag === "code") return inner.trim() ? `\`${inner.trim()}\`` : "";
    return inner;
  }

  // The last answer on the page, without its thinking panel. A code block with a language header
  // keeps the language in the fence rather than as a stray first line.
  function answerText(site, node) {
    const copy = node.cloneNode(true);
    if (site.strip) copy.querySelectorAll(site.strip).forEach((element) => element.remove());
    // KaTeX renders every formula twice (MathML for readers, HTML for the eye): keep its TeX once.
    copy.querySelectorAll(".katex").forEach((formula) => {
      const tex = formula.querySelector("annotation[encoding='application/x-tex']")?.textContent;
      if (tex) formula.replaceWith(document.createTextNode(`$${tex.trim()}$`));
    });
    // A code block's header holds its language: move that onto the code, then the header can go.
    copy.querySelectorAll("[class*='banner'],[class*='code-header'],[class*='code__hd'],[class*='segment-code-lang']").forEach((header) => {
      const owner = header.closest("pre") || header.parentElement?.querySelector("pre")
        || header.closest("[class*='code']")?.querySelector("pre");
      const language = [...header.querySelectorAll("*"), header]
        .filter((element) => element.children.length === 0)
        .map((element) => (element.textContent || "").trim().toLowerCase())
        .find((text) => /^[a-z][\w+#.-]{0,19}$/.test(text) && !/^(copy|download|run|edit|复制|下载)$/.test(text));
      if (owner && language && !owner.getAttribute("data-delegator-lang")) owner.setAttribute("data-delegator-lang", language);
      header.remove();
    });
    // Code viewers put their own chrome inside the answer: line numbers, a language tag, Copy buttons.
    copy.querySelectorAll("[class*='line-number'],[class*='lineNumber'],[class*='linenumber'],[class*='line-num'],[role='button'],[class*='copy'],[class*='toolbar'],[class*='code-header'],[class*='codeHeader']")
      .forEach((element) => element.remove());
    copy.querySelectorAll("[class*='absolute']").forEach((element) => {
      if (element.nextElementSibling && /^[\w+#.-]{1,20}$/.test((element.textContent || "").trim())) element.remove();
    });
    return toMarkdown(copy).replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  // The answer node: the site's own selector, which names the assistant's side only. Text is not a
  // filter here: "2+2" is a fair prompt, and "2+2 = 4" contains it.
  function lastAnswer(site) {
    const nodes = query(site.answer);
    // Outermost only: a broad selector also matches parts of the answer (a code block's own markdown
    // class), and the last of those would stand in for the whole answer.
    const outer = nodes.filter((element) => !nodes.some((other) => other !== element && other.contains(element)));
    return outer.at(-1) || null;
  }

  async function trusted(action, details = {}) {
    const result = await chrome.runtime.sendMessage({ type: "DELEGATOR_DOOR_DEBUGGER", action, ...details });
    if (result?.error) throw new Error(result.error);
    return result;
  }

  // What is on the page, for an error that says more than "it failed". Structure only, and the prompt's
  // own text is never included: classes, counts and lengths.
  function pageFacts(site, promptHead) {
    const describe = (element) => `${element.tagName.toLowerCase()}${element.id ? `#${element.id}` : ""}.${String(element.className?.baseVal ?? element.className ?? "").trim().split(/\s+/).slice(0, 3).join(".")}`;
    const composer = findComposer(site);
    const facts = [
      `url ${location.pathname}`,
      `окно ${window.innerWidth}x${window.innerHeight}`,
      `видимость ${document.visibilityState}`,
      `поле ${composer ? `${describe(composer)}:${composerLength(composer)}` : "нет"}`,
      `вход ${loginWall() ? "просит" : "нет"}`,
      `ответ(${site.answer}) ${query(site.answer).length}`,
      `пользователь ${query(site.user).length}`,
      `генерирует ${isGenerating()}`,
    ];
    const bubble = promptHead && [...document.querySelectorAll("body *")].reverse()
      .find((element) => element.children.length <= 2 && (element.textContent || "").includes(promptHead) && element !== composer);
    if (bubble) {
      let holder = bubble;
      while (holder.parentElement && holder.parentElement !== document.body && holder.parentElement.children.length < 2) holder = holder.parentElement;
      let list = holder.parentElement;
      for (let up = 0; up < 4 && list?.parentElement && list.children.length < 2; up++) list = list.parentElement;
      const rows = [...(list?.children || [])].slice(-5).map((element) => `${describe(element)}:${(element.textContent || "").length}`);
      facts.push(`пузырь ${describe(bubble)}`, `рядом ${rows.join(" | ")}`);
    } else {
      facts.push("пузыря с запросом нет");
    }
    const buttons = query("button,[role='button']").map(labelOf).filter(Boolean).slice(-8).map((text) => text.slice(0, 24));
    facts.push(`кнопки ${buttons.join(" | ")}`);
    return facts.join("; ").slice(0, 1400);
  }

  function setComposerText(composer, text) {
    composer.focus();
    if (composer.tagName === "TEXTAREA" || composer.tagName === "INPUT") {
      const prototype = composer.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(prototype, "value").set.call(composer, text);
      composer.dispatchEvent(new Event("input", { bubbles: true }));
      return;
    }
    document.execCommand("insertText", false, text);
  }

  const composerLength = (composer) => (composer?.value ?? composer?.innerText ?? "").trim().length;

  async function typePrompt(site, text) {
    const composer = findComposer(site);
    if (!composer) throw new Error("На странице нет поля ввода.");
    setComposerText(composer, text);
    await sleep(300);
    if (composerLength(composer) > 0) return composer;
    // A rich editor that ignores execCommand takes a real paste.
    const transfer = new DataTransfer();
    transfer.setData("text/plain", text);
    composer.dispatchEvent(new ClipboardEvent("paste", { clipboardData: transfer, bubbles: true, cancelable: true }));
    await sleep(300);
    if (composerLength(composer) > 0) return composer;
    await trusted("begin");
    composer.focus();
    await trusted("text", { text });
    await sleep(300);
    if (composerLength(composer) > 0) return composer;
    throw new Error("Страница не приняла текст запроса.");
  }

  async function pressSend(site, composer, promptHead, text) {
    // A prompt counts as sent once the page shows it. An empty composer alone proves nothing: a page that
    // hydrates late wipes the text it was given, and that looked like a send followed by a dead model.
    const wasSent = () => composerLength(findComposer(site)) === 0
      && (document.body.textContent || "").includes(promptHead);
    const refill = async () => {
      const current = findComposer(site);
      if (current && composerLength(current) === 0) {
        setComposerText(current, text);
        await sleep(400);
      }
    };
    const waitSent = async (ms) => {
      const until = Date.now() + ms;
      while (Date.now() < until) {
        if (wasSent() || loginWall()) return true;
        await sleep(150);
      }
      return false;
    };
    const button = () => {
      const candidate = query(site.send).at(-1) || null;
      return candidate?.closest?.("button,[role='button']") || candidate;
    };
    const until = Date.now() + 5000;
    while (Date.now() < until) {
      const current = button();
      if (current && !current.disabled && current.getAttribute("aria-disabled") !== "true") break;
      await sleep(100);
    }
    button()?.click();
    if (await waitSent(3000)) return;
    await refill();
    composer.focus();
    composer.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true }));
    if (await waitSent(3000)) return;
    // The page ignores untrusted input: the same keys and clicks through the debugger.
    await trusted("begin");
    await refill();
    const target = button();
    if (target) {
      const rect = target.getBoundingClientRect();
      await trusted("click", { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 });
      if (await waitSent(2500)) return;
    }
    composer.focus();
    await trusted("key", { key: "Enter" });
    if (await waitSent(2500)) return;
    throw new Error(`Страница не приняла запрос: ни кнопка, ни Enter его не отправили. ${pageFacts(site, promptHead)}`);
  }

  let menuSeen = "";

  function menuRows() {
    const rows = query("[role='menuitem'],[role='menuitemradio'],[role='option'],[data-menu-item]");
    if (rows.length) return rows;
    return query("[role='menu'] button,[role='listbox'] button,[data-menu-content] button,[data-dropdown-menu-content] button,[data-menu-content] [class*='item']");
  }

  async function trustedClickOn(element) {
    const rect = element.getBoundingClientRect();
    await trusted("click", { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 });
  }

  function openMenu(element) {
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup"]) {
      element.dispatchEvent(new (type.startsWith("pointer") ? PointerEvent : MouseEvent)(type, { bubbles: true, cancelable: true, button: 0 }));
    }
    element.click();
  }

  // The strongest model the page offers. Never a reason to fail: the page's default still answers,
  // and the reply reports what really ran.
  async function chooseModel(site) {
    if (!site.picker || !site.models?.length) return;
    const picker = query(site.picker)[0];
    if (!picker) return;
    const current = (picker.innerText || "").replace(/\s+/g, " ").trim();
    if (site.models[0].test(current)) return;
    openMenu(picker);
    await sleep(600);
    if (!menuRows().length) {
      await trustedClickOn(picker);
      await sleep(800);
    }
    const rows = menuRows();
    const rowText = (element) => (element.innerText || element.textContent || "").replace(/\s+/g, " ").trim();
    menuSeen = rows.map(rowText).map((text) => text.slice(0, 40)).slice(0, 12).join(" | ");
    for (const pattern of site.models) {
      const row = rows.find((element) => pattern.test(rowText(element)));
      if (row) {
        row.click();
        await sleep(300);
        if (!site.models[0].test(rowText(query(site.picker)[0]))) {
          await trustedClickOn(row).catch(() => {});
          await sleep(300);
        }
        return;
      }
    }
    await trusted("key", { key: "Escape" }).catch(() => {});
    await sleep(200);
  }

  async function chooseToggles(site) {
    for (const pattern of site.toggles || []) {
      const toggle = query("button,[role='button']").find((element) => pattern.test(labelOf(element)));
      if (!toggle) continue;
      const pressed = toggle.getAttribute("aria-pressed") === "true"
        || /selected|active|checked/i.test(toggle.className || "");
      if (!pressed) toggle.click();
      await sleep(200);
    }
  }

  function usedLabel(site, doorLabel) {
    const picker = query(site.picker)[0];
    const text = picker ? (picker.innerText || "").replace(/\s+/g, " ").trim() : "";
    if (text) return text;
    if (site.modelLabel) {
      const leaf = query("span,div,button").find((element) => element.children.length === 0 && site.modelLabel.test((element.textContent || "").trim()));
      if (leaf) return leaf.textContent.trim();
    }
    return doorLabel;
  }

  async function waitForAnswer(site, promptHead, maxWaitMs, prompt) {
    const started = Date.now();
    const deadline = started + Math.min(Math.max(Number(maxWaitMs) || 360000, 60000), 900000);
    let lifeAt = Date.now();
    const observer = new MutationObserver(() => { lifeAt = Date.now(); });
    observer.observe(document.body, { subtree: true, childList: true, characterData: true });
    let best = "";
    let changedAt = Date.now();
    let wallSince = 0;
    try {
      while (Date.now() < deadline) {
        if (aborted) throw new Error("ABORTED: другая дверь ответила раньше.");
        const node = lastAnswer(site);
        const raw = node ? answerText(site, node) : "";
        const text = THINKING_ONLY.test(raw) || raw === prompt ? "" : raw;
        if (text !== best) {
          best = text;
          changedAt = Date.now();
        }
        if (!best) {
          if (loginWall()) {
            wallSince = wallSince || Date.now();
            if (Date.now() - wallSince >= 3000) throw new Error(`LOGIN: сайт просит войти. ${pageFacts(site, promptHead)}`);
          } else {
            wallSince = 0;
          }
          const notice = limitNotice();
          if (notice) throw new Error(`QUOTA: ${notice}`);
        }
        if (best && site.failure?.test(best)) throw new Error(`Сайт вернул ошибку: ${best.slice(0, 200)}`);
        if (best && best.length < 300 && BUSY_TEXT.test(best)) throw new Error(`SLOW: сайт занят: ${best.slice(0, 200)}`);
        const quiet = Date.now() - changedAt;
        // A one-word answer gets a longer look: it may be the first word of a slow stream.
        const needed = best.length < 40 ? STABLE_MS * 2 : STABLE_MS;
        if (best && quiet >= needed && !isGenerating() && !site.running?.()) return best;
        // A page that says it is thinking is alive, however still it sits: GLM-5.3 thought for over two
        // minutes with nothing moving. The race's own hedge covers the wait.
        if (!best && query("button,[role='button'],span").some((element) => element.children.length === 0 && /^(thinking|думает|思考中)/i.test((element.textContent || "").trim()))) {
          lifeAt = Date.now();
        }
        if (Date.now() - lifeAt >= DEAD_AFTER_MS) {
          if (best) return best;
          throw new Error(`SLOW: нет признаков жизни ${Math.round(DEAD_AFTER_MS / 1000)} с. ${pageFacts(site, promptHead)}`);
        }
        await sleep(500);
      }
      if (best) return best;
      throw new Error(`SLOW: нет ответа за ${Math.round((Date.now() - started) / 1000)} с. ${pageFacts(site, promptHead)}`);
    } finally {
      observer.disconnect();
    }
  }

  // A site renders its guest header for a moment while it reads the session, and the composer appears
  // later still in a background tab. So a login wall counts only once it has stood for a while, and the
  // page is ready once a composer has stood without one.
  async function waitReady(site) {
    const by = Date.now() + 30000;
    let wallSince = 0;
    let clearSince = 0;
    while (Date.now() < by) {
      const composer = findComposer(site);
      if (loginWall()) {
        clearSince = 0;
        wallSince = wallSince || Date.now();
        if (Date.now() - wallSince >= 8000) throw new Error(`LOGIN: сайт просит войти. ${pageFacts(site, "")}`);
      } else {
        wallSince = 0;
        if (composer) {
          clearSince = clearSince || Date.now();
          if (Date.now() - clearSince >= 1200) return;
        } else {
          clearSince = 0;
        }
      }
      await sleep(250);
    }
    throw new Error(`На странице не появилось поле ввода. ${pageFacts(site, "")}`);
  }

  // For checking a site by hand when its markup changes (`debug` on /api/web/ask): the shape of the
  // answer as tags, classes and lengths, with text only for the short labels that give a toolbar away.
  function answerSkeleton(site, promptHead) {
    const node = lastAnswer(site);
    const lines = [
      `picker ${query(site.picker)[0]?.innerText?.replace(/\s+/g, " ").slice(0, 60) || "нет"}; menu ${menuSeen || "нет"}`,
      `buttons ${query("button,[role='button']").map(labelOf).filter(Boolean).map((text) => text.slice(0, 24)).slice(-14).join(" | ")}`,
    ];
    if (!node) return `${lines[0]}\nno answer node; ${pageFacts(site, promptHead)}`;
    let up = node;
    for (let depth = 0; depth < 4 && up.parentElement; depth++) up = up.parentElement;
    const walk = (element, depth) => {
      if (lines.length > 90 || depth > 12) return;
      const name = `${element.tagName.toLowerCase()}.${String(element.className?.baseVal ?? element.className ?? "").trim().split(/\s+/).slice(0, 3).join(".").slice(0, 60)}`;
      const length = (element.textContent || "").length;
      const label = element.children.length === 0 && length > 0 && length <= 16 ? ` "${element.textContent.trim()}"` : "";
      const role = element.getAttribute("role") ? ` role=${element.getAttribute("role")}` : "";
      lines.push(`${" ".repeat(depth)}${element === node ? "*" : ""}${name}${role} ${length}${label}`);
      if (element.tagName.toLowerCase() !== "svg") [...element.children].forEach((child) => walk(child, depth + 1));
    };
    walk(up, 0);
    return lines.join("\n");
  }

  // A site may reopen the last conversation at its front page, and a turn must not continue it: the
  // old text would become context for the task, and the task would land in someone's own thread.
  async function ensureFreshChat(site) {
    if (!query(site.answer).length && !query(site.user).length) return;
    const isNew = (element) => /^(new chat|новый чат|new conversation|开启新对话|新建对话|新对话)/i.test(labelOf(element));
    const button = query("a,button,[role='button']").find(isNew);
    if (!button) throw new Error(`Сайт открыл старый чат, а кнопки нового чата нет. ${pageFacts(site, "")}`);
    button.click();
    const until = Date.now() + 8000;
    while (Date.now() < until) {
      if (!query(site.answer).length && !query(site.user).length && findComposer(site)) return;
      await sleep(200);
    }
    await trustedClickOn(button).catch(() => {});
    const retry = Date.now() + 5000;
    while (Date.now() < retry) {
      if (!query(site.answer).length && !query(site.user).length && findComposer(site)) return;
      await sleep(200);
    }
    throw new Error(`Новый чат не открылся. ${pageFacts(site, "")}`);
  }

  async function runTurn(door, doorLabel, task) {
    const site = SITES[door];
    if (!site) throw new Error(`Неизвестный сайт: ${door}.`);
    aborted = false;
    currentDoor = door;
    void phase("драйвер запущен");
    // Focus emulation for the whole turn, as for Gemini: a background page lays out and streams as if
    // it were in front. Not fatal: a page that does not need it still works.
    await trusted("begin").catch(() => {});
    void phase("жду страницу");
    await waitReady(site);
    await ensureFreshChat(site);
    void phase("выбор модели");
    await chooseModel(site);
    await chooseToggles(site);
    const text = String(task.text || "");
    // The first line only: pages collapse or restyle what follows it.
    const promptHead = text.trim().split("\n")[0].trim().slice(0, 40);
    void phase("ввод запроса");
    const composer = await typePrompt(site, text);
    void phase("отправка");
    await pressSend(site, composer, promptHead, text);
    void phase("жду ответ");
    const answer = await waitForAnswer(site, promptHead, task.max_wait_ms, text.trim());
    const used = usedLabel(site, doorLabel);
    return { text: task.debug ? `${answer}\n=== DOM ===\n${answerSkeleton(site, promptHead)}` : answer, used };
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === "DELEGATOR_DOOR_ABORT") {
      aborted = true;
      query("button,[role='button']").find((element) => STOP_LABEL.test(element.getAttribute("aria-label") || ""))?.click();
      return;
    }
    if (message?.type !== "DELEGATOR_DOOR_RUN") return;
    void runTurn(message.door, message.label, message.task)
      .then((result) => sendResponse(result))
      .catch((error) => sendResponse({ error: error instanceof Error ? error.message : String(error) }));
    return true;
  });
})();

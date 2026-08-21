const MODEL_GROUPS = [
  {
    label: "Auto",
    options: [{ value: "auto", label: "auto (Delegator)" }],
  },
  {
    label: "Gemini",
    options: [
      { value: "gemini-3.1-flash-lite", label: "Gemini 3.1 Flash-Lite" },
      { value: "gemini-2.5-pro", label: "Gemini 2.5 Pro" },
      { value: "gemini-2.5-flash", label: "Gemini 2.5 Flash" },
      { value: "gemini-2.5-flash-lite", label: "Gemini 2.5 Flash Lite" },
    ],
  },
  {
    label: "Codex",
    options: [
      { value: "gpt-5.5", label: "GPT-5.5" },
    ],
  },
  {
    label: "OpenCode / OpenRouter",
    options: [
      { value: "opencode/big-pickle", label: "Big Pickle Free" },
      { value: "opencode/deepseek-v4-flash-free", label: "DeepSeek V4 Flash Free" },
      { value: "opencode/laguna-s-2.1-free", label: "Laguna S 2.1 Free" },
      { value: "opencode/ling-3.0-flash-free", label: "Ling-3.0-flash Free" },
      { value: "opencode/mimo-v2.5-free", label: "MiMo V2.5 Free" },
      { value: "opencode/nemotron-3-ultra-free", label: "Nemotron 3 Ultra Free" },
      { value: "opencode/north-mini-code-free", label: "North Mini Code Free" },
      { value: "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free", label: "Nemotron 3 Ultra free" },
      { value: "openrouter/nvidia/nemotron-3-super-120b-a12b:free", label: "Nemotron 3 Super free" },
      { value: "openrouter/google/gemma-4-31b-it:free", label: "Gemma 4 31B free" },
      { value: "openrouter/google/gemma-4-26b-a4b-it:free", label: "Gemma 4 26B A4B free" },
      { value: "openrouter/cohere/north-mini-code:free", label: "North Mini Code free" },
      { value: "openrouter/inclusionai/ling-3.0-flash:free", label: "Ling 3.0 Flash free" },
      { value: "openrouter/openai/gpt-oss-20b:free", label: "gpt-oss-20b free" },
      { value: "openrouter/nvidia/nemotron-3-nano-30b-a3b:free", label: "Nemotron 3 Nano 30B free" },
      { value: "openrouter/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", label: "Nemotron 3 Nano Omni free" },
      { value: "openrouter/poolside/laguna-s-2.1:free", label: "Laguna S 2.1 free" },
      { value: "openrouter/poolside/laguna-xs-2.1:free", label: "Laguna XS 2.1 free" },
      { value: "openrouter/nvidia/nemotron-nano-12b-v2-vl:free", label: "Nemotron Nano 12B VL free" },
      { value: "openrouter/nvidia/nemotron-nano-9b-v2:free", label: "Nemotron Nano 9B free" },
      { value: "openrouter/nvidia/nemotron-3.5-content-safety:free", label: "Nemotron 3.5 Safety free" },
      { value: "openrouter/openrouter/free", label: "OpenRouter Free Router" },
    ],
  },
];

const REASONING_OPTIONS = {
  auto: [{ value: "auto", label: "auto" }],
  codex: [
    { value: "auto", label: "auto" },
    { value: "low", label: "low" },
    { value: "medium", label: "medium" },
    { value: "high", label: "high" },
    { value: "extra_high", label: "extra high" },
  ],
  opencode_default: [
    { value: "auto", label: "auto" },
    { value: "low", label: "low" },
    { value: "medium", label: "medium" },
    { value: "high", label: "high" },
  ],
  opencode_gpt5nano: [
    { value: "auto", label: "auto" },
    { value: "minimal", label: "minimal" },
    { value: "low", label: "low" },
    { value: "medium", label: "medium" },
    { value: "high", label: "high" },
  ],
  opencode_gptoss: [
    { value: "auto", label: "auto" },
    { value: "low", label: "low" },
    { value: "medium", label: "medium" },
    { value: "high", label: "high" },
    { value: "xhigh", label: "xhigh" },
  ],
  opencode_gemma: [
    { value: "auto", label: "auto" },
    { value: "low", label: "low" },
    { value: "high", label: "high" },
  ],
};

const THEME_KEY = "delegator-core:theme";
const FONT_KEY = "delegator-core:font";
const MODEL_KEY = "delegator-core:model";
const REASONING_KEY = "delegator-core:reasoning";
const NAV_KEY = "delegator-core:nav";
const PINNED_KEY = "delegator-core:pinned-sessions";
const SIDEBAR_WIDTH_KEY = "delegator-core:sidebar-width";
const CURRENT_SESSION_KEY = "delegator-core:current-session-id";
const DRAFTS_KEY = "delegator-core:drafts";
const ACTIVE_TASK_KEY = "delegator-core:active-task";

const state = {
  sessions: [],
  messages: [],
  messageCache: new Map(),
  currentSession: null,
  currentSessionId: null,
  config: null,
  sending: false,
  activeTaskId: null,
  activeEventSource: null,
  currentWorkspaceRoot: "D:\\Documents\\New project",
  currentTaskProvider: "",
  pendingTask: null,
  searchQuery: "",
  activeNav: "projects",
  editingMessage: null,
  selectedModel: "auto",
  selectedReasoning: "auto",
  pinnedSessions: new Set(),
  sidebarWidth: 290,
  pendingTicker: null,
  pendingStartedAt: 0,
  pendingPhase: "",
  importSyncTicker: null,
  healthTicker: null,
  draftPersistTimer: null,
  healthCheckRunning: false,
  serverOnline: true,
  reconnectQueued: false,
  searchRenderTimer: null,
  resizeQueued: false,
  inputHeight: 42,
  lastInputLines: 1,
  lastInputAt: 0,
  attachments: [],
  autoScrollLocked: false,
  suppressScrollTracking: false,
  visibleMessageLimit: 180,
  importSyncRunning: false,
};

const els = {
  configSummary: document.getElementById("configSummary"),
  navNew: document.getElementById("navNew"),
  navSearch: document.getElementById("navSearch"),
  navProjects: document.getElementById("navProjects"),
  panelNew: document.getElementById("panelNew"),
  searchPopover: document.getElementById("searchPopover"),
  panelProjects: document.getElementById("panelProjects"),
  newSessionForm: document.getElementById("newSessionForm"),
  sessionTitle: document.getElementById("sessionTitle"),
  searchInput: document.getElementById("searchInput"),
  resumeWorkspaceButton: document.getElementById("resumeWorkspaceButton"),
  workspaceHint: document.getElementById("workspaceHint"),
  importCodexButton: document.getElementById("importCodexButton"),
  quickNewChatButton: document.getElementById("quickNewChatButton"),
  refreshSessionsButton: document.getElementById("refreshSessionsButton"),
  sessionList: document.getElementById("sessionList"),
  sidebarResizer: document.getElementById("sidebarResizer"),
  settingsButton: document.getElementById("settingsButton"),
  restartServerButton: document.getElementById("restartServerButton"),
  settingsOverlay: document.getElementById("settingsOverlay"),
  closeSettingsButton: document.getElementById("closeSettingsButton"),
  themeSelect: document.getElementById("themeSelect"),
  fontSelect: document.getElementById("fontSelect"),
  modelsToggle: document.getElementById("modelsToggle"),
  modelsPanel: document.getElementById("modelsPanel"),
  modelsPanelClose: document.getElementById("modelsPanelClose"),
  modelsPanelBody: document.getElementById("modelsPanelBody"),
  usageToggle: document.getElementById("usageToggle"),
  usagePanel: document.getElementById("usagePanel"),
  usagePanelClose: document.getElementById("usagePanelClose"),
  usagePanelRefresh: document.getElementById("usagePanelRefresh"),
  usagePanelBody: document.getElementById("usagePanelBody"),
  modelDot: document.getElementById("modelDot"),
  topbarModelLabel: document.getElementById("topbarModelLabel"),
  activeModelsChips: document.getElementById("activeModelsChips"),
  topbarStatus: document.getElementById("topbarStatus"),
  messageList: document.getElementById("messageList"),
  chatForm: document.getElementById("chatForm"),
  editBanner: document.getElementById("editBanner"),
  editBannerText: document.getElementById("editBannerText"),
  cancelEditButton: document.getElementById("cancelEditButton"),
  footerStatus: document.getElementById("footerStatus"),
  attachmentTray: document.getElementById("attachmentTray"),
  attachmentInput: document.getElementById("attachmentInput"),
  attachButton: document.getElementById("attachButton"),
  modeSelect: document.getElementById("modeSelect"),
  modelSelect: document.getElementById("modelSelect"),
  reasoningSelect: document.getElementById("reasoningSelect"),
  messageInput: document.getElementById("messageInput"),
  sendButton: document.getElementById("sendButton"),
  messageTemplate: document.getElementById("messageTemplate"),
  pendingTemplate: document.getElementById("pendingTemplate"),
};

function api(path, options = {}) {
  return fetch(path, {
    headers: {
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
    ...options,
  }).then(async (response) => {
    if (!response.ok) {
      const text = await response.text();
      throw new Error(text || `HTTP ${response.status}`);
    }
    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("application/json")) {
      return response.json();
    }
    return response.text();
  });
}

function setStatus(text, isError = false, options = {}) {
  const { busy = false, phase = "" } = options;
  const value = (text || "").trim();
  if (!value || value === "Готово.") {
    els.footerStatus.hidden = true;
    els.footerStatus.textContent = "";
    delete els.footerStatus.dataset.busy;
    delete els.footerStatus.dataset.phase;
    return;
  }
  els.footerStatus.hidden = false;
  els.footerStatus.textContent = value;
  els.footerStatus.style.color = isError ? "var(--danger)" : "var(--muted)";
  if (busy && !isError) {
    els.footerStatus.dataset.busy = "true";
  } else {
    delete els.footerStatus.dataset.busy;
  }
  if (phase) {
    els.footerStatus.dataset.phase = phase;
  } else {
    delete els.footerStatus.dataset.phase;
  }
}

function formatTaskPhaseLabel(phase) {
  switch (phase) {
    case "prepare":
      return "Подготавливаю контекст";
    case "queue":
      return "Запрос в очереди";
    case "thinking":
      return "Модель обдумывает ответ";
    case "stream":
      return "Модель формирует итоговый ответ";
    case "reconnect":
      return "Переподключаюсь к задаче";
    case "server":
      return "Сервер перезапускается";
    default:
      return "Выполняется";
  }
}

function setTaskStatus(phase, provider, seconds = 0) {
  state.pendingPhase = phase || "";
  const label = formatTaskPhaseLabel(state.pendingPhase);
  const providerLabel = provider ? `: ${formatProviderLabel(provider)}` : "";
  const secondsLabel = seconds > 0 ? ` · ${seconds}с` : "";
  setStatus(`${label}${providerLabel}${secondsLabel}`, false, { busy: true, phase: state.pendingPhase });
}

function getInitialWorkspaceRoot() {
  const params = new URLSearchParams(window.location.search);
  const value = params.get("workspace_root");
  return value && value.trim() ? value.trim() : state.currentWorkspaceRoot;
}

function shouldResumeWorkspaceOnLoad() {
  const params = new URLSearchParams(window.location.search);
  return params.get("resume") === "1";
}

function preferredOutputLanguage(text) {
  const value = text || "";
  if (/[А-Яа-яЁё]/.test(value)) return "ru";
  return "en";
}

function formatTimestamp(value) {
  try {
    return new Date(value).toLocaleString("ru-RU");
  } catch {
    return value;
  }
}

function normalizeTimestampKey(value) {
  const source = (value || "").trim();
  if (!source) return "";
  const ms = Date.parse(source);
  if (Number.isNaN(ms)) return source;
  return new Date(ms).toISOString();
}

function formatWorkspaceLabel(session) {
  if (!session.workspace_root) {
    return session.client || "local";
  }
  const workspaceLabel = state.config?.workspace_labels?.[session.workspace_root];
  const normalized = session.workspace_root.replaceAll("\\", "/");
  const parts = normalized.split("/").filter(Boolean);
  const projectName = parts.length ? parts[parts.length - 1] : session.workspace_root;
  const prefix = workspaceLabel ? `${workspaceLabel} · ` : "";
  return `${prefix}${projectName} · ${session.workspace_root}`;
}

function formatTokenCount(value) {
  const num = Number(value);
  if (!Number.isFinite(num)) return "0";
  return Math.round(num).toLocaleString("ru-RU");
}

function formatUsageCost(value) {
  const num = Number(value);
  if (!Number.isFinite(num) || num <= 0) return "";
  return `$${num >= 1 ? num.toFixed(2) : num.toFixed(4)}`;
}

function formatElapsedSeconds(value) {
  const num = Number(value);
  if (!Number.isFinite(num) || num <= 0) return "";
  return `${(num / 1000).toFixed(1).replace(".", ",")} с`;
}

function buildUsageBadgeText(source) {
  if (!source || typeof source !== "object") return "";
  const model = String(source.model || "").trim();
  const totalTokens = Number(source.total_tokens);
  const hasTokens = source.total_tokens != null && Number.isFinite(totalTokens) && totalTokens > 0;
  if (!model && !hasTokens) return "";
  const parts = [];
  if (model) parts.push(getModelLabel(model));
  if (hasTokens) parts.push(`${formatTokenCount(totalTokens)} ток.`);
  const cost = formatUsageCost(source.cost);
  if (cost) parts.push(cost);
  const elapsed = formatElapsedSeconds(source.elapsed_ms);
  if (elapsed) parts.push(elapsed);
  return parts.join(" · ");
}

function buildUsageTooltip(source) {
  if (!source || typeof source !== "object") return "";
  const details = [];
  if (source.prompt_tokens != null && Number.isFinite(Number(source.prompt_tokens))) {
    details.push(`Промпт: ${formatTokenCount(source.prompt_tokens)} ток.`);
  }
  if (source.completion_tokens != null && Number.isFinite(Number(source.completion_tokens))) {
    details.push(`Ответ: ${formatTokenCount(source.completion_tokens)} ток.`);
  }
  if (source.provider) {
    details.push(`Провайдер: ${source.provider}`);
  }
  return details.join(" · ");
}

function sameMessageKey(left, right) {
  return [
    left.role || "",
    left.content || "",
    normalizeTimestampKey(left.created_at || ""),
  ].join("\u241f") === [
    right.role || "",
    right.content || "",
    normalizeTimestampKey(right.created_at || ""),
  ].join("\u241f");
}

function dedupeMessages(messages) {
  const result = [];
  const indexByKey = new Map();
  for (const message of messages || []) {
    const key = [
      message.role || "",
      message.content || "",
      normalizeTimestampKey(message.created_at || ""),
    ].join("\u241f");
    const existingIndex = indexByKey.get(key);
    if (existingIndex === undefined) {
      indexByKey.set(key, result.length);
      result.push(message);
      continue;
    }
    const existing = result[existingIndex];
    result[existingIndex] = {
      ...existing,
      ...message,
      provider: existing.provider || message.provider || null,
      mode: existing.mode || message.mode || null,
      model: existing.model || message.model || null,
      prompt_tokens: existing.prompt_tokens ?? message.prompt_tokens ?? null,
      completion_tokens: existing.completion_tokens ?? message.completion_tokens ?? null,
      total_tokens: existing.total_tokens ?? message.total_tokens ?? null,
      cost: existing.cost ?? message.cost ?? null,
      elapsed_ms: existing.elapsed_ms ?? message.elapsed_ms ?? null,
      created_at: normalizeTimestampKey(existing.created_at || message.created_at || ""),
    };
  }
  return result;
}

function buildDisplayMessages(messages) {
  const source = dedupeMessages(messages || []);
  const result = [];
  let index = 0;
  while (index < source.length) {
    const current = source[index];
    if (current.role !== "assistant") {
      result.push(current);
      index += 1;
      continue;
    }
    let end = index;
    while (end + 1 < source.length && source[end + 1].role === "assistant") {
      end += 1;
    }
    if (end === index) {
      result.push(current);
      index += 1;
      continue;
    }
    const last = { ...source[end] };
    const reasoningParts = source
      .slice(index, end)
      .map((item) => (item.content || "").trim())
      .filter(Boolean);
    if (reasoningParts.length) {
      last._groupedReasoning = reasoningParts.join("\n\n");
      last._groupedReasoningCount = reasoningParts.length;
    }
    result.push(last);
    index = end + 1;
  }
  return result;
}

function getSelectedModel() {
  return els.modelSelect.value && els.modelSelect.value !== "auto" ? els.modelSelect.value : null;
}

function getSelectedReasoning() {
  return els.reasoningSelect.value && els.reasoningSelect.value !== "auto" ? els.reasoningSelect.value : null;
}

function getModelLabel(value) {
  for (const group of MODEL_GROUPS) {
    const match = group.options.find((option) => option.value === value);
    if (match) return match.label;
  }
  return value || "auto";
}

function getReasoningProfile(model) {
  if (!model || model === "auto") return REASONING_OPTIONS.auto;
  if (model.startsWith("gpt-5.") || model.startsWith("gpt-5.3-codex")) return REASONING_OPTIONS.codex;
  if (model.includes("gpt-5-nano")) return REASONING_OPTIONS.opencode_gpt5nano;
  if (model.includes("gpt-oss-")) return REASONING_OPTIONS.opencode_gptoss;
  if (model.includes("gemma-4-31b")) return REASONING_OPTIONS.opencode_gemma;
  if (
    model.includes("hy3-preview")
    || model.includes("nemotron")
    || model.includes("ling-")
    || model.includes("minimax")
    || model.includes("mimo")
    || model.includes("deepseek-v4")
    || model.includes("laguna-s")
    || model.includes("north-mini")
  ) {
    return REASONING_OPTIONS.opencode_default;
  }
  return REASONING_OPTIONS.auto;
}

function estimateReasoningScore(text, mode) {
  const value = (text || "").trim();
  if (!value) return 0;
  let score = 0;
  const lines = value.split(/\r?\n/).length;
  const lowered = value.toLowerCase();
  if (mode === "boost") score += 4;
  if (mode === "verify") score += 3;
  if (value.length > 700) score += 3;
  else if (value.length > 260) score += 2;
  else if (value.length > 80) score += 1;
  if (lines >= 8) score += 2;
  else if (lines >= 4) score += 1;
  if (/```|traceback|stack|exception|ошиб|error|debug|investigat|проанализ|архитект|security|benchmark|root cause|найди причину|почему|refactor|compare|audit|verify|оптимиз/i.test(lowered)) {
    score += 2;
  }
  if (_message_is_greeting(value)) score -= 3;
  if (value.length <= 24 && !/\n/.test(value)) score -= 1;
  return score;
}

function resolveAutoReasoning(model, mode, text) {
  const options = getReasoningProfile(model).map((item) => item.value).filter((value) => value !== "auto");
  if (!options.length) return null;
  const score = estimateReasoningScore(text, mode);
  if (model && (model.startsWith("gpt-5.") || model.startsWith("gpt-5.3-codex"))) {
    if (score <= 0) return "low";
    if (score <= 2) return "medium";
    if (score <= 4) return "high";
    return options.includes("extra_high") ? "extra_high" : "high";
  }
  if (model && model.includes("gpt-oss-")) {
    if (score <= 0) return "low";
    if (score <= 2) return "medium";
    if (score <= 4) return "high";
    return options.includes("xhigh") ? "xhigh" : "high";
  }
  if (model && model.includes("gpt-5-nano")) {
    if (score <= -1) return "minimal";
    if (score <= 1) return "low";
    if (score <= 3) return "medium";
    return "high";
  }
  if (model && model.includes("gemma-4-31b")) {
    return score >= 3 ? "high" : "low";
  }
  if (score <= 0) return options.includes("low") ? "low" : options[0];
  if (score <= 2) {
    if (options.includes("medium")) return "medium";
    if (options.includes("low")) return "low";
    return options[0];
  }
  return options.includes("high") ? "high" : options[options.length - 1];
}

function renderModelOptions() {
  els.modelSelect.innerHTML = "";
  for (const group of MODEL_GROUPS) {
    const optgroup = document.createElement("optgroup");
    optgroup.label = group.label;
    for (const option of group.options) {
      const node = document.createElement("option");
      node.value = option.value;
      node.textContent = option.label;
      optgroup.appendChild(node);
    }
    els.modelSelect.appendChild(optgroup);
  }
  const saved = window.localStorage.getItem(MODEL_KEY) || "auto";
  state.selectedModel = saved;
  els.modelSelect.value = saved;
  renderReasoningOptions();
  fitComposerControls();
}

// ── Model stats tracking ──
let modelStats = null;
function getModelStats() {
  if (!modelStats) modelStats = loadJsonStorage("delegator-core:model-stats", {});
  return modelStats;
}

function recordModelUse(model) {
  if (!model || model === "auto") return;
  const stats = getModelStats();
  stats[model] = (stats[model] || 0) + 1;
  window.localStorage.setItem("delegator-core:model-stats", JSON.stringify(stats));
}

function updateTopbar() {
  const selected = state.selectedModel || "auto";
  const active = state.currentTaskProvider;
  const isActive = !!active && state.sending;

  els.topbarModelLabel.textContent = getModelLabel(selected);
  els.modelDot.dataset.active = isActive ? "true" : "false";

  els.activeModelsChips.innerHTML = "";
  if (isActive && active !== selected) {
    const chip = document.createElement("span");
    chip.className = "model-chip";
    chip.innerHTML = `<span class="model-chip-dot"></span>${escapeHtml(getModelLabel(active))}`;
    els.activeModelsChips.appendChild(chip);
  }

  if (els.topbarStatus) {
    els.topbarStatus.textContent = isActive ? `${getModelLabel(active)} · активна` : "";
  }

  if (!els.modelsPanel.hidden) renderModelsPanel();
}

function renderModelsPanel() {
  const selected = state.selectedModel || "auto";
  const active = state.currentTaskProvider;
  const isActive = state.sending;
  els.modelsPanelBody.innerHTML = "";

  for (const group of MODEL_GROUPS) {
    const groupLabel = document.createElement("div");
    groupLabel.className = "model-group-label";
    groupLabel.textContent = group.label;
    els.modelsPanelBody.appendChild(groupLabel);

    for (const option of group.options) {
      const row = document.createElement("div");
      row.className = "model-row";
      const isSelected = option.value === selected;
      const isRunning = isActive && option.value === active;
      row.dataset.selected = isSelected ? "true" : "false";
      row.dataset.active = isRunning ? "true" : "false";

      const uses = getModelStats()[option.value] || 0;
      const metaText = uses > 0 ? `${uses} исп.` : "";

      row.innerHTML = `
        <span class="model-row-dot"></span>
        <span class="model-row-name">${escapeHtml(option.label)}</span>
        ${isRunning ? `<span class="model-row-badge">активна</span>` : ""}
        ${metaText ? `<span class="model-row-meta">${escapeHtml(metaText)}</span>` : ""}
        <button class="model-row-select-btn" type="button">${isSelected ? "выбрана" : "выбрать"}</button>
      `;

      row.querySelector(".model-row-select-btn").addEventListener("click", (e) => {
        e.stopPropagation();
        selectModelFromPanel(option.value);
      });
      row.addEventListener("click", () => selectModelFromPanel(option.value));
      els.modelsPanelBody.appendChild(row);
    }
  }
}

function selectModelFromPanel(value) {
  state.selectedModel = value;
  els.modelSelect.value = value;
  window.localStorage.setItem(MODEL_KEY, value);
  renderReasoningOptions();
  fitComposerControls();
  updateTopbar();
  closeModelsPanel();
}

function openModelsPanel() {
  els.modelsPanel.hidden = false;
  els.modelsToggle.setAttribute("aria-expanded", "true");
  renderModelsPanel();
}

function closeModelsPanel() {
  els.modelsPanel.hidden = true;
  els.modelsToggle.setAttribute("aria-expanded", "false");
}

// ── Usage stats panel ──
function usageNumber(...values) {
  for (const value of values) {
    if (value == null) continue;
    const num = Number(value);
    if (Number.isFinite(num)) return num;
  }
  return 0;
}

function formatUsageDate(value) {
  const source = String(value || "").trim();
  if (!source) return "—";
  const ms = Date.parse(source);
  if (Number.isNaN(ms)) return source;
  return new Date(ms).toLocaleDateString("ru-RU", { day: "2-digit", month: "2-digit", year: "numeric" });
}

function setUsagePanelStatus(text) {
  els.usagePanelBody.innerHTML = "";
  const node = document.createElement("div");
  node.className = "usage-status";
  node.textContent = text;
  els.usagePanelBody.appendChild(node);
}

function buildUsageTableHtml(headers, rows) {
  const head = headers
    .map((header) => `<th${header.numeric ? ` class="usage-num"` : ""}>${escapeHtml(header.label)}</th>`)
    .join("");
  const body = rows
    .map((cells) => `<tr>${cells
      .map((cell) => `<td${cell.numeric ? ` class="usage-num"` : ""}>${escapeHtml(cell.text)}</td>`)
      .join("")}</tr>`)
    .join("");
  return `<table class="usage-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function appendUsageSection(body, label, rowsHtml, emptyText) {
  const sectionLabel = document.createElement("div");
  sectionLabel.className = "model-group-label";
  sectionLabel.textContent = label;
  body.appendChild(sectionLabel);
  if (!rowsHtml) {
    const empty = document.createElement("div");
    empty.className = "usage-status";
    empty.textContent = emptyText;
    body.appendChild(empty);
    return;
  }
  const wrapper = document.createElement("div");
  wrapper.className = "usage-table-wrap";
  wrapper.innerHTML = rowsHtml;
  body.appendChild(wrapper);
}

function renderUsagePanel(data) {
  const body = els.usagePanelBody;
  body.innerHTML = "";

  const today = data?.today || {};
  const savedTokens = usageNumber(data?.savedOutputTokens, data?.savedTokensTotal, data?.saved_tokens_total);
  const handledTokens = usageNumber(data?.handledTokens, data?.handled_tokens);
  const spentTokens = usageNumber(data?.spentTokensTotal, data?.spent_tokens_total);
  const delegations = usageNumber(data?.delegations);
  const todayTokens = usageNumber(today.totalTokens, today.total_tokens);
  const todayCost = formatUsageCost(usageNumber(today.cost));

  const savedHint =
    "Оценка: выходные токены, которые дорогой модели IDE не пришлось генерировать — " +
    `Делегатор отдал ${formatTokenCount(delegations)} готовых ответов и перемолол ` +
    `${formatTokenCount(handledTokens)} ток. контекста вместо неё. Бенчмарки не учитываются.`;

  const summary = document.createElement("div");
  summary.className = "usage-summary";
  summary.innerHTML = `
    <div class="usage-card" data-accent="true" title="${escapeHtml(savedHint)}">
      <div class="usage-card-value">${escapeHtml(formatTokenCount(savedTokens))}</div>
      <div class="usage-card-label">Сэкономлено основной модели</div>
    </div>
    <div class="usage-card" title="Токены бесплатных моделей Делегатора: внутренние стадии и неудачные попытки тоже здесь">
      <div class="usage-card-value">${escapeHtml(formatTokenCount(spentTokens))}</div>
      <div class="usage-card-label">Потрачено Делегатором</div>
    </div>
    <div class="usage-card" title="Сколько раз задача реально ушла в Делегатор за период">
      <div class="usage-card-value">${escapeHtml(formatTokenCount(delegations))}</div>
      <div class="usage-card-label">Делегирований</div>
    </div>
    <div class="usage-card">
      <div class="usage-card-value">${escapeHtml(formatTokenCount(todayTokens))}${todayCost ? ` <span class="usage-card-extra">${escapeHtml(todayCost)}</span>` : ""}</div>
      <div class="usage-card-label">Токенов сегодня</div>
    </div>
  `;
  body.appendChild(summary);

  const modelsSource = data?.byModel ?? data?.by_model;
  const models = Array.isArray(modelsSource) ? modelsSource : [];
  let modelsHtml = "";
  if (models.length) {
    const showModelCost = models.some((item) => usageNumber(item.cost) > 0);
    const sortedModels = [...models].sort(
      (left, right) => usageNumber(right.totalTokens, right.total_tokens) - usageNumber(left.totalTokens, left.total_tokens),
    );
    modelsHtml = buildUsageTableHtml(
      [
        { label: "Модель" },
        { label: "Запросы", numeric: true },
        { label: "Токены", numeric: true },
        ...(showModelCost ? [{ label: "Стоимость", numeric: true }] : []),
      ],
      sortedModels.map((item) => [
        { text: item.model ? getModelLabel(item.model) : "—" },
        { text: formatTokenCount(usageNumber(item.requests)), numeric: true },
        { text: formatTokenCount(usageNumber(item.totalTokens, item.total_tokens)), numeric: true },
        ...(showModelCost ? [{ text: formatUsageCost(usageNumber(item.cost)) || "—", numeric: true }] : []),
      ]),
    );
  }
  appendUsageSection(body, "По моделям", modelsHtml, "Данных по моделям пока нет.");

  const dailySource = data?.daily;
  const daily = Array.isArray(dailySource) ? dailySource : [];
  let dailyHtml = "";
  if (daily.length) {
    const showDailyCost = daily.some((item) => usageNumber(item.cost) > 0);
    const sortedDaily = [...daily].sort((left, right) => String(right.date || "").localeCompare(String(left.date || "")));
    dailyHtml = buildUsageTableHtml(
      [
        { label: "Дата" },
        { label: "Запросы", numeric: true },
        { label: "Токены", numeric: true },
        ...(showDailyCost ? [{ label: "Стоимость", numeric: true }] : []),
      ],
      sortedDaily.map((item) => [
        { text: formatUsageDate(item.date) },
        { text: formatTokenCount(usageNumber(item.requests)), numeric: true },
        { text: formatTokenCount(usageNumber(item.totalTokens, item.total_tokens)), numeric: true },
        ...(showDailyCost ? [{ text: formatUsageCost(usageNumber(item.cost)) || "—", numeric: true }] : []),
      ]),
    );
  }
  appendUsageSection(body, "По дням", dailyHtml, "Данных по дням пока нет.");
}

async function refreshUsagePanel() {
  setUsagePanelStatus("Загружаю статистику...");
  try {
    const data = await api("/api/usage?days=7");
    renderUsagePanel(data);
  } catch {
    setUsagePanelStatus("Статистика пока недоступна");
  }
}

function openUsagePanel() {
  closeModelsPanel();
  els.usagePanel.hidden = false;
  els.usageToggle.setAttribute("aria-expanded", "true");
  void refreshUsagePanel();
}

function closeUsagePanel() {
  els.usagePanel.hidden = true;
  els.usageToggle.setAttribute("aria-expanded", "false");
}

function renderReasoningOptions() {
  const selectedModel = els.modelSelect.value || "auto";
  const options = getReasoningProfile(selectedModel);
  const saved = window.localStorage.getItem(REASONING_KEY) || "auto";
  els.reasoningSelect.innerHTML = "";
  for (const option of options) {
    const node = document.createElement("option");
    node.value = option.value;
    node.textContent = option.label;
    els.reasoningSelect.appendChild(node);
  }
  const next = options.some((option) => option.value === saved) ? saved : "auto";
  state.selectedReasoning = next;
  els.reasoningSelect.value = next;
  fitComposerControls();
}

function loadUiPrefs() {
  const theme = window.localStorage.getItem(THEME_KEY) || "codex-green";
  const font = window.localStorage.getItem(FONT_KEY) || "segoe";
  const nav = window.localStorage.getItem(NAV_KEY) || "projects";
  const sidebarWidth = Number(window.localStorage.getItem(SIDEBAR_WIDTH_KEY) || 290);
  const reasoning = window.localStorage.getItem(REASONING_KEY) || "auto";
  const pinnedRaw = window.localStorage.getItem(PINNED_KEY);
  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.font = font;
  state.sidebarWidth = Number.isFinite(sidebarWidth) ? sidebarWidth : 290;
  document.documentElement.style.setProperty("--sidebar-width", `${state.sidebarWidth}px`);
  try {
    const parsed = pinnedRaw ? JSON.parse(pinnedRaw) : [];
    state.pinnedSessions = new Set(Array.isArray(parsed) ? parsed : []);
  } catch {
    state.pinnedSessions = new Set();
  }
  state.currentSessionId = getSavedCurrentSessionId();
  state.selectedReasoning = reasoning;
  els.themeSelect.value = theme;
  els.fontSelect.value = font;
  state.activeNav = nav;
}

function saveUiPref(key, value) {
  window.localStorage.setItem(key, value);
}

function loadJsonStorage(key, fallback) {
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return fallback;
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

function loadDraftMap() {
  const value = loadJsonStorage(DRAFTS_KEY, {});
  return value && typeof value === "object" ? value : {};
}

function saveDraftMap(value) {
  window.localStorage.setItem(DRAFTS_KEY, JSON.stringify(value || {}));
}

function saveCurrentSessionId(sessionId) {
  if (!sessionId) {
    window.localStorage.removeItem(CURRENT_SESSION_KEY);
    return;
  }
  window.localStorage.setItem(CURRENT_SESSION_KEY, sessionId);
}

function getSavedCurrentSessionId() {
  return (window.localStorage.getItem(CURRENT_SESSION_KEY) || "").trim() || null;
}

function persistDraftForSession(sessionId, text) {
  if (!sessionId) return;
  const drafts = loadDraftMap();
  if (!text) {
    delete drafts[sessionId];
  } else {
    drafts[sessionId] = {
      text,
      updated_at: new Date().toISOString(),
    };
  }
  const entries = Object.entries(drafts)
    .sort((left, right) => new Date(right[1]?.updated_at || 0) - new Date(left[1]?.updated_at || 0))
    .slice(0, 30);
  saveDraftMap(Object.fromEntries(entries));
}

function scheduleDraftPersist() {
  if (state.draftPersistTimer) {
    window.clearTimeout(state.draftPersistTimer);
  }
  state.draftPersistTimer = window.setTimeout(() => {
    state.draftPersistTimer = null;
    persistDraftForSession(state.currentSessionId, els.messageInput.value || "");
  }, 180);
}

function restoreDraftForSession(sessionId) {
  if (!sessionId) {
    els.messageInput.value = "";
    autoResizeInput(true);
    return;
  }
  const drafts = loadDraftMap();
  const text = drafts?.[sessionId]?.text || "";
  els.messageInput.value = text;
  state.lastInputAt = Date.now();
  autoResizeInput(true);
}

function loadPersistedActiveTask() {
  const value = loadJsonStorage(ACTIVE_TASK_KEY, null);
  return value && typeof value === "object" ? value : null;
}

function persistActiveTask(task) {
  if (!task?.taskId || !task?.sessionId) return;
  window.localStorage.setItem(
    ACTIVE_TASK_KEY,
    JSON.stringify({
      taskId: task.taskId,
      sessionId: task.sessionId,
      provider: task.provider || "",
      mode: task.mode || "",
      reasoning: task.reasoning || "",
      preview: task.preview || "",
      updated_at: new Date().toISOString(),
    }),
  );
}

function clearPersistedActiveTask() {
  window.localStorage.removeItem(ACTIVE_TASK_KEY);
}

function looksOfflineError(error) {
  const text = String(error?.message || error || "");
  return /Failed to fetch|NetworkError|fetch|ECONNREFUSED|connection|network/i.test(text);
}

function fitControlWidth(control) {
  if (!control) return;
  const text = control.options?.[control.selectedIndex]?.textContent || control.value || "";
  const probe = document.createElement("span");
  probe.textContent = `  ${text}  `;
  probe.style.position = "absolute";
  probe.style.visibility = "hidden";
  probe.style.whiteSpace = "pre";
  probe.style.font = window.getComputedStyle(control).font;
  document.body.appendChild(probe);
  const width = Math.min(420, Math.max(92, Math.ceil(probe.getBoundingClientRect().width) + 26));
  document.body.removeChild(probe);
  control.style.width = `${width}px`;
}

function fitComposerControls() {
  fitControlWidth(els.modeSelect);
  fitControlWidth(els.modelSelect);
  fitControlWidth(els.reasoningSelect);
}

function switchNav(name) {
  state.activeNav = name;
  saveUiPref(NAV_KEY, name);
  for (const [key, button] of [["new", els.navNew], ["search", els.navSearch], ["projects", els.navProjects]]) {
    button.dataset.active = key === name ? "true" : "false";
  }
  els.panelNew.hidden = name !== "new";
  els.panelProjects.hidden = name !== "projects";
  if (name !== "search") {
    hideSearchPopover();
  }
}

function setSending(sending) {
  state.sending = sending;
  els.sendButton.disabled = sending || !state.currentSessionId;
  els.messageInput.disabled = sending || !state.currentSessionId;
  els.modeSelect.disabled = sending;
  els.modelSelect.disabled = sending;
  els.reasoningSelect.disabled = sending;
  els.importCodexButton.disabled = sending;
  els.resumeWorkspaceButton.disabled = sending;
  updateTopbar();
}

let searchPopoverHideTimer = null;

function showSearchPopover() {
  if (searchPopoverHideTimer) {
    window.clearTimeout(searchPopoverHideTimer);
    searchPopoverHideTimer = null;
  }
  els.searchPopover.hidden = false;
  els.navSearch.dataset.active = "true";
}

function hideSearchPopoverDelayed() {
  if (searchPopoverHideTimer) {
    window.clearTimeout(searchPopoverHideTimer);
  }
  searchPopoverHideTimer = window.setTimeout(() => {
    hideSearchPopover();
  }, 140);
}

function hideSearchPopover() {
  if (searchPopoverHideTimer) {
    window.clearTimeout(searchPopoverHideTimer);
    searchPopoverHideTimer = null;
  }
  els.searchPopover.hidden = true;
  if (state.activeNav !== "search") {
    els.navSearch.dataset.active = "false";
  }
}

function closeActiveStream(options = {}) {
  const { preservePersisted = false } = options;
  if (state.activeEventSource) {
    state.activeEventSource.close();
    state.activeEventSource = null;
  }
  state.activeTaskId = null;
  state.currentTaskProvider = "";
  state.pendingTask = null;
  clearPendingTicker();
  if (!preservePersisted) {
    clearPersistedActiveTask();
  }
}

function setServerOnline(isOnline) {
  const changed = state.serverOnline !== isOnline;
  state.serverOnline = isOnline;
  if (!changed) return;
  if (!isOnline) {
    setStatus("Delegator Core перезапускается или недоступен. Состояние чата сохранено.", true, { phase: "server" });
    return;
  }
  setStatus("Delegator Core восстановлен. Возобновляю чат...", false, { busy: true, phase: "reconnect" });
}

async function recoverPersistedTask() {
  const persisted = loadPersistedActiveTask();
  if (!persisted?.taskId || !persisted?.sessionId) return;
  if (!state.currentSessionId || persisted.sessionId !== state.currentSessionId) return;
  if (state.activeTaskId === persisted.taskId && state.activeEventSource) return;
  try {
    const task = await api(`/api/chat/tasks/${persisted.taskId}`);
    state.currentTaskProvider = task.provider || persisted.provider || "auto";
    if (task.status === "queued" || task.status === "running") {
      state.activeTaskId = task.id;
      setPendingTask(
        `Восстанавливаю задачу: ${formatProviderLabel(state.currentTaskProvider)}`,
        `${state.currentTaskProvider || "auto"} · ${task.mode || persisted.mode || "delegate"}`,
        persisted.preview || "",
      );
      setSending(true);
      setTaskStatus("reconnect", state.currentTaskProvider || task.provider || persisted.provider || "auto", 0);
      await streamTask(task.id, { recovering: true });
      return;
    }
    clearPersistedActiveTask();
    if (task.status === "completed" || task.status === "failed") {
      await refreshCurrentSession({ activate: false, refreshList: true });
      if (task.status === "failed" && task.error) {
        setStatus(`Предыдущая задача завершилась ошибкой: ${task.error}`, true);
      }
    }
  } catch (error) {
    if (looksOfflineError(error)) {
      setServerOnline(false);
      return;
    }
    clearPersistedActiveTask();
  }
}

async function checkServerHealth() {
  if (state.healthCheckRunning) return;
  state.healthCheckRunning = true;
  try {
    const response = await fetch("/health", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const wasOffline = !state.serverOnline;
    setServerOnline(true);
    if (wasOffline) {
      if (state.currentSessionId) {
        try {
          await refreshCurrentSession({ activate: false, refreshList: true });
        } catch {}
      }
      await recoverPersistedTask();
    }
  } catch {
    setServerOnline(false);
  } finally {
    state.healthCheckRunning = false;
  }
}

function startHealthMonitor() {
  if (state.healthTicker) return;
  state.healthTicker = window.setInterval(() => {
    void checkServerHealth();
  }, 4000);
}

function autoResizeInput(force = false) {
  state.resizeQueued = false;
  const area = els.messageInput;
  const baseHeight = 42;
  const maxHeight = Math.floor(window.innerHeight * 0.4);
  const lineCount = Math.max(1, (area.value.match(/\n/g) || []).length + 1);
  if (!force && lineCount === state.lastInputLines && state.inputHeight) return;
  const lineHeight = 20;
  const next = Math.min(maxHeight, Math.max(baseHeight, baseHeight + ((lineCount - 1) * lineHeight)));
  area.style.height = `${next}px`;
  state.inputHeight = next;
  state.lastInputLines = lineCount;
}

function scheduleAutoResize() {
  if (state.resizeQueued) return;
  state.resizeQueued = true;
  window.requestAnimationFrame(autoResizeInput);
}

function showEditBanner() {
  if (!state.editingMessage) {
    els.editBanner.hidden = true;
    return;
  }
  els.editBanner.hidden = false;
  els.editBannerText.textContent = "Редактирование сообщения. Отправка создаст новую версию запроса.";
}

function clearEditing() {
  state.editingMessage = null;
  els.messageInput.value = "";
  showEditBanner();
  autoResizeInput();
  setStatus("Редактирование отменено.");
}

function flashActiveSession() {
  const active = els.sessionList.querySelector(".session-item[data-active='true']");
  if (!active) return;
  active.dataset.flash = "true";
  active.scrollIntoView({ block: "nearest", behavior: "smooth" });
  window.setTimeout(() => {
    if (active.dataset.active === "true") {
      delete active.dataset.flash;
    }
  }, 1200);
}

function filteredSessions() {
  const query = state.searchQuery.trim().toLowerCase();
  const base = !query ? [...state.sessions] : state.sessions.filter((session) => {
    const haystack = [
      session.title,
      session.client,
      session.workspace_root,
      state.config?.workspace_labels?.[session.workspace_root || ""] || "",
      session.source_kind,
      session.search_text,
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    return haystack.includes(query);
  });
  return base.sort((left, right) => {
    const leftPinned = state.pinnedSessions.has(left.id);
    const rightPinned = state.pinnedSessions.has(right.id);
    if (leftPinned !== rightPinned) return leftPinned ? -1 : 1;
    return new Date(right.updated_at) - new Date(left.updated_at);
  });
}

function savePinnedSessions() {
  saveUiPref(PINNED_KEY, JSON.stringify([...state.pinnedSessions]));
}

function togglePinnedSession(sessionId) {
  if (state.pinnedSessions.has(sessionId)) {
    state.pinnedSessions.delete(sessionId);
  } else {
    state.pinnedSessions.add(sessionId);
  }
  savePinnedSessions();
  renderSessions();
}

function clampSidebarWidth(value) {
  const min = Math.max(220, Math.floor(window.innerWidth / 20));
  const max = Math.max(min, Math.floor(window.innerWidth / 3));
  return Math.min(max, Math.max(min, value));
}

function applySidebarWidth(value) {
  state.sidebarWidth = clampSidebarWidth(value);
  document.documentElement.style.setProperty("--sidebar-width", `${state.sidebarWidth}px`);
  saveUiPref(SIDEBAR_WIDTH_KEY, String(state.sidebarWidth));
}

function renderSessions() {
  const sessions = filteredSessions();
  els.sessionList.innerHTML = "";
  const fragment = document.createDocumentFragment();
  if (!sessions.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = state.searchQuery ? "Ничего не найдено." : "Сессий пока нет.";
    fragment.appendChild(empty);
    els.sessionList.appendChild(fragment);
    return;
  }

  for (const session of sessions) {
    const button = document.createElement("div");
    button.className = "session-item";
    button.tabIndex = 0;
    button.setAttribute("role", "button");
    if (session.id === state.currentSessionId) {
      button.dataset.active = "true";
    }
    button.innerHTML = `
      <div class="session-main">
        <span class="session-item-title">${escapeHtml(session.title)}</span>
        <span class="session-item-meta">${escapeHtml(formatWorkspaceLabel(session))}</span>
        <span class="session-item-meta">${escapeHtml(session.client || "local")} · ${escapeHtml(formatTimestamp(session.updated_at))}</span>
      </div>
      <div class="session-side">
        <button class="session-rename" type="button" title="Переименовать чат" aria-label="Переименовать чат">✎</button>
        <button class="session-pin" type="button" title="Закрепить чат">${state.pinnedSessions.has(session.id) ? "★" : "☆"}</button>
      </div>
    `;
    const renameButton = button.querySelector(".session-rename");
    const pinButton = button.querySelector(".session-pin");
    pinButton.dataset.pinned = state.pinnedSessions.has(session.id) ? "true" : "false";
    renameButton.addEventListener("click", async (event) => {
      event.preventDefault();
      event.stopPropagation();
      try {
        await renameSession(session.id);
      } catch (error) {
        setStatus(`Ошибка переименования: ${error.message}`, true);
      }
    });
    pinButton.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      togglePinnedSession(session.id);
    });
    button.addEventListener("click", () => selectSession(session.id));
    button.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        selectSession(session.id);
      }
    });
    fragment.appendChild(button);
  }
  els.sessionList.appendChild(fragment);
}

function buildPendingCard() {
  if (!state.pendingTask) return null;
  const node = els.pendingTemplate.content.firstElementChild.cloneNode(true);
  node.querySelector(".pending-text").textContent = state.pendingTask.text;
  node.querySelector(".message-meta").textContent = state.pendingTask.meta;
  const previewNode = node.querySelector(".pending-stream");
  previewNode.hidden = true;
  previewNode.textContent = "";
  return node;
}

function splitReasoningAndAnswer(content) {
  const value = (content || "").replace(/\r\n/g, "\n");
  const explicitSplit = /(?:^|\n)\s*(?:final answer|final|итог|итоговый ответ|ответ)\s*:\s*/i;
  if (explicitSplit.test(value)) {
    const parts = value.split(explicitSplit);
    const reasoningText = (parts.shift() || "").trim();
    const answerText = parts.join("\n").trim();
    if (reasoningText && answerText) {
      return { reasoning: reasoningText, answer: answerText };
    }
  }
  const lines = value.split("\n");
  const reasoning = [];
  const answer = [];
  let seenAnswerText = false;
  let sawReasoningMarker = false;
  let sawParagraphBreak = false;
  for (const line of lines) {
    const trimmed = line.trim();
    const looksLikeReasoning = /^(strategic_intent|summary|reasoning|analysis|thinking|plan|approach|diagnosis)\s*:/i.test(trimmed);
    const looksLikeCommentary = /^(сначала|сейчас|проверю|проверяю|дальше|исправляю|наш[её]л|вижу|сделаю|делаю|перепроверю|изолирую|локализовал|прогоняю|подтвердилось|корень|причина|first|now|checking|found|fixing|next|confirmed|root cause)\b/i.test(trimmed);
    if (!seenAnswerText && looksLikeReasoning) {
      sawReasoningMarker = true;
      reasoning.push(line);
      continue;
    }
    if (!seenAnswerText && !trimmed && reasoning.length) {
      sawParagraphBreak = true;
      reasoning.push(line);
      continue;
    }
    if (!seenAnswerText && !reasoning.length && looksLikeCommentary) {
      sawReasoningMarker = true;
      reasoning.push(line);
      continue;
    }
    if (!seenAnswerText && reasoning.length && sawParagraphBreak && trimmed) {
      seenAnswerText = true;
    }
    if (trimmed) {
      seenAnswerText = true;
    }
    answer.push(line);
  }
  const reasoningText = reasoning.join("\n").trim();
  const answerText = answer.join("\n").trim();
  if (!sawReasoningMarker || !reasoningText || !answerText) {
    return { reasoning: "", answer: value.trim() };
  }
  return { reasoning: reasoningText, answer: answerText };
}

function renderMessages(messages, options = {}) {
  const { forceBottom = false, restoreScrollTop = null } = options;
  const keepBottom = forceBottom || shouldAutoScroll();
  els.messageList.innerHTML = "";
  const displayMessages = buildDisplayMessages(messages);
  const visibleMessages = displayMessages.length > state.visibleMessageLimit ? displayMessages.slice(-state.visibleMessageLimit) : displayMessages;
  const hiddenCount = displayMessages.length - visibleMessages.length;
  const fragment = document.createDocumentFragment();
  if (!displayMessages.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "В этой сессии пока нет сообщений.";
    fragment.appendChild(empty);
  } else {
    if (hiddenCount > 0) {
      const loadMore = document.createElement("button");
      loadMore.type = "button";
      loadMore.className = "ghost-button compact-button load-more-button";
      loadMore.textContent = `Показать ещё ${hiddenCount} сообщений`;
      loadMore.addEventListener("click", () => {
        state.visibleMessageLimit += 200;
        renderMessages(state.messages, { restoreScrollTop: els.messageList.scrollTop });
      });
      fragment.appendChild(loadMore);
    }

    for (const message of visibleMessages) {
      const node = els.messageTemplate.content.firstElementChild.cloneNode(true);
      node.dataset.role = message.role;
      node.querySelector(".message-role").textContent = message.role;
      const actions = node.querySelector(".message-actions");
      const { reasoning, answer } = message.role === "assistant"
        ? splitReasoningAndAnswer(message.content)
        : { reasoning: "", answer: message.content };
      const combinedReasoning = [
        message._groupedReasoning || "",
        reasoning || "",
      ].filter(Boolean).join("\n\n");
      const contentNode = node.querySelector(".message-content");
      renderRichText(contentNode, answer || (combinedReasoning ? "" : message.content));
      contentNode.hidden = contentNode.childNodes.length === 0;

      const reasoningNode = node.querySelector(".reasoning-block");
      if (combinedReasoning) {
        reasoningNode.hidden = false;
        reasoningNode.open = false;
        const summaryLabel = message._groupedReasoningCount
          ? `Показать рассуждения (${message._groupedReasoningCount})`
          : "Показать рассуждения";
        reasoningNode.querySelector("summary").textContent = summaryLabel;
        reasoningNode.querySelector(".reasoning-content").textContent = combinedReasoning;
      }

      const copyButton = document.createElement("button");
      copyButton.type = "button";
      copyButton.className = "message-action";
      copyButton.textContent = "⧉";
      copyButton.title = "Копировать";
      copyButton.setAttribute("aria-label", "Копировать");
      copyButton.dataset.tooltip = "Копировать";
      copyButton.addEventListener("click", async () => {
        await navigator.clipboard.writeText(message.content);
        setStatus("Сообщение скопировано.");
      });
      actions.appendChild(copyButton);

      if (message.role === "user") {
        const editButton = document.createElement("button");
        editButton.type = "button";
        editButton.className = "message-action";
        editButton.textContent = "✎";
        editButton.title = "Редактировать";
        editButton.setAttribute("aria-label", "Редактировать");
        editButton.dataset.tooltip = "Редактировать";
        editButton.addEventListener("click", () => {
          state.editingMessage = message;
          els.messageInput.value = message.content;
          if (message.mode) {
            els.modeSelect.value = message.mode;
          }
          showEditBanner();
          autoResizeInput();
          els.messageInput.focus();
          els.messageInput.setSelectionRange(els.messageInput.value.length, els.messageInput.value.length);
          setStatus("Сообщение перенесено в редактор.");
        });
        actions.appendChild(editButton);
      }

      const usageNode = node.querySelector(".message-usage");
      if (usageNode && message.role === "assistant") {
        const usageText = buildUsageBadgeText(message);
        if (usageText) {
          usageNode.hidden = false;
          usageNode.textContent = usageText;
          const usageTitle = buildUsageTooltip(message);
          if (usageTitle) usageNode.title = usageTitle;
        }
      }

      const meta = [formatTimestamp(message.created_at)];
      if (message.provider) meta.push(message.provider);
      if (message.mode) meta.push(message.mode);
      const metaNode = node.querySelector(".message-meta");
      metaNode.textContent = meta.join(" · ");
      metaNode.addEventListener("mousedown", () => {
        metaNode.dataset.selectable = "true";
      });
      metaNode.addEventListener("mouseup", () => {
        delete metaNode.dataset.selectable;
      });
      metaNode.addEventListener("mouseleave", () => {
        delete metaNode.dataset.selectable;
      });
      fragment.appendChild(node);
    }
  }

  const pendingNode = buildPendingCard();
  if (pendingNode) {
    fragment.appendChild(pendingNode);
  }
  els.messageList.appendChild(fragment);

  if (keepBottom) {
    scrollMessageListToBottom();
  } else if (restoreScrollTop !== null) {
    requestAnimationFrame(() => {
      els.messageList.scrollTop = Math.max(0, restoreScrollTop);
    });
  }
}

function setSessionHeader(session) {
  state.currentSession = session || null;
  return;
}

function upsertSession(session) {
  if (!session) return;
  const index = state.sessions.findIndex((item) => item.id === session.id);
  if (index >= 0) {
    state.sessions[index] = session;
  } else {
    state.sessions.unshift(session);
  }
}

async function refreshCurrentSession(options = {}) {
  if (!state.currentSessionId) return;
  const { activate = false, refreshList = false } = options;
  const previousScrollTop = els.messageList.scrollTop;
  const keepBottom = shouldAutoScroll();
  const [session, messages] = await Promise.all([
    api(`/api/sessions/${state.currentSessionId}`),
    api(`/api/sessions/${state.currentSessionId}/messages`),
    ...(activate
      ? [api(`/api/sessions/${state.currentSessionId}/activate`, { method: "POST", body: JSON.stringify({}) })]
      : []),
  ]);
  state.messages = dedupeMessages(messages);
  state.messageCache.set(state.currentSessionId, state.messages);
  upsertSession(session);
  setSessionHeader(session);
  renderMessages(state.messages, { forceBottom: keepBottom, restoreScrollTop: keepBottom ? null : previousScrollTop });
  if (refreshList) {
    renderSessions();
  }
}

async function loadConfig() {
  state.config = await api("/api/config");
  els.configSummary.textContent = `mode ${state.config.default_mode} · shell ${state.config.shell_timeout_sec}s`;
  els.modeSelect.value = state.config.default_mode;
  state.currentWorkspaceRoot = getInitialWorkspaceRoot();
  els.workspaceHint.textContent = state.currentWorkspaceRoot;
  renderModelOptions();
  updateTopbar();
}

async function loadSessions() {
  state.sessions = await api("/api/sessions");
  renderSessions();
  if (!state.currentSessionId && state.sessions.length) {
    await selectSession(state.sessions[0].id);
    return;
  }
  if (state.currentSessionId && !state.sessions.some((session) => session.id === state.currentSessionId)) {
    state.currentSessionId = null;
    saveCurrentSessionId(null);
    state.messages = [];
    setSessionHeader(null);
    renderMessages([]);
    restoreDraftForSession(null);
    return;
  }
  if (state.currentSessionId && state.sessions.some((session) => session.id === state.currentSessionId) && !state.messages.length) {
    await selectSession(state.currentSessionId, { force: true, activate: false, skipPersist: true });
  }
}

function startImportSync() {
  if (state.importSyncTicker) return;
  state.importSyncTicker = window.setInterval(async () => {
    const current = state.sessions.find((session) => session.id === state.currentSessionId);
    const typingRecently = Date.now() - state.lastInputAt < 3500;
    const inputBusy = document.activeElement === els.messageInput || !!els.messageInput.value.trim();
    if (!current || !["codex", "antigravity"].includes(current.source_kind) || !current.source_id || state.sending || document.hidden || typingRecently || inputBusy || state.importSyncRunning) return;
    state.importSyncRunning = true;
    try {
      const query = encodeURIComponent(current.source_id);
      const result = await api(`/api/import/codex?source_id=${query}`, {
        method: "POST",
        body: JSON.stringify({}),
      });
      if ((result.updated_sessions || 0) > 0) {
        await refreshCurrentSession({ activate: false, refreshList: true });
      }
    } catch {
    } finally {
      state.importSyncRunning = false;
    }
  }, 20000);
}

async function selectSession(sessionId, options = {}) {
  const { force = false, activate = true, skipPersist = false } = options;
  if (!force && sessionId === state.currentSessionId && state.messages.length) {
    return;
  }
  if (!skipPersist && state.currentSessionId && state.currentSessionId !== sessionId) {
    persistDraftForSession(state.currentSessionId, els.messageInput.value || "");
  }
  state.currentSessionId = sessionId;
  saveCurrentSessionId(sessionId);
  state.visibleMessageLimit = 180;
  state.autoScrollLocked = false;
  renderSessions();
  const cachedMessages = state.messageCache.get(sessionId);
  if (cachedMessages && cachedMessages.length) {
    state.messages = cachedMessages;
    const cachedSession = state.sessions.find((session) => session.id === sessionId) || state.currentSession;
    if (cachedSession) {
      setSessionHeader(cachedSession);
    }
    renderMessages(state.messages, { forceBottom: true });
  }
  const [session, messages] = await Promise.all([
    api(`/api/sessions/${sessionId}`),
    api(`/api/sessions/${sessionId}/messages`),
    ...(activate ? [api(`/api/sessions/${sessionId}/activate`, { method: "POST", body: JSON.stringify({}) })] : []),
  ]);
  state.messages = dedupeMessages(messages);
  state.messageCache.set(sessionId, state.messages);
  upsertSession(session);
  setSessionHeader(session);
  renderMessages(state.messages, { forceBottom: true });
  restoreDraftForSession(sessionId);
  setSending(false);
  if (!state.activeTaskId) {
    state.pendingTask = null;
  }
  await recoverPersistedTask();
  setStatus("");
}

async function createSession(title) {
  const payload = {
    title: title.trim(),
    client: "delegator-web",
  };
  const session = await api("/api/sessions", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  els.sessionTitle.value = "";
  await loadSessions();
  await selectSession(session.id);
  switchNav("projects");
}

async function renameSession(sessionId) {
  if (!sessionId) return;
  const current = state.sessions.find((item) => item.id === sessionId) || (state.currentSession?.id === sessionId ? state.currentSession : null);
  if (!current) return;
  const next = window.prompt("Новое название чата", current.title || "");
  if (!next || !next.trim()) return;
  const session = await api(`/api/sessions/${sessionId}`, {
    method: "PATCH",
    body: JSON.stringify({ title: next.trim() }),
  });
  upsertSession(session);
  if (state.currentSessionId === sessionId) {
    state.currentSession = session;
    setSessionHeader(session);
  }
  renderSessions();
  setStatus("Название чата обновлено.");
}

async function uploadAttachment(file) {
  const form = new FormData();
  form.append("file", file, file.name);
  const response = await fetch("/api/uploads", { method: "POST", body: form });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || `HTTP ${response.status}`);
  }
  return response.json();
}

async function materializeAttachments() {
  if (!state.attachments.length) return [];
  const uploaded = [];
  for (const file of state.attachments) {
    uploaded.push(await uploadAttachment(file));
  }
  state.attachments = [];
  renderAttachmentTray();
  return uploaded;
}

function attachmentsToMarkdown(items) {
  if (!items.length) return "";
  const blocks = items.map((item) => {
    if (item.kind === "image") {
      return `![${item.name}](${item.content_url})\n[${item.name}](${item.local_path})`;
    }
    return `[${item.name}](${item.local_path})`;
  });
  return blocks.join("\n\n");
}

async function importCodexSessions() {
  setStatus("Импортирую чаты IDE...");
  const result = await api("/api/import/codex", {
    method: "POST",
    body: JSON.stringify({}),
  });
  await loadSessions();
  if (result.imported_session_ids && result.imported_session_ids.length > 0) {
    await selectSession(result.imported_session_ids[0]);
  }
  setStatus(`Импорт: новых ${result.imported_sessions}, обновлено ${result.updated_sessions}, пропущено ${result.skipped_sessions}, файлов ${result.scanned_files}.`);
}

async function resumeWorkspaceSession() {
  if (!state.currentWorkspaceRoot) {
    setStatus("Текущий проект не определён.", true);
    return;
  }
  setStatus("Ищу основной чат проекта...");
  const query = encodeURIComponent(state.currentWorkspaceRoot);
  const result = await api(`/api/workspaces/preferred?workspace_root=${query}`);
  const alreadyOpen = result.session.id === state.currentSessionId;
  await loadSessions();
  await selectSession(result.session.id);
  flashActiveSession();
  setStatus(alreadyOpen ? `Основной чат проекта уже открыт: ${result.session.title}` : `Открыт основной чат проекта: ${result.session.title}`);
}

function setPendingTask(text, meta, preview = "") {
  state.pendingTask = { text, meta, preview };
  const existing = els.messageList.querySelector(".pending-card");
  if (existing) {
    existing.querySelector(".pending-text").textContent = text;
    existing.querySelector(".message-meta").textContent = meta;
    const previewNode = existing.querySelector(".pending-stream");
    previewNode.hidden = true;
    previewNode.textContent = "";
    if (shouldAutoScroll()) {
      scrollMessageListToBottom();
    }
    return;
  }
  renderMessages(state.messages, { forceBottom: true });
}

function clearPendingTicker() {
  if (state.pendingTicker) {
    window.clearInterval(state.pendingTicker);
    state.pendingTicker = null;
  }
  state.pendingPhase = "";
}

function startPendingTicker(provider, mode, phase = "thinking") {
  clearPendingTicker();
  state.pendingStartedAt = Date.now();
  state.pendingPhase = phase;
  setTaskStatus(provider ? phase : "prepare", provider, 0);
  state.pendingTicker = window.setInterval(() => {
    if (!state.pendingTask) {
      clearPendingTicker();
      return;
    }
    const seconds = Math.max(1, Math.floor((Date.now() - state.pendingStartedAt) / 1000));
    setPendingTask(`Отвечает: ${formatProviderLabel(provider)}`, `${provider} · ${mode} · ${seconds}с`, state.pendingTask?.preview || "");
    setTaskStatus(state.pendingPhase || phase, provider, seconds);
  }, 1000);
}

async function sendMessage(text, mode) {
  if (!state.currentSessionId) {
    setStatus("Сначала создай или выбери сессию.", true);
    return;
  }
  const draftSnapshot = text;
  const selectedModel = getSelectedModel();
  const selectedReasoning = getSelectedReasoning() || resolveAutoReasoning(selectedModel || "auto", mode, text);
  setSending(true);
  setStatus("Подготавливаю контекст и ставлю запрос в очередь...", false, { busy: true, phase: "prepare" });
  try {
    const uploadedAttachments = await materializeAttachments();
    const attachmentBlock = attachmentsToMarkdown(uploadedAttachments);
    const finalText = attachmentBlock ? `${text}\n\n${attachmentBlock}` : text;
    const started = await api("/api/chat/turn/start", {
      method: "POST",
      body: JSON.stringify({
        session_id: state.currentSessionId,
        text: finalText,
        mode,
        client: "delegator-web",
        model: selectedModel,
        reasoning: selectedReasoning,
      }),
    });
    els.messageInput.value = "";
    state.lastInputAt = Date.now();
    autoResizeInput();
    state.editingMessage = null;
    showEditBanner();
    upsertSession(started.session);
    state.messages = dedupeMessages([...state.messages, started.user_message]);
    setSessionHeader(started.session);
    renderMessages(state.messages, { forceBottom: true });
    renderSessions();
    closeActiveStream();
    state.activeTaskId = started.task.id;
    state.currentTaskProvider = selectedModel || started.task.provider || "auto";
    persistDraftForSession(state.currentSessionId, "");
    persistActiveTask({
      taskId: started.task.id,
      sessionId: state.currentSessionId,
      provider: state.currentTaskProvider,
      mode,
      reasoning: selectedReasoning || "",
      preview: "",
    });
    const pendingMeta = [formatProviderLabel(state.currentTaskProvider), mode];
    if (selectedReasoning) pendingMeta.push(selectedReasoning);
    setPendingTask(`Отвечает: ${getModelLabel(state.currentTaskProvider)}`, pendingMeta.join(" · "), "");
    startPendingTicker(state.currentTaskProvider, mode, "queue");
    await streamTask(started.task.id);
  } catch (error) {
    persistDraftForSession(state.currentSessionId, draftSnapshot);
    setStatus(`Ошибка: ${error.message}`, true);
    setSending(false);
  }
}

function formatProviderLabel(provider) {
  return getModelLabel(provider || "auto");
}

async function streamTask(taskId, options = {}) {
  const { recovering = false } = options;
  return new Promise((resolve) => {
    const source = new EventSource(`/api/chat/tasks/${taskId}/events`);
    state.activeEventSource = source;

    source.addEventListener("task", async (event) => {
      const payload = JSON.parse(event.data);
      const provider = payload.provider || state.currentTaskProvider || getSelectedModel() || "auto";
      state.currentTaskProvider = provider;
      updateTopbar();
      persistActiveTask({
        taskId,
        sessionId: state.currentSessionId,
        provider,
        mode: payload.mode,
        preview: payload.stream_text || state.pendingTask?.preview || "",
      });

      if (payload.status === "queued") {
        setPendingTask(`В очереди: ${formatProviderLabel(provider)}`, `${provider} · ${payload.mode}`, "");
        setTaskStatus("queue", provider, 0);
        return;
      }
      if (payload.status === "running") {
        const phase = payload.stream_text && String(payload.stream_text).trim() ? "stream" : "thinking";
        setPendingTask(`Отвечает: ${formatProviderLabel(provider)}`, `${provider} · ${payload.mode}`, "");
        startPendingTicker(provider, payload.mode, phase);
        return;
      }
      if (payload.status === "completed") {
        recordModelUse(provider);
        clearPendingTicker();
        closeActiveStream();
        if (payload.assistant_message && state.currentSessionId) {
          state.messages = dedupeMessages([...state.messages, payload.assistant_message]);
          state.messageCache.set(state.currentSessionId, state.messages);
          renderMessages(state.messages, { forceBottom: true });
        }
        const usageText = buildUsageBadgeText(payload.assistant_message) || buildUsageBadgeText(payload);
        setStatus(`Ответ получен: ${formatProviderLabel(provider)}${usageText ? ` · ${usageText}` : ""}`);
        await refreshCurrentSession({ activate: false, refreshList: true });
        setSending(false);
        resolve();
        return;
      }
      if (payload.status === "failed") {
        const reason = payload.error || "неизвестная ошибка";
        setPendingTask(`Ошибка ответа: ${formatProviderLabel(provider)}`, `${provider} · ${payload.mode}`);
        setStatus(`Ошибка выполнения: ${reason}`, true);
        clearPendingTicker();
        closeActiveStream();
        await refreshCurrentSession({ activate: false, refreshList: true });
        setSending(false);
        resolve();
      }
    });

    source.onerror = async () => {
      setStatus(recovering ? "Проверяю восстановленную задачу..." : "Поток событий оборвался. Проверяю состояние задачи...", false, { busy: true, phase: "reconnect" });
      clearPendingTicker();
      source.close();
      state.activeEventSource = null;
      try {
        const task = await api(`/api/chat/tasks/${taskId}`);
        if (task.status === "completed" || task.status === "failed") {
          await refreshCurrentSession({ activate: false, refreshList: true });
          closeActiveStream();
        } else {
          persistActiveTask({
            taskId,
            sessionId: task.session_id,
            provider: task.provider || state.currentTaskProvider,
            mode: task.mode,
            preview: state.pendingTask?.preview || "",
          });
        }
      } catch (error) {
        if (looksOfflineError(error)) {
          setServerOnline(false);
          persistActiveTask({
            taskId,
            sessionId: state.currentSessionId,
            provider: state.currentTaskProvider,
            mode: state.pendingTask?.meta || "",
            preview: state.pendingTask?.preview || "",
          });
          closeActiveStream({ preservePersisted: true });
          setStatus("Сервер перезапускается. Состояние чата и активная задача сохранены.", false, { busy: true, phase: "server" });
        } else {
          setStatus(`Ошибка проверки задачи: ${error.message}`, true);
          closeActiveStream();
        }
      }
      setSending(false);
      resolve();
    };
  });
}

function escapeHtml(text) {
  return (text || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&#39;");
}

function normalizeHref(target) {
  const value = (target || "").trim();
  if (!value) return "#";
  if (/^(https?:|mailto:|\/api\/)/i.test(value)) return value;
  if (/^[a-zA-Z]:[\\/]/.test(value)) {
    return `file:///${value.replaceAll("\\", "/")}`;
  }
  return value;
}

function appendTextNode(parent, text) {
  if (!text) return;
  parent.appendChild(document.createTextNode(text));
}

function cleanInlineText(text) {
  return (text || "")
    .replace(/\r\n/g, "\n")
    .replace(/^\s*<image>\s*$/gim, "")
    .replace(/^\s*<\/image>\s*$/gim, "")
    .replace(/\n{3,}/g, "\n\n")
    .trimEnd();
}

async function copyImageToClipboard(src) {
  const response = await fetch(src);
  const blob = await response.blob();
  await navigator.clipboard.write([new ClipboardItem({ [blob.type || "image/png"]: blob })]);
}

async function downloadImageToSystem(src, filename = "") {
  const response = await fetch(src);
  const blob = await response.blob();
  const blobUrl = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = blobUrl;
  anchor.download = filename || `delegator-image-${Date.now()}.png`;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  window.setTimeout(() => URL.revokeObjectURL(blobUrl), 1000);
}

function renderInlineRichText(parent, text) {
  const value = cleanInlineText(text);
  const regex = /!\[([^\]]*)\]\(([^)]+)\)|\[([^\]]+)\]\(([^)]+)\)|(https?:\/\/[^\s]+)|([A-Za-z]:\\[^\s]+|[A-Za-z]:\/[^\s]+)/g;
  let lastIndex = 0;
  let match;
  while ((match = regex.exec(value)) !== null) {
    appendTextNode(parent, value.slice(lastIndex, match.index));
    if (match[1] !== undefined) {
      const src = normalizeHref(match[2]);
      const wrapper = document.createElement("span");
      wrapper.className = "message-image";
      const link = document.createElement("a");
      link.href = src;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.className = "message-image-link";
      const img = document.createElement("img");
      img.alt = match[1] || "image";
      img.src = src;
      link.appendChild(img);
      wrapper.appendChild(link);
      const actions = document.createElement("span");
      actions.className = "message-image-actions";
      const openButton = document.createElement("button");
      openButton.type = "button";
      openButton.className = "message-image-action";
      openButton.textContent = "Открыть";
      openButton.addEventListener("click", () => {
        window.open(src, "_blank", "noopener,noreferrer");
      });
      const copyButton = document.createElement("button");
      copyButton.type = "button";
      copyButton.className = "message-image-action";
      copyButton.textContent = "Копировать";
      copyButton.addEventListener("click", async () => {
        try {
          await copyImageToClipboard(src);
          setStatus("Изображение скопировано.");
        } catch (error) {
          setStatus(`Не удалось скопировать изображение: ${error.message}`, true);
        }
      });
      const saveButton = document.createElement("button");
      saveButton.type = "button";
      saveButton.className = "message-image-action";
      saveButton.textContent = "Скачать";
      saveButton.addEventListener("click", async () => {
        try {
          await downloadImageToSystem(src);
          setStatus("Изображение отправлено в загрузки.");
        } catch (error) {
          setStatus(`Не удалось сохранить изображение: ${error.message}`, true);
        }
      });
      actions.appendChild(openButton);
      actions.appendChild(copyButton);
      actions.appendChild(saveButton);
      wrapper.appendChild(actions);
      parent.appendChild(wrapper);
    } else if (match[3] !== undefined) {
      const link = document.createElement("a");
      link.href = normalizeHref(match[4]);
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.textContent = match[3];
      parent.appendChild(link);
    } else {
      const href = match[5] || match[6];
      const link = document.createElement("a");
      link.href = normalizeHref(href);
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.textContent = href;
      parent.appendChild(link);
    }
    lastIndex = regex.lastIndex;
  }
  appendTextNode(parent, value.slice(lastIndex));
}

function renderRichText(node, text) {
  node.innerHTML = "";
  const lines = cleanInlineText(text).split(/\r?\n/);
  lines.forEach((line, index) => {
    const lineNode = document.createElement("div");
    renderInlineRichText(lineNode, line);
    node.appendChild(lineNode);
    if (index < lines.length - 1) {
      node.appendChild(document.createTextNode("\n"));
    }
  });
}

function shouldAutoScroll() {
  if (state.autoScrollLocked) return false;
  const box = els.messageList;
  const delta = box.scrollHeight - box.scrollTop - box.clientHeight;
  return delta < 140;
}

function scrollMessageListToBottom() {
  state.suppressScrollTracking = true;
  requestAnimationFrame(() => {
    els.messageList.scrollTop = els.messageList.scrollHeight;
    const last = els.messageList.lastElementChild;
    if (last && typeof last.scrollIntoView === "function") {
      last.scrollIntoView({ block: "end" });
    }
    requestAnimationFrame(() => {
      els.messageList.scrollTop = els.messageList.scrollHeight;
      requestAnimationFrame(() => {
        els.messageList.scrollTop = els.messageList.scrollHeight;
        window.setTimeout(() => {
          state.suppressScrollTracking = false;
          state.autoScrollLocked = false;
        }, 80);
      });
    });
  });
}

function renderAttachmentTray() {
  const items = state.attachments || [];
  els.attachmentTray.innerHTML = "";
  els.attachmentTray.hidden = items.length === 0;
  for (const item of items) {
    const chip = document.createElement("div");
    chip.className = "attachment-chip";
    chip.innerHTML = `
      <span class="attachment-chip-name">${escapeHtml(item.name)}</span>
      <button type="button" class="attachment-chip-remove" aria-label="Удалить вложение">×</button>
    `;
    chip.querySelector(".attachment-chip-remove").addEventListener("click", () => {
      state.attachments = state.attachments.filter((entry) => entry !== item);
      renderAttachmentTray();
    });
    els.attachmentTray.appendChild(chip);
  }
}

function queueFiles(files) {
  const maxBytes = 10 * 1024 * 1024;
  for (const file of files || []) {
    if (!file) continue;
    if (file.size > maxBytes) {
      setStatus(`Файл слишком большой: ${file.name}`, true);
      continue;
    }
    state.attachments.push(file);
  }
  renderAttachmentTray();
}

function openSettings() {
  els.settingsOverlay.style.display = "flex";
  els.settingsOverlay.hidden = false;
}

function closeSettings() {
  els.settingsOverlay.hidden = true;
  els.settingsOverlay.style.display = "none";
}

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  saveUiPref(THEME_KEY, theme);
}

function applyFont(font) {
  document.documentElement.dataset.font = font;
  saveUiPref(FONT_KEY, font);
}

els.navNew.addEventListener("click", () => switchNav("new"));
els.navSearch.addEventListener("mouseenter", showSearchPopover);
els.navSearch.addEventListener("mouseleave", hideSearchPopoverDelayed);
els.navSearch.addEventListener("click", (event) => {
  event.preventDefault();
  showSearchPopover();
});
els.navProjects.addEventListener("click", () => switchNav("projects"));
els.searchPopover.addEventListener("mouseenter", showSearchPopover);
els.searchPopover.addEventListener("mouseleave", hideSearchPopoverDelayed);

els.newSessionForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const title = els.sessionTitle.value.trim() || "Новый чат";
  setStatus("Создаю сессию...");
  try {
    await createSession(title);
  } catch (error) {
    setStatus(`Ошибка создания: ${error.message}`, true);
  }
});

els.quickNewChatButton.addEventListener("click", () => {
  switchNav("new");
  els.sessionTitle.focus();
});

els.searchInput.addEventListener("input", () => {
  state.searchQuery = els.searchInput.value || "";
  if (state.searchRenderTimer) {
    window.clearTimeout(state.searchRenderTimer);
  }
  state.searchRenderTimer = window.setTimeout(() => {
    state.searchRenderTimer = null;
    renderSessions();
  }, 120);
});

els.refreshSessionsButton.addEventListener("click", async () => {
  setStatus("Обновляю список...");
  try {
    await loadSessions();
    setStatus("Готово.");
  } catch (error) {
    setStatus(`Ошибка обновления: ${error.message}`, true);
  }
});

els.importCodexButton.addEventListener("click", async () => {
  setSending(true);
  try {
    await importCodexSessions();
  } catch (error) {
    setStatus(`Ошибка импорта: ${error.message}`, true);
  }
  setSending(false);
});

els.resumeWorkspaceButton.addEventListener("click", async () => {
  setSending(true);
  try {
    await resumeWorkspaceSession();
  } catch (error) {
    setStatus(`Не удалось открыть основной чат: ${error.message}`, true);
  }
  setSending(false);
});

els.chatForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const text = els.messageInput.value.trim();
  if (!text) return;
  await sendMessage(text, els.modeSelect.value);
});

els.messageInput.addEventListener("keydown", async (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    if (state.sending) return;
    const text = els.messageInput.value.trim();
    if (!text) return;
    await sendMessage(text, els.modeSelect.value);
  }
});

els.attachmentInput.addEventListener("change", () => {
  queueFiles(els.attachmentInput.files);
  els.attachmentInput.value = "";
});

els.messageInput.addEventListener("paste", (event) => {
  const items = Array.from(event.clipboardData?.items || []);
  const files = [];
  for (const item of items) {
    if (item.kind === "file") {
      const file = item.getAsFile();
      if (file) files.push(file);
    }
  }
  if (files.length) {
    queueFiles(files);
  }
});

els.cancelEditButton.addEventListener("click", () => {
  clearEditing();
});

els.modelSelect.addEventListener("change", () => {
  state.selectedModel = els.modelSelect.value || "auto";
  saveUiPref(MODEL_KEY, state.selectedModel);
  renderReasoningOptions();
  fitComposerControls();
  updateTopbar();
  setStatus(`Выбрана модель: ${getModelLabel(state.selectedModel)}`);
});

els.reasoningSelect.addEventListener("change", () => {
  state.selectedReasoning = els.reasoningSelect.value || "auto";
  saveUiPref(REASONING_KEY, state.selectedReasoning);
  fitComposerControls();
  setStatus(`Выбран уровень рассуждений: ${els.reasoningSelect.options[els.reasoningSelect.selectedIndex]?.textContent || state.selectedReasoning}`);
});

els.modeSelect.addEventListener("change", () => {
  fitComposerControls();
});

els.modelsToggle.addEventListener("click", () => {
  if (els.modelsPanel.hidden) {
    openModelsPanel();
  } else {
    closeModelsPanel();
  }
});

els.modelsPanelClose.addEventListener("click", closeModelsPanel);

document.addEventListener("click", (event) => {
  if (!els.modelsPanel.hidden &&
      !els.modelsPanel.contains(event.target) &&
      !els.modelsToggle.contains(event.target)) {
    closeModelsPanel();
  }
});

els.usageToggle.addEventListener("click", () => {
  if (els.usagePanel.hidden) {
    openUsagePanel();
  } else {
    closeUsagePanel();
  }
});

els.usagePanelClose.addEventListener("click", closeUsagePanel);

els.usagePanelRefresh.addEventListener("click", () => {
  void refreshUsagePanel();
});

document.addEventListener("click", (event) => {
  if (!els.usagePanel.hidden &&
      !els.usagePanel.contains(event.target) &&
      !els.usageToggle.contains(event.target)) {
    closeUsagePanel();
  }
});

els.settingsButton.addEventListener("click", openSettings);
if (els.restartServerButton) {
  els.restartServerButton.addEventListener("click", async () => {
    if (!confirm("Вы уверены, что хотите перезапустить локальный сервер?")) {
      return;
    }
    setStatus("Перезапуск сервера...", false, { busy: true });
    try {
      await api("/api/restart", { method: "POST", body: JSON.stringify({}) });
      
      // Ping health endpoint in a loop until it responds ok, then reload
      setTimeout(async function ping() {
        try {
          const res = await fetch("/health");
          if (res.ok) {
            setStatus("Сервер успешно перезапущен. Обновляю страницу...");
            setTimeout(() => window.location.reload(), 600);
          } else {
            setTimeout(ping, 400);
          }
        } catch {
          setTimeout(ping, 400);
        }
      }, 1000);
    } catch (error) {
      setStatus(`Ошибка перезапуска: ${error.message}`, true);
    }
  });
}
els.closeSettingsButton.addEventListener("click", (event) => {
  event.preventDefault();
  event.stopPropagation();
  closeSettings();
});
els.settingsOverlay.addEventListener("click", (event) => {
  if (event.target === els.settingsOverlay) {
    closeSettings();
  }
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !els.settingsOverlay.hidden) {
    closeSettings();
  }
  if (event.key === "Escape" && !els.usagePanel.hidden) {
    closeUsagePanel();
  }
});

els.themeSelect.addEventListener("change", () => {
  applyTheme(els.themeSelect.value);
});

els.fontSelect.addEventListener("change", () => {
  applyFont(els.fontSelect.value);
});

els.messageInput.addEventListener("input", () => {
  state.lastInputAt = Date.now();
  scheduleDraftPersist();
  scheduleAutoResize();
});
window.addEventListener("resize", scheduleAutoResize);
window.addEventListener("resize", () => {
  applySidebarWidth(state.sidebarWidth);
  fitComposerControls();
});
window.addEventListener("beforeunload", () => {
  persistDraftForSession(state.currentSessionId, els.messageInput.value || "");
});
window.addEventListener("pagehide", () => {
  persistDraftForSession(state.currentSessionId, els.messageInput.value || "");
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    persistDraftForSession(state.currentSessionId, els.messageInput.value || "");
    return;
  }
  if (!document.hidden) {
    void checkServerHealth();
  }
});
els.messageList.addEventListener("scroll", () => {
  if (state.suppressScrollTracking) {
    return;
  }
  const box = els.messageList;
  const delta = box.scrollHeight - box.scrollTop - box.clientHeight;
  state.autoScrollLocked = delta > 96;
});

els.sidebarResizer.addEventListener("mousedown", (event) => {
  event.preventDefault();
  els.sidebarResizer.dataset.dragging = "true";
  const startX = event.clientX;
  const startWidth = state.sidebarWidth;
  function onMove(moveEvent) {
    const next = startWidth + (moveEvent.clientX - startX);
    applySidebarWidth(next);
  }
  function onUp() {
    delete els.sidebarResizer.dataset.dragging;
    window.removeEventListener("mousemove", onMove);
    window.removeEventListener("mouseup", onUp);
  }
  window.addEventListener("mousemove", onMove);
  window.addEventListener("mouseup", onUp);
});

async function boot() {
  loadUiPrefs();
  switchNav(state.activeNav);
  showEditBanner();
  setSending(true);
  autoResizeInput();
  try {
    await loadConfig();
    await loadSessions();
    startHealthMonitor();
    await checkServerHealth();
    startImportSync();
    if (shouldResumeWorkspaceOnLoad()) {
      await resumeWorkspaceSession();
    } else if (!state.currentSessionId) {
      try {
        await resumeWorkspaceSession();
      } catch {}
    }
    await recoverPersistedTask();
    setStatus("Готово.");
    fitComposerControls();
    els.messageInput.focus();
  } catch (error) {
    setStatus(`Ошибка запуска: ${error.message}`, true);
  }
  setSending(false);
}

boot();

// Pure model matching, ranking, and reasoning-level helpers shared by content.js and door.js.
// No DOM access so Node unit tests can evaluate this file directly in a vm context.
(() => {
  const FAMILIES = [
    { id: "carbon", pattern: /carbon/i, weight: 9 },
    { id: "neon", pattern: /neon/i, weight: 8 },
    { id: "argon", pattern: /argon/i, weight: 7 },
    { id: "hydrogen", pattern: /hydrogen/i, weight: 6 },
    { id: "flash-lite", pattern: /flash[\s-]*lite/i, weight: 1 },
    { id: "flash", pattern: /flash/i, weight: 3 },
    { id: "pro", pattern: /\bpro\b/i, weight: 5 },
    { id: "ultra", pattern: /\bultra\b/i, weight: 5 },
  ];

  const GEN4_FAMILIES = new Set(["carbon", "neon", "argon", "hydrogen"]);

  function clean(text) {
    return String(text || "").replace(/google\s+ai\s+(pro|ultra|plus)/gi, " ");
  }

  function familyOf(text) {
    const cleaned = clean(text);
    for (const entry of FAMILIES) {
      if (entry.pattern.test(cleaned)) return entry.id;
    }
    return "";
  }

  function versionOf(text) {
    const cleaned = clean(text);
    const match = cleaned.match(/gemini\s*(\d+(?:[.,]\d+)?)/i)
      || cleaned.match(/(?:^|\s)(\d+(?:[.,]\d+)?)\s+(?:carbon|neon|argon|hydrogen|pro|flash|ultra)/i)
      || cleaned.match(/^\s*(\d+(?:[.,]\d+)?)(?=\s|$)/);
    if (!match) return 0;
    const value = parseFloat(match[1].replace(",", "."));
    return Number.isFinite(value) && value <= 20 ? value : 0;
  }

  function modelRank(text) {
    const family = familyOf(text);
    let version = versionOf(text);
    if (!version && GEN4_FAMILIES.has(family)) version = 4;
    if (!version && !family) return -1;
    const weight = family ? (FAMILIES.find((entry) => entry.id === family)?.weight ?? 5) : 5;
    return version * 10 + weight;
  }

  const GEMINI_MATCHERS = {
    "gemini-web/carbon": (text) => familyOf(text) === "carbon",
    "gemini-web/neon": (text) => familyOf(text) === "neon",
    "gemini-web/argon": (text) => familyOf(text) === "argon",
    "gemini-web/hydrogen": (text) => familyOf(text) === "hydrogen",
    "gemini-web/3.1-pro": (text) => familyOf(text) === "pro",
    "gemini-web/3.8-flash": (text) => familyOf(text) === "flash",
    "gemini-web/3.5-flash-lite": (text) => familyOf(text) === "flash-lite",
  };

  // AI Studio's rows carry the model's id. Same choices as the Gemini page, by the shared setting.
  const STUDIO_MODELS = {
    carbon: /gemini-[\d.]+-carbon(?!-(?:image|tts|live|audio))/i,
    neon: /gemini-[\d.]+-neon(?!-(?:image|tts|live|audio))/i,
    argon: /gemini-[\d.]+-argon(?!-(?:image|tts|live|audio))/i,
    hydrogen: /gemini-[\d.]+-hydrogen(?!-(?:image|tts|live|audio))/i,
    "3.1-pro": /gemini-3\.1-pro(?!-image)/i,
    "3.8-flash": /gemini-3\.8-flash(?![\w-])/i,
    "3.5-flash-lite": /gemini-3\.5-flash-lite(?![\w-])/i,
  };

  const REASONING_MATCHERS = {
    low: /^(низк|low)/i,
    medium: /^(средн|medium)/i,
    high: /^(высок|high)/i,
    xhigh: /^(очень высок|сверхвысок|максим|extra[\s-]*high|x-?high|very high|extra|ultra)/i,
  };

  const REASONING_ORDER = {
    best: [
      REASONING_MATCHERS.xhigh,
      REASONING_MATCHERS.high,
      REASONING_MATCHERS.medium,
      REASONING_MATCHERS.low,
    ],
    xhigh: [REASONING_MATCHERS.xhigh, REASONING_MATCHERS.high],
    high: [REASONING_MATCHERS.high],
    medium: [REASONING_MATCHERS.medium],
    low: [REASONING_MATCHERS.low],
  };

  const REASONING_ROW = /^(уровень (рассуждений|размышлений|мышления)|reasoning level|thinking level)/i;

  const STUDIO_LEVELS = {
    best: [/^(extra[\s-]*high|x-?high|very high)/i, /^high/i],
    xhigh: [/^(extra[\s-]*high|x-?high|very high)/i, /^high/i],
    high: [/^high/i],
    medium: [/^medium/i],
    low: [/^low/i],
  };

  globalThis.__delegatorModels = {
    FAMILIES,
    clean,
    familyOf,
    versionOf,
    modelRank,
    GEMINI_MATCHERS,
    STUDIO_MODELS,
    REASONING_MATCHERS,
    REASONING_ORDER,
    REASONING_ROW,
    STUDIO_LEVELS,
  };
})();

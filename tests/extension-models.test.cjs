const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");

function loadModels() {
  const context = vm.createContext({});
  const source = fs.readFileSync(
    path.join(__dirname, "../extensions/gemini-web-bridge/models.js"),
    "utf8",
  );
  vm.runInContext(source, context);
  return context.__delegatorModels;
}

const MODELS = loadModels();

test("Gemini 4 ranks Carbon > Neon > Argon > Hydrogen for bare and full labels", () => {
  assert.ok(MODELS.modelRank("Carbon") > MODELS.modelRank("Neon"));
  assert.ok(MODELS.modelRank("Neon") > MODELS.modelRank("Argon"));
  assert.ok(MODELS.modelRank("Argon") > MODELS.modelRank("Hydrogen"));

  const fullCarbon = "Gemini 4 Carbon · Google AI Ultra";
  const fullNeon = "Gemini 4 Neon · Google AI Pro";
  const fullHydrogen = "Gemini 4 Hydrogen · Google AI Pro";
  assert.ok(MODELS.modelRank(fullCarbon) > MODELS.modelRank(fullNeon));
  assert.ok(MODELS.modelRank(fullNeon) > MODELS.modelRank(fullHydrogen));
});

test("live Gemini menu rows rank Carbon > Neon > Hydrogen and ignore Auto/Reasoning", () => {
  // Captured live from gemini.google.com/app on 2026-11-26.
  const autoRow = "Авто Адаптируется к вашим потребностям";
  const hydrogenRow = "Повседневные дела 4 Hydrogen";
  const neonRow = "Глубокий анализ 4 Neon Новинка";
  const carbonRow = "Код и сложные задачи 4 Carbon";
  const reasoningRow = "Уровень рассуждений.";

  assert.equal(MODELS.modelRank(autoRow), -1);
  assert.ok(MODELS.REASONING_ROW.test(reasoningRow));
  assert.ok(MODELS.modelRank(carbonRow) > MODELS.modelRank(neonRow));
  assert.ok(MODELS.modelRank(neonRow) > MODELS.modelRank(hydrogenRow));
  assert.ok(MODELS.GEMINI_MATCHERS["gemini-web/carbon"](carbonRow));
  assert.ok(MODELS.GEMINI_MATCHERS["gemini-web/neon"](neonRow));
  assert.ok(MODELS.GEMINI_MATCHERS["gemini-web/hydrogen"](hydrogenRow));
  assert.ok(!MODELS.GEMINI_MATCHERS["gemini-web/3.1-pro"](neonRow));
});

test("Hydrogen outranks legacy 3.8 Flash > 3.1 Pro / 3.5 Flash-Lite", () => {
  assert.ok(MODELS.modelRank("4 Hydrogen") > MODELS.modelRank("3.8 Flash"));
  assert.ok(MODELS.modelRank("3.8 Flash") > MODELS.modelRank("3.1 Pro"));
  assert.ok(MODELS.modelRank("3.8 Flash") > MODELS.modelRank("3.5 Flash-Lite"));
});

test("utility rows without version or family score -1", () => {
  assert.equal(MODELS.modelRank("Deep Research"), -1);
  assert.equal(MODELS.modelRank("Canvas"), -1);
});

test("familyOf ignores Google AI Pro/Ultra/Plus tier descriptions", () => {
  assert.equal(MODELS.familyOf("Gemini 4 Hydrogen · Google AI Pro"), "hydrogen");
  assert.equal(MODELS.familyOf("3.1 Pro"), "pro");
  assert.equal(MODELS.familyOf("Hydrogen Высокий"), "hydrogen");
});

test("AI Studio matchers cover Gemini 4 ids and exclude media variants", () => {
  assert.match("gemini-4-carbon", MODELS.STUDIO_MODELS.carbon);
  assert.match("gemini-4-carbon-preview", MODELS.STUDIO_MODELS.carbon);
  assert.doesNotMatch("gemini-4-carbon-image", MODELS.STUDIO_MODELS.carbon);

  assert.match("gemini-4-neon", MODELS.STUDIO_MODELS.neon);
  assert.match("gemini-4-neon-preview", MODELS.STUDIO_MODELS.neon);
  assert.doesNotMatch("gemini-4-neon-tts", MODELS.STUDIO_MODELS.neon);

  assert.match("gemini-4-hydrogen", MODELS.STUDIO_MODELS.hydrogen);
  assert.match("gemini-4-hydrogen-preview", MODELS.STUDIO_MODELS.hydrogen);
  assert.doesNotMatch("gemini-4-hydrogen-audio", MODELS.STUDIO_MODELS.hydrogen);

  assert.match("gemini-4-argon", MODELS.STUDIO_MODELS.argon);
});

test("xhigh reasoning matches localized and English extra-high labels without colliding with high", () => {
  assert.match("Очень высокая", MODELS.REASONING_MATCHERS.xhigh);
  assert.match("Extra high", MODELS.REASONING_MATCHERS.xhigh);
  assert.doesNotMatch("Очень высокая", MODELS.REASONING_MATCHERS.high);
  assert.match("Extra High", MODELS.STUDIO_LEVELS.xhigh[0]);
});

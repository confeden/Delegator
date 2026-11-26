const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");

function worker(windows) {
  const created = [];
  const fetched = [];
  const event = { addListener() {} };
  const context = vm.createContext({
    console, URL, setTimeout() {}, clearTimeout() {},
    fetch(url) { fetched.push(url); return new Promise(() => {}); },
    chrome: {
      windows: { async getAll() { return windows; }, async create() { throw Error("Unexpected profile window"); } },
      tabs: {
        onUpdated: event, onRemoved: event,
        async create(options) { created.push(options); return { id: 1, windowId: options.windowId }; },
        async query() { return []; },
      },
      tabGroups: { async query() { return []; } },
      alarms: { create() {}, onAlarm: event },
      runtime: { onStartup: event, onInstalled: event, onMessage: event },
      debugger: { onDetach: event },
    },
  });
  const source = fs.readFileSync(path.join(__dirname, "../extensions/gemini-web-bridge/background.js"), "utf8")
    .replace(/^void (syncBridge|watchDemand|syncDoors|watchDoors)\(\);$/gm, "");
  vm.runInContext(source, context);
  return { context, created, fetched };
}

test("a worker without a profile window neither polls nor creates tabs", async () => {
  const { context, created, fetched } = worker([]);
  await vm.runInContext("openBridgeTab()", context);
  await assert.rejects(vm.runInContext("ensureDoorTab('kimi')", context));
  vm.runInContext("void watchDemand(); void watchDoors();", context);
  await new Promise(setImmediate);
  assert.equal(created.length, 0);
  assert.equal(fetched.length, 0);
});

test("an open profile polls both queues and creates Gemini in its own window", async () => {
  const { context, created, fetched } = worker([{ id: 7, state: "normal" }]);
  // Grouping is unrelated to profile selection.
  vm.runInContext("groupBridgeTab = async () => {};", context);
  await vm.runInContext("openBridgeTab()", context);
  assert.equal(created[0].windowId, 7);
  vm.runInContext("void watchDemand(); void watchDoors();", context);
  await new Promise(setImmediate);
  assert.equal(fetched.length, 2);
  assert.ok(fetched.some(url => url.includes("/api/gemini-web/wait")));
  assert.ok(fetched.some(url => url.includes("/api/web-door/wait")));
});

test("a profile closed during a poll leaves the reply unclaimed", async () => {
  const windows = [{ id: 7, state: "normal" }];
  const { context, created } = worker(windows);
  let consumed = false;
  context.fetch = async () => {
    windows.length = 0;
    return { ok: true, async json() { consumed = true; return { login: ["gemini"] }; } };
  };
  vm.runInContext("void watchDoors();", context);
  await new Promise(setImmediate);
  assert.equal(consumed, false);
  assert.equal(created.length, 0);
});

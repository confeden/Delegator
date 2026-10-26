// Runs in the PAGE's own world, before Gemini's scripts. The bridge window stays
// minimized so the user is never interrupted, and a hidden page refuses to send
// a message; this makes the page believe it is visible and focused.
(() => {
  try {
    if (new URL(location.href).searchParams.get("delegator_bridge") === "1") sessionStorage.setItem("delegatorBridge", "1");
    if (sessionStorage.getItem("delegatorBridge") !== "1") return;
  } catch {
    return;
  }
  const define = (target, name, getter) => {
    try { Object.defineProperty(target, name, { configurable: true, get: getter }); } catch { /* keep the real one */ }
  };
  define(Document.prototype, "visibilityState", () => "visible");
  define(Document.prototype, "webkitVisibilityState", () => "visible");
  define(Document.prototype, "hidden", () => false);
  define(Document.prototype, "webkitHidden", () => false);
  try { Document.prototype.hasFocus = () => true; } catch { /* ignore */ }
  for (const type of ["visibilitychange", "webkitvisibilitychange", "blur", "pagehide"]) {
    window.addEventListener(type, (event) => event.stopImmediatePropagation(), true);
    document.addEventListener(type, (event) => event.stopImmediatePropagation(), true);
  }
})();

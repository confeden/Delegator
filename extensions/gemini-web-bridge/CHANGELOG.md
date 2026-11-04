# Delegator Gemini Bridge changes

## 0.22.3

- Puter removed. New web doors with one generic driver (`door.js`): AI Studio, Kimi, Z.ai, Qwen, DeepSeek, Tencent Hy, Rudder.
- «Войти»: the GUI asks, the site opens in front, and the sign-in is confirmed by what the page shows.
- All doors share one long poll: Chrome allows six connections to a host, and a poll per door starved the last ones.
- Gemini and AI Studio follow one shared model and reasoning choice.
- A subscription dialog, a Retry button or an apology from the site is a failed turn, never an answer.
- Reloads itself once when Delegator ships a newer copy (`storage` permission for that one mark).
- A door that loses the race is told to stop, so a dead turn does not hold the tab or spend quota.
- Gemini: a cold tab waits 30 s for the model picker (8 s failed every first request), and a guest page reports `LOGIN`.

## 0.13.0

- Pick models and reasoning levels by the visible text of Gemini's menu rows (checked against the live menu), not by key order.
- Open and close the minimized Gemini window automatically while Delegator's "Gemini Web" setting is on; no manual tab, no tab group (`tabGroups` replaced by `alarms`).

## 0.12.0

- Insert prompts with Chrome's trusted `Input.insertText` so Gemini's controlled composer accepts them.

## 0.11.0

- Select Gemini models and reasoning levels through trusted keyboard navigation, avoiding inaccessible menu items.
- Confirm the chosen model from Gemini's model picker label before sending the request.

## 0.10.0

- Search Gemini's open shadow roots when locating model and reasoning menu controls.
- Add a visible-text fallback for menu rows that Gemini exposes without button or menuitem roles.

## 0.9.0

- Re-query Gemini's model picker after each UI transition so selection checks follow Angular's replaced controls.
- Focus the reasoning submenu item with a trusted click before sending Enter or ArrowRight.

## 0.8.0

- Use Chrome's debugger input protocol for trusted clicks and key presses on the Gemini bridge tab, scoped to that tab and detached immediately after submitting a prompt.
- Request Chrome's `debugger` permission because Gemini ignores synthetic extension clicks on its model and reasoning menus.

## 0.7.0

- Add pointer and mouse event fallbacks for Gemini's Angular Material controls, then confirm model and reasoning changes in the UI.

## 0.6.0

- Open Gemini model and reasoning menus with a keyboard fallback when a DOM click does not activate them.
- Prefer Enter for Gemini's reasoning submenu and verify the selected model and reasoning level.
- Skip reopening the model menu when the requested model is already active.
- Wait for Gemini to enable its send button after filling the composer before submitting the request.
- Keep Enter as a fallback, dispatching both keydown and keyup.

## 0.5.0

- Wait for Gemini to enable its send button after filling the composer before submitting the request.
- Keep Enter as a fallback, dispatching both keydown and keyup.

## 0.4.0

- Target Gemini's visible rich-text input instead of its hidden Quill clipboard element.
- Open reasoning-level options with the menu's ArrowRight keyboard action.

## 0.3.0

- Reconnect to an already-open Delegator Gemini tab when Chrome starts or restarts the extension service worker.
- Re-inject the bridge content script on eligible Gemini tabs so a missed static injection does not leave the bridge disconnected.
- Keep the content script idempotent when Chrome delivers multiple startup events.

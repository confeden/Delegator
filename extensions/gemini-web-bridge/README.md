# Delegator Gemini Bridge

This unpacked Chrome extension connects the Delegator Core at `127.0.0.1:1380` to a dedicated Google Gemini tab. It does not use the Gemini API or read other tabs. It runs only on `https://gemini.google.com/app?delegator_bridge=1` and talks only to the local Core.

## Install in Chrome

1. Open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked** and select this directory (once).
2. In Delegator, tick **Gemini Web (через Chrome)** on the «Интеграция» tab. The extension then opens a minimized Gemini window by itself (you must be signed in to Gemini in Chrome) and closes it when the setting is off or Delegator is paused.

Chrome asks for access to the Gemini site and the local Delegator Core. The extension manifest limits its website access to Gemini and `127.0.0.1:1380`. It requests `alarms` to check Delegator's setting every 30 s, `scripting` to restore the bridge if Chrome restarts its service worker, and `debugger` because Gemini ignores synthetic extension clicks on its model and reasoning menus. Debugger input is restricted in the service worker to the dedicated Gemini Bridge tab and only sends clicks, Enter, and ArrowRight; it detaches immediately after submitting a prompt. The extension does not request history or cookies and does not use the debugger to read page contents or interact with other tabs.

Text prompts and the chat context included by Delegator are sent to Gemini using the signed-in Google account. The browser UI flow currently supports text only; attachments are rejected for Gemini Web requests.

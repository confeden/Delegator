# Политика runtime Delegator

Используйте `ai-delegate.cmd` из этого каталога как единственную точку входа.

- `micro` — небольшой нетривиальный анализ;
- `delegate` — обычная или широкая задача;
- `parallel` — независимые части задачи;
- `verify` — рискованные или финальные технические утверждения;
- `ui` — открыть панель Delegator.

Ключи Google и OpenCode/OpenRouter настраиваются только в GUI Delegator. Runtime не должен читать системные API-key переменные или учётные данные других приложений.

Модели Gemini ограничены `gemini-pro-latest`, `gemini-flash-latest` и `gemini-flash-lite-latest`. Модели `opencode/*` требуют OpenCode CLI; `openrouter/*` используют прямой API и DPAPI-ключи Delegator.

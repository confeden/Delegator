# Протоколы моделей Delegator

Проверено 3 августа 2026 года по актуальной документации провайдеров.

## Gemini

Обычный пул Delegator содержит только выбранные alias:

- `gemini-pro-latest`;
- `gemini-flash-latest`;
- `gemini-flash-lite-latest`.

Alias `latest` автоматически переключается Google на новую версию соответствующего семейства. Запрос выполняется через `POST /v1beta/models/{model}:generateContent`. Тело содержит единственный актуальный пользовательский turn и не передаёт устаревшие sampling-параметры, поэтому совместимо с текущими требованиями новых Gemini-моделей.

Runtime читает только DPAPI-аккаунты, сохранённые GUI Delegator. Системные `GEMINI_API_KEY` и `GOOGLE_API_KEY`, Gemini CLI и внешние файлы ключей не используются. Аккаунты балансируются по локально измеренным токенам, запросам и времени последнего использования. При quota/rate limit выполняется переключение на другой включённый аккаунт.

Специализированные семейства намеренно исключены: Live/audio, TTS, генерация изображений, embeddings, Veo, Imagen, Lyria, Deep Research, Antigravity, Robotics и Computer Use требуют других протоколов или режимов ответа.

Документация: <https://ai.google.dev/gemini-api/docs/latest-model>, <https://ai.google.dev/gemini-api/docs/models>, <https://ai.google.dev/api/models>, <https://ai.google.dev/api/generate-content>.

## OpenCode Zen

В GUI доступны семь бесплатных alias Zen. `opencode/big-pickle` выключена по умолчанию; остальные шесть включены. Runtime передаёт выбранную модель установленному OpenCode CLI. CLI сам управляет протоколом Zen и собственной авторизацией.

Для каждого запроса Delegator запускает нативный `opencode.exe` в отдельном рабочем каталоге и с изолированной конфигурацией текстового агента. Поэтому проектные и глобальные `AGENTS.md` не могут повторно вызвать Delegator или заменить исходную задачу. Многострочный prompt передаётся напрямую из PowerShell, без промежуточного `.cmd`, которое может повредить переносы строк; `ai-delegate.cmd` остаётся только внешней стабильной точкой входа для IDE.

Официальная установка для Windows через npm:

```powershell
npm install -g opencode-ai
```

Также поддерживаются официальные варианты Chocolatey, Scoop и отдельный бинарник. Документация: <https://dev.opencode.ai/docs/>.

## OpenRouter

Модели `openrouter/*` вызываются напрямую через `POST https://openrouter.ai/api/v1/chat/completions`. Ключи хранятся в том же разделе GUI, что и Google-ключи. При наличии нескольких включённых ключей runtime меняет начальный аккаунт и пробует следующий при ошибке или rate limit.

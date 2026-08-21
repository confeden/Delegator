Delegator — небольшое приложение для Windows 10/11, живущее в трее. Оно тихо встраивается в ваши
IDE-ассистенты (Codex/ChatGPT, Antigravity, OpenCode, Cursor, Claude, VS Code) и забирает у них ту часть
работы, где дорогая модель не нужна: разбор длинных логов, черновой код, поиск, пересказ,
независимая перепроверка. Эти задачи уходят на бесплатные модели — и возвращаются готовым ответом.

Зачем это нужно:

- **Экономия.** Токены дорогой модели тратятся на решения и правки, а не на рутину. Сколько именно
  сэкономлено — видно во вкладке «Статистика».
- **Качество.** Слабые и средние модели поодиночке ошибаются. Delegator их не просто вызывает: он
  распределяет задачи, сталкивает мнения, отбраковывает слабые ответы и собирает из них один
  уверенный. Иногда результат оказывается лучше, чем у модели, которую вы бы выбрали сами.
- **Незаметность.** Никаких новых окон и команд: ассистент, которым вы уже пользуетесь, просто
  начинает работать экономнее и увереннее.

Что именно и когда делегировать, как ранжируются модели, когда включается перепроверка и по каким
признакам ответ отбраковывается — Delegator решает сам, и правила подстраиваются под ситуацию.
Вам достаточно поставить галочки в интерфейсе.

## Установка

Права администратора не требуются. Программа устанавливается в:

```text
%LOCALAPPDATA%\Programs\Delegator\
  delegator.exe
  delegator-core.exe
  resources\theme.json
  runtime\
```

Python, Rust, виртуальное окружение и копия исходного репозитория на целевом ПК не нужны. Ярлык автозапуска запускает `delegator.exe --background`. Обычный запуск открывает панель управления; закрытие окна скрывает её в трее.

Установщик пока не подписан цифровой подписью, поэтому Windows SmartScreen может показать предупреждение о неизвестном издателе.

## Бесплатные модели OpenCode

Часть моделей приходит через OpenCode CLI. Если его нет, вкладка **Модели OpenCode** предложит
кнопку «Установить» — Delegator поставит всё необходимое сам (при отсутствии Node.js — и его тоже).
Список бесплатных моделей обновляется автоматически: новые появляются и включаются сами, исчезнувшие
уходят из маршрутизации.

Модели `openrouter/*` вызываются напрямую и требуют только ключ, добавленный во вкладке «API-ключи».

При делегировании OpenCode запускается в изолированном текстовом контексте: пользовательские и проектные `AGENTS.md` не подменяют задачу и не создают рекурсивный вызов Delegator. Авторизация самого OpenCode CLI при этом сохраняется.

## Внешний вид

Нативный интерфейс `egui` использует тёмную тему и `Segoe UI Semibold` размером 16. Настройки находятся в `resources\theme.json` рядом с установленным приложением; исходный файл — `assets\theme.json`. После изменения темы перезапустите Delegator. JSON выбран вместо CSS, потому что интерфейс не использует HTML/WebView.

## Данные и ключи

- конфигурация GUI: `%APPDATA%\Delegator\DelegatorWin\config\config.json`;
- база и журналы Core: `%LOCALAPPDATA%\DelegatorWin\core`;
- счётчики и кэш маршрутизатора: `%LOCALAPPDATA%\DelegatorWin\runtime`.

Ключи Google и OpenCode/OpenRouter шифруются Windows DPAPI для текущего пользователя. Можно добавлять несколько ключей каждого провайдера, включать, заменять и удалять их в любое время. Системные `GEMINI_API_KEY` и `GOOGLE_API_KEY`, профили Gemini CLI и ключи других приложений не читаются.

Google-запросы распределяются между включёнными аккаунтами по расходу токенов, числу запросов и времени последнего использования. При квоте или rate limit Delegator временно исключает аккаунт и пробует следующий. Прямые OpenRouter-запросы также перебирают включённые ключи при ошибках.

## Модели Gemini

Единственный стандартный Gemini-пул состоит из выбранных `latest` alias:

- `gemini-pro-latest`;
- `gemini-flash-latest`;
- `gemini-flash-lite-latest`.

Delegator вызывает их через нативный REST-метод `models.generateContent`. Другие Gemini-модели не попадают в список выбора.

## Модели OpenCode

В интерфейсе доступны семь бесплатных alias OpenCode Zen:

- `opencode/big-pickle`;
- `opencode/deepseek-v4-flash-free`;
- `opencode/laguna-s-2.1-free`;
- `opencode/ling-3.0-flash-free`;
- `opencode/mimo-v2.5-free`;
- `opencode/nemotron-3-ultra-free`;
- `opencode/north-mini-code-free`.

Выбор GUI является главным: старые рейтинги или дополнительные файлы не могут незаметно включить снятую галочку.

## Интеграция с IDE

При включении IDE Delegator поддерживает отмеченный hook-блок с абсолютным путём к установленному `runtime\ai-delegate.cmd`:

- Antigravity: `%USERPROFILE%\.gemini\config\AGENTS.md`;
- Codex: `%USERPROFILE%\.codex\AGENTS.md`;
- OpenCode: `%USERPROFILE%\.config\opencode\AGENTS.md`;
- Cursor: `%USERPROFILE%\.cursor\rules\delegator.md`;
- Claude: `%USERPROFILE%\.claude\CLAUDE.md` и `%APPDATA%\Claude\CLAUDE.md`;
- VS Code/Copilot: `%USERPROFILE%\.copilot\instructions\delegator.instructions.md`.

Hooks обновляются без перезапуска IDE. Деинсталлятор запускает `delegator.exe --remove-hooks` и удаляет только блоки и compatibility shims, принадлежащие Delegator.

## Runtime и Core

`delegator.exe` запускает скрытый `delegator-core.exe`. В автономный Core включены FastAPI, Uvicorn, SQLite и статические ресурсы. Проверка состояния:

```text
http://127.0.0.1:1380/health
```

Ответ содержит версию `0.7.1` и путь к установленному runtime, поэтому старый Core на порту 1380 не принимается за текущий.

## Сборка

Зависимости сборки нужны только разработчику:

```powershell
.\build-installer.ps1
```

Скрипт создаёт build-only Python-окружение, устанавливает закреплённые версии из `requirements-build.txt`, запускает Rust-тесты, собирает GUI и автономный Core, затем создаёт Inno Setup установщик `dist\DelegatorSetup-0.7.1.exe`.

Полезные проверки:

```powershell
cargo test --locked
.\scripts\audit-release.ps1 -InstallerPath .\dist\DelegatorSetup-0.7.1.exe
& "$env:LOCALAPPDATA\Programs\Delegator\runtime\ai-delegate.cmd" models
Invoke-RestMethod http://127.0.0.1:1380/health
```

## Обновления

Delegator проверяет наличие новой версии раз в 8 часов по релизам GitHub
(<https://github.com/confeden/Delegator/releases>) и показывает уведомление в панели
управления, когда доступен более свежий тег. Скачивание и установка остаются ручными.

## Лицензия

Проект распространяется по лицензии **Delegator Non-Commercial, No-AI-Training License
(DNC-NAT) 1.0** — файл [LICENSE](LICENSE), актуальная версия:
<https://github.com/confeden/Delegator/blob/main/LICENSE>

---

# Создано с ❤️

🙋 **Группа в Телеграм:** [@nova_txt](https://t.me/nova_txt) — вопросы, новости,
поддержка.

☕ **[Отблагодарить](https://nova-app.eu/donate)** — если Delegator оказался полезным.
Это необязательный способ сказать "спасибо".

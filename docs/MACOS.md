# Delegator — модифицированная версия для macOS

Порт основан на [confeden/Delegator](https://github.com/confeden/Delegator).
Сохраняется исходная лицензия [DNC-NAT 1.0](../LICENSE), разрешающая
некоммерческое использование. Это отдельная модификация, а не официальный релиз автора.

## Установка

Распакуйте ZIP или откройте DMG и перенесите `Delegator.app` в `/Applications`
либо `~/Applications`. Запустите приложение, добавьте свои API-ключи во вкладке
API и включите нужные интеграции. Закрытие окна оставляет приложение в строке меню;
выход выполняется через пункт «Выйти из Delegator».

Сборка подписана локальной ad-hoc подписью, без Apple Developer ID и нотариализации.
Для загруженной сборки macOS может потребовать разрешить открытие в настройках
«Защита и безопасность». Локально собранное приложение запускается обычным способом.

Внутри находятся Rust GUI, самостоятельное Python-ядро, PowerShell 7.4 и Python
для бенчмарков. Устанавливать Python, Rust или PowerShell на целевой Mac не нужно.
OpenCode CLI требуется только для моделей `opencode/*`. Его можно установить
отдельно либо через npm кнопкой в интерфейсе, если Node.js уже установлен.
Для API-провайдеров OpenCode CLI не требуется.

## Данные

| Что | Где |
| --- | --- |
| Конфигурация | `~/Library/Application Support/Delegator/config.json` |
| База ядра | `~/Library/Application Support/Delegator/core/` |
| Журналы и кэш | `~/Library/Application Support/Delegator/runtime/` |
| API-ключи | login Keychain, сервис `org.delegator.macos.api-keys` |
| Автозапуск | `~/Library/LaunchAgents/org.delegator.macos.plist` |

В конфигурации сохраняются ссылки `keychain:...`, а сами ключи читает Security.framework.
Windows DPAPI-ключи нужно ввести заново. Интеграции выключены по умолчанию и
включаются пользователем в интерфейсе. При включении меняется блок Delegator
в соответствующих файлах инструкций IDE.

Проверка ядра: `curl http://127.0.0.1:1380/health`.

CLI (путь обязательно заключать в кавычки):

```sh
"/Applications/Delegator.app/Contents/Resources/runtime/ai-delegate" models
"/Applications/Delegator.app/Contents/Resources/runtime/ai-delegate" assist -PromptFile /tmp/task.txt
```

Для удаления интеграций и автозапуска перед удалением приложения:

```sh
"/Applications/Delegator.app/Contents/MacOS/delegator" --remove-hooks
"/Applications/Delegator.app/Contents/MacOS/delegator" --disable-autostart
```

## Сборка

Нужны Xcode Command Line Tools, stable Rust и framework Python 3.12+ с python.org.
Сборка выполняется на Mac нужной архитектуры (Intel или Apple Silicon):

```sh
python3 scripts/build-macos.py
```

Скрипт устанавливает закреплённые зависимости в локальное `.venv-macos`, проверяет
SHA-256 архива PowerShell, запускает тесты, собирает `.app`, ZIP и DMG в `dist/`.
Перед созданием архивов проверяется запуск ядра из подписанного `.app`, его
HTTP-интерфейс и встроенные Python/PowerShell с временными данными. Проверка
готового приложения выполняется и с `--skip-tests`.
`--debug` ускоряет разработку; `--skip-tests` пропускает тесты исходников; `--no-dmg` создаёт
только приложение и ZIP. Минимальная целевая версия macOS — 12.0.

Автоматическая установка обновлений из Windows-релизов не поддерживается.
Обновлять этот порт нужно вручную, заменяя `.app`; пользовательские данные остаются
в Application Support. Apple Silicon требует отдельной сборки и проверки на ARM Mac.

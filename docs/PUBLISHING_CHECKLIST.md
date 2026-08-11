# Чек-лист публикации на GitHub

Перед открытием публичного репозитория:

- [ ] Выбрать и добавить `LICENSE`; это юридическое решение владельца.
- [ ] Указать владельца и URL репозитория в `Cargo.toml` и badges README.
- [ ] Включить GitHub Private Vulnerability Reporting.
- [ ] Включить secret scanning и push protection.
- [ ] Проверить первый commit командами `scripts\audit-release.ps1` и `git status --ignored`.
- [ ] Убедиться, что `dist\`, `target\`, `.venv*\`, AppData, базы и журналы не staged.
- [ ] Собрать установщик из чистого clone через ручной workflow **Build Windows installer**.
- [ ] Проверить установку, обновление, автозапуск, tray, IDE hooks и удаление в Windows VM.
- [ ] Проверить жёлтую диагностику при отсутствии OpenCode CLI.
- [ ] Подписать `delegator.exe`, `delegator-core.exe`, установщик и деинсталлятор перед широкой раздачей.
- [ ] Публиковать SHA-256 каждой beta-сборки.

Не добавляйте Git remote, не выполняйте commit/push, не создавайте release и не загружайте артефакты без явного разрешения владельца репозитория.

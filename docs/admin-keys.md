# Управление ключами пользователей

Все ключи LLM API владеет `internal-auth-provider`. Файл ключей живёт на
хосте (`secrets/keys.acl`), примонтирован в контейнер только на чтение.
UI нет — всё через `make` на хостовой машине.

## Формат `secrets/keys.acl`

Один ключ на строку: `имя:ключ`. Строки с `#` — комментарии.
Права `600`, файл в git не попадает (`.gitignore`).

## Права на файл (rootless podman)

`keys.acl` на хосте принадлежит администратору, права `600`. Контейнер
`internal-auth-provider` читает его, запускаясь от uid 0 (`user: "0:0"` в
compose): при rootless podman uid 0 внутри контейнера — это uid администратора
хоста, поэтому файл читается без chown и без флага монтирования `U`. Файл
остаётся вашим: `make` и редактирование — от обычного пользователя, `podman
unshare` не нужен. (Ранее стоял флаг `U`, переставлявший владельца файла на
подuid — из-за чего ключ переставал принадлежать админу. Это снято.)

## Операции

```bash
make init                       # создать пустой secrets/keys.acl и .env из примеров
make key-add NAME=agent-lap1    # добавить ключ (значение покажется ОДИН раз)
make key-rotate NAME=agent-lap1 # перевыпустить значение существующего ключа
make key-list                   # имена ключей без значений
make key-rm NAME=agent-lap1     # удалить ключ (отзыв)
```

`key-add` на существующее имя не срабатывает и подсказывает `key-rotate` — так
значение не дублируется. После `key-add`/`key-rotate`/`key-rm` ничего
перезапускать не нужно: auth-provider перечитывает файл при изменении mtime
(секунды). Отзыв: следующий запрос со старым/удалённым ключом получает 401.

## Сервисный ключ web-ui

```bash
make key-add NAME=webui        # показать значение
# вставить значение в .env: WEBUI_SERVICE_KEY=<значение>
make up                        # пересоздать web-ui с новым значением
```

Значение в `.env` и в `keys.acl` — одно и то же; при `key-rm NAME=webui`
обновите и `.env`.

## Выдача ключа агенту (ноутбук в LAN)

Точка входа: `http://LAN_IP:8731/v1` (HTTP — решение MVP; TLS — roadmap).

- **Anthropic-совместимый вход (Claude Code):**
  `ANTHROPIC_BASE_URL=http://LAN_IP:8731` + `ANTHROPIC_API_KEY=<ключ>`
  (клиент шлёт `x-api-key`).
- **OpenAI-совместимый вход (SDK, Codex, curl):**
  `OPENAI_BASE_URL=http://LAN_IP:8731/v1` + `OPENAI_API_KEY=<ключ>`
  (`Authorization: Bearer`).

Проверка с ноутбука:

```bash
curl -s http://LAN_IP:8731/v1/models -H "Authorization: Bearer <ключ>"   # 200 + список моделей
curl -s -o /dev/null -w '%{http_code}\n' http://LAN_IP:8731/v1/models     # 401 без ключа
```

## Безопасность (принятые ограничения MVP)

- Ключи ходят по LAN открытым HTTP — сниффер в LAN их увидит.
  Roadmap: self-signed TLS на 8731 (CLAUDE.md §9).
- 4 ключа: 3 агентских + 1 сервисный (`webui`). Имена — только для людей,
  в логах squid/auth-provider ключ не светится (auth-provider печатает только
  количество).

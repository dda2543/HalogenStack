# Чек-лист проверки на сервере (фаза 1)

Выполняется человеком на сервере. Всё — из каталога проекта, от обычного
пользователя podman (root не нужен, кроме мест с `sudo`).
Порядок: сначала запуск (A), затем изоляция (B), затем функции (C),
затем эксперименты по ужесточению (D).

## A. Запуск

- [ ] Подготовлено: podman ≥ 5.7, podman-compose, модели в `HALOGEN_MODELS_DIR`,
      домены в `.env` (`LAN_IP` — адрес LAN-интерфейса, не 127.0.0.1).
- [ ] `make init` — созданы `secrets/keys.acl`, `.env`.
- [ ] `make key-add NAME=webui` → значение в `.env` (`WEBUI_SERVICE_KEY`);
      `WEBUI_SECRET_KEY=$(openssl rand -hex 32)` в `.env`.
- [ ] `make key-add NAME=agent-lap1` (×3 для агентских ключей).
- [ ] `make up` → `make ps`: все 5 контейнеров up; у `halogen-auth-provider`
      статус healthy (спустя ~30 с).
- [ ] `podman logs halogen-flash-server` — модель загрузилась, ошибок ROCm нет.

## B. Изоляция (главная часть)

- [ ] Порт на хосте только один:
      `ss -ltnp | grep -E '8731|8000|3128|8080'` — виден только `LAN_IP:8731`.
- [ ] Сети: `podman network inspect halogen-stack-internal halogen-stack-egress` —
      `"internal": true` у обеих; в `halogen-stack-wan` только egress-proxy:
      `podman network inspect halogen-stack-wan --format '{{range .Containers}}{{.Name}} {{end}}'`.
- [ ] У web-ui нет прямого пути наружу (ожидаем исключение таймаута/refused):
      `podman exec halogen-web-ui python -c "import socket;socket.create_connection(('1.1.1.1',443),4)"`
- [ ] halogen не видит LAN/интернет:
      `podman exec halogen-flash-server cat /proc/net/route` — маршрут по
      умолчанию отсутствует (внутренняя сеть).
- [ ] auth-provider без портов: `ss -ltnp | grep 9000` — пусто.
- [ ] forward-auth работает:
      `curl -s -o /dev/null -w '%{http_code}\n' http://LAN_IP:8731/v1/models` → 401;
      с `-H "Authorization: Bearer <ключ>"` → 200.
- [ ] Query-строка в URL не режется (регрессия: агенты шлют `/v1/...?` и
      `?param=…`; раньше forward_auth передавал её на `/authz` → 404):
      `curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer <ключ>" http://LAN_IP:8731/v1/models?` → 200;
      с `?x=1` → 200; без ключа с `?x=1` → 401 (не 404!).
- [ ] `/healthz` открыт: `curl -s http://LAN_IP:8731/healthz` → 200 (версию
      halogen видно — при публичном входе фазы 2 решим, закрыть ли).
      ВНИМАНИЕ: `/healthz` — это halogen (Caddy переписывает на `/health`),
      а `/health` на том же порту — это web-ui (catch-all `handle`), не halogen.
      Отличать по `Server:` в ответе: `uvicorn` vs web-ui.
- [ ] squid: пустой whitelist → `podman exec halogen-web-ui python -c "import requests;requests.get('http://example.org',timeout=10)"` → ошибка.
- [ ] SELinux: `sudo ausearch -m avc -ts boot | grep -i halogen` — пусто
      (или объяснить каждую запись).

## C. Функции

- [ ] SSE-стриминг сквозь reverse-proxy (чанки идут постепенно, не пачкой в конце):
      `curl -N http://LAN_IP:8731/v1/chat/completions -H "Authorization: Bearer <ключ>" -H 'content-type: application/json' -d '{"model":"<имя из /v1/models>","messages":[{"role":"user","content":"скажи 1..5"}],"stream":true}'`
- [ ] Open WebUI: вход создаётся только админом (ENABLE_SIGNUP=false),
      чат через сервисный ключ отвечает.
- [ ] whitelist: `make whitelist-add DOMAIN=php.net` → тесты из
      `admin-whitelist.md` (200 html / картинка отклонена / не-whitelist отклонён).
      `make whitelist-rm DOMAIN=php.net` → php.net снова отклонён.
- [ ] Отзыв ключа: `make key-rm NAME=agent-lap1` → запрос с этим ключом → 401.

## D. Эксперименты по ужесточению (отмечать результат)

- [ ] **ipc:** убрать `ipc: host`, добавить `shm_size: "32gb"` → `make up`.
      Жив? Нет (ошибки shm/ROCm в логах)? → вернуть `ipc: host` (принятое
      ограничение, зафиксировать в CLAUDE.md §6.1).
- [ ] **NET_RAW:** сейчас `cap_drop: [ALL]` без `cap_add` — если halogen не
      стартует, добавить `NET_RAW` отдельно и записать, что она реально нужна.
- [ ] **read_only halogen:** старт с `read_only: true` + tmpfs — фиксируем,
      какие пути потребовали tmpfs.
- [ ] Open WebUI `HTTP_PROXY`/`NO_PROXY`: чат работает (запросы к
      reverse-proxy не идут через squid) — при проблемах расширить `NO_PROXY`.

## Е. Что считать эталоном «зелёного» прогона

Все пункты A–C зелёные; D — с зафиксированными решениями (что включили обратно
и почему). Результат прогона — комментарий к коммиту или апдейт этого файла.

# Чек-лист проверки на сервере (фазы 1–2)

Выполняется человеком на сервере. Всё — из каталога проекта, от обычного
пользователя podman (`sudo` нужен только в `make cert` / `cert-renew` и для
`sysctl`). Порядок: A (запуск) → B (изоляция) → C (функции) → D (ужесточение) →
E (публичный вход, только если включена фаза 2).

URL с `?` в curl **обязательно в кавычках** — иначе shell съест символ как glob
(именно так в одном из прогонов получился `/v1/model?s`).

## 0. Статус последнего прогона

Зелёное (подтверждено на сервере 2026-10-26):

- A полностью: 5 контейнеров up, `make init`/`key-add`/`key-rm` работают;
- B: forward-auth 401/200, query-строки после фикса — 200, `/healthz` → 200
  (после `rewrite /health`), egress-политика squid работает (403 на всё,
  whitelist пуст);
- C: чат через WebUI и прямой API-ответ модели `halogen-qwen3.8-flash-next`.

Не проверялось (новый код с 2026-10-26):

- C: `make key-rotate`, проверка чистого лога web-ui после `OFFLINE_MODE`;
- D: ни один эксперимент по ужесточению ещё не прогонялся;
- E: вся фаза 2 — каркас написан без podman/сети, ни один пункт не проверялся.

## A. Запуск (фаза 1)

- [ ] Подготовлено: podman ≥ 5.7, podman-compose, модели в `HALOGEN_MODELS_DIR`,
      в `.env` заданы `LAN_IP` (адрес LAN-интерфейса, не 127.0.0.1),
      `HALOGEN_MODELS_DIR`, `CACHE_DIR`, `SECRETS_DIR`.
- [ ] `make init` — созданы `secrets/keys.acl` (0600) и `.env` из примеров.
- [ ] 4 ключа: `make key-add NAME=webui` (значение → `WEBUI_SERVICE_KEY` в
      `.env`) и три агентских. `WEBUI_SECRET_KEY=$(openssl rand -hex 32)` в
      `.env`.
      Внимание: `key-add` не идемпотентен — для перевыпуска существующего имени
      использовать `make key-rotate NAME=...`.
- [ ] `make up` → `make ps`: 5 контейнеров up; у `halogen-auth-provider`
      статус healthy (спустя ~30 с).
- [ ] `podman logs halogen-flash-server` — модель загрузилась, ошибок ROCm нет,
      видно `listening on 0.0.0.0:8731` и версию 0.18.15.

## B. Изоляция (главная часть)

- [ ] Портов на хосте ровно один (фаза 1):
      `ss -ltnp | grep -E ':(8731|443|3128|8080|9000)\b'` — виден только
      `LAN_IP:8731`. В фазе 2 добавляется `0.0.0.0:443` (waf-firewall) — и
      только. `8080`/`3128`/`9000` наружу не светятся.
- [ ] Если путь агентов переведён на WireGuard (§3.1 архитектуры): `8731`
      слушает только туннельный адрес — `ss -ltnp | grep 8731` →
      `10.80.0.1:8731`, и с устройства, которое не пир WG, `nc -vz <адрес-хоста>
      8731` недоступен. Настройка: `docs/admin-server-ubuntu.md`,
      `docs/admin-client-macos.md`.
- [ ] Сети: имена посмотреть через `podman network ls` (префикс проекта —
      `halogen-stack`, разделитель зависит от версии podman-compose). У
      `internal`, `egress` и `public` — `"internal": true`; в `wan` только
      egress-proxy:
      `podman network inspect <wan> --format '{{range .Containers}}{{.Name}} {{end}}'`.
- [ ] У web-ui нет прямого пути наружу (ожидаем таймаут/refused):
      `podman exec halogen-web-ui python -c "import socket;socket.create_connection(('1.1.1.1',443),4)"`
- [ ] halogen не видит LAN/интернет:
      `podman exec halogen-flash-server cat /proc/net/route` — маршрута по
      умолчанию нет (внутренняя сеть).
- [ ] auth-provider без портов: `ss -ltnp | grep 9000` — пусто.
- [ ] forward-auth работает:
      `curl -s -o /dev/null -w '%{http_code}\n' http://LAN_IP:8731/v1/models` → 401;
      с `-H "Authorization: Bearer <ключ>"` → 200.
- [ ] Query-строка в URL не режется (регрессия: агенты шлют `/v1/...?` и
      `?param=…`; раньше forward_auth передавал её на `/authz` → 404):
      `curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer <ключ>" 'http://LAN_IP:8731/v1/models?'` → 200;
      с `?x=1` → 200; без ключа с `?x=1` → 401 (не 404!).
- [ ] Голый `/v1` тоже уходит в API, а не в web-ui (регрессия матчера
      `path /v1 /v1/*`): `curl -s -o /dev/null -w '%{http_code}\n' http://LAN_IP:8731/v1` → 401,
      а не HTML от Open WebUI.
- [ ] `/healthz` открыт: `curl -s http://LAN_IP:8731/healthz` → 200 (версию
      halogen видно — см. пункт E про публичный доступ).
      ВНИМАНИЕ: `/healthz` — это halogen (Caddy переписывает на `/health`),
      а `/health` на том же порту — это web-ui (catch-all `handle`), не halogen.
      Отличать по заголовку `Server:`: `uvicorn` vs web-ui.
- [ ] squid: пустой whitelist →
      `podman exec halogen-web-ui python -c "import requests;requests.get('http://example.org',timeout=10)"`
      → ошибка.
- [ ] SELinux: `sudo ausearch -m avc -ts boot | grep -i halogen` — пусто
      (или объяснить каждую запись).

## C. Функции

- [ ] SSE-стриминг сквозь reverse-proxy (чанки идут постепенно, не пачкой в конце):
      `curl -N http://LAN_IP:8731/v1/chat/completions -H "Authorization: Bearer <ключ>" -H 'content-type: application/json' -d '{"model":"<имя из /v1/models>","messages":[{"role":"user","content":"скажи 1..5"}],"stream":true}'`
- [ ] Open WebUI: вход создаётся только админом (ENABLE_SIGNUP=false),
      чат через сервисный ключ отвечает.
- [ ] web-ui не пытается качать модели (`OFFLINE_MODE=true`):
      `podman logs --since 5m halogen-web-ui 2>&1 | grep -iE "proxyerror|SentenceTransformer"`
      — пусто. (До OFFLINE_MODE здесь был `httpx.ProxyError: 403 Forbidden` —
      штатная работа egress, но шум и мёртвый RAG.) Требует рестарта web-ui
      после правки compose.
- [ ] Перевыпуск ключа: `make key-rotate NAME=agent-lap1` → старый ключ → 401,
      новый из вывода → 200 (auth-provider перечитывает `keys.acl` по mtime,
      рестарт не нужен). **Ещё не проверялось.**
- [ ] whitelist: `make whitelist-add DOMAIN=php.net` → тесты из
      `admin-whitelist.md` (200 html / картинка отклонена / не-whitelist отклонён);
      `make whitelist-rm DOMAIN=php.net` → php.net снова отклонён.
- [ ] Отзыв ключа: `make key-rm NAME=agent-lap1` → запрос с этим ключом → 401.

## D. Эксперименты по ужесточению (отмечать результат)

- [ ] **ipc:** убрать `ipc: host`, добавить `shm_size: "32gb"` → `make up`.
      Жив? Нет (ошибки shm/ROCm в логах)? → вернуть `ipc: host` (принятое
      ограничение; зафиксировать в `CLAUDE.md` §6, п. 1 и 7).
- [ ] **NET_RAW:** сейчас `cap_drop: [ALL]` без `cap_add` — если halogen не
      стартует, добавить `NET_RAW` отдельно и записать, что она реально нужна.
- [ ] **read_only halogen:** старт с `read_only: true` + tmpfs — зафиксировать,
      какие пути потребовали tmpfs.
- [ ] Open WebUI `HTTP_PROXY`/`NO_PROXY`: чат работает (запросы к
      reverse-proxy не идут через squid) — при проблемах расширить `NO_PROXY`.

## E. Фаза 2 — публичный вход (только после зелёных A–C)

Предпосылки и разбор отказов: `docs/admin-public.md`. В `.env` заданы
`PUBLIC_DOMAIN` и `CERTS_DIR`.

- [ ] `sysctl net.ipv4.ip_unprivileged_port_start` = 0 (иначе публикация 443 в
      rootless podman не поднимется).
- [ ] `make waf-build` собирает образ; **записать фактические версии**
      `coraza-caddy` и CRS и зафиксировать их в `waf/Dockerfile` (ARG) —
      сейчас там `latest` и `v4.4.0`, не проверены.
- [ ] `make cert CERT_EMAIL=...` выпускает сертификат; в `${CERTS_DIR}` лежат
      `fullchain.pem` + `privkey.pem` 0600, владелец — администратор хоста
      (не root!), и `git status` их не видит (`.gitignore`).
- [ ] `make public-up` → `make ps`: 6 контейнеров, `halogen-waf` Up (healthy).
- [ ] `podman exec halogen-waf caddy validate --config /etc/caddy/Caddyfile` — OK.
- [ ] снаружи основной smoke: `curl -s -o /dev/null -w '%{http_code}\n' https://ai.dda2543.ru/` → 200
      (логин Open WebUI по HTTPS, сертификат валиден).
- [ ] LLM API снаружи закрыт: `https://ai.dda2543.ru/v1/models` — даже с
      валидным ключом → **403**, а не 200/401.
- [ ] **Решить судьбу `/healthz` наружу.** Сейчас `https://ai.dda2543.ru/healthz`
      отвечает 200 и отдаёт версию halogen — то есть публично доступен номер
      версии движка. Варианты: оставить (диагностика) или закрыть на waf
      (`respond 403` для `path /healthz`). Зафиксировать решение в
      `CLAUDE.md` §1.2.
- [ ] HTTP снаружи не обслуживается: `curl -sv http://ai.dda2543.ru/ 2>&1 | tail -3`
      → соединение отклонено (редиректа на HTTPS в каркасе нет, осознанно).
- [ ] LAN-путь не пострадал: `http://LAN_IP:8731/v1/models` с ключом → 200.
- [ ] SSE сквозь WAF: чат в WebUI через `https://ai.dda2543.ru` отвечает
      стримингом (чанки постепенно, не пачкой).
- [ ] waf не имеет выхода наружу: `podman exec halogen-waf cat /proc/net/route`
      — маршрута по умолчанию нет (сеть `public` — internal).
- [ ] Ложные срабатывания CRS разобраны
      (`podman logs --since 1h halogen-waf 2>&1 | grep -i coraza`),
      `SecRuleEngine` переключён `DetectionOnly` → `On`, WebUI продолжает
      работать (вход, чат, загрузка файла).
- [ ] `make cert-renew` продлевает и перезапускает waf (`curl -v` показывает
      новый срок действия сертификата).

## Ж. Что считать эталоном «зелёного» прогона

A–C зелёные; D — с зафиксированными решениями (что вернули и почему); E —
зелёные, если фаза 2 включена. Результат прогона — запись в `CLAUDE.md` §10
(журнал) и, если менялся состав проверок, апдейт этого файла.

## Приложение: известные грабли

- **Права на `keys.acl`.** Rootless podman: uid 0 контейнера = uid администратора
  хоста, поэтому auth-provider запускается `user: "0:0"` и читает файл 0600 без
  `chown`. Флаг монтирования `U` не использовать — он переставляет владельца файла
  на подuid и ломает доступ администратору.
- **Тег squid мутабелен.** Образ egress запинен по digest (`compose.yaml`);
  тегов `:6`/`:stable` у Canonical нет, схема — `<ver>-<ubuntu>_{beta,edge}`.
- **`make key-add` не идемпотентен** — для смены значения `key-rotate`.
- **`make cert`/`cert-renew` требуют sudo** (certbot), всё остальное — от
  обычного пользователя.

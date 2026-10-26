# CLAUDE.md — halogen-stack

Рабочий документ проекта. Инструкции среды для агента — в `/docs/CLAUDE.md`
(он приоритетнее этого файла в вопросах запуска контейнера, сети, прав на запись).

## 1. Цели проекта

1. Безопасный запуск `halogen-flash-server` (LLM-инференс-сервер).
2. Обратный прокси перед `halogen-flash-server` — изолировать от прямых запросов.
3. Персональные ключи пользователей (поддержка 4 пользователей).
4. Запуск WebUI (Open WebUI).
5. Изоляция всех приложений от хостовой машины.
6. Изоляция приложений от интернета: приложения не исходят наружу; WebUI —
   только GET на разрешённые сайты.

**Статус: цели и план ещё согласованы не полностью.** Не начинать реализацию
без явного «go» по текущему этапу.

### 1.1 Список сервисов (зафиксирован 2026-10-25)

Основные:

| # | Сервис | Роль |
|---|---|---|
| 1 | halogen-flash-server | LLM-инференс |
| 2 | web-ui | Open WebUI |
| 3 | internal-auth-provider | владеет всеми ключами пользователей |
| 4 | reverse-proxy | единственная точка входа к LLM API |
| 5 | waf-firewall | фильтрация входящего трафика |
| 6 | egress-proxy | squid: единственный маршрут web-ui наружу (whitelist + GET) |

На будущее (возможно, на отдельном сервере мониторинга): metrics-waf,
node-exporter, blackbox-exporter, prometheus, grafana.

### 1.2 Зафиксированные решения (2026-10-25)

- Все ключи пользователей — у `internal-auth-provider`.
- Редактирование ACL — конфигурационными файлами; UI не нужен, но процесс
  подробно документируется.
- WebUI разрешено чтение документации (пример: php.net); видео, картинки и
  прочий медиа-контент запрещён.
- GPU-проброс принят как ограничение изоляции от хоста.
- Проверенный `compose.yaml` — **не эталон**; любые отклонения требуют тестов
  на сервере пользователя.
- `internal-auth-provider` — **своя минимальная реализация**. Ключи хранятся на
  хостовой машине, монтируются в контейнер auth-provider. Обновление ключей,
  ACL и whitelist WebUI — через `make` администратором сервера (вне контейнера).
- Модель пользователей (4 ключа auth-provider):
  - 3 ключа — агенты с 2 ноутбуков в **локальной сети** (прямой API-доступ);
  - 1 ключ — сервисный, для `web-ui` (живёт в internal-сети).
- Учётные записи Open WebUI — для **внешних** пользователей, в т.ч. из
  интернета. auth-provider их не касается: WebUI ходит в LLM одним сервисным
  ключом.
- LLM API доступен **только через reverse-proxy** с проверкой ключа через
  auth-provider (forward-auth, подтверждено). `halogen-flash-server` и
  `internal-auth-provider` не имеют портов на хосте: из интернета и напрямую
  недоступны.
- Публичный вход: `https://ai.dda2543.ru` → `waf-firewall` (TLS-терминация +
  CRS). Сертификат — certbot на хосте через `make`. **DNS-запись ai.dda2543.ru
  ещё не создана** — предпосылка публичного запуска.
- Scope WAF — только публичный путь WebUI (LAN-путь агентов без WAF).
- Каркас фазы 2 (создан 2026-10-26, **на сервере не проверялся**):
  `compose.public.yaml` (waf-firewall в сети `public`, порт хоста `443`→`8443`
  в контейнере — без `CAP_NET_BIND_SERVICE`), `waf/Dockerfile` (Caddy+Coraza+CRS,
  версии ARG — зафиксировать после первой сборки), `config/caddy/Caddyfile.waf`
  (`SecRuleEngine DetectionOnly` на первый прогон), `make waf-build/public-up/
  cert/cert-renew`, `docs/admin-public.md`, чек-лист §Е. Два решения: сертификат
  через `certbot --standalone` (waf занимает только 443; редиректа HTTP→HTTPS
  нет), и reverse-proxy отвечает `403` на `/v1/*` с публичным `Host` — LLM API
  наружу не светится. Предпосылка на хосте: `net.ipv4.ip_unprivileged_port_start=0`.
- Механизм auth-provider (подтверждён): reverse-proxy → forward-auth к
  auth-provider на каждый запрос; ключи в файлах хоста, перечитывание по
  сигналу/таймеру.
- Путь агентов (решение 2026-10-26, заменило «HTTP в LAN» и «self-signed TLS»):
  **WireGuard на сервере + VLAN-containment на роутере**. `8731` биндится на
  туннельный адрес (`LAN_IP=10.80.0.1`), в LAN слушателя нет; из интернета
  проброшены только 443 и 80 (ACME). Два слоя ключей (пир WG + `keys.acl`) —
  осознанно. Документация: `docs/admin-router-mikrotik.md`,
  `docs/admin-server-ubuntu.md`, `docs/admin-client-macos.md`; канон —
  `docs/architecture.md` §3.1. Реализация — вне репозитория (роутер и хост),
  агент к ней не причастен.
- Whitelist доменов WebUI: **изначально пуст**; в документации — пример
  добавления php.net.
- web-ui запускается с `OFFLINE_MODE: "true"` (решение 2026-10-26): эмбеддинги с
  HuggingFace не скачиваются (их всё равно режет egress), проверка версий
  выключена. Следствие — RAG-встраивания в MVP не работают; возврат только через
  монтирование готового кэша HF отдельным томом.
- `egress-proxy` (squid) **одобрен** как 6-й сервис: единственный контейнер
  с маршрутом наружу; web-ui ходит через него по `HTTP_PROXY`.
- ПО прокси **одобрено — Caddy дважды**: `waf-firewall` = Caddy+Coraza (CRS),
  `reverse-proxy` = чистый Caddy с `forward_auth` к auth-provider.
- MVP: `halogen-flash-server` запускается **без** `HALOGEN_API_KEY` (не
  тестирован на сервере). Защита LLM API — только сетевая изоляция (доступен
  лишь с reverse-proxy). Включение ключа — roadmap (§9).

## 2. Режим работы

- Планируем и обсуждаем до правок. Ищем противоречия, фиксируем их здесь.
- Маленькие подзадачи: минимальный результат → правки. Не брать всё сразу.
- Лимит рассуждения/ответа агента — 12k токенов, думать поэтапно.
- `git push` — только человек. `git commit` — **разрешён агенту** решением
  пользователя от 2026-10-25 (чекпоинты ради чистого diff и отката).
  Ограничения: не переписывать историю (amend/rebase/reset на закоммиченном),
  коммитить только осмысленные вехи, сообщение коммита — на русском.

## 3. Среда разработки (контейнер агента)

- Режим: **dev** (`/workspace/src` — rw). Podman 5.7.0 на хосте пользователя.
- Сеть контейнера агента: internal-сеть, наружу только через HTTP-прокси
  `http://proxy:3128`. Это же — эталон паттерна изоляции для halogen-stack.
- Секреты (`.env`, токены) агенту недоступны намеренно.
- При сетевой ошибке — остановиться и сообщить человеку, не искать обходы.
- Инструменты в контейнере агента (проверено 2026-10-25): **node v24** — основной
  скриптовый инструмент (текстовые/файловые операции делать на нём), есть также
  `perl` и `git`. **Нет `python3`, `jq`, `yq`, `make`, `curl`, `wget`, `podman`** —
  не пробовать, сразу node.
- `podman` и `make` — на сервере пользователя, не у агента: compose/Makefile
  здесь пишутся, но выполняются и тестируются человеком на сервере.

## 4. Справочные материалы (`/docs`, он же `reference/`)

| Путь | Что это |
|---|---|
| `/docs/compose.yaml` | Проверенный на сервере пользователя standalone-compose для `halogen-flash-server:0.18.15`. **Безопасности не обеспечивает** (host network). |
| `/docs/halogen-flash-server/` | Репозиторий LLM-сервера: README, `docs/` (configuration.md, api.md, sessions.md, limits.md…), `docker-compose.yml`. |
| `/docs/halogen-server/` | Родственный движок (Qwen3.8-27B, `ghcr.io/peonist-ai/halogen`). Не целевой компонент стека — справочный. |
| `/docs/open-webui/` | WebUI (Open WebUI, форк-подобный upstream). Целевой компонент. |
| `/docs/caddy/` | Исходники Caddy v2 — источник фактов о поведении `forward_auth`, матчеров и `rewrite` (сеть для поиска по GitHub недоступна). |

## 5. Установленные технические факты

- `halogen-flash-server` — OpenAI-совместимый API + Anthropic-совместимый вход
  (`x-api-key`), слушает порт **8731** (по умолчанию; env `HALOGEN_API_PORT`).
  Требует GPU-устройства хоста: `/dev/kfd`, `/dev/dri`, `ipc: host`, `memlock=-1`,
  группы video/render (`group_add: keep-groups`). Источник:
  `/docs/halogen-flash-server/docs/api.md:3`, `deploy/entrypoint.sh:27`
  (`API_PORT=${HALOGEN_API_PORT:-8731}`). Внимание: в проверенном `/docs/compose.yaml`
  стоит проброс `"8731:8000"`, но там `network_mode: host` — он игнорируется,
  приложение слушает 8731 (отсюда ошибочные «8000» в ранних версиях этого дока).
- **Аутентификация: ровно один ключ** `HALOGEN_API_KEY` (или `HALOGEN_API_KEY_FILE`).
  Без ключа — 401 на всех маршрутах кроме открытого `/health`.
  Источник: `docs/configuration.md:498+`, `docs/api.md:15`.
  ⇒ **Персональные ключи 4 пользователей возможны только на обратном прокси**
  (N пользовательских ключей → один upstream-ключ).
- Проверенный compose: `network_mode: host`, `read_only: true`, tmpfs `/tmp`/`/run`,
  `cap_drop: ALL` + `NET_BIND_SERVICE`/`NET_RAW`, модели `~/halogen-models:/models:ro`,
  кэш `./cache:/cache:z`. Источник: `/docs/compose.yaml`.
- SELinux-enforcing хост (флаг `:z` в проверенном compose) — учитывать при
  монтированиях и при выборе mTLS/сокетов.
- **`halogen-flash-server` 0.18.15 — FastAPI/uvicorn** (в логе — `Uvicorn running
  on http://0.0.0.0:8731`, предупреждение `@app.on_event("startup")`), в access-логе
  печатает полный request-target вместе с query (`"GET /v1/model?x=1" 404`).
  404 в таком случае — от неизвестного пути, а не из-за query. Query на валидном
  пути (`/v1/models?x=1`) на сервере ещё не проверялся. Источник: логи сервера,
  сессия 3.
- **Caddy `forward_auth` сохраняет query-строку исходного запроса.** Он реализован
  как `reverse_proxy` + `rewrite` на `uri`; `RawQuery` перезаписывается только если
  в самом `uri` есть `?` (`/docs/caddy/modules/caddyhttp/rewrite/rewrite.go:274`).
  Значит `POST /v1/messages?x=1` приходит на auth-provider как `GET /authz?x=1`.
  Лечится: `uri /authz?` (пустой `?` гасит query) + сравнение только пути в
  auth-provider.
- **Матчер `path` в Caddy видит только `r.URL.Path`, query игнорирует**
  (`/docs/caddy/modules/caddyhttp/matchers.go:439`). `/v1/*` — это prefix-матч по
  `/v1/` (`matchers.go:521`), поэтому голый `/v1` не матчится и проваливается в
  соседний `handle` (к web-ui).
- **rootless podman (на сервере):** uid 0 в контейнере = uid администратора
  хоста. Поэтому `internal-auth-provider` читает host-`keys.acl` (0600) через
  `user: "0:0"` в compose — без chown и без флага монтирования `U` (U
  переставлял владельца на подuid). Источник: `compose.yaml`
  (internal-auth-provider) + маппинг uid в rootless podman.

## 6. Обнаруженные противоречия (к разрешению на этапе планирования)

1. **Host network vs изоляция.** Проверенный compose использует `network_mode: host`
   (и `ipc: host` для ROCm shared memory). Цели 5–6 требуют internal-сетей.
   Нужно проверить, живёт ли `ipc: host` с podman-сетями (скорее да: ipc и сеть
   независимы), и чем заменить `NET_RAW`/`NET_BIND_SERVICE`.
2. ~~Один ключ сервера vs 4 пользователя~~ — **решено**: reverse-proxy Caddy +
   forward-auth к auth-provider (§1.2).
3. **WebUI наружу только GET на разрешённые сайты.** «Только документация» —
   семантически нефильтруемо; технический компромисс: egress-прокси (squid-подобный)
   с whitelist доменов + метод GET + allowlist Content-Type (text/html,
   text/plain). Медиа отсекается по Content-Type, но это эвристика. Требует
   конкретного списка доменов (§7.6). Также: сборка образа Open WebUI требует
   pypi/npm на build-time — это отдельный сетевой контекст, не runtime.
4. ~~GPU~~ — **принято как ограничение** (см. §1.2).
5. ~~Обратный прокси: какой?~~ — **решено**: Caddy (§1.2).
6. ~~Имя сервиса №1~~ — **разрешено**: сервис №1 = `halogen-flash-server`.
8. ~~Нет egress-фильтра для WebUI~~ — **решено**: `egress-proxy` (squid)
   одобрен как 6-й сервис (§1.2).
7. **`ipc: host` в проверенном compose** делит IPC-namespace хоста — против
   цели 5. Проверить на сервере: ROCm с приватным IPC + `shm_size` вместо
   `ipc: host`; заодно — нужна ли ещё `NET_RAW`.

## 7. Открытые вопросы к человеку

На 2026-10-25 открытых вопросов **не осталось** (всё закрыто в §1.2, §9).
Архитектура зафиксирована: **`docs/architecture.md`** (канон).
Каркас фазы 1 создан 2026-10-25 (`compose.yaml`, Caddyfile, squid.conf,
auth-provider, Makefile, примеры env/secrets); смоук-тест auth-provider в
контейнере агента — 6/6 PASS. Admin-руководства написаны: `docs/admin-keys.md`,
`docs/admin-whitelist.md`, `docs/server-test-checklist.md`. При подготовке
доков исправлен дефект каркаса: у web-ui появился бы прямой путь наружу через
сеть `egress` — теперь `egress` тоже `internal: true`, а squid выходит в мир
через отдельную сеть `wan` (единственный контейнер в ней). Чек-лист прогнан на
сервере 2026-10-26 (итоги — §10): 4/5 контейнеров подняты, egress-proxy (squid)
ещё `Exited(1)`. Открытых вопросов к человеку нет; рабочие дефекты — в §10.
Дальше по плану — каркас фазы 2.

## 8. Соглашения

- Факты в документации сопровождать ссылкой на файл-источник (`/docs/...` или `src/...`).
- Сетевые обращения — только через `HTTP_PROXY` (уже выставлен).
- Не трогать `settings.json`, `squid.conf`/`squid.d/` (см. `/docs/CLAUDE.md` §2).

## 9. Roadmap (после MVP)

- Внедрение пути агентов по §1.2: WG на сервере + VLAN на MikroTik (доки
  `admin-router-mikrotik.md` / `admin-server-ubuntu.md` / `admin-client-macos.md`),
  затем смена `LAN_IP` в `.env` на `10.80.0.1` и проверка чек-листа §Б.
- Стек мониторинга: metrics-waf, node-exporter, blackbox-exporter, prometheus,
  grafana — возможно, на отдельном хосте; сети проектировать с запасом под него.
- Публичный запуск WebUI требует: DNS-запись ai.dda2543.ru → IP сервера,
  certbot на хосте (через make), затем включение публичного входа.
- Единый вход в Open WebUI через auth-provider (OIDC) — если потребуется.
- Включить `HALOGEN_API_KEY` на halogen-flash-server (defense-in-depth: ключ
  знает только reverse-proxy) — после тестирования на сервере; в MVP работает
  без него, полагаясь на сетевую изоляцию (§1.2).

## 10. Журнал

**2026-10-25 (сессия 1).** Согласованы цели, список сервисов (6) и архитектура
(`docs/architecture.md` — канон); написан каркас фазы 1 (compose, Caddy
forward_auth, squid egress с пустым whitelist, auth-provider на node,
Makefile) и все руководства (`docs/admin-*.md`, `docs/server-test-checklist.md`);
смоук-тест auth-provider 6/6 PASS; исправлен дефект: у web-ui был прямой путь
наружу через `egress` — добавлена сеть `wan` (в ней только squid).
Коммиты сессии: `86b69e6..7e02505`.

**2026-10-26 (сессия 2).** Прогнан `docs/server-test-checklist.md` на сервере.
`make init` OK; `.env` донастроен; `make key-add` не идемпотентен (нужен
предварительный `make key-rm`) — все 4 ключа созданы. `make up` дал ошибки
(права + версия squid); человек ввёл 5 PR (#1–#5): Caddyfile-монтирование
`:ro:z`→`:ro,z`; образ egress `:6`→`:6.6-24.04_beta`; к монтированию ключей
добавлен флаг `U`; порт halogen `8000`→`8731` в Caddyfile; в squid.conf объявлен
`safe_ports` (использовался, но не был определён → фатальный краш squid),
`docs_content` разбит на 3 regex без кавычек, проверка Content-Type перенесена
из `http_access` в `http_reply_access` (`rep_header` — ACL фазы ответа; в фазе
запроса всегда ложен → резалось всё). auth-provider не читал ключи — обход
`podman unshare chown 1000:1000 ./secrets/keys.acl`. Итог: 4/5 контейнеров Up;
**egress-proxy (squid) — `Exited(1)`, не поднят**. Ревью: перенос `rep_header` и
`safe_ports` — верные фиксы реальных багов каркаса. Расхождения: тег squid
мутабелен (а тегов `:6`/`:stable`, как я ошибочно предполагал, вообще нет —
схема Canonical `<ver>-<ubuntu>_{beta,edge}`); флаг `U` — костыль (рекурсивно
меняет владельца файла на хосте, ключ перестал принадлежать пользователю).
**Исправлено в сессии 2:** `internal-auth-provider` запускается `user: "0:0"`
(rootless uid 0 = хост-админ читает 0600 `keys.acl`), `U` снят;
`keys.acl.example` стал комментариев (key-add не сталкивается с заглушками);
добавлен `make key-rotate` (перевыпуск значения) — требует проверки на сервере.
Образ egress-proxy запинен по digest `sha256:6a097f68…` (LTS noble, squid 6.6)
вместо мутабельного тега. Доки: исправлен устаревший факт §5 (порт), коммит
`b3a70dd`; права ключей —
§5 + `docs/admin-keys.md`. **Проверено на сервере (зелёный прогон):** все 5
контейнеров Up, squid держится (реальная причина `Exited(1)` — необъявленный
`safe_ports`, не regex: догадку про несколько inline-regex в `rep_header`
отбрасываем — squid 6.6 их принимает); auth-provider читает 4 ключа (`user:0:0`
подтверждён); сквозной authz: без ключа и с bogus → 401, с валидным → 200
(отдаётся модель `halogen-qwen3.8-flash-next`). Коммиты сессии: `b3a70dd..`
(см. git log).

**2026-10-26 (сессия 3).** Разобран дефект: агенты шлют на LLM URL с `?` и
GET-параметрами. Причина — `forward_auth` переписывает запрос на `uri /authz`, но
**сохраняет query-строку** исходного запроса (`rewrite.go:274`), а auth-provider
сравнивал `req.url` со строкой `/authz` точно → `/authz?x=1` давал 404 → Caddy
отдавал этот 404 клиенту (запрос «блокировался»). Голый хвостовой `?` (пустой
query) не ломался: Go не пишет `?` при пустом `RawQuery`. **Исправлено:**
auth-provider сравнивает только путь (`req.url.split("?",1)[0]`), в Caddyfile
`uri /authz?` (явно гасит query на auth-запросе) и матчер `@api path /v1 /v1/*`
(голый `/v1` не матчился `/v1/*` и проваливался к web-ui). Смоук-тест
auth-provider в контейнере агента — 9/9 PASS (в т.ч. `?x=1`, многопарный query,
401 без ключа с query, 404 на чужом пути). Факты — в §5. **Не проверено на
сервере** (нет `caddy`/`podman` у агента): прогнать новый пункт чек-листа §B и
`podman exec halogen-reverse-proxy caddy validate --config /etc/caddy/Caddyfile`.
Неизвестно также, терпит ли сам halogen query-параметры на `/v1/*` — исходников
нет в `/docs`, проверить `curl`-ом на сервере.

**Проверено на сервере (подтверждение фикса query-строк):**
`GET /v1/models?` с валидным ключом → 200. Дефект закрыт.
Два наблюдения из того же прогона:
- `GET /health` на порту прокси даёт 200 **не от halogen**: `/health` не матчится
  ни с `@health (/healthz)`, ни с `@api`, и уходит в catch-all `handle` → web-ui
  (его `/health` и отвечает). Разматч `/healthz` ↔ `/health` остаётся открытым.
- web-ui при старте: `httpx.ProxyError: 403 Forbidden` →
  `Error loading SentenceTransformer: 403` — это **наш egress работает**: Open WebUI
  тянет дефолтный `RAG_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2`
  с HuggingFace (`/docs/open-webui/backend/open_webui/config.py:1015`), squid
  режет пустым whitelist. Правильного обхода нет (качать бинарники через наш
  allowlist Content-Type всё равно нельзя) — см. точку входа: `OFFLINE_MODE=true`.

**Дополнено (та же сессия):** пункт «подключить Claude Code к halogen» закрыт
пользователем — агент работает с LLM через `HALOGEN_BASE_URL` (переключено на
разрабатываемую версию движка), проблема подключения устранена. Из shell-песочницы
агента этот адрес недоступен намеренно (нет маршрута; наружу только `HTTP_PROXY`)
— рантайм Claude Code ходит в LLM сам. Сквозная проверка `/v1/models` через стек
остаётся пунктом чек-листа §B на сервере.

**Исправлено (та же сессия):** разматч `/healthz` ↔ halogen `/health` — в
`handle @health` добавлен `rewrite /health` (подтверждено сервером: `/healthz`
давал 404 от uvicorn с `Via: 1.1 Caddy`). Заодно в чек-листе §B зафиксировано,
что `/health` на порту прокси — это web-ui (catch-all), а halogen — только
`/healthz`. **Требуется рестарт reverse-proxy + `caddy validate`.**

**Подтверждено на сервере:** `/healthz` → 200 после `rewrite /health`.

**Добавлено (решение человека):** web-ui переведён на `OFFLINE_MODE: "true"`
(`compose.yaml`, §1.2) — убирает стартовый `httpx.ProxyError: 403` и мёртвый
RAG. Требует рестарта web-ui и проверки из чек-листа §C.

**Каркас фазы 2 (конец сессии 3).** Создано: `compose.public.yaml`
(waf-firewall, сеть `public`, `443`→`8443`, `read_only`+tmpfs, `cap_drop: ALL`,
`user: "0:0"` под читаемость сертификатов 0600), `waf/Dockerfile`
(Caddy+Coraza+CRS, версии в ARG — не проверены), `config/caddy/Caddyfile.waf`
(TLS с файлов + Coraza в DetectionOnly), `scripts/cert-deploy.sh` (deploy-hook
certbot → `CERTS_DIR` с владельцем-админом), цели `make waf-build / public-up /
public-down / public-logs / cert / cert-renew`, `.env.example` (PUBLIC_DOMAIN,
CERTS_DIR), `docs/admin-public.md`, чек-лист §Е. Правки фазы 1: сеть `public`
объявлена в `compose.yaml`, reverse-proxy в неё подключён и получил
`PUBLIC_DOMAIN`, в его Caddyfile добавлен `403` на `/v1/*` с публичным `Host`.
Ничего из этого агент не запускал (нет podman/сети) — прогон §Е за человеком.
Там же актуализирован `docs/server-test-checklist.md`: заголовок «фазы 1–2»,
блок «0. Статус последнего прогона» (что уже зелёное и что не проверялось),
убран устаревший порт 8000, исправлена ссылка §6.1 → §6 п.1/7, добавлены
регрессии (голый `/v1`, `key-rotate`, чистый лог web-ui после OFFLINE_MODE),
имена сетей выводятся через `podman network ls` (разделитель зависит от версии
podman-compose), а пункт E про `/healthz` переформулирован как **решение**
(сейчас версия halogen доступна из интернета).

**Сегментация сети (решение человека, та же сессия).** Выбран «идеальный путь»:
WireGuard на сервере (путь агентов, `8731` только на туннельном адресе) +
VLAN-containment на MikroTik (сервер вне LAN, из интернета только 443 и 80).
Два слоя ключей приняты сознательно. Написаны три эксплуатационных документа:
`docs/admin-router-mikrotik.md`, `docs/admin-server-ubuntu.md`,
`docs/admin-client-macos.md`; канон дополнен §3.1, roadmap §9 переписан (пункт
«self-signed TLS для LAN» заменён на WG). Ничего из этого не проверялось агентом
(нет доступа ни к роутеру, ни к хосту) — синтаксис RouterOS, пути Homebrew и
номера адресов сверять на месте.

**Точка входа следующей сессии:** (1) рестарт web-ui → чек-лист §C (чистый лог
после OFFLINE_MODE); (2) предпосылки фазы 2 на хосте — DNS `ai.dda2543.ru`,
`net.ipv4.ip_unprivileged_port_start=0`, certbot — затем прогон чек-листа §Е
начиная с `make waf-build` (ждать ошибок по версиям ARG и синтаксису `seclang`);
(3) после зелёного §Е — переключение Coraza `DetectionOnly` → `On`.


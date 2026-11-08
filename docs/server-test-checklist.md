# Чек-лист проверки на сервере (фазы 1–2)

Выполняется человеком на сервере. Всё — из каталога проекта, от обычного
пользователя podman (`sudo` нужен только в `make cert` / `cert-renew` и для
`sysctl`). Порядок: A (запуск) → B (изоляция) → C (функции) → D (ужесточение) →
E (публичный вход, только если включена фаза 2).

URL с `?` в curl **обязательно в кавычках** — иначе shell съест символ как glob
(именно так в одном из прогонов получился `/v1/model?s`).

## Автоматизация: `scripts/check.sh`

Значительную часть §A, §A1, §B, §C и локальной §E прогоняет скрипт — он ничего
не меняет, только читает состояние контейнеров и дёргает HTTP:

```
bash scripts/check.sh                  # все секции
bash scripts/check.sh -s A,B           # только секции A и B
bash scripts/check.sh --key-name agent1
CHECK_KEY=… bash scripts/check.sh      # ключ прямо в окружении
bash scripts/check.sh --no-llm         # не гонять генерацию (дешевле)
bash scripts/check.sh -v               # печатать каждый запрос (ключ не печатается)
bash scripts/check.sh --self-test      # самопроверка парсеров, без сети и podman
```

Ключ: `CHECK_KEY`, иначе запись из `secrets/keys.acl` (имя — `--key-name`, по
умолчанию первый не-`webui`), иначе `WEBUI_SERVICE_KEY`. `LAN_IP`,
`PUBLIC_DOMAIN`, `SECRETS_DIR`, `CERTS_DIR` — из окружения (оно побеждает) и из
`.env`, то есть так же, как их читает podman-compose. Значения ключей скрипт не
печатает. Код возврата 0 — проваленных проверок нет.

Ручным остаётся то, что скрипт сознательно не трогает: скорость и доля кэша
промптов (нужна нагрузка Claude Code), крах при конкурентных strict tool calls
(наблюдение в бою), §D (меняет конфигурацию), наружная часть §E (TLS и CRS из
интернета) и вход в Open WebUI (браузер).

## 0. Статус последнего прогона

Зелёное (подтверждено на сервере 2026-10-26):

- A полностью: 5 контейнеров up, `make init`/`key-add`/`key-rm` работают;
- B: forward-auth 401/200, query-строки после фикса — 200, `/healthz` → 200
  (после `rewrite /health`), egress-политика squid работает (403 на всё,
  whitelist пуст);
- C: чат через WebUI и прямой API-ответ модели `halogen-qwen3.8-flash-next`.

Зелёное (подтверждено на сервере 2026-10-28):

- A: prompt-кэш только в RAM + `HALOGEN_FORK=0` — `./cache` пуст (4 KiB),
  `handles.json` не пересоздаётся, `PUBLIC_DOMAIN` из `podman-compose config`
  = `ai.dda2543.ru`; в логе `serve_api` пул на 39–40% (≈207k/524k) при кэше
  промптов 98.9–99.9% и 67–73 t/s;
- A: `make key-rotate NAME=webui` отработал (значение выдаётся один раз).
  Внимание: после перевыпуска `webui` нужно вписать значение в `.env` и
  `make up` — иначе web-ui шлёт старый ключ и получает 401 (`admin-keys.md`);
- C: чистый лог web-ui после рестарта с `OFFLINE_MODE` — ни `ProxyError`, ни
  403; `all-MiniLM-L6-v2` грузится из тома `webui_data`, значит
  RAG-встраивания **работуют** (см. §1.2 CLAUDE.md — прежняя формулировка была
  неверна); 401 после перевыпуска ключа тоже нет.
- E (частично, локально — публичного пути ещё нет): `/healthz` наружу закрыт.
  Проверено подстановкой публичного `Host` на LAN-порту прокси:
  `curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: ai.dda2543.ru' http://${LAN_IP}:8731/healthz` → **403**,
  тот же запрос без заголовка → **200**. Значит матчер `@public_halogen`
  разобран живым Caddy, а `caddy validate` по этому матчеру не нужен.

Зелёное (подтверждено на сервере 2026-11-08):

- A1 (частично): 0.20.0 поднялся — `version 0.20.0, engine version 0.20.0`,
  слушает `[::]` и `0.0.0.0:8731` (движок отдельно, на `127.0.0.1:8730`),
  warm start 0.29 с до `listening` — значит генерация на ROCm 10.1 работает,
  `HALOGEN_MAX_TOKENS_DEFAULT` и `HALOGEN_REASONING_EFFORT` видны в логе,
  предупреждения `on_event` больше нет.

Зелёное (подтверждено 2026-11-09 по логу halogen за рабочий сеанс):

- A1: 61 запрос через прокси, все `200`, ошибок ROCm/HIP/OOM нет;
- A1: доля кэша промптов 93.7–100%, генерация 49–105 t/s (прежние замеры
  0.18.15 — 67–73), холодный prefill ≈2100 t/s (131k токенов за 62 с) —
  RAM-only на 0.20.0 отрабатывает, скорость не просела;
- A1: фикс 0.18.23 про end-of-turn внутри reasoning виден в логе счётчиком
  `end of turn kept as text: N in the think block`.

Зелёное (первый прогон `scripts/check.sh` на сервере, 2026-11-09):

- A: 5 контейнеров up; версия front end и движка 0.20.0 = пин в `compose.yaml`;
  RAM-only после апгрейда подтверждён (`HALOGEN_FORK=0` в env контейнера,
  `HALOGEN_CACHE_DIR` нет, тома `/cache` нет, `./cache` на хосте не создаётся);
  в последних 300 строках лога ошибок ROCm/HIP/OOM нет; двойной стек
  `[::]` + `0.0.0.0:8731`.
- A1: **фикс 0.19.1 подтверждён живьём** — битая tool-схема даёт `400`, и
  обычный запрос сразу после неё проходит (`200`), значит генерационный слот
  не удержан.
- B: `8731` слушает только `192.168.101.249:8731`; наружу не светятся
  8080/3128/9000; `internal`, `egress` и `public` — internal, в `wan` только
  `halogen-egress-proxy`; у web-ui нет прямого пути наружу, у halogen — маршрута
  по умолчанию; forward-auth: `401` без ключа и с bogus, `200` с валидным,
  query-строки (`?` и `?x=1`) не режутся, голый `/v1` идёт в API; `/healthz`
  с LAN-пути `200`.
- C: SSE идёт потоком, `/v1/messages` по `x-api-key` (путь Claude Code) `200`,
  лог web-ui чистый, `OFFLINE_MODE` подтверждён, эмбеддинг-модель грузится
  локально.
- E (локально): `/healthz` и `/v1/models` с публичным `Host` → `403`, тот же
  запрос без заголовка → `200`.

  Первый прогон дал `PASS 37 · FAIL 2 · SKIP 4`, и **оба FAIL'а оказались
  дефектами самого скрипта**, а не сервера: различение halogen/web-ui по
  заголовку `Server:` (оба приложения uvicorn → заголовок одинаковый) и оценка
  отказа squid по коду возврата `requests` (403 исключением не является).
  **Повторный прогон исправленным скриптом — `PASS 39 · FAIL 0 · SKIP 4`**, в том
  числе `squid отклонил GET example.org (403)` и `squid отклонил и CONNECT
  (TLS-туннель на 443)`.

Не проверялось:

- C: цикл `401→200` на агентском ключе после `key-rotate` — проверка ручная,
  скрипт её не делает;
- C: цикл whitelist (`make whitelist-add DOMAIN=php.net` → 200 html / картинка
  отклонена → `make whitelist-rm`); скрипт при пустом whitelist проверяет
  только отказ;
- A1: `warm start` и `listening on [::]` — скрипт читает их из **начала** лога
  контейнера (исправлено 2026-11-09: раньше искал в последних 300 строках и на
  загруженном сервере не находил — строки есть в полном логе, в хвосте их уже
  нет). В следующем прогоне обе должны дать PASS; если нет — смотреть, не
  настроена ли ротация логов у podman. Крах при конкурентных strict tool calls —
  только наблюдение в бою;
- D: ни один эксперимент по ужесточению ещё не прогонялся;
- E: вся фаза 2 — каркас написан без podman/сети; проверен только локальный
  `/healthz`-прогон (см. зелёное выше), остальное упирается в закрытые WAN-порты.

## A. Запуск (фаза 1)

- [ ] Подготовлено: podman ≥ 5.7, podman-compose, модели в `HALOGEN_MODELS_DIR`,
      в `.env` заданы `LAN_IP` (адрес LAN-интерфейса, не 127.0.0.1),
      `HALOGEN_MODELS_DIR`, `SECRETS_DIR`. (`CACHE_DIR` больше не нужен —
      дисковый prompt-кэш выключен 2026-10-28.)
- [ ] `make init` — созданы `secrets/keys.acl` (0600) и `.env` из примеров.
- [ ] 4 ключа: `make key-add NAME=webui` (значение → `WEBUI_SERVICE_KEY` в
      `.env`) и три агентских. `WEBUI_SECRET_KEY=$(openssl rand -hex 32)` в
      `.env`.
      Внимание: `key-add` не идемпотентен — для перевыпуска существующего имени
      использовать `make key-rotate NAME=...`. Перевыпуск `webui` дополнительно
      требует вписать новое значение в `.env` и `make up`: иначе web-ui шлёт
      старый ключ и получает 401 на все запросы к LLM.
- [ ] `make up` → `make ps`: 5 контейнеров up; у `halogen-auth-provider`
      статус healthy (спустя ~30 с).
- [ ] `podman logs halogen-flash-server` — модель загрузилась, ошибок ROCm нет,
      API-порт слушает 8731. Версию читать не из лога, а из `/healthz` (он
      отдаёт версию и front end, и движка) — с 0.19.0 сервер поднимается с
      `--host ::`, поэтому прежняя строка `listening on 0.0.0.0:8731` в логе
      могла измениться; зафиксировать фактическую.
- [ ] Prompt-кэш только в RAM (изменение 2026-10-28):
      `podman inspect halogen-flash-server --format '{{json .Config.Env}}' | tr ',' '\n' | grep -iE 'FORK|CACHE'`
      → виден `HALOGEN_FORK=0`, `HALOGEN_CACHE_DIR` отсутствует; тома `/cache`
      нет в `podman inspect halogen-flash-server --format '{{json .Mounts}}'`.
      Прогнать ходов пять Claude Code и убедиться, что `./cache` на хосте не
      создаётся (`du -sh cache 2>/dev/null`). Побочный эффект: после рестарта
      контейнера все разговоры холодные — первый ход заметно дольше. По замерам
      на реальных сессиях Claude Code (123–128k токенов, prefill ≈800–1100
      tok/s) это **2–2.5 минуты**: оценка «40 с» была про контекст в 32k, а не
      про то, чем мы реально пользуемся.
- [ ] Разовая очистка старых 42 GiB (только при первом переходе на RAM-only):
      `podman stop halogen-flash-server` — ждать до 60 с, при остановке
      сливается последний ход; затем `rm -rf cache/*` и `make up`. Сверить
      `df -h /`: до очистки было 94% занято, 33 GiB свободно.

## A1. Обновление образа 0.18.15 → 0.20.0

Пин в `compose.yaml` поднят 2026-11-08; между ними пять релизов (0.18.16…0.18.23,
0.19.0, 0.19.1, 0.20.0). Агент образ не запускал — прогон за человеком.

**Подтверждено 2026-11-08 по логу старта** (человек, `podman logs halogen-flash-server`):

- `serve_api: version 0.20.0, engine version 0.20.0` — образ обновился, front end
  и движок одной версии;
- `serve_api: engine at 127.0.0.1:8730, listening on [::] and 0.0.0.0:8731` и
  `Uvicorn running on http://[::]:8731` — двойной стек подтверждён (двойная
  строка: `[::]` и `0.0.0.0`), движок сидит на loopback `127.0.0.1:8730` и наружу
  из контейнера не торчит, слушает только front end на 8731. Прежняя строка
  `listening on 0.0.0.0:8731` — это она и есть;
- `serve_api: warm start: one 15-token request, 10 tokens, 0.29 s, before
  listening` — warm-up 0.18.23 работает (0.29 с ≈ обещанные ~0.3 с), и это же
  значит, что генерация на ROCm 10.1 жива: до `listening` прошёл реальный запрос;
- наших env видно в логе: `HALOGEN_MAX_TOKENS_DEFAULT=16384`,
  `HALOGEN_REASONING_EFFORT=xhigh`;
- предупреждения `@app.on_event("startup")` в логе больше нет (снято в 0.19.1) —
  лог старта чище, чем на 0.18.15.

**Осталось проверить:**

- [ ] Скорость не просела — сравнить t/s в логе `serve_api` с прежними 67–73 t/s;
      апстрим обещает −9…15% энергии при генерации при той же скорости. Ответы
      могут отличаться от 0.18.15 в последних битах (смена компилятора и
      GEMM-библиотеки) — это заявлено, регрессией не считать.
- [ ] RAM-only пережил апгрейд: `HALOGEN_FORK=0` в env, тома `/cache` нет,
      `./cache` на хосте не создаётся (тот же прогон, что в §A). С 0.18.16
      auto-keep выключен и самим апстримом (#207, #208), так что наш `FORK=0`
      теперь вторая страховка, а не единственная.
- [ ] Кэш промптов на месте при Claude Code с tool-search (0.18.18 чинил его
      сброс на загружаемых MCP-инструментах): в логе `serve_api` доля кэша
      держится на прежних 98–99%.
- [ ] Регрессия 0.19.1 — битая tool-схема больше не съедает генерационный слот:
      `curl -s -w '\n%{http_code}\n' http://LAN_IP:8731/v1/chat/completions -H "Authorization: Bearer <ключ>" -H 'content-type: application/json' -d '{"model":"<имя из /v1/models>","messages":[{"role":"user","content":"привет"}],"tools":[{"type":"function","function":{"name":"t","parameters":"не объект"}}]}'`
      → **400** с именем tool в тексте (до 0.19.1 — 500 и потерянный слот).
      Сразу следом обычный запрос → 200: сервер не «затыкается».
- [ ] Регрессия 0.20.0 — крах движка при конкурентных strict tool calls
      (чтение освобождённой памяти → `GPU memory fault`): отдельного смоук-теста
      нет, наблюдать в логах при параллельной работе агентов.
- [ ] `ss -ltnp` — слушатель по-прежнему ровно один (`LAN_IP:8731`). С 0.19.0
      halogen внутри контейнера слушает и IPv6 (`--host ::`), но наружу не
      публикуется — ничего не должно добавиться.
- [ ] Опционально (дорого): `/v1/messages` с промптом длиннее контекста отвечает
      штатной строкой Anthropic `prompt is too long: N tokens > M maximum`
      (0.18.19) — её Claude Code умеет compact + retry.

**Что смотреть в логе в бою** (замеры 2026-11-09; по скорости и кэшу отклонений нет):

- `pool N/524288 NN%` — за сеанс из 174 ответов пик **100%**, 58 ответов
  держались на 95–100% (первый сеанс дня — 98%). В связке со строками
  `kv pool: no room … forgot` это значит, что вытесняются записи prompt-кэша:
  **21 вытеснение за сеанс** против 3 в первом, вплоть до целых записей по 68k и
  122k токенов. Порог из прежней редакции («много `forgot` + пул выше 95%») —
  пройден, это про RAM (`HALOGEN_KV_POOL_POSITIONS`, `HALOGEN_CACHE_ENTRIES`,
  `HALOGEN_CACHE_BRANCHES`), не про диск.
- `kv pool: the region at N … cannot grow and nothing holds a move; the turn runs
  in the N positions it has left (max_tokens 32000 -> N)` — **генерации не хватило
  места, движок молча режет `max_tokens`**. 16 turn'ов за сеанс, худший
  32000 → 9759: Claude Code просит 32k на ответ, получает меньше. Арифметика:
  самый длинный prompt за сеанс 226 297 токенов при `HALOGEN_CTX=262144`, то есть
  один такой разговор с полным ответом ≈ половина пула, и два таких одновременно
  упираются всегда. Что именно растить — вопрос человеку (CLAUDE.md §7).
- `halogen: WARNING … GiB of host RAM is in use before this server starts` —
  предупреждение про то, что n-gram-таблица (47.7 GiB) читается через file
  cache. При 15.6 GiB чужих процессов оно оказалось пессимистичным (prefill
  вышел ≈2100 t/s), но если чужих процессов станет больше — смотреть сюда.
  Рядом в логе старта: `NOTE … contiguous-allocator pool the GPU cannot use`
  (12.3 GiB) и `MemAvailable now 106.6 GiB` — от них считается бюджет.
- `a vision sidecar is present but NOT loaded` — изображения не принимаются,
  `HALOGEN_VISION_TOWER` не задан (решение не принято, CLAUDE.md §7).
- `end of turn kept as text: N in the think block` — счётчик фикса 0.18.23;
  ненулевой — штатный исход, а не ошибка.
- С включённым prompt-кэшем тёплый ответ **не побитово равен** холодному (строка
  `a warm answer is NOT bitwise the cold one` в логе старта) — побитовое
  сравнение ответов между холодным и тёплым прогоном не считается регрессией.

## B. Изоляция (главная часть)

- [ ] Портов на хосте ровно один (фаза 1):
      `ss -ltnp | grep -E ':(8731|443|3128|8080|9000)\b'` — виден только
      `LAN_IP:8731`. В фазе 2 добавляется `PUBLIC_BIND_IP:443` (waf-firewall,
      при пустом `PUBLIC_BIND_IP` — `0.0.0.0`) — и только. `8080`/`3128`/`9000`
      наружу не светятся.
      Страховка от молчаливого `0.0.0.0` — `GUARD_LAN_IP` в `Makefile`:
      `make up`/`public-up` проверяют непустоту `LAN_IP` до запуска compose и
      различают «пусто в `.env`» и «передано пустым через окружение». Проверить
      обе ветки, контейнеры при этом не пересоздаются:
      `LAN_IP= make up` — ветка окружения (make экспортирует команднострочные
      переменные в рецепты, а пустое значение окружения перебивает `.env`) —
      и временно обнулённая строка `LAN_IP=` в `.env` — ветка dotenv.
      Третья страховка, на случай запуска в обход make: `${LAN_IP:?…}` прямо в
      `compose.yaml`; она падает трейсбеком podman-compose (`RuntimeError:
      LAN_IP не задан …`) — некрасиво, но громко.
      Регрессия правки 2026-10-28: если в строке публикации потеряется суффикс
      `:8731:8080`, `make up` падает на `parsing container port: invalid port
      number: … parsing "192.168.101.249"` и reverse-proxy не создаётся
      (остальные 4 контейнера поднимаются) — признак именно этой поломки.
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
      Различать их нужно **телом ответа**, а не заголовком `Server:`: оба
      приложения — FastAPI/uvicorn, и у обоих `Server: uvicorn` (web-ui
      запускается через `uvicorn.run`, `open_webui/__init__.py:86`). У halogen
      в теле версия и служебные поля (`halogen-flash-server/docs/api.md:69`),
      у web-ui — строго `{"status":true}` (`open_webui/main.py:3077`):
      `curl -s http://LAN_IP:8731/health` → `{"status":true}`.
- [ ] squid: пустой whitelist → **отказ 403**. Оценивать надо код ответа, а не
      то, упало ли приложение: `requests.get()` не бросает исключение на 403 —
      страница отказа squid это обычный ответ с кодом 403.
      `podman exec halogen-web-ui python -c "import requests;print(requests.get('http://example.org',timeout=10).status_code)"` → **403**;
      тот же запрос по HTTPS (`https://example.org`) должен падать с
      `ProxyError`: для туннелей в squid отдельное правило
      `allow CONNECT allowed_sites` (`config/squid/squid.conf:29`), и внутри
      туннеля Content-Type уже не фильтруется. Что squid режет видно и по логу
      web-ui: до `OFFLINE_MODE` там был `httpx.ProxyError: 403 Forbidden` на
      попытку тянуть HuggingFace.
- [ ] SELinux на этом хосте **нет** (подтверждено 2026-10-28: `dpkg -l |
      grep selinux` даёт только `libselinux1` — рантайм-библиотека, приходит
      как зависимость; Ubuntu по умолчанию на AppArmor). Проверено напрямую:
      `[ -e /sys/fs/selinux ] && echo вкл || echo выключен` → «SELinux выключен».
      Пункт про `ausearch -m avc` из чек-листа убран как неприменимый; флаги
      `,z`/`:z` в монтированиях оставлены намеренно — на хосте без SELinux это
      no-op, но они понадобятся при переносе на SELinux-хост.

## C. Функции

- [ ] SSE-стриминг сквозь reverse-proxy (чанки идут постепенно, не пачкой в конце):
      `curl -N http://LAN_IP:8731/v1/chat/completions -H "Authorization: Bearer <ключ>" -H 'content-type: application/json' -d '{"model":"<имя из /v1/models>","messages":[{"role":"user","content":"скажи 1..5"}],"stream":true}'`
- [ ] Open WebUI: вход создаётся только админом (ENABLE_SIGNUP=false),
      чат через сервисный ключ отвечает.
- [ ] web-ui не пытается качать модели (`OFFLINE_MODE=true`):
      `podman logs --since 5m halogen-web-ui 2>&1 | grep -iE "proxyerror|Error loading|403"`
      — пусто, и в логе видно `Offline mode enabled, skipping installation of
      requirements`. Строка `Loading SentenceTransformer model from
      /app/backend/data/cache/embedding/models/...` — **норма, а не ошибка**:
      модель уже лежит в томе `webui_data` и грузится локально (проверено
      2026-10-28). До `OFFLINE_MODE` здесь был `httpx.ProxyError: 403 Forbidden` —
      штатная работа egress, но шум и мёртвый RAG.
- [ ] Перевыпуск ключа: `make key-rotate NAME=agent-lap1` → старый ключ → 401,
      новый из вывода → 200 (auth-provider перечитывает `keys.acl` по mtime,
      рестарт не нужен). Сама команда проверена 2026-10-28 на `webui`; цикл
      401→200 на агентском ключе — **ещё не проверялось**. Напоминание: после
      перевыпуска `webui` править `.env` и `make up` (`admin-keys.md`).
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
- [ ] `/healthz` наружу закрыт (решение от 2026-10-28; реализовано в
      `config/caddy/Caddyfile` — матчер `@public_halogen` добавляет `/healthz`
      к публичному `Host`):
      `curl -s -o /dev/null -w '%{http_code}\n' https://ai.dda2543.ru/healthz` →
      **403**, а с LAN-пути по-прежнему 200
      (`curl -s http://LAN_IP:8731/healthz`).
      Часть на LAN-порту **проверена 2026-10-28** (см. §0): с `-H 'Host:
      ai.dda2543.ru'` → 403, без заголовка → 200. Осталось повторить сквозь WAF
      снаружи, когда откроются WAN-порты.
- [ ] `PUBLIC_BIND_IP` из `.env` (если задан) действительно в bind:
      `ss -ltnp | grep ':443\b'` — адрес из `.env`, а не `0.0.0.0`; и с устройства
      LAN `curl -k -s -o /dev/null -w '%{http_code}\n' https://<адрес-хоста>/` →
      соединение отклонено (публичный вход обходным путём из LAN недоступен).
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

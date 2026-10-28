# Архитектура halogen-stack

Каноническое описание архитектуры. Зафиксировано 2026-10-25 по итогам
согласования (источия решений: `CLAUDE.md` §1.2). Изменения архитектуры —
только через правку этого документа с одобрения человека.

## 1. Схема

```
                              интернет
                                 │ 443/tcp, TLS ai.dda2543.ru (фаза 2)
                          ┌──────▼───────┐
                          │ waf-firewall │  Caddy + Coraza (CRS)
                          └──────┬───────┘  сеть: public
 LAN (2 ноутбука)                │
   агенты ─WireGuard─▶ ┌────────▼────────┐
   (туннель, §3.1)     │  reverse-proxy  │  Caddy (forward_auth)
                        └───┬──────────┬──┘  сети: public + internal
              forward-auth  │          │
                 ┌──────────┘          │
                 ▼                     ▼
        ┌─────────────────┐   ┌──────────────────────┐
        │ internal-auth-  │   │ halogen-flash-server │  GPU: /dev/kfd,/dev/dri
        │ provider        │   └──────────────────────┘
        └─────────────────┘   ┌──────────┐
         ключи: файлы         │  web-ui  │─HTTP_PROXY─▶ ┌──────────────┐──▶ интернет
         хоста (make)         └──────────┘              │ egress-proxy │  (squid:
                              сети: internal + egress  └──────────────┘   whitelist+GET)
```

## 2. Сервисы

| Сервис | Образ | Сети | Порты на хосте |
|---|---|---|---|
| halogen-flash-server | `ghcr.io/peonist-ai/halogen-flash-server:0.18.15` | internal | — |
| reverse-proxy | Caddy 2 | internal, public | `LAN_IP:8731` |
| internal-auth-provider | своя сборка (node) | internal | — |
| web-ui | Open WebUI | internal, egress | — |
| egress-proxy | squid | egress | — |
| waf-firewall | Caddy 2 + Coraza (CRS), своя сборка `waf/` | public | `PUBLIC_BIND_IP:443` → `8443` в контейнере (пусто = `0.0.0.0`; фаза 2) |

## 3. Сети podman

| Сеть | internal (без шлюза) | Участники |
|---|---|---|
| `internal` | да | halogen-flash-server, reverse-proxy, internal-auth-provider, web-ui |
| `egress` | да | web-ui, egress-proxy |
| `wan` | нет — единственный шлюз наружу | egress-proxy |
| `public` | да | waf-firewall, reverse-proxy (фаза 2) |

Ровно два проброса на хост: `LAN_IP:8731` (reverse-proxy, агенты) и
`PUBLIC_BIND_IP:443` (waf-firewall, фаза 2; по умолчанию `0.0.0.0`, после VLAN
сужается до адреса WAN-интерфейса). `LAN_IP` обязателен: пустое значение валит
`make up` (`GUARD_LAN_IP` в `Makefile`, плюс `${LAN_IP:?…}` в compose) вместо
молчаливой публикации `8731` на `0.0.0.0`.
`egress-proxy` — единственный
контейнер, состоящий в `wan`, то есть единственный с маршрутом в интернет;
у web-ui прямого пути наружу нет физически (обе его сети — internal), весь
исходящий трафик идёт через squid по `HTTP_PROXY`.

### 3.1 Внешняя сегментация (решение 2026-10-26)

Хост стека отделён от основной LAN и не имеет в неё маршрута; путь агентов
шифруется. Два независимых механизма, они закрывают разные дыры:

- **VLAN на роутере (MikroTik)** — containment: сервер в `10.20.0.0/24`, доступ
  «сервер → LAN» запрещён, из интернета проброшены только `443` (WebUI) и `80`
  (ACME-выпуск). Не шифрует ничего.
- **WireGuard на сервере** — путь агентов: `8731` биндится на туннельный адрес
  (`LAN_IP=10.80.0.1`), в LAN слушателя нет вовсе; персональные ключи едут
  внутри туннеля, а не открытым HTTP. Не изолирует скомпрометированный хост.

Порт `8731` наружу не публикуется. Два слоя учётных данных (ключ пира WG +
персональный ключ из `keys.acl`) — осознанно: отзыв доступа требует обоих шагов.
Конкретика: `docs/admin-router-mikrotik.md`, `docs/admin-server-ubuntu.md`,
`docs/admin-client-macos.md`.

## 4. Пути запросов

1. **Агент:** агент → WireGuard-туннель → `http://10.80.0.1:8731/v1|v1/messages`
   с `Authorization: Bearer <персональный ключ>` (HTTP внутри туннеля WG,
   §3.1) → reverse-proxy делает
   forward-auth запрос к internal-auth-provider (тот сверяет ключ с файлами
   хоста) → при 200 reverse-proxy → halogen-flash-server. В MVP halogen работает
   без собственного ключа (roadmap: включить `HALOGEN_API_KEY`).
2. **Внешний пользователь → WebUI (фаза 2):** браузер →
   `https://ai.dda2543.ru` → waf-firewall (TLS-терминация, CRS) →
   reverse-proxy → web-ui. Аутентификация — учётные записи Open WebUI.
3. **WebUI → LLM:** web-ui → reverse-proxy с сервисным ключом (1 из 4) →
   forward-auth → halogen-flash-server.
4. **WebUI → интернет:** web-ui → `HTTP_PROXY=http://egress-proxy:3128` →
   squid: только GET, домены из whitelist (изначально пуст), allowlist
   Content-Type (text/html, text/plain). Медиа отсекается по Content-Type —
   это эвристика, не гарантия.
5. **WebUI и загрузка моделей:** у web-ui нет и не может быть пути скачать
   эмбеддинги (бинарники режет и whitelist, и Content-Type), поэтому он запущен
   с `OFFLINE_MODE: "true"` (`compose.yaml`) — `HF_HUB_OFFLINE=1`, без
   auto-update моделей и без проверки версий. При этом RAG-встраивания
   **работают**: `all-MiniLM-L6-v2` уже лежит в томе `webui_data` и грузится
   локально. Основание — вывод из логов старта 2026-10-28 (`Loading
   SentenceTransformer model from /app/backend/data/cache/embedding/models/…`,
   ни `ProxyError`, ни 403); сквозного RAG-запроса отдельно не проверяли.
   Незадокументированная зависимость: при пересоздании тома модель не
   восстановить — egress её не пропустит (подробности: `CLAUDE.md` §1.2).

## 5. Модель доверия

- **Хост:** поверхность = 2 порта (см. §3) + GPU-проброс (принятое
  ограничение). Контейнеры: `read_only`, `cap_drop: ALL`, `no-new-privileges`,
  tmpfs для записи; `ipc: host` под вопросом (тесты, §7).
- **LLM API:** недоступен напрямую и из интернета; единственный путь —
  reverse-proxy после forward-auth. auth-provider сам не имеет портов на
  хосте — его спрашивает только reverse-proxy.
- **Секреты:** персональные ключи (4) — файлы на хосте (`secrets/`, в
  .gitignore), примонтированы только в auth-provider; перечитывание по
  сигналу/таймеру. Администрирование ключей/ACL/whitelist — только `make`
  на хосте.
- **Наружу:** никто, кроме web-ui (через egress-proxy, whitelist пуст).

## 6. Фазы

- **Фаза 1 (MVP):** 5 сервисов без waf-firewall; агенты по HTTP в LAN;
  web-ui доступен из LAN через reverse-proxy; whitelist пуст (= наружу
  нельзя ни на какой домен).
- **Фаза 2 (каркас создан 2026-10-26, на сервере ещё не проверялся):**
  waf-firewall + DNS `ai.dda2543.ru` + certbot на хосте (make) → публичный вход
  WebUI на 443. Детали: `compose.public.yaml`, `waf/Dockerfile`,
  `config/caddy/Caddyfile.waf`, `docs/admin-public.md`. Два решения каркаса:
  сертификат выпускается `certbot --standalone` (waf слушает только 443, поэтому
  :80 свободен и для выпуска, и для продления; HTTP→HTTPS редиректа нет), и
  reverse-proxy отклоняет `403` запросы к `/v1/*` с публичным `Host` — LLM API
  в интернет не светится даже через WAF.

## 7. Что проверить тестами на сервере

- ROCm без `ipc: host` (приватный IPC + `shm_size`); заодно — нужна ли `NET_RAW`.
- `read_only: true` + tmpfs для halogen-flash-server (`/tmp`, `/run`). Том
  `/cache` убран 2026-10-28 вместе с дисковым prompt-кэшем (§10 CLAUDE.md) —
  заодно проверить, что контейнер стартует без него.
- SELinux на сервере нет (AppArmor) — проверено 2026-10-28, см. CLAUDE.md §5.
  Отсюда остаётся только проверить работу Coraza (запись audit-логов).
- SSE-стриминг LLM сквозь reverse-proxy (без буферизации, без WAF на этом пути).
- Open WebUI: `HTTP_PROXY`/`NO_PROXY` (внутренние адреса — мимо squid).
- bind reverse-proxy `8731` на LAN-интерфейс (не на 0.0.0.0).

## 8. Roadmap (детали: CLAUDE.md §9)

WireGuard-туннель для пути агентов + VLAN-containment (решение принято,
реализация — вне репозитория, см. §3.1) → `HALOGEN_API_KEY` на halogen →
мониторинг (metrics-waf, node-exporter, blackbox-exporter, prometheus,
grafana) → опционально OIDC для Open WebUI.

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
   агенты ──8731/tcp──▶ ┌────────▼────────┐
   (HTTP, MVP)          │  reverse-proxy  │  Caddy (forward_auth)
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
| waf-firewall | Caddy 2 + Coraza (CRS) | public | `0.0.0.0:443` (фаза 2) |

## 3. Сети podman

| Сеть | internal (без шлюза) | Участники |
|---|---|---|
| `internal` | да | halogen-flash-server, reverse-proxy, internal-auth-provider, web-ui |
| `egress` | да | web-ui, egress-proxy |
| `wan` | нет — единственный шлюз наружу | egress-proxy |
| `public` | да | waf-firewall, reverse-proxy (фаза 2) |

Ровно два проброса на хост: `LAN_IP:8731` (reverse-proxy, агенты) и
`0.0.0.0:443` (waf-firewall, фаза 2). `egress-proxy` — единственный
контейнер, состоящий в `wan`, то есть единственный с маршрутом в интернет;
у web-ui прямого пути наружу нет физически (обе его сети — internal), весь
исходящий трафик идёт через squid по `HTTP_PROXY`.

## 4. Пути запросов

1. **Агент (LAN):** агент → `http://LAN_IP:8731/v1|v1/messages` с
   `Authorization: Bearer <персональный ключ>` → reverse-proxy делает
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
- **Фаза 2:** waf-firewall + DNS `ai.dda2543.ru` + certbot на хосте (make)
  → публичный вход WebUI на 443.

## 7. Что проверить тестами на сервере

- ROCm без `ipc: host` (приватный IPC + `shm_size`); заодно — нужна ли `NET_RAW`.
- `read_only: true` + tmpfs для halogen-flash-server (кэш `/cache`, `/tmp`, `/run`).
- SELinux: монтирования с `:z/:Z`, работа Coraza (запись audit-логов).
- SSE-стриминг LLM сквозь reverse-proxy (без буферизации, без WAF на этом пути).
- Open WebUI: `HTTP_PROXY`/`NO_PROXY` (внутренние адреса — мимо squid).
- bind reverse-proxy `8731` на LAN-интерфейс (не на 0.0.0.0).

## 8. Roadmap (детали: CLAUDE.md §9)

self-signed TLS для LAN-пути агентов → `HALOGEN_API_KEY` на halogen →
мониторинг (metrics-waf, node-exporter, blackbox-exporter, prometheus,
grafana) → опционально OIDC для Open WebUI.

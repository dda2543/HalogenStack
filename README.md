# HalogenStack

Изолированный стек для запуска LLM-сервера `halogen-flash-server` и WebUI
(Open WebUI) на podman-compose. Управление инфраструктурой — через `make`
на хостовой машине.

## Цели

1. Безопасный запуск `halogen-flash-server` (LLM-инференс, AMD Strix Halo).
2. Обратный прокси перед LLM — изоляция от прямых запросов.
3. Персональные ключи пользователей (4: 3 агента в LAN + 1 сервисный для WebUI).
4. WebUI (Open WebUI) с собственными учётными записями для внешних пользователей.
5. Изоляция приложений от хостовой машины (кроме принятого GPU-проброса).
6. Изоляция от интернета: наружу не может никто, кроме WebUI — только GET на
   домены из whitelist (изначально пуст).

## Сервисы

| Сервис | Что это |
|---|---|
| halogen-flash-server | LLM-инференс; без портов на хосте, доступен только reverse-proxy |
| reverse-proxy | Caddy: единственная точка входа; forward-auth к auth-provider |
| internal-auth-provider | своя минимальная реализация; владеет всеми ключами; ключи — файлы на хосте |
| web-ui | Open WebUI; наружу только через egress-proxy |
| waf-firewall | Caddy + Coraza (CRS); TLS-терминация `ai.dda2543.ru`; только публичный путь WebUI |
| egress-proxy | squid: единственный маршрут наружу; whitelist + GET |

## Архитектура

Каноническое описание: [docs/architecture.md](docs/architecture.md).

```
                              интернет
                                 │ 443/tcp, TLS ai.dda2543.ru (фаза 2)
                          ┌──────▼───────┐
                          │ waf-firewall │  Caddy + Coraza (CRS)
                          └──────┬───────┘
 LAN (2 ноутбука)                │
   агенты ──8731/tcp──▶ ┌────────▼────────┐
   (HTTP, MVP)          │  reverse-proxy  │──forward-auth──▶ [internal-auth-provider]
                        └───┬──────────┬──┘                        (ключи: файлы хоста)
                            ▼          ▼
                 [halogen-flash-     [web-ui] ─HTTP_PROXY─▶ [egress-proxy/squid] ─▶ интернет
                  server] (GPU)                            (whitelist + только GET)
```

Сети: `internal` (без шлюза: halogen, proxy, auth-provider, web-ui),
`egress` (web-ui ↔ squid ↔ мир), `public` (waf ↔ proxy, фаза 2).
На хост проброшены ровно два порта: `LAN_IP:8731` и (фаза 2)
`PUBLIC_BIND_IP:443` (пусто = `0.0.0.0`).
`egress-proxy` — единственный контейнер с маршрутом в интернет.

## Фазы

- **Фаза 1 (MVP):** внутренний контур — halogen, reverse-proxy, auth-provider,
  web-ui, egress-proxy (whitelist пуст). LAN-путь агентов по HTTP.
- **Фаза 2:** публичный вход — waf-firewall, TLS для `ai.dda2543.ru`.

## Roadmap (после MVP)

- DNS-запись `ai.dda2543.ru` → IP сервера + certbot на хосте (предпосылка
  публичного входа).
- Self-signed TLS на LAN-пути агентов (сейчас — HTTP).
- Включение `HALOGEN_API_KEY` на halogen-flash-server после тестирования.
- Мониторинг: metrics-waf, node-exporter, blackbox-exporter, prometheus,
  grafana (возможен отдельный хост).

## Документация

Рабочий документ проекта (решения, противоречия, соглашения) — [CLAUDE.md](CLAUDE.md).

- [docs/architecture.md](docs/architecture.md) — канон архитектуры.
- [docs/admin-keys.md](docs/admin-keys.md) — ключи пользователей (`make key-*`).
- [docs/admin-whitelist.md](docs/admin-whitelist.md) — whitelist WebUI (`make whitelist-*`).
- [docs/admin-public.md](docs/admin-public.md) — публичный вход WebUI (фаза 2: waf-firewall, TLS).
- [docs/admin-router-mikrotik.md](docs/admin-router-mikrotik.md) — VLAN для сервера и проброс портов на MikroTik.
- [docs/admin-server-ubuntu.md](docs/admin-server-ubuntu.md) — сервер LLM: адресация VLAN и WireGuard для агентов.
- [docs/admin-client-macos.md](docs/admin-client-macos.md) — ноутбук агента: WireGuard + доступ к API.
- [docs/server-test-checklist.md](docs/server-test-checklist.md) — прогон на сервере перед тем, как считать фазу 1 зелёной.

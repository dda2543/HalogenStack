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
Административные руководства (ключи, ACL, whitelist) — `docs/` (в процессе).

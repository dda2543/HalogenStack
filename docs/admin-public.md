# Публичный вход WebUI (фаза 2) — руководство администратора

Канон архитектуры: `docs/architecture.md`. Здесь — только порядок действий на
сервере и разбор типичных отказов.

Путь, который мы включаем: браузер → `https://ai.dda2543.ru` → `waf-firewall`
(TLS + Coraza/CRS) → `reverse-proxy` → `web-ui`. ЛLM API с публичной стороны
**не** доступен: reverse-proxy отбивает `/v1/*` с публичным `Host` (403), а
LAN-путь агентов через WAF не проходит и остаётся как был.

## 1. Предпосылки

1. **DNS.** `ai.dda2543.ru` → IP сервера. Без этого certbot не выпустит
   сертификат, а проверка `curl -resolve` будет врать.
2. **certbot на хосте** (`dnf install certbot` / `apt install certbot`).
3. **Порт 80 на хосте свободен И доступен из интернета.** Certbot работает в
   режиме `--standalone` и сам занимает :80 на время выпуска/продления; waf
   слушает только 443, поэтому конфликтов на хосте нет. Но HTTP-01 требует,
   чтобы :80 был проброшен с роутера — при закрытых входящих портах WAN
   (состояние на 2026-10-28) проверка не пройдёт, и `make cert` упадёт.
   Альтернатива — DNS-01 (нужен доступ к зоне у регистратора), тогда :80 не
   нужен вовсе.
4. **rootless podman и привилегированный порт хоста.** Публикация `443:8443`
   требует, чтобы не-root мог bind-ить порт <1024:

   ```bash
   sysctl net.ipv4.ip_unprivileged_port_start   # должно быть 0
   # если 1024:
   echo 'net.ipv4.ip_unprivileged_port_start=0' | sudo tee /etc/sysctl.d/99-halogen.conf
   sudo sysctl --system
   ```
5. **`.env`**: `PUBLIC_DOMAIN`, `CERTS_DIR` (см. `.env.example`).
6. **`PUBLIC_BIND_IP`** (в `.env`) — адрес хоста, на котором публикуется 443.
   Пусто = `0.0.0.0`: публичный вход доступен и из LAN. После настройки VLAN
   (§3.1 архитектуры) сюда ставят адрес WAN/VLAN-интерфейса сервера — тогда
   из LAN в 443 напрямую не попасть, а снаружи приходит проброс роутера.
   Проверить фактический bind: `ss -ltnp | grep ':443\b'`.

## 2. Сборка и выпуск

```bash
make waf-build          # Caddy + Coraza + CRS (образ halogen-waf:local)
make cert CERT_EMAIL=admin@example.org   # Let's Encrypt → ./secrets/certs
make public-up          # фаза 1 + waf-firewall
```

`make cert` вызывает certbot с `--deploy-hook`, который копирует
`fullchain.pem`/`privkey.pem` в `CERTS_DIR` и назначает их владельцем
администратора хоста (`scripts/cert-deploy.sh`). Это нужно из-за rootless
podman: uid 0 внутри контейнера = uid администратора снаружи, поэтому файлов
`0600` хватает — без `chown` в контейнере и без флага монтирования `U`.

Проверка после запуска:

```bash
podman exec halogen-waf caddy validate --config /etc/caddy/Caddyfile
curl -v --resolve ai.dda2543.ru:443:127.0.0.1 https://ai.dda2543.ru/healthz
curl -v --resolve ai.dda2543.ru:443:127.0.0.1 https://ai.dda2543.ru/v1/models
#   ожидаем 403 — LLM API снаружи закрыт
```

## 3. Продление сертификата

```bash
make cert-renew     # certbot renew + podman restart halogen-waf
```

Рестарт обязателен: Caddy читает файлы сертификата при загрузке конфига.
Штатный systemd-таймер certbot контейнер не перезапустит, поэтому либо
`make cert-renew` по своему cron/таймеру, либо продление вручную раз в ~60 дней.
**Открытый вопрос:** автоматизация рестарта из deploy-hook (hook работает от root,
контейнер — rootless) — намеренно не решена в каркасе.

## 4. Coraza: от «только смотреть» к блокировке

В `config/caddy/Caddyfile.waf` стоит `SecRuleEngine DetectionOnly`: правила
срабатывают и пишутся в лог, но запрос проходит. Порядок включения блокировки:

```bash
make public-logs | grep -i coraza     # собрать ложные срабатывания на реальном трафике
```

Разобрать срабатывания (обычно это большие JSON-тела и заголовки WebUI), при
необходимости отключить конкретные правила через `SecRuleRemoveById` в блоке
`seclang`, и только затем поменять `DetectionOnly` → `On` и `make public-up`.

Порог тела запроса — 20 МБ (`SecRequestBodyLimit`): больше — отклоняется. Если
в WebUI нужны загрузки крупнее, поднять и здесь, и в ограничениях web-ui.

## 5. Откат

```bash
make public-down   # снимает и фазу 2, и фазу 1
make up            # вернуться к фазе 1 (без waf)
```

Снять только waf, оставив фазу 1: `podman stop halogen-waf`.

## 6. Что в каркасе ещё не проверено

Каркас писался без доступа к podman/интернету, поэтому первый прогон на сервере
обязателен (чек-лист, §E). Известные точки риска:

- **Сборка образа:** версии `CORAZA_CADDY_VERSION` (сейчас `latest`) и
  `CRS_VERSION` (сейчас `v4.4.0`) в `waf/Dockerfile` не проверены — после
  успешной сборки зафиксировать конкретные.
- **Синтаксис `seclang`/`coraza`** в Caddyfile — по документации модуля, не
  проверен `caddy validate`.
- **SELinux**: `Include /etc/coraza/rules/*.conf` читается из образа (метка
  контейнера), но audit-лог Coraza писать некуда при `read_only` — если
  понадобится audit-файл, добавлять tmpfs/том.
- **HTTP→HTTPS редиректа нет**: waf слушает только 443. Если нужен редирект с
  :80, придётся переводить certbot на webroot и решать «курицу и яйцо» первого
  выпуска (сертификата ещё нет, а Caddy с TLS уже не стартует).

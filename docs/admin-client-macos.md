# Клиент-агент (macOS): WireGuard-доступ к LLM API

Часть схемы «агенты — через WireGuard». Канон: `docs/architecture.md` §3.
Серверная часть: `docs/admin-server-ubuntu.md` (там же — как добавить пира),
роутер: `docs/admin-router-mikrotik.md`.

Без поднятого туннеля агент не видит LLM: в LAN порт `8731` не слушается,
адрес `10.80.0.1` живёт только внутри WireGuard.

## 1. Пакеты — на выбор

**GUI-приложение** (App Store, «WireGuard»): туннели поднимаются сами при входе в
систему, удобно для ноутбука, который носят из офиса. Требует подтверждения
system extension в *System Settings → Privacy & Security*; на управляемом MDM
маке подтверждение может быть заблокировано политикой.

**`wireguard-tools`** (CLI):

```bash
brew install wireguard-tools
/opt/homebrew/sbin/wg-quick --help     # на Intel-маке путь /usr/local/sbin
```

Два способа не используют один и тот же интерфейс одновременно — выберите один
для конкретного машины.

## 2. Ключи клиента

```bash
umask 077
wg genkey | tee ~/wg-private.key | wg pubkey > ~/wg-public.key
cat ~/wg-public.key     # этот ключ передать администратору сервера
```

Приватный ключ не покидает ноутбук. Администратор добавляет публичный ключ в
`/etc/wireguard/wg0.conf` сервера и выдаёт персональный ключ API
(`make key-add NAME=agent-lap1`, значение показывается один раз).

Адрес клиенту выделяет администратор: `10.80.0.2` для первого ноутбука,
`10.80.0.3` для второго.

## 3. Конфигурация туннеля

`/opt/homebrew/etc/wireguard/wg0.conf` (для GUI-приложения — импорт этого же
файла через «Add Tunnel from file»; путь каталога на Intel:
`/usr/local/etc/wireguard/`):

```ini
[Interface]
PrivateKey = <содержимое ~/wg-private.key>
Address = 10.80.0.2/24

[Peer]
PublicKey = <публичный ключ сервера>
AllowedIPs = 10.80.0.1/32
Endpoint = 10.20.0.10:51820
PersistentKeepalive = 25
```

`AllowedIPs = 10.80.0.1/32` — сплит-туннель: через WG идёт только LLM-сервер,
остальной трафик (браузер, обновления) идёт как шёл. `PersistentKeepalive`
нужен, если между клиентом и сервером есть NAT (выход из-за роутера провайдера,
мобильный хотспот).

Для доступа **извне** (командировка, гостевой Wi-Fi) — `Endpoint` должен указывать
на адрес, доступный снаружи: публичный адрес роутера или DDNS-имя
(`Endpoint = <ddns>:51820`), и на роутере должен быть проброс UDP 51820
(в `docs/admin-router-mikrotik.md` §4 это правило отключено по умолчанию).

## 4. Подключение и проверка

```bash
sudo /opt/homebrew/sbin/wg-quick up wg0
sudo /opt/homebrew/sbin/wg show                 # latest handshake ≠ 0
curl -s -o /dev/null -w '%{http_code}\n' http://10.80.0.1:8731/healthz    # 200
curl -s -o /dev/null -w '%{http_code}\n' http://10.80.0.1:8731/v1/models  # 401 без ключа
curl -s -H "Authorization: Bearer <персональный ключ>" \
     http://10.80.0.1:8731/v1/models            # 200, список моделей
sudo /opt/homebrew/sbin/wg-quick down wg0       # выключить
```

Handshake нулевой → UDP 51820 не доходит (роутер, неверный `Endpoint`).
Handshake есть, а `curl` не отвечает → смотреть сервер
(`ss -ltnp | grep 8731`, `podman logs halogen-reverse-proxy`).

## 5. После сна/смены сети

macOS роняет туннель при сне и при смене сети. CLI-вариант поднимается вручную
(`wg-quick down wg0 && wg-quick up wg0` — `down` нужен, иначе останется
полусостояние `utun`). GUI-приложение подхватывает такие случаи само и умеет
«активировать при входе в систему» — для ноутбука это причина выбрать его.

## 6. Настройка агента

Ключевое: базовый URL — **без** суффикса `/v1` (источник:
`/docs/halogen-flash-server/docs/claude-code.md:8`), адрес — туннельный:

```bash
export ANTHROPIC_BASE_URL=http://10.80.0.1:8731
export ANTHROPIC_AUTH_TOKEN=<персональный ключ из keys.acl>
```

Значения живут в сессии/оболочке агента; в репозиторий их не класть (`.env` и
`secrets/` в `.gitignore`, но агентские переменные вообще вне репозитория).

## 7. Отзыв и замена доступа

- **Ноутбук потерян / агент уволен:** на сервере убрать `[Peer]` из
  `wg0.conf` → `sudo wg syncconf wg0 <(sudo wg-quick strip wg0)`; на сервере же
  `make key-rm NAME=agent-lap1`. Нужны оба шага: WG без ключа API всё равно не
  даёт доступа к LLM, а ключ без туннеля некуда послать.
- **Плановая замена ключей:** сгенерировать новую пару на клиенте (§2),
  заменить публичный ключ на сервере, перевыпустить API-ключ
  (`make key-rotate NAME=...`).
- **Проверка, что отзыв сработал:** `curl` с этим ноутбуком → 401 (отозван ключ)
  или таймаут (отозван туннель).

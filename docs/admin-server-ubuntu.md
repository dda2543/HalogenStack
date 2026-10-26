# Сервер LLM (Ubuntu): VLAN-адресация и WireGuard для агентов

Часть схемы «агенты — через WireGuard, сервер — в отдельном VLAN». Канон:
`docs/architecture.md` §3. Смежные: `docs/admin-router-mikrotik.md`,
`docs/admin-client-macos.md`, `docs/admin-public.md` (публичный вход).

Итог, к которому мы идём:

- сервер живёт в VLAN `10.20.0.0/24` (адрес `10.20.0.10`), в остальную LAN у него
  нет доступа;
- LLM API (`8731`) слушает **только** WireGuard-адрес `10.80.0.1` — в LAN нет
  открытого порта вообще;
- ключи агентов едут по шифрованному туннелю, а не открытым HTTP;
- в интернет смотрят ровно два порта: `443` (WebUI) и, на время выпуска
  сертификата, `80`.

Два слоя учётных данных — это осознанно: WireGuard (ключ пира) не отменяет
персональные ключи из `secrets/keys.acl`, он только прячет их в туннеле. Отзыв
доступа = удалить пира **и** отозвать ключ (`make key-rm`).

## 1. Пакеты

```bash
sudo apt update && sudo apt install -y wireguard-tools
podman --version && podman-compose --version   # podman ≥ 5.7
```

## 2. Сетевой адрес сервера

Если порт роутера — access для VLAN 20 (вариант по умолчанию), сервер видит
обычный Ethernet и VLAN настраивать не нужно.

`/etc/netplan/60-halogen.yaml`:

```yaml
network:
  version: 2
  ethernets:
    enp1s0:
      addresses: [10.20.0.10/24]
      routes:
        - to: default
          via: 10.20.0.1
      nameservers:
        addresses: [10.20.0.1]
```

```bash
sudo netplan apply
ip -br addr show        # 10.20.0.10/24
ping -c1 10.20.0.1
```

Если вместо этого роутер отдаёт trunk с тегом — нужен субинтерфейс
(`link: enp1s0`, `id: 20` в netplan) вместо адреса на физическом порту.

Проверка containment (должно быть недоступно): `ping -c1 192.168.1.1`.

## 3. WireGuard: генерация ключей

Ключ сервера:

```bash
sudo install -d -m 700 /etc/wireguard
(umask 077; sudo wg genkey | sudo tee /etc/wireguard/server.key >/dev/null)
sudo chmod 600 /etc/wireguard/server.key
sudo wg pubkey < /etc/wireguard/server.key    # → публичный ключ, отдать админу
```

Ключи клиентов генерируются **на клиентах** (см. `docs/admin-client-macos.md`),
сюда попадают только их публичные ключи.

## 4. WireGuard: конфиг сервера

`/etc/wireguard/wg0.conf` (права 0600, приватный ключ можно вписать прямо или
оставить `PrivateKeyCommand`):

```ini
[Interface]
Address = 10.80.0.1/24
ListenPort = 51820
PrivateKey = <содержимое /etc/wireguard/server.key>

# ноутбук 1 (агент)
[Peer]
PublicKey = <публичный ключ клиента 1>
AllowedIPs = 10.80.0.2/32

# ноутбук 2 (агент)
[Peer]
PublicKey = <публичный ключ клиента 2>
AllowedIPs = 10.80.0.3/32
```

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
wg show                      # должен быть wg0; handshake появится после первого пакета от пира
```

`AllowedIPs` на стороне сервера — только /32 по пиру: туннель «до сервера», не
«весь трафик клиента». Маршрутизация через wg0 на сервере не включается
(`ip_forward` не нужен).

Отзыв пира: убрать его секцию `[Peer]` и выполнить

```bash
sudo wg syncconf wg0 <(sudo wg-quick strip wg0)
```

## 5. Привязка стека к туннелю

В `.env` — адрес WireGuard вместо LAN-адреса:

```ini
LAN_IP=10.80.0.1
```

После этого `ports: "${LAN_IP}:8731:8080"` биндит сокет только на `wg0`.
Проверка:

```bash
make up
ss -ltnp | grep 8731        # 10.80.0.1:8731 — и больше ничего
```

**Порядок старта важен:** если podman поднимется раньше `wg0`, bind не удастся
(контейнер будет перезапускаться до появления интерфейса). Вариант для загрузки —
системд-юнит:

`/etc/systemd/system/halogen-stack.service`:

```ini
[Unit]
Description=halogen-stack (podman-compose)
Requires=wg-quick@wg0.service
After=network-online.target wg-quick@wg0.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=<администратор podman>
WorkingDirectory=/home/<администратор>/halogen-stack
ExecStart=/usr/bin/podman-compose -f compose.yaml up -d
ExecStop=/usr/bin/podman-compose -f compose.yaml down

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable halogen-stack
```

Порт хоста `443` из rootless podman требует (уже есть в `docs/admin-public.md`):

```bash
echo 'net.ipv4.ip_unprivileged_port_start=0' | sudo tee /etc/sysctl.d/99-halogen.conf
sudo sysctl --system
```

Если на сервере включён `ufw`, открыть только то, что приходит извне:
`sudo ufw allow 51820/udp`, `sudo ufw allow 443/tcp`, `sudo ufw allow in on wg0 to any port 8731`.

## 6. Проверка

С ноутбука-агента (см. `docs/admin-client-macos.md`):

```bash
sudo wg show wg0                      # latest handshake — свежий
curl -s -o /dev/null -w '%{http_code}\n' http://10.80.0.1:8731/healthz   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://10.80.0.1:8731/v1/models # 401
```

С любого другого устройства той же LAN (не пира WG):

```bash
nc -vz 10.20.0.10 8731   # → refused/timeout — так и должно быть
```

С сервера: `wg show wg0 latest-handshakes` (0 означает «пир не стучался»),
`ip route get 192.168.1.1` — трафик в LAN должен блокироваться на роутере.

Дальше — общий прогон `docs/server-test-checklist.md`.

## 7. Отказоустойчивость и отладка

| Симптом | Куда смотреть |
|---|---|
| `wg show` без handshake | `Endpoint` у клиента, проброс/разрешение UDP 51820 (`docs/admin-router-mikrotik.md` §4–5) |
| Handshake есть, `8731` не отвечает | `ss -ltnp | grep 8731` (не поднялся до `wg0`), `podman logs halogen-reverse-proxy` |
| После ребута агенты не видят API | порядок юнитов: `systemctl status halogen-stack wg-quick@wg0` |
| Пир «пропал» после сна ноутбука | на macOS туннель поднимается заново вручную/приложением — см. `docs/admin-client-macos.md` §5 |
| Нужен новый агент | сгенерировать ключи на клиенте, добавить `[Peer]`, `wg syncconf`, выдать ключ из `make key-add` |

Мониторинг (roadmap): `wg show wg0 latest-handshakes` — дешёвый признак живости
пути агентов, его можно отдавать blackbox-exporter.

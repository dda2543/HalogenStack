# Роутер MikroTik: VLAN для сервера и проброс публичного входа

Часть схемы «агенты — через WireGuard, сервер — в отдельном VLAN». Канон
архитектуры: `docs/architecture.md` §3. Смежные документы:
`docs/admin-server-ubuntu.md` (настройка сервера), `docs/admin-client-macos.md`
(клиенты-агенты).

Имена интерфейсов (`bridge1`, `ether1-WAN`, `ether5`) подставьте свои — ниже они
условные. Проверено на агенте не было: это план для ручного ввода в RouterOS 7.x.

## 1. Что должно получиться

| Поток | Разрешение |
|---|---|
| интернет → `10.20.0.10:443` | да (WebUI) |
| интернет → `10.20.0.10:80` | да, только для ACME (см. §4) |
| интернет → `10.20.0.10:51820/udp` | только если агенты ходят извне (§4) |
| VLAN агентов → `10.20.0.10:51820/udp` | да (это и есть путь агентов) |
| VLAN агентов → `10.20.0.10:22` | только адрес администратора |
| сервер → остальная LAN | **нет** |
| сервер → интернет | да (образы контейнеров, egress squid) |

Порт `8731` (LLM API) наружу не пробрасывается вообще: он слушает только
WireGuard-адрес сервера.

Адреса: LAN — `192.168.1.0/24`, VLAN сервера — `10.20.0.0/24` (сервер
`10.20.0.10`, роутер `10.20.0.1`), WireGuard — `10.80.0.0/24` (сервер
`10.80.0.1`, ноутбуки `10.80.0.2…4`).

## 2. VLAN 20

**Самое опасное место.** `vlan-filtering=yes` на живом бридже без записей VLAN
для существующих портов отрезает от сети всё, включая вас. Порядок: сначала
записи VLAN для **всех** портов, только потом включение фильтрации. Работайте
через консоль/Serial или порт, который точно останется в своём VLAN.

```routeros
# 2.1. Существующая LAN — VLAN 10 (пример: ether2..ether4)
/interface bridge vlan add bridge=bridge1 vlan-id=10 untagged=bridge1,ether2,ether3,ether4

# 2.2. VLAN 20 — порт сервера
/interface bridge vlan add bridge=bridge1 vlan-id=20 untagged=bridge1,ether5
/interface bridge port add bridge=bridge1 interface=ether5 pvid=20 \
    frame-types=admit-only-untagged-and-priority-tagged ingress-filtering=yes

# 2.3. Включить фильтрацию (только после 2.1 и 2.2)
/interface bridge set bridge1 vlan-filtering=yes
```

Порт сервера — access (untagged): на Ubuntu не нужно никакой конфигурации VLAN,
там обычная сеть `10.20.0.0/24`. Если решите гнать серверу trunk — тогда на
стороне Ubuntu нужен VLAN-субинтерфейс, и вся конфигурация в
`docs/admin-server-ubuntu.md` §2 меняется.

## 3. Адресация и DNS

```routeros
/interface vlan add name=vlan20-srv interface=bridge1 vlan-id=20
/ip address add address=10.20.0.1/24 interface=vlan20-srv

# статика для сервера (или DHCP-пул с lease по MAC)
/ip dhcp-server network add address=10.20.0.0/24 gateway=10.20.0.1 dns-server=10.20.0.1

# split DNS: из LAN публичное имя ведёт на внутренний адрес (иначе нужен hairpin-NAT)
/ip dns static add name=ai.dda2543.ru address=10.20.0.10
```

`halogen-server.local` больше не используется: mDNS не ходит между VLAN.
Агенты обращаются к `10.80.0.1` внутри WireGuard-туннеля.

## 4. Проброс из интернета

```routeros
/ip firewall address-list add list=srv-halogen address=10.20.0.10
/ip firewall address-list add list=agents address=192.168.1.20 address=192.168.1.21

# WebUI
/ip firewall nat add chain=dstnat action=dst-nat to-addresses=10.20.0.10 to-ports=443 \
    protocol=tcp in-interface=ether1-WAN dst-port=443 comment="halogen: WebUI"
# ACME: certbot --standalone на сервере занимает :80 на время выпуска/продления.
# В остальное время на :80 никто не слушает → снаружи «connection refused».
/ip firewall nat add chain=dstnat action=dst-nat to-addresses=10.20.0.10 to-ports=80 \
    protocol=tcp in-interface=ether1-WAN dst-port=80 comment="halogen: ACME"
# Опционально: агенты извне. Без этого WireGuard работает только внутри сети.
/ip firewall nat add chain=dstnat action=dst-nat to-addresses=10.20.0.10 to-ports=51820 \
    protocol=udp in-interface=ether1-WAN dst-port=51820 comment="halogen: WireGuard (агенты извне)"
```

Если вместо 80 выберете DNS-01 (выпуск сертификата через API DNS-провайдера),
правило для :80 не нужен — см. `docs/admin-public.md` §6.

## 5. Фильтрация forward

Новые правила должны стоять **выше** финального `accept` в цепочке `forward`
(в дефолтом конфиге RouterOS он последний) — используйте `place-before`.

```routeros
/ip firewall filter add chain=forward action=accept protocol=tcp in-interface=ether1-WAN \
    dst-address-list=srv-halogen dst-port=443,80 comment="публичный вход + ACME"
/ip firewall filter add chain=forward action=accept protocol=tcp in-interface=ether1-WAN \
    protocol=udp dst-address-list=srv-halogen dst-port=51820 comment="WireGuard снаружи" disabled=yes
/ip firewall filter add chain=forward action=accept protocol=tcp src-address-list=agents \
    dst-address-list=srv-halogen dst-port=51820 comment="агенты → WireGuard"
/ip firewall filter add chain=forward action=accept protocol=tcp src-address=192.168.1.10 \
    dst-address-list=srv-halogen dst-port=22 comment="admin ssh"
/ip firewall filter add chain=forward action=drop src-address-list=srv-halogen \
    dst-address=192.168.1.0/24 comment="сервер не ходит в LAN"
```

Обратный трафик (ответы сервера агентам) проходит правилом
`established,related`, который в дефолтном конфиге стоит раньше.

## 6. Проверка

```bash
# с ноутбука-агента (VLAN 10), до поднятого WG:
nc -vz 10.20.0.10 8731      # → refused/timeout: LLM API в LAN не светится
nc -vzu 10.20.0.10 51820    # → UDP «открыт» проверяется иначе: wg show должен показать handshake
# с любого устройства LAN:
nc -vz 10.20.0.10 22        # → refused/timeout (кроме машины администратора)
# снаружи (с мобильного интернета):
curl -sv --resolve ai.dda2543.ru:443:<публичный-IP> https://ai.dda2543.ru/ -o /dev/null
# сервер не видит LAN (на самом сервере):
ip route get 192.168.1.1    # через 10.20.0.1 — и должно быть закрыто файрволом роутера
```

Итоговая проверка «зелёного» состояния — в `docs/server-test-checklist.md` §Б/§Е.

## 7. Типичные отказы

- **Пропала LAN после включения `vlan-filtering`** — не добавлены записи VLAN для
  существующих портов. Подключение по Serial/Winbox с порта вне бриджа,
  `vlan-filtering=no`, затем заново по §2.
- **`make cert` падает** — не проброшен :80 или на :80 что-то уже слушает
  (проверить `ss -ltnp | grep :80` на сервере).
- **`wg show` не показывает handshake** — правило `dst-port=51820` не попало в
  нужную цепочку/порядок, либо `Endpoint` в конфиге клиента указывает не туда.
- **Веб-интерфейс роутера стал недоступен с сервера** — так и задумано (drop
  сервер→LAN). Администрирование роутера — с машины из LAN.

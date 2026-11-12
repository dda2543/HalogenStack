# Дисковый prompt-кэш: выделенный диск

Решение 2026-11-12. Под дисковый слой prompt-кэша `halogen-flash-server`
выделен отдельный диск. Документ — про хостовую часть: разметку, права,
страховки и откат. Переменные в контейнере — `compose.yaml`
(`halogen-flash-server`, `environment`).

## 1. Что это решает и что нет

Решает:

- **Место на `/`.** Дисковый слой пишет ~27 KiB на токен контекста
  (`reference configuration.md:344-345`): 3.3 GiB на типовой разговор Claude
  Code (123–128k токенов), до 7.2 GiB при `HALOGEN_CTX=262144`. На `/` этот
  слой разросся до 42 GiB за 14 минут при 33 GiB свободных — из-за чего
  2026-10-28 его и отключили.
- **Холодный старт.** С дисковым слоем разговор переживает рестарт контейнера:
  первый ход после `podman restart` — секунды вместо ≈62 с холодного prefill на
  131k токенов (замер 2026-11-09). Восстановление побитово совпадает с
  продолжением в RAM (`reference configuration.md:352-356`).
- **Конкуренцию за диск.** n-gram-таблица модели (47.7 GiB) читается через page
  cache с корневого раздела; записи кэша больше не делят с ней одно устройство.

Не решает:

- **Давление KV-пула** (вопрос §7.2 `CLAUDE.md`). Пул живёт в RAM, дисковый слой
  его не разгружает: `no room` / `forgot` и урезанный `max_tokens` останутся.
  Справочник предупреждает: близкого к потолку пула скорость сброса на диск
  падает с нескольких GB/s до сотен MB/s (на ответ это не влияет,
  `reference configuration.md:357-364`). У нас пул бывает на 98–100%.

## 2. Диск

| | |
|---|---|
| Устройство | `nvme0n1` (не путать с `nvme1n1` — там `/boot` и LVM с `/`) |
| Модель / серийный | Samsung SSD 9100 PRO 1TB / S7YDNS0L608786N |
| Ёмкость | 931.5 GB ≈ 868 GiB |
| Разметка | GPT, одна партиция `nvme0n1p1`, ext4, метка `halogen-cache`, `-m 0` |
| UUID ФС | `2b433842-6026-4778-b7f2-8e898f6940ee` |
| Точка монтирования | `/srv/halogen-cache` |
| Каталог кэша | `/srv/halogen-cache/prompt-cache` (он же `HALOGEN_CACHE_DIR_HOST`) |

Шифрования (LUKS) сознательно нет: угроза — физический доступ к домашнему
серверу, при нём в руках и так `keys.acl` и `.env`, а passphrase при загрузке
сделал бы автоматический подъём стека хрупким.

## 3. Кто владеет каталогом (важно)

Стек поднят **rootless podman от пользователя `halogen`** (вход на сервер:
`sudo su - halogen` из `dda`; у `halogen` sudo нет). Значит uid 0 внутри
контейнера — это uid `halogen`, и каталог кэша обязан принадлежать `halogen`,
иначе halogen не сможет писать. Все root-шаги (разметка, fstab, `chown`)
выполняются из `dda` через `sudo`, а `make` и `check.sh` — из `halogen`.

Права подобраны так, чтобы несмонтированный диск нельзя было перепутать с
примонтированным:

| Путь | Владелец | Права | Смысл |
|---|---|---|---|
| `/srv/halogen-cache` | `root:root` | `0755` | точка монтирования; на `/` это пустой каталог, записать в него `halogen` не может |
| `/srv/halogen-cache/prompt-cache` | `halogen:halogen` | `0700` | существует **только на новом диске** |

Из этого следует главная страховка: если диск не примонтирован, `prompt-cache`
не существует, а создать его в root-owned `/srv/halogen-cache` rootless podman
не может → запуск падает, а не пишет кэш в корневой раздел.

## 4. Разметка с нуля (чистая установка или перенос)

```bash
# 0. убедиться, что это тот диск и он пуст (wipefs -n — dry-run, должен молчать)
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS /dev/nvme0n1
sudo wipefs -n /dev/nvme0n1

# 1. партиция
sudo parted --script /dev/nvme0n1 mklabel gpt mkpart halogen-cache 1MiB 100%

# 2. ФС: -m 0 — не резервировать 5% под root (на 931G это ~43 GiB мёртвого места)
sudo mkfs.ext4 -L halogen-cache -m 0 /dev/nvme0n1p1

# 3. точка монтирования (root-owned — см. §3)
sudo install -d -m 755 -o root -g root /srv/halogen-cache

# 4. fstab — ОДНОЙ строкой, с настоящим UUID (плейсхолдер в файл не копировать!)
sudo blkid -s UUID -o value /dev/nvme0n1p1
echo "UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p1) /srv/halogen-cache ext4 defaults,nofail,noatime,x-systemd.mount-timeout=30 0 2" | sudo tee -a /etc/fstab
grep -n halogen-cache /etc/fstab        # ровно одна строка

# 5. смонтировать и проверить
sudo systemctl daemon-reload && sudo mount -a && findmnt /srv/halogen-cache

# 6. каталог кэша — на новом диске, владелец halogen (см. §3)
sudo install -d -m 700 -o halogen -g halogen /srv/halogen-cache/prompt-cache
ls -ld /srv/halogen-cache /srv/halogen-cache/prompt-cache
```

Пояснения:

- `nofail` — загрузка не виснет, если диск вышел из строя (тогда стек просто не
  поднимется, см. страховку в §5).
- `noatime` — кэш гоняет гигабайты, лишние записи меток доступа не нужны.
- `discard` в опции НЕ ставить: LRU-вытеснение удаляет гигабайтами, TRIM на
  каждый unlink замедлит его. В Ubuntu есть штатный `fstrim.timer` (раз в
  неделю) — его достаточно, проверить `systemctl list-timers | grep fstrim`.
- ext4, а не btrfs/zfs/tmpfs: halogen требует ФС, принимающая **direct I/O**;
  tmpfs и overlay он отвергает с сообщением, и кэш молча остаётся в RAM
  (`reference configuration.md:347-349`). Проверка от имени `halogen`:

  ```bash
  dd if=/dev/zero of=/srv/halogen-cache/prompt-cache/.odtest bs=1M count=64 oflag=direct
  rm -f /srv/halogen-cache/prompt-cache/.odtest
  ```

## 5. Настройки и страховки

`.env` (ключ добавлен в `.env.example`):

```
HALOGEN_CACHE_DIR_HOST=/srv/halogen-cache/prompt-cache
```

`compose.yaml`: `HALOGEN_CACHE_DIR=/cache`, `HALOGEN_CACHE_DISK_GIB="640"`,
`HALOGEN_CACHE_PRUNE_OLD="1"`, том `${HALOGEN_CACHE_DIR_HOST}:/cache:z` и
`stop_grace_period: 60s` (при остановке флешится последний ход; podman по
умолчанию ждёт только 10 с).

Почему 640, а не «сколько есть»: `HALOGEN_CACHE_DISK_GIB` ограничивает
**поддерево текущей конфигурации** и вытесняет по LRU только когда НОВЫЙ
разговор превышает лимит (`reference FLAGS.md:135-136`). Дефолт 64 в 2026-10-28
был больше свободного места — чистка не включилась ни разу. 640 GiB при ~868 GiB
ёмкости: ≈190 типовых разговоров, запас на переполнение (максимум один
разговор, до 7.2 GiB) и на старые поддеревья.

`HALOGEN_CACHE_PRUNE_OLD=1` — потому что лимит считается только по текущему
поддереву, а прошлый апгрейд образа оставляет своё навечно
(`reference configuration.md:366-371`): без чистки старые поддеревья и есть
незафиксированный рост. Цена: откат образа застанет холодный кэш.

Три слоя защиты от «кэш поехал на `/`»:

1. `prompt-cache` существует только на диске (§3) — физически не даст записать
   не туда;
2. `GUARD_CACHE_DIR` в `Makefile` — `make up` и `make public-up` падают до
   интерполяции, если путь не задан, или он (или его родитель) не является
   точкой монтирования, или **его устройство совпадает с устройством `/`**
   (последнее закрывает дыру «каталог прямо в `/`»: `/` — тоже точка
   монтирования, и без этой проверки `/cache` проходил бы). Сообщение указывает
   на этот документ. Логика guard'а прогнана в песочнице агента на 10 сценариях
   (пустое значение из окружения, `.env` с `export`/пробелами/кавычками,
   комментарий вместо значения, отсутствие `.env`, путь на `/`, путь вне точки
   монтирования) — все 10 дают ожидаемый результат;
3. `${HALOGEN_CACHE_DIR_HOST:?…}` прямо в `compose.yaml` — закрывает запуск в
   обход make (прямой `podman-compose`), по образцу `LAN_IP`.

Проверить страховки без риска:

```bash
HALOGEN_CACHE_DIR_HOST=/var/tmp/cache make up   # ждём падение: не точка монтирования
HALOGEN_CACHE_DIR_HOST=/cache make up           # ждём падение: то же устройство, что и /
HALOGEN_CACHE_DIR_HOST= make up                 # ждём падение: пустое значение из окружения
make cache-info                                 # устройство, занято, размер каталога
```

## 6. Проверка после включения

Автоматически — `scripts/check.sh`, секция A (там же `df`-сравнение каталога кэша
с `/` и размер кэша). Ручные проверки и тест «тёплый ход после рестарта» —
`docs/server-test-checklist.md` §A.

Что смотреть в логе старта (`podman logs halogen-flash-server`):

- строку prompt-кэша с дисковым каталогом (при `HALOGEN_CACHE_DIR` она
  отличается от RAM-only-варианта — формулировку зафиксировать при первом
  прогоне);
- счётчик вычищенных старых поддеревьев от `PRUNE_OLD` (`N other
  configuration(s) hold X GiB there` до чистки);
- в бою — что `df -h /srv/halogen-cache` растёт, а `df -h /` стоит на месте.

## 7. Откат на RAM-only

Если диск выйдет из строя или кэш снова начнёт расти непредсказуемо:

1. закомментировать `HALOGEN_CACHE_DIR`, `HALOGEN_CACHE_DISK_GIB`,
   `HALOGEN_CACHE_PRUNE_OLD` в `compose.yaml` и убрать том `/cache`;
2. закомментировать `GUARD_CACHE_DIR` в рецептах `up`/`public-up` (иначе `make up`
   продолжит требовать диск);
3. `make up`.

Цена отката известна: после рестарта все разговоры холодные, ≈62 с на 131k
токенов. Именно это состояние было штатным с 2026-10-28 по 2026-11-12.

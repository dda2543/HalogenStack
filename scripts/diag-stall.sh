#!/usr/bin/env bash
# halogen-stack — диагностика «сервер виснет» (нехватка памяти / compact_stall /
# reclaim весов под строки n-gram-таблицы / GTT, удержанный мёртвым процессом).
#
# Задача скрипта — не починить, а различить три механизма, которые выглядят
# одинаково: (1) хосту не хватает памяти ИЛИ памяти нужной ФОРМЫ — ядро уходит
# в компакцию и всё встаёт на минуты (reference /docs/halogen-flash-server/
# docs/host-setup.md:10-15); (2) ядро отдаёт страницы ВЕСОВ под строки таблицы
# 47.7 GiB, и драйвер каждый раз пересобирает маппинг движка — тот же столл,
# считается как `GPU queues evicted N ms` (host-setup.md:92-106, FLAGS.md:176);
# (3) kill, прилетевший движку внутри ядра, оставляет GTT занятым без процесса,
# и после этого не поднимается ничего до перезагрузки (troubleshooting.md:57-92).
#
# Скрипт ничего не меняет на хосте: только читает /proc, /sys, журнал ядра, лог
# контейнера и дёргает HTTP. Root не нужен (кроме fuser по /dev/kfd — он
# подписан как SKIP, если прав не хватило).
#
# Запуск — на сервере, от пользователя podman (halogen), из каталога проекта:
#   bash scripts/diag-stall.sh                 # пассивная часть + нагрузка
#   bash scripts/diag-stall.sh --no-load       # только пассивная часть
#   bash scripts/diag-stall.sh --load-only     # сразу нагрузка (без пассивной)
#   bash scripts/diag-stall.sh --tokens 16000 --prompt-kib 200
#   bash scripts/diag-stall.sh --pool-every 5 --probe-every 10
#   bash scripts/diag-stall.sh --watch 3600   # час пассивного наблюдения в бою
#   bash scripts/diag-stall.sh --key-name agent1
#   CHECK_KEY=... bash scripts/diag-stall.sh
#
# Нагрузочный прогон ОДИН по умолчанию: он сам и есть «запрос, требующий
# значительного времени» — холодный prefill на случайном тексте (чтобы не в
# prompt-кэш и чтобы строки таблицы читались с диска) плюс длинный ответ. Во
# время него посекундно пишется сэмплер (PSI, MemAvailable, Mlocked,
# pgscan_direct, compact_stall, pgmajfault, GPU/GTT, процессы в D), а раз в
# --probe-every секунд шлётся крошечный запрос «ещё жив ли сервер» — это и есть
# измеряемый симптом. Прогон БЕРЁМ ГИГБАЙТЫ пула и минуты GPU: запускаем, когда
# можно, но лучше ровно тогда, когда агенты работают (тогда столлы и случаются).
#
# Настройки — из окружения (оно побеждает) и из .env, как их читает
# podman-compose: LAN_IP, SECRETS_DIR, WEBUI_SERVICE_KEY. Ключ — CHECK_KEY,
# иначе --key-name из secrets/keys.acl, иначе первый не-webui, иначе
# WEBUI_SERVICE_KEY. Значения ключей не печатаются никогда.
#
# Выход — текст + путь к двум файлам (сырой SSE-поток и сэмплер TSV): их и
# прикладывать к отчёту.

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd -- "$ROOT" || exit 1

# --- опции -------------------------------------------------------------------
DO_PASSIVE=1
DO_LOAD=1
KEY_NAME=""
BASE=""
BASE_SET=0
ENV_FILE=".env"
PODMAN=${PODMAN:-podman}
CONTAINER=halogen-flash-server
PROMPT_KIB=200        # размер холодного промпта, KiB случайного текста
TOKENS=16000          # max_tokens нагрузочного запроса
MAX_TIME=900          # потолок на нагрузочный запрос, с
INTERVAL=1            # период сэмплера, с
PROBE_EVERY=10        # раз в N секунд дёргать «ещё жив ли»
POOL_EVERY=5          # раз в N секунд снимать пул/очередь из контейнера
WATCH=0               # >0: пассивное наблюдение N секунд без нагрузочного запроса
OUTDIR=""
TIMEOUT=20            # таймаут коротких HTTP-вызовов

usage() { sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-load)   DO_LOAD=0; shift ;;
    --load-only) DO_PASSIVE=0; DO_LOAD=1; shift ;;
    --prompt-kib) PROMPT_KIB=${2:?}; shift 2 ;;
    --tokens)    TOKENS=${2:?}; shift 2 ;;
    --max-time)  MAX_TIME=${2:?}; shift 2 ;;
    --interval)  INTERVAL=${2:?}; shift 2 ;;
    --probe-every) PROBE_EVERY=${2:?}; shift 2 ;;
    --pool-every)  POOL_EVERY=${2:?}; shift 2 ;;
    --watch)       WATCH=${2:?}; shift 2 ;;
    --outdir)    OUTDIR=${2:?}; shift 2 ;;
    -k|--key-name) KEY_NAME=${2:?}; shift 2 ;;
    -b|--base)   BASE=${2:?}; BASE_SET=1; shift 2 ;;
    -t|--timeout) TIMEOUT=${2:?}; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "неизвестный аргумент: $1 (--help)" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=""; C_R=""; C_Y=""; C_B=""; C_0=""
fi

N_PASS=0; N_FAIL=0; N_SKIP=0
section() { printf '\n%s%s%s\n' "$C_B" "$1" "$C_0"; }
pass()  { N_PASS=$((N_PASS+1)); printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$1"; }
fail()  { N_FAIL=$((N_FAIL+1)); printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$1"; }
skip()  { N_SKIP=$((N_SKIP+1)); printf '  %sSKIP%s %s\n' "$C_Y" "$C_0" "$1"; }
info()  { printf '  ·    %s\n' "$1"; }
note()  { printf '       %s\n' "$1"; }
warn()  { printf '  %sWARN%s %s\n' "$C_Y" "$C_0" "$1"; }

# --- конфигурация (копия хелперов check.sh: скрипт самодостаточен) -----------
dotenv_get() { # $1=имя
  [ -f "$ENV_FILE" ] || return 1
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" \
    | tail -n 1 | tr -d '\r' \
    | sed -E 's/[[:space:]]+$//' \
    | sed -E 's/^"(.*)"$/\1/' \
    | sed -E "s/^'(.*)'\$/\1/"
}
cfg_get() { # $1=имя
  local v=${!1-}
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  dotenv_get "$1"
}

keys_file_path() {
  local sd; sd=$(cfg_get SECRETS_DIR); sd=${sd:-./secrets}
  printf '%s/keys.acl' "${sd%/}"
}
key_by_name() { # $1=имя $2=файл
  awk -F: -v n="$1" '!/^[[:space:]]*#/ && NF>1 && $1==n { sub(/^[^:]*:/, ""); gsub(/[[:space:]]/, ""); print; exit }' "$2" 2>/dev/null
}
first_agent_key_name() { # $1=файл
  awk -F: '!/^[[:space:]]*#/ && NF>1 && $1!="webui" { print $1; exit }' "$1" 2>/dev/null
}

KEY=""; KEY_SOURCE=""
resolve_key() {
  if [ -n "${CHECK_KEY:-}" ]; then KEY=$CHECK_KEY; KEY_SOURCE="окружение CHECK_KEY"; return 0; fi
  local kf; kf=$(keys_file_path)
  if [ -n "$KEY_NAME" ]; then
    [ -f "$kf" ] || { fail "ключей нет в $kf, а запрошен --key-name $KEY_NAME"; return 1; }
    KEY=$(key_by_name "$KEY_NAME" "$kf")
    [ -n "$KEY" ] || { fail "записи '$KEY_NAME' нет в $kf"; return 1; }
    KEY_SOURCE="$KEY_NAME из $kf"; return 0
  fi
  if [ -f "$kf" ]; then
    local n; n=$(first_agent_key_name "$kf")
    if [ -n "$n" ]; then KEY=$(key_by_name "$n" "$kf"); KEY_SOURCE="$n из $kf"; return 0; fi
  fi
  local w; w=$(cfg_get WEBUI_SERVICE_KEY)
  if [ -n "$w" ]; then KEY=$w; KEY_SOURCE="WEBUI_SERVICE_KEY"; return 0; fi
  fail "ключ не найден: CHECK_KEY, --key-name NAME или make key-add"
  return 1
}

LAN=$(cfg_get LAN_IP)
[ -n "$BASE" ] || BASE="http://${LAN}:8731"
if [ -z "$LAN" ] && [ "$BASE_SET" = 0 ]; then
  echo "LAN_IP не задан ни в окружении, ни в $ENV_FILE — некуда слать запросы. Запуск из каталога проекта (рядом .env) или --base http://АДРЕС:8731" >&2
fi

# --- сетевой интерфейс, по которому живёт LAN ----------------------------------
# Нужен, чтобы сэмплер следил за состоянием именно NIC: «Host is down» у
# клиента = не отработал ARP, то есть интерфейс лежал, а не halogen.
detect_nic() {
  local i n
  if [ -n "$LAN" ] && command -v ip >/dev/null 2>&1; then
    n=$(ip -o route get "$LAN" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)
    [ -n "$n" ] && { printf '%s' "$n"; return 0; }
  fi
  # запасной путь: сначала тот, что реально up и с линком, потом любой физический
  local pass
  for pass in 1 2; do
    for i in /sys/class/net/*; do
      case ${i##*/} in
        lo|veth*|br-*|cni*|tap*|docker*|podman*|virbr*|erspan*|gre*|gretap*|ip6*|dummy*|tun*|wg*|flannel*|kube*|cali*|zebra*|MLO*) continue ;;
      esac
      [ -f "$i/operstate" ] || continue
      if [ "$pass" = 1 ]; then
        [ "$(cat "$i/operstate" 2>/dev/null)" = "up" ] || continue
        [ "$(cat "$i/carrier" 2>/dev/null)" = "1" ] || continue
      fi
      printf '%s' "${i##*/}"; return 0
    done
  done
}
NIC=$(detect_nic)

# --- доступные инструменты ---------------------------------------------------
HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1
HAVE_PODMAN=0; command -v "$PODMAN" >/dev/null 2>&1 && HAVE_PODMAN=1
HAVE_JOURNALCTL=0; command -v journalctl >/dev/null 2>&1 && HAVE_JOURNALCTL=1

http_body() { curl -s --max-time "$TIMEOUT" "$@" 2>/dev/null; }
http_code() { local c; c=$(curl -s -o /dev/null --max-time "$TIMEOUT" -w '%{http_code}' "$@" 2>/dev/null); printf '%s' "${c:-000}"; }

# JSON без jq: значение поля верхнего уровня (число или строка).
jget() { # $1=файл $2=имя поля
  grep -o "\"$2\":[^,}]*" "$1" 2>/dev/null | head -n 1 \
    | sed -E "s/\"$2\":[[:space:]]*//; s/\"//g"
}

# вызов маршрута halogen ИЗНУТРИ контейнера (python3 там есть, curl — нет)
halogen_route() { # $1=путь
  $PODMAN exec "$CONTAINER" python3 -c \
    "import urllib.request as u;print(u.urlopen('http://127.0.0.1:8731$1').read().decode())" 2>/dev/null
}

# --- 1. окружение хоста ------------------------------------------------------
sec_host() {
  section "1. Хост: что задано до всякой нагрузки"

  local k; k=$(uname -r 2>/dev/null)
  info "ядро: $k   (справочник мерил на 7.1.8; #83 воспроизводился на 7.2.5)"
  local cmdline=""; [ -r /proc/cmdline ] && cmdline=$(tr '\n' ' ' </proc/cmdline)
  if [ -n "$cmdline" ]; then
    info "cmdline: $cmdline"
    case "$cmdline" in
      *amdgpu.noretry=0*)
        warn "amdgpu.noretry=0: потерянную страницу GPU ретраит вместо ошибки — то есть то же событие даёт МОЛЧАЩИЙ движок, а не падение (host-setup.md:41-44). Для цели «не виснет молча» его убирают" ;;
      *amdgpu.noretry*) info "amdgpu.noretry задан не-0: ошибка будет громкой" ;;
      *)              info "amdgpu.noretry не задан (дефолт драйвера)" ;;
    esac
    case "$cmdline" in
      *iommu=off*)   info "iommu=off — эталонная конфигурация справочника (performance.md:280)" ;;
      *iommu=pt*)    info "iommu=pt: prefill −13…16% как налог на энергобюджет; к зависанию отношения не имеет (performance.md:280-288)" ;;
      *iommu=*)      info "iommu задан в режиме отличном от off/pt — сверить с performance.md:280" ;;
      *)             info "iommu в cmdline не помянут (на Strix Halo часто включён по умолчанию, смотреть dmesg)" ;;
    esac
  else
    skip "/proc/cmdline не читается"
  fi

  # memlock — предпосылка HALOGEN_WEIGHTS_LOCK
  local ml; ml=$(ulimit -H -l 2>/dev/null)
  if [ "$ml" = "unlimited" ]; then
    pass "memlock hard = unlimited — HALOGEN_WEIGHTS_LOCK поднимется"
  else
    fail "memlock hard = $ml: rootless-поду не поднимет лимит выше этого, WEIGHTS_LOCK молча не залочит ничего (host-setup.md:129-145). Правка: строки memlock в /etc/security/limits.conf + ПЕРЕЛОГИН"
  fi
  info "memlock soft = $(ulimit -S -l 2>/dev/null)"

  # своп и память
  local mt ms sw
  mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  ms=$(awk '/^MemSwapTotal|^SwapTotal:/{print $2}' /proc/meminfo)
  sw=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
  info "MemTotal = $((mt/1024/1024)) GiB (справочник: на таких машинах 121–125 GiB, configuration.md:119)"
  if [ "${sw:-0}" -gt 0 ]; then
    info "SwapTotal = $((sw/1024/1024)) GiB, занято $(awk '/^SwapFree:/{print $2}' /proc/meminfo | awk -v s="$sw" '{print int((s-$1)/1024/1024)}') GiB — своп под weights-локом станет частью истории"
  else
    info "свопа нет"
  fi

  # sysctl-переключатели из host-setup.md
  local s
  for s in vm.compact_unevictable_allowed vm.compaction_proactiveness vm.min_free_kbytes \
           vm.vfs_cache_pressure vm.watermark_scale_factor vm.dirty_ratio vm.dirty_background_bytes; do
    local v; v=$(sysctl -n "$s" 2>/dev/null)
    [ -n "$v" ] && info "$s = $v"
  done
  local cua; cua=$(sysctl -n vm.compact_unevictable_allowed 2>/dev/null)
  case "$cua" in
    0) pass "vm.compact_unevictable_allowed=0 — компакция не таскает залоченные веса" ;;
    "") skip "vm.compact_unevictable_allowed не читается" ;;
    *) info "vm.compact_unevictable_allowed=$cua: при WEIGHTS_LOCK=1 компакция всё равно будет двигать веса, «which costs the same cycle» (host-setup.md:147-153)" ;;
  esac
}

# --- 2. память: факт против MemAvailable -------------------------------------
sec_memory() {
  section "2. Память: форма, а не количество"

  local ma mlk uev
  ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  mlk=$(awk '/^Mlocked:/{print $2}' /proc/meminfo)
  uev=$(awk '/^Unevictable:/{print $2}' /proc/meminfo)
  info "MemAvailable = $((ma/1024/1024)) GiB   Mlocked = $((mlk/1024)) MiB   Unevictable = $((uev/1024)) MiB"
  if [ "${mlk:-0}" -gt 1048576 ]; then
    pass "Mlocked nonzero — веса залочены (HALOGEN_WEIGHTS_LOCK работает)"
  else
    info "Mlocked ≈ 0: веса НЕ залочены. Само по себе это не дефект (дефолт), но значит: под давлением ядро отдаёт их страницы под строки n-gram-таблицы, и драйвер пересобирает маппинг движка — механизм столлов из #85/#83 (host-setup.md:92-106)"
  fi
  note "помнить: MemAvailable на этой машине врёт на размер модели (~62 GiB), потому что веса считаются reclaimable file cache — верить строке \`host memory left for everything else\` из лога старта (host-setup.md:61-76)"

  # счётчики давления: что наросло с момента загрузки
  info "счётчики /proc/vmstat (накопительные):"
  local f
  for f in compact_stall compact_fail compact_success pgscan_direct pgsteal_direct pgmajfault allocstall_movable allocstall_normal allocstall_dma; do
    local v; v=$(awk -v k="$f" '$1==k{print $2}' /proc/vmstat)
    [ -n "$v" ] && note "$f = $v"
  done
  note "pgscan_direct>0 или compact_stall растущий = прямые аллокации встали в реклейм/компакцию — это и есть «выглядит ровно как зависание»"

  # PSI — прямой ответ «память / диск / CPU» вместо гипотезы про шину
  local p
  for p in memory io cpu; do
    if [ -r "/proc/pressure/$p" ]; then
      note "PSI $p: $(tr '\n' ' ' < "/proc/pressure/$p")"
    fi
  done
  [ -r /proc/pressure/memory ] || skip "/proc/pressure нет (ядро старше 4.8?)"

  # conntrack: переполнение таблицы (podman/nftables держат в ней соединения)
  # даёт «соединения не устанавливаются» при живом ядре — очень похоже на наш
  # симптом, и проверяется одной строкой
  local ctc ctm
  ctc=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
  ctm=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
  if [ -n "$ctc" ] && [ -n "$ctm" ]; then
    if [ "$ctm" -gt 0 ] && [ $((ctc * 100 / ctm)) -ge 80 ]; then
      warn "conntrack заполнен на $((ctc * 100 / ctm))% ($ctc из $ctm) — новые соединения будут отваливаться"
    else
      info "conntrack: $ctc из $ctm ($(( ctc * 100 / ctm ))%)"
    fi
  fi

  info "нагрузка: $(cat /proc/loadavg)  (nproc = $(nproc 2>/dev/null))"
  local d; d=$(ps -eo stat= 2>/dev/null | grep -c '^D' || true)
  info "процессов в D (uninterruptible sleep) прямо сейчас: ${d:-?} — именно их watchdog отказывается считать клином (FLAGS.md:172)"
}

# --- 3. GPU и GTT ------------------------------------------------------------
sec_gpu() {
  section "3. GPU: GTT и удержанный мёртвым процессом пул"

  local d found=0
  for d in /sys/class/drm/card*/device; do
    [ -d "$d" ] || continue
    [ -f "$d/mem_info_gtt_used" ] || continue
    found=1
    local gu gs vu vt vram_total=""
    gu=$(cat "$d/mem_info_gtt_used" 2>/dev/null)
    gs=$(cat "$d/mem_info_gtt_size" 2>/dev/null)
    vu=$(cat "$d/mem_info_vram_used" 2>/dev/null)
    # имя файла с объёмом VRAM различается между ядрами
    for vt in mem_info_vram_total mem_info_vram_size mem_info_vram_visible; do
      [ -f "$d/$vt" ] && { vram_total=$(cat "$d/$vt"); break; }
    done
    # mem_info_* отдают БАЙТЫ: делить надо на 1024^3 (первая версия делила на
    # 1024^2 и подписывала GiB — вранье в 1024 раза)
    info "$d: GTT used = $(( ${gu:-0} / 1024 / 1024 / 1024 )) GiB из $(( ${gs:-0} / 1024 / 1024 / 1024 )) GiB   VRAM used = $(( ${vu:-0} / 1024 / 1024 / 1024 )) GiB из $(( ${vram_total:-0} / 1024 / 1024 / 1024 )) GiB"
    local busy; busy=$(cat "$d/gpu_busy_percent" 2>/dev/null)
    [ -n "$busy" ] && info "gpu_busy_percent = $busy"
    # KV-пул живёт в GTT: сравниваем занятое с тем, что должен держать наш старт
    if [ "${gu:-0}" -gt 0 ] && [ "$HAVE_PODMAN" = 1 ] && [ "$(container_state halogen-flash-server)" != "running" ]; then
      warn "GTT занят ($(( gu / 1024 / 1024 )) GiB), а halogen не запущен — признак удержанного мёртвым процессом GTT: следующие старты будут висеть до перезагрузки (troubleshooting.md:57-92). Проверить: fuser -v /dev/kfd"
    fi
  done
  [ "$found" = 1 ] || skip "не нашёл /sys/class/drm/card*/device/mem_info_gtt_used"

  if [ "$HAVE_PODMAN" = 1 ]; then
    local who
    who=$(fuser -v /dev/kfd 2>/dev/null | tr -s ' \n' ' ')
    if [ -n "$who" ]; then info "/dev/kfd держат: $who"; else info "/dev/kfd никем не держится (или не хватило прав — тогда sudo fuser -v /dev/kfd)"; fi
  fi

  # NIC: «Host is down» у клиента = не отработал ARP → интерфейс лежал.
  section "3b. Сетевой путь"
  if [ -z "$NIC" ]; then skip "не определил сетевой интерфейс"; return 0; fi
  local st car drv
  st=$(cat "/sys/class/net/$NIC/operstate" 2>/dev/null)
  car=$(cat "/sys/class/net/$NIC/carrier" 2>/dev/null)
  drv=$(ethtool -i "$NIC" 2>/dev/null | awk '/^driver:|^firmware-version:|^version:/ {printf "%s ", $2}')
  info "интерфейс $NIC: operstate=${st:-?} carrier=${car:-?} драйвер: ${drv:-ethtool недоступен}"
  info "счётчики: $(for f in rx_dropped tx_dropped rx_errors tx_errors rx_missed_errors; do
                      v=$(cat "/sys/class/net/$NIC/statistics/$f" 2>/dev/null); [ -n "$v" ] && printf '%s=%s ' "$f" "$v"; done)"
  if [ -n "$car" ] && [ "$car" = "0" ]; then warn "carrier=0 — линка физически нет прямо сейчас"
  elif [ -n "$st" ] && [ "$st" != "up" ]; then warn "operstate=$st — интерфейс не up"
  else pass "интерфейс $NIC сейчас up и с carrier"
  fi
  info "история линка (кто падал): journalctl -k | grep -iE 'link is (down|up)|nic|reset adapter'"
}

container_state() { $PODMAN inspect -f '{{.State.Status}}' "$1" 2>/dev/null; }

# --- 4. журнал ядра ----------------------------------------------------------
sec_journal() {
  section "4. Журнал ядра: что машина видела во время зависаний"

  if [ "$HAVE_JOURNALCTL" != 1 ]; then skip "journalctl нет"; return 0; fi
  local pat='hung_task|blocked for more than|amdgpu|kfd|machine check|Out of memory|oom-kill|Killed process|compac|gpu reset|GPU fault|cat_err|soft lockup|softlockup|rcu.*stall|watchdog: BUG|hard LOCKUP|link is down|link is up|nic .*reset|reset adapter|suspend entry|suspend exit|s2idle|en[a-z0-9]+: Link|eth[0-9]+: Link'
  local b
  for b in "" "-b"; do
    local label="текущая загрузка"
    [ -n "$b" ] && label="прошлая загрузка (-b-1)"
    [ -n "$b" ] && b="-b -1"
    local out n
    out=$(journalctl -k $b --no-pager 2>/dev/null | grep -iE "$pat")
    n=$(printf '%s' "$out" | grep -c . || true)
    if [ "${n:-0}" = 0 ]; then info "$label: совпадений нет"; continue; fi
    info "$label: $n строк по шаблону"
    printf '%s\n' "$out" | grep -iE 'blocked for more than|Out of memory|oom-kill|Killed process|gpu reset|machine check' | head -n 12 | sed 's/^/       /'
    note "полное: journalctl -k $b | grep -iE '$pat'"
  done
  note "нет строк \`blocked for more than 120 seconds\` при жалобе на зависание = ядро столл не видело, искать в логе halogen и в GPU"

  # Подозрение на suspend: «машина пропала и потом оттаяла» на десктопном
  # запуске (quiet splash) часто оказывается штатным s2idle, а не зависанием.
  local sus
  sus=$(journalctl -k --no-pager 2>/dev/null | grep -iE 'suspend entry|suspend exit|s2idle|PM: suspend' | tail -n 6)
  if [ -n "$sus" ]; then
    warn "в журнале есть suspend/resume — «пропадала и оттаивала» может быть штатным сном:"
    printf '%s\n' "$sus" | sed 's/^/       /'
  else
    info "suspend/resume в журнале не замечен (значит падения — не сон)"
  fi
  local lnk
  lnk=$(journalctl -k --no-pager 2>/dev/null | grep -iE 'link is down|link is up|nic .*reset|reset adapter' | tail -n 8)
  if [ -n "$lnk" ]; then
    warn "были события линка NIC — сетевой путь падал сам по себе:"
    printf '%s\n' "$lnk" | sed 's/^/       /'
  else
    info "событий линка NIC в журнале нет"
  fi
  local pstore
  pstore=$(ls -A /sys/fs/pstore 2>/dev/null | head -n 5)
  if [ -n "$pstore" ]; then
    warn "в pstore есть записи предыдущего падения: $pstore"
  else
    info "pstore пуст: ramoops не настроен, следов жёсткого зависания не будет (crashkernel — это kdump, не pstore)"
  fi
}

# --- 5. лог контейнера halogen ----------------------------------------------
sec_log() {
  section "5. Лог halogen: строки, которые отвечают прямо"

  if [ "$HAVE_PODMAN" != 1 ]; then skip "podman нет"; return 0; fi
  if [ "$(container_state "$CONTAINER")" != "running" ]; then fail "$CONTAINER не запущен"; return 0; fi
  local log; log=$($PODMAN logs "$CONTAINER" 2>&1)
  local n; n=$(printf '%s\n' "$log" | grep -c . || true)
  info "строк в логе контейнера: $n"

  # 5.1 — сколько RAM реально осталось (главное число, которого у нас нет)
  local left
  left=$(printf '%s\n' "$log" | grep -iE 'host memory left for everything else' | tail -n 1)
  if [ -n "$left" ]; then
    pass "есть строка про оставшееся место"
    note "$left"
    note "это и есть бюджет сожителей; free/MemAvailable врут на размер модели (host-setup.md:61-76)"
  else
    skip "строки \`host memory left for everything else\` в логе нет (старый пин? лог ротирован?)"
  fi
  printf '%s\n' "$log" | grep -iE 'free\(1\) and MemAvailable will report' | tail -n 1 | sed 's/^/       /'
  printf '%s\n' "$log" | grep -iE 'of host RAM is in use before this server starts' | tail -n 1 | sed 's/^/       /'

  # 5.2 — GTT до старта и предупреждения о фрагментации
  for pat in 'GTT in use before this start' 'WARNING.*GTT is in use' 'LOWERING THE POOL' 'still reserving' 'FRAG|frag ' 'compact' 'reserving the KV pool'; do
    local hit; hit=$(printf '%s\n' "$log" | grep -iE "$pat" | tail -n 2)
    [ -n "$hit" ] && printf '%s\n' "$hit" | sed 's/^/       /'
  done

  # 5.3 — счётчик пересборки маппинга (механизм #2)
  local ev evn evmax
  ev=$(printf '%s\n' "$log" | grep -oE 'GPU queues evicted [0-9]+ ms' )
  evn=$(printf '%s\n' "$ev" | grep -c . || true)
  if [ "${evn:-0}" = 0 ]; then
    pass "ни одной строки \`GPU queues evicted\` — маппинг движка не пересобирали"
  else
    evmax=$(printf '%s\n' "$ev" | grep -oE '[0-9]+' | sort -n | tail -n 1)
    warn "строк \`GPU queues evicted\`: $evn, максимум ${evmax} ms — это и есть плата за reclaim весов (FLAGS.md:176); в /metrics тот же счётчик: halogen:gpu_queues_evicted_seconds_total"
  fi

  # 5.4 — чтение таблицы с диска
  local lt; lt=$(printf '%s\n' "$log" | grep -E 'lookup table: .* took [0-9]' | tail -n 5)
  if [ -n "$lt" ]; then info "таблица читалась с диска (строки >=2 s):"; printf '%s\n' "$lt" | sed 's/^/       /'
  else info "строк \`lookup table: ... took N s\` нет — таблица была в page cache"; fi

  # 5.5 — watchdog и «молчание не считается клином»
  local wd; wd=$(printf '%s\n' "$log" | grep -iE 'not counted as a wedge|watchdog|deferr' | tail -n 8)
  if [ -n "$wd" ]; then warn "watchdog что-то писал:"; printf '%s\n' "$wd" | sed 's/^/       /'
  else info "watchdog молчал (ни kills, ни отсрочек)"; fi

  # 5.6 — старт и кэш
  printf '%s\n' "$log" | grep -iE 'prompt cache on DISK|prompt cache ON|oom_score_adj|version .* engine version|listening on' | head -n 6 | sed 's/^/       /'
  local cg ws
  cg=$(printf '%s\n' "$log" | grep -cE 'cannot grow' || true)
  ws=$(printf '%s\n' "$log" | grep -cE 'was shortened' || true)
  info "признаки обреза хода за жизнь контейнера: \`cannot grow\` = ${cg:-0} (рутина с 0.20.1), \`was shortened\` = ${ws:-0} (настоящий обрез)"
  [ "${ws:-0}" = 0 ] || warn "есть \`was shortened\` — пул реально режет max_tokens, см. §7.2 CLAUDE.md"
}

# --- 6. /cache и /metrics из контейнера --------------------------------------
sec_api() {
  section "6. /cache и /metrics (python3 внутри контейнера)"

  if [ "$HAVE_PODMAN" != 1 ]; then skip "podman нет"; return 0; fi
  if [ "$(container_state "$CONTAINER")" != "running" ]; then skip "$CONTAINER не запущен"; return 0; fi

  local cf; cf=$(mktemp "${TMPDIR:-/tmp}/diag-cache.XXXXXX")
  halogen_route /cache > "$cf"
  if [ ! -s "$cf" ]; then
    skip "/cache не получился (python3 не запустился или маршрут закрыт)"
  else
    local u used clamp drop ev root hr thr entries
    used=$(jget "$cf" usage_ratio); u=$(jget "$cf" used)
    clamp=$(jget "$cf" room_clamped); drop=$(jget "$cf" dropped)
    ev=$(jget "$cf" evicted); root=$(jget "$cf" cache_root)
    hr=$(jget "$cf" hit_rate); thr=$(jget "$cf" token_hit_rate)
    entries=$(jget "$cf" max_entries)
    info "пул: used=$u, usage_ratio=${used:-?} ; room_clamped=${clamp:-?} ; dropped=${drop:-?} ; evicted(RAM)=${ev:-?}"
    info "кэш: max_entries=${entries:-?}, hit_rate=${hr:-?}, token_hit_rate=${thr:-?}, cache_root=${root:-?}"
    if [ "${clamp:-0}" = 0 ]; then pass "room_clamped=0 — ходы не урезались из-за пула"; else warn "room_clamped=${clamp} — пул резал max_tokens"; fi
    info "полный JSON: $cf"
  fi

  local mf; mf=$(mktemp "${TMPDIR:-/tmp}/diag-metrics.XXXXXX")
  halogen_route /metrics > "$mf"
  if [ ! -s "$mf" ]; then
    skip "/metrics не получился"
  else
    info "счётчики, относящиеся к столлам:"
    grep -E 'gpu_queues_evicted|evict|kv_pool|pool_positions|pool_used|waiting_for_room|shortened|clamped|admission|queue' "$mf" \
      | grep -v '^#' | head -n 25 | sed 's/^/       /'
    info "полный /metrics: $mf"
  fi
}

# --- 7. нагрузка + сэмплер ---------------------------------------------------
# Проба «ещё жив ли» двумя разными маршрутами: /healthz не трогает GPU и слоты,
# генерация трогает. Без разделения «прокси жив, а генерация стоит» неотличимо
# от «не отвечает ничего». Коды пишутся как есть: 000 = таймаут или отказ коннекта.
probe_once() { # $1=epoch
  local ep=$1 r body code t
  # inner — healthz ИЗНУТРИ контейнера, минуя сетевой стек хоста вовсе. Это
  # решающая проба: inner живой при мёртвых healthz/gen = halogen в порядке,
  # лёг сетевой путь (NIC/драйвер/ARP), а не инференс.
  if [ "$HAVE_PODMAN" = 1 ]; then
    r=$($PODMAN exec "$CONTAINER" python3 -c \
      'import urllib.request as u,time
t=time.time()
try:
    print(u.urlopen("http://127.0.0.1:8731/healthz",timeout=20).status, round(time.time()-t,2))
except Exception as e:
    print("000", round(time.time()-t,2))' 2>/dev/null)
    printf '%s\tinner\t%s\n' "$ep" "${r:-000 0}" >> "$PROBE_FILE"
  fi
  r=$(curl -s -o /dev/null --max-time 20 -w '%{http_code} %{time_total}' "$BASE/healthz" 2>/dev/null)
  printf '%s\thealthz\t%s\n' "$ep" "${r:-000 0}" >> "$PROBE_FILE"
  body=$(printf '{"model":"%s","messages":[{"role":"user","content":"ок"}],"max_tokens":8}' "$MODEL")
  # тело пишем в файл: при не-200 оно и есть ответ на вопрос «кто отказал»
  t=$(mktemp "${TMPDIR:-/tmp}/diag-probe-body.XXXXXX")
  r=$(curl -s -o "$t" --max-time 120 -w '%{http_code} %{time_total}' -X POST \
        -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
        -d "$body" "$BASE/v1/chat/completions" 2>/dev/null)
  code=${r%% *}
  if [ "${code:-000}" != "200" ] && [ "$(find "$PROBE_FAIL_DIR" -type f 2>/dev/null | wc -l)" -lt 5 ]; then
    mv "$t" "$PROBE_FAIL_DIR/${ep}.${code:-000}.body" 2>/dev/null || rm -f "$t"
  else
    rm -f "$t"
  fi
  printf '%s\tgen\t%s\n' "$ep" "${r:-000 0}" >> "$PROBE_FILE"
}

# Снимок пула и очереди из контейнера. Именно эта колонка решает, ждал ли запрос
# места: usage_ratio и waiting_for_room — датчики текущего момента.
POOL_SNIPPET='import urllib.request as u,json,re
c=json.loads(u.urlopen("http://127.0.0.1:8731/cache",timeout=5).read())
p=c.get("pool",{})
m=u.urlopen("http://127.0.0.1:8731/metrics",timeout=5).read().decode()
g=lambda k:(re.search(r"halogen:"+k+r" ([0-9.eE+-]+)",m) or [None,"0"])[1]
print(p.get("used"),p.get("usage_ratio"),p.get("waiting_for_room"),p.get("room_clamped"),p.get("busy_regions"),p.get("held_regions"),c.get("dropped"),c.get("evicted"),g("queue_waited_total"),g("queue_wait_seconds_total"),g("queue_wait_longest_seconds"),sep="\t")'

pool_once() { # $1=epoch
  [ "$HAVE_PODMAN" = 1 ] || return 0
  local out
  out=$($PODMAN exec "$CONTAINER" python3 -c "$POOL_SNIPPET" 2>/dev/null)
  [ -n "$out" ] && printf '%s\t%s\n' "$1" "$out" >> "$POOL_FILE"
}

sampler() { # $1=tsv $2=период $3=probe_every $4=длительность_сек
  local tsv=$1 per=$2 probe=$3 dur=$4
  local t0 now i=0 last_pool=0
  t0=$(date +%s)
  printf 'epoch\tload1\tmemavail_kib\tmlocked_kib\tpgscan_direct\tcompact_stall\tpgmajfault\tpsi_mem_some\tpsi_mem_total\tpsi_io_some\tpsi_io_total\tgpbusy\tgtt_gib\tdstate\tnic_state\tnic_carrier\tnic_drop\tnic_err\n' > "$tsv"
  while :; do
    now=$(date +%s)
    [ $((now - t0)) -gt "$dur" ] && break
    local ma mlk psd cs pmf pms pmt pis pit busy gtt ds la
    ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    mlk=$(awk '/^Mlocked:/{print $2}' /proc/meminfo)
    psd=$(awk '$1=="pgscan_direct"{print $2}' /proc/vmstat)
    cs=$(awk '$1=="compact_stall"{print $2}' /proc/vmstat)
    pmf=$(awk '$1=="pgmajfault"{print $2}' /proc/vmstat)
    pms=$(sed -n 's/^some .*avg10=\([0-9.]*\).*/\1/p' /proc/pressure/memory 2>/dev/null)
    pmt=$(sed -n 's/^some .*total=\([0-9]*\).*/\1/p' /proc/pressure/memory 2>/dev/null)
    pis=$(sed -n 's/^some .*avg10=\([0-9.]*\).*/\1/p' /proc/pressure/io 2>/dev/null)
    pit=$(sed -n 's/^some .*total=\([0-9]*\).*/\1/p' /proc/pressure/io 2>/dev/null)
    la=$(cut -d' ' -f1 /proc/loadavg)
    ds=$(ps -eo stat= 2>/dev/null | grep -c '^D' || true)
    busy=""; gtt=""
    local d
    for d in /sys/class/drm/card*/device; do
      [ -f "$d/mem_info_gtt_used" ] || continue
      busy=$(cat "$d/gpu_busy_percent" 2>/dev/null)
      gtt=$(( $(cat "$d/mem_info_gtt_used" 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
      break
    done
    # Состояние NIC: «Host is down»/«No route to host» у удалённого клиента =
    # не отработал ARP, то есть интерфейс лежал. Проверяем прямо по счётчикам.
    local nst="" ncar="" ndrop="" nerr=""
    if [ -n "$NIC" ] && [ -d "/sys/class/net/$NIC" ]; then
      nst=$(cat "/sys/class/net/$NIC/operstate" 2>/dev/null)
      ncar=$(cat "/sys/class/net/$NIC/carrier" 2>/dev/null)
      ndrop=$(( $(cat "/sys/class/net/$NIC/statistics/rx_dropped" 2>/dev/null || echo 0) + $(cat "/sys/class/net/$NIC/statistics/tx_dropped" 2>/dev/null || echo 0) ))
      nerr=$(( $(cat "/sys/class/net/$NIC/statistics/rx_errors" 2>/dev/null || echo 0) + $(cat "/sys/class/net/$NIC/statistics/tx_errors" 2>/dev/null || echo 0) ))
    fi
    # Проба «ещё жив ли» — В ФОНЕ. Синхронная проба зависла бы вместе с сервером
    # и съела ровно те секунды, ради которых ведётся сэмплер.
    if [ "$probe" != 0 ] && [ $((i % probe)) = 0 ] && [ -n "$KEY" ]; then
      probe_once "$now" &
    fi
    # Состояние пула — тоже в фоне и тоже ВО ВРЕМЯ нагрузки: мгновенные датчики
    # (waiting_for_room, busy_regions) после прогона уже нули.
    if [ "$POOL_EVERY" != 0 ] && [ $((now - last_pool)) -ge "$POOL_EVERY" ]; then
      last_pool=$now
      pool_once "$now" &
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$now" "$la" "$ma" "$mlk" "$psd" "$cs" "$pmf" "$pms" "$pmt" "$pis" "$pit" "$busy" "$gtt" "$ds" "$nst" "$ncar" "$ndrop" "$nerr" >> "$tsv"
    i=$((i + 1))
    sleep "$per"
  done
}

# Сводка по всем трём регистраторам. Вынесена отдельно, чтобы --watch печатал
# ровно то же, что и нагрузочный прогон.
print_summaries() { # $1=tsv
  local tsv=$1
  # сводка по сэмплеру
  info "сводка сэмплера ($(($(wc -l < "$tsv") - 1)) отсчётов по ${INTERVAL} с):"
  awk -F'\t' 'NR>1 {
      n++
      if (mn=="" || $3<mn) mn=$3
      if ($8!="" && $8+0>psm) psm=$8+0
      if ($10!="" && $10+0>pso) pso=$10+0
      if ($14+0>dsm) dsm=$14+0
      if ($12!="" && $12+0>busym) busym=$12+0
      if ($13!="" && $13+0>gttm) gttm=$13+0
      if ($15!="" && $15!="up") { notup++; if ($15!="" && $15!="down") nst=$15 }
      if ($16!="" && $16+0==0) nocar++
      if (first==0) { first=1; s0=$5; c0=$6; f0=$7; mt0=$9; it0=$11; d0=$17; er0=$18 }
      e0=$5; e1=$6; e2=$7; e3=$9; e4=$11; d1=$17; er1=$18
    }
    END {
      if (!n) { print "  (пусто)"; exit }
      printf "  min MemAvailable      = %d GiB\n", mn/1024/1024
      printf "  delta pgscan_direct   = %d\n", e0-s0
      printf "  delta compact_stall   = %d\n", e1-c0
      printf "  delta pgmajfault      = %d  (мажорные промахи = чтение таблицы с диска)\n", e2-f0
      printf "  PSI memory some max avg10 = %.1f%%   total=%d\n", psm, e3-mt0
      printf "  PSI io      some max avg10 = %.1f%%   total=%d\n", pso, e4-it0
      printf "  процессов в D, максимум = %d\n", dsm
      printf "  gpu_busy max = %s%%   GTT max = %s GiB\n", busym, gttm
      printf "  NIC: отсчётов не-up = %d, без carrier = %d, delta drop = %d, delta err = %d\n", notup+0, nocar+0, d1-d0, er1-er0
    }' "$tsv" | sed 's/^/       /'

  # пробы «ещё жив ли» — главный измеряемый симптом. healthz и генерация
  # разделены: «прокси жив, генерация стоит» и «не отвечает ничего» — разные диагнозы.
  if [ -s "$PROBE_FILE" ]; then
    info "пробы «ещё жив ли» (раз в ${PROBE_EVERY} с, параллельно нагрузке):"
    awk -F'\t' '
      { split($3, a, " "); c = a[1]; t = a[2] + 0
        n[$2]++; sum[$2] += t
        if (t > mx[$2]) { mx[$2] = t; at[$2] = $1; mxc[$2] = c }
        if (c != "200") { bad[$2]++; codes[$2 " " c]++ } }
      END {
        for (k in n)
          printf "  %-8s всего %d, не-200: %d, средняя %.1f с, самая долгая %.1f с (код %s, в %s)\n",
                 k, n[k], bad[k]+0, sum[k]/n[k], mx[k], (mxc[k] ? mxc[k] : "-"), strftime("%H:%M:%S", at[k])
        for (ck in codes) printf "  код%s × %d\n", substr(ck, index(ck, " ")), codes[ck]
      }' "$PROBE_FILE" | sed 's/^/       /'
    note "000 = таймаут или отказ коннекта; 4xx/5xx = отказ кто-то вернул (тело первых пяти — в $PROBE_FAIL_DIR)"
    if [ -d "$PROBE_FAIL_DIR" ] && [ -n "$(ls -A "$PROBE_FAIL_DIR" 2>/dev/null)" ]; then
      info "тела отказов (первые байты):"
      for f in "$PROBE_FAIL_DIR"/*; do
        [ -f "$f" ] || continue
        printf '       %s: %s\n' "$(basename "$f")" "$(head -c 200 "$f" | tr '\n' ' ')"
      done
    fi
  else
    skip "проб не было (--probe-every 0 или нет ключа)"
  fi

  # пул ВО ВРЕМЯ нагрузки — решает вопрос «ждал ли запрос места»
  if [ -s "$POOL_FILE" ]; then
    info "пул и очередь во время нагрузки ($(wc -l < "$POOL_FILE") снимков по ${POOL_EVERY} с):"
    awk -F'\t' '
      { n++
        if ($3+0 > mxu) { mxu = $3+0; at = $1 }
        if ($4+0 > mxw) { mxw = $4+0 }
        if ($7+0 > mxb) { mxb = $7+0 }
        if ($10+0 > mxq) { mxq = $10+0 }
        if (n == 1) { u0 = $10 }
        last = $10
      }
      END {
        printf "  usage_ratio максимум = %.3f (в %s)\n", mxu, strftime("%H:%M:%S", at)
        printf "  waiting_for_room максимум = %d\n", mxw
        printf "  busy_regions максимум = %d\n", mxb
        printf "  queue_waited_total: %s → %s (выросло за прогон на %s)\n", u0, last, last - u0
        printf "  queue_wait_longest максимум = %s с\n", mxq
      }' "$POOL_FILE" | sed 's/^/       /'
    note "usage_ratio близко к 1 при выросшем queue_waited_total = новые ходы ждали позиции в пуле"
  fi
  info "файлы: поток $raw ; сэмплер $tsv ; пробы $PROBE_FILE ; пул $POOL_FILE"
  note "сэмплер TSV — главный артефакт: колонки 5/6/7 (pgscan_direct, compact_stall, pgmajfault) и 8/10 (PSI) различают память, диск и GPU"
}

# Пассивное наблюдение: тот же сэмплер, те же пробы и снимки пула, но БЕЗ
# нагрузочного запроса. Нужен потому, что зависание случается в бою во время
# работы агентов, а не по заказу. Запуск: bash scripts/diag-stall.sh --watch 3600
sec_watch() {
  section "7. Наблюдение ${WATCH} с без нагрузочного запроса"
  local tsv raw
  tsv=$(mktemp "${TMPDIR:-/tmp}/diag-samples.XXXXXX.tsv")
  raw="(нет — режим наблюдения)"
  PROBE_FILE=$(mktemp "${TMPDIR:-/tmp}/diag-probes.XXXXXX.tsv")
  POOL_FILE=$(mktemp "${TMPDIR:-/tmp}/diag-pool.XXXXXX.tsv")
  PROBE_FAIL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/diag-probe-fail.XXXXXX")
  info "пишу сэмплер, пробы и снимки пула ${WATCH} с; Ctrl-C прерывает и печатает сводку"
  sampler "$tsv" "$INTERVAL" "$PROBE_EVERY" "$WATCH" &
  local smp=$!
  trap "kill $smp 2>/dev/null" INT
  while kill -0 "$smp" 2>/dev/null; do sleep 2; done
  wait "$smp" 2>/dev/null
  trap - INT
  print_summaries "$tsv"
}
sec_load() {
  section "7. Нагрузка: холодный prefill + длинный ответ, с посекундным сэмплером"

  if [ "$HAVE_CURL" != 1 ]; then skip "curl нет"; return 0; fi
  if [ -z "$KEY" ]; then skip "ключа нет — нагрузку не гоняем"; return 0; fi
  local code; code=$(http_code "$BASE/healthz")
  if [ "$code" != "200" ]; then fail "$BASE/healthz вернул $code — стек не отвечает, нагрузку не гоняем"; return 0; fi
  MODEL=$(http_body -H "Authorization: Bearer $KEY" "$BASE/v1/models" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)
  if [ -z "$MODEL" ]; then fail "/v1/models не отдал модель (ключ $KEY_SOURCE)"; return 0; fi
  info "модель: $MODEL ; ключ: $KEY_SOURCE (значение не печатается)"
  info "промпт: ${PROMPT_KIB} KiB случайного текста (холодный prefill + промахи по n-gram-таблице), max_tokens=$TOKENS"
  note "запрос возьмёт ~(prompt+max_tokens) позиций пула и несколько минут GPU. Симтом чаще ловится, когда агенты уже работают"

  # тело: случайные слова => ни prompt-кэш, ни предсказуемость для таблицы
  local body_file; body_file=$(mktemp "${TMPDIR:-/tmp}/diag-body.XXXXXX.json")
  {
    printf '{"model":"%s","messages":[{"role":"user","content":"' "$MODEL"
    printf 'Придумай очень длинный рассказ. Материалы к нему ниже, они перемешаны и бессмысленны, используй их как ритмическую основу. '
    # ~90 слов на KiB: в среднем 11.5 байта на слово с пробелом (проверено на
    # этом же списке слов), то есть --prompt-kib 200 даёт ~207 KB текста
    awk -v n=$((PROMPT_KIB * 90)) 'BEGIN{srand(); split("ядро шина память кэш диск узел поток кадр строка таблица весов грань слой вектор матрица окно слот пикет разряд гавань пристань фонарь чертёж деталь узел", w, " "); for(i=0;i<n;i++) printf "%s ", w[int(rand()*24)+1]}'
    printf '"}],"stream":true,"max_tokens":%d,"temperature":0.7}' "$TOKENS"
  } > "$body_file"
  local bytes; bytes=$(wc -c < "$body_file")
  info "тело запроса: $bytes байт (~$((bytes/4/1024))k токенов по оценке 4 байта/токен)"

  local raw tsv
  raw=$(mktemp "${TMPDIR:-/tmp}/diag-stream.XXXXXX.sse")
  tsv=$(mktemp "${TMPDIR:-/tmp}/diag-samples.XXXXXX.tsv")
  PROBE_FILE=$(mktemp "${TMPDIR:-/tmp}/diag-probes.XXXXXX.tsv")
  POOL_FILE=$(mktemp "${TMPDIR:-/tmp}/diag-pool.XXXXXX.tsv")
  PROBE_FAIL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/diag-probe-fail.XXXXXX")

  # сэмплер живёт чуть дольше запроса: столл часто продолжается после его конца
  sampler "$tsv" "$INTERVAL" "$PROBE_EVERY" $((MAX_TIME + 30)) &
  local smp=$!

  local t0 t1
  t0=$(date +%s)
  # Разбор потока — циклом на bash, а не awk: mawk (на Ubuntu это /usr/bin/awk)
  # буферизует вход и выдаёт строки пачкой в конце, поэтому живые паузы им
  # измерить нельзя — проверено экспериментально на mawk 1.3.4.
  #
  # Пауза считается по ЛЮБОМУ data:-чанку, а не только по content. Первая версия
  # считала только content — и запрос под HALOGEN_REASONING_EFFORT=xhigh выглядел
  # как 288-секундное зависание, хотя модель просто ~4.5 минуты думала: дельты
  # размышлений в content не попадают. Так что «тишина» = тишина всего потока.
  local chunks=0 content_chunks=0 reason_chunks=0 keepalive=0
  local ttft=-1 total_s=0 gap=0 gap_at=0
  local t_first=-1 t_now g line t_start t_last
  t_start=${EPOCHSECONDS:-$(date +%s)}
  t_last=$t_start
  exec 3>>"$raw"
  while IFS= read -r line; do
    printf '%s\n' "$line" >&3
    case $line in
      ":"*) keepalive=$((keepalive + 1)) ;;
      data:*"[DONE]"*) ;;
      data:*)
        t_now=${EPOCHSECONDS:-$(date +%s)}
        [ "$t_first" -lt 0 ] && t_first=$t_now
        g=$((t_now - t_last))
        if [ "$g" -gt "$gap" ]; then gap=$g; gap_at=$chunks; fi
        t_last=$t_now
        chunks=$((chunks + 1))
        # Подсчёт через [[ == ]], а не case: шаблоны с кавычками внутри case
        # разбираются ненадёжно (тот же шаблон то матчится, то ломает парсер —
        # поймано на mawk-песочнице). Кавычки в [[ ]] значат «буквально».
        if [[ $line == *'"content":'* && $line != *'"content":""'* ]]; then
          content_chunks=$((content_chunks + 1))
        fi
        if [[ $line == *reasoning* || $line == *thinking* ]]; then
          reason_chunks=$((reason_chunks + 1))
        fi
        ;;
    esac
  done < <(curl -sN --max-time "$MAX_TIME" -X POST \
             -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
             --data-binary "@$body_file" "$BASE/v1/chat/completions" 2>/dev/null)
  exec 3>&-
  t_now=${EPOCHSECONDS:-$(date +%s)}
  total_s=$((t_now - t_start))
  [ "$t_first" -ge 0 ] && ttft=$((t_first - t_start))
  {
    printf 'chunks=%d\ncontent_chunks=%d\nreasoning_chunks=%d\nkeepalive=%d\n' \
      "$chunks" "$content_chunks" "$reason_chunks" "$keepalive"
    printf 'ttft_s=%d\ntotal_s=%d\nmax_gap_s=%d\nmax_gap_after_chunk=%d\n' \
      "$ttft" "$total_s" "$gap" "$gap_at"
  } > "${tsv}.stream"
  t1=$t_now

  kill "$smp" 2>/dev/null; wait "$smp" 2>/dev/null

  local lines; lines=$(grep -c '^data:' "$raw" || true)
  if [ "${lines:-0}" = 0 ]; then
    fail "в ответе нет ни одной SSE-строки — вот начало тела:"
    head -c 400 "$raw" | sed 's/^/       /'; echo
    return 0
  fi
  info "разбор потока (разрешение 1 с, EPOCHSECONDS):"
  sed 's/^/       /' "${tsv}.stream"
  info "стена запроса: $((t1 - t0)) с"
  local ttf tot ch cnt rsn ka
  ttf=$(sed -n 's/^ttft_s=//p' "${tsv}.stream"); ttf=${ttf:-0}
  tot=$(sed -n 's/^total_s=//p' "${tsv}.stream"); tot=${tot:-0}
  ch=$(sed -n 's/^chunks=//p' "${tsv}.stream"); ch=${ch:-0}
  cnt=$(sed -n 's/^content_chunks=//p' "${tsv}.stream"); cnt=${cnt:-0}
  rsn=$(sed -n 's/^reasoning_chunks=//p' "${tsv}.stream"); rsn=${rsn:-0}
  ka=$(sed -n 's/^keepalive=//p' "${tsv}.stream"); ka=${ka:-0}
  if [ "$ttf" -gt 0 ]; then
    info "TTFT = ${ttf} с (холодный prefill: справочник ~2100 tok/s, 131k токенов за ~62 с)"
  fi
  if [ "$ch" -gt 0 ] && [ $((tot - ttf)) -gt 0 ]; then
    info "генерация: ${ch} чанков (content ${cnt}, размышлений ${rsn}, keepalive ${ka}) за $((tot - ttf)) с ≈ $((ch / (tot - ttf))) чанк/с (в бою 49–105 tok/s, медиана 76.9)"
  fi
  if [ "$rsn" -gt 0 ]; then
    note "чанки размышлений есть (${rsn}) — при xhigh это норма; пауза считается по всему потоку, а не только по content"
  fi
  local gap; gap=$(sed -n 's/^max_gap_s=//p' "${tsv}.stream")
  if [ "${gap:-0}" -ge 30 ]; then
    warn "в потоке была пауза ${gap} с (после чанка №$(sed -n 's/^max_gap_after_chunk=//p' "${tsv}.stream")) — это и есть «перестаёт отвечать»"
  elif [ "${gap:-0}" -ge 5 ]; then
    warn "пауза ${gap} с внутри потока"
  else
    pass "пауз длиннее 5 с в потоке не было (максимум ${gap:-0} с)"
  fi

  print_summaries "$tsv"
}

# --- 8. как читать -----------------------------------------------------------
sec_read() {
  section "8. Как читать результат"
  cat <<'TXT'
  · usage_ratio → 1 и выросший queue_waited_total при спокойной памяти
      → новые ходы ждут ПОЗИЦИИ в KV-пуле (прежние разговоры держат регионы).
        Это про HALOGEN_KV_POOL_POSITIONS / HALOGEN_KV_SLOTS, а не про RAM.
  · Mlocked ≈ 0 + растущий pgscan_direct/compact_stall + PSI memory >10%
      → механизм №2: ядро отдаёт страницы весов под таблицу. Правка —
        HALOGEN_WEIGHTS_LOCK=1 (+ memlock unlimited в limits.conf, перелогин)
        и vm.compact_unevictable_allowed=0.
  · PSI io высокий, pgmajfault растёт, память в порядке
      → таблица читается с диска: RAM съеден пулом. Правка — HALOGEN_KV8=1
        (тот же пул вдвое дешевле) или HALOGEN_HOST_RESERVE_GIB выше.
  · строки `blocked for more than 120 seconds` / `amdgpu ... reset` в журнале
      → это не память: драйвер/железо. Смотреть amdgpu.noretry в cmdline
        (он превращает ошибку в молчаливый движок) и GTT после kill.
  · GTT занят при незапущенном halogen
      → удержанный мёртвым процессом GTT, поможет только перезагрузка
        (troubleshooting.md:57-92). До решения — не полагаться на restart policy.
  · пробы «ещё жив ли» долгие или не-200, а память спокойная
      → ход упирается в очередь/слоты, а не в хост: см. HALOGEN_ADMIT_CHUNK
        (у нас HALOGEN_MAX_TOK=16384 уже делит паузу пополам).
  · всё спокойно и в потоке пауз нет
      → столл не воспроизвёлся; гонять --load, когда агенты реально работают.
TXT
}

# --- сборка ------------------------------------------------------------------
[ -n "$OUTDIR" ] || OUTDIR=.
printf '%s=== diag-stall: диагностика зависаний halogen-stack ===%s\n' "$C_B" "$C_0"
info "хост: $(uname -s -r)  время: $(date -Is)  пользователь: $(id -un)"
info "базовый адрес: $BASE"

if [ "$DO_PASSIVE" = 1 ]; then
  sec_host
  sec_memory
  sec_gpu
  sec_journal
  sec_log
  sec_api
fi
if [ "$WATCH" != 0 ]; then
  resolve_key || info "без ключа пробы генерации не пойдут"
  sec_watch
elif [ "$DO_LOAD" = 1 ]; then
  resolve_key || info "без ключа нагрузка пропускается"
  sec_load
fi

section "Итог"
printf '  PASS %d · FAIL %d · SKIP %d\n' "$N_PASS" "$N_FAIL" "$N_SKIP"
printf '  Это диагностика, а не чек-лист: FAIL здесь = найденный механизм, а не поломка стека.\n'

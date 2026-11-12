#!/usr/bin/env bash
# halogen-stack — автоматическая версия проверок из docs/server-test-checklist.md.
#
# Покрывает всё, что поддаётся автоматизации: §A (запуск), §A1 (регрессии после
# обновления образа), §B (изоляция), §C (функции) и локальную часть §E
# (публичный путь подстановкой Host). Что не поддаётся — помечает SKIP с
# объяснением: скорость и доля кэша промптов требуют нагрузки, крах при
# конкурентных strict tool calls (§A1) наблюдается только в бою, а §D меняет
# конфигурацию — его скрипт не трогает.
#
# Запуск — на сервере, от обычного пользователя podman, из каталога проекта:
#   bash scripts/check.sh                      # все секции
#   bash scripts/check.sh -s A,B               # только секции A и B
#   bash scripts/check.sh --key-name agent1    # какой ключ брать из keys.acl
#   CHECK_KEY=... bash scripts/check.sh        # ключ прямо в окружении
#   bash scripts/check.sh --no-llm             # не гонять генерацию (дешевле)
#   bash scripts/check.sh --self-test          # самопроверка хелперов, без сети
#   bash scripts/check.sh -v                   # печатать каждый HTTP-запрос
#
# Ключи берутся из окружения и файлов конфига, в таком порядке:
#   1. CHECK_KEY            — значение ключа прямо в окружении
#   2. --key-name NAME      — запись `NAME:ключ` из secrets/keys.acl
#   3. первый не-webui ключ из secrets/keys.acl
#   4. WEBUI_SERVICE_KEY    — из окружения или .env (сервисный ключ web-ui)
# Значения ключей не печатаются никогда, в том числе в -v.
#
# Настройки читаются из окружения (оно побеждает) и из .env — как их читает
# podman-compose: LAN_IP, PUBLIC_DOMAIN, SECRETS_DIR, CERTS_DIR,
# WEBUI_SERVICE_KEY, HALOGEN_CACHE_DIR_HOST.
#
# Скрипт ничего не меняет: читает состояние контейнеров и дёргает HTTP.

set -uo pipefail

# --- каталог проекта (чтобы запуск работал из любой директории) ---------------
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd -- "$ROOT" || exit 1

# --- опции -------------------------------------------------------------------
SECTIONS="A,A1,B,C,E"
KEY_NAME=""
NO_LLM=0
VERBOSE=0
SELFTEST=0
TIMEOUT=15
ENV_FILE=".env"
PODMAN=${PODMAN:-podman}
BASE=""              # пусто = http://LAN_IP:8731
EXPECTED_VERSION=""  # пусто = версия из compose.yaml

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--sections) SECTIONS=${2:?нужно перечислить секции, например A,B}; SECTIONS=${SECTIONS//[[:space:]]/}; shift 2 ;;
    -k|--key-name) KEY_NAME=${2:?}; shift 2 ;;
    -b|--base)     BASE=${2:?}; shift 2 ;;
    -t|--timeout)  TIMEOUT=${2:?}; shift 2 ;;
    --no-llm)      NO_LLM=1; shift ;;
    -v|--verbose)  VERBOSE=1; shift ;;
    --self-test)   SELFTEST=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "неизвестный аргумент: $1 (--help)" >&2; exit 2 ;;
  esac
done

# --- вывод -------------------------------------------------------------------
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

# ожидаемый код ответа
expect_code() { # $1=что проверяем $2=ожидаемый код $3=полученный
  if [ "$2" = "$3" ]; then pass "$1 (код $3)"; else fail "$1: ждали $2, получили $3"; fi
}

want_section() { case ",$SECTIONS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# --- чтение конфигурации -----------------------------------------------------
# Значение из .env без исполнения файла (в .env может оказаться что угодно).
# Шаблон терпим к `export KEY=`, пробелам вокруг `=`, кавычкам и CRLF — как
# guard в Makefile и podman-compose.
dotenv_get() { # $1=имя
  [ -f "$ENV_FILE" ] || return 1
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" \
    | tail -n 1 \
    | tr -d '\r' \
    | sed -E 's/[[:space:]]+$//' \
    | sed -E 's/^"(.*)"$/\1/' \
    | sed -E "s/^'(.*)'\$/\1/"
}

# значение переменной: окружение побеждает .env (так же делает podman-compose)
cfg_get() { # $1=имя
  local v=${!1-}
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  dotenv_get "$1"
}

# --- ключ --------------------------------------------------------------------
KEY=""
KEY_SOURCE=""
keys_file_path() {
  local sd
  sd=$(cfg_get SECRETS_DIR); sd=${sd:-./secrets}
  printf '%s/keys.acl' "${sd%/}"
}

# значение ключа по имени из keys.acl (ничего не печатает)
key_by_name() { # $1=имя $2=файл
  awk -F: -v n="$1" '!/^[[:space:]]*#/ && NF>1 && $1==n { sub(/^[^:]*:/, ""); gsub(/[[:space:]]/, ""); print; exit }' "$2" 2>/dev/null
}

first_agent_key_name() { # $1=файл
  awk -F: '!/^[[:space:]]*#/ && NF>1 && $1!="webui" { print $1; exit }' "$1" 2>/dev/null
}

resolve_key() {
  if [ -n "${CHECK_KEY:-}" ]; then KEY=$CHECK_KEY; KEY_SOURCE="окружение CHECK_KEY"; return 0; fi
  local kf; kf=$(keys_file_path)
  if [ -n "$KEY_NAME" ]; then
    if [ ! -f "$kf" ]; then fail "ключей нет в $kf — а запрошен --key-name $KEY_NAME"; return 1; fi
    KEY=$(key_by_name "$KEY_NAME" "$kf")
    if [ -z "$KEY" ]; then
      fail "записи '$KEY_NAME' нет в $kf (имена: $(cut -d: -f1 "$kf" | grep -v '^#' | tr '\n' ' '))"
      return 1
    fi
    KEY_SOURCE="$KEY_NAME из $kf"; return 0
  fi
  if [ -f "$kf" ]; then
    local n; n=$(first_agent_key_name "$kf")
    if [ -n "$n" ]; then KEY=$(key_by_name "$n" "$kf"); KEY_SOURCE="$n из $kf"; return 0; fi
  fi
  local w; w=$(cfg_get WEBUI_SERVICE_KEY)
  if [ -n "$w" ]; then KEY=$w; KEY_SOURCE="WEBUI_SERVICE_KEY (сервисный ключ web-ui)"; return 0; fi
  fail "не удалось найти ни один ключ: задайте CHECK_KEY, или --key-name NAME, или make key-add NAME=agent1"
  return 1
}

# --- HTTP --------------------------------------------------------------------
# Все вызовы идут через эти обёртки; заголовок с ключом подставляется здесь и
# наружу не печатается.
http_code() { # $@ = аргументы curl (URL последним)
  local code
  code=$(curl -s -o /dev/null --max-time "$TIMEOUT" -w '%{http_code}' "$@" 2>/dev/null)
  printf '%s' "${code:-000}"
}
api_code() {
  [ "$VERBOSE" = 1 ] && note "curl $* (ключ подставлен)"
  http_code -H "Authorization: Bearer $KEY" "$@"
}
http_body() { curl -s --max-time "$TIMEOUT" "$@" 2>/dev/null; }
api_body() {
  [ "$VERBOSE" = 1 ] && note "curl $* (ключ подставлен)"
  http_body -H "Authorization: Bearer $KEY" "$@"
}

container_state() { $PODMAN inspect -f '{{.State.Status}}' "$1" 2>/dev/null; }

# Есть ли в web-ui python — им мы проверяем egress изнутри контейнера. Без этой
# проверки «python не запустился» неотличим от «python запустился и его не пустили»:
# обе ветки дают ненулевой код возврата, и проверка прямого пути наружу
# проходила бы по неверной причине.
webui_py_probe() { $PODMAN exec halogen-web-ui python -c 'print(1)' 2>/dev/null | tail -n 1; }

model_id() { api_body "$BASE/v1/models" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4; }

# --- секции ------------------------------------------------------------------
sec_A() {
  section "A. Запуск"

  # .env и LAN_IP
  local lan; lan=$(cfg_get LAN_IP)
  if [ -z "$lan" ]; then
    fail "LAN_IP не задан ни в окружении, ни в $ENV_FILE — нечем проверять bind"
  elif [ "$lan" = "0.0.0.0" ] || [ "$lan" = "127.0.0.1" ]; then
    fail "LAN_IP=$lan — публикация 8731 на всех адресах или только на loopback; нужен адрес LAN-интерфейса"
  else
    pass "LAN_IP=$lan (окружение/$ENV_FILE)"
  fi
  info "базовый адрес проверок: $BASE"

  # контейнеры
  local c state bad="" n=0
  for c in halogen-flash-server halogen-reverse-proxy halogen-auth-provider halogen-web-ui halogen-egress-proxy; do
    state=$(container_state "$c")
    if [ "$state" = "running" ]; then n=$((n+1)); else bad="$bad $c(${state:-нет})"; fi
  done
  if [ -z "$bad" ]; then pass "все 5 контейнеров running"; else fail "не поднялись:$bad"
  fi

  # healthcheck auth-provider
  local hs; hs=$($PODMAN inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' halogen-auth-provider 2>/dev/null)
  case "$hs" in
    healthy) pass "internal-auth-provider healthy" ;;
    "")      skip "у auth-provider нет healthcheck-секции" ;;
    *)       fail "internal-auth-provider: $hs (ждём healthy, ~30 с после старта)" ;;
  esac

  # версия образа
  local want got body
  want=${EXPECTED_VERSION:-$(sed -n 's|.*halogen-flash-server:\([0-9][0-9.]*\).*|\1|p' compose.yaml | head -n 1)}
  body=$(http_body "$BASE/healthz")
  got=$(printf '%s' "$body" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n 1)
  if [ -z "$body" ]; then
    fail "/healthz не отвечает по $BASE (стек не поднялся или адрес неверный)"
  elif [ -n "$want" ] && [ "$got" = "$want" ]; then
    pass "версия halogen $got совпадает с пином в compose.yaml"
  else
    fail "версия halogen: в ответе '$got', в compose.yaml пин '$want'"
  fi

  # Дисковый prompt-кэш (решение 2026-11-12): включён и лежит на выделенном
  # диске. ВНИМАНИЕ: до этой даты проверка требовала обратного (RAM-only,
  # решение 2026-10-28) — утверждения ниже инвертированы.
  local envjson mounts
  envjson=$($PODMAN inspect -f '{{json .Config.Env}}' halogen-flash-server 2>/dev/null)
  if printf '%s' "$envjson" | grep -q 'HALOGEN_FORK=0'; then
    pass "HALOGEN_FORK=0 в окружении контейнера"
  else
    fail "HALOGEN_FORK=0 не найден в окружении контейнера"
  fi
  if printf '%s' "$envjson" | grep -q 'HALOGEN_CACHE_DIR=/cache'; then
    pass "HALOGEN_CACHE_DIR=/cache — дисковый prompt-кэш включён"
  else
    fail "HALOGEN_CACHE_DIR=/cache не найден в окружении — дискового кэша нет (решение 2026-11-12)"
  fi
  # Лимит обязан быть задан и быть ненулевым: 0 = без границ, а дефолт 64 в
  # 2026-10-28 оказался больше свободного места — LRU не включился ни разу.
  local gib; gib=$(printf '%s' "$envjson" | grep -o 'HALOGEN_CACHE_DISK_GIB=[0-9]\+' | head -n 1 | cut -d= -f2)
  case "$gib" in
    ""|"0") fail "HALOGEN_CACHE_DISK_GIB='${gib:-не задан}' — без лимита поддерево не ограничено (у нас 640)" ;;
    *)      pass "HALOGEN_CACHE_DISK_GIB=$gib" ;;
  esac
  if printf '%s' "$envjson" | grep -q 'HALOGEN_CACHE_PRUNE_OLD=1'; then
    pass "HALOGEN_CACHE_PRUNE_OLD=1 — поддеревья старых сборок вычищаются на старте"
  else
    fail "HALOGEN_CACHE_PRUNE_OLD не включён — старые поддеревья после апгрейдов копятся незафиксированно"
  fi
  mounts=$($PODMAN inspect -f '{{json .Mounts}}' halogen-flash-server 2>/dev/null)
  if printf '%s' "$mounts" | grep -q '"Destination":"/cache"'; then
    pass "том /cache примонтирован"
  else
    fail "тома /cache нет — писать дисковому кэшу некуда"
  fi
  # Каталог на хосте: задан, существует и НЕ на разделе / (иначе повторится
  # сценарий 2026-10-28). Устройство сравниваем по df -P: /dev/mapper/… против
  # /dev/nvme0n1p1.
  local cachedir dev_root dev_cache
  cachedir=$(cfg_get HALOGEN_CACHE_DIR_HOST)
  if [ -z "$cachedir" ]; then
    fail "HALOGEN_CACHE_DIR_HOST не задан ни в окружении, ни в $ENV_FILE"
  elif [ ! -d "$cachedir" ]; then
    fail "каталога кэша нет: $cachedir (создать и chown — docs/admin-cache-disk.md)"
  else
    dev_root=$(df -P / 2>/dev/null | awk 'NR==2 {print $1}')
    dev_cache=$(df -P "$cachedir" 2>/dev/null | awk 'NR==2 {print $1}')
    if [ -z "$dev_cache" ]; then
      fail "не удалось определить устройство для $cachedir"
    elif [ "$dev_cache" = "$dev_root" ]; then
      fail "каталог кэша $cachedir лежит на разделе / ($dev_root) — нужен выделенный диск"
    else
      pass "каталог кэша $cachedir на устройстве $dev_cache (не /)"
      info "размер кэша: $(du -sh "$cachedir" 2>/dev/null | cut -f1) при лимите ${gib:-?} GiB"
    fi
  fi
  # Старый каталог в каталоге проекта — признак, что кэш снова пишет не туда.
  if [ -d ./cache ] && [ -n "$(ls -A ./cache 2>/dev/null)" ]; then
    fail "на хосте есть непустой ./cache ($(du -sh ./cache 2>/dev/null | cut -f1)) — кэш пишется в каталог проекта"
  else
    pass "старый ./cache в каталоге проекта не создаётся"
  fi

  # место на разделе (справочно: модели и логи тоже чего-то стоят)
  local used; used=$(df -P / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
  if [ -n "$used" ]; then
    if [ "$used" -ge 90 ]; then info "занято / : $used% — тесно"; else info "занято / : $used%"; fi
  fi

  # Лог старта читаем из НАЧАЛА лога контейнера, ошибки — из конца. `--tail 300`
  # для стартовых строк не годится: на загруженном сервере 300 строк — это
  # несколько минут работы, и warm start с 'listening on' уезжают из окна
  # (проверено 2026-11-09: в полном логе строки есть, в хвосте их уже нет).
  local log errlog
  log=$($PODMAN logs 2>&1 halogen-flash-server | head -n 200)
  errlog=$($PODMAN logs --tail 300 halogen-flash-server 2>&1)
  if printf '%s' "$log" | grep -q 'warm start'; then
    pass "warm start 0.18.23 в логе: $(printf '%s' "$log" | grep -m1 'warm start' | cut -c1-90)"
  else
    skip "строки 'warm start' в начале лога нет (если контейнер пересоздавали с ротацией логов — смотреть полный лог)"
  fi
  if printf '%s' "$log" | grep -qF 'listening on [::]'; then
    pass "двойной стек (0.19.0): $(printf '%s' "$log" | grep -m1 'listening on' | cut -c1-90)"
  else
    info "строки 'listening on [::]' в начале лога нет — на 0.19.0+ она обязана быть, проверьте полный лог"
  fi
  if printf '%s' "$log" | grep -q 'on_event'; then
    info "в логе осталось предупреждение on_event (в 0.19.1 его убрали)"
  fi
  if printf '%s' "$errlog" | grep -qiE 'hipError|HSA_STATUS_ERROR|out of memory|CUDA error'; then
    fail "в логе halogen есть строки про ошибки ROCm/HIP/память"
  else
    pass "ошибок ROCm/HIP/OOM в последних 300 строках лога нет"
  fi
}

sec_A1() {
  section "A1. Регрессии после обновления образа (0.19.1 / 0.20.0)"

  # Давление KV-пула и prompt-кэша за всю жизнь контейнера. Порог тревоги из
  # CLAUDE.md §5: вытеснение записей кэша вместе с пулом на 9x% означает, что
  # не хватает пула или слотов. Это не PASS/FAIL — размером пула решает человек,
  # здесь только цифры.
  local alllog forgot clamped poolmax
  alllog=$($PODMAN logs 2>&1 halogen-flash-server)
  forgot=$(printf '%s' "$alllog" | grep -c 'prompt cache: at its .*forgot')
  clamped=$(printf '%s' "$alllog" | grep -c 'cannot grow and nothing holds a move')
  poolmax=$(printf '%s' "$alllog" | grep -o 'pool [0-9]*/[0-9]* [0-9]*%' \
            | awk '{gsub("%","",$3); if ($3>m) m=$3} END {print m+0}')
  info "за жизнь контейнера: prompt-кэш вытеснил записей ${forgot:-0}, turn'ов с урезанным max_tokens ${clamped:-0}, пик пула ${poolmax:-0}%"
  if [ "${clamped:-0}" != "0" ]; then
    info "  'cannot grow' = генерации не хватило места, max_tokens урезан апстримом (вопрос о размере пула — §7)"
  fi

  if [ "$NO_LLM" = 1 ]; then skip "--no-llm: проверки с запросами пропущены"; return 0; fi
  if [ -z "$KEY" ]; then skip "нет ключа — проверки с запросами пропущены"; return 0; fi

  local model; model=$(model_id)
  if [ -z "$model" ]; then fail "/v1/models не вернул имя модели — дальше нечем проверять"; return 0; fi
  info "модель для тестов: $model"

  # 0.19.1: невалидная tool-схема = 400, слот не занят навсегда
  local body code
  body=$(printf '{"model":"%s","messages":[{"role":"user","content":"привет"}],"tools":[{"type":"function","function":{"name":"probe_tool","parameters":"не объект"}}]}' "$model")
  code=$(api_code -X POST -H 'content-type: application/json' -d "$body" "$BASE/v1/chat/completions")
  expect_code "битая tool-схема отклонена (фикс 0.19.1)" "400" "$code"

  body=$(printf '{"model":"%s","messages":[{"role":"user","content":"скажи ок"}],"max_tokens":8}' "$model")
  code=$(api_code -X POST -H 'content-type: application/json' -d "$body" "$BASE/v1/chat/completions")
  expect_code "обычный запрос сразу после битой схемы (слот свободен)" "200" "$code"

  skip "крах при конкурентных strict tool calls (0.20.0) — наблюдается только в бою, §A1"
  skip "скорость против прежних 67–73 t/s — нужен прогон Claude Code, §A1"
}

sec_B() {
  section "B. Изоляция"

  local lan; lan=$(cfg_get LAN_IP)

  # слушатели на хосте
  if command -v ss >/dev/null 2>&1; then
    local addrs on8731="" bad="" a host ok
    addrs=$(ss -ltnH 2>/dev/null | awk '{print $4}')
    for a in $addrs; do
      case "$a" in
        *:8731) on8731="$on8731 $a" ;;
        *:8080|*:3128|*:9000) bad="$bad $a" ;;
      esac
    done
    if [ -z "$on8731" ]; then
      fail "на хосте вообще нет слушателя :8731"
    else
      ok=1
      for a in $on8731; do
        host=${a%:8731}
        if [ -z "$lan" ] || [ "$host" != "$lan" ]; then ok=0; fi
      done
      if [ "$ok" = 1 ]; then pass "8731 слушает только$on8731"
      else fail "8731 слушает не только LAN_IP:$on8731 (ожидался $lan)"; fi
    fi
    if [ -z "$bad" ]; then pass "наружу не светятся 8080/3128/9000"
    else fail "на хосте слушают порты, которых быть не должно:$bad"; fi
  else
    skip "нет ss — проверку слушателей пропустить"
  fi

  # сети podman
  local nets n wan inwan
  nets=$($PODMAN network ls --format '{{.Name}}' 2>/dev/null | grep -E '^halogen-stack[-_]')
  if [ -z "$nets" ]; then
    skip "сетей проекта (halogen-stack_*) не найдено — стек не поднят?"
  else
    for n in $nets; do
      if $PODMAN network inspect "$n" 2>/dev/null | tr -d '[:space:]' | grep -q '"internal":true'; then
        pass "$n — internal (без шлюза)"
      else
        case "$n" in
          *wan*) info "$n — со шлюзом (так и задумано: в ней только squid)" ;;
          *)     fail "$n — НЕ internal: у участников есть путь наружу" ;;
        esac
      fi
    done
    wan=$(printf '%s\n' "$nets" | grep 'wan' | head -n 1)
    if [ -n "$wan" ]; then
      inwan=$($PODMAN ps --filter "network=$wan" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
      if [ -z "$inwan" ]; then
        skip "не удалось список участников $wan (фильтр podman ps не сработал)"
      elif [ "$inwan" = "halogen-egress-proxy " ]; then
        pass "в $wan только halogen-egress-proxy"
      else
        fail "в $wan контейнеры: $inwan — ждём только halogen-egress-proxy"
      fi
    fi
  fi

  # изоляция самих контейнеров
  local py_ok=0
  if [ "$(container_state halogen-web-ui)" = "running" ]; then
    [ "$(webui_py_probe)" = "1" ] && py_ok=1
  fi
  if [ "$py_ok" != 1 ]; then
    skip "в web-ui нет python (или контейнер не поднят) — проверки egress изнутри пропустить"
  elif $PODMAN exec halogen-web-ui python -c "import socket;socket.create_connection(('1.1.1.1',443),4)" >/dev/null 2>&1; then
    fail "web-ui достал до 1.1.1.1:443 — у него появился прямой путь наружу"
  else
    pass "web-ui не достаёт наружу напрямую"
  fi
  if [ "$(container_state halogen-flash-server)" = "running" ]; then
    if $PODMAN exec halogen-flash-server cat /proc/net/route 2>/dev/null \
       | awk 'NR>1 && $2=="00000000" { found=1 } END { exit !found }'; then
      fail "у halogen есть маршрут по умолчанию — он видит LAN/интернет"
    else
      pass "у halogen нет маршрута по умолчанию (внутренняя сеть)"
    fi
  else
    skip "halogen не запущен — проверку маршрута пропустить"
  fi

  # forward-auth
  expect_code "/v1/models без ключа"       "401" "$(http_code "$BASE/v1/models")"
  expect_code "/v1/models с bogus-ключом"  "401" "$(http_code -H 'Authorization: Bearer bogus-000' "$BASE/v1/models")"
  expect_code "голый /v1 идёт в API, а не в web-ui" "401" "$(http_code "$BASE/v1")"
  if [ -n "$KEY" ]; then
    expect_code "/v1/models с валидным ключом"    "200" "$(api_code "$BASE/v1/models")"
    expect_code "query-строка '/v1/models?'"      "200" "$(api_code "$BASE/v1/models?")"
    expect_code "query-строка '/v1/models?x=1'"   "200" "$(api_code "$BASE/v1/models?x=1")"
    expect_code "без ключа и с query (регрессия 404)" "401" "$(http_code "$BASE/v1/models?x=1")"
  else
    skip "нет ключа — позитивную часть forward-auth пропущено"
  fi

  # health-маршруты: /healthz → halogen (в Caddy rewrite на /health), /health →
  # web-ui (catch-all handle). Заголовком Server они НЕ различаются: оба
  # приложения — FastAPI/uvicorn, и у обоих в ответе «Server: uvicorn»
  # (web-ui запускается через uvicorn.run,
  # /docs/open-webui/backend/open_webui/__init__.py:86). На этом первая версия
  # проверки и попадалась: она выдавала FAIL, когда всё в порядке.
  # Различаем телом ответа: у halogen в /health версия и служебные поля
  # (/docs/halogen-flash-server/docs/api.md:69), у web-ui — строго
  # {"status":true} (/docs/open-webui/backend/open_webui/main.py:3077).
  expect_code "/healthz открыт с LAN-пути" "200" "$(http_code "$BASE/healthz")"
  local hz h hz_ver
  hz=$(http_body "$BASE/healthz")
  h=$(http_body "$BASE/health")
  hz_ver=$(printf '%s' "$hz" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n 1)
  if [ -z "$hz" ]; then
    info "у /healthz пустой ответ — различать маршруты нечем"
  elif [ -n "$hz_ver" ]; then
    pass "/healthz отвечает halogen (в теле версия $hz_ver)"
  else
    fail "/healthz отвечает не halogen — в теле нет версии: $(printf '%s' "$hz" | head -c 70)"
  fi
  case "$h" in
    *'"status"'*) pass "/health — web-ui, а не halogen (в теле {\"status\":…})" ;;
    "")           info "/health не отвечает — web-ui поднят?" ;;
    *)            if [ -n "$hz" ] && [ "$h" = "$hz" ]; then
                    fail "/health и /healthz отдают одно и то же — оба уходят в halogen, разматч сломался"
                  else
                    info "у /health непривычный отклик: $(printf '%s' "$h" | head -c 70)"
                  fi ;;
  esac

  # egress squid: пустой whitelist. Оценивать нужно КОД ответа, а не то, упало ли
  # приложение: requests.get() не бросает исключение на 403 — страница отказа
  # squid это обычный ответ с кодом 403. Первая версия проверки («упал ли
  # запрос») считала отказ успехом и проваливалась ложно. HTTP и CONNECT
  # проверяем раздельно: для туннелей в squid отдельное правило
  # `allow CONNECT allowed_sites` (config/squid/squid.conf:29), и внутри
  # туннеля Content-Type уже не фильтруется.
  local wl
  wl=$(grep -v '^[[:space:]]*#' config/squid/whitelist.txt 2>/dev/null | grep -c '[^[:space:]]')
  if [ "${wl:-0}" != "0" ]; then
    skip "в whitelist $wl записей — проверку пустого whitelist прогонять на пустом"
  elif [ "$py_ok" != 1 ]; then
    skip "в web-ui нет python/requests — проверку squid изнутри контейнера пропустить"
  else
    local py_http py_https code code_tls
    py_http='import requests
print(requests.get("http://example.org", timeout=10).status_code)'
    py_https='import requests
try:
    print("tunnel:" + str(requests.get("https://example.org", timeout=10).status_code))
except requests.exceptions.ProxyError:
    print("refused")
except requests.exceptions.RequestException as e:
    print("other:" + type(e).__name__)'
    code=$($PODMAN exec halogen-web-ui python -c "$py_http" 2>/dev/null | tail -n 1)
    case "$code" in
      403)  pass "пустой whitelist: squid отклонил GET example.org (403)" ;;
      200)  fail "пустой whitelist: squid ПРОПУСТИЛ example.org (200) — фильтр не работает" ;;
      "")   info "example.org через squid: ответа нет — прокси недоступен из web-ui?" ;;
      *)    info "example.org через squid: неожиданный код $code" ;;
    esac
    code_tls=$($PODMAN exec halogen-web-ui python -c "$py_https" 2>/dev/null | tail -n 1)
    case "$code_tls" in
      refused)    pass "пустой whitelist: squid отклонил и CONNECT (TLS-туннель на 443)" ;;
      tunnel:200) fail "пустой whitelist: squid пустил TLS-туннель в example.org — allow CONNECT слишком широкий" ;;
      tunnel:*)   info "CONNECT example.org прошёл, ответ источника: $code_tls" ;;
      other:*)    info "CONNECT example.org: туннель не открылся по причине ${code_tls#other:} (проверить маршрут squid наружу)" ;;
      *)          info "CONNECT example.org: непонятный результат '$code_tls'" ;;
    esac
  fi

  # справочно: SELinux на сервере нет (AppArmor), см. CLAUDE.md §5
  if [ -e /sys/fs/selinux ]; then
    info "SELinux включён — чек-лист писался для хоста без него"
  else
    info "SELinux выключен (как и ожидается)"
  fi
}

sec_C() {
  section "C. Функции"

  if [ "$NO_LLM" = 1 ] || [ -z "$KEY" ]; then
    skip "проверки генерации пропущены (--no-llm или нет ключа)"
  else
    local model; model=$(model_id)
    if [ -z "$model" ]; then
      fail "/v1/models не вернул имя модели"
    else
      # SSE сквозь reverse-proxy: кадры приходят, а не пачка в конце
      local stream body
      body=$(printf '{"model":"%s","messages":[{"role":"user","content":"посчитай 1 2 3"}],"stream":true,"max_tokens":24}' "$model")
      stream=$(curl -sN --max-time 60 -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
               -d "$body" "$BASE/v1/chat/completions" 2>/dev/null | head -c 4000)
      if printf '%s' "$stream" | grep -q '^data:'; then
        pass "SSE идёт потоком (есть кадры data:)"
      else
        fail "SSE: в ответе нет кадров 'data:' — стриминг сквозь reverse-proxy сломан"
      fi
      # Anthropic-совместимый вход, которым пользуется Claude Code
      local code
      code=$(curl -s -o /dev/null --max-time 60 -w '%{http_code}' -H "x-api-key: $KEY" \
             -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
             -d "$(printf '{"model":"%s","max_tokens":8,"messages":[{"role":"user","content":"ок"}]}' "$model")" \
             "$BASE/v1/messages")
      expect_code "/v1/messages по x-api-key (путь Claude Code)" "200" "$code"
    fi
  fi

  # лог web-ui: OFFLINE_MODE и отсутствие резов egress
  if [ "$(container_state halogen-web-ui)" = "running" ]; then
    local wlog
    wlog=$($PODMAN logs --tail 400 halogen-web-ui 2>&1)
    if printf '%s' "$wlog" | grep -qE 'ProxyError|403 Forbidden'; then
      fail "в логе web-ui есть ProxyError/403 — кто-то из web-ui пытается наружу"
    else
      pass "в логе web-ui нет ProxyError/403"
    fi
    if printf '%s' "$wlog" | grep -qi 'Offline mode enabled'; then
      pass "OFFLINE_MODE подтверждён логом"
    else
      skip "строки 'Offline mode enabled' в последних 400 строках нет — рестартуйте web-ui, чтобы увидеть старт"
    fi
    if printf '%s' "$wlog" | grep -qi 'MiniLM'; then
      pass "эмбеддинг-модель грузится локально (RAG-встраивания живы)"
    else
      info "упоминания MiniLM в последних 400 строках нет — это нормально, если web-ui давно не перезапускался"
    fi
  else
    skip "web-ui не запущен — проверки его лога пропущены"
  fi
}

sec_E() {
  section "E. Публичный путь (локально, подстановкой Host)"

  local pub; pub=$(cfg_get PUBLIC_DOMAIN); pub=${pub:-ai.dda2543.ru}
  info "публичное имя: $pub"
  expect_code "/healthz с публичным Host запрещён"   "403" "$(http_code -H "Host: $pub" "$BASE/healthz")"
  expect_code "/v1/models с публичным Host запрещён" "403" "$(http_code -H "Host: $pub" "$BASE/v1/models")"
  expect_code "тот же /healthz без заголовка — 200"  "200" "$(http_code "$BASE/healthz")"

  if [ "$(container_state halogen-waf)" = "running" ]; then
    info "waf-firewall поднят: наружную часть §E (TLS, CRS, сертификат) скрипт не проверяет — см. чек-лист"
  else
    skip "waf-firewall не поднят — фаза 2 выключена, наружную §E проверять не на чём"
  fi
  local certs; certs=$(cfg_get CERTS_DIR); certs=${certs:-./secrets/certs}
  if [ -d "$certs" ] && [ -n "$(ls -A "$certs" 2>/dev/null)" ]; then
    info "сертификаты в $certs лежат"
  else
    info "в $certs пусто — сертификат не выпускался (certbot --standalone требует открытый :80)"
  fi
}

# --- самопроверка хелперов ---------------------------------------------------
selftest() {
  local tdir rc=0 v
  tdir=$(mktemp -d) || { echo "  BAD mktemp не сработал"; return 1; }
  printf 'LAN_IP=10.0.0.1\nexport WEBUI_SERVICE_KEY = "quoted-key" \n# LAN_IP=1.2.3.4\nSINGLE=\x27sq\x27\n' > "$tdir/.env"
  printf '# комментарий\nwebui:aaa\nagent1:bbb\nagent2:ccc\n' > "$tdir/keys.acl"

  local save_env=$ENV_FILE
  ENV_FILE="$tdir/.env"

  v=$(dotenv_get LAN_IP);          [ "$v" = "10.0.0.1" ] && echo "  ok  dotenv: обычная запись" || echo "  BAD dotenv: обычная запись (получено '$v')"; [ "$v" = "10.0.0.1" ] || rc=1
  v=$(dotenv_get WEBUI_SERVICE_KEY); [ "$v" = "quoted-key" ] && echo "  ok  dotenv: export + пробелы + кавычки" || echo "  BAD dotenv: export/пробелы/кавычки (получено '$v')"; [ "$v" = "quoted-key" ] || rc=1
  v=$(dotenv_get SINGLE);          [ "$v" = "sq" ] && echo "  ok  dotenv: одинарные кавычки" || echo "  BAD dotenv: одинарные кавычки (получено '$v')"; [ "$v" = "sq" ] || rc=1
  v=$(dotenv_get NOPE);            [ -z "$v" ] && echo "  ok  dotenv: нет ключа → пусто" || echo "  BAD dotenv: отсутствующий ключ"; [ -z "$v" ] || rc=1
  LAN_IP=9.9.9.9
  v=$(cfg_get LAN_IP);             [ "$v" = "9.9.9.9" ] && echo "  ok  cfg_get: окружение побеждает .env" || echo "  BAD cfg_get: приоритет окружения (получено '$v')"; [ "$v" = "9.9.9.9" ] || rc=1
  unset LAN_IP
  v=$(cfg_get LAN_IP);             [ "$v" = "10.0.0.1" ] && echo "  ok  cfg_get: без окружения — .env" || echo "  BAD cfg_get: фолбэк на .env (получено '$v')"; [ "$v" = "10.0.0.1" ] || rc=1
  v=$(first_agent_key_name "$tdir/keys.acl"); [ "$v" = "agent1" ] && echo "  ok  keys.acl: первый не-webui" || echo "  BAD keys.acl: выбор имени (получено '$v')"; [ "$v" = "agent1" ] || rc=1
  v=$(key_by_name agent2 "$tdir/keys.acl");   [ "$v" = "ccc" ] && echo "  ok  keys.acl: значение по имени" || echo "  BAD keys.acl: значение (получено '$v')"; [ "$v" = "ccc" ] || rc=1
  v=$(key_by_name nope "$tdir/keys.acl");     [ -z "$v" ] && echo "  ok  keys.acl: нет записи → пусто" || echo "  BAD keys.acl: отсутствующая запись"; [ -z "$v" ] || rc=1

  ENV_FILE=$save_env
  rm -rf "$tdir"
  return $rc
}

# --- main --------------------------------------------------------------------
if [ "$SELFTEST" = 1 ]; then
  printf '%sСамопроверка хелперов%s\n' "$C_B" "$C_0"
  selftest
  rc=$?
  if [ $rc = 0 ]; then echo "  всё сошлось"; else echo "  ЕСТЬ РАСХОЖДЕНИЯ"; fi
  exit $rc
fi

for tool in curl podman; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "нужен $tool — запустите скрипт на сервере" >&2
    exit 2
  fi
done

# базовый адрес: явный --base, иначе LAN_IP из окружения/.env
if [ -z "$BASE" ]; then
  LAN_NOW=$(cfg_get LAN_IP)
  BASE="http://${LAN_NOW}:8731"
fi

printf '%shalogen-stack: проверки из docs/server-test-checklist.md%s\n' "$C_B" "$C_0"
printf 'каталог: %s · секции: %s\n' "$ROOT" "$SECTIONS"

if ! resolve_key; then
  info "проверки, которым нужен ключ, будут пропущены"
elif [ -n "$KEY" ]; then
  info "ключ для тестов: $KEY_SOURCE (значение не печатается)"
fi

want_section A  && sec_A
want_section A1 && sec_A1
want_section B  && sec_B
want_section C  && sec_C
want_section E  && sec_E

printf '\n%sИтог:%s PASS %d · FAIL %d · SKIP %d\n' "$C_B" "$C_0" "$N_PASS" "$N_FAIL" "$N_SKIP"
if [ "$N_FAIL" != 0 ]; then
  printf '%sЕсть проваленные проверки — см. строки FAIL выше%s\n' "$C_R" "$C_0"
  exit 1
fi
exit 0

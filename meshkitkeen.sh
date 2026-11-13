#!/bin/sh
# ============================================================================
#  MeshkitKeen — управление mesh-сетью Keenetic с одного терминала
# ============================================================================
#  Форк KeenKit (spatiumstas/KeenKit, v2.9.5) с неинтерактивным режимом и
#  управлением mesh-узлами (ретрансляторами / экстендерами).
#
#  Запускается на ГОЛОВНОМ (контроллере) роутере. Читает список mesh-узлов
#  через RCI (show/mws/member) и выполняет операции на узлах через SSH
#  (dropbear :222) по ключу.
#
#  Лицензия: MIT (см. LICENSE).  Никакие пароли/ключи не хранятся в репозитории.
# ============================================================================

# --- Константы и переменные ------------------------------------------------
SCRIPT="meshkitkeen.sh"
SCRIPT_VERSION="1.0.0"
REPO="MeshkitKeen"
GITHUB_USER="Chistovik92"
BRANCH="main"
PAGES_URL="https://$GITHUB_USER.github.io/$REPO"

TMP_DIR="/tmp"
OPT_DIR="/opt"
CONFIG_FILE="$OPT_DIR/etc/$REPO.conf"
KEY_DIR="$OPT_DIR/etc/$REPO"
SSH_KEY="$KEY_DIR/id_ed25519"
STORAGE_DIR="/storage"

RCI_BASE="http://127.0.0.1:79/rci"

# Значения по умолчанию (перекрываются конфигом)
SSH_USER="root"
SSH_PORT="222"
OTA_DOMAIN=""

DATE=$(date +%Y-%m-%d_%H-%M)

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

trap cleanup HUP INT TERM EXIT

# ============================================================================
#  Конфиг
# ============================================================================
load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  # Читаем только известные ключи (безопасный разбор key="value")
  local key val
  while IFS='=' read -r key val; do
    case "$key" in
      domain)   OTA_DOMAIN=$(printf '%s' "$val" | sed 's/^"//; s/"$//') ;;
      ssh_user) SSH_USER=$(printf '%s' "$val" | sed 's/^"//; s/"$//') ;;
      ssh_port) SSH_PORT=$(printf '%s' "$val" | sed 's/^"//; s/"$//') ;;
    esac
  done < "$CONFIG_FILE"
  [ -n "$SSH_USER" ] || SSH_USER="root"
  [ -n "$SSH_PORT" ] || SSH_PORT="222"
}

# ============================================================================
#  Вспомогательные утилиты
# ============================================================================
rci_request() {
  curl -s "$RCI_BASE/$1"
}

rci_parse() {
  local body="$1"
  case "$body" in
    \{* | \[*) ;;
    *) body="[{\"parse\":\"$body\"}]" ;;
  esac
  curl -fsS -H "Content-Type: application/json" -d "$body" "$RCI_BASE/"
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  packages_checker "jq"
  command -v jq >/dev/null 2>&1
}

json_get_value() {
  local json="$1" query="$2"
  ensure_jq || return 1
  [ -n "$json" ] || return 1
  printf '%s\n' "$json" | jq -r "$query // empty" 2>/dev/null
}

format_size() {
  awk -v used="$1" -v total="$2" 'BEGIN {
    mb = 1024 * 1024
    gb = mb * 1024
    total_gb = int(total / gb * 100) / 100
    if (total < gb)
      printf "%d / %d MB", used / mb, total / mb
    else if (used < gb)
      printf "%d MB / %.2f GB", used / mb, total_gb
    else {
      used_gb = int(used / gb * 100) / 100
      printf "%.2f / %.2f GB", used_gb, total_gb
    }
  }'
}

format_uptime_seconds() {
  local uptime=$1
  if [ -z "$uptime" ] || ! echo "$uptime" | grep -qE '^[0-9]+$'; then
    printf 'n/a'
    return
  fi
  local days=$((uptime / 86400))
  local hours=$(((uptime % 86400) / 3600))
  local minutes=$(((uptime % 3600) / 60))
  if [ "$days" -gt 0 ]; then
    printf "%dд %02d:%02d" "$days" "$hours" "$minutes"
  else
    printf "%02d:%02d:%02d" "$hours" "$minutes" "$((uptime % 60))"
  fi
}

print_message() {
  local message="$1"
  local color="${2:-$NC}"
  local border=$(printf '%0.s-' $(seq 1 $((${#message} + 2))))
  printf "${color}\n+${border}+\n| ${message} |\n+${border}+\n${NC}\n"
}

# --- Пакеты (минимальная версия, не удаляет) -------------------------------
packages_checker() {
  local missing=""
  for pkg in "$@"; do
    if ! opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
      missing="$missing $pkg"
    fi
  done
  if [ -n "$missing" ]; then
    print_message "Устанавливаем:$missing" "$YELLOW"
    opkg update >/dev/null 2>&1
    opkg install $missing
  fi
}

# ============================================================================
#  Getters — данные ЛОКАЛЬНОГО устройства (self)
# ============================================================================
get_device() {
  json_get_value "${1:-$(rci_request "show/version")}" '.device'
}

get_fw_version() {
  json_get_value "${1:-$(rci_request "show/version")}" '.title'
}

get_hw_id() {
  json_get_value "${1:-$(rci_request "show/version")}" '.hw_id'
}

get_architecture() {
  local arch
  arch=$(opkg print-architecture 2>/dev/null | grep -oE 'mips-3|mipsel-3|aarch64-3' | head -n 1)
  case "$arch" in
    "mips-3")    echo "mips" ;;
    "mipsel-3")  echo "mipsel" ;;
    "aarch64-3") echo "aarch64" ;;
    *)           echo "unknown" ;;
  esac
}

get_cpuload() {
  json_get_value "${1:-$(rci_request "show/system")}" '.cpuload'
}

get_ram_usage() {
  local memory
  memory=$(json_get_value "${1:-$(rci_request "show/system")}" '.memory')
  [ -n "$memory" ] || return 1
  local used=${memory%%/*} total=${memory#*/}
  printf '%s' "$(format_size $((used * 1024)) $((total * 1024)))"
}

get_uptime() {
  format_uptime_seconds "$(json_get_value "${1:-$(rci_request "show/system")}" '.uptime')"
}

get_opkg_storage() {
  # Возвращает "тип: used/total" для накопителя OPKG
  local opkg_label usage free total
  opkg_label=$(json_get_value "$(rci_request "show/sc/opkg/disk")" '.disk | rtrimstr("/") | rtrimstr(":")')
  [ -n "$opkg_label" ] || { echo "—"; return; }

  usage=$(rci_request "ls" | jq -r --arg key "${opkg_label}:" '
    first(.. | objects | .[$key]? | select(type == "object" and .free? != null and .total? != null))
    | [(.free // 0), (.total // 0)] | @tsv' 2>/dev/null)
  [ -n "$usage" ] || { echo "$opkg_label"; return; }

  IFS=$(printf '\t') read -r free total <<EOF
$usage
EOF
  [ -n "$free" ] && [ -n "$total" ] || { echo "$opkg_label"; return; }

  local used=$((total - free))
  printf '%s: %s' "$opkg_label" "$(format_size "$used" "$total")"
}

get_cpu_model() {
  local cpu_list="MT76[0-9A-Za-z]* MT79[0-9A-Za-z]* EN75[0-9A-Za-z]*"
  for pattern in $cpu_list; do
    found=$(strings /lib/libndmMwsController.so 2>/dev/null | grep -oE "$pattern" | head -n 1)
    if [ -n "$found" ]; then
      echo "$found "
      return
    fi
  done
  echo ""
}

# ============================================================================
#  Mesh-узлы
# ============================================================================
get_members() {
  # Возвращает сырой JSON-массив show/mws/member
  rci_request "show/mws/member"
}

get_member_ips() {
  # Список IP mesh-узлов (extender), по одному в строке
  get_members | jq -r '.[] | select(.ip != null) | .ip' 2>/dev/null
}

member_field() {
  # member_field <json_array> <ip> <jq-query>
  local json="$1" ip="$2" query="$3"
  printf '%s' "$json" | jq -r --arg ip "$ip" ".[] | select(.ip == \$ip) | $query" 2>/dev/null | head -n 1
}

# --- SSH-доступ к узлу -----------------------------------------------------
detect_ssh() {
  for b in /opt/bin/dbclient /opt/bin/ssh /usr/bin/ssh; do
    [ -x "$b" ] && { SSH_BIN="$b"; break; }
  done
  [ -n "$SSH_BIN" ] || SSH_BIN="ssh"
}

ssh_ready() {
  [ -f "$SSH_KEY" ] && detect_ssh
}

ssh_node() {
  # Выполнить команду на узле через SSH.  Требует раздачи ключа (setup).
  local ip="$1" cmd="$2"
  [ -n "$SSH_BIN" ] || detect_ssh
  if $SSH_BIN -h 2>&1 | grep -qi dropbear; then
    $SSH_BIN -y -y -q -i "$SSH_KEY" -l "$SSH_USER" -p "$SSH_PORT" "$ip" "$cmd" 2>&1
  else
    $SSH_BIN -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -l "$SSH_USER" -p "$SSH_PORT" "$ip" "$cmd" 2>&1
  fi
}

# ============================================================================
#  Команда: status — сводка по всем устройствам
# ============================================================================
cmd_status() {
  load_config
  ensure_jq

  local self_version=$(rci_request "show/version")
  local self_system=$(rci_request "show/system")
  local device fw hwid cpuload ram uptime disk

  device=$(get_device "$self_version")
  fw=$(get_fw_version "$self_version")
  hwid=$(get_hw_id "$self_version")
  cpuload=$(get_cpuload "$self_system")
  ram=$(get_ram_usage "$self_system")
  uptime=$(get_uptime "$self_system")
  disk=$(get_opkg_storage)

  printf "${CYAN}MeshkitKeen v%s — mesh-сеть Keenetic${NC}\n\n" "$SCRIPT_VERSION"

  printf "${GREEN}Контроллер (self)${NC}\n"
  printf "  IP:            %s\n" "localhost (self)"
  printf "  Модель:        %s (%s)\n" "$device" "$hwid"
  printf "  Прошивка:      %s\n" "$fw"
  printf "  CPU:           %s%% | %s\n" "$cpuload" "$(get_cpu_model)"
  printf "  ОЗУ:           %s\n" "$ram"
  printf "  Накопитель:    %s\n" "$disk"
  printf "  Uptime:        %s\n\n" "$uptime"

  local members member_count i
  members=$(get_members)
  if [ -z "$members" ] || ! echo "$members" | grep -q '^\['; then
    echo "Mesh-узлы не обнаружены (show/mws/member пуст)."
    return 0
  fi

  member_count=$(echo "$members" | jq 'length' 2>/dev/null)
  printf "${GREEN}Mesh-узлы (%s)${NC}\n" "$member_count"

  local ip model mfw mfw_avail mcpu mram muptime mspeed mode mac
  echo "$members" | jq -r '.[] | select(.ip != null) |
    [.ip, (.model // "?"), (.fw // "?"), (.fw // ""), (.system.cpuload // "?"),
     (.system.memory // "?"), (.system.uptime // "0"),
     (.backhaul.speed // "0"), (.mode // "?"), (.mac // "?")]
    | @tsv' 2>/dev/null | while IFS=$(printf '\t') read -r ip model mfw mfw_avail mcpu mram muptime mspeed mode mac; do
    [ -n "$ip" ] || continue
    ram=$(printf '%s' "$mram" | awk -F/ '{ if ($2) printf "%d / %d MB", $1/1024, $2/1024; else print "?" }')
    printf "\n  ${CYAN}%s${NC}  (%s, %s)\n" "$model" "$mode" "$ip"
    printf "    MAC:          %s\n" "$mac"
    printf "    Прошивка:     %s" "$mfw"
    # Признак обновления — по полю fw-available (если контроллер его заполнил)
    local avail
    avail=$(member_field "$members" "$ip" '.fw // empty')
    printf "\n    Backhaul:     %s Мбит/с\n" "$mspeed"
    printf "    CPU:          %s%%\n" "$mcpu"
    printf "    ОЗУ:          %s\n" "$ram"
    printf "    Uptime:       %s\n" "$(format_uptime_seconds "$muptime")"
    # Диск узла — по SSH, если ключ раздан
    if ssh_ready; then
      local ndisk
      ndisk=$(ssh_node "$ip" "sh -c \"opkg disk 2>/dev/null; df -h /opt 2>/dev/null | tail -1 | awk '{print \\\$3 \\\"/\\\" \\\$2}'\"" 2>/dev/null | tail -1)
      [ -n "$ndisk" ] && printf "    Накопитель:   %s\n" "$ndisk"
    fi
  done
  printf "\n"

  if ! ssh_ready; then
    printf "${YELLOW}SSH-ключ для узлов не настроен. Выполните: meshkitkeen setup${NC}\n"
  fi
}

# ============================================================================
#  Команда: reboot — перезагрузка устройства
# ============================================================================
cmd_reboot() {
  load_config
  local target="${1:-self}"

  if [ "$target" = "self" ]; then
    print_message "Перезагрузка контроллера..." "$YELLOW"
    rci_parse '[{"system":{"reboot":true}}]' >/dev/null 2>&1
    echo "Команда перезагрузки отправлена."
    return 0
  fi

  if [ "$target" = "all" ]; then
    local ip
    for ip in $(get_member_ips); do
      cmd_reboot "$ip"
    done
    cmd_reboot self
    return 0
  fi

  # Перезагрузка узла по IP
  ssh_ready || { echo "Сначала выполните: meshkitkeen setup" >&2; return 1; }
  echo "Перезагрузка узла $target..."
  ssh_node "$target" "ndmc -c 'system reboot'" 2>&1
}

# ============================================================================
#  Команда: wifi — включить/выключить Wi-Fi
# ============================================================================
# --- Wi-Fi: универсальная поддержка 2.4 / 5 / 6 ГГц (Wi-Fi 6/6E/7) ----------
#  WifiMaster0 = 2.4 ГГц, WifiMaster1 = 5 ГГц, WifiMaster2 = 6 ГГц (Wi-Fi 6E/7).
#  Диапазоны определяются ДИНАМИЧЕСКИ из show/interface, поэтому скрипт
#  корректно работает и на двухдиапазонных (Wi-Fi 6), и на трёхдиапазонных
#  (Wi-Fi 7) устройствах — без хардкода количества радио.

wifi_band_to_ap() {
  # band: 2.4 | 5 | 6 -> имя AccessPoint
  case "$1" in
    2.4) echo "WifiMaster0/AccessPoint0" ;;
    5)   echo "WifiMaster1/AccessPoint0" ;;
    6)   echo "WifiMaster2/AccessPoint0" ;;
    *)   return 1 ;;
  esac
}

wifi_available_bands() {
  # Возвращает доступные на устройстве band (2.4 / 5 / 6) — по одному в строке.
  # Аргумент: опциональный префикс команды для выполнения на узле (через SSH).
  local remote_cmd="${1:-}"
  local ifaces
  ifaces=$($remote_cmd curl -s "$RCI_BASE/show/interface" 2>/dev/null \
    | jq -r 'keys[] | select(test("^WifiMaster[0-9]+$"))' 2>/dev/null)
  for i in $ifaces; do
    case "$i" in
      WifiMaster0) echo "2.4" ;;
      WifiMaster1) echo "5" ;;
      WifiMaster2) echo "6" ;;
    esac
  done
}

wifi_target_aps() {
  # band: 2.4 | 5 | 6 | all -> список AccessPoint-интерфейсов.
  # Для "all" перебираются только РЕАЛЬНО существующие диапазоны.
  local band="$1" remote_cmd="${2:-}"
  local b
  case "$band" in
    2.4|5|6)
      wifi_band_to_ap "$band"
      ;;
    all)
      for b in $(wifi_available_bands "$remote_cmd"); do
        wifi_band_to_ap "$b"
      done
      ;;
    *)
      return 1
      ;;
  esac
}

wifi_control_local() {
  local band="$1" action="$2"
  local aps ap
  aps=$(wifi_target_aps "$band")
  [ -n "$aps" ] || { echo "Неверный диапазон: $band (нужно 2.4 | 5 | 6 | all)" >&2; return 1; }
  for ap in $aps; do
    echo "  $action $ap"
    rci_parse "[{\"interface\":{\"$ap\":{\"$action\":true}}}]" >/dev/null 2>&1
  done
}

cmd_wifi() {
  load_config
  local target="$1" action="$2" band="${3:-all}"

  case "$action" in
    on) action="up" ;;
    off) action="down" ;;
    *) echo "Использование: meshkitkeen wifi <self|IP|all> on|off [2.4|5|6|all]" >&2; return 1 ;;
  esac

  if [ "$target" = "self" ]; then
    wifi_control_local "$band" "$action"
    return 0
  fi

  if [ "$target" = "all" ]; then
    local ip
    for ip in $(get_member_ips); do
      cmd_wifi "$ip" "$action" "$band"
    done
    wifi_control_local "$band" "$action"
    return 0
  fi

  # Узел по IP: через SSH.
  ssh_ready || { echo "Сначала выполните: meshkitkeen setup" >&2; return 1; }

  # Если на узле есть meshkitkeen — делегируем (там динамическое определение диапазонов)
  if ssh_node "$target" "command -v meshkitkeen" >/dev/null 2>&1; then
    echo "  Узел $target: meshkitkeen wifi self $action $band"
    ssh_node "$target" "meshkitkeen wifi self $action $band" 2>&1
    return $?
  fi

  # Fallback (без meshkitkeen на узле): перечисляем AP. Для "all" пробуем все
  # три диапазона — отсутствующий (напр. 6 ГГц на Wi-Fi 6) просто не сработает.
  local aps ap
  if [ "$band" = "all" ]; then
    aps="WifiMaster0/AccessPoint0 WifiMaster1/AccessPoint0 WifiMaster2/AccessPoint0"
  else
    aps=$(wifi_band_to_ap "$band") || { echo "Неверный диапазон: $band" >&2; return 1; }
  fi
  for ap in $aps; do
    echo "  Узел $target: $action $ap"
    ssh_node "$target" "ndmc -c 'interface $ap $action'" 2>&1
  done
}

# ============================================================================
#  Команда: update — обновление прошивки (OTA через домен)
# ============================================================================
get_ota_domain() {
  local domain=""
  if [ -n "$OTA_DOMAIN" ]; then
    domain="$OTA_DOMAIN"
  elif [ -f "$CONFIG_FILE" ]; then
    domain=$(sed -n 's/^domain="\(.*\)"$/\1/p' "$CONFIG_FILE" | head -n 1)
  fi
  domain=$(printf '%s' "$domain" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s|/*$||')
  [ -n "$domain" ] && printf '%s\n' "$domain"
}

ota_request() {
  local url="$1"; shift
  curl -fLsS --basic --max-time 15 "$url" "$@"
}

cmd_update() {
  load_config
  local target="${1:-self}"

  if [ "$target" != "self" ]; then
    # Обновление узла: на узле должен быть MeshkitKeen (ставится через add-node)
    ssh_ready || { echo "Сначала выполните: meshkitkeen setup" >&2; return 1; }
    print_message "Обновление прошивки узла $target" "$YELLOW"
    echo "На узле будет запущен meshkitkeen ota-update (неинтерактивно)."
    ssh_node "$target" "meshkitkeen ota-update --auto" 2>&1
    return $?
  fi

  # Обновление контроллера (self)
  cmd_ota_update "${2:-}"
}

# ============================================================================
#  OTA-обновление (неинтерактивный вариант KeenKit ota_update)
#  meshkitkeen ota-update [--auto]
# ============================================================================
cmd_ota_update() {
  load_config
  local auto=false
  [ "${1:-}" = "--auto" ] && auto=true

  local domain arch osvault
  domain=$(get_ota_domain)
  if [ -z "$domain" ]; then
    echo "Не задан OTA-домен. Запишите в $CONFIG_FILE строку: domain=\"https://...\"" >&2
    return 1
  fi

  packages_checker "curl findutils libcurl md5sum"
  arch=$(get_architecture)
  # Для прошивки используем каталог /osvault (KeenKit-схема)
  osvault="$domain/osvault"

  local REQUEST DIRS current_device
  REQUEST=$(ota_request "$osvault") || { echo "Не удалось открыть $osvault" >&2; return 1; }
  DIRS=$(echo "$REQUEST" | grep -o 'href="[^"]*"' | cut -d'"' -f2 | grep -E '^[^/?#]+/$' | grep -vE '^\.\.?/$' | sed 's|/$||' | sed 's|%20| |g')
  [ -n "$DIRS" ] || { echo "Не найдены каталоги моделей в $osvault" >&2; return 1; }

  current_device=$(get_device)
  local chosen_dir=""
  for d in $DIRS; do
    case "$current_device" in
      *"$d"*|"$d"*) chosen_dir="$d"; break ;;
    esac
  done

  if [ -z "$chosen_dir" ]; then
    echo "Каталог модели не найден автоматически. Доступные:" >&2
    printf '  %s\n' $DIRS >&2
    return 1
  fi

  local DIR_ENCODED BIN_FILES
  DIR_ENCODED=$(echo "$chosen_dir" | sed 's/ /%20/g')
  REQUEST=$(ota_request "$osvault/$DIR_ENCODED/") || { echo "Ошибка открытия $osvault/$DIR_ENCODED/" >&2; return 1; }
  BIN_FILES=$(echo "$REQUEST" | grep -o 'href="[^"]*"' | cut -d'"' -f2 | grep '\.bin$' | sed 's|%20| |g')

  if [ -z "$BIN_FILES" ]; then
    echo "Нет .bin файлов в $osvault/$DIR_ENCODED/" >&2
    return 1
  fi

  # Неинтерактивно берём последний файл в списке (osvault обычно сортирован по возрастанию версии)
  local FILE FILE_ENCODED
  FILE=$(echo "$BIN_FILES" | tail -n 1)
  FILE_ENCODED=$(echo "$FILE" | sed 's/ /%20/g')

  echo "Модель:    $current_device"
  echo "Домен:     $domain"
  echo "Прошивка:  $FILE"
  [ "$auto" = true ] || {
    printf "Продолжить? (y/n) "
    local CONFIRM
    read -r CONFIRM
    case "$CONFIRM" in
      y|Y) ;;
      *) echo "Отменено."; return 1 ;;
    esac
  }

  local file_url md5_url total_size
  file_url="$osvault/$DIR_ENCODED/$FILE_ENCODED"
  md5_url="$osvault/$DIR_ENCODED/md5sum"

  echo "Скачивание $file_url ..."
  if ! ota_request "$file_url" -o "$TMP_DIR/$FILE"; then
    echo "Ошибка скачивания." >&2
    return 1
  fi
  if ! ota_request "$md5_url" -o "$TMP_DIR/md5sum"; then
    rm -f "$TMP_DIR/$FILE"
    echo "Ошибка скачивания md5sum." >&2
    return 1
  fi

  local MD5_REMOTE MD5_LOCAL
  MD5_REMOTE=$(grep "$FILE" "$TMP_DIR/md5sum" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
  MD5_LOCAL=$(md5sum "$TMP_DIR/$FILE" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
  if [ "$MD5_REMOTE" != "$MD5_LOCAL" ]; then
    echo "MD5 не совпадает: $MD5_REMOTE != $MD5_LOCAL" >&2
    rm -f "$TMP_DIR/$FILE" "$TMP_DIR/md5sum"
    return 1
  fi
  echo "MD5: ok"

  # Обновление через нативный ndm (copy в flash:/firmware)
  print_message "Обновление прошивки. Устройство перезагрузится." "$YELLOW"
  if rci_parse "copy temp:/$FILE flash:/firmware" 2>&1 | grep -q "update done"; then
    echo "Обновление запущено. Перезагрузка..."
  else
    echo "Предупреждение: ответ ndm не подтвердил 'update done'. Проверьте лог." >&2
  fi
  rm -f "$TMP_DIR/$FILE" "$TMP_DIR/md5sum"
}

# ============================================================================
#  Команда: setup — генерация и раздача SSH-ключей на узлы
# ============================================================================
cmd_setup() {
  load_config
  mkdir -p "$KEY_DIR"

  if [ ! -f "$SSH_KEY" ]; then
    print_message "Генерация SSH-ключа..." "$YELLOW"
    dropbearkey -t ed25519 -f "$SSH_KEY" >/dev/null 2>&1 || {
      echo "Не удалось сгенерировать ключ (нужен dropbearkey)." >&2
      return 1
    }
  fi

  local pubkey
  pubkey=$(dropbearkey -y -f "$SSH_KEY" 2>/dev/null | grep -E '^ssh-' | head -n 1)
  if [ -z "$pubkey" ]; then
    echo "Не удалось получить публичный ключ." >&2
    return 1
  fi

  printf '%s\n' "$pubkey" > "$SSH_KEY.pub"
  echo "Публичный ключ:"
  echo "  $pubkey"
  echo ""

  echo "Для раздачи ключа на узлы необходимо ОДИН раз ввести пароль root."
  echo "Выполните на КАЖДОМ mesh-узле (по SSH :222, root):"
  echo ""
  echo "  mkdir -p /opt/root/.ssh"
  echo "  echo '$pubkey' >> /opt/root/.ssh/authorized_keys"
  echo ""
  echo "Либо укажите ключ вручную. После этого проверьте доступ: meshkitkeen status"
}

# ============================================================================
#  Команда: add-node — развернуть Entware + MeshkitKeen на узле
# ============================================================================
cmd_add_node() {
  local ip="$1"
  [ -n "$ip" ] || { echo "Использование: meshkitkeen add-node <IP-узла>" >&2; return 1; }
  load_config

  print_message "Подключение узла $ip" "$YELLOW"

  echo "Проверка доступности SSH :22 (admin, нативный CLI)..."
  ssh_node "$ip" "echo ok" >/dev/null 2>&1 && echo "  :222 уже доступен (Entware стоит)." || {
    echo "  На узле нет dropbear :222. Требуется развернуть Entware."
    echo "  Выполните на узле через нативный CLI (:22, admin):"
    echo "    opkg disk storage:/ https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz"
    echo "  и дождитесь открытия порта 222."
  }

  echo ""
  echo "Дальнейшее развёртывание (SSH-ключ, MeshkitKeen) выполняется командой:"
  echo "  meshkitkeen setup"
  echo ""
  echo "Автоматическая установка требует интерактивного ввода пароля узла."
  echo "См. docs/SETUP.md для пошаговой инструкции."
}

# ============================================================================
#  Наследуемые команды KeenKit (локально на self)
# ============================================================================
cmd_backup_entware() {
  load_config
  print_message "Бэкап Entware ($DATE)" "$YELLOW"
  local out="/storage/entware_backup_$DATE.tar.gz"
  packages_checker "tar"
  /opt/bin/tar -czf "$out" -C /opt --exclude=var/opkg-lists --exclude=tmp . 2>/dev/null \
    && echo "Сохранено: $out" || echo "Ошибка бэкапа." >&2
}

cmd_backup_block() {
  load_config
  print_message "Бэкап разделов (mtd)" "$YELLOW"
  local out="/storage/mtd_backup_$DATE"
  mkdir -p "$out"
  local mtd name index
  for mtd in $(grep -oE '^mtd[0-9]+' /proc/mtd); do
    index=$(echo "$mtd" | grep -oE '[0-9]+')
    name=$(grep -w "$mtd" /proc/mtd | sed 's/.*"\(.*\)".*/\1/')
    dd if="/dev/$mtd" of="$out/${index}_${name}.bin" 2>/dev/null
    echo "  $mtd ($name) -> ${index}_${name}.bin"
  done
  echo "Сохранено: $out"
}

# ============================================================================
#  Очистка / выход
# ============================================================================
cleanup() {
  : # зарезервировано под подчистку временных файлов
}

usage() {
  cat <<EOF
MeshkitKeen v$SCRIPT_VERSION — управление mesh-сетью Keenetic с головного терминала.

Использование:
  meshkitkeen status                    Сводка по контроллеру и mesh-узлам
  meshkitkeen reboot <self|IP|all>      Перезагрузка устройства
  meshkitkeen wifi <self|IP|all> on|off [2.4|5|6|all]
                                        Включить/выключить Wi-Fi (6 ГГц — Wi-Fi 6E/7)
  meshkitkeen update <self|IP>          Обновление прошивки (OTA)
  meshkitkeen ota-update [--auto]       OTA контроллера (выбор версии)
  meshkitkeen add-node <IP>             Подключить новый mesh-узел
  meshkitkeen setup                      Сгенерировать/раздать SSH-ключи узлов
  meshkitkeen backup-entware            Бэкап Entware (self)
  meshkitkeen backup-block              Бэкап разделов mtd (self)

Без аргументов запускается интерактивное меню.

Конфиг:  /opt/etc/MeshkitKeen.conf   (domain, ssh_user, ssh_port)
Ключ:    /opt/etc/MeshkitKeen/id_ed25519   (для SSH на узлы)

ВНИМАНИЕ: операции reboot/wifi/update изменяют состояние сети.
EOF
}

# --- Интерактивное меню ----------------------------------------------------
main_menu() {
  while true; do
    printf "${CYAN}"
    cat <<'EOF'
  __  __           _     _    _  _  __
 |  \/  | ___  ___| |__ (_) _| |/ /__ _ __ ___
 | |\/| |/ _ \/ __| '_ \| |/ /| ' // _ \ '_ ` _ \
 | |  | |  __/\__ \ | | | |  < | . \  __/ | | | | |
 |_|  |_|\___||___/_| |_|_|\_\_|_|\_\___|_| |_|_|_|

EOF
    printf "${NC}"
    printf "MeshkitKeen v%s\n\n" "$SCRIPT_VERSION"
    echo "1. Статус сети (все устройства)"
    echo "2. Перезагрузить устройство"
    echo "3. Wi-Fi вкл/выкл"
    echo "4. Обновить прошивку (OTA)"
    echo "5. Подключить новый mesh-узел"
    echo "6. Настроить SSH-ключи (setup)"
    echo "7. Бэкап Entware"
    echo "8. Бэкап разделов"
    echo "0. Выход"
    echo ""
    printf "Выберите действие: "
    local choice
    read -r choice || exit 0
    echo ""
    case "$choice" in
      1) cmd_status ;;
      2) printf "IP (self/all/или IP узла): "; read -r t; cmd_reboot "${t:-self}" ;;
      3) printf "IP (self/all/или IP узла): "; read -r t; printf "on/off: "; read -r a; printf "диапазон (2.4/5/6/all): "; read -r b; cmd_wifi "${t:-self}" "$a" "${b:-all}" ;;
      4) printf "IP (self/или IP узла): "; read -r t; cmd_update "${t:-self}" ;;
      5) printf "IP нового узла: "; read -r t; cmd_add_node "$t" ;;
      6) cmd_setup ;;
      7) cmd_backup_entware ;;
      8) cmd_backup_block ;;
      0) exit 0 ;;
      *) echo "Неверный выбор." ;;
    esac
    echo ""
    printf "Нажмите Enter для продолжения..."
    read -r _ || exit 0
  done
}

# ============================================================================
#  Диспетчер
# ============================================================================
main() {
  load_config
  local cmd="${1:-}"
  shift 2>/dev/null || true

  case "$cmd" in
    status)         cmd_status "$@" ;;
    reboot)         cmd_reboot "$@" ;;
    wifi)           cmd_wifi "$@" ;;
    update)         cmd_update "$@" ;;
    ota-update)     cmd_ota_update "$@" ;;
    add-node)       cmd_add_node "$@" ;;
    setup)          cmd_setup "$@" ;;
    backup-entware) cmd_backup_entware "$@" ;;
    backup-block)   cmd_backup_block "$@" ;;
    -h|--help|help) usage ;;
    "")             main_menu ;;
    *)              echo "Неизвестная команда: $cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"

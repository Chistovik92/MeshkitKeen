#!/bin/sh
# ============================================================================
#  MeshkitKeen — управление mesh-сетью Keenetic с одного терминала
# ============================================================================
#  Форк KeenKit (spatiumstas/KeenKit, v2.9.5). СОХРАНЁН весь функционал
#  оригинального KeenKit (интерактивное меню, OTA, загрузчик, бэкапы, и т.д.)
#  и ДОБАВЛЕН неинтерактивный режим + управление mesh-узлами (ретрансляторы/
#  экстендеры) с головного роутера.
#
#  Без аргументов запускается полное интерактивное меню KeenKit.
#  С аргументами — неинтерактивные команды (status/reboot/wifi/update/...).
#
#  Лицензия: MIT (см. LICENSE).  Никакие пароли/ключи не хранятся в репозитории.
# ============================================================================
trap cleanup HUP INT TERM EXIT
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BRANCH="main"
USERNAME="Chistovik92"
USER='root'
REPO="MeshkitKeen"
PAGES_URL="https://$USERNAME.github.io/$REPO"
SCRIPT="meshkitkeen.sh"
TMP_DIR="/tmp"
OPT_DIR="/opt"
CONFIG_FILE="$OPT_DIR/etc/$REPO.conf"
STORAGE_DIR="/storage"
SCRIPT_VERSION="2.9.5"
FORK_VERSION="1.0.0"
MIN_RAM_SIZE="256"
MIN_RAM_SIZE_AARCH64="512"
PACKAGES_LIST="python3-base python3 python3-light libpython3"
DATE=$(date +%Y-%m-%d_%H-%M)

# --- MeshkitKeen: SSH-доступ к узлам и OTA-источник -------------------------
SSH_USER="root"
SSH_PORT="222"
KEY_DIR="$OPT_DIR/etc/$REPO"
SSH_KEY="$KEY_DIR/id_ed25519"
SSH_BIN=""
# OTA-домен по умолчанию — Osvault (KeenKit), https://osvault.project-athens.com
OTA_DOMAIN_DEFAULT="https://osvault.project-athens.com"

print_menu() {
  local version_info system_info ndss_info

  printf "\033c"
  printf "${CYAN}"
  cat <<'EOF'
    __ __                __ __ _ __
   / //_/__  ___  ____  / //_/(_) /_
  / ,< / _ \/ _ \/ __ \/ ,<  / / __/
 / /| /  __/  __/ / / / /| |/ / /_
/_/ |_\___/\___/_/ /_/_/ |_/_/\__/

EOF
  version_info=$(rci_request "show/version")
  system_info=$(rci_request "show/system")
  ndss_info=$(rci_request "show/ndss")
  arch="$(get_architecture)"
  printf "${CYAN}Модель:         ${NC}%s\n" "$(get_device "$version_info") ($(get_hw_id "$version_info")) | $(get_fw_version "$version_info") (слот: "$(get_boot_current)")$(get_ndm_storage && printf ' | Single')"
  printf "${CYAN}Процессор:      ${NC}%s\n" "$(get_cpu_model)($arch)$(get_temperatures)"
  if get_bootloader_info=$(get_bootloader_version); [ -n "$get_bootloader_info" ]; then
    printf "${CYAN}Загрузчик:      ${NC}%s\n" "$get_bootloader_info"
  fi
  if get_modem_info=$(get_modem); [ -n "$get_modem_info" ]; then
    printf "${CYAN}Модемы:         ${NC}%s\n" "$get_modem_info"
  fi
  printf "${CYAN}ОЗУ:            ${NC}%s\n" "$(get_ram_usage "$system_info")"
  printf "${CYAN}OPKG:           ${NC}%s\n" "$(get_opkg_storage)"
  printf "${CYAN}Время работы:   ${NC}%s\n" "$(get_uptime "$system_info")"
  if get_repeaters_info=$(get_mws_members); [ -n "$get_repeaters_info" ]; then
    printf "${CYAN}Ретрансляторы:  ${NC}"
    printf "%b\n" "$get_repeaters_info"
  fi
  printf "${CYAN}Версия:         ${NC}%s\n\n" "$SCRIPT_VERSION by ${USERNAME}$(check_update)"
  echo "1. Обновить прошивку из файла"
  echo "2. Бэкап разделов"
  echo "3. Бэкап Entware"
  if get_host "$ndss_info"; then
    echo "4. Заменить раздел"
    echo "5. OTA Update"
    echo "6. Обновить сервисные данные"
  fi
  echo "7. Переключить слот"
  if get_host "$ndss_info" && { [ "$arch" != "mipsel" ] || is_uboot_writable; }; then
    echo "8. KeenBOOT OTA Update"
  fi
  printf "\n77. Change language"
  printf "\n88. Удалить пакеты и настройки\n"
  echo "99. Обновить скрипт"
  echo "00. Выход"
  echo ""
}

main_menu() {
  while true; do
    print_menu
    if ! read -r -p "Выберите действие: " choice; then
      echo ""
      exit 0
    fi
    echo ""
    choice=$(echo "$choice" | tr -d '\032' | tr -d '[A-Z]')

    if [ -z "$choice" ]; then
      continue
    fi

    case "$choice" in
    1) firmware_manual_update ;;
    2) backup_block ;;
    3) backup_entware ;;
    4) rewrite_block ;;
    5) ota_update ;;
    6) service ;;
    7) switch_boot_slot ;;
    8) ota_update "keenboot" ;;
    00) exit 0 ;;
    77) changeLanguage ;;
    88) packages_delete ;;
    99) script_update ;;
    *)
      echo "Неверный выбор. Попробуйте снова."
      sleep 1
      ;;
    esac
  done
}

print_message() {
  local message="$1"
  local color="${2:-$NC}"
  local border=$(printf '%0.s-' $(seq 1 $((${#message} + 2))))
  printf "${color}\n+${border}+\n| ${message} |\n+${border}+\n${NC}\n"
}

print_list_with_highlight() {
  local items="$1"
  local current_model="$2"

  local normalized_current
  normalized_current=$(echo "$current_model" | tr '[:upper:]' '[:lower:]' | sed 's/[_-]/ /g')

  local i=1
  while IFS= read -r item; do
    local normalized_item
    normalized_item=$(echo "$item" | tr '[:upper:]' '[:lower:]' | sed 's/[_-]/ /g')

    if [[ "$normalized_item" == *"$normalized_current"* ]] || \
       [[ "$normalized_current" == *"$normalized_item"* ]]; then
      printf "%d. ${CYAN}%s${NC}\n" "$i" "$item"
    else
      printf "%d. %s\n" "$i" "$item"
    fi
    i=$((i + 1))
  done <<EOF
$items
EOF
}

rci_request() {
  local endpoint="$1"
  curl -s "http://127.0.0.1:79/rci/$endpoint"
}

rci_parse() {
  local body="$1"

  case "$body" in
  \{* | \[*) ;;
  *) body="[{\"parse\":\"$body\"}]" ;;
  esac

  curl -fsS -H "Content-Type: application/json" \
    -d "$body" \
    "http://127.0.0.1:79/rci/"
}

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi

  packages_checker "jq"
  command -v jq >/dev/null 2>&1
}

json_get_value() {
  local json="$1"
  local query="$2"

  ensure_jq || return 1
  [ -n "$json" ] || return 1

  printf '%s\n' "$json" | jq -r "$query // empty" 2>/dev/null
}

get_ls_usage() {
  local volume_key="$1"
  local volume_label="$2"

  ensure_jq || return 1

  rci_request "ls" | jq -r --arg key "$volume_key" --arg label "$volume_label" '
    first(
      (
        ..
        | objects
        | .[$key]?
        | select(type == "object" and .free? != null and .total? != null)
      ),
      (
        ..
        | objects
        | select(.label? == $label and .free? != null and .total? != null)
      )
    )
    | [(.free // 0), (.total // 0)]
    | @tsv
  ' 2>/dev/null
}

ndmc_cli() {
  unset LD_LIBRARY_PATH
  ndmc -c "$@"
}

native_fwupdate() {
  local firmware="$1"
  local firmware_rci_path response

  case "$firmware" in
  "$STORAGE_DIR"/*)
    firmware_rci_path="storage:/${firmware#"$STORAGE_DIR"/}"
    ;;
  "$TMP_DIR"/*)
    firmware_rci_path="temp:/${firmware#"$TMP_DIR"/}"
    ;;
  *)
    return 1
    ;;
  esac

  if ! response=$(rci_parse "copy $firmware_rci_path flash:/firmware" 2>&1); then
    return 1
  fi

  echo "$response" | grep -q "update done"
}

check_update() {
  local response
  response=$(curl -s --max-time 1 "https://api.github.com/repos/$USERNAME/$REPO/releases/latest")
  REMOTE_VERSION=$(json_get_value "$response" '.tag_name')
  [ -z "$REMOTE_VERSION" ] && return
  [ "$REMOTE_VERSION" != "$SCRIPT_VERSION" ] && printf " | ${GREEN}Доступно $REMOTE_VERSION${NC}"
}

get_device() {
  json_get_value "${1:-$(rci_request "show/version")}" '.device'
}

get_fw_version() {
  json_get_value "${1:-$(rci_request "show/version")}" '.title'
}

get_hw_id() {
  json_get_value "${1:-$(rci_request "show/version")}" '.hw_id'
}

format_uptime_seconds() {
  local uptime=$1
  if [ -z "$uptime" ] || ! echo "$uptime" | grep -qE '^[0-9]+$'; then
    return
  fi
  local days=$((uptime / 86400))
  local hours=$(((uptime % 86400) / 3600))
  local minutes=$(((uptime % 3600) / 60))
  local seconds=$((uptime % 60))

  if [ "$days" -gt 0 ]; then
    printf "%d дн. %02d:%02d:%02d" "$days" "$hours" "$minutes" "$seconds"
  else
    printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
  fi
}

get_uptime() {
  local system_info="${1:-$(rci_request "show/system")}"
  local uptime
  uptime=$(json_get_value "$system_info" '.uptime')
  format_uptime_seconds "$uptime"
}

get_mws_members() {
  local mws_json=$(rci_request "show/mws/member")
  local result=""

  if [ -z "$mws_json" ] || ! echo "$mws_json" | grep -q '^\['; then
    return 0
  fi

  ensure_jq || return 0
  local repeater_data
  repeater_data=$(echo "$mws_json" | jq -r '
    .[] |
    select(.model != null) |
    "\(.model)|" +
    "\(.fw // "null")|" +
    "\(.system.uptime // "0")|" +
    "\(.backhaul.txrate // .backhaul.speed // "0")"' 2>/dev/null)

  if [ -z "$repeater_data" ]; then
    return 0
  fi

  local first=true
  while IFS='|' read -r model fw uptime speed; do
    local output_line=""

    if [ "$fw" != "null" ]; then
      local uptime_formatted=$(format_uptime_seconds "$uptime")
      output_line=$(printf "%s | %s | %s Мбит/с | %s" "$model" "$fw" "$speed" "$uptime_formatted")
    else
      output_line=$(printf "%s | ${RED}Не в сети${NC}" "$model")
    fi

    if [ "$first" = "true" ]; then
      result="${output_line}"
      first=false
    else
      result="${result}\n                ${output_line}"
    fi
  done <<EOF
$repeater_data
EOF

  echo "$result"
}

get_ram_usage() {
  local system_info="${1:-$(rci_request "show/system")}"
  local memory
  local used total

  memory=$(json_get_value "$system_info" '.memory')
  used=${memory%%/*}
  total=${memory#*/}
  printf "%d / %d MB\n" "$((used / 1024))" "$((total / 1024))"
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

get_opkg_storage() {
  local opkg_label usage free total used

  opkg_label=$(json_get_value "$(rci_request "show/sc/opkg/disk")" '.disk | rtrimstr("/") | rtrimstr(":")')
  [ -n "$opkg_label" ] || return

  usage=$(get_ls_usage "${opkg_label}:" "$opkg_label")
  [ -n "$usage" ] || return

  IFS=$(printf '\t') read -r free total <<EOF
$usage
EOF
  [ -n "$free" ] && [ -n "$total" ] || return

  used=$((total - free))
  echo "$(format_size $used $total)"
}

get_internal_storage_size() {
  local flag="$1"
  local usage free total used

  usage=$(get_ls_usage "storage:" "storage")
  [ -n "$usage" ] || return

  IFS=$(printf '\t') read -r free total <<EOF
$usage
EOF
  if [ -n "$free" ] && [ -n "$total" ]; then
    used=$((total - free))
    if [ "$flag" = "free" ]; then
      echo $((free / 1024 / 1024))
    else
      format_size $used $total
    fi
  fi
}

get_ram_size() {
  local system_info="${1:-$(rci_request "show/system")}"
  local memtotal
  memtotal=$(json_get_value "$system_info" '.memtotal')
  echo "$memtotal" | awk '{print int($1 / 1024)}' 2>/dev/null
}

get_boot_current() {
  cat /proc/dual_image/boot_current 2>/dev/null
}

is_uboot_writable() {
  local uboot_index flags
  uboot_index=$(get_mtd_index_by_name "U-Boot") || return 1
  [ -n "$uboot_index" ] || return 1
  flags=$(cat "/sys/class/mtd/mtd$uboot_index/flags" 2>/dev/null) || return 1
  [ "$flags" = "0x400" ]
}

parse_bootloader_version() {
    local strings="$1" pattern found
    found=$(echo "$strings" | grep -m1 '^Version: (KB-')
    [ -n "$found" ] && {
        echo "KeenBOOT $(echo "$found" | sed -e 's/^Version: (//' -e 's/)$//')"
        return
    }
    for pattern in '^KeenBOOT ' 'U-Boot v' 'U-Boot '; do
        found=$(echo "$strings" | grep -m1 "$pattern")
        [ -n "$found" ] && {
            [ "$pattern" = '^KeenBOOT ' ] &&
                echo "$found" ||
                echo "$found" | sed 's/^.*U-Boot/U-Boot/'
            return
        }
    done
}

get_bootloader_version() {
    local device version offset
    device=/dev/$(awk -F: '/"U-Boot"/{print $1;exit}' /proc/mtd) || return
    version=$(parse_bootloader_version "$(strings "$device" 2>/dev/null)")
    [ -n "$version" ] && {
        echo "$version"
        return
    }

    for offset in $(strings -t d "$device" 2>/dev/null | awk '$2 == "7zXZ" { print $1 - 1 }'); do
        [ "$offset" -gt 0 ] 2>/dev/null || continue
        version=$(parse_bootloader_version "$(dd if="$device" bs="$((offset + 24))" skip=1 2>/dev/null |
            xz -dc --single-stream --format=raw --lzma2=dict=1MiB 2>/dev/null | strings)")
        [ -n "$version" ] && {
            echo "$version"
            return
        }
    done
}

copy_dual_config() {
  local current_slot="$1"
  local new_slot="$2"
  local cfg_slot1 cfg_slot2 src_cfg_slot dst_cfg_slot
  local arch src_dev dst_dev

  cfg_slot1=$(get_mtd_index_by_name "Config_1")
  cfg_slot2=$(get_mtd_index_by_name "Config_2")

  if [ -z "$cfg_slot1" ] || [ -z "$cfg_slot2" ]; then
    print_message "Разделы Config_1/Config_2 не найдены, копирование конфигурации невозможно." "$RED"
    return 1
  fi

  case "$current_slot-$new_slot" in
  1-2)
    src_cfg_slot="$cfg_slot1"
    dst_cfg_slot="$cfg_slot2"
    ;;
  2-1)
    src_cfg_slot="$cfg_slot2"
    dst_cfg_slot="$cfg_slot1"
    ;;
  *)
    ;;
  esac

  arch="$(get_architecture)"
  case "$arch" in
  aarch64)
    src_dev="/dev/mtd$src_cfg_slot"
    dst_dev="/dev/mtd$dst_cfg_slot"
    ;;
  mips | mipsel | *)
    src_dev="/dev/mtdblock$src_cfg_slot"
    dst_dev="/dev/mtdblock$dst_cfg_slot"
    ;;
  esac

  print_message "Копирую конфигурацию: Config_$current_slot → Config_$new_slot" "$CYAN"
  dd_output=$(dd if="$src_dev" of="$dst_dev" 2>&1 | tee /dev/tty)
  if echo "$dd_output" | grep -iq "error\|can't"; then
    print_message "Ошибка при копировании конфигурации" "$RED"
    return 1
  fi

  return 0
}

change_boot_slot() {
  rci_parse "copy proc:/dual_image/boot_active proc:/dual_image/boot_backup" >/dev/null 2>&1 || return 1
  rci_parse "copy proc:/dual_image/boot_fails proc:/dual_image/boot_active" >/dev/null 2>&1 || return 1
  rci_parse "copy proc:/dual_image/boot_fails proc:/dual_image/commit" >/dev/null 2>&1 || return 1

  return 0
}

switch_boot_slot() {
  local current_slot new_slot
  current_slot="$(get_boot_current)"

  case "$current_slot" in
  1) new_slot=2 ;;
  2) new_slot=1 ;;
  *)
    print_message "Неподдерживаемое значение слота: $current_slot" "$RED"
    exit_function
    ;;
  esac

  read -p "Текущий слот: $current_slot. Сменить на $new_slot? (y/n) " confirm_switch
  confirm_switch=$(echo "$confirm_switch" | tr -d ' \n\r')
  case "$confirm_switch" in
  y | Y) ;;
  *)
    exit_function
    ;;
  esac

  print_message "Переключаю слот $current_slot на $new_slot" "$CYAN"

  if change_boot_slot; then
    print_message "Слот успешно переключен на $new_slot. Для применения требуется перезагрузка." "$GREEN"
    read -p "Перезагрузить роутер? (y/n) " reboot_ans
    reboot_ans=$(echo "$reboot_ans" | tr -d ' \n\r')
    case "$reboot_ans" in
    y | Y)
      reboot
      ;;
    *) ;;

    esac
  else
    print_message "Ошибка при переключении слота" "$RED"
  fi

  exit_function
}

get_ndm_storage() {
  strings /lib/modules/4.9-ndm-5/ndm_storage.ko 2>/dev/null | grep -q "Firmware_2"
}

get_architecture() {
  local arch
  arch=$(opkg print-architecture | grep -oE 'mips-3|mipsel-3|aarch64-3' | head -n 1)

  case "$arch" in
  "mips-3") echo "mips" ;;
  "mipsel-3") echo "mipsel" ;;
  "aarch64-3") echo "aarch64" ;;
  *) echo "unknown_arch" ;;
  esac
}

get_radio_temp() {
  json_get_value "${2:-$(rci_request "show/interface")}" ".[\"$1\"].temperature"
}

get_temperatures() {
  local interface_info="$1"

  temp_2=$(get_radio_temp WifiMaster0 "$interface_info")
  temp_5=$(get_radio_temp WifiMaster1 "$interface_info")
  arch=$(get_architecture)
  cpu_str=""
  wifi_str=""

  if [ "$arch" = "aarch64" ]; then
    temp_cpu_raw=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp | tr -d -c '0-9')
    if [ -n "$temp_cpu_raw" ]; then
      cpu_str="CPU: $((temp_cpu_raw / 1000))°C"
    fi
  fi

  if ! echo "$temp_2" | grep -qE '^[0-9]+$'; then
    [ -n "$cpu_str" ] && echo " | $cpu_str"
    return
  fi

  if echo "$temp_5" | grep -qE '^[0-9]+$'; then
    diff=$((temp_5 - temp_2))
    [ $diff -lt 0 ] && diff=$((-diff))
    if [ $diff -lt 3 ]; then
      wifi_str="Wi-Fi: ${temp_5}°C"
    else
      wifi_str="2.4GHz: ${temp_2}°C | 5GHz: ${temp_5}°C"
    fi
  else
    wifi_str="2.4GHz: ${temp_2}°C"
  fi

  [ -n "$cpu_str" ] && wifi_str="$wifi_str | $cpu_str"
  echo " | $wifi_str"
}

get_cpu_model() {
  cpu_list="MT76[0-9A-Za-z]* MT79[0-9A-Za-z]* EN75[0-9A-Za-z]*"
  for pattern in $cpu_list; do
    found=$(strings /lib/libndmMwsController.so 2>/dev/null | grep -oE "$pattern" | head -n 1)
    if [ -n "$found" ]; then
      echo "$found "
      return
    fi
  done
}

get_modem() {
  local interfaces iface modem_line result

  ensure_jq || return 0
  interfaces=$(rci_parse '[{"show":{"sc":{"interface":{"trait":"Mobile"}}}}]' | jq -r '
    (if type == "array" then .[0] else . end)
    | (.interface // .show.sc.interface // {})
    | keys[]?
  ' 2>/dev/null)
  [ -n "$interfaces" ] || return

  result=""
  for iface in $interfaces; do
    modem_line=$(rci_request "show/interface/$iface" | jq -r '
      select((.plugged // "") != "no")
      | (
            ([.ati.model, .product, .description, .id, ""] | map(select(. != null and . != "")) | .[0]) as $name
          | (.operator // "") as $operator
          | (.band // "") as $band
          | (.bandwidth // "") as $bandwidth
          | (
              [
                (.carrier // {})
                | to_entries[]?
                | .value
                | select((.active // true) and .band != null)
                | "B\(.band)\(if (.bandwidth // "") != "" then "@\(.bandwidth) МГц" else "" end)"
              ]
              | if length > 0 then
                  join(" + ")
                elif $band != "" then
                  "B\($band)\(if $bandwidth != "" then "@\($bandwidth) МГц" else "" end)"
                else
                  ""
                end
            ) as $carrier
          | $name
            + (if $operator != "" then " | " + $operator else "" end)
            + (if $carrier != "" then " | " + $carrier else "" end)
            + (if (.temperature // "") != "" then " | \(.temperature)°C" else "" end)
        )
    ' 2>/dev/null)
    [ -n "$modem_line" ] || continue

    if [ -n "$result" ]; then
      result="$result\n                $modem_line"
    else
      result="$modem_line"
    fi
  done

  [ -n "$result" ] && echo -e "$result"
}

get_mtd_index_by_name() {
  local name="$1"
  grep -w "$name" /proc/mtd | awk -F: '{print $1}' | grep -oE '[0-9]+'
}

get_host() {
  [ "$(json_get_value "${1:-$(rci_request "show/ndss")}" '.host')" = "127.0.0.1" ]
}

check_host() {
  if ! get_host; then
    main_menu
  fi
}

spinner_start() {
  SPINNER_MSG="$1"
  (
    i=0
    while :; do
      set -- "⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"
      eval "spin=\${$((i % 10 + 1))}"
      printf '\r\033[K\033[0;37m[%s] %s\033[0m' "$spin" "$SPINNER_MSG"
      i=$((i + 1))
      usleep 100000
    done
  ) &
  SPINNER_PID=$!
}

spinner_stop() {
  local rc=${1:-0}
  if [ -n "$SPINNER_PID" ]; then
    kill "$SPINNER_PID" 2>/dev/null
    wait "$SPINNER_PID" 2>/dev/null
    unset SPINNER_PID
  fi
  if [ $rc -eq 0 ]; then
    printf "\r[✔] %s\n" "$SPINNER_MSG"
  else
    printf "\r[✖] %s\n" "$SPINNER_MSG"
  fi
}

packages_checker() {
  local packages="$1"
  local flag="$2"
  local missing=""
  local installed
  installed=$(opkg list-installed 2>/dev/null)

  for pkg in $packages; do
    if ! echo "$installed" | grep -q "^$pkg "; then
      missing="$missing $pkg"
    fi
  done

  if [ -n "$missing" ]; then
    print_message "Устанавливаем:$missing" "$GREEN"
    opkg update >/dev/null 2>&1
    opkg install $missing $flag
    echo ""
  fi
}

packages_delete() {
  delete_log=$(opkg remove $PACKAGES_LIST --autoremove 2>&1)
  removed_packages=""
  failed_packages=""

  for package in $PACKAGES_LIST; do
    if echo "$delete_log" | grep -q "Removing package $package"; then
      removed_packages="$removed_packages $package"
    elif echo "$delete_log" | grep -q "Package $package is depended upon by packages"; then
      failed_packages="$failed_packages $package"
    fi
  done

  if [ -n "$removed_packages" ]; then
    print_message "Пакеты успешно удалены:$removed_packages" "$GREEN"
  fi

  if [ -n "$failed_packages" ]; then
    print_message "Следующие пакеты не были удалены из-за зависимостей:$failed_packages" "$RED"
  fi

  if [ -z "$removed_packages" ] && [ -z "$failed_packages" ]; then
    print_message "Используемые пакеты не установлены" "$CYAN"
  fi
  if [ -f "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    print_message "Файл удален: $CONFIG_FILE" "$CYAN"
  fi
  exit_function
}

perform_dd() {
  local input_file="$1"
  local output_file="$2"

  checking_mtd_size "$input_file" "$output_file" || return 1
  sync
  echo 3 >/proc/sys/vm/drop_caches || true
  output=$(dd if="$input_file" of="$output_file" conv=fsync 2>&1 | tee /dev/tty)

  if echo "$output" | grep -iq "error\|can't"; then
    print_message "Ошибка при перезаписи раздела. Воспользуйтесь загрузчиком" "$RED"
    umountFS
    exit_function
  fi
}

checking_mtd_size() {
  local input_file="$1"
  local output_file="$2"

  if echo "$output_file" | grep -qE '^/dev/mtdblock[0-9]+'; then
    local mtd_index
    mtd_index=$(echo "$output_file" | grep -oE '[0-9]+$')
    [ -n "$mtd_index" ] || return 0

    local line size_hex part_size file_size
    line=$(grep "^mtd${mtd_index}:" /proc/mtd 2>/dev/null)
    [ -n "$line" ] || return 0

    set -- $line
    size_hex=$2
    echo "$size_hex" | grep -qiE '^[0-9a-f]+$' || return 0
    part_size=$((0x$size_hex))

    [ -f "$input_file" ] || return 0
    file_size=$(wc -c < "$input_file" 2>/dev/null)
    echo "$file_size" | grep -qE '^[0-9]+$' || return 0

    if [ "$file_size" -gt "$part_size" ]; then
      print_message "Файл больше выбранного раздела. Воспользуйтесь загрузчиком" "$RED"
      umount /tmp >/dev/null 2>&1
      exit_function
      return 1
    fi
  fi
  return 0
}

select_drive() {
  local message="$1"
  local media_output parsed_output
  local uuid display_name fstype total_bytes free_bytes used_bytes

  if ! ensure_jq; then
    print_message "Не удалось установить jq" "$RED"
    return 1
  fi

  uuids=""
  index=2
  media_output=$(rci_request "show/media")

  if [ -z "$media_output" ]; then
    print_message "Не удалось получить список накопителей" "$RED"
    return 1
  fi

  echo "0. Временное хранилище (tmp)"
  echo "1. Встроенное хранилище ($(get_internal_storage_size))"

  if ! parsed_output=$(printf '%s\n' "$media_output" | jq -r '
    to_entries[]
    | select(.value.bus != "mtd")
    | .value as $media
    | (($media.manufacturer // "") | if . != "" then . else ($media.product // "") end) as $device_name
    | ($media.partition // [])[]
    | select(.state == "MOUNTED" and ((.fstype // "" | ascii_downcase) != "swap"))
    | [
        (.uuid // ""),
        ((.label // "") | if $device_name != "" then
          $device_name + (if . != "" then " • " + . else "" end)
        elif . != "" then . else "Unknown" end),
        ((.fstype // "") | ascii_upcase),
        (.total // "0"),
        (.free // "0")
      ]
    | @tsv
  ' 2>/dev/null); then
    print_message "Не удалось обработать список накопителей" "$RED"
    return 1
  fi

  while IFS=$(printf '\t') read -r uuid display_name fstype total_bytes free_bytes; do
    [ -z "$uuid" ] && continue
    echo "$total_bytes" | grep -qE '^[0-9]+$' || total_bytes=0
    echo "$free_bytes" | grep -qE '^[0-9]+$' || free_bytes=0
    used_bytes=$((total_bytes - free_bytes))
    [ "$used_bytes" -lt 0 ] && used_bytes=0

    echo "$index. $display_name • ($fstype, $(format_size $used_bytes $total_bytes))"
    if [ -n "$uuids" ]; then
      uuids="$uuids
$uuid"
    else
      uuids="$uuid"
    fi
    index=$((index + 1))
  done <<EOF
$parsed_output
EOF

  exit_main_menu
  if ! read -r -p "$message " choice; then
    echo ""
    exit 0
  fi
  choice=$(echo "$choice" | tr -d ' \n\r')
  if [ "$choice" = "00" ]; then
    main_menu
  fi
  echo ""
  case "$choice" in
  0) selected_drive="$TMP_DIR" ;;
  1) selected_drive="$STORAGE_DIR" ;;
  *)
    if [ -n "$uuids" ]; then
      selected_drive=$(printf '%s\n' "$uuids" | sed -n "$((choice - 1))p")
      if [ -z "$selected_drive" ]; then
        print_message "Неверный выбор" "$RED"
        exit_function
      fi
      selected_drive="/tmp/mnt/$selected_drive"
    else
      print_message "Неверный выбор" "$RED"
      exit_function
    fi
    ;;
  esac
}

has_an_external_storage() {
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -q "$OPT_DIR"; then
      continue
    fi
    return 0
  done <<EOF
$(mount | grep "/dev/sd")
EOF
  return 1
}

backup_config() {
  if has_an_external_storage; then
    print_message "Обнаружены внешние накопители" "$CYAN"
    read -p "Создать бэкап startup-config? (y/n) " user_input
    user_input=$(echo "$user_input" | tr -d ' \n\r')

    case "$user_input" in
    y | Y)
      echo ""
      select_drive "Выберите накопитель для бэкапа:" || return 1

      if [ -n "$selected_drive" ]; then
        local device_uuid=$(echo "$selected_drive" | awk -F'/' '{print $NF}')
        local folder_path="$device_uuid:/backup$DATE"
        local backup_file="$folder_path/$(get_hw_id)_$(get_fw_version)_startup-config.txt"
        mkdir "$selected_drive/backup$DATE" || return 1
        rci_parse "copy startup-config $backup_file" >/dev/null 2>&1

        if [ $? -eq 0 ]; then
          print_message "Startup-config сохранен в $backup_file" "$GREEN"
        else
          print_message "Ошибка при сохранении бэкапа" "$RED"
          return 1
        fi
      else
        echo "Бэкап не выполнен, накопитель не выбран."
        return 1
      fi
      ;;
    *)
      echo ""
      ;;
    esac
  fi
}

exit_function() {
  ota_cleanup
  echo ""
  if [ ! -t 0 ]; then
    exit 0
  fi
  if ! read -n 1 -s -r -p "Для возврата нажмите любую клавишу..."; then
    echo ""
    exit 0
  fi
  pkill -P $$ 2>/dev/null
  exec "$OPT_DIR/$SCRIPT"
}

exit_main_menu() {
  printf "\n${CYAN}00. Выход в главное меню${NC}\n\n"
}

script_update() {
  packages_checker "curl libcurl"

  UPDATE_URLS="https://raw.githubusercontent.com/$USERNAME/$REPO/$BRANCH/$SCRIPT"

  update_success=0
  for url in $UPDATE_URLS; do
    response=$(curl -fLsS --connect-timeout 5 --max-time 10 "$url" --output "$TMP_DIR/$SCRIPT" 2>&1)
    if [ $? -eq 0 ] && [ -f "$TMP_DIR/$SCRIPT" ] && [ -s "$TMP_DIR/$SCRIPT" ]; then
      update_success=1
      break
    fi
    response=$(printf "%s\n" "$response" | head -n1)
    print_message "Ошибка: $response" "$RED"
    rm -f "$TMP_DIR/$SCRIPT"
  done

  if [ "$update_success" -eq 0 ]; then
    print_message "Не удалось загрузить обновление" "$RED"
    exit_function
  fi

  mv "$TMP_DIR/$SCRIPT" "$OPT_DIR/$SCRIPT"
  chmod +x "$OPT_DIR/$SCRIPT"
  print_message "Скрипт успешно обновлён" "$GREEN"
  sleep 1
  exec "$OPT_DIR/$SCRIPT"
}

mountFS() {
  mount -t tmpfs tmpfs /tmp
  print_message "LockFS: true"
}

umountFS() {
  sleep 1
  umount /tmp
  print_message "UnlockFS: true"
}

get_ota_domain() {
  local domain="" confirm
  if [ "${1:-}" != "new" ] && [ -f "$CONFIG_FILE" ]; then
    domain=$(sed -n 's/^domain="\(.*\)"$/\1/p' "$CONFIG_FILE" | head -n 1)
  fi
  if [ -z "$domain" ]; then
    if [ "${1:-}" = "new" ]; then
      if ! read -r -p "Изменить домен? (y/n) " confirm; then
        return 1
      fi
      case "$confirm" in
      y | Y) ;;
      *) return 1 ;;
      esac
    fi
    if ! read -r -p "Введите домен: " domain; then
      return 1
    fi
  fi

  domain=$(printf '%s' "$domain" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s|/*$||')
  if [ -z "$domain" ]; then
    print_message "Домен не указан" "$RED" >&2
    return 1
  fi
  printf '%s\n' "$domain"
}

save_ota_domain() {
  local domain="$1" tmp
  domain=$(printf '%s' "$domain" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s|/*$||')
  [ -n "$domain" ] || return 1
  mkdir -p "${CONFIG_FILE%/*}" || return 1
  tmp="$CONFIG_FILE.tmp"
  if [ -f "$CONFIG_FILE" ]; then
    grep -v '^domain=' "$CONFIG_FILE" > "$tmp" 2>/dev/null
  else
    : > "$tmp"
  fi
  printf 'domain="%s"\n' "$domain" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE" || return 1
  print_message "Домен сохранён в $CONFIG_FILE" "$GREEN"
}

# Неинтерактивное определение OTA-домена: конфиг -> иначе домен по умолчанию.
resolve_ota_domain() {
  local domain=""
  [ -f "$CONFIG_FILE" ] && domain=$(sed -n 's/^domain="\(.*\)"$/\1/p' "$CONFIG_FILE" | head -n 1)
  domain=$(printf '%s' "$domain" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s|/*$||')
  [ -n "$domain" ] || domain="$OTA_DOMAIN_DEFAULT"
  printf '%s\n' "$domain"
}

ota_request() {
  local url="$1"
  shift
  if ! curl -fLsS --basic --max-time 7 "$url" "$@"; then
    url=$(printf '%s' "$url" | sed 's/%/%%/g')
    print_message "Не удалось загрузить: $url" "$RED" >&2
    return 1
  fi
}

ota_cleanup() {
  if [ -n "$progress_pid" ]; then
    kill "$progress_pid" 2>/dev/null
    wait "$progress_pid" 2>/dev/null
    unset progress_pid
  fi
  if [ -n "$DOWNLOAD_PATH" ] && [ -n "$FILE" ]; then
    rm -f "$DOWNLOAD_PATH/$FILE" "$DOWNLOAD_PATH/md5sum"
  fi
  unset DOWNLOAD_PATH FILE
}

uboot_write_aarch64() {
  local image="$1" module="$TMP_DIR/mtd_rw_all.ko" writer="$TMP_DIR/keenboot_writer" rc
  local base="$PAGES_URL/files/keenboot/modules" file
  for file in mtd_rw_all.ko keenboot_writer; do
    if ! ota_request "$base/$file" -o "$TMP_DIR/$file"; then
      rm -f "$module" "$writer"
      return 1
    fi
    if [ ! -s "$TMP_DIR/$file" ]; then
      print_message "Файл пуст или не был загружен: $(printf '%s' "$base/$file" | sed 's/%/%%/g')" "$RED"
      rm -f "$module" "$writer"
      return 1
    fi
  done
  chmod +x "$writer" || return 1
  rmmod mtd2_unlock 2>/dev/null || true
  rmmod mtd_rw_all 2>/dev/null || true
  insmod "$module" || return 1
  "$writer" WRITE "$image"
  rc=$?
  rmmod mtd_rw_all 2>/dev/null || true
  rm -f "$module" "$writer"
  return "$rc"
}

show_progress() {
  local total_size="$1"
  local downloaded=0
  local progress=0
  local file_path="$2"
  local file_name="$3"
  local stop_requested=false final_update
  trap 'stop_requested=true' TERM

  while [ "$downloaded" -lt "$total_size" ]; do
    final_update="$stop_requested"
    if [ -f "$file_path" ]; then
      downloaded=$(ls -l "$file_path" | awk '{print $5}')
      progress=$((downloaded * 100 / total_size))
      printf "\rЗагрузка $file_path... (%d%%)" "$progress"
    fi
    [ "$final_update" = true ] && break
    sleep 1
  done
  printf "\n"
}

ota_update() {
  check_host
  local ota_mode="${1:-firmware}" arch domain ota_path osvault file_url md5_url
  packages_checker "curl findutils libcurl"
  if [ "$ota_mode" = "keenboot" ]; then
    arch=$(get_architecture)
    [ "$arch" != "mipsel" ] || is_uboot_writable || return 1
    packages_checker "xz"
    ota_path="/files/keenboot/$arch"
  else
    ota_path="/osvault"
  fi
  domain=$(get_ota_domain) || { exit_function; return 1; }
  while true; do
    osvault="$domain$ota_path"
    if REQUEST=$(ota_request "$osvault"); then
      DIRS=$(echo "$REQUEST" | grep -o 'href="[^"]*"' | cut -d'"' -f2 | grep -E '^[^/?#]+/$' | grep -vE '^\.\.?/$' | sed 's|/$||' | sed 's|%20| |g')
      [ -z "$DIRS" ] || break
      print_message "Не найдены каталоги OTA: $(printf '%s' "$osvault" | sed 's/%/%%/g')" "$RED"
    fi
    domain=$(get_ota_domain new) || { exit_function; return 1; }
  done
  save_ota_domain "$domain"

  local current_device_model=$(get_device)
  print_list_with_highlight "$DIRS" "$current_device_model"
  exit_main_menu
  dir_count=$(echo "$DIRS" | wc -l)
  while true; do
    if ! read -r -p "Выберите папку (от 1 до $dir_count): " DIR_NUM; then
      echo ""
      exit 0
    fi
    if [ "$DIR_NUM" = "00" ]; then
      main_menu
    fi
    if echo "$DIR_NUM" | grep -qE '^[0-9]+$' && [ "$DIR_NUM" -ge 1 ] && [ "$DIR_NUM" -le "$dir_count" ]; then
      break
    else
      print_message "Неверный выбор. Выберите от 1 до $dir_count." "$RED"
    fi
  done
  DIR=$(echo "$DIRS" | sed -n "${DIR_NUM}p")
  DIR_ENCODED=$(echo "$DIR" | sed 's/ /%20/g')

  REQUEST=$(ota_request "$osvault/$DIR_ENCODED/") || { exit_function; return 1; }
  BIN_FILES=$(echo "$REQUEST" | grep -o 'href="[^"]*"' | cut -d'"' -f2 | grep '\.bin$' | sed 's|%20| |g')

  if [ -z "$BIN_FILES" ]; then
    print_message "В директории $(printf '%s' "$osvault/$DIR_ENCODED/" | sed 's/%/%%/g') нет файлов." "$RED"
    exit_function
  else
    printf "\nВерсии для $DIR:\n"
    print_list_with_highlight "$BIN_FILES" "$current_device_model"
    exit_main_menu
    file_count=$(echo "$BIN_FILES" | wc -l)
    while true; do
      if ! read -r -p "Выберите версию (от 1 до $file_count): " FILE_NUM; then
        echo ""
        exit 0
      fi
      if [ "$FILE_NUM" = "00" ]; then
        unset FILE
        unset DOWNLOAD_PATH
        unset use_mount
        unset progress_pid
        main_menu
        return
      fi
      if echo "$FILE_NUM" | grep -qE '^[0-9]+$' && [ "$FILE_NUM" -ge 1 ] && [ "$FILE_NUM" -le "$file_count" ]; then
        break
      else
        print_message "Неверный выбор. Выберите от 1 до $file_count." "$RED"
      fi
    done
    FILE=$(echo "$BIN_FILES" | sed -n "${FILE_NUM}p")
    FILE_ENCODED=$(echo "$FILE" | sed 's/ /%20/g')

    if [ -z "$FILE" ]; then
      print_message "Файл не выбран" "$RED"
      exit_function
    fi
    file_url="$osvault/$DIR_ENCODED/$FILE_ENCODED"
    md5_url="$osvault/$DIR_ENCODED/md5sum"
    total_size=$(ota_request "$file_url" -I | grep -i content-length | tail -n 1 | awk '{print $2}' | tr -d '\r')
    if ! echo "$total_size" | grep -qE '^[0-9]+$' || [ "$total_size" -le 0 ]; then
      print_message "Не удалось определить размер файла: $(printf '%s' "$file_url" | sed 's/%/%%/g')" "$RED"
      exit_function
    fi
    total_size_mb=$((total_size / 1024 / 1024))
    free_space_mb=$(get_internal_storage_size free)
    if [ -n "$free_space_mb" ] && [ "$free_space_mb" -ge "$total_size_mb" ]; then
      DOWNLOAD_PATH="$STORAGE_DIR"
      use_mount=true
    else
      DOWNLOAD_PATH="$TMP_DIR"
      use_mount=false
    fi
    mkdir -p "$DOWNLOAD_PATH"
    echo ""
    show_progress "$total_size" "$DOWNLOAD_PATH/$FILE" "$FILE" &
    progress_pid=$!
    if ! ota_request "$file_url" --output "$DOWNLOAD_PATH/$FILE"; then
      kill "$progress_pid" 2>/dev/null
      wait "$progress_pid" 2>/dev/null
      rm -f "$DOWNLOAD_PATH/$FILE"
      exit_function
      return 1
    fi
    kill "$progress_pid" 2>/dev/null
    wait "$progress_pid" 2>/dev/null
    unset progress_pid
    if [ ! -s "$DOWNLOAD_PATH/$FILE" ]; then
      print_message "Файл пуст или не был загружен: $(printf '%s' "$file_url" | sed 's/%/%%/g')" "$RED"
      exit_function
      return 1
    fi

    if ! ota_request "$md5_url" --output "$DOWNLOAD_PATH/md5sum"; then
      rm -f "$DOWNLOAD_PATH/$FILE" "$DOWNLOAD_PATH/md5sum"
      exit_function
      return 1
    fi
    MD5SUM_REMOTE=$(grep "$FILE" "$DOWNLOAD_PATH/md5sum" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
    MD5SUM_LOCAL=$(md5sum "$DOWNLOAD_PATH/$FILE" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
    if [ "$MD5SUM_REMOTE" != "$MD5SUM_LOCAL" ]; then
      printf "${RED}MD5 хеш не совпадает.${NC}\n"
      echo "Ожидаемый: $MD5SUM_REMOTE"
      echo "Фактический: $MD5SUM_LOCAL"
      rm -f "$DOWNLOAD_PATH/$FILE"
      rm -f "$DOWNLOAD_PATH/md5sum"
      exit_function
    fi
    if [ "$ota_mode" = "keenboot" ]; then
      print_message "Внимание! Обновление загрузчика опасная процедура, может привести к неработоспособности устройства!" "$RED"
    fi
    printf "${GREEN}MD5 хеш совпадает${NC}\n\n"
    read -p "$(printf "Выбран ${GREEN}$FILE${NC} для обновления, всё верно? (y/n) ")" CONFIRM
    case "$CONFIRM" in
    y | Y)
      if [ "$ota_mode" = "keenboot" ]; then
        if [ "$arch" = "aarch64" ]; then
          uboot_write_aarch64 "$DOWNLOAD_PATH/$FILE"
        else
          ubootSlot=$(get_mtd_index_by_name "U-Boot")
          perform_dd "$DOWNLOAD_PATH/$FILE" "/dev/mtdblock$ubootSlot"
        fi
        update_rc=$?
      else
        update_firmware_block "$DOWNLOAD_PATH/$FILE" "$use_mount"
        update_rc=$?
      fi
      ;;
    *)
      if [ "$CONFIRM" != "n" ] && [ "$CONFIRM" != "N" ]; then
        print_message "Неверный выбор" "$RED"
      fi
      ;;
    esac

    ota_cleanup

    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
      if [ "$update_rc" -eq 2 ]; then
        exit 0
      fi
      if [ "$update_rc" -ne 2 ]; then
        if [ "$update_rc" -ne 0 ]; then
          print_message "Обновление завершилось с ошибкой" "$RED"
          exit_function
        fi
        if [ "$ota_mode" = "keenboot" ]; then
          print_message "Загрузчик успешно обновлён" "$GREEN"
          exit_function
        else
          print_message "Успешно обновлено. Перезагрузка устройства..." "$GREEN"
          sleep 1
          reboot
        fi
      fi
    else
      exit_function
    fi
  fi
}

update_firmware_legacy() {
  local firmware="$1"
  local use_mount="$2"
  if [ "$use_mount" = true ] || [[ "$firmware" == *"$STORAGE_DIR"* ]]; then
    mountFS
  fi

  for partition in Firmware Firmware_1 Firmware_2; do
    if [ "$partition" = "Firmware_2" ] && (get_ndm_storage || [ "$(get_boot_current)" = "1" ]); then
      continue
    fi
    mtd_index=$(get_mtd_index_by_name "$partition")
    [ -z "$mtd_index" ] && continue

    echo "Обновляю $partition..."
    perform_dd "$firmware" "/dev/mtdblock$mtd_index"
    echo ""
  done

  if [ "$use_mount" = true ] || [[ "$firmware" == *"$STORAGE_DIR"* ]]; then
    umountFS
  fi
}

update_firmware_dual() {
  local firmware="$1"
  local use_mount="$2"
  local current_slot new_slot
  local fw_slot1 fw_slot2
  local target_fw_slot

  current_slot="$(get_boot_current)"
  if ! echo "$current_slot" | grep -qE '^[12]$'; then
    print_message "Не удалось определить текущий слот: $current_slot. Использую стандартный режим обновления." "$RED"
    update_firmware_legacy "$firmware" "$use_mount"
    return
  fi

  fw_slot1=$(get_mtd_index_by_name "Firmware_1")
  fw_slot2=$(get_mtd_index_by_name "Firmware_2")
  case "$current_slot" in
  1)
    new_slot=2
    target_fw_slot="$fw_slot2"
    ;;
  2)
    new_slot=1
    target_fw_slot="$fw_slot1"
    ;;
  esac

  print_message "Текущий слот: $current_slot. Записываю прошивку в слот: $new_slot" "$CYAN"
  if native_fwupdate "$firmware"; then
    print_message "Прошивка успешно обновлена. Перезагрузка устройства..." "$GREEN"
    return 2
  fi
  perform_dd "$firmware" "/dev/mtdblock$target_fw_slot"

  if ! copy_dual_config "$current_slot" "$new_slot"; then
    print_message "Ошибка при копировании конфигурации, слот не будет переключён на $new_slot." "$RED"
    return 1
  fi

  print_message "Переключаюсь на $new_slot слот" "$CYAN"
  if ! change_boot_slot; then
    print_message "Ошибка при переключении слота на $new_slot." "$RED"
    return 1
  fi
}

update_firmware_block() {
  local firmware="$1"
  local use_mount="$2"
  local arch
  arch="$(get_architecture)"

  if [ "$arch" = "aarch64" ]; then
    local ram_size=$(get_ram_size)
    if [ "$ram_size" -lt "$MIN_RAM_SIZE_AARCH64" ]; then
      print_message "Мало оперативной памяти ($ram_size MB)" "$RED"
      read -p "Рекомендуется обновление через загрузчик. Продолжить? (y/n) " confirm
      confirm=$(echo "$confirm" | tr -d ' \n\r')
      case "$confirm" in
      y | Y) ;;
      n | N) exit_function ;;
      *) ;;
      esac
    fi
  fi

  backup_config || return 1
  if get_ndm_storage; then
    update_firmware_legacy "$firmware" "$use_mount"
  else
    update_firmware_dual "$firmware" "$use_mount"
  fi
}

find_files() {
  local search_path="$1"
  local min_size="$2"
  local exclude_pattern="$3"

  if [ "$search_path" = "$TMP_DIR" ]; then
    if [ -n "$exclude_pattern" ]; then
      find "$search_path" -name '*.bin' -size +"$min_size" -not -path '*/mnt/*' -not -path "$exclude_pattern"
      return
    fi
    find "$search_path" -name '*.bin' -size +"$min_size" -not -path '*/mnt/*'
    return
  fi

  if [ -n "$exclude_pattern" ]; then
    find "$search_path" -name '*.bin' -size +"$min_size" -not -path "$exclude_pattern"
    return
  fi

  find "$search_path" -name '*.bin' -size +"$min_size"
}

firmware_manual_update() {
  packages_checker "findutils"
  ram_size=$(get_ram_size)

  if [ "$ram_size" -lt $MIN_RAM_SIZE ]; then
    print_message "Обновление возможно только со встроенного накопителя Entware" "$CYAN"
    selected_drive="$STORAGE_DIR"
    use_mount=true
  else
    select_drive "Выберите накопитель с размещённым файлом обновления:" || return 1
    use_mount=false
  fi

  files=$(find_files "$selected_drive" "1M")
  count=$(echo "$files" | wc -l)

  if [ -z "$files" ]; then
    print_message "Файл обновления не найден на накопителе" "$RED"
    exit_function
  fi

  echo "$files" | sed "s|$selected_drive/||" | awk '{print NR".", $0}'
  exit_main_menu
  read -p "Выберите файл обновления (от 1 до $count): " choice
  choice=$(echo "$choice" | tr -d ' \n\r')
  if [ "$choice" = "00" ]; then
    main_menu
  fi
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
    print_message "Неверный выбор файла" "$RED"
    exit_function
  fi

  Firmware=$(echo "$files" | awk "NR==$choice")
  FirmwareName=$(basename "$Firmware")
  echo ""
  read -p "$(printf "Выбран ${GREEN}$FirmwareName${NC} для обновления, всё верно? (y/n) ")" item_rc1
  item_rc1=$(echo "$item_rc1" | tr -d ' \n\r')
  case "$item_rc1" in
  y | Y)
    update_firmware_block "$Firmware" "$use_mount"
    update_rc=$?
    if [ "$update_rc" -eq 2 ]; then
      exit 0
    fi
    if [ "$update_rc" -ne 0 ]; then
      print_message "Обновление завершилось с ошибкой" "$RED"
      exit_function
    fi
    print_message "Прошивка успешно обновлена" "$GREEN"
    printf "${NC}"
    read -p "Удалить файл обновления? (y/n) " item_rc2
    item_rc2=$(echo "$item_rc2" | tr -d ' \n\r')
    case "$item_rc2" in
    y | Y)
      rm "$Firmware"
      sleep 2
      ;;
    n | N)
      echo ""
      ;;
    *) ;;
    esac
    print_message "Перезагрузка устройства..." "${CYAN}"
    sleep 1
    reboot
    ;;
  esac
  main_menu
}

backup_block() {
  select_drive "Выберите накопитель для бэкапа:" || return 1
  mtd_output=$(cat /proc/mtd)
  printf "\n${GREEN}Доступные разделы:${NC}\n"
  echo "$mtd_output" | awk 'NR>1 {print $0}'
  printf "99. Бэкап всех разделов${NC}\n"
  exit_main_menu
  folder_path="$selected_drive/backup$DATE"
  read -p "Укажите номер(а) раздела(ов) разделив пробелами: " choice
  echo ""
  choice=$(echo "$choice" | tr -d '\n\r')

  if [ "$choice" = "00" ]; then
    main_menu
  fi

  error_occurred=0
  non_existent_parts=""
  valid_parts=0

  if [ "$choice" = "99" ]; then
    output_all_mtd=$(cat /proc/mtd | grep -c "mtd")
    for i in $(seq 0 $(($output_all_mtd - 1))); do
      mtd_name=$(echo "$mtd_output" | awk -v i=$i 'NR==i+2 {gsub(/"/, "", $4); print $4}')
      if [ $valid_parts -eq 0 ]; then
        mkdir "$folder_path" || return 1
        valid_parts=1
      fi

      spinner_start "Копирую mtd$i.$mtd_name.bin"
      if cat "/dev/mtdblock$i" >"$folder_path/mtd$i.$mtd_name.bin"; then
        spinner_stop 0
      else
        spinner_stop 1
        error_occurred=1
        break
      fi
    done
  else
    for part in $choice; do
      if ! echo "$mtd_output" | awk -v i=$part 'NR==i+2 {print $1}' | grep -q "mtd$part"; then
        non_existent_parts="$non_existent_parts $part"
        continue
      fi

      selected_mtd=$(echo "$mtd_output" | awk -v i=$part 'NR==i+2 {gsub(/"/, "", $4); print $4}')

      if [ $valid_parts -eq 0 ]; then
        mkdir "$folder_path" || return 1
        valid_parts=1
      fi

      spinner_start "Копирую mtd$part.$selected_mtd.bin"
      if dd if="/dev/mtd$part" of="$folder_path/mtd$part.$selected_mtd.bin" >/dev/null 2>&1; then
        spinner_stop 0
      else
        spinner_stop 1
        error_occurred=1
      fi
    done
  fi

  if [ -n "$non_existent_parts" ]; then
    print_message "Ошибка: Раздела${non_existent_parts} не существует!" "$RED"
    error_occurred=1
  fi

  if [ "$error_occurred" -eq 0 ] && [ $valid_parts -eq 1 ]; then
    print_message "Успешно сохранено в $folder_path" "$GREEN"
  else
    print_message "Ошибка при сохранении." "$RED"
  fi
  exit_function
}

backup_entware() {
  packages_checker "tar libacl"
  select_drive "Выберите накопитель:" || return 1
  backup_file="$selected_drive/$(get_architecture)_entware_backup_$DATE.tar.gz"
  spinner_start "Выполняю копирование"
  tar_output=$(tar cvzf "$backup_file" -C "$OPT_DIR" --exclude="$(basename "$backup_file")" . 2>&1)
  rc=$?

  log_operation=$(echo "$tar_output" | tail -n 2)
  if echo "$log_operation" | grep -iq "error\|no space left on device"; then
    spinner_stop 1
    print_message "Ошибка при создании бэкапа:" "$RED"
    echo "$log_operation"
  else
    spinner_stop 0
    print_message "Бэкап успешно сохранен в $backup_file" "$GREEN"
  fi
  exit_function
}

rewrite_block() {
  check_host
  select_drive "Выберите накопитель с размещённым файлом:" || return 1
  files=$(find_files "$selected_drive" "60k")
  count=$(echo "$files" | wc -l)
  if [ -z "$files" ]; then
    print_message "Файл для замены не найден в выбранном хранилище" "$RED"
    exit_function
  fi
  echo "Найдены файлы:"
  echo "$files" | sed "s|$selected_drive/||" | awk '{print NR".", $0}'
  exit_main_menu
  read -p "Выберите файл для замены: " choice
  choice=$(echo "$choice" | tr -d ' \n\r')
  if [ "$choice" = "00" ]; then
    main_menu
  fi
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
    print_message "Неверный выбор файла" "$RED"
    exit_function
  fi

  mtdFile=$(echo "$files" | awk "NR==$choice")
  mtdName=$(basename "$mtdFile")
  echo ""
  mtd_output=$(cat /proc/mtd)
  echo "$mtd_output" | awk 'NR>1 {print $0}'
  exit_main_menu
  read -p "Укажите номер(а) раздела(ов) разделив пробелами: " choice
  choice=$(echo "$choice" | tr -d '\n\r')

  if [ "$choice" = "00" ]; then
    main_menu
  fi

  error_occurred=0
  non_existent_parts=""
  valid_parts=0
  arch="$(get_architecture)"

  for part in $choice; do
    if ! echo "$mtd_output" | awk -v i=$part 'NR==i+2 {print $1}' | grep -q "mtd$part"; then
      non_existent_parts="$non_existent_parts $part"
      continue
    fi

    selected_mtd=$(echo "$mtd_output" | awk -v i=$part 'NR==i+2 {gsub(/"/, "", $4); print $4}')

    if [ "$selected_mtd" = "U-Boot" ]; then
      print_message "Внимание! Перезапись загрузчика опасная процедура, может привести к неработоспособности устройства!" "$RED"
    fi

    echo ""
    read -r -p "$(printf "Перезаписать раздел ${CYAN}mtd$part.$selected_mtd${NC} вашим ${GREEN}$mtdName${NC}? (y/n) ")" item_rc1
    item_rc1=$(echo "$item_rc1" | tr -d ' \n\r')
    case "$item_rc1" in
    y | Y)
      if [[ "$mtdFile" == *"$STORAGE_DIR"* ]]; then
        mountFS
      fi

      if [ "$selected_mtd" = "U-Boot" ] && [ "$arch" = "aarch64" ]; then
        if uboot_write_aarch64 "$mtdFile"; then
          print_message "Раздел успешно перезаписан" "$GREEN"
        else
          print_message "Ошибка при перезаписи U-Boot" "$RED"
          error_occurred=1
        fi
      else
        if perform_dd "$mtdFile" "/dev/mtdblock$part"; then
          print_message "Раздел успешно перезаписан" "$GREEN"
        else
          print_message "Ошибка при перезаписи раздела" "$RED"
          error_occurred=1
        fi
      fi

      if [[ "$mtdFile" == *"$STORAGE_DIR"* ]]; then
        umountFS
      fi
      ;;
    n | N)
      echo ""
      ;;
    *) ;;
    esac
  done

  if [ -n "$non_existent_parts" ]; then
    print_message "Ошибка: Раздела${non_existent_parts} не существует!" "$RED"
    error_occurred=1
  fi

  if [ "$error_occurred" -eq 0 ]; then
    read -r -p "Перезагрузить роутер? (y/n) " item_rc2
    item_rc2=$(echo "$item_rc2" | tr -d ' \n\r')
    case "$item_rc2" in
    y | Y)
      reboot
      ;;
    n | N)
      echo ""
      ;;
    *) ;;
    esac
  fi
  exit_function
}

service() {
  check_host
  folder_path="$OPT_DIR/backup$DATE"
  SCRIPT_PATH="$TMP_DIR/service.py"
  target_flag=$1
  packages_checker "curl python3-base python3 python3-light libpython3 findutils" "--nodeps"

  local service_url="$PAGES_URL/service.py"
  curl -fLs "$service_url" --output "$SCRIPT_PATH"
  if [ $? -ne 0 ] || ! head -n1 "$SCRIPT_PATH" | grep -q "^#\|^import\|^def\|^class"; then
    print_message "Ошибка при получении файла: $service_url" "$RED"
    exit_function
  fi

  mkdir -p "$folder_path"
  mtdSlot=$(get_mtd_index_by_name "U-Config")
  mtdSlot_res=$(get_mtd_index_by_name "U-Config_res")
  if [ -n "$mtdSlot" ]; then
    perform_dd "/dev/mtd$mtdSlot" "$folder_path/U-Config.bin"
    if [ $? -eq 0 ]; then
      print_message "Бэкап текущего U-Config сохранён в $folder_path" "$GREEN"
    else
      print_message "Ошибка при создании бэкапа U-Config" "$RED"
    fi
  fi

  if [ -n "$target_flag" ]; then
    python3 "$SCRIPT_PATH" "$folder_path/U-Config.bin" "$target_flag"
  else
    python3 "$SCRIPT_PATH" "$folder_path/U-Config.bin"
  fi

  mtdFile=$(find "$folder_path" -type f -name 'U-Config_*.bin' | head -n 1)
  if [ -n "$mtdFile" ]; then
    print_message "Новые сервисные данные сохранены в $mtdFile" "$GREEN"
  else
    print_message "Не удалось подготовить новые сервисные данные" "$RED"
    exit_function
  fi
  read -p "Продолжить замену? (y/n) " item_rc1
  item_rc1=$(echo "$item_rc1" | tr -d ' \n\r')
  case "$item_rc1" in
  y | Y)
    echo ""
    printf "${CYAN}Перезаписываю раздел...${NC}\n"
    perform_dd "$mtdFile" "/dev/mtdblock$mtdSlot"
    if [ -n "$mtdSlot_res" ]; then
      echo ""
      printf "${CYAN}Найден второй раздел, перезаписываю...${NC}\n"
      perform_dd "$mtdFile" "/dev/mtdblock$mtdSlot_res"
    fi
    if [ $? -eq 0 ]; then
      print_message "Сервисные данные успешно заменены" "$GREEN"
    else
      print_message "Ошибка при выполнении замены" "$RED"
    fi
    ;;
  esac
  read -p "Перезагрузить роутер? (y/n) " item_rc2
  item_rc2=$(echo "$item_rc2" | tr -d ' \n\r')
  case "$item_rc2" in
  y | Y)
    echo ""
    reboot
    ;;
  n | N)
    echo ""
    ;;
  *) ;;
  esac
  exit_function
}

changeLanguage() {
  if [ "$BRANCH" = "main" ]; then
    BRANCH_NEW="main-english"
  else
    BRANCH_NEW="main"
  fi
  print_message "Switching..." "$CYAN"
  if curl -fL -s "https://raw.githubusercontent.com/$USERNAME/$REPO/${BRANCH_NEW}/install.sh" --output /tmp/install.sh &&
    [ -s /tmp/install.sh ]; then
    exec sh /tmp/install.sh
  else
    print_message "Error switching" "$RED"
    exit_function
  fi
}

cleanup() {
  rc=$?
  ota_cleanup
  if [ -n "$SPINNER_PID" ]; then
    kill "$SPINNER_PID" 2>/dev/null
    wait "$SPINNER_PID" 2>/dev/null
    printf "\r\n"
    unset SPINNER_PID
  fi
  pkill -P $$ 2>/dev/null
  exit "$rc"
}

# ============================================================================
#  MeshkitKeen: неинтерактивный режим + управление mesh-узлами
#  (дополнение поверх полного KeenKit; весь оригинальный код выше сохранён)
# ============================================================================

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  local key val
  while IFS='=' read -r key val; do
    case "$key" in
      ssh_user) SSH_USER=$(printf '%s' "$val" | sed 's/^"//; s/"$//') ;;
      ssh_port) SSH_PORT=$(printf '%s' "$val" | sed 's/^"//; s/"$//') ;;
    esac
  done < "$CONFIG_FILE"
  [ -n "$SSH_USER" ] || SSH_USER="root"
  [ -n "$SSH_PORT" ] || SSH_PORT="222"
}

get_cpuload() {
  json_get_value "${1:-$(rci_request "show/system")}" '.cpuload'
}

detect_ssh() {
  local b
  for b in /opt/bin/dbclient /opt/bin/ssh /usr/bin/ssh; do
    [ -x "$b" ] && { SSH_BIN="$b"; break; }
  done
  [ -n "$SSH_BIN" ] || SSH_BIN="ssh"
}

ssh_ready() {
  [ -f "$SSH_KEY" ] && detect_ssh
}

ssh_node() {
  local ip="$1" cmd="$2"
  [ -n "$SSH_BIN" ] || detect_ssh
  if $SSH_BIN -h 2>&1 | grep -qi dropbear; then
    $SSH_BIN -y -y -q -i "$SSH_KEY" -l "$SSH_USER" -p "$SSH_PORT" "$ip" "$cmd" 2>&1
  else
    $SSH_BIN -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -l "$SSH_USER" -p "$SSH_PORT" "$ip" "$cmd" 2>&1
  fi
}

get_members() {
  rci_request "show/mws/member"
}

get_member_ips() {
  get_members | jq -r '.[] | select(.ip != null) | .ip' 2>/dev/null
}

# --- Wi-Fi: универсальная поддержка 2.4 / 5 / 6 ГГц (Wi-Fi 6/6E/7) ----------
wifi_band_to_ap() {
  case "$1" in
    2.4) echo "WifiMaster0/AccessPoint0" ;;
    5)   echo "WifiMaster1/AccessPoint0" ;;
    6)   echo "WifiMaster2/AccessPoint0" ;;
    *)   return 1 ;;
  esac
}

wifi_available_bands() {
  local ifaces i
  ifaces=$(rci_request "show/interface" | jq -r 'keys[] | select(test("^WifiMaster[0-9]+$"))' 2>/dev/null)
  for i in $ifaces; do
    case "$i" in
      WifiMaster0) echo "2.4" ;;
      WifiMaster1) echo "5" ;;
      WifiMaster2) echo "6" ;;
    esac
  done
}

wifi_target_aps() {
  local band="$1" b
  case "$band" in
    2.4|5|6) wifi_band_to_ap "$band" ;;
    all) for b in $(wifi_available_bands); do wifi_band_to_ap "$b"; done ;;
    *) return 1 ;;
  esac
}

wifi_control_local() {
  local band="$1" action="$2" aps ap
  aps=$(wifi_target_aps "$band")
  [ -n "$aps" ] || { echo "Неверный диапазон: $band (нужно 2.4 | 5 | 6 | all)" >&2; return 1; }
  for ap in $aps; do
    echo "  $action $ap"
    rci_parse "[{\"interface\":{\"$ap\":{\"$action\":true}}}]" >/dev/null 2>&1
  done
}

# --- Команды ----------------------------------------------------------------

cmd_status() {
  load_config
  ensure_jq

  local self_version self_system device fw hwid cpuload ram uptime disk label
  self_version=$(rci_request "show/version")
  self_system=$(rci_request "show/system")
  device=$(get_device "$self_version")
  fw=$(get_fw_version "$self_version")
  hwid=$(get_hw_id "$self_version")
  cpuload=$(get_cpuload "$self_system")
  ram=$(get_ram_usage "$self_system")
  uptime=$(get_uptime "$self_system")
  label=$(json_get_value "$(rci_request "show/sc/opkg/disk")" '.disk | rtrimstr("/") | rtrimstr(":")')
  disk=$(get_opkg_storage)

  printf "${CYAN}MeshkitKeen v%s (KeenKit %s) — mesh-сеть Keenetic${NC}\n\n" "$FORK_VERSION" "$SCRIPT_VERSION"

  printf "${GREEN}Контроллер (self)${NC}\n"
  printf "  Модель:        %s (%s)\n" "$device" "$hwid"
  printf "  Прошивка:      %s\n" "$fw"
  printf "  CPU:           %s%% | %s\n" "$cpuload" "$(get_cpu_model)"
  printf "  ОЗУ:           %s\n" "$ram"
  printf "  Накопитель:    %s %s\n" "$label" "$disk"
  printf "  Uptime:        %s\n\n" "$uptime"

  local members member_count ip model mfw mfw_avail mcpu mram muptime mspeed mode mac
  members=$(get_members)
  if [ -z "$members" ] || ! echo "$members" | grep -q '^\['; then
    echo "Mesh-узлы не обнаружены (show/mws/member пуст)."
    return 0
  fi

  member_count=$(echo "$members" | jq 'length' 2>/dev/null)
  printf "${GREEN}Mesh-узлы (%s)${NC}\n" "$member_count"

  echo "$members" | jq -r '.[] | select(.ip != null) |
    [.ip, (.model // "?"), (.fw // "?"), (."fw-available" // ""), (.system.cpuload // "?"),
     (.system.memory // "?"), (.system.uptime // "0"),
     (.backhaul.speed // "0"), (.mode // "?"), (.mac // "?")]
    | @tsv' 2>/dev/null | while IFS=$(printf '\t') read -r ip model mfw mfw_avail mcpu mram muptime mspeed mode mac; do
    [ -n "$ip" ] || continue
    ram=$(printf '%s' "$mram" | awk -F/ '{ if ($2) printf "%d / %d MB", $1/1024, $2/1024; else print "?" }')
    local upd
    if [ -n "$mfw_avail" ]; then
      if [ "$mfw_avail" = "$mfw" ]; then
        upd="нет (актуальна)"
      else
        upd="${YELLOW}ДОСТУПНО: $mfw_avail${NC}"
      fi
    else
      upd="—"
    fi
    printf "\n  ${CYAN}%s${NC}  (%s, %s)\n" "$model" "$mode" "$ip"
    printf "    MAC:          %s\n" "$mac"
    printf "    Прошивка:     %s\n" "$mfw"
    printf "    Обновление:   %s\n" "$upd"
    printf "    Backhaul:     %s Мбит/с\n" "$mspeed"
    printf "    CPU:          %s%%\n" "$mcpu"
    printf "    ОЗУ:          %s\n" "$ram"
    printf "    Uptime:       %s\n" "$(format_uptime_seconds "$muptime")"
    if ssh_ready; then
      local ndisk
      ndisk=$(ssh_node "$ip" "df -h /opt 2>/dev/null | tail -1 | awk '{print \$3\"/\"\$2}'" 2>/dev/null | tail -1)
      [ -n "$ndisk" ] && printf "    Накопитель:   %s\n" "$ndisk"
    fi
  done
  printf "\n"
  if ! ssh_ready; then
    printf "${YELLOW}SSH-ключ для узлов не настроен. Выполните: meshkitkeen setup${NC}\n"
  fi
}

cmd_reboot() {
  load_config
  local target="${1:-self}"
  case "$target" in
    self)
      print_message "Перезагрузка контроллера..." "$YELLOW"
      rci_parse '[{"system":{"reboot":true}}]' >/dev/null 2>&1
      echo "Команда перезагрузки отправлена."
      ;;
    all)
      local ip
      for ip in $(get_member_ips); do cmd_reboot "$ip"; done
      cmd_reboot self
      ;;
    *)
      ssh_ready || { echo "Сначала выполните: meshkitkeen setup" >&2; return 1; }
      echo "Перезагрузка узла $target..."
      ssh_node "$target" "ndmc -c 'system reboot'" 2>&1
      ;;
  esac
}

cmd_wifi() {
  load_config
  local target="$1" action="$2" band="${3:-all}"
  case "$action" in
    on) action="up" ;;
    off) action="down" ;;
    *) echo "Использование: meshkitkeen wifi <self|IP|all> on|off [2.4|5|6|all]" >&2; return 1 ;;
  esac

  case "$target" in
    self)
      wifi_control_local "$band" "$action"
      ;;
    all)
      local ip
      for ip in $(get_member_ips); do cmd_wifi "$ip" "$action" "$band"; done
      wifi_control_local "$band" "$action"
      ;;
    *)
      ssh_ready || { echo "Сначала выполните: meshkitkeen setup" >&2; return 1; }
      if ssh_node "$target" "command -v meshkitkeen" >/dev/null 2>&1; then
        echo "  Узел $target: meshkitkeen wifi self $action $band"
        ssh_node "$target" "meshkitkeen wifi self $action $band" 2>&1
        return $?
      fi
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
      ;;
  esac
}

cmd_domain() {
  load_config
  local action="${1:-}" url="${2:-}"
  case "$action" in
    set)
      [ -n "$url" ] || { echo "Использование: meshkitkeen domain set <URL>" >&2; return 1; }
      save_ota_domain "$url" || return 1
      ;;
    reset)
      if [ -f "$CONFIG_FILE" ] && grep -q '^domain=' "$CONFIG_FILE"; then
        grep -v '^domain=' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        echo "Источник сброшен к домену по умолчанию ($OTA_DOMAIN_DEFAULT)."
      else
        echo "Кастомный домен не задан — уже используется домен по умолчанию."
      fi
      ;;
    "")
      echo "Текущий OTA-домен: $(resolve_ota_domain)"
      if [ -f "$CONFIG_FILE" ] && grep -q '^domain=' "$CONFIG_FILE"; then
        echo "  (задан в $CONFIG_FILE)"
      else
        echo "  (домен по умолчанию)"
      fi
      ;;
    *)
      echo "Использование:" >&2
      echo "  meshkitkeen domain               — показать текущий источник" >&2
      echo "  meshkitkeen domain set <URL>     — задать свой источник прошивок" >&2
      echo "  meshkitkeen domain reset         — вернуться к домену по умолчанию" >&2
      return 1
      ;;
  esac
}

cmd_update() {
  load_config
  local target="${1:-self}" domain_override="" args=""
  shift 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain) domain_override="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ "$target" != "self" ]; then
    ssh_ready || { echo "Сначала выполните: meshkitkeen setup" >&2; return 1; }
    print_message "Обновление прошивки узла $target" "$YELLOW"
    if ssh_node "$target" "command -v meshkitkeen" >/dev/null 2>&1; then
      args="--auto"
      [ -n "$domain_override" ] && args="$args --domain $domain_override"
      ssh_node "$target" "meshkitkeen ota-update $args" 2>&1
      return $?
    fi
    echo "MeshkitKeen не найден на узле. Установите его (см. docs/SETUP.md)." >&2
    return 1
  fi

  if [ -n "$domain_override" ]; then
    cmd_ota_update --domain "$domain_override"
  else
    cmd_ota_update
  fi
}

# --- OTA (неинтерактивно): использует оригинальные KeenKit-функции ----------
cmd_ota_update() {
  load_config
  local auto=false domain_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto=true; shift ;;
      --domain) domain_override="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  local domain osvault
  if [ -n "$domain_override" ]; then
    domain=$(printf '%s' "$domain_override" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s|/*$||')
  else
    domain=$(resolve_ota_domain)
  fi
  [ -n "$domain" ] || { echo "Не удалось определить OTA-домен." >&2; return 1; }

  packages_checker "curl findutils libcurl md5sum"
  osvault="$domain/osvault"

  local REQUEST DIRS current_device chosen_dir
  REQUEST=$(ota_request "$osvault") || {
    echo "Не удалось открыть $osvault" >&2
    echo "Смените источник: meshkitkeen domain set <URL>" >&2
    return 1
  }
  DIRS=$(echo "$REQUEST" | grep -o 'href="[^"]*"' | cut -d'"' -f2 | grep -E '^[^/?#]+/$' | grep -vE '^\.\.?/$' | sed 's|/$||' | sed 's|%20| |g')
  [ -n "$DIRS" ] || {
    echo "Не найдены каталоги моделей в $osvault" >&2
    echo "Смените источник: meshkitkeen domain set <URL>" >&2
    return 1
  }

  current_device=$(get_device)
  chosen_dir=""
  local d hwid
  for d in $DIRS; do
    case "$current_device" in
      *"$d"*) chosen_dir="$d"; break ;;
    esac
  done
  if [ -z "$chosen_dir" ]; then
    hwid=$(get_hw_id)
    for d in $DIRS; do
      case "$d" in
        *"$hwid"*) chosen_dir="$d"; break ;;
      esac
    done
  fi
  if [ -z "$chosen_dir" ]; then
    echo "Каталог модели не найден автоматически. Доступные:" >&2
    printf '  %s\n' $DIRS >&2
    return 1
  fi

  local DIR_ENCODED BIN_FILES
  DIR_ENCODED=$(echo "$chosen_dir" | sed 's/ /%20/g')
  REQUEST=$(ota_request "$osvault/$DIR_ENCODED/") || { echo "Ошибка открытия $osvault/$DIR_ENCODED/" >&2; return 1; }
  BIN_FILES=$(echo "$REQUEST" | grep -o 'href="[^"]*"' | cut -d'"' -f2 | grep '\.bin$' | sed 's|%20| |g')
  [ -n "$BIN_FILES" ] || { echo "Нет .bin файлов в $osvault/$DIR_ENCODED/" >&2; return 1; }

  local FILE FILE_ENCODED
  FILE=$(echo "$BIN_FILES" | tail -n 1)
  FILE_ENCODED=$(echo "$FILE" | sed 's/ /%20/g')

  echo "Модель:    $current_device"
  echo "Домен:     $domain"
  echo "Прошивка:  $FILE"
  if [ "$auto" != true ]; then
    printf "Продолжить? (y/n) "
    local CONFIRM
    read -r CONFIRM
    case "$CONFIRM" in
      y|Y) ;;
      *) echo "Отменено."; return 1 ;;
    esac
  fi

  local file_url md5_url total_size total_size_mb free_space_mb DOWNLOAD_PATH
  file_url="$osvault/$DIR_ENCODED/$FILE_ENCODED"
  md5_url="$osvault/$DIR_ENCODED/md5sum"
  total_size=$(ota_request "$file_url" -I | grep -i content-length | tail -n 1 | awk '{print $2}' | tr -d '\r')
  if echo "$total_size" | grep -qE '^[0-9]+$' && [ "$total_size" -gt 0 ]; then
    total_size_mb=$((total_size / 1024 / 1024))
    free_space_mb=$(get_internal_storage_size free)
    if [ -n "$free_space_mb" ] && [ "$free_space_mb" -ge "$total_size_mb" ]; then
      DOWNLOAD_PATH="$STORAGE_DIR"
    else
      DOWNLOAD_PATH="$TMP_DIR"
    fi
  else
    DOWNLOAD_PATH="$TMP_DIR"
  fi
  mkdir -p "$DOWNLOAD_PATH" 2>/dev/null || DOWNLOAD_PATH="$TMP_DIR"

  echo "Скачивание $FILE ..."
  if ! ota_request "$file_url" --output "$DOWNLOAD_PATH/$FILE"; then
    echo "Ошибка скачивания." >&2; return 1
  fi
  if [ ! -s "$DOWNLOAD_PATH/$FILE" ]; then
    echo "Файл пуст или не был загружен." >&2; return 1
  fi
  if ! ota_request "$md5_url" --output "$DOWNLOAD_PATH/md5sum"; then
    rm -f "$DOWNLOAD_PATH/$FILE"; echo "Ошибка скачивания md5sum." >&2; return 1
  fi

  local MD5_REMOTE MD5_LOCAL
  MD5_REMOTE=$(grep "$FILE" "$DOWNLOAD_PATH/md5sum" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
  MD5_LOCAL=$(md5sum "$DOWNLOAD_PATH/$FILE" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
  if [ "$MD5_REMOTE" != "$MD5_LOCAL" ]; then
    echo "MD5 не совпадает: $MD5_REMOTE != $MD5_LOCAL" >&2
    rm -f "$DOWNLOAD_PATH/$FILE" "$DOWNLOAD_PATH/md5sum"
    return 1
  fi
  echo "MD5: ok"

  local update_rc
  update_firmware_block "$DOWNLOAD_PATH/$FILE"
  update_rc=$?
  rm -f "$DOWNLOAD_PATH/$FILE" "$DOWNLOAD_PATH/md5sum"

  if [ "$update_rc" -eq 2 ]; then
    echo "Прошивка обновлена (нативный ndm). Устройство перезагрузится."
    return 0
  fi
  if [ "$update_rc" -ne 0 ]; then
    echo "Обновление завершилось с ошибкой." >&2
    return 1
  fi
  echo "Успешно обновлено. Перезагрузка устройства..."
  sleep 1
  rci_parse '[{"system":{"reboot":true}}]' >/dev/null 2>&1
}

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
  echo "Раздайте ключ на каждый mesh-узел (по SSH :222, root):"
  echo "  mkdir -p /opt/root/.ssh"
  echo "  echo '$pubkey' >> /opt/root/.ssh/authorized_keys"
  echo ""
  echo "Затем проверьте доступ: meshkitkeen status"
}

cmd_add_node() {
  local ip="$1"
  [ -n "$ip" ] || { echo "Использование: meshkitkeen add-node <IP-узла>" >&2; return 1; }
  load_config

  print_message "Подключение узла $ip" "$YELLOW"

  echo "Проверка доступности SSH :222 (Entware)..."
  ssh_node "$ip" "echo ok" >/dev/null 2>&1 && echo "  :222 уже доступен (Entware стоит)." || {
    echo "  На узле нет dropbear :222. Разверните Entware на узле (см. docs/SETUP.md)."
  }

  echo ""
  echo "Дальнейшее развёртывание (SSH-ключ, MeshkitKeen) — командой:"
  echo "  meshkitkeen setup"
  echo "См. docs/SETUP.md для пошаговой инструкции."
}

usage() {
  cat <<EOF
MeshkitKeen v$FORK_VERSION — форк KeenKit $SCRIPT_VERSION с управлением mesh-сетью.

Команды (неинтерактивный режим):
  meshkitkeen status                    Сводка по контроллеру и mesh-узлам
  meshkitkeen reboot <self|IP|all>      Перезагрузка устройства
  meshkitkeen wifi <self|IP|all> on|off [2.4|5|6|all]
                                        Включить/выключить Wi-Fi (6 ГГц — Wi-Fi 6E/7)
  meshkitkeen update <self|IP> [--domain <URL>]
                                        Обновление прошивки (OTA, источник Osvault)
  meshkitkeen ota-update [--auto] [--domain <URL>]
                                        OTA контроллера (неинтерактивно)
  meshkitkeen domain [set <URL>|reset]  Настроить источник обновлений
  meshkitkeen add-node <IP>             Подключить новый mesh-узел
  meshkitkeen setup                      Сгенерировать SSH-ключи для узлов
  meshkitkeen backup-entware            Бэкап Entware
  meshkitkeen backup-block              Бэкап разделов mtd

Без аргументов запускается полное интерактивное меню KeenKit
(обновление прошивки, загрузчик, бэкапы, компоненты и т.д.).

Конфиг:  /opt/etc/MeshkitKeen.conf   (domain, ssh_user, ssh_port)
Ключ:    /opt/etc/MeshkitKeen/id_ed25519   (для SSH на узлы)

ВНИМАНИЕ: операции reboot/wifi/update изменяют состояние сети.
EOF
}

# --- Интерактивное меню MeshkitKeen (дополнение к меню KeenKit) -------------
mesh_menu() {
  while true; do
    printf "${CYAN}MeshkitKeen v%s — управление mesh-сетью${NC}\n\n" "$FORK_VERSION"
    echo "1. Статус сети (все устройства)"
    echo "2. Перезагрузить устройство"
    echo "3. Wi-Fi вкл/выкл"
    echo "4. Обновить прошивку (OTA)"
    echo "5. Подключить новый mesh-узел"
    echo "6. Настроить SSH-ключи (setup)"
    echo "7. Источник обновлений (domain)"
    echo "0. Выход"
    echo ""
    printf "Выберите действие: "
    local choice t a b
    read -r choice || exit 0
    echo ""
    case "$choice" in
      1) cmd_status ;;
      2) printf "IP (self/all/или IP узла): "; read -r t; cmd_reboot "${t:-self}" ;;
      3) printf "IP (self/all/или IP узла): "; read -r t; printf "on/off: "; read -r a; printf "диапазон (2.4/5/6/all): "; read -r b; cmd_wifi "${t:-self}" "$a" "${b:-all}" ;;
      4) printf "IP (self/или IP узла): "; read -r t; cmd_update "${t:-self}" ;;
      5) printf "IP нового узла: "; read -r t; cmd_add_node "$t" ;;
      6) cmd_setup ;;
      7) printf "URL источника (пусто — показать): "; read -r t; [ -n "$t" ] && cmd_domain set "$t" || cmd_domain ;;
      0) exit 0 ;;
      *) echo "Неверный выбор." ;;
    esac
    echo ""
    printf "Нажмите Enter для продолжения..."
    read -r _ || exit 0
  done
}

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
    domain)         cmd_domain "$@" ;;
    add-node)       cmd_add_node "$@" ;;
    setup)          cmd_setup "$@" ;;
    backup-entware) backup_entware ;;
    backup-block)   backup_block ;;
    menu)           mesh_menu ;;
    -h|--help|help) usage ;;
    *)              echo "Неизвестная команда: $cmd" >&2; usage; exit 1 ;;
  esac
}

if [ "$1" = "script_update" ]; then
  script_update
elif [ $# -gt 0 ]; then
  main "$@"
else
  main_menu
fi
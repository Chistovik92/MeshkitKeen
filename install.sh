#!/bin/sh
# ============================================================================
#  MeshkitKeen — установщик
# ============================================================================
#  Скачивает meshkitkeen.sh с GitHub, ставит зависимости, создаёт симлинк и
#  конфиг.  НЕ хранит и НЕ запрашивает пароли.
#
#  Запуск (на головном роутере, root-shell :222):
#    curl -fLsS https://raw.githubusercontent.com/Chistovik92/MeshkitKeen/main/install.sh | sh
# ============================================================================

REPO="MeshkitKeen"
SCRIPT="meshkitkeen.sh"
GITHUB_USER="Chistovik92"
BRANCH="main"
TMP_DIR="/tmp"
OPT_DIR="/opt"
CONFIG_FILE="$OPT_DIR/etc/$REPO.conf"

NC='\033[0m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'

print_message() {
  local message="$1" color="${2:-$NC}"
  local border=$(printf '%0.s-' $(seq 1 $((${#message} + 2))))
  printf "${color}\n+${border}+\n| ${message} |\n+${border}+\n${NC}\n"
}

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
    opkg install $missing || {
      print_message "Не удалось установить зависимости" "$RED"
      return 1
    }
  fi
}

main() {
  print_message "MeshkitKeen — установка" "$GREEN"

  # Зависимости (curl/jq обязательны; dropbearkey входит в dropbear)
  packages_checker curl jq findutils tar libcurl || return 1

  # Скачиваем скрипт
  print_message "Скачивание $SCRIPT ..."
  if ! curl -fLsS "https://raw.githubusercontent.com/$GITHUB_USER/$REPO/$BRANCH/$SCRIPT" \
        --output "$TMP_DIR/$SCRIPT"; then
    print_message "Не удалось скачать скрипт" "$RED"
    return 1
  fi

  mv "$TMP_DIR/$SCRIPT" "$OPT_DIR/$SCRIPT"
  chmod +x "$OPT_DIR/$SCRIPT"
  ln -sf "$OPT_DIR/$SCRIPT" "$OPT_DIR/bin/meshkitkeen"

  # Конфиг (из примера, если ещё нет)
  if [ ! -f "$CONFIG_FILE" ]; then
    print_message "Создание конфига $CONFIG_FILE" "$YELLOW"
    curl -fLsS "https://raw.githubusercontent.com/$GITHUB_USER/$REPO/$BRANCH/conf/meshkitkeen.conf.example" \
      --output "$CONFIG_FILE" 2>/dev/null || \
    cat > "$CONFIG_FILE" <<'EOF'
# MeshkitKeen configuration
# OTA-домен (ваш сервер прошивок, каталог /osvault)
domain="https://your-ota-domain.example.com"
# Доступ к mesh-узлам по SSH
ssh_user="root"
ssh_port="222"
EOF
    echo "  Отредактируйте domain в $CONFIG_FILE"
  fi

  print_message "Готово. Запуск: meshkitkeen" "$GREEN"
  echo "  meshkitkeen status   — сводка по сети"
  echo "  meshkitkeen setup    — настроить SSH-ключи для узлов"
  echo "  meshkitkeen --help   — все команды"
}

main "$@"

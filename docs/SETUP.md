# Установка и настройка MeshkitKeen

## Архитектура

MeshkitKeen запускается на **головном** роутере (контроллере mesh-сети). Список
mesh-узлов он читает локально через RCI (`http://127.0.0.1:79/rci/show/mws/member`),
а операции на узлах выполняет по **SSH** (dropbear `:222`, Entware) **по ключу**.

```
[Контроллер .1]  --RCI (локально)--> список узлов + само состояние
        |
        +--SSH :222 по ключу--> [Узел .51]  Entware + dropbear
        +--SSH :222 по ключу--> [Узел .35]  Entware + dropbear
```

Никакие пароли не передаются и не хранятся в репозитории. Доступ — только по
SSH-ключу, публичная часть которого раздаётся на узлы один раз.

## Предусловия

1. На **контроллере** установлен Entware с root-shell по SSH `:222`
   (пакеты: `dropbear`, `dropbearkey`, `curl`, `jq`).
2. На каждом mesh-узле, которым нужно управлять удалённо, тоже установлен Entware
   с dropbear `:222`.

Если Entware на узлах ещё нет — разверните его (см. «Развёртывание Entware на узле»).

## Шаг 1. Установка на контроллер

```sh
curl -fLsS https://raw.githubusercontent.com/Chistovik92/MeshkitKeen/main/install.sh | sh
```

Установщик:
- ставит зависимости (`curl jq findutils tar libcurl`), если их нет;
- скачивает `meshkitkeen.sh` в `/opt/meshkitkeen.sh`;
- создаёт симлинк `/opt/bin/meshkitkeen`;
- создаёт `/opt/etc/MeshkitKeen.conf` из примера.

## Шаг 2. Конфигурация

Отредактируйте `/opt/etc/MeshkitKeen.conf`:

```
domain="https://your-ota-domain.example.com"   # ваш OTA-сервер, каталог /osvault
ssh_user="root"
ssh_port="222"
```

`domain` нужен только для команды `update`. Каталог `/osvault` должен содержать
подпапки по моделям устройств с файлами `.bin` и `md5sum`:

```
https://<domain>/osvault/<ModelName>/
    ├── <version>.bin
    └── md5sum
```

## Шаг 3. SSH-ключи для узлов

```sh
meshkitkeen setup
```

Скрипт сгенерирует пару `ed25519` в `/opt/etc/MeshkitKeen/id_ed25519` и покажет
публичный ключ. Раздайте его на **каждый** mesh-узел (по SSH `:222`, root) — один раз:

```sh
mkdir -p /opt/root/.ssh
echo 'ssh-ed25519 AAAA... ваш-ключ' >> /opt/root/.ssh/authorized_keys
```

> Примечание: у root в Entware домашний каталог — `/opt/root`, поэтому dropbear
> ищет `authorized_keys` именно в `/opt/root/.ssh/`.

После раздачи проверьте доступ:

```sh
meshkitkeen status
```

Строка `Накопитель:` у узлов появится только когда ключ раздан.

## Шаг 4. Подключение нового mesh-узла

1. Подключите узел к mesh (через веб-интерфейс Keenetic или `add-node`).
2. Убедитесь, что он появился в `meshkitkeen status`.
3. Разверните на нём Entware (см. ниже).
4. Раздайте SSH-ключ (см. Шаг 3).

```sh
meshkitkeen add-node 192.168.1.100
```

### Развёртывание Entware на узле

Если на узле ещё нет Entware, зайдите на него по нативному CLI (`:22`, admin) и выполните:

```
opkg disk storage:/ https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz
```

> Архитектуру инсталлера подберите под устройство (для aarch64 — путь выше; для
> mipsel — `mipsel-installer.tar.gz` и т.д.). Точную архитектуру узла можно узнать
> командой `show version` (поле `arch`).

После этого откроется порт `:222` и узел станет доступен по SSH.

## Безопасность — что НЕ попадает в git

Файл `.gitignore` исключает:
- `conf/meshkitkeen.conf` и `/opt/etc/MeshkitKeen.conf` — реальный конфиг;
- `id_*`, `*.key`, `*.pem`, `authorized_keys` — SSH-ключи;
- `*.log`, `*_probe*.json`, `*.bin`, `*.tar.gz` — временные/отладочные файлы.

Перед коммитом проверяйте, что в репозиторий не попали реальные IP/MAC/лицензии/пароли.

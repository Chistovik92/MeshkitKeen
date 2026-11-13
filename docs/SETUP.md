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

1. На **контроллере** установлен Entware с root-shell по SSH `:222` и пакетами:
   `curl`, `jq`, а также **`openssh-client` + `openssh-keygen`** (см. ниже — клиент
   dropbear не умеет pubkey-аутентификацию).
2. На каждом mesh-узле, которым нужно управлять удалённо, установлен Entware
   с dropbear `:222`, причём dropbear запущен с опцией `-D /opt/root/.ssh`
   (см. «Фикс dropbear на узле»).

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

Установите OpenSSH-клиент (нужен для SSH-доступа к узлам по ключу):

```sh
opkg install openssh-client openssh-keygen
```

> Почему: Entware-клиент `dbclient` (dropbear) **не поддерживает
> pubkey-аутентификацию** — с ключом он выдаёт `No auth methods could be used`
> и падает в пароль. OpenSSH-клиент работает по ключу корректно.

## Шаг 2. Конфигурация

Отредактируйте `/opt/etc/MeshkitKeen.conf`:

```
ssh_user="root"
ssh_port="222"
#domain="https://your-ota-domain.example.com"   # необязательно, см. ниже
```

`domain` нужен только для команды `update`/`ota-update`. Если он не задан,
используется **Osvault по умолчанию** (`https://osvault.project-athens.com`) — тот же
источник, что и в KeenKit.

Свой источник прошивок удобнее задать командами (без правки файла вручную):

```sh
meshkitkeen domain set https://your-ota-domain.example.com
meshkitkeen domain        # показать текущий источник
meshkitkeen domain reset  # вернуться к Osvault по умолчанию
```

Каталог `/osvault` на сервере должен содержать подпапки по моделям устройств
с файлами `.bin` и `md5sum`:

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
mkdir -p /opt/root/.ssh && chmod 700 /opt/root/.ssh
echo 'ssh-ed25519 AAAA... ваш-ключ' > /opt/root/.ssh/authorized_keys && chmod 600 /opt/root/.ssh/authorized_keys
```

> Примечание: у root в Entware домашний каталог — `/opt/root`, поэтому ключ кладём
> именно в `/opt/root/.ssh/`.

### Фикс dropbear на узле (обязательно)

По умолчанию dropbear-сервер на узле ищет `authorized_keys` по `HOME=/`, а `/` —
read-only. Поэтому **на каждом узле** добавьте опцию `-D /opt/root/.ssh` в init-скрипт
`/opt/etc/init.d/S51dropbear` (строка запуска):

```
if ! "$DROPBEAR" -p "$PORT" -P "$PIDFILE" -D /opt/root/.ssh; then
```

и перезапустите:

```sh
/opt/etc/init.d/S51dropbear restart
```

Без этой опции ключ не будет принят, и SSH упадёт в пароль.

После раздачи проверьте доступ:

```sh
meshkitkeen status
```

Строка `Накопитель:` у узлов появится только когда ключ раздан и dropbear
настроен с `-D`.

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

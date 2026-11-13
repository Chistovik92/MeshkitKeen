# Справочник команд MeshkitKeen

Все команды выполняются на **головном** роутере (контроллере).

## Общий синтаксис

```
meshkitkeen <команда> [аргументы]
```

Без аргументов запускается интерактивное меню.

## `status`

Сводка по контроллеру и всем mesh-узлам.

```sh
meshkitkeen status
```

Выводит для каждого устройства:
- модель и hw_id;
- версию прошивки;
- нагрузку CPU (%);
- занятую ОЗУ (used / total);
- накопитель OPKG (тип и used / total) — у узлов только при разданном SSH-ключе;
- uptime;
- у узлов — backhaul (Мбит/с), режим (extender), MAC.

Информация об узлах читается через `show/mws/member` (без SSH), кроме накопителя,
который запрашивается по SSH.

## `reboot`

Перезагрузка устройства.

```sh
meshkitkeen reboot self        # контроллер
meshkitkeen reboot 192.168.1.100  # конкретный узел по IP
meshkitkeen reboot all         # все узлы + контроллер
```

Узлы перезагружаются через SSH (`ndmc -c 'system reboot'`).

## `wifi`

Включение/выключение Wi-Fi.

```sh
meshkitkeen wifi self on 5     # включить 5 ГГц на контроллере
meshkitkeen wifi 192.168.1.100 off 2.4
meshkitkeen wifi all off 6     # выключить 6 ГГц (Wi-Fi 6E/7) на всех
meshkitkeen wifi all on        # включить все диапазоны на всех
```

- Диапазоны: `2.4`, `5`, `6` (6 ГГц — только на Wi-Fi 6E/7), `all`.
- Диапазоны определяются динамически из `show/interface`; на устройстве без 6 ГГц
  диапазон `6` отсутствует и просто не трогается.
- Для узлов с установленным MeshkitKeen операция делегируется ему; иначе используется
  fallback через `ndmc -c 'interface <WifiMasterN/AccessPoint0> <up|down>'`.

## `update`

Обновление прошивки по OTA.

```sh
meshkitkeen update self        # контроллер (интерактивно подтверждает)
meshkitkeen update 192.168.1.100  # узел (требует meshkitkeen на узле)
```

См. также `ota-update`.

## `ota-update`

Неинтерактивное OTA-обновление контроллера.

```sh
meshkitkeen ota-update          # покажет версию и спросит подтверждение
meshkitkeen ota-update --auto   # без подтверждения (для удалённого вызова)
```

Логика: открывает `<domain>/osvault`, находит каталог модели, берёт последний `.bin`,
проверяет MD5 по `md5sum`, обновляет прошивку через нативный ndm
(`copy temp:/<file> flash:/firmware`).

## `add-node`

Подготовка нового mesh-узла.

```sh
meshkitkeen add-node 192.168.1.100
```

Проверяет наличие Entware (`:222`) на узле и подсказывает дальнейшие шаги
(развёртывание Entware, раздача ключа). См. [SETUP.md](SETUP.md).

## `setup`

Генерация и раздача SSH-ключей.

```sh
meshkitkeen setup
```

Генерирует `id_ed25519` в `/opt/etc/MeshkitKeen/` и печатает публичный ключ для
добавления в `/opt/root/.ssh/authorized_keys` на узлах.

## `backup-entware`

Резервная копия Entware (`/opt`) в `/storage/entware_backup_<дата>.tar.gz`.

```sh
meshkitkeen backup-entware
```

## `backup-block`

Резервная копия разделов прошивки (`/proc/mtd`) в `/storage/mtd_backup_<дата>/`.

```sh
meshkitkeen backup-block
```

## `--help`

```sh
meshkitkeen --help
```

## Таблица соответствия диапазонов

| Диапазон | Интерфейс              | Стандарт        |
|----------|------------------------|-----------------|
| 2.4 ГГц  | `WifiMaster0/AccessPoint0` | Wi-Fi 4/6    |
| 5 ГГц    | `WifiMaster1/AccessPoint0` | Wi-Fi 5/6    |
| 6 ГГц    | `WifiMaster2/AccessPoint0` | Wi-Fi 6E/7   |

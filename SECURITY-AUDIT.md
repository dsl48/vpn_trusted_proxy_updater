# Расширенная проверка базовой безопасности

Расширение `check-basic-security-extended.sh` запускается основным `install.sh` поверх базового read-only аудита. Оно не меняет firewall, ipset, systemd, Docker, CrowdSec, Fail2Ban или TrafficGuard.

## Сетевые listeners

Публичность определяется только по колонке `Local Address:Port` вывода `ss -H -lntup`.

Публичными считаются bind-адреса:

```text
0.0.0.0
[::]
*
```

Loopback-адреса `127.0.0.0/8` и `::1` не включаются в число публичных listeners. Значение `0.0.0.0:*` в колонке удалённого адреса слушающего сокета не считается публичным bind.

CrowdSec LAPI получает:

```text
[OK]       при bind на 127.0.0.0/8 или ::1
[CRITICAL] при bind на любом не-loopback адресе
```

## Fail2Ban

Проверяются:

- наличие пакета или `fail2ban-client`;
- активность `fail2ban.service`;
- ответ `fail2ban-client ping`;
- список активных jails;
- включение в автозагрузку.

Отсутствие Fail2Ban выводится как `INFO`, когда CrowdSec и firewall bouncer активны. Одновременная работа Fail2Ban и CrowdSec не считается конфликтом.

## TrafficGuard

Проверяется реализация `dotX12/traffic-guard`.

Аудит подтверждает:

- наличие и запуск `/usr/local/bin/traffic-guard` или бинарника из `PATH`;
- существование и количество элементов в `SCANNERS-BLOCK-V4` и `SCANNERS-BLOCK-V6`;
- наличие правила `DROP` с соответствующим ipset;
- подключение цепочки `SCANNERS-BLOCK` к `INPUT` либо UFW before-input;
- наличие `/etc/ipset.conf`;
- включение `antiscan-ipset-restore.service`;
- состояние опционального `antiscan-aggregate.timer`.

Также выполняется read-only сравнение локальных ipset с текущими публичными списками:

```text
public/antiscanner.list
public/government_networks.list
```

Результат сравнения:

```text
[OK]       покрытие 100%
[WARN]     покрытие от 90% до 99%
[CRITICAL] покрытие ниже 90%
[SKIP]     списки невозможно получить или отсутствует Python 3/curl
```

Сравнение нормализует IP и CIDR через Python `ipaddress`. Временные файлы удаляются после проверки.

## Docker и RemnaNode

Для контейнера с точным именем `remnawave-node-agent` следующие параметры считаются штатными и выводятся как `INFO`:

- `privileged=true`;
- процесс от root/default user;
- writable root filesystem.

Исключение не распространяется на другие контейнеры. Для `remnawave-node-agent` продолжают считаться проблемой:

- Docker socket внутри контейнера;
- mount корня хоста `/`;
- `network_mode=host`;
- отсутствие restart policy;
- отключённые Docker logs;
- отсутствие ограничений ротации логов.

## Запуск

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh | sudo sh
```

В главном меню выбрать:

```text
1 — Проверка базовой безопасности
```

# Расширенная проверка базовой безопасности

Расширение `check-basic-security-extended.sh` запускается основным `install.sh` поверх базового read-only аудита. Оно не меняет firewall, ipset, systemd, Docker, CrowdSec, Fail2Ban или TrafficGuard.

После общего аудита запускается отдельная read-only проверка `check-crowdsec-caddy-acquisitions.sh`. Она анализирует все профили с выделенным Caddy file/docker acquisition: Remnawave Panel, CDN Origin и VLESS selfsteal.

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

## CrowdSec acquisitions для Caddy

Для профилей с выделенным access log ожидается следующая схема:

```text
выделенный file/docker access log -> type: caddy -> CrowdSec
journalctl caddy.service          -> не подключён
/var/log/syslog                   -> не подключён общим acquisition
/var/log/messages                 -> не подключён общим acquisition
```

Для CDN Origin выделенный datasource должен быть ровно один:

```text
/var/log/caddy/access.log -> type: caddy
```

Причина: `log_skip` отключает только access log выбранного Caddy route. Operational log `http.handlers.reverse_proxy` продолжает поступать в journald и может содержать URI XHTTP-сессии. На системах с rsyslog те же сообщения дополнительно копируются в `/var/log/syslog`.

Проверка выводит:

- список выделенных Caddy acquisitions;
- `[CRITICAL]`, если CrowdSec читает `journalctl` с `_SYSTEMD_UNIT=caddy.service`;
- `[WARN]`, если подключён общий `/var/log/syslog` или `/var/log/messages`;
- для CDN Origin — количество acquisition-файлов, читающих `/var/log/caddy/access.log`;
- состояние `crowdsec-cdn-allowlist-sync.path`;
- наличие `/usr/local/sbin/sync-crowdsec-cdn-allowlist`;
- признаки профилей Remnawave Panel и VLESS selfsteal;
- фактические runtime-источники из `cscli metrics show acquisition`.

VPN/XHTTP routes на CDN Origin должны содержать `log_skip`, поэтому их запросы не должны попадать в `/var/log/caddy/access.log`.

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

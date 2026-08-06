# Проверка и базовая защита VPN-серверов

Интерактивное меню для read-only аудита и установки защитных компонентов на серверах проекта VPN. Основная целевая платформа — Debian/Ubuntu.

## Запуск

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh | sudo sh
```

Требуются root-права, `curl` и интерактивный `/dev/tty`.

## Главное меню

```text
════════════════════════════════════════════════════════════
              ПРОВЕРКА И ЗАЩИТА СЕРВЕРА
════════════════════════════════════════════════════════════

1 — Проверка базовой безопасности
2 — Установка базовых настроек безопасности
3 — Установка TrafficGuard
4 — Установка CrowdSec
0 — Выход
```

После завершения выбранного сценария управление возвращается в главное меню.

## 1. Проверка базовой безопасности

Проверка выполняется файлами:

```text
check-basic-security.sh
check-basic-security-extended.sh
```

Она работает только в режиме чтения и проверяет:

- ОС, обновления и состояние `dpkg`;
- пользователей и эффективную конфигурацию SSH;
- публичные listeners;
- firewall, ping и базовые `sysctl`;
- CrowdSec и firewall bouncer;
- Fail2Ban;
- TrafficGuard и фактическое заполнение ipset;
- Docker и профильное исключение для `remnawave-node-agent`;
- диск, время, журналы и права на секреты.

Подробные критерии приведены в [`SECURITY-AUDIT.md`](SECURITY-AUDIT.md).

## 2. Установка базовых настроек безопасности

Мастер использует только существующую учётную запись. Перед каждым предложением проверяется текущее состояние; уже применённые или более строгие параметры выводятся как `[OK]`.

Потенциально опасные изменения SSH, `sysctl` и nftables выполняются транзакционно:

1. создаётся backup в `/var/lib/server-security/transactions/`;
2. запускается systemd timer автоматического восстановления;
3. изменение применяется и технически проверяется;
4. пользователь проверяет новую SSH-сессию, VPN и сервисы;
5. таймер удаляется только после явного подтверждения.

Сроки отката:

```text
SSH       5 минут
sysctl    5 минут
nftables  3 минуты
```

Мастер поддерживает:

- интерактивную установку SSH-ключа;
- `PubkeyAuthentication`, `PermitRootLogin prohibit-password` и отключение парольного входа после проверки ключа;
- ограничения `MaxAuthTries`, `LoginGraceTime`, `MaxStartups`;
- автоматические security updates;
- безопасные kernel/network `sysctl`;
- loose `rp_filter` для VPN-сценариев;
- ограничение ping в собственной таблице `inet server_security`;
- Fail2Ban, когда CrowdSec с bouncer отсутствует;
- NTP, logrotate, лимиты journald и проверку прав секретов.

## 3. Установка TrafficGuard

Используется проект `dotX12/traffic-guard` и два списка:

```text
public/antiscanner.list
public/government_networks.list
```

Установщик:

- проверяет IP текущей SSH-сессии;
- применяет списки через `traffic-guard full`;
- поддерживает UFW;
- по выбору включает агрегированное журналирование;
- проверяет IPv4/IPv6 ipset, DROP-правила и подключение цепочки `SCANNERS-BLOCK`.

Upstream installer закреплён на конкретном commit ref. Переопределение:

```bash
TRAFFIC_GUARD_INSTALLER_REF=<commit-or-branch>
```

## 4. Установка CrowdSec

Меню профилей:

```text
Куда устанавливаются базовые средства защиты?
  1 — Панель Remnawave + Caddy
  2 — Нода CDN Origin
  3 — Нода VLESS + selfsteal на Caddy
```

Оркестрация выполняется через `install-crowdsec-bootstrap.sh`. Local API переносится на loopback:

```text
127.0.0.1:18888
```

### Панель Remnawave + Caddy

Профиль реализован в `install-crowdsec-remnawave-panel.sh`. Он поддерживает:

```text
Caddy на хосте: /etc/caddy/Caddyfile
Caddy в Docker: /opt/remnawave/caddy/Caddyfile
```

Nginx и Traefik не поддерживаются этим профилем.

Сценарий:

- находит запущенный контейнер `remnawave/backend`;
- проверяет, не опубликованы ли сервисы Remnawave наружу вместо loopback;
- получает домен из `/opt/remnawave/.env` или запрашивает его;
- однозначно находит Caddy site block панели;
- добавляет отдельный JSON access log;
- для официального Docker Caddy при необходимости создаёт `docker-compose.override.yml` с bind mount `/var/log/caddy`;
- создаёт backup Caddyfile и systemd timer отката на 5 минут;
- выполняет `caddy validate`, reload и HTTPS-проверку панели;
- устанавливает CrowdSec Security Engine и коллекции Linux/Caddy;
- создаёт file acquisition для Caddy;
- предлагает добавить IP текущей SSH-сессии и дополнительные IP/CIDR в `remnawave-panel-trusted`;
- устанавливает firewall bouncer с именем `remnawave-panel-firewall-bouncer`;
- проверяет свежий API pull remediation component.

Профиль спрашивает, как панель получает трафик:

```text
Прямое подключение:
  firewall bouncer применяет SSH- и HTTP-решения

Cloudflare/CDN/reverse proxy:
  firewall bouncer применяет только SSH-решения
  HTTP-журналы продолжают анализироваться CrowdSec
```

За CDN сетевой firewall видит адрес прокси, поэтому HTTP-решения намеренно не применяются к firewall без отдельного application-level remediation component.

Управляемые файлы:

```text
/var/log/caddy/remnawave-panel-access.log
/etc/crowdsec/acquis.d/remnawave-panel-caddy.yaml
/etc/crowdsec/remnawave-panel-profile.env
```

Для доставки большого профиля bootstrap собирает проверяемый payload из файлов каталога:

```text
crowdsec-remnawave-panel/
```

Перед выполнением собранный payload обязательно проходит `bash -n`.

### CDN Origin

Сценарий:

- настраивает доверенные диапазоны Яндекс CDN и/или Билайн CDN;
- создаёт CrowdSec AllowList для CDN и администратора;
- устанавливает firewall bouncer;
- применяет через firewall только SSH-решения;
- опционально подключает CrowdSec Console;
- проверяет remediation component.

### VLESS + selfsteal

Сценарий:

- поддерживает Caddy на хосте и в Docker;
- определяет стандартный HTTPS selfsteal block;
- добавляет управляемый JSON access log;
- создаёт file или Docker acquisition;
- устанавливает firewall bouncer для SSH- и HTTP-решений;
- проверяет регистрацию и свежий Local API pull.

## Закрепление версии проекта

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh \
  | sudo VPN_INSTALL_REF=<tag-or-commit> sh
```

## Секреты

Не публикуйте содержимое:

- `/etc/cdn-trusted-proxies.conf`;
- `/etc/crowdsec/local_api_credentials.yaml`;
- `/etc/crowdsec/online_api_credentials.yaml`;
- `/etc/crowdsec/bouncers/*.yaml.local`;
- `/etc/crowdsec/remnawave-panel-profile.env`;
- `.env` файлов;
- enrollment key CrowdSec Console.

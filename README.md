# Проверка и базовая защита VPN-серверов

Интерактивное меню для read-only аудита безопасности и установки отдельных защитных компонентов на серверах проекта VPN.

## Запуск

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh | sudo sh
```

Требуются root-права, `curl` и интерактивный `/dev/tty`. Основной целевой набор ОС — Debian/Ubuntu.

## Главное меню

```text
════════════════════════════════════════════════════════════
              ПРОВЕРКА И ЗАЩИТА СЕРВЕРА
════════════════════════════════════════════════════════════

1 — Проверка базовой безопасности
    Read-only аудит ОС, SSH, сети, firewall, Docker и средств защиты.

2 — Установка базовых настроек безопасности
    Интерактивное усиление SSH, sysctl, ping, обновлений и журналов
    с backup и автоматическим откатом опасных изменений.

3 — Установка TrafficGuard
    Отсекает известные сети сканеров на уровне iptables/ipset,
    до передачи соединения SSH, Caddy, Xray и другим сервисам.

4 — Установка CrowdSec
    Анализирует журналы, выявляет атаки и динамически блокирует
    источники через firewall bouncer.

0 — Выход
```

После проверки или любого установочного сценария мастер предлагает нажать Enter и возвращает пользователя в главное меню. Пустой Enter в главном меню запускает проверку безопасности.

## 1. Проверка базовой безопасности

Проверка выполняется файлами:

```text
check-basic-security.sh
check-basic-security-extended.sh
```

Она работает только в режиме чтения и не изменяет firewall, SSH, sysctl, пакеты, Docker, CrowdSec, Fail2Ban или TrafficGuard.

Проверяются:

- ОС, обновления и `dpkg`;
- пользователи и эффективная конфигурация SSH;
- публичные listeners по колонке `Local Address:Port`;
- firewall, ping и базовые sysctl;
- CrowdSec и firewall bouncer;
- Fail2Ban;
- TrafficGuard, ipset и фактическое покрытие списков;
- Docker и профильное исключение для `remnawave-node-agent`;
- диск, время, журналы и права на секреты.

Подробные критерии описаны в [`SECURITY-AUDIT.md`](SECURITY-AUDIT.md).

## 2. Установка базовых настроек безопасности

Мастер находится в `install-baseline-security.sh`. Создание нового администратора исключено: используется только выбранная существующая учётная запись.

Перед каждым предложением проверяется текущее эффективное состояние. Уже применённая или более строгая настройка выводится как `[OK]` и не запрашивается повторно. Каждое изменение подтверждается отдельным вопросом `Y/n` либо `y/N`.

### Транзакции и автоматический откат

Потенциально опасные изменения SSH, сетевых `sysctl` и nftables выполняются транзакционно:

1. создаётся backup в `/var/lib/server-security/transactions/`;
2. создаются отдельные systemd service и timer автоматического восстановления;
3. изменение применяется и технически проверяется;
4. пользователь проверяет новую SSH-сессию, VPN и публичные сервисы;
5. только после явного подтверждения таймер удаляется.

Сроки автоматического отката:

```text
SSH       5 минут
sysctl    5 минут
nftables  3 минуты
```

При ошибке `sshd -t`, неактивном SSH service, неприменившемся sysctl или ошибке nftables восстановление выполняется немедленно. Если пользователь не подтверждает работоспособность, таймер остаётся активным, а мастер прекращает дальнейшие изменения.

### SSH-ключ

Мастер предлагает выбрать существующего пользователя и проверяет `authorized_keys` через `ssh-keygen`.

Когда рабочего ключа нет, показывается инструкция для macOS, Linux и Windows PowerShell:

```bash
ssh-keygen -t ed25519 -a 100 \
  -f ~/.ssh/vpn-admin-ed25519 \
  -C "vpn-admin"
```

Доступны два способа установки публичного ключа:

- вставка одной строки `.pub` в мастер;
- выполнение `ssh-copy-id` из другого терминала.

Приватный ключ блокируется по сигнатуре `BEGIN ... PRIVATE KEY`. Публичный ключ проверяется командой `ssh-keygen -lf`, после чего выставляются права `0700` для `.ssh` и `0600` для `authorized_keys`.

`PasswordAuthentication` и `KbdInteractiveAuthentication` не предлагается отключать, пока пользователь явно не подтвердит успешный вход по ключу в новой SSH-сессии.

### SSH hardening

Отдельно проверяются и при необходимости предлагаются:

```text
PubkeyAuthentication yes
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:60
X11Forwarding no
AllowAgentForwarding no
```

Полный запрет root-login и отключение `AllowTcpForwarding` автоматически не выполняются.

Управляемый drop-in:

```text
/etc/ssh/sshd_config.d/00-server-security.conf
```

После записи обязательны `sshd -t`, reload активного `ssh.service`/`sshd.service` и проверка эффективных значений через `sshd -T`.

### Автоматические обновления

Отдельно предлагаются:

- установка `unattended-upgrades`;
- включение автоматических security updates;
- удаление неиспользуемых зависимостей;
- автоматическая перезагрузка, по умолчанию отключённая.

Управляемый файл:

```text
/etc/apt/apt.conf.d/90-server-security
```

### Kernel и сетевые sysctl

Проверяются и предлагаются отдельными вопросами:

- SYN cookies;
- игнорирование broadcast echo;
- запрет IPv4/IPv6 redirects;
- запрет source routing;
- reverse path filtering;
- `kernel.kptr_restrict`;
- `kernel.dmesg_restrict`;
- `kernel.yama.ptrace_scope`.

Для VPN применяется только loose reverse path filtering `2`; уже активные значения `1` или `2` считаются настроенными и не изменяются.

Управляемый файл:

```text
/etc/sysctl.d/90-server-security.conf
```

Перед применением сохраняются исходный файл и runtime-значения каждого изменяемого параметра.

### Ограничение ping

При наличии nftables мастер отдельно предлагает ограничить IPv4 и IPv6 echo-request до двух запросов в секунду с burst 5. Служебный ICMPv6 не блокируется.

Используется только собственная таблица:

```text
table inet server_security
```

Мастер не выполняет `nft flush ruleset` и не изменяет таблицы Docker, CrowdSec, TrafficGuard или UFW. Для автозагрузки создаётся отдельный `server-security-nft.service`.

### Fail2Ban

Если CrowdSec и firewall bouncer уже активны, Fail2Ban не предлагается. В остальных случаях мастер может отдельно:

- установить или запустить Fail2Ban;
- включить jail `sshd`;
- добавить IP текущего SSH-подключения в `ignoreip`.

### Время, журналы и права

Отдельно проверяются и предлагаются:

- включение системной NTP-синхронизации;
- установка `logrotate`;
- лимиты journald `SystemMaxUse=512M` и `RuntimeMaxUse=256M`;
- удаление прав `other` у обнаруженных CrowdSec credentials и `.env`-файлов.

Массовые `chmod -R` и `chown -R` не используются.

## 3. Установка TrafficGuard

Используется проект `dotX12/traffic-guard`. Обёртка находится в:

```text
install-traffic-guard.sh
```

Установщик:

- кратко объясняет назначение компонента;
- запрашивает подтверждение;
- загружает два списка:
  - `public/antiscanner.list`;
  - `public/government_networks.list`;
- проверяет, не входит ли IP текущего SSH-подключения в один из списков;
- при отсутствии TrafficGuard запускает официальный upstream installer;
- применяет списки через `traffic-guard full`;
- по выбору включает агрегированное журналирование;
- проверяет ipset `SCANNERS-BLOCK-V4` и `SCANNERS-BLOCK-V6`;
- проверяет DROP-правило и подключение цепочки `SCANNERS-BLOCK` к входящему трафику.

Upstream installer закреплён на конкретном commit ref. Его можно переопределить переменной:

```bash
TRAFFIC_GUARD_INSTALLER_REF=<commit-or-branch>
```

При повторном запуске существующий бинарник не переустанавливается, но списки скачиваются и применяются заново.

## 4. Установка CrowdSec

Пункт открывает существующее меню ролей:

```text
Куда устанавливаются базовые средства защиты?
  1 — Панель управления (пока не реализовано)
  2 — Нода CDN Origin
  3 — Нода VLESS + selfsteal на Caddy
```

Оркестрация вынесена в `install-crowdsec-bootstrap.sh`. Она использует проверенный bootstrap из commit `9effc4730be57ac198197536e449d8519670fb08`, но все профильные компоненты загружает из `VPN_INSTALL_REF`, по умолчанию из текущего `main`.

### CDN Origin

Сценарий:

- настраивает доверенные диапазоны Яндекс CDN и/или Билайн CDN;
- создаёт CrowdSec AllowList для CDN и администратора;
- переносит Local API на `127.0.0.1:18888`;
- устанавливает firewall bouncer;
- применяет через firewall только SSH-решения;
- подключает CrowdSec Console и проверяет remediation component.

### VLESS + selfsteal

Сценарий:

- поддерживает Caddy на хосте и в Docker;
- автоматически определяет стандартный HTTPS selfsteal block;
- добавляет управляемый JSON access log;
- создаёт file или Docker acquisition;
- устанавливает CrowdSec и firewall bouncer для решений `ssh` и `http`;
- при недоступном Caddy Admin API перезапускает контейнер и ждёт его восстановления.

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
- `.env` файлов;
- enrollment key CrowdSec Console.

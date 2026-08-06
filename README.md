# Проверка и базовая защита VPN-серверов

Интерактивный набор скриптов для аудита базовой безопасности и установки CrowdSec-защиты на серверах проекта VPN.

## Запуск

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh | sudo sh
```

Нужен интерактивный `/dev/tty`. Основной установщик работает на Debian/Ubuntu и должен запускаться от root.

## Главное меню

```text
Проверка и защита сервера
  1 — Проверка базовой безопасности
  2 — Установить базовые средства защиты
  0 — Выход
```

Пустой Enter выбирает проверку безопасности.

# Проверка базовой безопасности

Проверка выполняется скриптом `check-basic-security.sh` и работает только в режиме чтения. Она не меняет firewall, SSH, sysctl, пакеты, пользователей, контейнеры и сервисы.

Результаты выводятся со статусами:

```text
[OK]       настройка соответствует базовой рекомендации
[WARN]     настройку желательно проверить или усилить
[CRITICAL] обнаружена серьёзная проблема
[INFO]     справочная информация
[SKIP]     проверка неприменима или недоступна
```

В конце выводятся счётчики и общая рекомендация. Скрипт возвращает код `0`, даже если найдены проблемы: результаты аудита не считаются ошибкой выполнения bootstrap.

## Что проверяется

### ОС и обновления

- дистрибутив, версия и ядро;
- незавершённые операции `dpkg --audit`;
- ожидающие обновления по текущему APT-кэшу;
- наличие и состояние `unattended-upgrades`;
- необходимость перезагрузки.

Проверка обновлений не выполняет `apt update` и не изменяет APT-кэш.

### Пользователи и SSH

- пользователи с UID 0;
- учётные записи с интерактивной оболочкой;
- пустые пароли;
- члены групп `sudo` и `wheel`;
- активность SSH service;
- эффективная конфигурация через `sshd -T`;
- `PermitRootLogin`;
- `PasswordAuthentication`;
- `KbdInteractiveAuthentication`;
- `PubkeyAuthentication`;
- `PermitEmptyPasswords`;
- `MaxAuthTries` и `LoginGraceTime`;
- X11, agent forwarding и TCP forwarding;
- права на `.ssh` и `authorized_keys`.

### Сетевая поверхность

- все TCP/UDP listeners через `ss -lntup`;
- сервисы на `0.0.0.0`, `[::]` и `*`;
- публичные базы данных и административные порты;
- привязка CrowdSec LAPI `18888` к loopback.

Публичные порты выводятся без автоматического закрытия. Скрипт не может определить правила внешнего cloud firewall.

### Firewall, сканирование и ping

- наличие nftables, UFW или iptables;
- входящая политика `DROP/DENY`;
- разрешение `established/related`;
- отбрасывание `ct state invalid`;
- блокировка или rate limit IPv4 echo-request;
- блокировка или rate limit IPv6 echo-request;
- состояние CrowdSec firewall bouncer.

Полное отсутствие ответа на ping не считается обязательным. Проверка принимает как безопасный вариант полную блокировку echo-request, так и ограничение его частоты. Служебный ICMPv6 отдельно не блокируется этим проектом.

### Kernel/sysctl

Проверяются:

```text
net.ipv4.tcp_syncookies
net.ipv4.icmp_echo_ignore_broadcasts
net.ipv4.conf.*.accept_redirects
net.ipv4.conf.*.send_redirects
net.ipv4.conf.*.accept_source_route
net.ipv4.conf.*.rp_filter
net.ipv6.conf.*.accept_redirects
net.ipv6.conf.*.accept_source_route
kernel.kptr_restrict
kernel.dmesg_restrict
kernel.yama.ptrace_scope
```

Для VPN, policy routing и асимметричных маршрутов `rp_filter=2` считается допустимым loose mode.

### CrowdSec

- наличие `cscli`;
- активность Security Engine;
- результат `crowdsec -t`;
- доступность Central API;
- наличие валидного firewall bouncer;
- наличие SSH/system acquisition;
- наличие Caddy/Docker acquisition после поступления логов.

Caddy datasource может отсутствовать в метриках до первого запроса, дошедшего до Caddy.

### Docker

- доступность Docker daemon;
- пользователи группы `docker`;
- `privileged=true`;
- `network_mode=host`;
- запуск процесса от root/default user;
- отсутствие restart policy;
- отсутствие ограничений ротации логов на уровне контейнера;
- mount корневой файловой системы хоста;
- mount `/var/run/docker.sock`;
- публичные Docker port bindings.

Некоторые предупреждения могут быть допустимы для конкретной инфраструктуры. Например, root user или writable rootfs иногда необходимы сетевым сервисам, но требуют ручной оценки.

### Диск, время и журналы

- заполнение корневого раздела;
- заполнение inode;
- NTP-синхронизация;
- logrotate;
- failed systemd units;
- OOM-события за последние 24 часа;
- неудачные SSH-входы за последние 24 часа.

### Права на секреты

Проверяются известные файлы:

- CrowdSec API credentials;
- firewall bouncer `.yaml.local`;
- `/root/.ssh/authorized_keys`;
- `.env` и `*.env` в `/opt` на глубине до пяти каталогов.

Содержимое секретов не выводится.

# Установка базовых средств защиты

После выбора пункта `2` открывается существующее меню ролей:

```text
Куда устанавливаются базовые средства защиты?
  1 — Панель управления (пока не реализовано)
  2 — Нода CDN Origin
  3 — Нода VLESS + selfsteal на Caddy
```

Пустой Enter выбирает профиль CDN Origin.

## CDN Origin

Сценарий:

- выбирает Яндекс CDN, Билайн CDN или обоих провайдеров;
- получает и регулярно обновляет доверенные CDN-диапазоны;
- настраивает `trusted_proxies` для Caddy;
- создаёт CrowdSec AllowList для CDN и администратора;
- переносит CrowdSec Local API на `127.0.0.1:18888`;
- устанавливает firewall bouncer;
- применяет через firewall только SSH-решения, чтобы не блокировать CDN edge;
- подключает Security Engine к CrowdSec Console;
- проверяет remediation component и свежий API pull.

## VLESS + selfsteal на Caddy

После выбора профиля мастер уточняет:

```text
Где запущен Caddy?
  1 — На хосте через systemd
  2 — В Docker
```

### Caddy на хосте

Используются:

```text
/etc/caddy/Caddyfile
/var/log/caddy/selfsteal-access.log
```

Caddyfile проверяется через `caddy validate`, затем применяется через `systemctl reload caddy`.

### Caddy в Docker

По умолчанию используется:

```text
/opt/remnanode/selfsteal/Caddyfile
```

Скрипт:

- находит контейнер по bind mount Caddyfile;
- определяет путь файла внутри контейнера;
- проверяет конфигурацию внутри контейнера;
- сохраняет inode файла при изменении отдельного bind mount;
- сначала запускает `caddy reload`;
- при недоступном Admin API выполняет `docker restart`;
- ждёт восстановления контейнера до 30 секунд;
- при ошибке показывает последние 100 строк Docker logs;
- направляет Caddy JSON access log в stdout;
- создаёт CrowdSec Docker datasource с меткой `type: caddy`.

### Автоматическое определение selfsteal-блока

Стандартный шаблон RemnaNode определяется по сочетанию:

```caddyfile
https://{$SELF_STEAL_DOMAIN} {
    bind unix/{$CADDY_SOCKET_PATH}|0666
    root * /var/www/html
    try_files {path} /index.html
    file_server
}
```

Обрабатывается только HTTPS-блок с `bind unix/...` и `file_server`. HTTP redirect и технический `:80` не изменяются. Для нестандартного Caddyfile мастер запрашивает заголовок site block вручную.

### Firewall bouncer VLESS-профиля

Для прямой VLESS/selfsteal-ноды применяются решения:

```text
ssh
http
```

Bouncer поддерживает nftables или iptables, IPv4 и IPv6. Для nftables используется hook `input`.

# CrowdSec Local API и безопасное обновление bouncer

Оба профиля используют:

```text
http://127.0.0.1:18888/
```

Перед обновлением firewall bouncer создаются новый API key и рабочий `.yaml.local`. Если пакетный post-install оставляет `dpkg` в незавершённом состоянии, установщик выполняет:

```bash
dpkg --configure -a
apt-get -f install -y
```

и проверяет итоговый `dpkg --audit`.

# Ручные проверки

```bash
systemctl status crowdsec --no-pager -l
systemctl status crowdsec-firewall-bouncer --no-pager -l
cscli metrics show acquisition
cscli metrics show bouncers
cscli bouncers list
cscli capi status
cscli console status
dpkg --audit
```

Для Docker Caddy:

```bash
docker ps
docker logs --tail 100 <caddy-container>
docker inspect <caddy-container>
```

Для nftables:

```bash
nft list ruleset
nft list table ip crowdsec
nft list table ip6 crowdsec6
```

# Закрепление версии

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh \
  | sudo VPN_INSTALL_REF=v1.0.0 sh
```

# Секреты

Не публикуйте содержимое:

- `/etc/cdn-trusted-proxies.conf`;
- `/etc/crowdsec/local_api_credentials.yaml`;
- `/etc/crowdsec/online_api_credentials.yaml`;
- `/etc/crowdsec/bouncers/*.yaml.local`;
- `.env` файлов;
- enrollment key CrowdSec Console.

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
    Усиление ОС, SSH, sysctl, firewall и автоматических обновлений.

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

Пункт зарезервирован для отдельного безопасного профиля настройки:

- SSH;
- sysctl;
- host firewall;
- автоматических security updates;
- журналирования и системных лимитов.

До утверждения совместимого профиля для VPN-нод пункт ничего не меняет и возвращает пользователя в главное меню.

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

# CrowdSec installer for VPN nodes

Интерактивный установщик CrowdSec для Caddy-серверов проекта VPN.

## Поддерживаемые профили

При запуске мастер спрашивает, куда выполняется установка:

```text
Куда устанавливается CrowdSec?
  1 — Панель управления (пока не реализовано)
  2 — Нода CDN Origin
  3 — Нода VLESS + selfsteal на Caddy
```

Пустой Enter выбирает профиль `CDN Origin`.

## Запуск

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh | sudo sh
```

Для интерактивного режима требуется доступный `/dev/tty`.

## Профиль CDN Origin

Существующий сценарий:

- выбор Яндекс CDN, Билайн CDN или обоих провайдеров;
- получение и регулярное обновление официальных CDN-диапазонов;
- настройка `trusted_proxies` для Caddy;
- AllowList для CDN и IP администратора;
- выбор частоты обновления списков, по умолчанию `1h`;
- firewall bouncer только для SSH-решений, чтобы HTTP-решение не заблокировало CDN edge;
- подключение к CrowdSec Console;
- проверка регистрации remediation component и свежего API pull.

## Профиль VLESS + selfsteal

Сценарий предназначен для прямой VLESS-ноды, где Caddy обслуживает selfsteal-сайт.

Мастер запрашивает:

```text
Домен/адрес selfsteal-сайта:
Дополнительные доверенные IP через пробел или запятую [нет]:
```

Скрипт:

- проверяет Caddy и `/etc/caddy/Caddyfile`;
- находит ровно один site block по введённому адресу;
- сохраняет резервную копию Caddyfile;
- добавляет в выбранный site block управляемый JSON access log;
- проверяет конфигурацию через `caddy validate`;
- применяет её через graceful reload;
- устанавливает CrowdSec и коллекции Linux, SSH и Caddy;
- создаёт acquisition для selfsteal access log;
- добавляет IP текущего SSH-подключения и указанные IP в AllowList;
- устанавливает firewall bouncer для SSH- и HTTP-решений;
- проверяет CrowdSec, Caddy, bouncer и состояние пакетной базы.

### Управляемый Caddy log

В выбранный site block добавляется блок между маркерами:

```caddyfile
# BEGIN CROWDSEC VLESS SELFSTEAL LOG
log crowdsec_selfsteal {
    output file /var/log/caddy/selfsteal-access.log {
        mode 0640
        roll_size 50MiB
        roll_keep 10
        roll_keep_for 720h
    }
    format json
}
# END CROWDSEC VLESS SELFSTEAL LOG
```

При повторном запуске этот блок заменяется, а не дублируется.

Acquisition создаётся в:

```text
/etc/crowdsec/acquis.d/caddy-selfsteal.yaml
```

Резервные копии Caddyfile сохраняются в:

```text
/var/lib/crowdsec/vless-selfsteal-backups/
```

## CrowdSec Local API

Для обоих профилей Local API переносится на редкий loopback-порт:

```text
http://127.0.0.1:18888/
```

Синхронно обновляются:

```text
/etc/crowdsec/config.yaml
/etc/crowdsec/local_api_credentials.yaml
/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.local
```

Перед изменениями создаются резервные копии. При неудачном запуске CrowdSec настройки LAPI откатываются.

## Firewall bouncer

Backend определяется автоматически:

```bash
iptables -V
```

- при наличии `nf_tables` используется `crowdsec-firewall-bouncer-nftables`;
- иначе используется `crowdsec-firewall-bouncer-iptables`.

Профили решений:

```text
CDN Origin          → ssh
VLESS + selfsteal   → ssh, http
```

Для nftables используется входящий hook `input`. IPv4 и IPv6 остаются включёнными.

Повторная установка безопасна: новый API-ключ и `.yaml.local` создаются до обновления пакета. Если пакетный `postinst` прерывает `dpkg`, установщик запускает восстановление через `dpkg --configure -a` и при необходимости `apt-get -f install`.

## CrowdSec Console

После установки мастер спрашивает:

```text
Подключить CrowdSec к панели app.crowdsec.net? [Y/n]:
```

Enrollment key вводится скрыто. После `Accept enroll` установщик перезапускает CrowdSec и firewall bouncer.

## Проверки

```bash
systemctl status crowdsec --no-pager -l
systemctl status crowdsec-firewall-bouncer --no-pager -l
systemctl status caddy --no-pager -l
cscli metrics show acquisition
cscli metrics show bouncers
cscli bouncers list
cscli capi status
cscli console status
dpkg --audit
```

Для nftables:

```bash
nft list table ip crowdsec
nft list table ip6 crowdsec6
```

У рабочего bouncer должны быть `Valid: ✔` и свежее значение `Last API pull`.

## Закрепление версии

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh \
  | sudo VPN_INSTALL_REF=v1.0.0 sh
```

## Секреты

Не публикуйте содержимое:

- `/etc/cdn-trusted-proxies.conf`;
- `/etc/crowdsec/local_api_credentials.yaml`;
- `/etc/crowdsec/online_api_credentials.yaml`;
- `/etc/crowdsec/bouncers/*.yaml.local`;
- enrollment key CrowdSec Console.

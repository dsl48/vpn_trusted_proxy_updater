# CrowdSec для Caddy CDN-origin

Интерактивная установка CrowdSec на Caddy-origin за Яндекс CDN, Билайн CDN или одновременно за обоими провайдерами.

## Что делает установщик

- позволяет выбрать Яндекс CDN, Билайн CDN или обоих провайдеров;
- использует формат вопросов `[Y/n]`, где пустой Enter означает `yes`;
- запрашивает учётные данные Билайн только при выборе Beeline CDN;
- устанавливает CrowdSec Security Engine и коллекции Linux, SSH и Caddy;
- исправляет права `/var/log/caddy` и `access.log`;
- подключает Caddy access log к CrowdSec;
- получает и регулярно обновляет доверенные CDN-диапазоны;
- создаёт общий `trusted_proxies` для Caddy;
- создаёт CrowdSec AllowList для CDN и IP администратора;
- переносит CrowdSec Local API с `127.0.0.1:8080` на `127.0.0.1:18888`;
- автоматически определяет `nftables` или `iptables`;
- устанавливает соответствующий CrowdSec firewall bouncer;
- ограничивает firewall bouncer решениями SSH-сценариев;
- предлагает подключить Security Engine к `app.crowdsec.net`;
- применяет конфигурацию Caddy только через validation и graceful reload.

## Запуск одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh | sudo sh
```

## Выбор CDN

Мастер задаёт вопросы по очереди:

```text
Собирать списки с Яндекс CDN? [Y/n]:
Собирать списки с Билайн CDN? [Y/n]:
```

Ответы:

- Enter, `yes` или `y` — включить провайдера;
- `no` или `n` — не включать провайдера.

Нужно выбрать хотя бы одного провайдера.

При выборе Билайн CDN запрашиваются:

```text
Email Beeline CDN:
Пароль Beeline CDN:
```

Учётная запись нужна только для локального получения временного API-токена и официального списка CDN-узлов через Beeline API. Пароль не выводится на экран. Данные сохраняются в `/etc/cdn-trusted-proxies.conf` с правами `0600 root:root`.

## CrowdSec Local API

По умолчанию CrowdSec использует `127.0.0.1:8080`. Установщик переносит Local API на:

```text
http://127.0.0.1:18888/
```

Меняются одновременно:

```text
/etc/crowdsec/config.yaml
/etc/crowdsec/local_api_credentials.yaml
/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.local
```

Порт остаётся доступным только через loopback и не открывается наружу. Перед изменением установщик:

- проверяет, что `127.0.0.1:18888` свободен;
- сохраняет резервные копии конфигурации;
- перезапускает CrowdSec;
- проверяет Local API через `cscli`;
- откатывает настройки при ошибке.

Для ручного выбора другого локального порта:

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh \
  | sudo CROWDSEC_LAPI_PORT=18889 sh
```

## Firewall bouncer

После настройки CDN установщик проверяет вывод:

```bash
iptables -V
```

Если вывод содержит `nf_tables`, устанавливается:

```text
crowdsec-firewall-bouncer-nftables
```

Иначе устанавливается:

```text
crowdsec-firewall-bouncer-iptables
```

Конфигурация хранится в:

```text
/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.local
```

Для CDN-origin bouncer получает только решения сценариев, содержащих `ssh`. HTTP-алерты CrowdSec не превращаются в глобальную firewall-блокировку CDN edge. В режиме nftables используется только hook `input`.

## Подключение к CrowdSec Console

После установки bouncer мастер спросит:

```text
Подключить CrowdSec к панели app.crowdsec.net? [Y/n]:
```

Enter означает `yes`.

Enrollment key нужно скопировать в CrowdSec Console:

```text
Security Engines → Add Security Engine
```

Ключ вводится скрыто. Установщик выполняет:

```bash
cscli console enroll ENROLL_KEY
```

Затем нужно открыть появившийся Security Engine в панели и нажать `Accept enroll`. После подтверждения вернитесь в терминал и нажмите Enter — установщик перезапустит CrowdSec.

## Настройка Caddy

Добавьте в глобальный блок `/etc/caddy/Caddyfile`:

```caddyfile
{
    admin 127.0.0.1:2019

    servers {
        import /etc/caddy/trusted-proxies.caddy
        trusted_proxies_strict
        client_ip_headers X-Forwarded-For
    }
}
```

Для VPN/XHTTP endpoint добавьте `log_skip`:

```caddyfile
handle @tunnel {
    log_skip
    reverse_proxy 127.0.0.1:7443
}
```

Проверка и graceful reload:

```bash
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
```

## Проверки

```bash
systemctl status crowdsec --no-pager -l
systemctl status crowdsec-firewall-bouncer --no-pager -l
systemctl status cdn-trusted-proxies.timer --no-pager -l
grep -n 'listen_uri' /etc/crowdsec/config.yaml
grep -n '^url:' /etc/crowdsec/local_api_credentials.yaml
grep -n '^api_url:' /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.local
ss -lntp | grep ':18888'
cscli bouncers list
cscli console status
cscli metrics
cscli allowlists list
```

Для nftables:

```bash
nft list table ip crowdsec
nft list table ip6 crowdsec6
```

Списки CDN:

```bash
ls -l /etc/caddy/trusted-proxies.d/
wc -l /etc/caddy/trusted-proxies.d/*.cidr
```

При повторном запуске отключённый провайдер удаляется из активного набора, а общий `trusted-proxies.caddy` перестраивается только из выбранных источников.

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

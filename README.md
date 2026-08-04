# CrowdSec для Caddy CDN-origin

Интерактивная установка CrowdSec на origin-ноду Caddy, работающую за Яндекс CDN, Билайн CDN или одновременно за обоими провайдерами.

Установщик:

- последовательно спрашивает, собирать ли доверенные диапазоны с Яндекс CDN и Билайн CDN;
- позволяет выбрать только Яндекс, только Билайн или обоих провайдеров;
- запрашивает учётные данные Билайн только при выборе Билайн CDN;
- устанавливает CrowdSec Security Engine и базовые коллекции;
- исправляет права `/var/log/caddy` и `access.log`;
- подключает Caddy access log к CrowdSec;
- получает и обновляет доверенные CDN-диапазоны;
- объединяет только выбранные диапазоны для `trusted_proxies` Caddy;
- создаёт CrowdSec AllowList для выбранных CDN и IP администратора;
- применяет изменения Caddy только через проверенный graceful reload;
- не устанавливает firewall bouncer автоматически.

## Запуск одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh | sudo sh
```

Интерактивный мастер задаёт вопросы по очереди:

```text
Собирать списки с Яндекс CDN? [да/нет]:
Собирать списки с Билайн CDN? [да/нет]:
```

Нужно выбрать хотя бы одного провайдера.

При выборе Билайн CDN установщик объяснит назначение учётной записи, а затем запросит:

```text
Email Beeline CDN:
Пароль Beeline CDN:
```

Учётная запись нужна только для локального получения временного API-токена и официального списка CDN-узлов через Beeline API. Пароль не выводится на экран. Данные сохраняются в:

```text
/etc/cdn-trusted-proxies.conf
```

Права файла:

```text
0600 root:root
```

При выборе только Яндекс CDN учётные данные Билайн не запрашиваются и обращения к Beeline API не выполняются.

## После установки

Добавьте в глобальный блок `/etc/caddy/Caddyfile`:

```caddyfile
{
    admin 127.0.0.1:2019

    servers {
        import /etc/caddy/trusted-proxies.caddy
        trusted_proxies_strict
        client_ip_headers X-Forwarded-For

        protocols h1 h2 h3
        max_header_size 65536
    }
}
```

Для VPN/XHTTP endpoint добавьте `log_skip`, чтобы туннельный трафик не анализировался CrowdSec:

```caddyfile
handle @tunnel {
    log_skip
    reverse_proxy 127.0.0.1:7443
}
```

Проверьте конфигурацию и выполните graceful reload:

```bash
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
```

## Проверки

```bash
systemctl status crowdsec --no-pager
systemctl status cdn-trusted-proxies.timer --no-pager
cscli metrics
cscli allowlists list
cat /etc/cdn-trusted-proxies.conf | sed -E 's/^(BEELINE_PASSWORD=).*/\1REDACTED/'
```

Списки выбранных провайдеров:

```bash
ls -l /etc/caddy/trusted-proxies.d/
wc -l /etc/caddy/trusted-proxies.d/*.cidr
```

Если при повторном запуске провайдер отключён, его старый CIDR-файл удаляется из активного набора и общий `trusted-proxies.caddy` перестраивается только из выбранных источников.

## Закрепление версии

Для воспроизводимой установки укажите тег или commit через переменную:

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh \
  | sudo VPN_INSTALL_REF=v1.0.0 sh
```

## Секреты

Не публикуйте содержимое:

- `/etc/cdn-trusted-proxies.conf`;
- `/etc/crowdsec/local_api_credentials.yaml`;
- `/etc/crowdsec/online_api_credentials.yaml`;
- `/etc/crowdsec/bouncers/*.yaml.local`.

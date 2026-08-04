# CrowdSec для Caddy CDN-origin

Интерактивная установка CrowdSec на origin-ноду Caddy, работающую за Yandex CDN и Beeline CDN.

Установщик:

- устанавливает CrowdSec Security Engine и базовые коллекции;
- исправляет права `/var/log/caddy` и `access.log`;
- подключает Caddy access log к CrowdSec;
- получает и обновляет доверенные диапазоны Yandex и Beeline;
- объединяет диапазоны для `trusted_proxies` Caddy;
- создаёт CrowdSec AllowLists для CDN и IP администратора;
- применяет изменения Caddy только через проверенный graceful reload;
- не устанавливает firewall bouncer автоматически.

## Запуск одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/dsl48/vpn_trusted_proxy_updater/main/install.sh | sudo sh
```

Команда запускает интерактивный мастер и запросит учётные данные Beeline CDN через `/dev/tty`.

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
systemctl status crowdsec-cdn-allowlist.path --no-pager
cscli metrics
cscli allowlists list
```

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

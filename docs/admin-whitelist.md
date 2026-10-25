# Whitelist сайтов для WebUI

WebUI может ходить наружу **только** через `egress-proxy` (squid) и только на
домены из whitelist. Политика (конфиг `config/squid/squid.conf`):

- методы: только `GET`/`HEAD`;
- домены: только из `config/squid/whitelist.txt` (ведущая точка = поддомены);
- HTTP-ответы: только текстовые `Content-Type` (`text/html`, `text/plain`,
  `application/json`) — картинки/видео/аудио отсекаются;
- HTTPS (`CONNECT`): туннель разрешён **только** на домены из whitelist.
  Внутри туннеля squid контент не видит — для HTTPS работает только
  доменный контроль (фильтр Content-Type по HTTPS — TLS bump, roadmap);
- всё остальное — deny. Изначально whitelist пуст → наружу нельзя никуда.

## Операции

```bash
make whitelist-add DOMAIN=php.net   # добавить + squid -k reconfigure
make whitelist-list                 # активные записи
make whitelist-rm DOMAIN=php.net    # убрать + reconfigure
```

`make` работает только при запущенном `halogen-egress-proxy`. Ручная правка
`whitelist.txt` тоже допустима — затем `podman exec halogen-egress-proxy squid -k reconfigure`.

## Пример: разрешить документацию PHP

```bash
make whitelist-add DOMAIN=php.net
```

В `whitelist.txt` появится строка `.php.net` (домен + поддомены). Проверка
выполняется **из контейнера web-ui** (у хоста своих правил нет):

```bash
# разрешённый документационный HTTP-запрос: ожидаем 200 text/html
podman exec halogen-web-ui python -c \
  "import requests; r=requests.get('http://php.net',timeout=15); print(r.status_code, r.headers.get('content-type'))"

# картинка с того же домена: ожидаем ошибку (Content-Type отклонён)
podman exec halogen-web-ui python -c \
  "import requests; requests.get('http://php.net/images/php-logo.gif',timeout=15)"

# не-whitelisted домен: ожидаем ошибку прокси
podman exec halogen-web-ui python -c \
  "import requests; requests.get('http://example.org',timeout=15)"
```

## В Open WebUI

Функция «Web URL context» (чтение веб-страниц по URL) и web-поиск должны быть
включены администратором в Settings → RAG; без whitelist они будут падать на
403 — это ожидаемое поведение пустого whitelist.

## Ограничение, которое надо помнить

«Только документация» семантически не фильтруется: любой разрешённый домен
отдаёт то, что на нём лежит. Фильтр — домен + метод + Content-Type.
Медиа-контент с разрешённых HTTP-доменов отсекается, с HTTPS-доменов — нет
(туннель).

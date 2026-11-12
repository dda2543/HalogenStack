# halogen-stack — управление со стороны сервера-хоста (podman + podman-compose).
PODMAN  ?= podman
COMPOSE ?= podman-compose
SECRETS_DIR ?= ./secrets
KEYS      := $(SECRETS_DIR)/keys.acl
WHITELIST := config/squid/whitelist.txt

# Пустой LAN_IP в интерполяции даёт ":8731:8080" — публикацию LLM-порта на
# 0.0.0.0. Проверка падает до всякой интерполяции и различает два случая:
# LAN_IP передан пустым через окружение (podman-compose берёт окружение даже
# при значении в .env — именно так в 2026-10-28 получили `invalid port number`)
# и LAN_IP пуст/отсутствует в .env.
# Шаблон поиска в .env терпим к вариантам записи (export LAN_IP=…, пробелы
# вокруг `=`) — их podman-compose понимает, а узкий `^LAN_IP=` их бы не нашёл
# и отклонил бы валидный запуск.
GUARD_LAN_IP = if [ -n "$${LAN_IP+x}" ]; then test -n "$$LAN_IP" || { echo "LAN_IP передан пустым окружением — порт 8731 опубликовался бы на 0.0.0.0"; exit 1; }; else grep -qE '^[[:space:]]*(export[[:space:]]+)?LAN_IP[[:space:]]*=[[:space:]]*[^[:space:]]' .env 2>/dev/null || { echo "LAN_IP не задан ни в окружении, ни в .env — порт 8731 опубликовался бы на 0.0.0.0"; exit 1; }; fi

# Дисковый prompt-кэш (решение 2026-11-12) обязан лежать на выделенном диске:
# в 2026-10-28 он съел 42 GiB на / и чуть не убил раздел. Проверки три, по
# образцу GUARD_LAN_IP:
#   1) HALOGEN_CACHE_DIR_HOST задан (пустое значение из окружения — отдельное
#      сообщение: оно перебивает .env так же, как у LAN_IP);
#   2) путь сам является точкой монтирования ИЛИ его родитель является — то
#      есть под ним реально примонтирован диск, а не каталог на /;
#   3) устройство этого пути ОТЛИЧАЕТСЯ от устройства /: иначе «каталог прямо в
#      /» (например /cache) проходил бы по проверке 2 — / тоже точка монтирования.
# Канон: диск смонтирован в /srv/halogen-cache, кэш в /srv/halogen-cache/
# prompt-cache. Сам prompt-cache существует только на новом диске, поэтому без
# монтирования podman не смог бы его создать (родитель принадлежит root, 0755) —
# guard лишь даёт внятное сообщение вместо этой ошибки. Разметка диска:
# docs/admin-cache-disk.md.
GUARD_CACHE_DIR = if [ -n "$${HALOGEN_CACHE_DIR_HOST+x}" ]; then test -n "$$HALOGEN_CACHE_DIR_HOST" || { echo "HALOGEN_CACHE_DIR_HOST передан пустым окружением — кэш уехал бы на корневой раздел"; exit 1; }; d="$$HALOGEN_CACHE_DIR_HOST"; else d=$$(grep -E '^[[:space:]]*(export[[:space:]]+)?HALOGEN_CACHE_DIR_HOST[[:space:]]*=' .env 2>/dev/null | tail -n 1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$$//; s/^"(.*)"$$/\1/'); if [ -z "$$d" ]; then echo "HALOGEN_CACHE_DIR_HOST не задан ни в окружении, ни в .env — кэш уехал бы на корневой раздел"; exit 1; fi; fi; p="$$d"; mountpoint -q "$$p" 2>/dev/null || p="$$(dirname "$$d")"; if ! mountpoint -q "$$p" 2>/dev/null; then echo "каталог кэша $$d не на примонтированном устройстве ($$p — не точка монтирования): поднимите диск, см. docs/admin-cache-disk.md"; exit 1; fi; r=$$(df -P / 2>/dev/null | awk 'NR==2 {print $$1}'); c=$$(df -P "$$p" 2>/dev/null | awk 'NR==2 {print $$1}'); if [ -z "$$r" ] || [ -z "$$c" ] || [ "$$r" = "$$c" ]; then echo "каталог кэша $$d лежит на том же устройстве, что и / ($${c:-неизвестно}) — нужен выделенный диск, иначе повторится сценарий 2026-10-28"; exit 1; fi

.PHONY: init up down build logs ps cache-info key-add key-rotate key-rm key-list whitelist-add whitelist-rm whitelist-list

init: ## создать пустой secrets/keys.acl и .env из примеров
	@test -f $(KEYS) || (install -m 600 secrets/keys.acl.example $(KEYS) && echo "создан $(KEYS) (пустой): добавьте ключи — make key-add NAME=...")
	@test -f .env || (cp .env.example .env && echo "создан .env: заполните LAN_IP, каталоги, ключи")

up: ## поднять стек (build + up -d)
	@$(GUARD_LAN_IP)
	@$(GUARD_CACHE_DIR)
	$(COMPOSE) -f compose.yaml up -d --build
down: ## остановить стек
	$(COMPOSE) -f compose.yaml down
build: ## собрать образы
	$(COMPOSE) -f compose.yaml build
logs: ## логи всех сервисов
	$(COMPOSE) -f compose.yaml logs -f --tail=100
ps: ## статус контейнеров
	$(COMPOSE) -f compose.yaml ps

# Переменная d остаётся заданной в этом же шелле: рецепт — одна команда.
cache-info: ## состояние дискового prompt-кэша (устройство, занято, размер каталога)
	@$(GUARD_CACHE_DIR); \
	echo "каталог кэша: $$d"; \
	mountpoint "$$d" 2>/dev/null || mountpoint "$$(dirname "$$d")"; \
	df -h "$$d" 2>/dev/null | tail -n 2; \
	printf 'размер каталога: '; du -sh "$$d" 2>/dev/null | cut -f1

# --- Ключи пользователей (auth-provider перечитывает keys.acl по mtime) ---

key-add: ## make key-add NAME=agent1 (новая запись; для смены значения — key-rotate)
	@test -n "$(NAME)" || { echo "использование: make key-add NAME=<имя>"; exit 1; }
	@if grep -q '^$(NAME):' $(KEYS) 2>/dev/null; then \
	  echo "ключ '$(NAME)' уже есть — новое значение: make key-rotate NAME=$(NAME)"; exit 1; \
	fi
	@KEY=$$(openssl rand -hex 32); \
	printf '%s:%s\n' "$(NAME)" "$$KEY" >> $(KEYS); chmod 600 $(KEYS); \
	echo "Добавлен ключ '$(NAME)' (показывается один раз): $$KEY"

key-rotate: ## make key-rotate NAME=agent1 (перевыпустить значение существующего ключа)
	@test -n "$(NAME)" || { echo "использование: make key-rotate NAME=<имя>"; exit 1; }
	@grep -q '^$(NAME):' $(KEYS) 2>/dev/null || { echo "ключа '$(NAME)' нет — добавьте: make key-add NAME=$(NAME)"; exit 1; }
	@KEY=$$(openssl rand -hex 32); \
	grep -v '^$(NAME):' $(KEYS) > $(KEYS).tmp && \
	printf '%s:%s\n' "$(NAME)" "$$KEY" >> $(KEYS).tmp && \
	mv $(KEYS).tmp $(KEYS) && chmod 600 $(KEYS); \
	echo "Ключ '$(NAME)' перевыпущен (показывается один раз): $$KEY"

key-rm: ## make key-rm NAME=agent1
	@test -n "$(NAME)" || { echo "использование: make key-rm NAME=<имя>"; exit 1; }
	@grep -v '^$(NAME):' $(KEYS) > $(KEYS).tmp && mv $(KEYS).tmp $(KEYS)
	@echo "Ключ '$(NAME)' удалён (отзыв действует после перечитывания auth-provider)"

key-list: ## имена ключей (без значений)
	@grep -v '^#' $(KEYS) 2>/dev/null | cut -d: -f1 | grep . || echo "(пусто)"

# --- Whitelist сайтов для web-ui (make редактирует файл + squid reconfigure) ---

whitelist-add: ## make whitelist-add DOMAIN=php.net
	@test -n "$(DOMAIN)" || { echo "использование: make whitelist-add DOMAIN=php.net"; exit 1; }
	@grep -qF '.$(DOMAIN)' $(WHITELIST) 2>/dev/null || echo '.$(DOMAIN)' >> $(WHITELIST)
	@$(PODMAN) exec halogen-egress-proxy squid -k reconfigure
	@echo "Разрешён домен '.$(DOMAIN)' (и поддомены)"

whitelist-rm: ## make whitelist-rm DOMAIN=php.net
	@test -n "$(DOMAIN)" || { echo "использование: make whitelist-rm DOMAIN=php.net"; exit 1; }
	@grep -v '^\.$(DOMAIN)$$' $(WHITELIST) > $(WHITELIST).tmp && mv $(WHITELIST).tmp $(WHITELIST)
	@$(PODMAN) exec halogen-egress-proxy squid -k reconfigure
	@echo "Домен '.$(DOMAIN)' убран из whitelist"

whitelist-list: ## активные записи whitelist
	@grep -v '^#' $(WHITELIST) | grep . || echo "(пусто — наружу нельзя никуда)"

# --- Фаза 2: публичный вход WebUI (waf-firewall, TLS) ---
# Подробности: docs/admin-public.md

PUBLIC_COMPOSE := -f compose.yaml -f compose.public.yaml
PUBLIC_DOMAIN  ?= ai.dda2543.ru
CERTS_DIR      ?= ./secrets/certs

.PHONY: waf-build public-up public-down public-logs cert cert-renew

waf-build: ## собрать образ waf-firewall (Caddy + Coraza + CRS; нужен интернет)
	$(COMPOSE) $(PUBLIC_COMPOSE) build waf-firewall

public-up: ## фаза 1 + waf-firewall (публичный вход)
	@$(GUARD_LAN_IP)
	@$(GUARD_CACHE_DIR)
	$(COMPOSE) $(PUBLIC_COMPOSE) up -d --build

public-down: ## снять всё вместе с фазой 2
	$(COMPOSE) $(PUBLIC_COMPOSE) down

public-logs: ## логи waf-firewall
	$(PODMAN) logs --tail=100 -f halogen-waf

cert: ## make cert CERT_EMAIL=admin@... — выпуск сертификата (нужен DNS и свободный :80)
	@test -n "$(CERT_EMAIL)" || { echo "использование: make cert CERT_EMAIL=admin@$(PUBLIC_DOMAIN)"; exit 1; }
	@echo "Требования: DNS $(PUBLIC_DOMAIN) → IP сервера; порт 80 на хосте свободен (waf слушает 443)."
	sudo certbot certonly --standalone --agree-tos -m $(CERT_EMAIL) -d $(PUBLIC_DOMAIN) \
	  --deploy-hook 'sh $(CURDIR)/scripts/cert-deploy.sh $(abspath $(CERTS_DIR)) $(shell id -un)'

cert-renew: ## продлить сертификаты и перезапустить waf (иначе Caddy держит старый)
	sudo certbot renew
	-$(PODMAN) restart halogen-waf

# waf-firewall: Caddy 2 + Coraza (coraza-caddy) + правила OWASP CRS.
# Собирается НА СЕРВЕРЕ: make waf-build (сборке нужен доступ в интернет).
# АГЕНТОМ НЕ СОБИРАЛСЯ (в песочнице нет podman/сети) — первый прогон человек,
# версии ниже проверить и зафиксировать (образец — пин squid по digest).

# --- правила CRS ---
FROM docker.io/library/alpine:3.20 AS crs
# Актуальные теги: https://github.com/coreruleset/coreruleset/tags
ARG CRS_VERSION=v4.4.0
RUN apk add --no-cache curl ca-certificates tar && \
    curl -fsSL "https://github.com/coreruleset/coreruleset/archive/refs/tags/${CRS_VERSION}.tar.gz" \
      | tar xz -C /opt && \
    mv /opt/coreruleset-* /opt/crs

# --- бинарник Caddy с модулем Coraza ---
FROM docker.io/library/caddy:2-builder AS builder
# После первой успешной сборки заменить на конкретную версию coraza-caddy.
ARG CORAZA_CADDY_VERSION=latest
RUN xcaddy build --with github.com/corazawaf/coraza-caddy/v2@${CORAZA_CADDY_VERSION}

FROM docker.io/library/caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
# Базовые директивы Coraza (SecDefaultAction и пр.) лежат внутри модуля и
# подключаются в Caddyfile как `Include @coraza.conf-recommended`.
COPY --from=crs /opt/crs/rules/ /etc/coraza/rules/
COPY --from=crs /opt/crs/crs-setup.conf.example /etc/coraza/crs-setup.conf

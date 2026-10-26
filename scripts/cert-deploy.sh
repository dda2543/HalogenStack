#!/bin/sh
# deploy-hook certbot: копирует сертификат в каталог, который читает
# rootless-контейнер waf-firewall.
#
# Вызывается certbot'ом (т.е. от root) при выпуске и при каждом успешном
# продлении. Так как hook работает от root, файлы явно переназначаются
# администратору хоста: в rootless podman uid 0 контейнера = uid этого
# пользователя, поэтому 0600 хватает без chown в контейнере и без флага `U`.
#
# Использование (из Makefile): cert-deploy.sh <каталог-назначения> <владелец>
set -eu

dest="${1:?использование: cert-deploy.sh <каталог-назначения> <владелец>}"
owner="${2:-root}"
domain="${CERTBOT_DOMAIN:?CERTBOT_DOMAIN задаёт certbot (не запускать вручную)}"
live="/etc/letsencrypt/live/${domain}"

install -d -m 700 "$dest"
install -m 600 "${live}/fullchain.pem" "${dest}/fullchain.pem"
install -m 600 "${live}/privkey.pem"   "${dest}/privkey.pem"
chown -R "${owner}" "$dest"
echo "cert-deploy: ${domain} → ${dest} (владелец ${owner})"

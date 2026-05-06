#!/bin/sh
set -eu

ENABLE_HTTPS="${ENABLE_HTTPS:-0}"
LE_WEBROOT="${LE_WEBROOT:-/var/www/_letsencrypt}"
AUTO_RELOAD_CERTS="${AUTO_RELOAD_CERTS:-1}"

if [ "$ENABLE_HTTPS" = "1" ]; then
  ENABLE_LETSENCRYPT="${ENABLE_LETSENCRYPT:-1}"
else
  ENABLE_LETSENCRYPT="${ENABLE_LETSENCRYPT:-0}"
fi

mkdir -p /etc/nginx/conf.d "$LE_WEBROOT" /run

if [ "$AUTO_RELOAD_CERTS" = "1" ] && [ -d /etc/letsencrypt ]; then
  (
    inotifywait -m -e close_write,move,create,delete /etc/letsencrypt >/dev/null 2>&1 |
      while read -r _; do
        nginx -s reload || true
      done
  ) &
fi

exec "$@"

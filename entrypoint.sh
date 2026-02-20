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

if [ "$ENABLE_HTTPS" = "1" ]; then
  if [ "$ENABLE_LETSENCRYPT" = "1" ]; then
    cat > /etc/nginx/conf.d/00-redirect-all.conf <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;

  location ^~ /.well-known/acme-challenge/ {
    root $LE_WEBROOT;
    default_type "text/plain";
    try_files \$uri =404;
  }

  location / { return 308 https://\$host\$request_uri; }
}
EOF
  else
    cat > /etc/nginx/conf.d/00-redirect-all.conf <<'EOF'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  location / { return 308 https://$host$request_uri; }
}
EOF
  fi
else
  cat > /etc/nginx/conf.d/00-redirect-all.conf <<'EOF'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  location /healthz { return 200 "ok\n"; }
  location / { return 404; }
}
EOF
fi

if [ "$AUTO_RELOAD_CERTS" = "1" ] && [ -d /etc/letsencrypt ]; then
  ( inotifywait -m -e close_write,move,create,delete /etc/letsencrypt >/dev/null 2>&1 \
      | while read -r _; do
          nginx -s reload || true
        done
  ) &
fi

exec "$@"

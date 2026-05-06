# Nginx WAF Image (ModSecurity + CRS + headers-more)

This document describes how to **use**, **configure**, and **maintain** the Docker/Podman image built in this thread.

It assumes:

* Built the image (example tag: `nginx-waf:1.28.2-modsec3.0.14-crs4.23.0`).
* Nginx layout:

  * `modsec/` for ModSecurity + CRS
  * `conf.d/` for shared snippets and upstream definitions
  * `sites-enabled/` for all `server {}` blocks

---

## 1) What this image contains

### Included components

* **Nginx (stable)** compiled from source
* **ModSecurity v3** (libmodsecurity)
* **ModSecurity-nginx connector** (dynamic module)
* **headers-more** module (dynamic module)
* **OWASP Core Rule Set (CRS)** under `/etc/nginx/modsec/owasp-crs`

### Layout inside the container

```
/etc/nginx/
  nginx.conf
  modules/
  modsec/
    modsecurity.conf
    unicode.mapping
    owasp-crs/
      crs-setup.conf
      rules/*.conf
  conf.d/
    maps.conf                 # baked into image
    proxy_common.conf         # baked into image
    proxy_http.conf           # baked into image (optional)
    proxy_ws.conf             # baked into image (optional)
    upstreams.conf            # meant to be mounted at runtime
  sites-enabled/              # meant to be mounted at runtime
```

---

## 2) Runtime behavior and environment variables

### Default behavior

* **HTTP only** (port 80)
* Port 443 is available but requires you to provide server blocks in `sites-enabled/`
* No default server is automatically generated; you must define all server blocks
* Requests to undefined `server_name` values will be dropped or matched to the first defined server

### Environment variables

| Variable             |                 Default | Meaning                                                                                                                                                             |
| -------------------- | ----------------------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ENABLE_HTTPS`       |                     `0` | When `1`, assumes you will handle HTTPS setup manually (no redirect server generated).                                                                              |
| `ENABLE_LETSENCRYPT` |                    auto | If `ENABLE_HTTPS=1` and this is **unset**, it defaults to `1` (Let's Encrypt mode). If set to `0`, you must provide certs manually in your `sites-enabled` configs. |
| `LE_WEBROOT`         | `/var/www/_letsencrypt` | ACME webroot where `.well-known/acme-challenge/` is served (only used when LE is enabled).                                                                          |
| `AUTO_RELOAD_CERTS`  |                     `1` | When `1`, a background watcher triggers `nginx -s reload` when `/etc/letsencrypt` changes (useful for renewals).                                                    |

### Let’s Encrypt certificate storage

Certificates are stored at:

```
/etc/letsencrypt/live/<domain>/fullchain.pem
/etc/letsencrypt/live/<domain>/privkey.pem
```

A volume should persist `/etc/letsencrypt`.

---

## 3) Runtime mounts from your host

You manage (mount from host at runtime):

1. `./conf.d/upstreams.conf` → `/etc/nginx/conf.d/upstreams.conf`
2. `./sites-enabled/` → `/etc/nginx/sites-enabled/`

> Note: `maps.conf`, `proxy_common.conf`, and helper configs like `proxy_http.conf` / `proxy_ws.conf` are **baked into the image** and included from `nginx.conf`. If you need custom versions, rebuild the image or mount them to override.

### 3.1 `conf.d/upstreams.conf`

For Compose testing, **use service names** (not `127.0.0.1`) because upstream services run in separate containers.

Example:

```nginx
upstream app1_backend {
  server app1:8080;
  keepalive 16;
}

upstream app2_backend {
  server app2:9090;
  keepalive 16;
}
```

> Note: You *can* point upstreams at private or public IPs as well:
> `server 192.168.1.50:8080;` or `server 10.0.0.10:8443;`.

### 3.2 `sites-enabled/*.conf`

Each file contains one or more `server {}` blocks.

The image includes proxy helper configs in `conf.d/`:
* `proxy_common.conf` — common proxy headers (Host, X-Forwarded-*, X-Request-Id)
* `proxy_http.conf` — HTTP-specific (disables Connection header)
* `proxy_ws.conf` — WebSocket-specific (Upgrade, Connection)

For HTTP smoke testing, a simple example:

```nginx
server {
  listen 80;
  server_name localhost;

  # Enable ModSecurity per-site
  modsecurity on;
  modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;

  location /app1/ {
    proxy_pass http://app1_backend/;
    include /etc/nginx/conf.d/proxy_common.conf;
    include /etc/nginx/conf.d/proxy_http.conf;
  }

  location /app2/ {
    proxy_pass http://app2_backend/;
    include /etc/nginx/conf.d/proxy_common.conf;
    include /etc/nginx/conf.d/proxy_http.conf;
  }

  location /healthz {
    return 200 "ok\n";
  }
}
```

#### Why `server_name` matters

Nginx matches requests to server blocks using the `Host` header. If two server blocks try to use `server_name _;` (wildcard), one will be ignored and you'll see warnings:

```
conflicting server name "_" on 0.0.0.0:80, ignored
```

**Solution**: Use specific server names that match your test/production domains:

```nginx
server_name localhost;                    # for local testing
server_name your-domain.com;              # for production
server_name 10.10.10.115 127.0.0.1;      # for private networks
```

When you request `http://localhost:8080/...`, the `Host` header is `localhost`. Using `server_name localhost;` ensures your block matches correctly.

---

## 4) Compose file for smoke testing

### 4.1 `compose.yaml`

```yaml
services:
  waf:
    image: nginx-waf:1.28.2-modsec3.0.14-crs4.23.0
    container_name: waf
    ports:
      - "8080:80"
      - "8443:443"
    environment:
      ENABLE_HTTPS: "0"          # default: HTTP only
      # ENABLE_HTTPS: "1"        # enable HTTPS support (manual cert setup)
      # ENABLE_LETSENCRYPT: "0"  # manual certs (only if ENABLE_HTTPS=1)
      LE_WEBROOT: /var/www/_letsencrypt
      AUTO_RELOAD_CERTS: "1"
    volumes:
      # Your custom upstream definitions
      - ./conf.d/upstreams.conf:/etc/nginx/conf.d/upstreams.conf:ro
      # Your custom server blocks
      - ./sites-enabled:/etc/nginx/sites-enabled:ro
      # Let's Encrypt persistence (safe to include even if not used)
      - letsencrypt:/etc/letsencrypt
      - acme_webroot:/var/www/_letsencrypt
      # Logs
      - waf_logs:/var/log/nginx
    depends_on:
      - app1
      - app2
    restart: unless-stopped

  app1:
    image: hashicorp/http-echo:1.0
    command: ["-listen=:8080", "-text=app1 ok"]
    expose:
      - "8080"

  app2:
    image: hashicorp/http-echo:1.0
    command: ["-listen=:9090", "-text=app2 ok"]
    expose:
      - "9090"

  # Optional: certbot renewal loop (useful only if ENABLE_HTTPS=1 and ENABLE_LETSENCRYPT=1)
  certbot:
    image: ${CERTBOT_IMAGE:-certbot/certbot:latest}
    volumes:
      - letsencrypt:/etc/letsencrypt
      - acme_webroot:/var/www/_letsencrypt
    entrypoint: ["sh", "-c"]
    command: >
      trap exit TERM;
      while :; do
        certbot renew --webroot -w /var/www/_letsencrypt --quiet;
        sleep 12h;
      done
    restart: unless-stopped
    profiles: ["le"]

volumes:
  letsencrypt:
  acme_webroot:
  waf_logs:
```

### 4.2 Bring it up

```bash
podman compose up -d
# or
docker compose up -d
```

### 4.3 Test

```bash
curl -i http://localhost:8080/healthz
curl -i http://localhost:8080/app1/
curl -i http://localhost:8080/app2/
```

---

## 5) HTTPS modes

### 5.1 HTTPS + Let's Encrypt setup

**Prerequisites:**
1. Your domain DNS must point to the host running this container.
2. Port 80 and 443 must be accessible from the internet.

**Steps:**

1. Set environment variables in your `compose.yaml`:

```yaml
environment:
  ENABLE_HTTPS: "1"
  # ENABLE_LETSENCRYPT defaults to 1 when ENABLE_HTTPS=1
  LE_WEBROOT: /var/www/_letsencrypt
  AUTO_RELOAD_CERTS: "1"
```

2. Create an HTTP server block in `sites-enabled/` to handle ACME challenges:

```nginx
server {
  listen 80;
  server_name your-domain.com;

  location /.well-known/acme-challenge/ {
    root /var/www/_letsencrypt;
  }

  # Optional: redirect all other traffic to HTTPS
  location / {
    return 301 https://$host$request_uri;
  }
}
```

3. Issue the certificate **once** (requires DNS pointing to host):

```bash
podman compose --profile le run --rm certbot certonly \
  --webroot -w /var/www/_letsencrypt \
  -d your-domain.com \
  --agree-tos --no-eff-email \
  -m you@your-domain.com
```

4. Add a 443 server block in `sites-enabled/` that references LE paths:

```nginx
server {
  listen 443 ssl http2;
  server_name your-domain.com;

  ssl_certificate     /etc/letsencrypt/live/your-domain.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

  modsecurity on;
  modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;

  location / {
    proxy_pass http://app1_backend;
    include /etc/nginx/conf.d/proxy_common.conf;
    include /etc/nginx/conf.d/proxy_http.conf;
  }
}
```

5. Bring the container up:

```bash
podman compose up -d
```

The `AUTO_RELOAD_CERTS` watcher will detect certificate renewals and reload Nginx automatically.

### 5.2 HTTPS + manual certificates

* Set:

```yaml
environment:
  ENABLE_HTTPS: "1"
  ENABLE_LETSENCRYPT: "0"
```

* You must mount your own certificates and reference them in your `sites-enabled/` server blocks:

```yaml
volumes:
  - ./certs/domain.com.crt:/etc/nginx/certs/domain.com.crt:ro
  - ./certs/domain.com.key:/etc/nginx/certs/domain.com.key:ro
```

Then reference them in your server block:

```nginx
server {
  listen 443 ssl http2;
  server_name your-domain.com;
  
  ssl_certificate     /etc/nginx/certs/your-domain.com.crt;
  ssl_certificate_key /etc/nginx/certs/your-domain.com.key;
  
  # ... rest of config
}
```

---

## 6) ModSecurity + CRS usage

### 6.1 Default mode

* The image ships ModSecurity config derived from `modsecurity.conf-recommended` with:

  * `SecRuleEngine DetectionOnly`
  * `SecUnicodeMapFile /etc/nginx/modsec/unicode.mapping 20127`
  * CRS includes:

    * `Include /etc/nginx/modsec/owasp-crs/crs-setup.conf`
    * `Include /etc/nginx/modsec/owasp-crs/rules/*.conf`

### 6.2 Enable per site

In a `server {}` block:

```nginx
modsecurity on;
modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;
```

### 6.3 Audit log

* Default audit log path:

```
/var/log/nginx/modsec_audit.log
```

Mount `/var/log/nginx` to persist logs and monitor file growth.

### 6.4 Switching to blocking

After you tune exclusions (recommended):

* Change `SecRuleEngine DetectionOnly` to `SecRuleEngine On`.

---

## 7) Common issues and fixes

### 7.1 Warning: conflicting server name "_" on 0.0.0.0:80

Cause:

* Two or more `server {}` blocks with `server_name _;` on the same port.
* Nginx will only use one and ignore the others.

Fix:

* Give each site a specific name like `server_name localhost;`, `server_name your-domain.com;`, or `server_name 127.0.0.1;`
* Never use multiple `server_name _;` blocks on the same port.

### 7.2 Requests return 404 from Nginx

Cause:

* No server block matches your request's `Host` header.
* Nginx will use the first defined server block as a fallback.

Fix:

* Ensure your `sites-enabled/*.conf` server block matches the request `Host` header.
* Verify configs loaded:

```bash
podman exec waf nginx -T | grep -n "server_name"
```

### 7.3 Upstreams using 127.0.0.1 don’t work in Compose

Cause:

* `127.0.0.1` inside the WAF container refers to the container itself.

Fix:

* Use service names: `server app1:8080;`
* Or point to private/public IPs explicitly.

---

## 8) Maintenance recommendations

### 8.1 Version bumps

When you bump versions (Nginx / ModSecurity / CRS):

* Rebuild the image.
* Run `nginx -t` and a smoke test.
* Review ModSecurity audit logs for rule behavior changes.

### 8.2 CRS tuning workflow

Recommended workflow:

1. Run in `DetectionOnly`.
2. Observe audit logs (rule IDs that fire frequently).
3. Add exclusions or adjust CRS config.
4. Move to `SecRuleEngine On` gradually (per-site first).

### 8.3 Observability

* Persist `/var/log/nginx`.
* Consider log rotation externally (or via host).

---

## 9) Quick commands

Validate config:

```bash
podman exec waf nginx -t
```

Reload Nginx:

```bash
podman exec waf nginx -s reload
```

Dump full running config:

```bash
podman exec waf nginx -T
```

---

## Appendix A: Files baked into the image

**These are part of the container build** (in the `Containerfile`):

* `nginx.conf`
* `conf.d/maps.conf`
* `conf.d/proxy_common.conf`
* `conf.d/proxy_http.conf` (optional HTTP proxy helpers)
* `conf.d/proxy_ws.conf` (optional WebSocket proxy helpers)
* `entrypoint.sh`

**These you provide at runtime** (mounted as volumes):

* `./conf.d/upstreams.conf` (your custom upstream definitions)
* `./sites-enabled/*.conf` (your custom server blocks)

---

## Appendix B: Example `sites-enabled/` configurations

### HTTP proxy with common headers

```nginx
server {
  listen 80;
  server_name localhost;

  modsecurity on;
  modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;

  location /api/ {
    proxy_pass http://api_backend/;
    include /etc/nginx/conf.d/proxy_common.conf;
    include /etc/nginx/conf.d/proxy_http.conf;
  }
}
```

### WebSocket proxy

```nginx
server {
  listen 80;
  server_name localhost;

  location /ws/ {
    proxy_pass http://ws_backend/;
    include /etc/nginx/conf.d/proxy_common.conf;
    include /etc/nginx/conf.d/proxy_ws.conf;
  }
}
```

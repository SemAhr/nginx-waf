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
    00-redirect-all.conf      # generated at runtime by entrypoint
    maps.conf
    proxy_common.conf
    upstreams.conf            # meant to be mounted
  sites-enabled/              # meant to be mounted
```

---

## 2) Runtime behavior and environment variables

### Default behavior

* **HTTP only**
* A runtime-generated default server answers `/healthz` and returns `404` for most other paths.

### Environment variables

| Variable             |                 Default | Meaning                                                                                                                                                             |
| -------------------- | ----------------------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ENABLE_HTTPS`       |                     `0` | When `1`, the container generates an HTTP->HTTPS redirect server on port 80.                                                                                        |
| `ENABLE_LETSENCRYPT` |                    auto | If `ENABLE_HTTPS=1` and this is **unset**, it defaults to `1` (Let’s Encrypt mode). If set to `0`, you must provide certs manually in your `sites-enabled` configs. |
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

## 3) Minimal host files you manage

You manage (mount from host):

1. `./conf.d/upstreams.conf` → `/etc/nginx/conf.d/upstreams.conf`
2. `./sites-enabled/` → `/etc/nginx/sites-enabled/`

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

For HTTP smoke testing, a simple example:

```nginx
server {
  listen 80;
  server_name localhost;

  # Enable ModSecurity per-site
  modsecurity on;
  modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;

  location /app1/ {
    include /etc/nginx/conf.d/proxy_common.conf;
    proxy_pass http://app1_backend/;
  }

  location /app2/ {
    include /etc/nginx/conf.d/proxy_common.conf;
    proxy_pass http://app2_backend/;
  }

  location /healthz {
    return 200 "ok\n";
  }
}
```

#### Why `server_name localhost` matters

If your default server uses `server_name _;` and your test server also uses `_`, Nginx may warn:

```
conflicting server name "_" on 0.0.0.0:80, ignored
```

And your custom routes won’t match.

When you request `http://localhost:8080/...`, the `Host` header is `localhost`. Using `server_name localhost;` makes your server block match correctly.

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
      # ENABLE_HTTPS: "1"        # enable HTTP->HTTPS redirect on :80
      # ENABLE_LETSENCRYPT: "0"  # manual certs (only if ENABLE_HTTPS=1)
      LE_WEBROOT: /var/www/_letsencrypt
      AUTO_RELOAD_CERTS: "1"
    volumes:
      - ./conf.d/upstreams.conf:/etc/nginx/conf.d/upstreams.conf:ro
      - ./sites-enabled:/etc/nginx/sites-enabled:ro
      - letsencrypt:/etc/letsencrypt
      - acme_webroot:/var/www/_letsencrypt
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
    image: certbot/certbot:latest
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

### 5.1 HTTPS + Let’s Encrypt (default when `ENABLE_HTTPS=1`)

1. Set environment:

```env
ENABLE_HTTPS=1
# ENABLE_LETSENCRYPT not set => defaults to 1
```

2. Issue the certificate **once** (requires your domain DNS pointing to the host):

```bash
podman compose --profile le run --rm certbot certonly \
  --webroot -w /var/www/_letsencrypt \
  -d your-domain.com \
  --agree-tos --no-eff-email \
  -m you@your-domain.com
```

3. Add a 443 server block in `sites-enabled/` that references LE paths:

```nginx
server {
  listen 443 ssl http2;
  server_name your-domain.com;

  ssl_certificate     /etc/letsencrypt/live/your-domain.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

  modsecurity on;
  modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;

  location / {
    include /etc/nginx/conf.d/proxy_common.conf;
    proxy_pass http://app1_backend;
  }
}
```

4. Restart WAF container (or rely on reload watcher if certs already exist):

```bash
podman compose restart waf
```

### 5.2 HTTPS + manual certificates (Let’s Encrypt disabled)

* Set:

```env
ENABLE_HTTPS=1
ENABLE_LETSENCRYPT=0
```

* You must mount your certs and reference them in your own 443 `server {}` blocks.

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

* Two `server {}` blocks on port 80 with `server_name _;`.

Fix:

* Give your real site a specific name like `server_name localhost;` or your domain.

### 7.2 Requests return 404 from Nginx

Cause:

* You are hitting the default server generated by entrypoint.

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

## Appendix A: Minimal files to keep in your repo

* `Containerfile`
* `entrypoint.sh`
* `nginx.conf`
* `conf.d/maps.conf`
* `conf.d/proxy_common.conf`
* `conf.d/upstreams.conf` (placeholder)

Runtime-managed:

* `./conf.d/upstreams.conf` (real upstreams)
* `./sites-enabled/*.conf` (all servers)

---

## Appendix B: Minimal `sites-enabled` server for localhost testing

```nginx
server {
  listen 80;
  server_name localhost;

  modsecurity on;
  modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;

  location /app1/ {
    include /etc/nginx/conf.d/proxy_common.conf;
    proxy_pass http://app1_backend/;
  }
}
```

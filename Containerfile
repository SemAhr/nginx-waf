ARG NGINX_VERSION=1.28.2
ARG MODSECURITY_VERSION=v3.0.14
ARG MODSECURITY_NGINX_VERSION=v1.0.4
ARG HEADERS_MORE_VERSION=v0.39
ARG OWASP_CRS_VERSION=v4.23.0

FROM alpine:3.20 AS build

ARG NGINX_VERSION
ARG MODSECURITY_VERSION
ARG MODSECURITY_NGINX_VERSION
ARG HEADERS_MORE_VERSION

RUN apk add --no-cache \
    build-base linux-headers git ca-certificates curl cmake automake autoconf libtool pkgconfig \
    pcre-dev pcre2-dev zlib-dev openssl-dev yajl-dev lmdb-dev curl-dev libxml2-dev libxslt-dev

WORKDIR /src

# --- ModSecurity (libmodsecurity) ---
RUN set -eux; \
    git config --global http.version HTTP/1.1; \
    git config --global http.postBuffer 524288000; \
    git config --global submodule.fetchJobs 4; \
    \
    for attempt in 1 2 3 4 5; do \
    rm -rf /src/ModSecurity; \
    if git -c http.lowSpeedLimit=0 -c http.lowSpeedTime=999999 \
    clone --depth 1 --branch "${MODSECURITY_VERSION}" \
    --recurse-submodules --shallow-submodules \
    https://github.com/owasp-modsecurity/ModSecurity.git /src/ModSecurity; then \
    break; \
    fi; \
    echo "ModSecurity clone failed (attempt $attempt). Retrying..." >&2; \
    sleep $((attempt * 3)); \
    done; \
    \
    cd /src/ModSecurity; \
    ./build.sh; \
    ./configure; \
    make -j"$(nproc)"; \
    make install

# Export: libmodsecurity runtime libs (robust)
RUN set -eux; \
    mkdir -p /out/lib; \
    lib_path="$(find /usr/local -type f -name 'libmodsecurity.so*' 2>/dev/null | sort | head -n 1)"; \
    if [ -z "$lib_path" ]; then \
    echo "libmodsecurity.so not found under /usr/local"; \
    find /usr/local -maxdepth 4 -type f -name '*modsecurity*' -print; \
    exit 1; \
    fi; \
    cp -av "$(dirname "$lib_path")"/libmodsecurity.so* /out/lib/

# Export: recommended config renamed + unicode.mapping + CRS include lines
RUN set -eux; \
    mkdir -p /out/modsec; \
    cp -av /src/ModSecurity/modsecurity.conf-recommended /out/modsec/modsecurity.conf; \
    \
    # unicode.mapping usually exists in the repo root; do not assume make install copies it anywhere
    if [ -f /src/ModSecurity/unicode.mapping ]; then \
    cp -av /src/ModSecurity/unicode.mapping /out/modsec/unicode.mapping; \
    else \
    unicode_path="$(find /src/ModSecurity -type f -name 'unicode.mapping' 2>/dev/null | head -n 1)"; \
    if [ -z "$unicode_path" ]; then \
    echo "unicode.mapping not found in ModSecurity source tree"; \
    exit 1; \
    fi; \
    cp -av "$unicode_path" /out/modsec/unicode.mapping; \
    fi; \
    \
    sed -i 's/^SecRuleEngine .*/SecRuleEngine DetectionOnly/' /out/modsec/modsecurity.conf; \
    \
    if grep -q '^SecUnicodeMapFile' /out/modsec/modsecurity.conf; then \
    sed -i 's|^SecUnicodeMapFile .*|SecUnicodeMapFile /etc/nginx/modsec/unicode.mapping 20127|' /out/modsec/modsecurity.conf; \
    else \
    printf '\nSecUnicodeMapFile /etc/nginx/modsec/unicode.mapping 20127\n' >> /out/modsec/modsecurity.conf; \
    fi; \
    \
    printf '\n# ---- OWASP Core Rule Set (CRS) ----\n' >> /out/modsec/modsecurity.conf; \
    printf 'Include /etc/nginx/modsec/owasp-crs/crs-setup.conf\n' >> /out/modsec/modsecurity.conf; \
    printf 'Include /etc/nginx/modsec/owasp-crs/rules/*.conf\n' >> /out/modsec/modsecurity.conf

# --- Nginx connector for ModSecurity ---
RUN git clone https://github.com/owasp-modsecurity/ModSecurity-nginx.git /src/ModSecurity-nginx \
    && cd /src/ModSecurity-nginx \
    && git checkout "${MODSECURITY_NGINX_VERSION}"

# --- headers-more ---
RUN git clone https://github.com/openresty/headers-more-nginx-module.git /src/headers-more-nginx-module \
    && cd /src/headers-more-nginx-module \
    && git checkout "${HEADERS_MORE_VERSION}"

# --- nginx source ---
RUN curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o /src/nginx.tar.gz \
    && tar -xzf /src/nginx.tar.gz -C /src \
    && rm -f /src/nginx.tar.gz

WORKDIR /src/nginx-${NGINX_VERSION}

RUN ./configure \
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/etc/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/run/nginx.pid \
    --lock-path=/run/nginx.lock \
    --with-compat \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_stub_status_module \
    --with-http_gzip_static_module \
    --with-pcre-jit \
    --add-dynamic-module=/src/ModSecurity-nginx \
    --add-dynamic-module=/src/headers-more-nginx-module \
    && make -j"$(nproc)" \
    && make install

FROM alpine:3.20 AS runtime

ARG OWASP_CRS_VERSION

RUN apk add --no-cache \
    ca-certificates \
    libstdc++ \
    pcre pcre2 yajl lmdb curl libxml2 libxslt openssl zlib \
    inotify-tools

RUN set -eux; \
    if ! getent group www-data >/dev/null 2>&1; then addgroup -S www-data; fi; \
    if ! getent passwd www-data >/dev/null 2>&1; then adduser -S -D -H -s /sbin/nologin -G www-data www-data; fi

COPY --from=build /usr/sbin/nginx /usr/sbin/nginx
COPY --from=build /etc/nginx/ /etc/nginx/

# libmodsecurity runtime libs
RUN mkdir -p /usr/local/lib
COPY --from=build /out/lib/ /usr/local/lib/
ENV LD_LIBRARY_PATH=/usr/local/lib

# modsec base files
RUN mkdir -p /etc/nginx/modsec
COPY --from=build /out/modsec/ /etc/nginx/modsec/

# CRS
RUN curl -fsSL \
    "https://github.com/coreruleset/coreruleset/archive/refs/tags/${OWASP_CRS_VERSION}.tar.gz" \
    -o /tmp/crs.tar.gz \
    && mkdir -p /etc/nginx/modsec/owasp-crs \
    && tar -xzf /tmp/crs.tar.gz -C /etc/nginx/modsec/owasp-crs --strip-components=1 \
    && rm -f /tmp/crs.tar.gz \
    && cp /etc/nginx/modsec/owasp-crs/crs-setup.conf.example /etc/nginx/modsec/owasp-crs/crs-setup.conf

# Required folder layout
RUN mkdir -p \
    /etc/nginx/conf.d \
    /etc/nginx/sites-enabled \
    /var/www/_letsencrypt \
    /var/cache/nginx \
    /var/log/nginx \
    /run \
    && chown -R www-data:www-data /var/cache/nginx /var/log/nginx /var/www/_letsencrypt

# Minimal config files
COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d/maps.conf /etc/nginx/conf.d/maps.conf
COPY conf.d/proxy_common.conf /etc/nginx/conf.d/proxy_common.conf
COPY conf.d/upstreams.conf /etc/nginx/conf.d/upstreams.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80 443
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]

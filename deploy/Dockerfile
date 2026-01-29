# syntax=docker/dockerfile:1

# 1) Source restic binary (pinned tag)
ARG RESTIC_IMAGE=restic/restic:0.18.1
ARG ALPINE_IMAGE=alpine:3.23.3
FROM ${RESTIC_IMAGE} AS restic

# 2) Builder: install tools and assemble a minimal /out tree
FROM ${ALPINE_IMAGE} AS builder

RUN apk add --no-cache \
    ca-certificates \
    gzip \
    mariadb-client \
    mariadb-connector-c

# Copy restic binary into builder FS
COPY --from=restic /usr/bin/restic /usr/local/bin/restic

# Copy only the script we need (explicit COPY; no "COPY . .")
COPY backup.sh /usr/local/bin/backup

RUN set -eux; \
    mkdir -p /out; \
    \
    copy_one() { \
    src="$1"; \
    dest="/out$src"; \
    mkdir -p "$(dirname "$dest")"; \
    cp -a "$src" "$dest"; \
    if [ -L "$src" ]; then \
    target="$(readlink -f "$src")"; \
    if [ -n "$target" ] && [ "$target" != "$src" ] && [ -e "$target" ]; then \
    copy_one "$target"; \
    fi; \
    fi; \
    }; \
    \
    copy_deps() { \
    target="$1"; \
    ldd "$target" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' \
    | sort -u \
    | while read -r lib; do \
    [ -e "$lib" ] || continue; \
    copy_one "$lib"; \
    done; \
    }; \
    \
    targets="\
    /usr/local/bin/restic \
    /usr/local/bin/backup \
    /usr/bin/mysqladmin \
    /usr/bin/mysqldump \
    /bin/gzip \
    /bin/busybox \
    /usr/lib/mariadb/plugin/caching_sha2_password.so \
    /etc/ssl/certs/ca-certificates.crt \
    "; \
    \
    for t in $targets; do \
    [ -e "$t" ] || { echo "Missing runtime file: $t" >&2; exit 1; }; \
    copy_one "$t"; \
    case "$t" in \
    *.so*|/usr/*bin/*|/bin/gzip|/bin/busybox) copy_deps "$t" ;; \
    esac; \
    done; \
    \
    /bin/busybox --install -s /out/bin; \
    \
    chmod 0755 \
    /out/usr/local/bin/restic \
    /out/usr/local/bin/backup \
    /out/usr/bin/mysqladmin \
    /out/usr/bin/mysqldump \
    /out/bin/gzip \
    /out/bin/busybox; \
    \
    mkdir -p /out/etc /out/tmp; \
    chmod 1777 /out/tmp; \
    { \
    echo 'root:x:0:0:root:/root:/bin/sh'; \
    echo 'backup:x:10001:10001:backup:/nonexistent:/sbin/nologin'; \
    } > /out/etc/passwd; \
    { \
    echo 'root:x:0:'; \
    echo 'backup:x:10001:'; \
    } > /out/etc/group

# 3) Runtime: extremely minimal
FROM scratch
COPY --from=builder /out/ /

ENV TZ=UTC \
    PATH=/usr/local/bin:/usr/bin:/bin \
    RESTIC_CACHE_DIR=/tmp/restic-cache

USER 10001:10001

ENTRYPOINT ["/usr/local/bin/backup"]

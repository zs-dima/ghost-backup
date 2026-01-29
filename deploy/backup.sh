#!/bin/sh
set -eu
(set -o pipefail) 2>/dev/null && set -o pipefail || true

umask 077
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { log "ERROR: $*"; exit 1; }
SCRIPT_VERSION="2026-01-29"
log "backup.sh version ${SCRIPT_VERSION}"

file_env() {
  var="$1"
  file_var="${var}_FILE"
  preserve_newlines="${2:-false}"
  eval val=\${$var:-}
  eval file=\${$file_var:-}

  if [ -n "${file:-}" ]; then
    [ -f "$file" ] || die "$file_var points to missing file: $file"
    if [ "${preserve_newlines}" = "true" ]; then
      val="$(cat "$file")"
    else
      val="$(tr -d '\r\n' < "$file")"
    fi
  fi

  [ -n "${val:-}" ] && eval export "$var=\$val"
}

# --- Restic config ---
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required (e.g. s3:https://HOST/BUCKET/PREFIX)}"
file_env RESTIC_PASSWORD
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD or RESTIC_PASSWORD_FILE is required}"

# AWS creds can be via AWS_SHARED_CREDENTIALS_FILE (recommended) or env.
# We don’t force them here because some environments use IAM roles or env injection.
file_env S3_ACCESS_KEY
file_env S3_SECRET_KEY
file_env S3_SESSION_TOKEN
if [ -n "${S3_ACCESS_KEY:-}" ] || [ -n "${S3_SECRET_KEY:-}" ] || [ -n "${S3_SESSION_TOKEN:-}" ]; then
  [ -n "${S3_ACCESS_KEY:-}" ] || die "S3_ACCESS_KEY or S3_ACCESS_KEY_FILE is required when S3_SECRET_KEY is set"
  [ -n "${S3_SECRET_KEY:-}" ] || die "S3_SECRET_KEY or S3_SECRET_KEY_FILE is required when S3_ACCESS_KEY is set"
  export AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}"
  export AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}"
  if [ -n "${S3_SESSION_TOKEN:-}" ]; then
    export AWS_SESSION_TOKEN="${S3_SESSION_TOKEN}"
  fi
fi

# --- MySQL config ---
: "${MYSQL_HOST:?MYSQL_HOST is required}"
: "${MYSQL_USER:?MYSQL_USER is required}"
: "${MYSQL_DATABASE:?MYSQL_DATABASE is required}"
MYSQL_PORT="${MYSQL_PORT:-3306}"

file_env MYSQL_PASSWORD
if [ -n "${MYSQL_PASSWORD:-}" ]; then
  export MYSQL_PWD="${MYSQL_PASSWORD}"
  unset MYSQL_PASSWORD
fi

# Plugin dir for MySQL 8 default auth (caching_sha2_password)
MYSQL_PLUGIN_DIR="${MYSQL_PLUGIN_DIR:-/usr/lib/mariadb/plugin}"
MYSQL_CLIENT_EXTRA_ARGS="${MYSQL_CLIENT_EXTRA_ARGS:-}"

MYSQL_COMMON_ARGS="--protocol=tcp -h ${MYSQL_HOST} -P ${MYSQL_PORT} -u ${MYSQL_USER} --plugin-dir=${MYSQL_PLUGIN_DIR} ${MYSQL_CLIENT_EXTRA_ARGS}"

# Wait for MySQL
WAIT_SECONDS="${MYSQL_WAIT_SECONDS:-60}"
SLEEP_SECONDS="${MYSQL_WAIT_INTERVAL_SECONDS:-5}"
tries=$(( (WAIT_SECONDS + SLEEP_SECONDS - 1) / SLEEP_SECONDS ))

log "Waiting for MySQL at ${MYSQL_HOST}:${MYSQL_PORT} (max ${WAIT_SECONDS}s)..."
i=0
while :; do
  i=$((i + 1))
  if mysqladmin ${MYSQL_COMMON_ARGS} ping --silent >/dev/null 2>&1; then
    log "MySQL is ready"
    break
  fi
  [ "$i" -ge "$tries" ] && die "MySQL not ready after ${WAIT_SECONDS}s"
  sleep "${SLEEP_SECONDS}"
done

# Safe defaults for InnoDB logical backups; override if needed
MYSQLDUMP_ARGS="${MYSQLDUMP_ARGS:-"--single-transaction --quick --routines --events --triggers --set-gtid-purged=OFF"}"

RESTIC_EXTRA_ARGS="${RESTIC_EXTRA_ARGS:-"--no-cache"}"

# Init repo if needed
if [ "${SKIP_INIT:-false}" != "true" ]; then
  if restic cat config >/dev/null 2>&1; then
    log "Restic repository exists"
  else
    log "Initializing restic repository..."
    restic init
  fi
fi

TAG_ARGS=""
if [ -n "${RESTIC_TAGS:-}" ]; then
  oldIFS="$IFS"
  IFS=','
  for t in ${RESTIC_TAGS}; do
    tt="$(echo "$t" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$tt" ] && TAG_ARGS="${TAG_ARGS} --tag ${tt}"
  done
  IFS="$oldIFS"
fi
TAG_ARGS="${TAG_ARGS} --tag db:${MYSQL_DATABASE}"

file_env BACKUP_PATHS true
RESTIC_HOST="${RESTIC_HOSTNAME:-$(hostname)}"
BACKUP_PATHS="${BACKUP_PATHS:-}"
RESTIC_ONE_FILE_SYSTEM="${RESTIC_ONE_FILE_SYSTEM:-false}"

ONE_FS_ARGS=""
if [ "${RESTIC_ONE_FILE_SYSTEM}" = "true" ]; then
  ONE_FS_ARGS="--one-file-system"
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP_NAME="${MYSQL_DATABASE}-${STAMP}.sql.gz"

log "Streaming database '${MYSQL_DATABASE}' to restic..."
# shellcheck disable=SC2086
mysqldump ${MYSQL_COMMON_ARGS} ${MYSQLDUMP_ARGS} \
  --databases "${MYSQL_DATABASE}" \
  2>/dev/null \
  | gzip -n -9 \
  | restic backup \
    --stdin \
    --stdin-filename "${DUMP_NAME}" \
    --host "${RESTIC_HOST}" \
    ${ONE_FS_ARGS} \
    ${TAG_ARGS} \
    ${RESTIC_EXTRA_ARGS} \
    -- \
  || die "restic backup (db) failed"

set --
if [ -n "${BACKUP_PATHS}" ]; then
  BACKUP_PATHS_NORMALIZED="$(printf '%s' "${BACKUP_PATHS}" | tr ',' '\n')"
  oldIFS="$IFS"
  IFS='
'
  for p in ${BACKUP_PATHS_NORMALIZED}; do
    pp="$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$pp" ] || continue
    [ -e "$pp" ] || die "Backup path missing: $pp"
    set -- "$@" "$pp"
  done
  IFS="$oldIFS"
fi

if [ "$#" -gt 0 ]; then
  log "Running restic backup for paths (host=${RESTIC_HOST})..."
  # shellcheck disable=SC2086
  restic backup \
    --host "${RESTIC_HOST}" \
    ${ONE_FS_ARGS} \
    ${TAG_ARGS} \
    ${RESTIC_EXTRA_ARGS} \
    -- "$@"
else
  log "No extra backup paths configured."
fi

if [ "${SKIP_FORGET:-false}" != "true" ]; then
  RESTIC_FORGET_ARGS="${RESTIC_FORGET_ARGS:-"--prune --keep-last 7 --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --group-by tags"}"
  log "Retention: restic forget ${RESTIC_FORGET_ARGS}"
  # shellcheck disable=SC2086
  restic forget ${RESTIC_FORGET_ARGS}
fi

if [ "${SKIP_CHECK:-false}" != "true" ] && [ -n "${RESTIC_CHECK_READ_DATA_SUBSET:-}" ]; then
  log "restic check --read-data-subset=${RESTIC_CHECK_READ_DATA_SUBSET}"
  restic check --read-data-subset="${RESTIC_CHECK_READ_DATA_SUBSET}"
fi

log "Backup completed."

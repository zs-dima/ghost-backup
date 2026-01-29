#!/bin/sh
set -eu

umask 077
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { log "ERROR: $*"; exit 1; }

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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" >/dev/null 2>&1 || true' EXIT INT TERM

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP_SQL="${tmpdir}/${MYSQL_DATABASE}-${STAMP}.sql"
DUMP_GZ="${DUMP_SQL}.gz"

# Safe defaults for InnoDB logical backups; override if needed
MYSQLDUMP_ARGS="${MYSQLDUMP_ARGS:-"--single-transaction --quick --routines --events --triggers --set-gtid-purged=OFF"}"

log "Dumping database '${MYSQL_DATABASE}'..."
# Avoid piping to restic stdin to prevent “restic waits forever” failure mode.
# shellcheck disable=SC2086
mysqldump ${MYSQL_COMMON_ARGS} ${MYSQLDUMP_ARGS} \
  --databases "${MYSQL_DATABASE}" \
  --result-file="${DUMP_SQL}" \
  >/dev/null 2>&1 || die "mysqldump failed (auth/plugin/permissions?)"

# gzip -n makes output more deterministic (better dedup) and avoids storing timestamps in gzip header
gzip -n -9 "${DUMP_SQL}" || die "gzip failed"
log "DB dump ready: ${DUMP_GZ}"

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
RESTIC_EXTRA_ARGS="${RESTIC_EXTRA_ARGS:-}"

set -- "${DUMP_GZ}"
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

ONE_FS_ARGS=""
if [ "${RESTIC_ONE_FILE_SYSTEM}" = "true" ]; then
  ONE_FS_ARGS="--one-file-system"
fi

log "Running restic backup (host=${RESTIC_HOST})..."
# shellcheck disable=SC2086
restic backup \
  --host "${RESTIC_HOST}" \
  ${ONE_FS_ARGS} \
  ${TAG_ARGS} \
  ${RESTIC_EXTRA_ARGS} \
  -- "$@"

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

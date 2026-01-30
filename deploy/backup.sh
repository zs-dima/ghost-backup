#!/bin/sh
set -eu

umask 077
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
else
  die "This script requires /bin/sh with pipefail support"
fi

# Newline-only IFS helper.
NL="$(printf '\nX')"
NL="${NL%X}"

require_cmd() {
  req_cmd="$1"
  command -v "$req_cmd" >/dev/null 2>&1 || die "Required command not found: $req_cmd"
}

is_positive_int() {
  int_value="$1"
  case "$int_value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$int_value" -gt 0 ] 2>/dev/null
}

SCRIPT_VERSION="2026-01-29.5"
log "backup.sh version ${SCRIPT_VERSION}"

file_env() {
  fe_var="$1"
  fe_file_var="${fe_var}_FILE"
  fe_preserve_newlines="${2:-false}"
  fe_val=""
  fe_file=""

  case "$fe_var" in
    RESTIC_PASSWORD)
      fe_val="${RESTIC_PASSWORD:-}"
      fe_file="${RESTIC_PASSWORD_FILE:-}"
      ;;
    S3_ACCESS_KEY)
      fe_val="${S3_ACCESS_KEY:-}"
      fe_file="${S3_ACCESS_KEY_FILE:-}"
      ;;
    S3_SECRET_KEY)
      fe_val="${S3_SECRET_KEY:-}"
      fe_file="${S3_SECRET_KEY_FILE:-}"
      ;;
    S3_SESSION_TOKEN)
      fe_val="${S3_SESSION_TOKEN:-}"
      fe_file="${S3_SESSION_TOKEN_FILE:-}"
      ;;
    MYSQL_PASSWORD)
      fe_val="${MYSQL_PASSWORD:-}"
      fe_file="${MYSQL_PASSWORD_FILE:-}"
      ;;
    BACKUP_PATHS)
      fe_val="${BACKUP_PATHS:-}"
      fe_file="${BACKUP_PATHS_FILE:-}"
      ;;
    *)
      die "file_env: unsupported variable '${fe_var}'"
      ;;
  esac

  if [ -n "${fe_val}" ] && [ -n "${fe_file}" ]; then
    die "${fe_var} and ${fe_file_var} are both set (use only one)"
  fi

  if [ -n "${fe_file}" ]; then
    [ -f "$fe_file" ] || die "$fe_file_var points to missing file: $fe_file"
    if [ "${fe_preserve_newlines}" = "true" ]; then
      fe_val="$(cat "$fe_file")"
    else
      fe_val="$(tr -d '\r\n' < "$fe_file")"
    fi
  fi

  if [ -n "${fe_val}" ]; then
    export "${fe_var}=${fe_val}"
  fi
}

# --- Restic config ---
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required (e.g. s3:https://HOST/BUCKET/PREFIX)}"
file_env RESTIC_PASSWORD
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD or RESTIC_PASSWORD_FILE is required}"

# Temp dir: restic needs writable temp for pack files.
TMPDIR="${TMPDIR:-/tmp}"
if [ ! -d "${TMPDIR}" ]; then
  mkdir -p "${TMPDIR}" 2>/dev/null || die "TMPDIR is not usable: ${TMPDIR}"
fi
[ -w "${TMPDIR}" ] || die "TMPDIR is not writable: ${TMPDIR}"
export TMPDIR

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
MYSQL_PASSWORD_VALUE=""
if [ -n "${MYSQL_PASSWORD:-}" ]; then
  MYSQL_PASSWORD_VALUE="${MYSQL_PASSWORD}"
  unset MYSQL_PASSWORD
fi

# Plugin dir for MySQL 8 default auth (caching_sha2_password)
if [ -z "${MYSQL_PLUGIN_DIR+x}" ]; then
  MYSQL_PLUGIN_DIR="/usr/lib/mariadb/plugin"
fi
MYSQL_PLUGIN_ARG=""
if [ -n "${MYSQL_PLUGIN_DIR}" ]; then
  if [ -d "${MYSQL_PLUGIN_DIR}" ]; then
    MYSQL_PLUGIN_ARG="--plugin-dir=${MYSQL_PLUGIN_DIR}"
  else
    log "WARN: MySQL plugin dir '${MYSQL_PLUGIN_DIR}' not found; skipping --plugin-dir"
  fi
fi
MYSQL_CLIENT_EXTRA_ARGS="${MYSQL_CLIENT_EXTRA_ARGS:-}"

require_cmd restic
require_cmd gzip
require_cmd mkfifo

# Prefer mariadb-admin for modern MariaDB clients.
MYSQLADMIN_BIN="${MYSQLADMIN_BIN:-}"
if [ -z "${MYSQLADMIN_BIN}" ]; then
  MYSQLADMIN_BIN="$(command -v mariadb-admin 2>/dev/null || true)"
fi
[ -n "${MYSQLADMIN_BIN}" ] && [ -x "${MYSQLADMIN_BIN}" ] || die "mariadb-admin binary not found (set MYSQLADMIN_BIN to an absolute path)"

build_user_tag_list() {
  RESTIC_USER_TAG_LIST=""
  if [ -z "${RESTIC_TAGS:-}" ]; then
    return 0
  fi

  tag_seen="$NL"
  oldIFS=$IFS
  IFS=','
  set -f
  # shellcheck disable=SC2086
  set -- ${RESTIC_TAGS}
  set +f
  IFS=$oldIFS

  for t in "$@"; do
    tag_trimmed="$(printf '%s\n' "$t" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$tag_trimmed" ] || continue
    case "$tag_seen" in
      *"$NL$tag_trimmed$NL"*) ;;
      *)
        tag_seen="${tag_seen}${tag_trimmed}${NL}"
        if [ -n "$RESTIC_USER_TAG_LIST" ]; then
          RESTIC_USER_TAG_LIST="${RESTIC_USER_TAG_LIST}${NL}${tag_trimmed}"
        else
          RESTIC_USER_TAG_LIST="$tag_trimmed"
        fi
        ;;
    esac
  done
}

restic_backup_stdin() {
  set -- --stdin --stdin-filename "${DUMP_NAME}" --host "${RESTIC_HOST}"

  if [ "${RESTIC_ONE_FILE_SYSTEM}" = "true" ]; then
    set -- "$@" --one-file-system
  fi

  build_user_tag_list
  if [ -n "${RESTIC_USER_TAG_LIST}" ]; then
    oldIFS=$IFS
    IFS=$NL
    set -f
    for tag in $RESTIC_USER_TAG_LIST; do
      set -- "$@" --tag "$tag"
    done
    set +f
    IFS=$oldIFS
  fi
  set -- "$@" --tag "db:${MYSQL_DATABASE}"

  if [ -n "${RESTIC_EXTRA_ARGS:-}" ]; then
    set -f
    # shellcheck disable=SC2086
    set -- "$@" ${RESTIC_EXTRA_ARGS}
    set +f
  else
    set -- "$@" --no-cache
  fi

  set -- "$@" --
  restic backup "$@"
}

restic_backup_paths() {
  # $@ are paths to back up
  set -- -- "$@"

  if [ -n "${RESTIC_EXTRA_ARGS:-}" ]; then
    set -f
    # shellcheck disable=SC2086
    set -- ${RESTIC_EXTRA_ARGS} "$@"
    set +f
  else
    set -- --no-cache "$@"
  fi

  build_user_tag_list
  if [ -n "${RESTIC_USER_TAG_LIST}" ]; then
    oldIFS=$IFS
    IFS=$NL
    set -f
    for tag in $RESTIC_USER_TAG_LIST; do
      set -- --tag "$tag" "$@"
    done
    set +f
    IFS=$oldIFS
  fi
  set -- --tag "db:${MYSQL_DATABASE}" "$@"

  if [ "${RESTIC_ONE_FILE_SYSTEM}" = "true" ]; then
    set -- --one-file-system "$@"
  fi

  set -- --host "${RESTIC_HOST}" "$@"
  restic backup "$@"
}

restic_forget() {
  set -- --host "${RESTIC_HOST}" --tag "db:${MYSQL_DATABASE}"
  if [ -n "${RESTIC_FORGET_ARGS:-}" ]; then
    set -f
    # shellcheck disable=SC2086
    set -- "$@" ${RESTIC_FORGET_ARGS}
    set +f
  else
    set -- "$@" --prune --keep-last 7 --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --group-by tags
  fi

  log "Retention: restic forget $*"
  restic forget "$@"
}

mysqladmin_ping() {
  set -- --protocol=tcp -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}"
  if [ -n "${MYSQL_PLUGIN_ARG}" ]; then
    set -- "$@" "${MYSQL_PLUGIN_ARG}"
  fi
  if [ -n "${MYSQL_CLIENT_EXTRA_ARGS}" ]; then
    set -f
    # shellcheck disable=SC2086
    set -- "$@" ${MYSQL_CLIENT_EXTRA_ARGS}
    set +f
  fi

  if [ -n "${MYSQL_PASSWORD_VALUE}" ]; then
    MYSQL_PWD="${MYSQL_PASSWORD_VALUE}" "${MYSQLADMIN_BIN}" "$@" ping --silent >/dev/null 2>&1
  else
    "${MYSQLADMIN_BIN}" "$@" ping --silent >/dev/null 2>&1
  fi
}

run_mysqldump() {
  set -- --protocol=tcp -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}"
  if [ -n "${MYSQL_PLUGIN_ARG}" ]; then
    set -- "$@" "${MYSQL_PLUGIN_ARG}"
  fi
  if [ -n "${MYSQL_CLIENT_EXTRA_ARGS}" ]; then
    set -f
    # shellcheck disable=SC2086
    set -- "$@" ${MYSQL_CLIENT_EXTRA_ARGS}
    set +f
  fi
  if [ -n "${MYSQLDUMP_ARGS:-}" ]; then
    set -f
    # shellcheck disable=SC2086
    set -- "$@" ${MYSQLDUMP_ARGS}
    set +f
  else
    set -- "$@" --single-transaction --quick --routines --events --triggers --no-tablespaces
  fi

  if [ -n "${MYSQL_PASSWORD_VALUE}" ]; then
    MYSQL_PWD="${MYSQL_PASSWORD_VALUE}" "${MYSQLDUMP_BIN}" "$@" --databases "${MYSQL_DATABASE}"
  else
    "${MYSQLDUMP_BIN}" "$@" --databases "${MYSQL_DATABASE}"
  fi
}

# Wait for MySQL
WAIT_SECONDS="${MYSQL_WAIT_SECONDS:-60}"
SLEEP_SECONDS="${MYSQL_WAIT_INTERVAL_SECONDS:-5}"
is_positive_int "${WAIT_SECONDS}" || die "MYSQL_WAIT_SECONDS must be a positive integer"
is_positive_int "${SLEEP_SECONDS}" || die "MYSQL_WAIT_INTERVAL_SECONDS must be a positive integer"
tries=$(( (WAIT_SECONDS + SLEEP_SECONDS - 1) / SLEEP_SECONDS ))

log "Waiting for MySQL at ${MYSQL_HOST}:${MYSQL_PORT} (max ${WAIT_SECONDS}s)..."
i=0
while :; do
  i=$((i + 1))
  if mysqladmin_ping; then
    log "MySQL is ready"
    break
  fi
  [ "$i" -ge "$tries" ] && die "MySQL not ready after ${WAIT_SECONDS}s"
  sleep "${SLEEP_SECONDS}"
done

# Dump binary (mariadb-dump or mysqldump)
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-}"
if [ -z "${MYSQLDUMP_BIN}" ]; then
  MYSQLDUMP_BIN="$(command -v mariadb-dump 2>/dev/null || true)"
  if [ -z "${MYSQLDUMP_BIN}" ]; then
    MYSQLDUMP_BIN="$(command -v mysqldump 2>/dev/null || true)"
  fi
fi
[ -n "${MYSQLDUMP_BIN}" ] && [ -x "${MYSQLDUMP_BIN}" ] || die "mysqldump binary not found (set MYSQLDUMP_BIN to an absolute path)"

# Safe defaults for logical backups; override if needed
# --no-tablespaces avoids PROCESS privilege requirement in MySQL 8 / MariaDB.
MYSQLDUMP_ARGS="${MYSQLDUMP_ARGS:-}"

# Init repo if needed
if [ "${SKIP_INIT:-false}" != "true" ]; then
  if restic cat config >/dev/null 2>&1; then
    log "Restic repository exists"
  else
    log "Initializing restic repository..."
    restic init
  fi
fi

file_env BACKUP_PATHS true
RESTIC_HOST="${RESTIC_HOST:-${RESTIC_HOSTNAME:-${HOSTNAME:-}}}"
if [ -z "${RESTIC_HOST}" ]; then
  if command -v hostname >/dev/null 2>&1; then
    RESTIC_HOST="$(hostname 2>/dev/null || true)"
  fi
fi
[ -n "${RESTIC_HOST}" ] || die "RESTIC_HOSTNAME, RESTIC_HOST, or HOSTNAME is required (unable to determine host)"
BACKUP_PATHS="${BACKUP_PATHS:-}"
RESTIC_ONE_FILE_SYSTEM="${RESTIC_ONE_FILE_SYSTEM:-false}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP_NAME="${MYSQL_DATABASE}-${STAMP}.sql.gz"

log "Streaming database '${MYSQL_DATABASE}' to restic..."
fifo="${TMPDIR}/mysqldump-$$.fifo"
cleanup_fifo() { rm -f "${fifo}" >/dev/null 2>&1 || true; }
cleanup_fifo
mkfifo "${fifo}" || die "mkfifo failed in ${TMPDIR}"
trap 'cleanup_fifo' EXIT INT TERM

run_mysqldump >"${fifo}" &
dump_pid=$!

gzip -n -9 < "${fifo}" | restic_backup_stdin || restic_status=$?
restic_status="${restic_status:-0}"

if wait "${dump_pid}"; then
  dump_status=0
else
  dump_status=$?
fi
cleanup_fifo
trap - EXIT INT TERM

[ "${dump_status}" -eq 0 ] || die "mysqldump failed (exit ${dump_status})"
[ "${restic_status}" -eq 0 ] || die "restic backup (db) failed (exit ${restic_status})"

set --
if [ -n "${BACKUP_PATHS}" ]; then
  BACKUP_PATHS_NORMALIZED="$(printf '%s' "${BACKUP_PATHS}" | tr ',' '\n')"
  oldIFS=$IFS
  IFS=$NL
  set -f
  for p in $BACKUP_PATHS_NORMALIZED; do
    pp="$(printf '%s\n' "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$pp" ] || continue
    [ -e "$pp" ] || die "Backup path missing: $pp"
    set -- "$@" "$pp"
  done
  set +f
  IFS=$oldIFS
fi

if [ "$#" -gt 0 ]; then
  log "Running restic backup for paths (host=${RESTIC_HOST})..."
  restic_backup_paths "$@"
else
  log "No extra backup paths configured."
fi

if [ "${SKIP_FORGET:-false}" != "true" ]; then
  restic_forget
fi

if [ "${SKIP_CHECK:-false}" != "true" ] && [ -n "${RESTIC_CHECK_READ_DATA_SUBSET:-}" ]; then
  log "restic check --read-data-subset=${RESTIC_CHECK_READ_DATA_SUBSET}"
  restic check --read-data-subset="${RESTIC_CHECK_READ_DATA_SUBSET}"
fi

log "Backup completed."

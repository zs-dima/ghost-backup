# MySQL Restic Backup

Containerized, one-shot backup job that runs `mysqldump`, streams it through gzip to restic, optionally backs up extra paths, then exits.

## Build

```bash
docker build -f deploy/Dockerfile -t backup-mysql:local deploy
```

## Run (Docker)

```bash
docker run --rm --name mysql-backup \
  --tmpfs /tmp:mode=1777,size=256m \
  --network <mysql-network> \
  -e RESTIC_REPOSITORY='s3:https://HOST/BUCKET/PREFIX' \
  -e RESTIC_PASSWORD_FILE=/run/secrets/restic_password \
  -e MYSQL_HOST=<mysql-host> \
  -e MYSQL_USER=<mysql-user> \
  -e MYSQL_DATABASE=<mysql-db> \
  -e MYSQL_PASSWORD_FILE=/run/secrets/mysql_password \
  -v /path/to/restic_password:/run/secrets/restic_password:ro \
  -v /path/to/mysql_password:/run/secrets/mysql_password:ro \
  backup-mysql:local
```

Use `*_FILE` for secrets. Supported: `RESTIC_PASSWORD`, `MYSQL_PASSWORD`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_SESSION_TOKEN`, `BACKUP_PATHS`.

## Env vars

| Var | Required | Default | Description |
| --- | --- | --- | --- |
| `RESTIC_REPOSITORY` | yes | — | Restic repo URL (e.g. `s3:https://HOST/BUCKET/PREFIX`). |
| `RESTIC_PASSWORD` / `RESTIC_PASSWORD_FILE` | yes | — | Restic repository password (value or file). |
| `MYSQL_HOST` | yes | — | MySQL host to connect to. |
| `MYSQL_USER` | yes | — | MySQL user for dump. |
| `MYSQL_DATABASE` | yes | — | MySQL database name. |
| `RESTIC_HOSTNAME` / `RESTIC_HOST` | conditional | — | Backup host label; required if hostname can’t be determined. |
| `MYSQL_PORT` | no | `3306` | MySQL port. |
| `MYSQL_PASSWORD` / `MYSQL_PASSWORD_FILE` | no | — | MySQL password (value or file). |
| `MYSQL_WAIT_SECONDS` | no | `60` | Max time to wait for MySQL. |
| `MYSQL_WAIT_INTERVAL_SECONDS` | no | `5` | Wait interval between pings. |
| `MYSQL_PLUGIN_DIR` | no | `/usr/lib/mariadb/plugin` | MySQL auth plugin dir. |
| `MYSQL_CLIENT_EXTRA_ARGS` | no | — | Extra args for `mysqladmin`/client. |
| `MYSQLDUMP_BIN` | no | auto | Path to `mariadb-dump`/`mysqldump`. |
| `MYSQLDUMP_ARGS` | no | safe defaults | Extra args for dump command. |
| `TMPDIR` | no | `/tmp` | Temp dir for FIFO and restic. |
| `BACKUP_PATHS` / `BACKUP_PATHS_FILE` | no | — | Comma‑separated extra paths to back up. |
| `RESTIC_TAGS` | no | — | Comma‑separated user tags. |
| `RESTIC_EXTRA_ARGS` | no | — | Extra args for `restic backup`. |
| `RESTIC_ONE_FILE_SYSTEM` | no | `false` | Add `--one-file-system`. |
| `RESTIC_FORGET_ARGS` | no | defaults | Overrides retention policy. |
| `RESTIC_CHECK_READ_DATA_SUBSET` | no | — | Enable `restic check` with subset. |
| `SKIP_INIT` | no | `false` | Skip `restic init`. |
| `SKIP_FORGET` | no | `false` | Skip retention step. |
| `SKIP_CHECK` | no | `false` | Skip `restic check`. |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | no | — | S3 access key pair (both required if either set). |
| `S3_SESSION_TOKEN` | no | — | Optional session token. |

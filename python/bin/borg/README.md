# Python tool: borg

## backup.py

### Description
Create, prune and check borg backups from a YAML configuration.

One tool for every host:

- **Data paths** - plain directories (glob patterns supported), for config
  backups on bare-metal hosts and container-volume backups on docker hosts.
- **Container dumps** - `postgres` (pg_dumpall via docker exec), `sqlite`
  (online `.backup` against the volume path) and `stop` (quiesce a container
  around `borg create`).
- **Multiple repositories** - e.g. the local borg server (fast, onsite) plus
  the Hetzner Storage Box (offsite); per-repository `rsh`/`remote_path`
  overrides (the Storage Box serves borg over SSH port 23 and needs
  `remote_path: borg-1.2` for a borg 1.2 client).
- **Hooks** - pre/post shell commands (`sh -c`); a failing pre hook aborts.
- **Alerts** - gotify summary, pushgateway metrics (Prometheus staleness
  alerts) and a healthchecks.io dead man's switch.

It replaces `bash/bin/borg/backup.sh` (removed). Exit codes: `0` ok,
`1` warning (borg rc 1, metrics push failed), `2` failure.

### Usage
```bash
$ uv run backup.py --help
usage: backup.py [-h] [--prune | --check] [-c CONFIG] [--dry-run] [-v] [--version]

Create, prune and check borg backups from a YAML configuration

options:
  --prune           Prune archives instead of creating
  --check           Verify repository integrity (borg check)
  -c, --config CONFIG  Path to YAML configuration file
  --dry-run         Show what would run without executing
  -v, --verbose     Enable debug logging
```

Run from the repository checkout on a host:
```bash
cd /usr/local/git/ops-utils/python/bin/borg
uv run backup.py --config /usr/local/etc/backup-borg.yaml
```

### Cron (pattern used on the hosts)
```
20 4  * * * cd /usr/local/git/ops-utils/python/bin/borg && uv run backup.py --config /usr/local/etc/backup-borg.yaml > /dev/null 2>&1
20 5  1 * * cd /usr/local/git/ops-utils/python/bin/borg && uv run backup.py --config /usr/local/etc/backup-borg.yaml --prune > /dev/null 2>&1
40 6  1 * * cd /usr/local/git/ops-utils/python/bin/borg && uv run backup.py --config /usr/local/etc/backup-borg.yaml --check > /dev/null 2>&1
```

### Configuration
See `backup-borg-template.yaml`. The configuration lives on the host
(e.g. `/usr/local/etc/backup-borg.yaml`, mode 0600) because it contains the
repository passphrase, the gotify token and the healthchecks.io UUID - never
commit it.

### Migration from bash/bin/borg env files
| env file (old)             | YAML (new)                          |
|----------------------------|-------------------------------------|
| `BORG_REPO`                | `repositories` (list, multi-target) |
| `BORG_PASSPHRASE`          | `passphrase` / `passphrase_file`    |
| `BORG_DIR_LIST`            | `paths`                             |
| `BORG_PREFIX`              | `prefix`                            |
| `BORG_EXCLUDE`             | `exclude` (list)                    |
| `BORG_PRUNE_KEEP_*`        | `prune.keep_*`                      |
| `run_pre` / `run_post`     | `hooks.pre` / `hooks.post`          |

Note: the old script's prune `--glob-archives` pattern lacked the trailing
`*`, so prune never matched any archive - this tool fixes that.

### Metrics (pushgateway)
```
borg_backup_success                        0|1
borg_backup_last_success_timestamp_seconds  epoch (success runs only)
borg_backup_duration_seconds
borg_backup_repo_count / borg_backup_failed_repos
borg_check_success / borg_check_last_success_timestamp_seconds
```
`BackupNotRun` alert rules key on `time() - borg_backup_last_success_timestamp_seconds`
- because the timestamp is a metric *value*, the alert fires even when the
pushing host died hours ago (pushgateway metrics never expire).

### Restore runbook
```bash
export BORG_PASSPHRASE='...'
export BORG_REPO='ssh://borg@nas/<host>'        # or the Storage Box repo
borg list                                      # pick an archive
borg mount ::daily_<host>_<date>_<time> /mnt/restore
# ... or extract single files:
borg extract ::daily_<host>_<date>_<time> var/lib/docker/volumes/<vol> --sparse
umount /mnt/restore
```

Database dumps land in `<dumps.dir>/<container>_<timestamp>.sql.gz`. Restore
a postgres dump into a scratch container:

```bash
zcat infisical-postgres_20260917_0420.sql.gz | \
  docker exec -i infisical-postgres psql -U infisical
```

Vaultwarden: copy the `.sqlite` dump back over the volume's `db.sqlite3`
while the container is stopped.

If the repository key is lost, `borg key export` output and the passphrase
are required - store both **offline** (password manager on another device),
not only on the backed-up host itself.

### Log files
Monthly log files are written to `<log_dir>/borg_backup_<hostname>_<year-month>.log`
(default `~/local/log`).

### License
See repository license file.

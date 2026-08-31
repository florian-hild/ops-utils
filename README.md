# ops-utils

Small ops tools: bash libraries, bash scripts, and Python utilities.

## Bash scripts

| Script | Description |
|--------|-------------|
| [`bash/bin/borg/backup.sh`](bash/bin/borg/backup.sh) | Create and prune backups with borgbackup |
| [`bash/bin/docker/update.sh`](bash/bin/docker/update.sh) | Update docker containers from a compose file |
| [`bash/bin/docker/update-history.sh`](bash/bin/docker/update-history.sh) | Show docker update history log |
| [`bash/bin/opnsense/backup.sh`](bash/bin/opnsense/backup.sh) | Create OPNsense backup from config.xml |
| [`bash/bin/opnsense/backup-viewer.sh`](bash/bin/opnsense/backup-viewer.sh) | Decrypt and decompress OPNsense backup files for inspection |
| [`bash/bin/opnsense/check-gw-status.sh`](bash/bin/opnsense/check-gw-status.sh) | Check OPNsense gateway status and log failures |
| [`bash/bin/opnsense/show-check-gw-log.sh`](bash/bin/opnsense/show-check-gw-log.sh) | Show Check Gateway status logfile |

## Bash libraries

| Library | Description |
|---------|-------------|
| [`bash/lib/logger/lib`](bash/lib/logger/lib) | Print log messages with timestamp and log level |
| [`bash/lib/logger_json/lib`](bash/lib/logger_json/lib) | Print log messages in json format |
| [`bash/lib/notify_gotify/lib`](bash/lib/notify_gotify/lib) | Send structured notifications to a Gotify server |

## Python tools

| Tool | Description |
|------|-------------|
| [`python/bin/hetzner`](python/bin/hetzner) | Update DNS records with the Hetzner API |

## License
See repository license file.

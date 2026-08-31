# Bash binaries: borg

## backup.sh

### Description
Create and prune backups with borgbackup.

The configuration is stored in an env file (see `backup-borg.env_template`).
Pre and post commands can be defined as `run_pre`/`run_post` functions in the env file.

### Usage:
```bash
$ ./backup.sh --help
Usage: backup.sh [options]

Description:
  Creates or prunes backups with borgbackup.
  Configuration is loaded from an env file.

Options:
  -e, --env FILE    Path to borg backup env file (required)
  -h, --help        Display this help message and exit
  -p, --prune       Prune borg backups instead of creating one
  -v, --verbose     Enable verbose debugging output
```

### Log files
Monthly log files are written to `${HOME}/local/log/borg_backup_<hostname>_<year-month>.log`.

### License
See repository license file.

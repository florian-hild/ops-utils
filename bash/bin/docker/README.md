# Bash binaries: docker

## update.sh

### Description
Update docker containers from a compose file.

Pulls images, rebuilds and recreates containers when the image changed,
and appends the new version to an update history JSONL log
(`update_history_<container>_log.jsonl` next to the compose file).

### Usage:
```bash
$ ./update.sh ?
ERROR File '?' not found

Usage: update.sh [compose file]
```

### Script output example:
```bash
$ DEBUG=true ./update.sh
INFO  Start update container: omada
DEBUG Current container image: da2ae97ea953
DEBUG Current container version:
[+] Pulling 7/7
 ✔ omada-controller 6 layers [⣿⣿⣿⣿⣿⣿]  0B/0B  Pulled  24.0s
[+] Building 0.0s (0/0)           docker:default
[+] Running 1/1
 ✔ Container omada  Started      15.5s
DEBUG New container image: 3a16b0c229fa
DEBUG New container version:
INFO  Image version has changed
DEBUG Write in log file: '/data/omada/update_history_omada_log.jsonl'
INFO  Finished update container: omada
```

## update-history.sh

### Description
Show docker update history log.

### Usage:
```bash
$ ./update-history.sh update_history_pihole_log.jsonl
```

### JSON log file example:
```json
$ cat update_history_*_log.jsonl
{"timestamp": "2023-11-07 00:34:17", "version": "", "image": "bf5ab2292b67"}
{"timestamp": "2023-11-09 22:43:35", "version": "", "image": "1bb7d7fe8467"}
{"timestamp": "2023-11-11 23:50:11", "version": "", "image": "da2ae97ea953"}
{"timestamp": "2023-11-21 21:34:51", "version": "", "image": "3a16b0c229fa"}
```

### Script output example:
```bash
$ ./update-history.sh update_history_pihole_log.jsonl
+-----------------------------------------------------+
| Timestamp           | Version        | Image        |
+-----------------------------------------------------+
| 2023-11-07 00:34:17 |                | bf5ab2292b67 |
| 2023-11-09 22:43:35 |                | 1bb7d7fe8467 |
| 2023-11-11 23:50:11 |                | da2ae97ea953 |
| 2023-11-21 21:34:51 |                | 3a16b0c229fa |
+-----------------------------------------------------+
```

### License
See repository license file.

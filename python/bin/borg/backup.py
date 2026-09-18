#!/usr/bin/env python3
"""Create, prune and check borg backups from a YAML configuration.

Replaces bash/bin/borg/backup.sh. One tool for every host: plain data paths,
container database dumps (postgres/sqlite) and quiesced containers (stop),
multiple repositories per host, pre/post hooks, gotify notifications,
pushgateway metrics and a healthchecks.io dead man's switch.
"""

from __future__ import annotations

import argparse
import fcntl
import glob
import gzip
import json
import logging
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import yaml

SCRIPT_VERSION = "1.0.0"
LOCK_FILE = "/tmp/borg_backup.lock"
DOCKER_VOLUME_BASE = Path("/var/lib/docker/volumes")
CONTAINER_TYPES = ("postgres", "sqlite", "stop")
HTTP_TIMEOUT = 10
EXIT_OK = 0
EXIT_WARNING = 1
EXIT_FAILURE = 2

logger = logging.getLogger("borg-backup")


class ConfigError(Exception):
    """Raised when the YAML configuration is invalid."""


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Repository:
    url: str
    rsh: str | None = None
    remote_path: str = ""


@dataclass(frozen=True)
class Container:
    name: str
    type: str
    user: str = ""
    volume: str = ""
    database: str = ""


@dataclass(frozen=True)
class Dumps:
    dir: Path
    keep_days: int = 7


@dataclass(frozen=True)
class Hooks:
    pre: tuple[str, ...] = ()
    post: tuple[str, ...] = ()


@dataclass(frozen=True)
class Prune:
    keep_last: int = 4
    keep_daily: int = 0
    keep_weekly: int = 4
    keep_monthly: int = 6
    keep_yearly: int = 2


@dataclass(frozen=True)
class Gotify:
    url: str
    token: str


@dataclass(frozen=True)
class Pushgateway:
    url: str
    job: str


@dataclass(frozen=True)
class Config:
    repositories: tuple[Repository, ...]
    passphrase: str
    paths: tuple[str, ...]
    prefix: str
    compression: str
    exclude: tuple[str, ...]
    exclude_caches: bool
    rsh: str | None
    remote_path: str
    dumps: Dumps | None
    containers: tuple[Container, ...]
    hooks: Hooks
    prune: Prune
    gotify: Gotify | None
    pushgateway: Pushgateway | None
    healthcheck: str | None
    log_dir: Path


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ConfigError(message)


def _str_list(value: object, key: str) -> tuple[str, ...]:
    _require(
        isinstance(value, list) and all(isinstance(item, str) for item in value),
        f"'{key}' must be a list of strings",
    )
    return tuple(value)


def _parse_repositories(raw: object) -> tuple[Repository, ...]:
    _require(isinstance(raw, list) and raw, "'repositories' must be a non-empty list")
    repos: list[Repository] = []
    for item in raw:
        if isinstance(item, str):
            repos.append(Repository(url=item))
            continue
        _require(
            isinstance(item, dict), "'repositories' entries must be strings or mappings"
        )
        url = item.get("url")
        _require(
            isinstance(url, str) and url, "'repositories' entry needs a 'url' string"
        )
        rsh = item.get("rsh")
        remote_path = item.get("remote_path", "")
        _require(isinstance(rsh, str) or rsh is None, "'rsh' must be a string")
        _require(isinstance(remote_path, str), "'remote_path' must be a string")
        repos.append(Repository(url=url, rsh=rsh, remote_path=remote_path))
    return tuple(repos)


def _parse_containers(raw: object) -> tuple[Container, ...]:
    _require(isinstance(raw, list), "'containers' must be a list")
    containers: list[Container] = []
    for item in raw:
        _require(isinstance(item, dict), "'containers' entries must be mappings")
        name = item.get("name")
        ctype = item.get("type")
        _require(isinstance(name, str) and name, "'containers' entry needs a 'name'")
        _require(
            ctype in CONTAINER_TYPES, f"container '{name}': unknown type '{ctype}'"
        )
        user = item.get("user", "")
        volume = item.get("volume", "")
        database = item.get("database", "")
        if ctype == "postgres":
            _require(
                isinstance(user, str) and user, f"container '{name}': needs 'user'"
            )
        if ctype == "sqlite":
            _require(
                isinstance(volume, str) and volume,
                f"container '{name}': needs 'volume'",
            )
            _require(
                isinstance(database, str) and database,
                f"container '{name}': needs 'database'",
            )
        containers.append(
            Container(
                name=name, type=ctype, user=user, volume=volume, database=database
            )
        )
    return tuple(containers)


def _parse_prune(raw: object) -> Prune:
    _require(isinstance(raw, dict), "'prune' must be a mapping")
    keep = {}
    for key in (
        "keep_last",
        "keep_daily",
        "keep_weekly",
        "keep_monthly",
        "keep_yearly",
    ):
        value = raw.get(key, Prune.__dataclass_fields__[key].default)
        _require(
            isinstance(value, int) and not isinstance(value, bool) and value >= 0,
            f"'prune.{key}' must be an integer >= 0",
        )
        keep[key] = value
    return Prune(**keep)


def _read_passphrase(raw: dict[str, object]) -> str:
    passphrase = raw.get("passphrase")
    if isinstance(passphrase, str) and passphrase:
        return passphrase
    passphrase_file = raw.get("passphrase_file")
    _require(
        isinstance(passphrase_file, str) and passphrase_file,
        "'passphrase' or 'passphrase_file' is required",
    )
    path = Path(passphrase_file)
    _require(path.is_file(), f"passphrase_file '{passphrase_file}' not found")
    if path.stat().st_mode & 0o777 != 0o600:
        logger.warning("Passphrase file %s is not mode 0600", path)
    return path.read_text(encoding="utf-8").strip()


def parse_config(raw: object) -> Config:
    """Validate the raw YAML mapping and build the frozen Config."""
    _require(isinstance(raw, dict), "configuration must be a YAML mapping")
    known_keys = {
        "repositories",
        "passphrase",
        "passphrase_file",
        "paths",
        "prefix",
        "compression",
        "exclude",
        "exclude_caches",
        "rsh",
        "remote_path",
        "dumps",
        "containers",
        "hooks",
        "prune",
        "gotify",
        "pushgateway",
        "healthcheck",
        "log_dir",
    }
    for key in raw:
        if key not in known_keys:
            logger.warning("Unknown configuration key '%s' - ignoring", key)

    repositories = _parse_repositories(raw.get("repositories"))
    passphrase = _read_passphrase(raw)

    paths = _str_list(raw.get("paths"), "paths")
    _require(paths, "'paths' must be a non-empty list")

    prefix = raw.get("prefix", "")
    _require(isinstance(prefix, str), "'prefix' must be a string")

    compression = raw.get("compression", "zlib,5")
    _require(isinstance(compression, str), "'compression' must be a string")

    exclude = _str_list(raw.get("exclude", []), "exclude")

    exclude_caches = raw.get("exclude_caches", True)
    _require(isinstance(exclude_caches, bool), "'exclude_caches' must be a boolean")

    rsh = raw.get("rsh")
    _require(isinstance(rsh, str) or rsh is None, "'rsh' must be a string")

    remote_path = raw.get("remote_path", "borg")
    _require(isinstance(remote_path, str), "'remote_path' must be a string")

    dumps_raw = raw.get("dumps")
    dumps = None
    if dumps_raw is not None:
        _require(isinstance(dumps_raw, dict), "'dumps' must be a mapping")
        dumps_dir = dumps_raw.get("dir")
        _require(isinstance(dumps_dir, str) and dumps_dir, "'dumps.dir' is required")
        keep_days = dumps_raw.get("keep_days", 7)
        _require(
            isinstance(keep_days, int)
            and not isinstance(keep_days, bool)
            and keep_days >= 1,
            "'dumps.keep_days' must be an integer >= 1",
        )
        dumps = Dumps(dir=Path(dumps_dir), keep_days=keep_days)

    containers = _parse_containers(raw.get("containers", []))
    for container in containers:
        if container.type in ("postgres", "sqlite"):
            _require(
                dumps is not None,
                f"container '{container.name}' (type {container.type}) needs a 'dumps' section",
            )

    hooks_raw = raw.get("hooks", {})
    _require(isinstance(hooks_raw, dict), "'hooks' must be a mapping")
    hooks = Hooks(
        pre=_str_list(hooks_raw.get("pre", []), "hooks.pre"),
        post=_str_list(hooks_raw.get("post", []), "hooks.post"),
    )

    prune = _parse_prune(raw.get("prune", {}))

    gotify_raw = raw.get("gotify")
    gotify = None
    if gotify_raw is not None:
        _require(isinstance(gotify_raw, dict), "'gotify' must be a mapping")
        gotify_url = gotify_raw.get("url")
        gotify_token = gotify_raw.get("token")
        _require(isinstance(gotify_url, str) and gotify_url, "'gotify.url' is required")
        _require(
            isinstance(gotify_token, str) and gotify_token, "'gotify.token' is required"
        )
        gotify = Gotify(url=gotify_url.rstrip("/"), token=gotify_token)

    pushgateway_raw = raw.get("pushgateway")
    pushgateway = None
    if pushgateway_raw is not None:
        _require(isinstance(pushgateway_raw, dict), "'pushgateway' must be a mapping")
        push_url = pushgateway_raw.get("url")
        _require(
            isinstance(push_url, str) and push_url, "'pushgateway.url' is required"
        )
        push_job = pushgateway_raw.get("job", "borg-backup")
        _require(
            isinstance(push_job, str) and push_job, "'pushgateway.job' must be a string"
        )
        pushgateway = Pushgateway(url=push_url.rstrip("/"), job=push_job)

    healthcheck = raw.get("healthcheck")
    if healthcheck is not None:
        _require(
            isinstance(healthcheck, str) and healthcheck,
            "'healthcheck' must be the ping URL string",
        )
        healthcheck = healthcheck.rstrip("/")

    log_dir = raw.get("log_dir", str(Path.home() / "local" / "log"))
    _require(isinstance(log_dir, str), "'log_dir' must be a string")

    return Config(
        repositories=repositories,
        passphrase=passphrase,
        paths=paths,
        prefix=prefix,
        compression=compression,
        exclude=exclude,
        exclude_caches=exclude_caches,
        rsh=rsh,
        remote_path=remote_path,
        dumps=dumps,
        containers=containers,
        hooks=hooks,
        prune=prune,
        gotify=gotify,
        pushgateway=pushgateway,
        healthcheck=healthcheck,
        log_dir=Path(log_dir),
    )


def load_config(config_path: str) -> Config:
    """Load and validate the YAML configuration file."""
    path = Path(config_path)
    if not path.is_file():
        raise FileNotFoundError(f"Configuration file not found: {config_path}")
    with path.open("r", encoding="utf-8") as file_handle:
        raw = yaml.safe_load(file_handle)
    return parse_config(raw)


# --------------------------------------------------------------------------- #
# Pure builders (unit tested)
# --------------------------------------------------------------------------- #


def hostname() -> str:
    return os.uname().nodename.split(".")[0]


def archive_name(prefix: str, host: str, timestamp: float) -> str:
    """Archive name, e.g. 'daily_docker01_2026-09-17_04:20'."""
    moment = time.localtime(timestamp)
    date_part = time.strftime("%Y-%m-%d", moment)
    time_part = time.strftime("%H:%M", moment)
    head = f"{prefix}_{host}" if prefix else host
    return f"{head}_{date_part}_{time_part}"


def prune_glob(prefix: str, host: str) -> str:
    """Glob for prune; trailing '*' was missing in the old bash script."""
    head = f"{prefix}_{host}" if prefix else host
    return f"{head}_*"


def expand_paths(paths: tuple[str, ...], base_dir: Path) -> tuple[str, ...]:
    """Expand glob patterns relative to the config file; keep order, dedupe."""
    resolved: list[str] = []
    for pattern in paths:
        if not os.path.isabs(pattern):
            pattern = str(base_dir / pattern)
        matches = sorted(glob.glob(pattern))
        if not matches:
            logger.warning("Path pattern '%s' matched nothing - skipped", pattern)
            continue
        for match in matches:
            if match not in resolved:
                resolved.append(match)
    return tuple(resolved)


def build_create_cmd(
    repo_url: str,
    archive: str,
    paths: tuple[str, ...],
    *,
    compression: str,
    exclude: tuple[str, ...],
    exclude_caches: bool,
) -> list[str]:
    cmd: list[str] = [
        "borg",
        "create",
        "--filter",
        "AME",
        "--list",
        "--stats",
        "--compression",
        compression,
    ]
    if exclude_caches:
        cmd.append("--exclude-caches")
    for pattern in exclude:
        cmd.extend(["--exclude", pattern])
    cmd.append(f"{repo_url}::{archive}")
    cmd.extend(paths)
    return cmd


def build_prune_cmd(repo_url: str, pattern: str, keep: Prune) -> list[str]:
    cmd: list[str] = ["borg", "prune", "--list", "--glob-archives", pattern]
    for key in (
        "keep_last",
        "keep_daily",
        "keep_weekly",
        "keep_monthly",
        "keep_yearly",
    ):
        cmd.extend([f"--{key.replace('_', '-')}", str(getattr(keep, key))])
    cmd.append(repo_url)
    return cmd


def build_check_cmd(repo_url: str) -> list[str]:
    return ["borg", "check", "--repository-only", "--info", repo_url]


def healthcheck_url(base_url: str, action: str = "") -> str:
    return f"{base_url}{action}"


def pushgateway_metrics_url(base_url: str, job: str, instance: str) -> str:
    quoted_job = urllib.parse.quote(job, safe="")
    quoted_instance = urllib.parse.quote(instance, safe="")
    return f"{base_url}/metrics/job/{quoted_job}/instance/{quoted_instance}"


def build_backup_metrics(
    prefix: str,
    success: bool,
    duration: float,
    repos: int,
    failed_repos: int,
    now: float,
) -> str:
    """Metrics body for a backup run (pushed to pushgateway)."""
    labels = f'{{prefix="{prefix}"}}' if prefix else ""
    lines = [
        "# TYPE borg_backup_success gauge",
        f"borg_backup_success{labels} {1 if success else 0}",
        "# TYPE borg_backup_duration_seconds gauge",
        f"borg_backup_duration_seconds{labels} {duration:.1f}",
        "# TYPE borg_backup_repo_count gauge",
        f"borg_backup_repo_count{labels} {repos}",
        "# TYPE borg_backup_failed_repos gauge",
        f"borg_backup_failed_repos{labels} {failed_repos}",
    ]
    if success:
        lines.extend(
            [
                "# TYPE borg_backup_last_success_timestamp_seconds gauge",
                f"borg_backup_last_success_timestamp_seconds{labels} {int(now)}",
            ]
        )
    return "\n".join(lines) + "\n"


def build_check_metrics(prefix: str, success: bool, now: float) -> str:
    """Metrics body for a --check run (pushed to pushgateway)."""
    labels = f'{{prefix="{prefix}"}}' if prefix else ""
    lines = [
        "# TYPE borg_check_success gauge",
        f"borg_check_success{labels} {1 if success else 0}",
    ]
    if success:
        lines.extend(
            [
                "# TYPE borg_check_last_success_timestamp_seconds gauge",
                f"borg_check_last_success_timestamp_seconds{labels} {int(now)}",
            ]
        )
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- #
# HTTP helpers (notifications, metrics, dead man's switch)
# --------------------------------------------------------------------------- #


def http_get(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as response:
            response.read(1)
        return True
    except (urllib.error.URLError, OSError) as error:
        logger.warning("GET %s failed: %s", url, error)
        return False


def http_post_json(url: str, payload: dict[str, object]) -> bool:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            response.read(1)
        return True
    except (urllib.error.URLError, OSError) as error:
        logger.warning("POST %s failed: %s", url, error)
        return False


def http_put_text(url: str, body: str) -> bool:
    request = urllib.request.Request(
        url,
        data=body.encode("utf-8"),
        headers={"Content-Type": "text/plain; charset=utf-8"},
        method="PUT",
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            response.read(1)
        return True
    except (urllib.error.URLError, OSError) as error:
        logger.warning("PUT %s failed: %s", url, error)
        return False


def send_gotify(gotify: Gotify, title: str, message: str, priority: int) -> bool:
    url = f"{gotify.url}/message?token={urllib.parse.quote(gotify.token)}"
    return http_post_json(
        url, {"title": title, "message": message, "priority": priority}
    )


# --------------------------------------------------------------------------- #
# Runner
# --------------------------------------------------------------------------- #


class BorgBackup:
    """Orchestrates one backup/prune/check run for one host."""

    def __init__(self, config: Config, dry_run: bool = False) -> None:
        self.config = config
        self.dry_run = dry_run
        self.host = hostname()
        self._stopped: list[str] = []

    # -- subprocess helpers ------------------------------------------------- #

    def _run(self, cmd: list[str], *, env: dict[str, str] | None = None) -> int:
        """Run a command, log its output; borg exit codes are returned as-is."""
        if self.dry_run:
            logger.info("DRY RUN: %s", " ".join(cmd))
            return 0
        logger.debug("Executing: %s", " ".join(cmd))
        result = subprocess.run(
            cmd, env=env, capture_output=True, text=True, check=False
        )
        if result.stdout:
            logger.info("\n%s", result.stdout.rstrip())
        if result.stderr:
            level = logging.WARNING if result.returncode != 0 else logging.INFO
            logger.log(level, "\n%s", result.stderr.rstrip())
        return result.returncode

    def _borg_env(self, repo: Repository) -> dict[str, str]:
        env = dict(os.environ)
        env["BORG_REPO"] = repo.url
        env["BORG_PASSPHRASE"] = self.config.passphrase
        rsh = repo.rsh or self.config.rsh
        if rsh:
            env["BORG_RSH"] = rsh
        env["BORG_REMOTE_PATH"] = repo.remote_path or self.config.remote_path
        return env

    def _hook(self, commands: tuple[str, ...], phase: str) -> bool:
        for command in commands:
            logger.info("Run %s hook: %s", phase, command)
            if self.dry_run:
                continue
            result = subprocess.run(
                ["sh", "-c", command], capture_output=True, text=True, check=False
            )
            if result.stdout:
                logger.info("\n%s", result.stdout.rstrip())
            if result.stderr:
                logger.warning("\n%s", result.stderr.rstrip())
            if result.returncode != 0:
                logger.error(
                    "%s hook failed (rc=%d): %s", phase, result.returncode, command
                )
                return False
        return True

    # -- container dumps ---------------------------------------------------- #

    def _dump_postgres(self, container: Container) -> Path:
        stamp = time.strftime("%Y%m%d_%H%M")
        target = self.config.dumps.dir / f"{container.name}_{stamp}.sql.gz"  # type: ignore[union-attr]
        cmd = ["docker", "exec", container.name, "pg_dumpall", "-U", container.user]
        logger.info("Dump postgres '%s' to %s", container.name, target)
        if self.dry_run:
            logger.info("DRY RUN: %s", " ".join(cmd))
            return target
        self.config.dumps.dir.mkdir(parents=True, exist_ok=True)  # type: ignore[union-attr]
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        with gzip.open(target, "wb") as archive:
            assert process.stdout is not None
            shutil.copyfileobj(process.stdout, archive)
        stderr = (
            process.stderr.read().decode("utf-8", "replace") if process.stderr else ""
        )
        returncode = process.wait()
        if stderr.strip():
            logger.info("pg_dumpall %s: %s", container.name, stderr.strip())
        if returncode != 0:
            target.unlink(missing_ok=True)
            raise RuntimeError(
                f"pg_dumpall for '{container.name}' failed (rc={returncode})"
            )
        return target

    def _dump_sqlite(self, container: Container) -> Path:
        stamp = time.strftime("%Y%m%d_%H%M")
        source = DOCKER_VOLUME_BASE / container.volume / "_data" / container.database
        target = self.config.dumps.dir / f"{container.name}_{stamp}.sqlite"  # type: ignore[union-attr]
        logger.info("Backup sqlite '%s' (%s) to %s", container.name, source, target)
        self.config.dumps.dir.mkdir(parents=True, exist_ok=True)  # type: ignore[union-attr]
        cmd = ["sqlite3", str(source), f".backup '{target}'"]
        returncode = self._run(cmd)
        if returncode != 0:
            raise RuntimeError(
                f"sqlite backup for '{container.name}' failed (rc={returncode})"
            )
        return target

    def _stop_container(self, name: str) -> None:
        logger.info("Stop container '%s' for a consistent copy", name)
        returncode = self._run(["docker", "stop", "-t", "60", name])
        if returncode != 0:
            raise RuntimeError(f"docker stop '{name}' failed (rc={returncode})")
        self._stopped.append(name)

    def _start_stopped(self) -> None:
        for name in reversed(self._stopped):
            logger.info("Start container '%s'", name)
            self._run(["docker", "start", name])
        self._stopped.clear()

    def _clean_dumps(self) -> None:
        dumps = self.config.dumps
        if dumps is None:
            return
        cutoff = time.time() - dumps.keep_days * 86400
        for entry in dumps.dir.glob("*"):
            if entry.is_file() and entry.stat().st_mtime < cutoff:
                logger.info("Remove old dump %s", entry.name)
                if not self.dry_run:
                    entry.unlink(missing_ok=True)

    def _run_dumps(self) -> list[str]:
        """Dump databases and stop 'stop' containers; raises on failure."""
        if self.config.containers and shutil.which("docker") is None:
            raise RuntimeError(
                "'containers' configured but no docker binary on this host"
            )
        if (
            not self.dry_run
            and any(c.type == "sqlite" for c in self.config.containers)
            and shutil.which("sqlite3") is None
        ):
            raise RuntimeError(
                "sqlite container configured but no sqlite3 (apt install sqlite3)"
            )
        dumped: list[str] = []
        for container in self.config.containers:
            if container.type == "postgres":
                dumped.append(str(self._dump_postgres(container)))
            elif container.type == "sqlite":
                dumped.append(str(self._dump_sqlite(container)))
            elif container.type == "stop":
                self._stop_container(container.name)
        self._clean_dumps()
        return dumped

    # -- notifications / metrics -------------------------------------------- #

    def _push_metrics(self, body: str) -> bool:
        if self.config.pushgateway is None:
            return True
        url = pushgateway_metrics_url(
            self.config.pushgateway.url, self.config.pushgateway.job, self.host
        )
        if self.dry_run:
            logger.info("DRY RUN: push metrics to %s:\n%s", url, body.rstrip())
            return True
        return http_put_text(url, body)

    def _ping_healthcheck(self, action: str) -> bool:
        if self.config.healthcheck is None:
            return True
        url = healthcheck_url(self.config.healthcheck, action)
        if self.dry_run:
            logger.info("DRY RUN: ping %s", url)
            return True
        return http_get(url)

    def _notify(self, title: str, message: str, priority: int) -> None:
        if self.config.gotify is None:
            return
        if not send_gotify(self.config.gotify, title, message, priority):
            logger.warning("Gotify notification failed")
        elif self.dry_run:
            logger.info("DRY RUN: gotify '%s' (priority %d)", title, priority)

    # -- modes --------------------------------------------------------------- #

    def run_backup(self) -> int:
        started = time.time()
        self._ping_healthcheck("/start")
        dumped: list[str] = []
        try:
            if not self._hook(self.config.hooks.pre, "pre"):
                return self._finish_backup(started, False, [], "pre hook failed", [], 0)
            try:
                dumped = self._run_dumps()
            except RuntimeError as error:
                logger.error("Dump phase failed: %s", error)
                return self._finish_backup(
                    started, False, [], f"dump phase failed: {error}", [], 0
                )
            paths = expand_paths(self.config.paths, self.config.log_dir)
            if self.config.dumps is not None:
                paths = (*paths, str(self.config.dumps.dir))
            archive = archive_name(self.config.prefix, self.host, started)
            repo_results: list[str] = []
            failed_repos = 0
            warning = False
            for repo in self.config.repositories:
                cmd = build_create_cmd(
                    repo.url,
                    archive,
                    paths,
                    compression=self.config.compression,
                    exclude=self.config.exclude,
                    exclude_caches=self.config.exclude_caches,
                )
                logger.info("Backup to %s", repo.url)
                rc = self._run(cmd, env=self._borg_env(repo))
                if rc == 0:
                    repo_results.append(f"{repo.url}: ok")
                elif rc == 1:
                    warning = True
                    repo_results.append(f"{repo.url}: warning (rc=1, files changed?)")
                else:
                    failed_repos += 1
                    repo_results.append(f"{repo.url}: FAILED (rc={rc})")
        finally:
            self._start_stopped()
        self._hook(self.config.hooks.post, "post")
        success = failed_repos == 0
        duration = time.time() - started
        if dumped:
            repo_results.append("Dumps: " + ", ".join(Path(d).name for d in dumped))
        return self._finish_backup(
            started,
            success,
            repo_results,
            "",
            repo_results,
            failed_repos,
            warning,
            duration,
        )

    def _finish_backup(
        self,
        started: float,
        success: bool,
        repo_results: list[str],
        detail: str,
        metrics_lines: list[str],
        failed_repos: int,
        warning: bool = False,
        duration: float | None = None,
    ) -> int:
        if duration is None:
            duration = time.time() - started
        state = "OK" if success else ("WARNING" if warning else "FAILED")
        title = f"Borg backup {self.host}: {state}"
        message = "\n".join(repo_results) if repo_results else detail
        message += f"\nDuration: {duration:.0f}s"
        for line in repo_results:
            logger.log(
                logging.WARNING if "FAILED" in line else logging.INFO, "%s", line
            )
        logger.info("Backup %s in %.0fs", state, duration)
        priority = 3 if success else (5 if warning else 8)
        self._notify(title, message, priority)
        metrics_ok = self._push_metrics(
            build_backup_metrics(
                self.config.prefix,
                success,
                duration,
                len(self.config.repositories),
                failed_repos,
                time.time(),
            )
        )
        self._ping_healthcheck("" if success else "/fail")
        if not success:
            return EXIT_FAILURE
        if warning or not metrics_ok:
            return EXIT_WARNING
        return EXIT_OK

    def run_prune(self) -> int:
        pattern = prune_glob(self.config.prefix, self.host)
        worst = EXIT_OK
        for repo in self.config.repositories:
            cmd = build_prune_cmd(repo.url, pattern, self.config.prune)
            logger.info("Prune %s (glob %s)", repo.url, pattern)
            rc = self._run(cmd, env=self._borg_env(repo))
            if rc >= 2:
                worst = EXIT_FAILURE
                self._notify(
                    f"Borg prune {self.host}: FAILED",
                    f"{repo.url}: prune failed (rc={rc})",
                    8,
                )
            elif rc == 1:
                worst = max(worst, EXIT_WARNING)
        return worst

    def run_check(self) -> int:
        results: list[str] = []
        failed = 0
        for repo in self.config.repositories:
            cmd = build_check_cmd(repo.url)
            logger.info("Check %s", repo.url)
            rc = self._run(cmd, env=self._borg_env(repo))
            if rc == 0:
                results.append(f"{repo.url}: ok")
            else:
                failed += 1
                results.append(f"{repo.url}: FAILED (rc={rc})")
        success = failed == 0
        if not success:
            self._notify(
                f"Borg check {self.host}: FAILED",
                "\n".join(results),
                8,
            )
        self._push_metrics(
            build_check_metrics(self.config.prefix, success, time.time())
        )
        return EXIT_OK if success else EXIT_FAILURE


# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #


def setup_logging(log_dir: Path, verbose: bool) -> Path:
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / f"borg_backup_{hostname()}_{time.strftime('%Y-%m')}.log"
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    formatter = logging.Formatter(
        "%(asctime)s %(levelname)-8s %(message)s", datefmt="%Y-%m-%dT%H:%M:%S%z"
    )
    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)
    file_handler = logging.FileHandler(log_file)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    return log_file


def acquire_lock() -> None:
    fd = os.open(LOCK_FILE, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        os.close(fd)
        raise RuntimeError(
            f"Another backup run holds {LOCK_FILE} - aborting"
        ) from error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create, prune and check borg backups from a YAML configuration"
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--prune", action="store_true", help="Prune archives instead of creating"
    )
    mode.add_argument(
        "--check", action="store_true", help="Verify repository integrity (borg check)"
    )
    parser.add_argument(
        "-c", "--config", required=True, help="Path to YAML configuration file"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Show what would run without executing"
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable debug logging"
    )
    parser.add_argument("--version", action="version", version=SCRIPT_VERSION)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config = load_config(args.config)
    log_file = setup_logging(config.log_dir, args.verbose)
    logger.info("Start borg backup script v%s (log: %s)", SCRIPT_VERSION, log_file)
    try:
        acquire_lock()
    except RuntimeError as error:
        logger.error("%s", error)
        return EXIT_FAILURE
    backup = BorgBackup(config, dry_run=args.dry_run)
    try:
        if args.prune:
            rc = backup.run_prune()
        elif args.check:
            rc = backup.run_check()
        else:
            rc = backup.run_backup()
    except Exception as error:  # cron must always get an exit code
        logger.critical("Unexpected error: %s", error, exc_info=True)
        rc = EXIT_FAILURE
    logger.info("End borg backup script (rc=%d)", rc)
    return rc


if __name__ == "__main__":
    sys.exit(main())

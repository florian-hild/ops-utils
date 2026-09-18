"""Unit tests for the borg backup tool (pure functions and config parsing)."""

from __future__ import annotations

import logging
from pathlib import Path

import pytest

import backup
from backup import (
    EXIT_FAILURE,
    EXIT_OK,
    BorgBackup,
    ConfigError,
    Prune,
    archive_name,
    build_backup_metrics,
    build_check_cmd,
    build_check_metrics,
    build_create_cmd,
    build_prune_cmd,
    expand_paths,
    healthcheck_url,
    parse_config,
    prune_glob,
    pushgateway_metrics_url,
)


def minimal_config() -> dict[str, object]:
    return {
        "repositories": ["ssh://borg@nas/host01"],
        "passphrase": "secret",
        "paths": ["/etc"],
    }


class TestParseConfig:
    def test_minimal_config(self) -> None:
        config = parse_config(minimal_config())
        assert config.repositories[0].url == "ssh://borg@nas/host01"
        assert config.repositories[0].remote_path == ""
        assert config.passphrase == "secret"
        assert config.paths == ("/etc",)
        assert config.prefix == ""
        assert config.compression == "zlib,5"
        assert config.exclude == ()
        assert config.exclude_caches is True
        assert config.remote_path == "borg"
        assert config.dumps is None
        assert config.containers == ()
        assert config.prune.keep_daily == 0
        assert config.prune.keep_weekly == 4
        assert config.gotify is None
        assert config.pushgateway is None
        assert config.healthcheck is None
        assert config.log_dir == Path.home() / "local" / "log"

    def test_repository_mapping_overrides(self) -> None:
        raw = minimal_config()
        raw["repositories"] = [
            "ssh://borg@nas/host01",
            {
                "url": "ssh://u1@u1.your-storagebox.de:23/./host01",
                "remote_path": "borg-1.2",
                "rsh": "ssh -i /root/.ssh/storagebox",
            },
        ]
        raw["rsh"] = "ssh -i /root/.ssh/id_ed25519"
        config = parse_config(raw)
        assert config.repositories[0].rsh is None
        assert config.repositories[1].remote_path == "borg-1.2"
        assert config.repositories[1].rsh == "ssh -i /root/.ssh/storagebox"
        assert config.rsh == "ssh -i /root/.ssh/id_ed25519"

    def test_missing_repositories(self) -> None:
        raw = minimal_config()
        del raw["repositories"]
        with pytest.raises(ConfigError):
            parse_config(raw)

    def test_missing_passphrase(self) -> None:
        raw = minimal_config()
        del raw["passphrase"]
        with pytest.raises(ConfigError):
            parse_config(raw)

    def test_empty_paths(self) -> None:
        raw = minimal_config()
        raw["paths"] = []
        with pytest.raises(ConfigError):
            parse_config(raw)

    def test_unknown_key_warns(self, caplog: pytest.LogCaptureFixture) -> None:
        raw = minimal_config()
        raw["passwort"] = "typo"
        with caplog.at_level(logging.WARNING):
            parse_config(raw)
        assert "Unknown configuration key 'passwort'" in caplog.text

    def test_containers_need_dumps(self) -> None:
        raw = minimal_config()
        raw["containers"] = [{"name": "pg", "type": "postgres", "user": "db"}]
        with pytest.raises(ConfigError, match="needs a 'dumps' section"):
            parse_config(raw)

    def test_container_type_validation(self) -> None:
        raw = minimal_config()
        raw["dumps"] = {"dir": "/root/backup/dumps"}
        raw["containers"] = [{"name": "x", "type": "mysql"}]
        with pytest.raises(ConfigError, match="unknown type"):
            parse_config(raw)

    def test_sqlite_needs_volume_and_database(self) -> None:
        raw = minimal_config()
        raw["dumps"] = {"dir": "/root/backup/dumps"}
        raw["containers"] = [{"name": "vw", "type": "sqlite", "volume": "vw_data"}]
        with pytest.raises(ConfigError, match="needs 'database'"):
            parse_config(raw)

    def test_gotify_requires_url_and_token(self) -> None:
        raw = minimal_config()
        raw["gotify"] = {"url": "https://gotify.example.com"}
        with pytest.raises(ConfigError, match="gotify.token"):
            parse_config(raw)

    def test_prune_validation(self) -> None:
        raw = minimal_config()
        raw["prune"] = {"keep_daily": "7"}
        with pytest.raises(ConfigError, match="keep_daily"):
            parse_config(raw)

    def test_passphrase_file_mode_warning(
        self, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        secret = tmp_path / "passphrase"
        secret.write_text("secret\n", encoding="utf-8")
        secret.chmod(0o600)
        raw = minimal_config()
        raw["passphrase_file"] = str(secret)
        del raw["passphrase"]
        config = parse_config(raw)
        assert config.passphrase == "secret"
        secret.chmod(0o644)
        with caplog.at_level(logging.WARNING):
            parse_config(raw)
        assert "not mode 0600" in caplog.text


class TestBuilders:
    def test_archive_name_with_prefix(self) -> None:
        stamp = 1760000000.0
        name = archive_name("daily", "docker01", stamp)
        assert name.startswith("daily_docker01_")
        date_part, time_part = name.split("_")[-2:]
        assert len(date_part) == 10  # YYYY-MM-DD
        assert len(time_part) == 5  # HH:MM

    def test_archive_name_without_prefix(self) -> None:
        assert archive_name("", "nas01", 1760000000.0).startswith("nas01_")

    def test_prune_glob_has_trailing_star(self) -> None:
        assert prune_glob("daily", "docker01") == "daily_docker01_*"
        assert prune_glob("", "nas01") == "nas01_*"

    def test_expand_paths_absolute_glob(self, tmp_path: Path) -> None:
        (tmp_path / "a.crontab").touch()
        (tmp_path / "b.crontab").touch()
        (tmp_path / "other.txt").touch()
        result = expand_paths(
            (f"{tmp_path}/*.crontab", str(tmp_path / "other.txt")), tmp_path
        )
        assert result == (
            str(tmp_path / "a.crontab"),
            str(tmp_path / "b.crontab"),
            str(tmp_path / "other.txt"),
        )

    def test_expand_paths_relative_resolves_against_base(self, tmp_path: Path) -> None:
        (tmp_path / "rel.txt").touch()
        result = expand_paths(("rel.txt",), tmp_path)
        assert result == (str(tmp_path / "rel.txt"),)

    def test_expand_paths_no_match_warns(
        self, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        with caplog.at_level(logging.WARNING):
            result = expand_paths((f"{tmp_path}/does-not-exist",), tmp_path)
        assert result == ()
        assert "matched nothing" in caplog.text

    def test_build_create_cmd(self) -> None:
        cmd = build_create_cmd(
            "ssh://borg@nas/host01",
            "daily_host01_2026-09-17_04:20",
            ("/etc", "/root"),
            compression="zlib,5",
            exclude=(".DS_Store", "*.tmp"),
            exclude_caches=True,
        )
        assert cmd[0:4] == ["borg", "create", "--filter", "AME"]
        assert "--exclude-caches" in cmd
        assert cmd[cmd.index("--compression") + 1] == "zlib,5"
        assert cmd.count("--exclude") == 2
        assert cmd[-3:] == [
            "ssh://borg@nas/host01::daily_host01_2026-09-17_04:20",
            "/etc",
            "/root",
        ]

    def test_build_create_cmd_without_excludes(self) -> None:
        cmd = build_create_cmd(
            "repo",
            "arch",
            ("/etc",),
            compression="none",
            exclude=(),
            exclude_caches=False,
        )
        assert "--exclude-caches" not in cmd
        assert "--exclude" not in cmd

    def test_build_prune_cmd(self) -> None:
        keep = Prune(
            keep_last=4, keep_daily=7, keep_weekly=4, keep_monthly=6, keep_yearly=2
        )
        cmd = build_prune_cmd("ssh://borg@nas/host01", "daily_host01_*", keep)
        assert cmd[0] == "borg"
        assert cmd[cmd.index("--glob-archives") + 1] == "daily_host01_*"
        assert cmd[cmd.index("--keep-daily") + 1] == "7"
        assert cmd[-1] == "ssh://borg@nas/host01"

    def test_build_check_cmd(self) -> None:
        assert build_check_cmd("repo-url") == [
            "borg",
            "check",
            "--repository-only",
            "--info",
            "repo-url",
        ]


class TestMetricsAndUrls:
    def test_backup_metrics_success(self) -> None:
        body = build_backup_metrics("daily", True, 123.4, 2, 0, 1760000000.0)
        assert 'borg_backup_success{prefix="daily"} 1' in body
        assert "borg_backup_last_success_timestamp_seconds" in body
        assert "1760000000" in body
        assert 'borg_backup_failed_repos{prefix="daily"} 0' in body

    def test_backup_metrics_failure_omits_timestamp(self) -> None:
        body = build_backup_metrics("daily", False, 10.0, 2, 1, 1760000000.0)
        assert 'borg_backup_success{prefix="daily"} 0' in body
        assert "last_success_timestamp" not in body

    def test_backup_metrics_without_prefix(self) -> None:
        body = build_backup_metrics("", True, 1.0, 1, 0, 1.0)
        assert "borg_backup_success 1" in body

    def test_check_metrics(self) -> None:
        body = build_check_metrics("daily", True, 1760000000.0)
        assert 'borg_check_success{prefix="daily"} 1' in body
        assert "1760000000" in body

    def test_healthcheck_url_actions(self) -> None:
        base = "https://hc-ping.com/uuid"
        assert healthcheck_url(base) == base
        assert healthcheck_url(base, "/start") == base + "/start"
        assert healthcheck_url(base, "/fail") == base + "/fail"

    def test_pushgateway_url_quotes_labels(self) -> None:
        url = pushgateway_metrics_url(
            "https://push.example.com", "borg backup", "host 01"
        )
        assert (
            url
            == "https://push.example.com/metrics/job/borg%20backup/instance/host%2001"
        )


class TestBorgBackupDryRun:
    def _config(self) -> backup.Config:
        return parse_config(minimal_config())

    def test_backup_dry_run_ok(
        self, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        config = self._config()
        object.__setattr__(config, "log_dir", tmp_path)
        with caplog.at_level(logging.INFO):
            backup_run = BorgBackup(config, dry_run=True)
            rc = backup_run.run_backup()
        assert rc == EXIT_OK
        assert "DRY RUN" in caplog.text

    def test_prune_dry_run(self, tmp_path: Path) -> None:
        config = self._config()
        object.__setattr__(config, "log_dir", tmp_path)
        rc = BorgBackup(config, dry_run=True).run_prune()
        assert rc == EXIT_OK

    def test_check_dry_run(self, tmp_path: Path) -> None:
        config = self._config()
        object.__setattr__(config, "log_dir", tmp_path)
        rc = BorgBackup(config, dry_run=True).run_check()
        assert rc == EXIT_OK

    def test_pre_hook_failure_aborts(self, tmp_path: Path) -> None:
        config = parse_config(
            {
                **minimal_config(),
                "hooks": {"pre": ["exit 7"]},
            }
        )
        object.__setattr__(config, "log_dir", tmp_path)
        rc = BorgBackup(config, dry_run=False).run_backup()
        assert rc == EXIT_FAILURE

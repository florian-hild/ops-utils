#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from argparse import ArgumentParser
from datetime import datetime
from pathlib import Path

import requests
import yaml
from hcloud import Client
from hcloud._exceptions import APIException
from hcloud.zones import Zone, ZoneRecord, ZoneRRSet


def parse_args() -> str:
    parser = ArgumentParser(description="Update Hetzner DNS record with current IP")
    parser.add_argument(
        "-c",
        "--config",
        required=True,
        help="Path to YAML configuration file",
    )
    args = parser.parse_args()
    return args.config


def load_config(config_path: str) -> dict[str, str]:
    config_file = Path(config_path)
    if not config_file.is_file():
        raise FileNotFoundError(f"Configuration file not found: {config_file}")

    with config_file.open("r", encoding="utf-8") as file_handle:
        config = yaml.safe_load(file_handle) or {}

    required_keys = {"log_file", "hcloud_token", "zone_name", "record_name"}
    missing_keys = sorted(key for key in required_keys if key not in config)
    if missing_keys:
        raise KeyError(
            "Missing required configuration keys: " + ", ".join(missing_keys)
        )

    return config


def write_log(log_file: Path, current_ip: str, last_ip: str, status: str):
    log_entry = {
        "timestamp": datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S"),
        "current": current_ip,
        "last": last_ip,
        "status": status,
    }
    with log_file.open("a", encoding="utf-8") as file_handle:
        file_handle.write(json.dumps(log_entry) + "\n")


def get_public_ip() -> str:
    """Fetch current public IP from ifconfig.me"""
    try:
        response = requests.get("https://ifconfig.me/ip", timeout=5)
        response.raise_for_status()
        return response.text.strip()
    except requests.RequestException as e:
        raise RuntimeError(f"Failed to get public IP: {e}")


def get_current_dns_ip(client: Client, zone_name: str, record_name: str) -> str | None:
    """Get current A record value from Hetzner DNS"""
    rrset = client.zones.get_rrset(
        zone=Zone(name=zone_name), name=record_name, type="A"
    )
    # Return first record value
    if rrset.records:
        return rrset.records[0].value

    return None


def update_dns_record(client: Client, zone_name: str, record_name: str, new_ip: str):
    """Update the A record to new IP"""
    rrset = ZoneRRSet(zone=Zone(name=zone_name), name=record_name, type="A")
    records = [ZoneRecord(value=new_ip, comment="Updated by Python script")]
    action = client.zones.set_rrset_records(rrset=rrset, records=records)
    action.wait_until_finished()
    print(f"DNS record updated to {new_ip}")


def run():
    config_path = parse_args()
    config = load_config(config_path)

    log_file = Path(config["log_file"])
    try:
        log_file.parent.mkdir(parents=True, exist_ok=True)
    except PermissionError as exc:
        raise PermissionError(
            f"Cannot create log directory '{log_file.parent}': {exc}"
        ) from exc

    client = Client(token=config["hcloud_token"])
    zone_name = config["zone_name"]
    record_name = config["record_name"]

    public_ip = get_public_ip()
    dns_ip = get_current_dns_ip(client, zone_name, record_name)

    if public_ip == dns_ip:
        print(f"No update needed, DNS already points to {public_ip}")
        status = "unchanged"
    else:
        print(f"Updating DNS from {dns_ip} to {public_ip}")
        update_dns_record(client, zone_name, record_name, public_ip)
        status = "updated"
        write_log(
            log_file=log_file,
            current_ip=public_ip,
            last_ip=dns_ip or "N/A",
            status=status,
        )


if __name__ == "__main__":
    try:
        run()
    except FileNotFoundError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    except KeyError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    except PermissionError as exc:
        print(f"Permission error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    except APIException as exc:
        message = getattr(exc, "message", str(exc))
        print(f"Hetzner API error: {message}", file=sys.stderr)
        raise SystemExit(1) from exc
    except RuntimeError as exc:
        print(f"Runtime error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc

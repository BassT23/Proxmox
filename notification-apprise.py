#!/usr/bin/env python3
"""Optional provider-neutral Apprise delivery for the status model.

The updater owns status and notification policy.  This helper owns only the
optional delivery, per-provider retry state, and bounded cleanup.  Provider
URLs are read from a protected file and are never accepted as arguments.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time


DEFAULT_URLS_FILE = "/etc/ultimate-updater/apprise-urls"
DEFAULT_STATE_FILE = "/var/lib/ultimate-updater/apprise-notification-state.json"
MAX_PROVIDER_TIMEOUT = 15.0
MAX_DELIVERY_BUDGET = 20.0
STATE_RETENTION_SECONDS = 30 * 86400
MAX_STATE_ENTRIES = 1024
MAX_URLS = 32
MAX_URL_LENGTH = 4096
MAX_BODY_LENGTH = 32768


def bounded_seconds(name, default, maximum):
    """Allow tests/operators to shorten, never extend, delivery limits."""
    try:
        value = float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default
    return max(0.05, min(value, maximum))


def mode_is_private(mode):
    return stat.S_IMODE(mode) == 0o600


def validate_parent(path):
    parent = path.parent
    if parent.is_symlink() or not parent.is_dir():
        raise ValueError("unsafe notification state directory")
    metadata = parent.stat()
    if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
        raise ValueError("unsafe notification state directory")


def protected_lines(path):
    """Read one provider URL per line from a root-owned private file."""
    if not path or not Path(path).is_absolute():
        raise ValueError("missing protected provider configuration")
    provider_path = Path(path)
    parent = provider_path.parent
    if parent.is_symlink() or not parent.is_dir():
        raise ValueError("unsafe provider configuration directory")
    parent_metadata = parent.stat()
    if parent_metadata.st_uid != os.geteuid() or parent_metadata.st_mode & 0o022:
        raise ValueError("unsafe provider configuration directory")
    descriptor = os.open(provider_path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or not mode_is_private(metadata.st_mode)
                or metadata.st_uid != os.geteuid() or metadata.st_size > 131072):
            raise ValueError("invalid protected provider configuration")
        with os.fdopen(descriptor, encoding="utf-8", closefd=False) as source:
            content = source.read(131073)
    finally:
        os.close(descriptor)
    if len(content) > 131072:
        raise ValueError("oversized provider configuration")
    values = []
    for line in content.splitlines():
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        if (len(value) > MAX_URL_LENGTH or any(char.isspace() for char in value)
                or "://" not in value or not value.split("://", 1)[0]):
            raise ValueError("invalid provider configuration")
        values.append(value)
    if not values or len(values) > MAX_URLS:
        raise ValueError("invalid provider configuration")
    return values


def read_status(path, scope):
    with open(path, encoding="utf-8") as source:
        payload = json.load(source)
    if not isinstance(payload, dict) or not isinstance(payload.get("targets"), list):
        raise ValueError("invalid status data")
    rows = []
    for item in payload["targets"]:
        if not isinstance(item, dict):
            raise ValueError("invalid status target")
        identity = str(item.get("id") or "")
        if scope and identity not in {scope, "guest:" + scope} and identity.rsplit(":", 1)[-1] != scope:
            continue
        counts = item.get("updates")
        error = item.get("error") if isinstance(item.get("error"), dict) else {}
        last_update = item.get("last_update") if isinstance(item.get("last_update"), dict) else {}
        rows.append({
            "id": identity,
            "reachable": item.get("reachable"),
            "check_status": item.get("check_status"),
            "available": counts.get("available") if isinstance(counts, dict) else None,
            "reboot": item.get("reboot_required"),
            "error_code": error.get("code"),
            "update_state": last_update.get("status"),
        })
    rows.sort(key=lambda item: item["id"])
    return payload, rows


def atomic_save(path, data):
    validate_parent(path)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".apprise-state-", delete=False) as handle:
            temporary = Path(handle.name)
            os.fchmod(handle.fileno(), 0o600)
            json.dump(prune_delivery_state(data, time.time()), handle,
                      sort_keys=True, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def deliver_one(url, title, message, state, timeout_seconds=None):
    """Run one provider in a process so a plugin cannot stall the job."""
    request = json.dumps({"url": url, "title": title, "message": message, "state": state})
    timeout = bounded_seconds("UU_APPRISE_PROVIDER_TIMEOUT", MAX_PROVIDER_TIMEOUT,
                              MAX_PROVIDER_TIMEOUT)
    if timeout_seconds is not None:
        timeout = min(timeout, max(0.05, timeout_seconds))
    try:
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), "--send-single"],
            input=request, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=timeout, check=False,
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def send_single():
    """Read a provider URL only from a private pipe, never argv or logs."""
    try:
        request = json.load(sys.stdin)
        import apprise  # optional dependency; imported only when enabled
        client = apprise.Apprise()
        if not client.add(request["url"]):
            return 69
        notify_type = {
            "issues": apprise.NotifyType.WARNING,
            "updates": apprise.NotifyType.INFO,
            "current": apprise.NotifyType.SUCCESS,
        }.get(request["state"], apprise.NotifyType.INFO)
        return 0 if client.notify(body=request["message"], title=request["title"],
                                  notify_type=notify_type) else 69
    except (OSError, ValueError, TypeError, KeyError, ImportError, RuntimeError):
        return 69


def read_delivery_state(path):
    """Malformed state resets deduplication so alerts can resume."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return {}
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or not mode_is_private(metadata.st_mode)
                or metadata.st_uid != os.geteuid() or metadata.st_size > 1024 * 1024):
            raise ValueError("unsafe delivery state")
        with os.fdopen(descriptor, encoding="utf-8", closefd=False) as source:
            try:
                state_data = json.load(source)
            except (json.JSONDecodeError, UnicodeError):
                state_data = {}
    finally:
        os.close(descriptor)
    return state_data if isinstance(state_data, dict) else {}


def prune_delivery_state(state_data, now):
    valid = {
        key: value for key, value in state_data.items()
        if isinstance(key, str) and isinstance(value, dict)
        and isinstance(value.get("updated_at"), (int, float))
        and 0 <= now - value["updated_at"] <= STATE_RETENTION_SECONDS
    }
    return dict(sorted(valid.items(), key=lambda item: item[1]["updated_at"],
                       reverse=True)[:MAX_STATE_ENTRIES])


def prepare_state(path):
    if not path.is_absolute():
        raise ValueError("Apprise state path must be absolute")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    validate_parent(path)


def main(argv=None):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("kind", choices=("check", "update"))
    parser.add_argument("status_file")
    parser.add_argument("state", choices=("updates", "issues", "current", "empty"))
    parser.add_argument("run_started_at", nargs="?", default="")
    args = parser.parse_args(argv)

    urls_path = os.environ.get("UU_APPRISE_URLS_FILE", DEFAULT_URLS_FILE)
    state_file = Path(os.environ.get("UU_APPRISE_STATE_FILE", DEFAULT_STATE_FILE))
    try:
        urls = protected_lines(urls_path)
        prepare_state(state_file)
        scope = os.environ.get("UU_SINGLE_TARGET_ID", "") if os.environ.get("UU_SINGLE_TARGET") == "true" else ""
        payload, rows = read_status(args.status_file, scope)
        if args.state == "empty":
            return 0
        body = sys.stdin.read(MAX_BODY_LENGTH + 1)
        if len(body) > MAX_BODY_LENGTH or not body.strip():
            raise ValueError("invalid notification body")
        key = args.kind + ":" + (scope or "all")
        marker = {"kind": args.kind, "state": args.state, "targets": rows}
        if args.kind == "update":
            marker["run_started_at"] = args.run_started_at or payload.get("generated_at")
        fingerprint = hashlib.sha256(
            json.dumps(marker, sort_keys=True, default=str, separators=(",", ":")).encode()
        ).hexdigest()
        lock_path = state_file.with_name(state_file.name + ".lock")
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            lock_metadata = os.fstat(lock_fd)
            if (not stat.S_ISREG(lock_metadata.st_mode)
                    or not mode_is_private(lock_metadata.st_mode)
                    or lock_metadata.st_uid != os.geteuid()):
                raise ValueError("unsafe delivery lock")
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            now = time.time()
            raw_state = read_delivery_state(state_file)
            previous = raw_state.get(key) if isinstance(raw_state.get(key), dict) else None
            state_data = prune_delivery_state(raw_state, now)
            if previous and previous.get("fingerprint") == fingerprint and "delivered_providers" not in previous:
                return 0
            entry = state_data.get(key) if previous and previous.get("fingerprint") == fingerprint else None
            if entry is None:
                entry = {"fingerprint": fingerprint, "state": args.state,
                         "delivered_providers": [], "updated_at": now}
            delivered = {
                item for item in entry.get("delivered_providers", [])
                if isinstance(item, str) and len(item) == 64
                and all(char in "0123456789abcdef" for char in item)
            }
            entry["delivered_providers"] = sorted(delivered)
            if args.kind == "check" and args.state == "current" and (
                    not previous or (previous.get("state") == "current"
                                     and previous.get("fingerprint") != fingerprint)):
                entry["delivered_providers"] = [hashlib.sha256(url.encode()).hexdigest() for url in urls]
                entry["updated_at"] = now
                state_data[key] = entry
                atomic_save(state_file, state_data)
                return 0
            failed = False
            deadline = time.monotonic() + bounded_seconds(
                "UU_APPRISE_DELIVERY_BUDGET", MAX_DELIVERY_BUDGET, MAX_DELIVERY_BUDGET)
            for url in urls:
                provider_id = hashlib.sha256(url.encode()).hexdigest()
                if provider_id in delivered:
                    continue
                remaining = deadline - time.monotonic()
                if remaining > 0 and deliver_one(url, "Ultimate Updater " + args.kind,
                                                  body, args.state, remaining):
                    delivered.add(provider_id)
                    entry["delivered_providers"] = sorted(delivered)
                    entry["updated_at"] = now
                    state_data[key] = entry
                    atomic_save(state_file, state_data)
                else:
                    failed = True
            if failed:
                print("Apprise delivery failed.", file=sys.stderr)
                return 69
            return 0
        finally:
            os.close(lock_fd)
    except (OSError, ValueError, TypeError, UnicodeError, ImportError, RuntimeError):
        print("Apprise notification unavailable.", file=sys.stderr)
        return 69


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--send-single":
        raise SystemExit(send_single())
    raise SystemExit(main())

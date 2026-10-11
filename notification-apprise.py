#!/usr/bin/env python3
"""Optional Apprise transport for Ultimate Updater's existing notification renderer.

Read provider URLs from a protected runtime file, never from argv or source.
The update/check engine owns status; this helper owns only delivery and dedupe.
"""
import argparse
import fcntl
import hashlib
import json
import logging
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time

STATE_DEFAULT = "/var/lib/ultimate-updater/apprise-notification-state.json"
DELIVERY_TIMEOUT_SECONDS = 15
DELIVERY_BUDGET_SECONDS = 20
STATE_RETENTION_SECONDS = 30 * 86400
MAX_STATE_ENTRIES = 1024


def protected_lines(path):
    if not path or not Path(path).is_absolute():
        raise ValueError("missing protected provider configuration")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077
                or metadata.st_uid != os.geteuid() or metadata.st_size > 131072):
            raise ValueError("invalid protected provider configuration")
        with os.fdopen(descriptor, encoding="utf-8", closefd=False) as source:
            content = source.read(131073)
        if len(content) > 131072:
            raise ValueError("oversized provider configuration")
    finally:
        os.close(descriptor)
    values = [line.strip() for line in content.splitlines()
              if line.strip() and not line.lstrip().startswith("#")]
    if not values or len(values) > 32 or any(len(value) > 4096 for value in values):
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
        rows.append({
            "id": identity,
            "reachable": item.get("reachable"),
            "check_status": item.get("check_status"),
            "available": counts.get("available") if isinstance(counts, dict) else None,
            "reboot": item.get("reboot_required"),
            "error_code": (item.get("error") or {}).get("code")
                          if isinstance(item.get("error"), dict) else None,
            "update_state": (item.get("last_update") or {}).get("status")
                            if isinstance(item.get("last_update"), dict) else None,
        })
    rows.sort(key=lambda item: item["id"])
    return payload, rows


def atomic_save(path, data):
    parent = path.parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=parent,
                                         prefix=".apprise-state-", delete=False) as handle:
            tmp_path = Path(handle.name)
            os.fchmod(handle.fileno(), 0o600)
            # Apply the cap to the final persisted map, including a new event.
            json.dump(prune_delivery_state(data, time.time()), handle,
                      sort_keys=True, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
        tmp_path = None
    finally:
        if tmp_path and tmp_path.exists():
            tmp_path.unlink()


def deliver_one(url, title, message, state, timeout_seconds=None):
    """Process-isolate a provider, so a hung plugin cannot stall an update job."""
    request = json.dumps({"url": url, "title": title, "message": message, "state": state})
    try:
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), "--send-single"],
            input=request, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=DELIVERY_TIMEOUT_SECONDS if timeout_seconds is None else min(DELIVERY_TIMEOUT_SECONDS, timeout_seconds), check=False,
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def send_single():
    """Provider URL arrives on a private pipe, never argv, logs or source."""
    try:
        request = json.load(sys.stdin)
        import apprise  # optional runtime dependency; not imported when disabled
        logging.disable(logging.CRITICAL)
        client = apprise.Apprise()
        if not client.add(request["url"]):
            return 69
        notify_type = {
            "issues": apprise.NotifyType.WARNING,
            "updates": apprise.NotifyType.INFO,
            "current": apprise.NotifyType.SUCCESS,
        }.get(request["state"], apprise.NotifyType.INFO)
        return 0 if client.notify(body=request["message"], title=request["title"], notify_type=notify_type) else 69
    except (OSError, ValueError, TypeError, KeyError, ImportError, RuntimeError):
        return 69


def read_delivery_state(path):
    """Handle corrupted JSON by discarding stale dedupe, never disabling alerts."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return {}
    try:
        meta = os.fstat(descriptor)
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.geteuid()
                or meta.st_mode & 0o077 or meta.st_size > 1024 * 1024):
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
    """Retain only bounded, recent delivery identities, no provider URLs."""
    valid = {
        key: value for key, value in state_data.items()
        if isinstance(key, str) and isinstance(value, dict)
        and isinstance(value.get("updated_at"), (int, float))
        and 0 <= now - value["updated_at"] <= STATE_RETENTION_SECONDS
    }
    return dict(sorted(valid.items(), key=lambda item: item[1]["updated_at"], reverse=True)[:MAX_STATE_ENTRIES])


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("check", "update"))
    parser.add_argument("status_file")
    parser.add_argument("state", choices=("updates", "issues", "current", "empty"))
    parser.add_argument("run_started_at", nargs="?", default="")
    args = parser.parse_args(argv)
    urls_path = os.environ.get("UU_APPRISE_URLS_FILE")
    if not urls_path:
        return 0
    state_file = Path(os.environ.get("UU_APPRISE_STATE_FILE", STATE_DEFAULT))
    if not state_file.is_absolute():
        print("Apprise state path must be absolute.", file=sys.stderr)
        return 78
    try:
        urls = protected_lines(urls_path)
        scope = os.environ.get("UU_SINGLE_TARGET_ID", "") if os.environ.get("UU_SINGLE_TARGET") == "true" else ""
        payload, rows = read_status(args.status_file, scope)
        if args.state == "empty":
            return 0
        body = sys.stdin.read(32768)
        if not body.strip():
            raise ValueError("empty notification body")
        key = args.kind + ":" + (scope or "all")
        marker = {
            "kind": args.kind,
            "state": args.state,
            "targets": rows,
        }
        if args.kind == "update":
            marker["run_started_at"] = args.run_started_at or payload.get("generated_at")
        fingerprint = hashlib.sha256(
            json.dumps(marker, sort_keys=True, default=str, separators=(",", ":")).encode()
        ).hexdigest()
        state_file.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        # Separate stable inode lock protects atomic state replacements.
        lock_path = state_file.with_name(state_file.name + ".lock")
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            now = time.time()
            raw_state = read_delivery_state(state_file)
            previous = raw_state.get(key)
            if not isinstance(previous, dict):
                previous = None
            state_data = prune_delivery_state(raw_state, now)
            # Already accepted old-format states represent completed delivery.
            if previous and previous.get("fingerprint") == fingerprint and "delivered_providers" not in previous:
                return 0
            entry = state_data.get(key) if previous and previous.get("fingerprint") == fingerprint else None
            if entry is None:
                entry = {"fingerprint": fingerprint, "state": args.state,
                         "delivered_providers": [], "updated_at": now}
            # Do not send an initial all-clear; do report recovery transitions.
            if args.kind == "check" and args.state == "current" and (
                not previous or (previous.get("state") == "current"
                                 and previous.get("fingerprint") != fingerprint)
            ):
                entry["delivered_providers"] = [hashlib.sha256(url.encode()).hexdigest() for url in urls]
                entry["updated_at"] = now
                state_data[key] = entry
                atomic_save(state_file, state_data)
                return 0
            # A malformed provider list is recoverable state, not a reason to
            # permanently suppress notifications. Never trust stored values.
            saved_providers = entry.get("delivered_providers")
            delivered = (
                {item for item in saved_providers
                 if isinstance(item, str) and len(item) == 64
                 and all(c in "0123456789abcdef" for c in item)}
                if isinstance(saved_providers, list) else set()
            )
            entry["delivered_providers"] = sorted(delivered)
            failed = False
            deadline = time.monotonic() + DELIVERY_BUDGET_SECONDS
            for url in urls:
                provider_id = hashlib.sha256(url.encode()).hexdigest()
                if provider_id in delivered:
                    continue
                remaining = deadline - time.monotonic()
                if remaining > 0 and deliver_one(url, "Ultimate Updater " + args.kind,
                                                 body, args.state, timeout_seconds=remaining):
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
        # No raw URL, provider exception, credential or notification body is logged.
        print("Apprise notification unavailable.", file=sys.stderr)
        return 69


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--send-single":
        raise SystemExit(send_single())
    raise SystemExit(main())

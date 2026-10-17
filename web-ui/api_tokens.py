#!/usr/bin/env python3
"""Small, fail-closed token store for the read-only integration API.

The file contains token metadata and SHA-256 digests only.  Token creation
prints the secret once for the local administrator; normal reads never do.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import stat
import tempfile


CONFIG_VERSION = 1
SUPPORTED_PERMISSIONS = frozenset({"read", "logs"})
TOKEN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
TOKEN_HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")


class TokenConfigError(ValueError):
    """The token configuration is unsafe or malformed."""


def hash_token(token):
    if not isinstance(token, str) or not TOKEN_RE.fullmatch(token):
        raise ValueError("Token has an invalid format.")
    return "sha256:" + hashlib.sha256(token.encode("utf-8")).hexdigest()


def _parse_expiry(value):
    if value is None:
        return None
    if not isinstance(value, str) or not value or len(value) > 64:
        raise TokenConfigError("expires_at must be an ISO-8601 timestamp or null.")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise TokenConfigError("expires_at is invalid.") from error
    if parsed.tzinfo is None:
        raise TokenConfigError("expires_at must include a timezone.")
    return parsed.astimezone(timezone.utc)


def _validate_token_record(record):
    if not isinstance(record, dict):
        raise TokenConfigError("A token record is invalid.")
    token_id = record.get("id")
    name = record.get("name")
    digest = record.get("hash")
    permissions = record.get("permissions")
    if (not isinstance(token_id, str) or not TOKEN_ID_RE.fullmatch(token_id)
            or not isinstance(name, str) or not 1 <= len(name) <= 80
            or any(ord(char) < 0x20 or ord(char) == 0x7f for char in name)
            or not isinstance(digest, str) or not TOKEN_HASH_RE.fullmatch(digest)
            or not isinstance(permissions, list) or not permissions
            or any(permission not in SUPPORTED_PERMISSIONS for permission in permissions)
            or ("logs" in permissions and "read" not in permissions)
            or len(set(permissions)) != len(permissions)
            or not isinstance(record.get("revoked", False), bool)):
        raise TokenConfigError("A token record is invalid.")
    _parse_expiry(record.get("expires_at"))
    return {
        "id": token_id,
        "name": name,
        "hash": digest,
        "permissions": list(permissions),
        "expires_at": record.get("expires_at"),
        "revoked": record.get("revoked", False),
    }


def _check_file(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise TokenConfigError("The token configuration cannot be inspected.") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise TokenConfigError("The token configuration must be a regular file.")
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise TokenConfigError("The token configuration ownership or permissions are unsafe.")
    if info.st_size > 128 * 1024:
        raise TokenConfigError("The token configuration is too large.")
    return info


def load_config(path):
    """Load a validated config. Missing configuration means disabled API."""
    path = Path(path)
    if _check_file(path) is None:
        return {"version": CONFIG_VERSION, "enabled": False, "tokens": []}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise TokenConfigError("The token configuration is invalid.") from error
    if (not isinstance(data, dict) or data.get("version") != CONFIG_VERSION
            or not isinstance(data.get("enabled"), bool)
            or not isinstance(data.get("tokens"), list)):
        raise TokenConfigError("The token configuration schema is invalid.")
    records = [_validate_token_record(record) for record in data["tokens"]]
    ids = [record["id"] for record in records]
    hashes = [record["hash"] for record in records]
    if len(set(ids)) != len(ids) or len(set(hashes)) != len(hashes):
        raise TokenConfigError("The token configuration contains duplicates.")
    return {"version": CONFIG_VERSION, "enabled": data["enabled"], "tokens": records}


def authenticate(path, token):
    """Return public token metadata or None; never return the token itself."""
    config = load_config(path)
    if not config["enabled"]:
        return None
    digest = hash_token(token)
    now = datetime.now(timezone.utc)
    for record in config["tokens"]:
        if record["revoked"] or (record["expires_at"] and _parse_expiry(record["expires_at"]) <= now):
            continue
        if hmac.compare_digest(record["hash"], digest):
            return {key: record[key] for key in ("id", "name", "permissions", "expires_at")}
    return None


def _write_config(path, data):
    path = Path(path)
    if path.exists() or path.is_symlink():
        _check_file(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(data, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as target:
            descriptor = None
            target.write(encoded)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _base_config(path):
    config = load_config(path)
    return {"version": CONFIG_VERSION, "enabled": config["enabled"], "tokens": config["tokens"]}


def set_enabled(path, enabled):
    config = _base_config(path)
    config["enabled"] = bool(enabled)
    _write_config(path, config)


def create_token(path, name, permissions, expires_at=None):
    if not isinstance(name, str) or not 1 <= len(name) <= 80 or any(ord(char) < 0x20 or ord(char) == 0x7f for char in name):
        raise ValueError("Name must be 1-80 characters without control characters.")
    if (not permissions or any(permission not in SUPPORTED_PERMISSIONS for permission in permissions)
            or ("logs" in permissions and "read" not in permissions)):
        raise ValueError("Only read and logs permissions are supported by API v1.")
    if len(set(permissions)) != len(permissions):
        raise ValueError("Permissions must be unique.")
    if expires_at is not None:
        _parse_expiry(expires_at)
    config = _base_config(path)
    token = secrets.token_urlsafe(32)
    record = {
        "id": secrets.token_hex(12),
        "name": name,
        "hash": hash_token(token),
        "permissions": list(permissions),
        "expires_at": expires_at,
        "revoked": False,
    }
    config["tokens"].append(record)
    _write_config(path, config)
    return record["id"], token


def revoke_token(path, token_id):
    config = _base_config(path)
    if not TOKEN_ID_RE.fullmatch(token_id):
        raise ValueError("Token ID is invalid.")
    for record in config["tokens"]:
        if record["id"] == token_id:
            record["revoked"] = True
            _write_config(path, config)
            return
    raise KeyError(token_id)


def _parser():
    parser = argparse.ArgumentParser(description="Manage Ultimate Updater API v1 bearer tokens.")
    parser.add_argument("--token-file", type=Path, default=Path("/etc/ultimate-updater/api-tokens.json"))
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("enable")
    commands.add_parser("disable")
    create = commands.add_parser("create")
    create.add_argument("name")
    create.add_argument("--permissions", default="read")
    create.add_argument("--expires-at")
    commands.add_parser("list")
    revoke = commands.add_parser("revoke")
    revoke.add_argument("token_id")
    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    try:
        if args.command == "enable":
            set_enabled(args.token_file, True)
            print("API v1 enabled.")
        elif args.command == "disable":
            set_enabled(args.token_file, False)
            print("API v1 disabled.")
        elif args.command == "list":
            config = load_config(args.token_file)
            print(json.dumps({"enabled": config["enabled"], "tokens": [
                {key: record[key] for key in ("id", "name", "permissions", "expires_at", "revoked")}
                for record in config["tokens"]
            ]}, indent=2, sort_keys=True))
        elif args.command == "create":
            permissions = [item.strip() for item in args.permissions.split(",") if item.strip()]
            token_id, token = create_token(args.token_file, args.name, permissions, args.expires_at)
            print(f"token_id={token_id}")
            print(f"token={token}")
            print("Store this token now; it will not be displayed again.")
        elif args.command == "revoke":
            revoke_token(args.token_file, args.token_id)
            print(f"Token {args.token_id} revoked.")
    except (OSError, TokenConfigError, ValueError, KeyError) as error:
        print(f"api-token: {error}", file=__import__("sys").stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Emit deterministic RPM update counts from a package query."""

import shutil
import subprocess
import sys


QUERY_FORMAT = "%{name}\t%{arch}\t%{repoid}"


def main():
    manager = next((name for name in ("dnf5", "dnf", "yum") if shutil.which(name)), None)
    if manager is None:
        print("UU_RPM_COUNTS|unknown|unknown|unknown|false")
        return 2

    command = [
        manager,
        "--cacheonly",
        "repoquery",
        "--available",
        "--upgrades",
        "--qf",
        QUERY_FORMAT,
    ]
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="strict",
        )
    except (OSError, UnicodeError):
        print("UU_RPM_COUNTS|unknown|unknown|unknown|false")
        return 2
    if result.returncode != 0:
        print("UU_RPM_COUNTS|unknown|unknown|unknown|false")
        return 2

    packages = set()
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) != 3 or not all(fields):
            print("UU_RPM_COUNTS|unknown|unknown|unknown|false")
            return 2
        packages.add((fields[0], fields[1]))

    # Current status-model semantics expose RPM systems as total-only.  The
    # advisory/security split remains unknown until a structured updateinfo
    # API is available on the target; never infer it from repo names or text.
    print(f"UU_RPM_COUNTS|ok|{len(packages)}|null|null|false")
    return 0


if __name__ == "__main__":
    sys.exit(main())

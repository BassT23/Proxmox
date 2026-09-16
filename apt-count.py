#!/usr/bin/env python3
"""Emit deterministic APT update counts from python-apt metadata."""

import sys


def main():
    try:
        import apt
    except ImportError:
        print("APT_COUNTS|unknown|unknown|unknown|false")
        return 2

    try:
        cache = apt.Cache()
        total = normal = security = 0
        for package in cache:
            if not package.is_upgradable:
                continue
            candidate = package.candidate
            origins = list(candidate.origins) if candidate is not None else []
            if not origins:
                print("APT_COUNTS|unknown|unknown|unknown|false")
                return 2
            known_origin = False
            is_security = False
            for origin in origins:
                fields = (
                    getattr(origin, "origin", ""),
                    getattr(origin, "archive", ""),
                    getattr(origin, "codename", ""),
                    getattr(origin, "label", ""),
                    getattr(origin, "site", ""),
                    getattr(origin, "component", ""),
                )
                values = [str(value or "").strip() for value in fields]
                if any(values):
                    known_origin = True
                if any("security" in value.lower() for value in values):
                    is_security = True
            if not known_origin:
                print("APT_COUNTS|unknown|unknown|unknown|false")
                return 2
            total += 1
            if is_security:
                security += 1
            else:
                normal += 1
    except Exception as error:  # pragma: no cover - exercised on target hosts
        print(f"APT_COUNTS|unknown|unknown|unknown|false|{type(error).__name__}")
        return 2

    print(f"APT_COUNTS|{total}|{normal}|{security}|true")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Filter preview tests using the repository's resolver contract."""

import stat
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


payload = {"generated_at": "now", "targets": [
    {"id": "host:Proxmox-Test-1", "type": "host", "name": "Proxmox-Test-1", "reachable": True},
    {"id": "910", "type": "lxc", "name": "debian", "reachable": True},
    {"id": "917", "type": "lxc", "name": "cent", "reachable": False},
    {"id": "mediacenter", "type": "external", "name": "Mediacenter", "reachable": True},
    {"id": "ct927", "type": "external", "name": "ct927", "reachable": True},
]}
inventory = [
    {"id": "mediacenter", "transport": "ssh"},
    {"id": "legacy-971", "transport": "ssh"},
]

with tempfile.TemporaryDirectory() as directory:
    resolver = Path(directory) / "tag-filter.sh"
    resolver.write_text(
        """#!/bin/bash
apply_only_exclude_tags() {
  local eligible=" ${UU_FILTER_ELIGIBLE_IDS:-} "
  if [[ "$ONLY" == selected && "$eligible" == *" 910 "* ]]; then
    ONLY="910"
  else
    ONLY=""
  fi
}
""",
        encoding="utf-8",
    )
    resolver.chmod(resolver.stat().st_mode | stat.S_IXUSR)

    base = {"ONLY_UPDATE_CHECK": "", "EXCLUDE_UPDATE_CHECK": ""}
    no_filter = server.target_preview(payload, base, resolver, inventory)
    assert no_filter["effective_count"] == len(no_filter["included"])
    assert [item["label"] for item in no_filter["included"]] == [
        "Proxmox-Test-1", "910 · debian", "917 · cent · offline", "Mediacenter", "legacy-971"
    ], no_filter
    assert not any("ct927" in item["label"] for item in no_filter["included"])

    missing = server.target_preview(payload, {}, resolver, inventory)
    assert missing["mode"] == "none" and missing["included"] == no_filter["included"]

    only = server.target_preview(payload, {**base, "ONLY_UPDATE_CHECK": "selected"}, resolver, inventory)
    assert only["mode"] == "only"
    assert only["effective_count"] == len(only["included"])
    assert [item["label"] for item in only["included"]] == ["Proxmox-Test-1", "910 · debian"]
    assert [item["label"] for item in only["excluded"]] == ["917 · cent · offline", "Mediacenter", "legacy-971"]

    both = server.target_preview(payload, {"ONLY_UPDATE_CHECK": "selected", "EXCLUDE_UPDATE_CHECK": "910"}, resolver, inventory)
    assert both["mode"] == "only"
    assert both["effective_count"] == len(both["included"])
    assert [item["label"] for item in both["included"]] == ["Proxmox-Test-1"]

    zero = server.target_preview(payload, {**base, "ONLY_UPDATE_CHECK": "missing"}, resolver, inventory)
    assert zero["mode"] == "none"
    assert zero["only_matches"] == 0
    assert zero["effective_selection"] == "all-eligible"
    assert len(zero["included"]) == len(no_filter["included"])

    exclude = server.target_preview(payload, {**base, "EXCLUDE_UPDATE_CHECK": "917"}, resolver, inventory)
    assert exclude["mode"] == "exclude"
    assert [item["label"] for item in exclude["excluded"]] == ["917 · cent · offline"]

    unknown = server.target_preview(payload, {**base, "ONLY_UPDATE_CHECK": "999"}, resolver, inventory)
    assert "999" in unknown["unknown"]
    assert unknown["only_unknown"] == ["999"]
    assert unknown["exclude_unknown"] == []

    only_zero_exclude_match = server.target_preview(
        payload, {**base, "ONLY_UPDATE_CHECK": "missing", "EXCLUDE_UPDATE_CHECK": "917"}, resolver, inventory,
    )
    assert only_zero_exclude_match["effective_selection"] == "all-eligible"
    assert only_zero_exclude_match["only_unknown"] == ["missing"]
    assert only_zero_exclude_match["exclude_unknown"] == []
    assert [item["label"] for item in only_zero_exclude_match["excluded"]] == ["917 · cent · offline"]

    exclude_missing = server.target_preview(
        payload, {**base, "EXCLUDE_UPDATE_CHECK": "missing-exclude"}, resolver, inventory,
    )
    assert exclude_missing["only_unknown"] == []
    assert exclude_missing["exclude_unknown"] == ["missing-exclude"]

    update_base = {"ONLY": "", "EXCLUDE": ""}
    update_only = server.target_preview(payload, {**update_base, "ONLY": "selected"}, resolver, inventory,
                                         filter_keys=("ONLY", "EXCLUDE"))
    assert update_only["mode"] == "only"
    assert update_only["effective_count"] == len(update_only["included"])
    assert [item["label"] for item in update_only["included"]] == [
        "Proxmox-Test-1", "910 · debian"
    ]
    update_zero = server.target_preview(payload, {**update_base, "ONLY": "missing"}, resolver, inventory,
                                         filter_keys=("ONLY", "EXCLUDE"))
    assert update_zero["mode"] == "none"
    assert update_zero["only_matches"] == 0
    assert len(update_zero["included"]) == len(no_filter["included"])
    update_exclude = server.target_preview(payload, {**update_base, "EXCLUDE": "917"}, resolver, inventory,
                                            filter_keys=("ONLY", "EXCLUDE"))
    assert update_exclude["mode"] == "exclude"
    assert update_exclude["effective_count"] == len(update_exclude["included"])
    assert [item["label"] for item in update_exclude["excluded"]] == ["917 · cent · offline"]

    update_missing = server.target_preview(payload, {}, resolver, inventory,
                                           filter_keys=("ONLY", "EXCLUDE"))
    assert update_missing["mode"] == "none"

    internal_base = {
        "USE_INTERNAL_TARGET_SELECTION": True,
        "CHECK_WITH_HOST": "true", "CHECK_WITH_LXC": "true", "CHECK_WITH_VM": "true",
        "CHECK_RUNNING_CONTAINER": "true", "CHECK_STOPPED_CONTAINER": "true",
        "CHECK_RUNNING_VM": "true", "CHECK_STOPPED_VM": "true", "CHECK_PAUSED_VM": "true",
        "WITH_HOST": "true", "WITH_LXC": "true", "WITH_VM": "true",
        "RUNNING_CONTAINER": "true", "STOPPED_CONTAINER": "true",
        "RUNNING_VM": "true", "STOPPED_VM": "true",
    }
    internal_default = server.target_preview(
        payload, internal_base, resolver, inventory,
        internal_selection={"check": {}, "update": {}},
    )
    assert internal_default["effective_selection"] == "all-eligible"
    assert internal_default["effective_count"] == len(internal_default["included"])

    stale_internal = server.target_preview(
        payload, internal_base, resolver, inventory,
        internal_selection={"check": {"999": "only"}, "update": {}},
    )
    assert stale_internal["mode"] == "internal-all"
    assert stale_internal["effective_selection"] == "all-eligible"
    assert stale_internal["only_matches"] == 0
    assert stale_internal["effective_count"] == internal_default["effective_count"]

    internal_only = server.target_preview(
        payload, internal_base, resolver, inventory,
        internal_selection={"check": {"910": "only"}, "update": {}},
    )
    assert internal_only["mode"] == "internal-only"
    assert internal_only["effective_selection"] == "only-matches"
    assert internal_only["only_matches"] == 1
    assert internal_only["effective_count"] == 1

    internal_exclude = server.target_preview(
        payload, internal_base, resolver, inventory,
        internal_selection={"check": {"917": "exclude"}, "update": {}},
    )
    assert internal_exclude["mode"] == "internal-exclude"
    assert internal_exclude["effective_count"] == internal_default["effective_count"] - 1

    scoped_payload = {**payload, "targets": [*payload["targets"],
        {"id": "918", "type": "lxc", "name": "stopped", "status": "stopped", "reachable": True}]}
    check_scoped = server.target_preview(
        scoped_payload, {**internal_base, "CHECK_STOPPED_CONTAINER": "false"}, resolver, inventory,
        internal_selection={"check": {}, "update": {}},
    )
    update_scoped = server.target_preview(
        scoped_payload, internal_base, resolver, inventory,
        filter_keys=("ONLY", "EXCLUDE"),
        internal_selection={"check": {}, "update": {}},
    )
    assert check_scoped["effective_count"] + 1 == update_scoped["effective_count"]

print("filter preview tests: PASS")

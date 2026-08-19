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
    assert [item["label"] for item in no_filter["included"]] == [
        "Proxmox-Test-1", "910 · debian", "917 · cent · offline", "Mediacenter", "legacy-971"
    ], no_filter
    assert not any("ct927" in item["label"] for item in no_filter["included"])

    missing = server.target_preview(payload, {}, resolver, inventory)
    assert missing["mode"] == "none" and missing["included"] == no_filter["included"]

    only = server.target_preview(payload, {**base, "ONLY_UPDATE_CHECK": "selected"}, resolver, inventory)
    assert only["mode"] == "only"
    assert [item["label"] for item in only["included"]] == ["Proxmox-Test-1", "910 · debian"]
    assert [item["label"] for item in only["excluded"]] == ["917 · cent · offline", "Mediacenter", "legacy-971"]

    both = server.target_preview(payload, {"ONLY_UPDATE_CHECK": "selected", "EXCLUDE_UPDATE_CHECK": "910"}, resolver, inventory)
    assert both["mode"] == "only"
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

    update_base = {"ONLY": "", "EXCLUDE": ""}
    update_only = server.target_preview(payload, {**update_base, "ONLY": "selected"}, resolver, inventory,
                                         filter_keys=("ONLY", "EXCLUDE"))
    assert update_only["mode"] == "only"
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
    assert [item["label"] for item in update_exclude["excluded"]] == ["917 · cent · offline"]

    update_missing = server.target_preview(payload, {}, resolver, inventory,
                                           filter_keys=("ONLY", "EXCLUDE"))
    assert update_missing["mode"] == "none"

print("filter preview tests: PASS")

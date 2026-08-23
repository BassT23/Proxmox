#!/usr/bin/env bash
# shellcheck disable=SC2034

# Execute a QEMU Guest Agent command through the explicit asynchronous
# guest-exec/guest-exec-status contract.  Keeping this in one helper avoids
# subtly different PID handling between checks and updates.

QEMU_GUEST_EXEC () {
  QEMU_EXEC_STDOUT=""
  QEMU_EXEC_STDERR=""
  QEMU_EXEC_OUTPUT=""
  QEMU_EXEC_EXITCODE=""
  QEMU_EXEC_TRANSPORT_RC=0
  QEMU_EXEC_ERROR_CLASS=""

  local vmid="${1:-}" raw start_rc pid parsed timeout=30 deadline
  shift || true
  [[ "$vmid" =~ ^[0-9]+$ ]] || {
    QEMU_EXEC_ERROR_CLASS=QGA_GUEST_EXEC
    QEMU_EXEC_OUTPUT="QEMU guest-exec requires a numeric VMID"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  }

  # Preserve the existing qm timeout option as the polling deadline.  A
  # timeout of zero retains qm's documented unlimited-wait semantics.
  local -a exec_args=(--synchronous 0)
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --timeout && $# -ge 2 ]]; then
      timeout="$2"
    elif [[ "$1" == --timeout=* ]]; then
      timeout="${1#*=}"
    fi
    exec_args+=("$1")
    shift
  done
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=30

  raw=$(qm guest exec "$vmid" "${exec_args[@]}" 2>&1)
  start_rc=$?
  if [[ $start_rc -ne 0 ]]; then
    QEMU_EXEC_ERROR_CLASS=QGA_GUEST_EXEC
    QEMU_EXEC_STDERR="$raw"
    QEMU_EXEC_OUTPUT="$raw"
    QEMU_EXEC_TRANSPORT_RC=$start_rc
    return 0
  fi

  if ! pid=$(printf '%s' "$raw" | python3 -c '
import json
import sys

raw = sys.stdin.read()
objects = []
try:
    objects.append(json.loads(raw))
except (TypeError, ValueError):
    pass
for line in raw.splitlines():
    try:
        objects.append(json.loads(line))
    except (TypeError, ValueError):
        continue
for obj in objects:
    value = obj.get("pid") if isinstance(obj, dict) else None
    if isinstance(value, int) and not isinstance(value, bool) and value > 0:
        print(value)
        raise SystemExit(0)
raise SystemExit(1)
'); then
    QEMU_EXEC_ERROR_CLASS=QGA_INVALID_PID
    QEMU_EXEC_STDERR="$raw"
    QEMU_EXEC_OUTPUT="QGA guest-exec did not return a valid PID"
    [[ -n "$raw" ]] && QEMU_EXEC_OUTPUT+=" ($raw)"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  fi
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
    QEMU_EXEC_ERROR_CLASS=QGA_INVALID_PID
    QEMU_EXEC_OUTPUT="QGA guest-exec did not return a valid PID"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  fi

  if [[ "$timeout" -gt 0 ]]; then
    deadline=$((SECONDS + timeout))
  else
    deadline=0
  fi
  while :; do
    raw=$(qm guest exec-status "$vmid" "$pid" 2>&1)
    start_rc=$?
    if [[ $start_rc -ne 0 ]]; then
      QEMU_EXEC_ERROR_CLASS=QGA_GUEST_EXEC_STATUS
      QEMU_EXEC_STDERR="$raw"
      QEMU_EXEC_OUTPUT="$raw"
      QEMU_EXEC_TRANSPORT_RC=$start_rc
      return 0
    fi

    if parsed=$(printf '%s' "$raw" | python3 -c '
import base64
import json
import sys

raw = sys.stdin.read()
objects = []
try:
    objects.append(json.loads(raw))
except (TypeError, ValueError):
    pass
for line in raw.splitlines():
    try:
        objects.append(json.loads(line))
    except (TypeError, ValueError):
        continue
response = next((obj for obj in objects if isinstance(obj, dict) and
                 ("exited" in obj or "exitcode" in obj or
                  "out-data" in obj or "err-data" in obj)), None)
if response is None:
    raise SystemExit(1)
exited = response.get("exited")
if exited is False or exited == 0:
    print("RUNNING")
    raise SystemExit(0)
if exited is not True and exited != 1 and "exitcode" not in response:
    raise SystemExit(1)
exitcode = response.get("exitcode", 0)
if not isinstance(exitcode, int) or isinstance(exitcode, bool) or exitcode < 0:
    raise SystemExit(1)
for key in ("out-data", "err-data"):
    value = response.get(key, "")
    if not isinstance(value, str):
        value = str(value)
    # The qm JSON representation contains decoded text; encode it only for the
    # shell transport so arbitrary newlines do not change field boundaries.
    print(base64.b64encode(value.encode()).decode())
print(exitcode)
'); then
      if [[ "$parsed" == RUNNING ]]; then
        :
      else
        local -a fields
        mapfile -t fields <<< "$parsed"
        if [[ ${#fields[@]} -eq 3 && ${fields[2]} =~ ^[0-9]+$ ]]; then
          IFS= read -r -d '' QEMU_EXEC_STDOUT < <(printf '%s' "${fields[0]}" | base64 -d) || true
          IFS= read -r -d '' QEMU_EXEC_STDERR < <(printf '%s' "${fields[1]}" | base64 -d) || true
          QEMU_EXEC_EXITCODE="${fields[2]}"
          if [[ -n "$QEMU_EXEC_STDOUT" && -n "$QEMU_EXEC_STDERR" ]]; then
            QEMU_EXEC_OUTPUT="${QEMU_EXEC_STDOUT}
${QEMU_EXEC_STDERR}"
          else
            QEMU_EXEC_OUTPUT="${QEMU_EXEC_STDOUT}${QEMU_EXEC_STDERR}"
          fi
          return 0
        fi
        QEMU_EXEC_ERROR_CLASS=QGA_GUEST_EXEC_STATUS
        QEMU_EXEC_OUTPUT="Invalid guest-exec-status response"
        QEMU_EXEC_TRANSPORT_RC=1
        return 0
      fi
    else
      QEMU_EXEC_ERROR_CLASS=QGA_GUEST_EXEC_STATUS
      QEMU_EXEC_STDERR="$raw"
      QEMU_EXEC_OUTPUT="Invalid guest-exec-status response"
      [[ -n "$raw" ]] && QEMU_EXEC_OUTPUT+=" ($raw)"
      QEMU_EXEC_TRANSPORT_RC=1
      return 0
    fi

    if [[ "$deadline" -gt 0 && "$SECONDS" -ge "$deadline" ]]; then
      QEMU_EXEC_ERROR_CLASS=QGA_TIMEOUT
      QEMU_EXEC_OUTPUT="QEMU guest-exec timed out after ${timeout}s"
      QEMU_EXEC_TRANSPORT_RC=1
      return 0
    fi
    sleep 1
  done
}

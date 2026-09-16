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
      shift 2
      continue
    elif [[ "$1" == --timeout=* ]]; then
      timeout="${1#*=}"
      shift
      continue
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

# Run a guest command in a transient systemd job whose lifetime is independent
# of qemu-ga.  This is intended for package-manager operations: qemu-ga may be
# restarted when qemu-guest-agent itself is upgraded, invalidating the
# guest-exec PID while the actual guest job is still running.
QEMU_GUEST_EXEC_DURABLE () {
  QEMU_EXEC_STDOUT=""
  QEMU_EXEC_STDERR=""
  QEMU_EXEC_OUTPUT=""
  QEMU_EXEC_EXITCODE=""
  QEMU_EXEC_TRANSPORT_RC=0
  QEMU_EXEC_ERROR_CLASS=""

  local vmid="${1:-}" raw start_rc timeout=120 deadline token unit script output rc
  shift || true
  [[ "$vmid" =~ ^[0-9]+$ ]] || {
    QEMU_EXEC_ERROR_CLASS=QGA_GUEST_EXEC
    QEMU_EXEC_OUTPUT="QEMU durable guest-exec requires a numeric VMID"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  }
  local -a command_args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --timeout && $# -ge 2 ]]; then
      timeout="$2"
      shift 2
      continue
    elif [[ "$1" == --timeout=* ]]; then
      timeout="${1#*=}"
      shift
      continue
    fi
    [[ "$1" == -- ]] || command_args+=("$1")
    shift
  done
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=120
  [[ ${#command_args[@]} -gt 0 ]] || {
    QEMU_EXEC_ERROR_CLASS=QGA_GUEST_EXEC
    QEMU_EXEC_OUTPUT="QEMU durable guest-exec requires a command"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  }

  token="ultimate-updater-qga-${vmid}-$$-${RANDOM}"
  unit="${token}.service"
  script="/run/${token}.sh"
  output="/run/${token}.output"
  rc="/run/${token}.rc"
  local command_line
  printf -v command_line '%q ' "${command_args[@]}"
  local script_body
  script_body=$(printf '%s\n' \
    '#!/bin/sh' \
    'set +e' \
    "exec >$(printf '%q' "$output") 2>&1" \
    "$command_line" \
    'result=$?' \
    "printf '%s\\n' \"\$result\" >$(printf '%q' "$rc")" \
    "exit \"\$result\"")
  local encoded_script
  encoded_script=$(printf '%s' "$script_body" | base64 -w0) || {
    QEMU_EXEC_ERROR_CLASS=QGA_GUEST_EXEC
    QEMU_EXEC_OUTPUT="Could not prepare durable guest-exec script"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  }

  QEMU_GUEST_EXEC "$vmid" --timeout 15 -- bash -c \
    "printf '%s' '$encoded_script' | base64 -d > '$script' && chmod 600 '$script' && systemd-run --unit='$unit' --collect --no-block /bin/sh '$script' >/dev/null"
  if [[ "$QEMU_EXEC_TRANSPORT_RC" -ne 0 || "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
    QEMU_EXEC_ERROR_CLASS=${QEMU_EXEC_ERROR_CLASS:-QGA_GUEST_EXEC}
    QEMU_EXEC_OUTPUT="Could not start durable guest update job: ${QEMU_EXEC_OUTPUT}"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  fi

  deadline=$((SECONDS + timeout))
  while :; do
    QEMU_GUEST_EXEC "$vmid" --timeout 15 -- bash -c \
      "if [ -r '$rc' ]; then cat '$output' 2>/dev/null; printf '\\n__UU_GUEST_EXIT__'; cat '$rc'; else exit 75; fi"
    if [[ "$QEMU_EXEC_TRANSPORT_RC" -ne 0 ]]; then
      # A transient QGA restart must not be confused with failure of the
      # already detached package-manager job.  The next poll is safe because
      # it only reads the durable status files.
      if [[ "$QEMU_EXEC_ERROR_CLASS" == QGA_INVALID_PID ||
        "$QEMU_EXEC_ERROR_CLASS" == QGA_GUEST_EXEC_STATUS ||
        "$QEMU_EXEC_ERROR_CLASS" == QGA_GUEST_EXEC ]]; then
        [[ "$deadline" -gt 0 && "$SECONDS" -ge "$deadline" ]] && break
        sleep 1
        continue
      fi
      break
    fi
    if [[ "$QEMU_EXEC_EXITCODE" -eq 75 ]]; then
      [[ "$deadline" -gt 0 && "$SECONDS" -ge "$deadline" ]] && break
      sleep 1
      continue
    fi
    if [[ "$QEMU_EXEC_EXITCODE" -eq 0 && "$QEMU_EXEC_STDOUT" == *__UU_GUEST_EXIT__* ]]; then
      local marker='__UU_GUEST_EXIT__' result_text result_code final_stdout final_output final_exitcode
      result_text="${QEMU_EXEC_STDOUT%%"$marker"*}"
      result_code="${QEMU_EXEC_STDOUT##*"$marker"}"
      result_code="${result_code//$'\n'/}"
      if [[ "$result_code" =~ ^[0-9]+$ ]]; then
        final_stdout="$result_text"
        final_output="$result_text"
        final_exitcode="$result_code"
        QEMU_EXEC_TRANSPORT_RC=0
        QEMU_GUEST_EXEC "$vmid" --timeout 15 -- bash -c "rm -f '$script' '$output' '$rc'" >/dev/null 2>&1 || true
        QEMU_EXEC_STDOUT="$final_stdout"
        QEMU_EXEC_STDERR=""
        QEMU_EXEC_OUTPUT="$final_output"
        QEMU_EXEC_EXITCODE="$final_exitcode"
        return 0
      fi
    fi
    QEMU_EXEC_ERROR_CLASS=QGA_GUEST_EXEC_STATUS
    QEMU_EXEC_OUTPUT="Invalid durable guest-job status"
    QEMU_EXEC_TRANSPORT_RC=1
    break
  done
  QEMU_EXEC_ERROR_CLASS=QGA_TIMEOUT
  QEMU_EXEC_OUTPUT="Durable guest update job did not finish within ${timeout}s; it was not terminated"
  QEMU_EXEC_TRANSPORT_RC=1
  return 0
}

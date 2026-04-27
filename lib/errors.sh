#!/bin/bash

##############
# Errors Lib #
##############

_ERROR_LIST=()

log_error() {
  local id="${1:-}" name="${2:-}" code="${3:-}" msg="${4:-}"
  _ERROR_LIST+=("[$id] ${name} — exit ${code}")
  {
    echo "${id} : ${name}"
    echo "Error code:   ${code}"
    [[ -n "$msg" ]] && echo "Error output: ${msg}"
    echo ""
  } >> "${ERROR_LOG_FILE:-/var/log/ultimate-updater-error.log}" 2>/dev/null || true
}

has_errors() {
  [[ ${#_ERROR_LIST[@]} -gt 0 ]]
}

ERROR_LOGGING() {
  touch "${ERROR_LOG_FILE}"
  true > "${ERROR_LOG_FILE}"
}

CLEAN_LOGFILE() {
  if [[ "${RICM:-false}" != true ]]; then
    local tmp="${LOG_FILE}.tmp"
    tail -n +2 "${LOG_FILE}" > "${tmp}" && mv "${tmp}" "${LOG_FILE}"
    sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" "${LOG_FILE}" > "${tmp}" && mv "${tmp}" "${LOG_FILE}"
    chmod 640 "${LOG_FILE}"
    rm -f "${tmp}"
  fi
}

EXIT() {
  local exit_code=$?
  local exec_host=""

  if [[ -f "/etc/ultimate-updater/temp/exec_host" ]]; then
    exec_host=$(awk -F'"' '/^EXEC_HOST=/ {print $2}' /etc/ultimate-updater/temp/exec_host)
  fi

  if [[ "${WELCOME_SCREEN:-false}" == true && -n "$exec_host" ]]; then
    scp "${LOCAL_FILES}/check-output" "${exec_host}:${LOCAL_FILES}/check-output" 2>/dev/null || true
  fi

  # Exit code 2 = clean early exit (help, version, uninstall, etc.)
  [[ "$exit_code" == 2 ]] && exit 0

  if [[ "${RICM:-false}" != true ]]; then
    if [[ "$exit_code" == 0 ]]; then
      if [[ -f "${ERROR_LOG_FILE}" ]] && [[ -s "${ERROR_LOG_FILE}" ]]; then
        echo -e "${OR}❌ Finished with errors.${CL}\n"
        echo "See: ${ERROR_LOG_FILE}"
        echo
        CLEAN_LOGFILE
        mail -s "Ultimate Updater summary - ${HOSTNAME}" "${EMAIL_USER:-root}" < "${ERROR_LOG_FILE}" 2>/dev/null || true
      else
        echo -e "${GN}✅ All updates done.${CL}\n"
        "${LOCAL_FILES}/exit/passed.sh"
        CLEAN_LOGFILE
        if [[ "${EMAIL_NO_UPDATES:-false}" == true ]]; then
          echo "All updates done. No errors." | mail -s "Ultimate Updater" "${EMAIL_USER:-root}" 2>/dev/null || true
        fi
      fi
    else
      echo -e "${RD}⚠  Error during update — exit ${exit_code}${CL}\n"
      "${LOCAL_FILES}/exit/error.sh"
      CLEAN_LOGFILE
      mail -s "Ultimate Updater summary - ${HOSTNAME}" "${EMAIL_USER:-root}" < "${LOG_FILE}" 2>/dev/null || true
    fi
  fi

  sleep 2
  rm -f /etc/ultimate-updater/temp/var
  rm -f "${LOCAL_FILES}/update"
  if [[ -f "/etc/ultimate-updater/temp/exec_host" && "${HOSTNAME}" != "${exec_host}" ]]; then
    rm -rf "${LOCAL_FILES}"
  fi
}

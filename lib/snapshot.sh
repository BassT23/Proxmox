#!/bin/bash

################
# Snapshot Lib #
################

CONTAINER_BACKUP() {
  if [[ "${SNAPSHOT:-false}" != true && "${BACKUP:-false}" != true ]]; then
    ui_skip "Snapshot and backup disabled"
    return 0
  fi

  if [[ "${SNAPSHOT:-false}" == true ]]; then
    local snap_name="Update_$(date '+%Y%m%d_%H%M%S')"
    if pct snapshot "${CONTAINER}" "${snap_name}" &>/dev/null; then
      ui_ok "Snapshot created"
      local old_snaps
      old_snaps=$(pct listsnapshot "${CONTAINER}" | sed -n "s/^.*Update\s*\(\S*\).*$/\1/p" | head -n -"${KEEP_SNAPSHOT:-3}")
      for snap in $old_snaps; do
        pct delsnapshot "${CONTAINER}" "Update${snap}" >/dev/null 2>&1 || true
      done
    else
      ui_error "Snapshot failed"
      if [[ "${BACKUP_LXC_MP:-true}" == true ]] && pct config "${CONTAINER}" | grep -q '^mp'; then
        ui_info "Falling back to backup (mount points detected)"
        BACKUP=true
        SNAPSHOT=false
        _BACKUP_RESET=true
      fi
    fi
  fi

  if [[ "${BACKUP:-false}" == true ]]; then
    ui_backup "Creating backup — this may take a while"
    local storage
    storage=$(pvesm status -content backup | awk 'NR>1{print $1; exit}')
    if vzdump "${CONTAINER}" \
        --mode "${BACKUP_MODE:-stop}" \
        --notes-template "{{guestname}} - Ultimate-Updater" \
        --storage "${storage}" \
        --compress zstd; then
      ui_ok "Backup created"
    else
      ui_error "Backup failed — skipping update for LXC ${CONTAINER}"
      if [[ "${_BACKUP_RESET:-false}" == true ]]; then
        BACKUP=$(awk -F'"' '/^BACKUP=/ {print $2}' "${CONFIG_FILE}")
        SNAPSHOT=$(awk -F'"' '/^SNAPSHOT/ {print $2}' "${CONFIG_FILE}")
        _BACKUP_RESET=false
      fi
      return 1
    fi
    if [[ "${_BACKUP_RESET:-false}" == true ]]; then
      BACKUP=$(awk -F'"' '/^BACKUP=/ {print $2}' "${CONFIG_FILE}")
      SNAPSHOT=$(awk -F'"' '/^SNAPSHOT/ {print $2}' "${CONFIG_FILE}")
      _BACKUP_RESET=false
    fi
  fi
}

VM_BACKUP() {
  if [[ "${SNAPSHOT:-false}" != true && "${BACKUP:-false}" != true ]]; then
    ui_skip "Snapshot and backup disabled"
    return 0
  fi

  if [[ "${SNAPSHOT:-false}" == true ]]; then
    local snap_name="Update_$(date '+%Y%m%d_%H%M%S')"
    if qm snapshot "${VM}" "${snap_name}" &>/dev/null; then
      ui_ok "Snapshot created"
      local old_snaps
      old_snaps=$(qm listsnapshot "${VM}" | sed -n "s/^.*Update\s*\(\S*\).*$/\1/p" | head -n -"${KEEP_SNAPSHOT:-3}")
      for snap in $old_snaps; do
        qm delsnapshot "${VM}" "Update${snap}" >/dev/null 2>&1 || true
      done
    else
      ui_error "Snapshot failed (storage may not support it)"
    fi
  fi

  if [[ "${BACKUP:-false}" == true ]]; then
    ui_backup "Creating VM backup — this may take a while"
    local storage
    storage=$(pvesm status -content backup | awk 'NR>1{print $1; exit}')
    if vzdump "${VM}" \
        --mode "${BACKUP_MODE:-stop}" \
        --storage "${storage}" \
        --compress zstd; then
      ui_ok "Backup created"
    else
      ui_error "Backup failed — skipping update for VM ${VM}"
      return 1
    fi
  fi
}

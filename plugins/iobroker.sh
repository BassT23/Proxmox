#!/bin/bash

#####################
# Plugin: ioBroker  #
#####################

CONFIG_FILE="${CONFIG_FILE:-/etc/ultimate-updater/update.conf}"
IOBROKER=$(awk -F'"' '/^IOBROKER=/ {print $2}' "${CONFIG_FILE}")

[[ "${IOBROKER}" == true ]] || exit 0
[[ -d /opt/iobroker ]] || exit 0

echo ""
echo "--- Updating ioBroker ---"
sudo -u iobroker bash -c "iob stop"
sudo -u iobroker bash -c "iob update"
sudo -u iobroker bash -c "iob upgrade -y"
sudo -u iobroker bash -c "iob upgrade self -y"
sudo -u iobroker bash -c "iob start"

# Restore network capabilities for radar2 adapter if installed
if [[ -d /opt/iobroker/iobroker-data/radar2.admin ]]; then
  for _bin in arp-scan node arp hcitool hciconfig l2ping; do
    _path=$(readlink -f "$(which "${_bin}" 2>/dev/null)" 2>/dev/null) || continue
    setcap cap_net_admin,cap_net_raw,cap_net_bind_service=+eip "${_path}" 2>/dev/null || true
  done
fi

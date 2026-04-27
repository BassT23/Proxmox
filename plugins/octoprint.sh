#!/bin/bash

#####################
# Plugin: OctoPrint #
#####################

CONFIG_FILE="${CONFIG_FILE:-/etc/ultimate-updater/update.conf}"
OCTOPRINT=$(awk -F'"' '/^OCTOPRINT=/ {print $2}' "${CONFIG_FILE}")

[[ "${OCTOPRINT}" == true ]] || exit 0
[[ -d /root/OctoPrint ]] || exit 0

echo ""
echo "--- Updating OctoPrint ---"
_oprint=$(find /home -name oprint 2>/dev/null | head -n1)
if [[ -z "${_oprint}" ]]; then
  echo "OctoPrint venv not found under /home"
  exit 1
fi
"${_oprint}/bin/pip" install -U --ignore-installed octoprint
service octoprint restart

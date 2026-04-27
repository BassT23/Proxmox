#!/bin/bash

####################
# Plugin: Pi-hole  #
####################

CONFIG_FILE="${CONFIG_FILE:-/etc/ultimate-updater/update.conf}"
PIHOLE=$(awk -F'"' '/^PIHOLE=/ {print $2}' "${CONFIG_FILE}")

[[ "${PIHOLE}" == true ]] || exit 0
[[ -f /usr/local/bin/pihole ]] || exit 0

echo ""
echo "--- Updating Pi-hole ---"
/usr/local/bin/pihole -up

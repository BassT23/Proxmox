#!/bin/bash

####################
# Plugin: Unifi    #
####################
# Unifi Network Controller updates are handled automatically by APT because
# the Unifi repo is detected in /etc/apt/sources.list.d.
# This plugin handles the headless / non-interactive dpkg options needed
# to avoid interactive prompts during Unifi package upgrades.
#
# Note: apt_upgrade() in os-update.sh already detects the Unifi repo and
# applies --allow-releaseinfo-change and --force-confdef/--force-confold
# automatically. This plugin is a no-op placeholder for hosts that want to
# explicitly confirm Unifi support is enabled via the UNIFI config key.

CONFIG_FILE="${CONFIG_FILE:-/etc/ultimate-updater/update.conf}"
UNIFI=$(awk -F'"' '/^UNIFI=/ {print $2}' "${CONFIG_FILE}")

[[ "${UNIFI}" == true ]] || exit 0

# Detection and upgrade are handled by apt_upgrade in os-update.sh.
# Nothing additional to do here.
exit 0

#!/bin/bash

################
# Run Plugins  #
################
# Executed inside the target container or VM.
# Sources each plugin script found in the plugins/ directory.
# Plugins are sorted alphabetically and run in order.

PLUGINS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plugins"
CONFIG_FILE="${CONFIG_FILE:-/etc/ultimate-updater/update.conf}"

[[ -d "${PLUGINS_DIR}" ]] || exit 0

for _plugin in "${PLUGINS_DIR}"/*.sh; do
  [[ -f "${_plugin}" ]] || continue
  # Run each plugin as a subprocess to isolate failures.
  bash "${_plugin}"
done

#!/bin/bash

# This work only for Container NOT the Hosts itself
VERSION=1.0

# Update PiHole
if [[ -f /usr/local/bin/pihole ]]; then
  echo -e "*** Updating PiHole ***\n"
  /usr/local/bin/pihole -up
  echo
fi

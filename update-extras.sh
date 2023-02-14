#!/bin/bash

# This work only for Container NOT the Hosts itself
VERSION=1.0

# Update PiHole
#if [[ -f /usr/local/bin/pihole ]]; then
hash pihole 2>/dev/null | {
  echo -e "*** Updating PiHole ***\n"
  /usr/local/bin/pihole -up
  echo
}

#else
#  echo -e "No extras found\n"
#fi

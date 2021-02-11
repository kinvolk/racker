#!/bin/bash

set -euo pipefail

PXE_INTERFACE="$(tail -n +2 /usr/share/oem/nodes.csv | grep -f <(cat /sys/class/net/*/address) | cut -d , -f 3)"
if [ "${PXE_INTERFACE}" = "" ]; then
  echo "Could not find PXE interface by secondary MAC address in /usr/share/oem/nodes.csv"
  exit 1
fi
# may have whitespace as prefix/suffix, thus use without quotes to get rid of it
PXE_INTERFACE=$(echo ${PXE_INTERFACE})
if [[ "${PXE_INTERFACE}" == *:* ]]; then
  PXE_INTERFACE="$(grep -m 1 "${PXE_INTERFACE}" /sys/class/net/*/address | cut -d / -f 5 | tail -n 1)"
else
  echo "Could not resolve PXE interface from ${PXE_INTERFACE}"
  exit 1
fi
echo "${PXE_INTERFACE}"

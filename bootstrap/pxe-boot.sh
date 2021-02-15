#!/bin/bash

set -euo pipefail

mac="$1"
domain="$2"

SCRIPTFOLDER="$(dirname "$(readlink -f "$0")")"

RACKER_VERSION=$(cat /opt/racker/RACKER_VERSION 2> /dev/null || true)
if [ "${RACKER_VERSION}" = "" ]; then
  RACKER_VERSION="latest"
fi
IPMI_USER=$(cat /usr/share/oem/ipmi_user)
IPMI_PASSWORD=$(cat /usr/share/oem/ipmi_password)

PXE_INTERFACE="$("${SCRIPTFOLDER}"/get-pxe-interface.sh)"
if [ "${PXE_INTERFACE}" = "" ]; then
  echo "Error getting PXE interface"
  exit 1
fi

bmcmac=$(grep -m 1 "$mac" /usr/share/oem/nodes.csv | cut -d , -f 2)
if [ "$bmcmac" = "" ]; then
  echo "BMC MAC address not found for $mac"
  exit 1
else
  # but may have whitespace as prefix/suffix, thus use without quotes to get rid of it
  bmcmac=$(echo $bmcmac)
fi
bmcipaddr=""
# poweron must be the last because when the OS comes up it does its own IPMI setup and we also don't know when any step after poweron would be executed
steps=(bootdev poweroff bootdev poweron)
count=60
while [ $count -gt 0 ]; do
  count=$((count - 1))
  sleep 1
  if [ "$bmcipaddr" = "" ]; then
    bmcipaddr=$(docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} sh -c "arp-scan -q -l -x -T $bmcmac --interface ${PXE_INTERFACE} | grep -m 1 $bmcmac | cut -f 1")
  fi
  if [ "$bmcipaddr" = "" ]; then
    continue
  fi
  if [ "${steps[0]}" = poweroff ]; then
    docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} ipmitool -C3 -I lanplus -H $bmcipaddr -U ${IPMI_USER} -P ${IPMI_PASSWORD} power off || continue
    steps=(${steps[*]:1})
    continue
  elif [ "${steps[0]}" = bootdev ]; then
    docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} ipmitool -C3 -I lanplus -H $bmcipaddr -U ${IPMI_USER} -P ${IPMI_PASSWORD} chassis bootdev pxe options=persistent || continue
    steps=(${steps[*]:1})
    continue
  else
    docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} ipmitool -C3 -I lanplus -H $bmcipaddr -U ${IPMI_USER} -P ${IPMI_PASSWORD} power on || continue
    break
  fi
  break # not reached
done
if [ $count -eq 0 ]; then
  echo "error: failed forcing a PXE boot for $domain installer"
  exit 1
fi

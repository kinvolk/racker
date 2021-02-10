#!/bin/bash

set -euo pipefail

mac="$1"
domain="$2"

RACKER_VERSION=$(cat /opt/racker/RACKER_VERSION 2> /dev/null || true)
if [ "${RACKER_VERSION}" = "" ]; then
  RACKER_VERSION="latest"
fi
IPMI_USER=$(cat /usr/share/oem/ipmi_user)
IPMI_PASSWORD=$(cat /usr/share/oem/ipmi_password)
PXE_INTERFACE=$(cat /usr/share/oem/pxe_interface)
if [ "${PXE_INTERFACE}" = "" ]; then
  echo "The PXE interface file /usr/share/oem/pxe_interface is missing"
  exit 1
fi
if [[ "${PXE_INTERFACE}" == *:* ]]; then
  PXE_INTERFACE="$(grep -m 1 "${PXE_INTERFACE}" /sys/class/net/*/address | cut -d / -f 5 | tail -n 1)"
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
step="poweroff"
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
  if [ "$step" = poweroff ]; then
    docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} ipmitool -C3 -I lanplus -H $bmcipaddr -U ${IPMI_USER} -P ${IPMI_PASSWORD} power off || continue
    step=bootdev
    continue
  elif [ "$step" = bootdev ]; then
    docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} ipmitool -C3 -I lanplus -H $bmcipaddr -U ${IPMI_USER} -P ${IPMI_PASSWORD} chassis bootdev pxe options=persistent || continue
    step=poweron
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

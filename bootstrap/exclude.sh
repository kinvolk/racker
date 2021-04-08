#!/bin/bash
set -euo pipefail

PROVISION_TYPE=${PROVISION_TYPE:-""}
NODE_MAC_ADDR=${NODE_MAC_ADDR:-""}

if [ "${PROVISION_TYPE}" = "" ] || [ "${NODE_MAC_ADDR}" = "" ]; then
  echo "Usage: PROVISION_TYPE=... NODE_MAC_ADDR=.. $0 (to be run in the ~/lokomotive or ~/flatcar-container-linux folder)"
  exit 1
fi

SCRIPTFOLDER="$(dirname "$(readlink -f "$0")")"

IP_ADDR_INTERNAL_EXPECTED=$({ grep -m 1 "${NODE_MAC_ADDR}" /opt/racker-state/dnsmasq/dnsmasq.conf || true ; } | cut -d = -f 2 | cut -d , -f 2)
if [ "${IP_ADDR_INTERNAL_EXPECTED}" = "" ]; then
  echo "Error: Could not find IP address for ${NODE_MAC_ADDR}"
  exit 1
fi
HOST_INTERNAL=$({ grep "${IP_ADDR_INTERNAL_EXPECTED} " /etc/hosts || true ; } | cut -d ' ' -f 2- | tr '\n' ' ' | xargs) # extra trailing space is intentional to not match an address prefix
if [ "${HOST_INTERNAL}" = "" ]; then
  echo "Error: Could not find internal host name for ${IP_ADDR_INTERNAL_EXPECTED}"
  exit 1
fi

if [ "${PROVISION_TYPE}" = "lokomotive" ]; then
  MAC_STATE="lokoctl-assets/cluster-assets"
  FILE=lokocfg.vars
else
  MAC_STATE="assets"
  FILE=terraform.tfvars
fi
# This only works with the files generated from prepared.sh
sed -i "s/\"${NODE_MAC_ADDR}\",//g" "${FILE}"
sed -i "s/\"${HOST_INTERNAL}\",//g" "${FILE}"
sed -i "/\"${HOST_INTERNAL}\"/d" "${FILE}"
rm -f cl/"${HOST_INTERNAL}".yaml cl/"${HOST_INTERNAL}"-custom.yaml
rm -f "${MAC_STATE}"/"${NODE_MAC_ADDR}"
sudo sed -i "/${IP_ADDR_INTERNAL_EXPECTED} /d" /etc/hosts # extra trailing space, only works with the file we just generated

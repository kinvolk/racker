#!/bin/bash
set -euo pipefail

FULL=${FULL:-"0"}
if [ $# -gt 0 ] && [ "$1" = "--full" ]; then
  FULL=1
fi

SCRIPTFOLDER="$(dirname "$(readlink -f "$0")")"
ASSET_DIR="${HOME}/lokomotive/lokoctl-assets"
source "${SCRIPTFOLDER}"/common.sh

# Skip header line, filter out the management node itself and sort by MAC address
NODES="$(tail -n +2 /usr/share/oem/nodes.csv | { grep -v -f <(cat /sys/class/net/*/address) || true ; } | sort)"
FULL_MAC_ADDRESS_LIST=($(echo "$NODES" | cut -d , -f 1))
FULL_BMC_MAC_ADDRESS_LIST=($(echo "$NODES" | cut -d , -f 2))

TYPE="no"
if [ -d ~/lokomotive ]; then
  TYPE="Lokomotive"
elif [ -d ~/flatcar-container-linux ]; then
  TYPE="Flatcar"
fi

echo "Provisioned: ${TYPE}"
names=""
if [ "${TYPE}" = "Lokomotive" ]; then
  MAC_STATE="${ASSET_DIR}/cluster-assets"
  printf "Kubernetes API reached: "
  names="$(get_node_names)"
  if [ "${names}" != "" ]; then
    echo "yes"
  else
    echo "no"
  fi
elif [ "${TYPE}" = "Flatcar" ]; then
  MAC_STATE="${HOME}/flatcar-container-linux/assets"
else
  MAC_STATE=""
fi

echo
echo "MAC address        BMC reached  OS provisioned  Joined cluster   Hostnames"
full_report=""
for mac in ${FULL_MAC_ADDRESS_LIST[*]}; do
  printf "${mac}\t"
  report=$("${SCRIPTFOLDER}"/ipmi "${mac}" diag 2>&1) && printf "✓\t" || printf "×\t"
  printf "\t"
  full_report+="${report}"$'\n\n'
  if [ "${MAC_STATE}" != "" ] && [ -f "${MAC_STATE}"/"${mac}" ]; then
    printf "✓\t"
  else
    printf "×\t"
  fi
  printf "\t"
  if [ "${TYPE}" = "Lokomotive" ]; then
    for name in ${names}; do
      found=0
      found_mac="$(get_node_mac "${name}")"
      if [ "${found_mac}" = "${mac}" ]; then
        found=1
        break
      fi
    done
    if [ "${found}" = "1" ]; then
      printf "✓\t"
    else
      printf "×\t"
    fi
  else
    printf "○\t"
  fi
  hostnames=$(echo "${report}" | { grep -m 1 "Internal host name:" || true ; } | cut -d ":" -f 2-)
  echo "${hostnames}"
done

echo
echo "To see details for a node, run \"ipmi <MAC|DOMAIN> diag\" or rerun this command with the parameter \"--full\" to see the details of all nodes."
if [ "${TYPE}" = "Lokomotive" ]; then
  echo "To query the Kubernetes and etcd cluster health, run: cd ~/lokomotive; lokoctl health"
fi

if [ "${FULL}" = "1" ]; then
  echo
  echo "${full_report}"
fi

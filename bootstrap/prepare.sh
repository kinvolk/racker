#!/bin/bash

# Copyright 2021 Kinvolk GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

PROVISION_TYPE=${PROVISION_TYPE:-"lokomotive"}
ONFAILURE=${ONFAILURE:-"ask"} # what to do on a provisioning failure, current choices: "ask", "retry", "exclude", "cancel"
RETRIES=${RETRIES:-"3"} # maximal retries if ONFAILURE=retry
CLUSTER_NAME=${CLUSTER_NAME:-"lokomotive"}
CLUSTER_DIR="$PWD"
ASSET_DIR="${CLUSTER_DIR}/lokoctl-assets"
FLATCAR_ASSETS_DIR="${CLUSTER_DIR}/assets"
EXCLUDE_NODES=(${EXCLUDE_NODES-""}) # white-space separated list of MAC addresses to exclude from provisioning (don't change VAR- to VAR:-)
PUBLIC_IP_ADDRS="${PUBLIC_IP_ADDRS:-"DHCP"}" # "DHCP" or otherwise an INI-like format with "[SECONDARY_MAC_ADDR]" sections and "ip_addr = IP_V4_ADDR/SUBNETSIZE", "gateway = GATEWAY_ADDR", "dns = DNS_ADDR" entries
if [ "${PUBLIC_IP_ADDRS}" = "DHCP" ]; then
  # use an empty INI config for no custom IP address configurations
  PUBLIC_IP_ADDRS=""
fi
CONTROLLER_AMOUNT=${CONTROLLER_AMOUNT:-"1"}
CONTROLLER_TYPE=${CONTROLLER_TYPE:-"any"}
KUBERNETES_DOMAIN_NAME=${KUBERNETES_DOMAIN_NAME:-"k8s.localdomain"}
if [ "${CONTROLLER_TYPE}" = "any" ]; then
  # use the empty string to match all entries in the node type column of the nodes.csv file
  CONTROLLER_TYPE=""
fi
SUBNET_PREFIX=${SUBNET_PREFIX:-"172.24.213"}
RACKER_VERSION=$(cat /opt/racker/RACKER_VERSION 2> /dev/null || true)
if [ "${RACKER_VERSION}" = "" ]; then
  RACKER_VERSION="latest"
fi
USE_WEB_UI=${USE_WEB_UI:-"false"}
USE_VELERO=${USE_VELERO:-"false"}
BACKUP_AWS_ACCESS_KEY=${BACKUP_AWS_ACCESS_KEY:-""}
BACKUP_AWS_SECRET_ACCESS_KEY=${BACKUP_AWS_SECRET_ACCESS_KEY:-""}
BACKUP_NAME=${BACKUP_NAME:-"lokomotive"}
BACKUP_S3_BUCKET_NAME=${BACKUP_S3_BUCKET_NAME:-""}
BACKUP_AWS_REGION=${BACKUP_AWS_REGION:-""}
STORAGE_PROVIDER=${STORAGE_PROVIDER:-"none"}
STORAGE_NODE_TYPE=${STORAGE_NODE_TYPE:-"any"}
if [ "${STORAGE_NODE_TYPE}" = "any" ]; then
    STORAGE_NODE_TYPE=""
fi
NUMBER_OF_STORAGE_NODES=${NUMBER_OF_STORAGE_NODES:-"1"}
if [ "${NUMBER_OF_STORAGE_NODES}" = "0" ]; then
    STORAGE_PROVIDER="none"
fi
USE_QEMU=${USE_QEMU:-"1"}
QEMU_SINGLE_NIC=${QEMU_SINGLE_NIC:-""}
if [ "$USE_QEMU" = "0" ]; then
  USE_QEMU=""
fi
OLD_LOKOMOTIVE=${OLD_LOKOMOTIVE:-""}

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: USE_QEMU=0|1 [QEMU_SINGLE_NIC=0|1] $0 create|destroy"
  echo "Should be run in a new empty directory, 'create' can't be rerun without removing the directory contents first."
  echo "Note: Make sure you disable any firewall for DHCP on the bridge, e.g. on Fedora, run sudo systemctl disable --now firewalld"
  exit 1
fi

SCRIPTFOLDER="$(dirname "$(readlink -f "$0")")"

source "${SCRIPTFOLDER}"/common.sh

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please do not run as root, sudo will be used where necessary"
  exit 1
fi

if [ "$(which lokoctl 2> /dev/null)" = "" ]; then
 echo "lokoctl not found in PATH"
 exit 1
fi

function cancel() {
  echo "Canceling"
  kill 0
  exit 1
}
trap cancel INT

function get_ini() {
  local mac_addr="$1"
  local key="$2"
  # get value of "key = val" line after "[mac_addr]" header, and filter out any spaces
  sed -nr "/^\[${mac_addr}\]/ { :l /^${key}[ ]*=/ { s/.*=[ ]*//; p; q;}; n; b l;}" | sed 's/ //g'
}

PUBLIC_IP_ADDRS_LIST=() # list of SECONDARY_MAC_ADDR-IP_V4_ADDR/SUBNETSIZE-GATEWAY-DNS strings
secondary_macs=$(echo "${PUBLIC_IP_ADDRS}" | { grep -o '^\[.*\]' || true ; } | tr -d '[]')
if [ "${secondary_macs}" != "" ]; then
  for secondary_mac in ${secondary_macs}; do
    ipv4_addr_and_subnet=$(echo "${PUBLIC_IP_ADDRS}" | get_ini ${secondary_mac} ip_addr)
    if [ "${ipv4_addr_and_subnet}" != "" ]; then
      gateway=${gateway:-"$(echo "${PUBLIC_IP_ADDRS}" | get_ini ${secondary_mac} gateway)"}
      dns=${dns:-"$(echo "${PUBLIC_IP_ADDRS}" | get_ini ${secondary_mac} dns)"}
      if [ "${gateway}" = "" ] || [ "${dns}" = "" ]; then
        echo "both the gateway and dns settings are required when an IP address on the public interface is configured"
        exit 1
      fi
      PUBLIC_IP_ADDRS_LIST+=("${secondary_mac}-${ipv4_addr_and_subnet}-${gateway}-${dns}")
    fi
  done
fi

if [ -n "$USE_QEMU" ]; then
  ls controller_macs worker_macs > /dev/null || { echo "Add at least one MAC address for each file controller_macs and worker_macs" ; exit 1 ; }
  if [ "$CONTROLLER_AMOUNT" != "$(cat controller_macs | wc -l)" ]; then
    echo "wrong amount of controller nodes found (check CONTROLLER_AMOUNT)"
    exit 1
  fi
  WORKER_AMOUNT="$(cat worker_macs | wc -l)"
  CONTROLLERS_MAC=($(cat controller_macs))
  MAC_ADDRESS_LIST=($(cat controller_macs worker_macs))
  FULL_MAC_ADDRESS_LIST=($(cat controller_macs worker_macs))
  FULL_BMC_MAC_ADDRESS_LIST=()
  PXE_INTERFACE="pxe0"
else
  ls /usr/share/oem/nodes.csv > /dev/null || { echo "The rack metadata file in /usr/share/oem/nodes.csv is missing" ; exit 1 ; }
  ls /usr/share/oem/ipmi_user /usr/share/oem/ipmi_password > /dev/null || { echo "The IPMI user and the IPMI password files /usr/share/oem/ipmi_user and /usr/share/oem/ipmi_password are missing" ; exit 1 ; }
  IPMI_USER=$(cat /usr/share/oem/ipmi_user)
  IPMI_PASSWORD=$(cat /usr/share/oem/ipmi_password)
  PXE_INTERFACE="$("${SCRIPTFOLDER}"/get-pxe-interface.sh)"
  if [ "${PXE_INTERFACE}" = "" ]; then
    echo "Error getting PXE interface"
    exit 1
  fi
  # Skip header line, filter out the management node itself and sort by MAC address
  NODES="$(tail -n +2 /usr/share/oem/nodes.csv | { grep -v -f <(cat /sys/class/net/*/address) || true ; } | sort)"
  FULL_MAC_ADDRESS_LIST=($(echo "$NODES" | cut -d , -f 1)) # sorted MAC addresses will be used to assign the IP addresses
  FULL_BMC_MAC_ADDRESS_LIST=($(echo "$NODES" | cut -d , -f 2))
  if [ "${#EXCLUDE_NODES[*]}" != 0 ]; then
    for node in ${EXCLUDE_NODES[*]}; do
      NODES="$(echo "$NODES" | grep -v "${node}")"
    done
  fi
  CONTROLLERS="$(echo "$NODES" | grep -m "$CONTROLLER_AMOUNT" "[ ,]$CONTROLLER_TYPE")"
  if [ "$(echo "$CONTROLLERS" | wc -l)" != "$CONTROLLER_AMOUNT" ]; then
    echo "wrong amount of controller nodes found (check the CONTROLLER_TYPE and CONTROLLER_AMOUNT)"
    exit 1
  fi
  WORKERS="$(echo "$NODES" | grep -v -F -x -f <(echo "$CONTROLLERS"))"
  CONTROLLERS_MAC=($(echo "$CONTROLLERS" | cut -d , -f 1))
  CONTROLLERS_BMC_MAC=($(echo "$CONTROLLERS" | cut -d , -f 2))
  WORKERS_MAC=($(echo "$WORKERS" | cut -d , -f 1))
  WORKERS_BMC_MAC=($(echo "$WORKERS" | cut -d , -f 2))
  MAC_ADDRESS_LIST=(${CONTROLLERS_MAC[*]} ${WORKERS_MAC[*]})
  BMC_MAC_ADDRESS_LIST=(${CONTROLLERS_BMC_MAC[*]} ${WORKERS_BMC_MAC[*]})
  WORKER_AMOUNT=$((${#MAC_ADDRESS_LIST[*]} - CONTROLLER_AMOUNT))
  if [ "${NUMBER_OF_STORAGE_NODES}" = "all" ];then
    NUMBER_OF_STORAGE_NODES="$(echo "$WORKERS" | { grep "[ ,]$STORAGE_NODE_TYPE" || true ; } | wc -l)"
  fi
  if [ "${STORAGE_PROVIDER}" != "none" ]; then
    STORAGE_NODES="$(echo "$WORKERS" | { grep -m "$NUMBER_OF_STORAGE_NODES" "[ ,]$STORAGE_NODE_TYPE" || true ;})"
    if [ "$NUMBER_OF_STORAGE_NODES" = "0" ]; then
      echo "no storage nodes of the given type found (check the STORAGE_NODE_TYPE and NUMBER_OF_STORAGE_NODES)"
      exit 1
    fi
    if [ "$(echo "$STORAGE_NODES" | wc -l)" != "$NUMBER_OF_STORAGE_NODES" ]; then
      echo "specified amount of storage nodes not found (check the STORAGE_NODE_TYPE and NUMBER_OF_STORAGE_NODES)"
      exit 1
    fi
    STORAGE_NODES_MAC=($(echo "$STORAGE_NODES" | cut -d , -f 1))
  fi
fi


INTERNAL_BRIDGE_SIZE="24"
INTERNAL_BRIDGE_BROADCAST="${SUBNET_PREFIX}.255"
INTERNAL_DHCP_RANGE_LOW="${SUBNET_PREFIX}.128" # use the second half for DHCP, the first for static addressing
INTERNAL_DHCP_RANGE_HIGH="${SUBNET_PREFIX}.254"
INTERNAL_DHCP_NETMASK="255.255.255.0"
if [ -n "$USE_QEMU" ]; then
  VM_MEMORY=2500
  VM_DISK=10
  INTERNAL_BRIDGE_NAME="pxe0"
  INTERNAL_BRIDGE_ADDRESS="${SUBNET_PREFIX}.1" # the bridge IP address will also be used for the management node containers, later when run in a VM, .0 should be used or no address since the external bridge can also be used to reach the nodes
  # Set up Internet connectivity for the non-PXE interface of each VM
  EXTERNAL_BRIDGE_NAME="ext0"
  EXTERNAL_BRIDGE_ADDRESS="192.168.254.1"
  EXTERNAL_BRIDGE_SIZE="24"
  EXTERNAL_BRIDGE_BROADCAST="192.168.254.255"
  EXTERNAL_DHCP_RANGE_LOW="192.168.254.2"
  EXTERNAL_DHCP_RANGE_HIGH="192.168.254.254"
  EXTERNAL_DHCP_NETMASK="255.255.255.0"
  EXTERNAL_DHCP_ROUTER_OPTION="${EXTERNAL_BRIDGE_ADDRESS}"
fi

# Use a private /24 subnet on an internal L2 network, part of 172.16.0.0/12 and assign the node number to the last byte, start with .2 for the first node (the management node is always .1).
# Purpose is DHCP/PXE but also stable addressing of the nodes.
function calc_ip_addr() {
  local node_mac="$1"
  local node_nr=2

  for mac in ${FULL_MAC_ADDRESS_LIST[*]} ${FULL_BMC_MAC_ADDRESS_LIST[*]}; do
    if [ "$mac" = "$node_mac" ]; then
      break
    fi
    let node_nr+=1
  done
  if [ "${node_nr}" -ge 128 ]; then
    exit 1
  fi
  echo "${SUBNET_PREFIX}.${node_nr}"
}

function get_matchbox_ip_addr() {
  echo "${SUBNET_PREFIX}.1"
}

function destroy_network() {
  if [ -n "$USE_QEMU" ]; then
    echo "Destroying internal network bridge ${INTERNAL_BRIDGE_NAME}"
    sudo ip link delete "${INTERNAL_BRIDGE_NAME}" type bridge || true

    echo "Destroying external network bridge ${EXTERNAL_BRIDGE_NAME}"
    sudo ip link delete "${EXTERNAL_BRIDGE_NAME}" type bridge || true
  fi
}

function create_network() {
  destroy_network
  if [ -n "$USE_QEMU" ]; then
    echo "Creating bridge ${EXTERNAL_BRIDGE_NAME}"

    sudo ip link add name "${EXTERNAL_BRIDGE_NAME}" type bridge
    sudo ip link set "${EXTERNAL_BRIDGE_NAME}" up
    sudo ip addr add dev "${EXTERNAL_BRIDGE_NAME}" "${EXTERNAL_BRIDGE_ADDRESS}/${EXTERNAL_BRIDGE_SIZE}" broadcast "${EXTERNAL_BRIDGE_BROADCAST}"

    echo "Creating bridge ${INTERNAL_BRIDGE_NAME}"

    sudo ip link add name "${INTERNAL_BRIDGE_NAME}" address aa:bb:cc:dd:ee:ff type bridge
    sudo ip link set "${INTERNAL_BRIDGE_NAME}" up
    sudo ip addr add dev "${INTERNAL_BRIDGE_NAME}" "${INTERNAL_BRIDGE_ADDRESS}/${INTERNAL_BRIDGE_SIZE}" broadcast "${INTERNAL_BRIDGE_BROADCAST}"

    # Setup NAT Internet access for the bridge (external, because the internal bridge DHCP does not announce a gateway unless QEMU_SINGLE_NIC is set)
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -t nat -A POSTROUTING -o $(ip route get 1 | grep -o -P ' dev .*? ' | cut -d ' ' -f 3) -j MASQUERADE

  else
    sudo tee /etc/systemd/network/10-pxe.network >/dev/null <<-EOF
	[Match]
	Name=${PXE_INTERFACE}
	[Link]
	RequiredForOnline=no
	[Address]
	Address=$(get_matchbox_ip_addr)/${INTERNAL_BRIDGE_SIZE}
	Scope=link
	[Network]
	DHCP=no
	LinkLocalAddressing=no
EOF
    sudo networkctl reload
    # kubectl should use systemd-resolved to get all controller IP addresses from /etc/hosts
    sudo ln -fs /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  fi
}

function create_certs() {
  local server_dir="/opt/racker-state/matchbox/certs"
  local cert_dir="/opt/racker-state/matchbox-client"
  local err_output=""
  tmp_dir=$(mktemp -d -t certs-XXXXXXXXXX)
  pushd "$tmp_dir" 1>/dev/null

  export SAN="IP.1:$(get_matchbox_ip_addr)"
  err_output=$("$SCRIPTFOLDER/scripts/tls/cert-gen" 2>&1) || { echo "${err_output}" ; exit 1; }

  sudo mkdir -p "${server_dir}"
  sudo chown -R $USER:$USER "${server_dir}"
  cp server.key server.crt ca.crt "${server_dir}"

  sudo mkdir -p "${cert_dir}"
  sudo chown -R $USER:$USER "${cert_dir}"
  cp ca.crt client.key client.crt "${cert_dir}"

  popd 1>/dev/null
  rm -rf "$tmp_dir"
}

function create_ssh_key() {
  if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -f ~/.ssh/id_rsa -N ''
  fi
}

function get_assets() {
  local DOWNLOAD_DIR="/opt/racker-state/matchbox/assets"
  sudo mkdir -p "${DOWNLOAD_DIR}"
  sudo chown -R $USER:$USER "${DOWNLOAD_DIR}"

  local FLATCAR_VERSION_FILE="${DOWNLOAD_DIR}/flatcar/current/version.txt"

  if [[ "$(ls -A "${DOWNLOAD_DIR}")" && -f "${FLATCAR_VERSION_FILE}" ]]; then
    # Check flatcar current stable version to be downloaded
    local AVAILABLE_FLATCAR_VERSION
    AVAILABLE_FLATCAR_VERSION=$(curl -fsS "https://stable.release.flatcar-linux.net/amd64-usr/current/version.txt" | grep '^FLATCAR_VERSION=')

    # Check what version we have downloaded locally
    local EXISTING_FLATCAR_VERSION
    EXISTING_FLATCAR_VERSION=$(grep '^FLATCAR_VERSION=' "${FLATCAR_VERSION_FILE}")

    # Skip download if available version is same as upstream version
    if [[ "${AVAILABLE_FLATCAR_VERSION}" == "${EXISTING_FLATCAR_VERSION}" ]]; then
      echo "Skipping download of Flatcar Linux assets, since downloaded version is up to date" >/dev/null
      return
    fi
  fi

  "$SCRIPTFOLDER/scripts/get-flatcar" stable current "${DOWNLOAD_DIR}" >/dev/null
}

function destroy_containers() {
  if [ -n "$USE_QEMU" ]; then
    docker stop matchbox || true
    docker rm matchbox || true

    sudo docker stop dnsmasq || true
    sudo docker rm dnsmasq || true

    sudo docker stop dnsmasq-external || true
    sudo docker rm dnsmasq-external || true
  fi
}

# DHCP/PXE on the internal bridge
function prepare_dnsmasq_conf() {
  sudo mkdir -p "/opt/racker-state/dnsmasq"
  sudo chown -R $USER:$USER "/opt/racker-state/dnsmasq"
  sed \
    -e "s/{{DHCP_RANGE_LOW}}/$INTERNAL_DHCP_RANGE_LOW/g" \
    -e "s/{{DHCP_RANGE_HIGH}}/$INTERNAL_DHCP_RANGE_HIGH/g" \
    -e "s/{{DHCP_NETMASK}}/$INTERNAL_DHCP_NETMASK/g" \
    -e "s/{{BRIDGE_NAME}}/${PXE_INTERFACE}/g" \
    -e "s/{{MATCHBOX}}/$(get_matchbox_ip_addr)/g" \
    < "$SCRIPTFOLDER/dnsmasq.conf.template" > "/opt/racker-state/dnsmasq/dnsmasq.conf"
  # # Careful: Assumes a particular format of the entries in the dnsmasq.conf.template file
  if [ "${QEMU_SINGLE_NIC}" = "1" ]; then
    sed -i "s/dhcp-option=3/dhcp-option=3,$(get_matchbox_ip_addr)/g" /opt/racker-state/dnsmasq/dnsmasq.conf
    sed -i "/dhcp-option=6/d" /opt/racker-state/dnsmasq/dnsmasq.conf
  fi
  local ip_address=""
  local bmc_mac=""
  local bmc_ip_address=""
  for mac in ${MAC_ADDRESS_LIST[*]}; do
    ip_address="$(calc_ip_addr ${mac})"
    echo "dhcp-host=${mac},${ip_address},2m" >> "/opt/racker-state/dnsmasq/dnsmasq.conf"
    if [ -z "$USE_QEMU" ]; then
      bmc_mac=$(grep -m 1 "${mac}" /usr/share/oem/nodes.csv | cut -d , -f 2 | sed 's/ //g')
      bmc_ip_address="$(calc_ip_addr ${bmc_mac})"
      echo "dhcp-host=${bmc_mac},${bmc_ip_address},2m" >> "/opt/racker-state/dnsmasq/dnsmasq.conf"
    fi
  done
}

# regular DHCP on the external bridge (as libvirt would do)
function prepare_dnsmasq_external_conf() {
  sudo mkdir -p "/opt/racker-state/dnsmasq"
  sudo chown -R $USER:$USER "/opt/racker-state/dnsmasq"
  sed \
    -e "s/{{DHCP_RANGE_LOW}}/$EXTERNAL_DHCP_RANGE_LOW/g" \
    -e "s/{{DHCP_RANGE_HIGH}}/$EXTERNAL_DHCP_RANGE_HIGH/g" \
    -e "s/{{DHCP_ROUTER_OPTION}}/$EXTERNAL_DHCP_ROUTER_OPTION/g" \
    -e "s/{{DHCP_NETMASK}}/$EXTERNAL_DHCP_NETMASK/g" \
    -e "s/{{BRIDGE_NAME}}/$EXTERNAL_BRIDGE_NAME/g" \
    < "$SCRIPTFOLDER/dnsmasq-external.conf.template" > "/opt/racker-state/dnsmasq/dnsmasq-external.conf"
}

function create_containers() {
  destroy_containers

  sudo mkdir -p "/opt/racker-state/matchbox/groups"
  sudo chown -R $USER:$USER "/opt/racker-state/matchbox"
  if [ -n "$USE_QEMU" ]; then
    MATCHBOX_CMD="$(grep -m 1 "ExecStartPre=docker run" "${SCRIPTFOLDER}/matchbox.service" | cut -d = -f 2- | sed "s/\${MATCHBOX_IP_ADDR}/$(get_matchbox_ip_addr)/g")"
    ${MATCHBOX_CMD}
  else
    sudo tee /opt/racker-state/matchbox-service >/dev/null <<-EOF
	MATCHBOX_IP_ADDR="$(get_matchbox_ip_addr)"
EOF
    # systemctl daemon-reload is not needed because we only change the env file
    sudo systemctl enable matchbox.service
    sudo systemctl restart matchbox.service
  fi

  prepare_dnsmasq_conf

  if [ -n "$USE_QEMU" ]; then
    DNSMASQ_CMD="$(grep -m 1 "ExecStartPre=docker run" "${SCRIPTFOLDER}/dnsmasq.service" | cut -d = -f 2-)"
    # (use real root here in case docker is actually podman with a user namespace)
    sudo ${DNSMASQ_CMD}
  else
    sudo touch /opt/racker-state/dnsmasq-service
    # systemctl daemon-reload is not needed because we only created the env file/condition file
    sudo systemctl enable dnsmasq.service
    sudo systemctl restart dnsmasq.service
  fi

  if [ -n "$USE_QEMU" ] && [ "${QEMU_SINGLE_NIC}" != "1" ]; then
  prepare_dnsmasq_external_conf

  sudo docker run --name dnsmasq-external \
    -d \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    -v "/opt/racker-state/dnsmasq/dnsmasq-external.conf:/etc/dnsmasq.conf:Z" \
    --net=host \
    quay.io/poseidon/dnsmasq:d40d895ab529160657defedde36490bcc19c251f -d
  fi
}

function destroy_node() {
  node_to_destroy=$1
  sudo virsh destroy ${node_to_destroy} || true
  sudo virsh undefine ${node_to_destroy} || true
}

function delete_storage() {
  node_storage_to_delete=$1
  sudo virsh vol-delete --pool default  ${node_storage_to_delete} || true
}

function destroy_flatcar_nodes() {
  if [ -n "$USE_QEMU" ]; then
    echo "Destroying nodes..."
    for ((count=0; count<$((${#MAC_ADDRESS_LIST[*]})); count++)); do
      destroy_node "node-${count}"
    done

    sudo virsh pool-refresh default

    for ((count=0; count<$((${#MAC_ADDRESS_LIST[*]})); count++)); do
      delete_storage "node-${count}.qcow2"
    done
  fi
}

function destroy_nodes() {
  if [ -n "$USE_QEMU" ]; then
  echo "Destroying nodes..."
  for ((count=0; count<$CONTROLLER_AMOUNT; count++)); do
    destroy_node "${CLUSTER_NAME}-controller-${count}.${KUBERNETES_DOMAIN_NAME}"
  done
  for ((count=0; count<$WORKER_AMOUNT; count++)); do
    destroy_node "${CLUSTER_NAME}-worker-${count}.${KUBERNETES_DOMAIN_NAME}"
  done

  sudo virsh pool-refresh default

  for ((count=0; count<$CONTROLLER_AMOUNT; count++)); do
    delete_storage "${CLUSTER_NAME}-controller-${count}.${KUBERNETES_DOMAIN_NAME}.qcow2"
  done
  for ((count=0; count<$WORKER_AMOUNT; count++)); do
    delete_storage "${CLUSTER_NAME}-worker-${count}.${KUBERNETES_DOMAIN_NAME}.qcow2"
  done
  fi
}

function destroy_all() {
  if [ "${PROVISION_TYPE}" = "lokomotive" ]; then
    destroy_nodes
  else
    destroy_flatcar_nodes
  fi

  destroy_containers
  destroy_network
}

# kubectl needs to resolve the cluster names, write them to /etc/hosts
function add_to_etc_hosts() {
  local ip_addr="$1"
  local names="$2"
  sudo sed -i "/.*${names}/d" /etc/hosts
  echo "${ip_addr} ${names}" | sudo tee -a /etc/hosts >/dev/null
}

function create_backup_credentials() {
  sed \
    -e "s/{{ACCESS_KEY}}/$BACKUP_AWS_ACCESS_KEY/g" \
    -e "s/{{SECRET_KEY}}/$BACKUP_AWS_SECRET_ACCESS_KEY/g" \
    < "$SCRIPTFOLDER/backup-credentials.template" > "./backup-credentials"
}

function copy_script() {
  local script_name="$1"
  if ! cmp --silent "$SCRIPTFOLDER/$script_name" $script_name; then
    cp "$SCRIPTFOLDER/$script_name" ./
  fi
}

function gen_cluster_vars() {
  local type="$1"
  local count=0
  local name=""
  local controller_macs="["
  local worker_macs="["
  local controller_names="["
  local worker_names="["
  local clc_snippets="{"$'\n'
  local installer_clc_snippets="{"$'\n'
  local node_specific_labels="{"$'\n'
  local ip_address=""
  local controller_hosts=""
  local id=""
  local j=0
  local variable_file=""
  sudo sed -i "/${SUBNET_PREFIX}./d" /etc/hosts
  sudo sed -i "/${CLUSTER_NAME}.${KUBERNETES_DOMAIN_NAME}/d" /etc/hosts
  if [ "$type" = "lokomotive" ]; then
    for mac in ${CONTROLLERS_MAC[*]}; do
      sudo sed -i "/${CLUSTER_NAME}-etcd${j}.${KUBERNETES_DOMAIN_NAME}/d" /etc/hosts
      controller_hosts+="          $(calc_ip_addr $mac) ${CLUSTER_NAME}-etcd${j}.${KUBERNETES_DOMAIN_NAME} ${CLUSTER_NAME}-controller-${j}.${KUBERNETES_DOMAIN_NAME} ${CLUSTER_NAME}.${KUBERNETES_DOMAIN_NAME}\n"
      # special case not covered by add_to_etc_hosts function
      echo "$(calc_ip_addr $mac)" "${CLUSTER_NAME}.${KUBERNETES_DOMAIN_NAME} ${CLUSTER_NAME}-etcd${j}.${KUBERNETES_DOMAIN_NAME}" | sudo tee -a /etc/hosts >/dev/null
      let j+=1
    done
    # initialize the variable for Lokomotive to use controller_* variables while plain Flatcar only uses the worker_* variables
    name="controller"
  fi
  for mac in ${MAC_ADDRESS_LIST[*]}; do
    if [ -n "$USE_QEMU" ]; then
      node_color=""
    else
      node_color="$(echo "$NODES" | grep ${mac} | cut -d , -f 4 | xargs)"
    fi
    ip_address="$(calc_ip_addr $mac)"
    if [ "$type" = "lokomotive" ]; then
      id="${CLUSTER_NAME}-${name}-${count}.${KUBERNETES_DOMAIN_NAME}"
    else
      id="node-"${count}
    fi
    add_to_etc_hosts "${ip_address}" "${id}"
    if [ "$name" = "controller" ]; then
      controller_macs+="\"${mac}\", "
      controller_names+="\"${id}\", "
    else
      worker_macs+="\"${mac}\", "
      worker_names+="\"${id}\", "
    fi
    node_specific_labels+="\"${id}\" = {\"metadata.node-type\" = \"${node_color}\""
    if [ "$STORAGE_PROVIDER" != "none" ]; then
      if [ "$(echo ${STORAGE_NODES_MAC[*]} | grep ${mac})" ]; then
        node_specific_labels+=", \"storage.lokomotive.io\" = \"${STORAGE_PROVIDER}\""
      fi
    fi
    node_specific_labels+="}"$'\n'
    mkdir -p cl
    clc_snippets+="\"${id}\" = [\"cl/${id}.yaml\", \"cl/${id}-custom.yaml\"]"$'\n'
    if [ "$type" = "lokomotive" ]; then
      sed -e "s/{{MAC}}/${mac}/g" -e "s#{{IP_ADDRESS}}#${ip_address}#g" -e "s/{{HOSTS}}/${controller_hosts}/g" -e "s#{{RACKER_VERSION}}#${RACKER_VERSION}#g" < "$SCRIPTFOLDER/network.yaml.template" > "cl/${id}.yaml"
    else
      sed -e "s/{{MAC}}/${mac}/g" -e "s#{{IP_ADDRESS}}#${ip_address}#g" -e "s#{{RACKER_VERSION}}#${RACKER_VERSION}#g" < "$SCRIPTFOLDER/flatcar/network.yaml.template" > "cl/${id}.yaml"
    fi
    if [ "${QEMU_SINGLE_NIC}" = "1" ]; then
      # Careful: Assumes a particular format of the first entry in the network.yaml.template file
      sed -i "0,/RequiredForOnline=no/s//RequiredForOnline=yes/" "cl/${id}.yaml"
      sed -i "0,/Scope=link/s//Scope=global/" "cl/${id}.yaml"
      sed -i "0,/LinkLocalAddressing=no/s//LinkLocalAddressing=no\n        DNS=$(get_matchbox_ip_addr)\n        [Route]\n        Destination=0.0.0.0\/0\n        Gateway=$(get_matchbox_ip_addr)/" "cl/${id}.yaml"
    fi
    if [ "${#PUBLIC_IP_ADDRS_LIST[*]}" != "0" ]; then
      installer_clc_snippets+="\"${id}\" = [\"cl/${id}-custom.yaml\"]"$'\n'
      for entry in ${PUBLIC_IP_ADDRS_LIST[*]}; do
        unpacked=($(echo $entry | tr - ' '))
        secondary_mac="${unpacked[0]}"
        ipv4_addr_and_subnet="${unpacked[1]}"
        gateway="${unpacked[2]}"
        dns="${unpacked[3]}"
        if [ "$(grep ${mac} /usr/share/oem/nodes.csv | grep ${secondary_mac})" != "" ]; then
          tee -a "cl/${id}-custom.yaml" >/dev/null <<-EOF
	networkd:
	  units:
	    - name: 10-public-stable.network
	      contents: |
	        [Match]
	        MACAddress=${secondary_mac}
	        [Address]
	        Address=${ipv4_addr_and_subnet}
	        [Network]
	        DHCP=no
	        LinkLocalAddressing=no
	        DNS=${dns}
	        [Route]
	        Destination=0.0.0.0/0
	        Gateway=${gateway}
EOF
        fi
      done
    else
      echo > "cl/${id}-custom.yaml"
    fi
    let count+=1
    if [ "$name" = "controller" ] && [ "$count" = "${CONTROLLER_AMOUNT}" ]; then
      count=0
      name="worker"
    fi
  done
  controller_macs+="]"
  worker_macs+="]"
  controller_names+="]"
  worker_names+="]"
  clc_snippets+=$'\n'"}"
  installer_clc_snippets+=$'\n'"}"
  node_specific_labels+=$'\n'"}"
  # We escape $var as \$var for the bash heredoc to preserve it as Terraform string, use ${VAR} for the bash heredoc substitution.
  # \${var} would be for Terraform substitution but it's not used; you can also use a nested terraform heredoc but better avoid it.
  # The "pxe_commands" variable is executed as command in a context that sets up "$mac" and "$domain" (but don't use "${mac}"
  # which would be a Terraform variable).
  if [ "$type" = "lokomotive" ]; then
    if [ "${OLD_LOKOMOTIVE}" = "1" ]; then
      COMPAT_OLD_LOKOMOTIVE="${CLUSTER_NAME}."
    else
      COMPAT_OLD_LOKOMOTIVE=""
    fi
    tee lokocfg.vars >/dev/null <<-EOF
	cluster_name = "${CLUSTER_NAME}"
	asset_dir = "${ASSET_DIR}"
	k8s_domain_name = "${COMPAT_OLD_LOKOMOTIVE}${KUBERNETES_DOMAIN_NAME}"
	controller_macs = ${controller_macs}
	worker_macs = ${worker_macs}
	controller_names = ${controller_names}
	worker_names = ${worker_names}
	matchbox_addr = "$(get_matchbox_ip_addr)"
	clc_snippets = ${clc_snippets}
	installer_clc_snippets = ${installer_clc_snippets}
	node_specific_labels = ${node_specific_labels}
EOF
  variable_file="lokocfg.vars"
  else
    tee terraform.tfvars >/dev/null <<-EOF
	asset_dir = "${FLATCAR_ASSETS_DIR}"
	node_macs = ${worker_macs}
	node_names = ${worker_names}
	matchbox_addr = "$(get_matchbox_ip_addr)"
	clc_snippets = ${clc_snippets}
	installer_clc_snippets = ${installer_clc_snippets}
EOF
  variable_file="terraform.tfvars"
  fi
  if [ -n "$USE_QEMU" ]; then
    tee -a "${variable_file}" >/dev/null <<-EOF
	kernel_console = []
	install_pre_reboot_cmds = ""
	pxe_commands = "sudo virsh destroy \$domain || true; sudo virsh undefine \$domain || true; sudo virsh pool-refresh default || true; sudo virsh vol-delete --pool default \$domain.qcow2 || true; sudo virt-install --name \$domain --network=bridge:${INTERNAL_BRIDGE_NAME},mac=\$mac  --network=bridge:${EXTERNAL_BRIDGE_NAME} --memory=${VM_MEMORY} --vcpus=1 --disk pool=default,size=${VM_DISK} --os-type=linux --os-variant=generic --noautoconsole --events on_poweroff=preserve --boot=hd,network"
EOF
  else
    # The first ipmitool raw command is used to disable the 60 secs timeout that clears the boot flag
    # The "ipmitool raw 0x00 0x08 0x05 0xe0 0x08 0x00 0x00 0x00" command can be replaced with "ipmitool chassis bootdev disk options=persistent,efiboot" once a new IPMI tool version is released
    tee -a "${variable_file}" >/dev/null <<-EOF
	kernel_console = ["console=ttyS1,57600n8", "earlyprintk=serial,ttyS1,57600n8"]
	install_pre_reboot_cmds = "docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} sh -c 'ipmitool raw 0x0 0x8 0x3 0x1f && ipmitool raw 0x00 0x08 0x05 0xe0 0x08 0x00 0x00 0x00'"
	pxe_commands = "${SCRIPTFOLDER}/pxe-boot.sh \$mac \$domain"
EOF
  fi

  if [ "$type" = "lokomotive" ]; then
    copy_script baremetal.lokocfg
    if [ "${OLD_LOKOMOTIVE}" = "1" ]; then
      sed -i "/wipe_additional_disks = true/d" baremetal.lokocfg
      sed -i "/node_specific_labels = var.node_specific_labels/d" baremetal.lokocfg
      sed -i "/pxe_commands = var.pxe_commands/d" baremetal.lokocfg
      sed -i "/install_pre_reboot_cmds = var.install_pre_reboot_cmds/d" baremetal.lokocfg
      sed -i "/kernel_console = var.kernel_console/d" baremetal.lokocfg
      sed -i "/installer_clc_snippets =.*/d" baremetal.lokocfg
    fi

    if [ "$STORAGE_PROVIDER" = "rook" ]; then
      copy_script rook.lokocfg
    fi

    if [ "$STORAGE_PROVIDER" = "openebs" ]; then
      copy_script openebs.lokocfg
    fi

    if [ "$USE_WEB_UI" = "true" ]; then
      copy_script web-ui.lokocfg
    fi

    if [ "$USE_VELERO" = "true" ]; then
      create_backup_credentials
      tee -a lokocfg.vars >/dev/null <<-EOF
	backup_name = "${BACKUP_NAME}"
	backup_s3_bucket_name = "${BACKUP_S3_BUCKET_NAME}"
	backup_aws_region = "${BACKUP_AWS_REGION}"
EOF
      copy_script velero.lokocfg
    fi
  else
    mkdir templates
    cp "$SCRIPTFOLDER"/flatcar/templates/base.yaml.tmpl templates/base.yaml.tmpl
    copy_script flatcar/variables.tf
    copy_script flatcar/versions.tf
    copy_script flatcar/flatcar.tf
  fi
}

function bmc_check() {
  local report=""
  errors=""
  error_macs=() # does not work when marked local
  local found=0
  local all=${#MAC_ADDRESS_LIST[*]}
  local ellipsis=1
  if [ -z "$USE_QEMU" ]; then
    echo # allocate one line (because we have one line of output) in advance to not hit the scroll buffer
    tput cuu 1 # and go back that line
    tput sc
    for mac in ${MAC_ADDRESS_LIST[*]}; do
      tput rc
      tput ed
      ELLIPSIS=$(printf '.%.0s' $(seq ${ellipsis}))
      echo "➤ Checking BMC connectivity (${found}/${all})${ELLIPSIS}"
      report=$(USE_TTY=0 USE_STDIN=0 "${SCRIPTFOLDER}"/ipmi "${mac}" diag 2>&1) && let found+=1 || {
        errors+="Error while checking BMC connectivity for ${mac}:"$'\n'"${report}"
        error_macs+=("${mac}")
      }
      let ellipsis+=1
      if [ ${ellipsis} -gt 3 ]; then
        ellipsis=1
      fi
    done
    tput rc
    tput ed
    if [ "${found}" = "${all}" ]; then
      echo "➤ Checking BMC connectivity (${found}/${all})... ✓ done"
    else
      echo "➤ Checking BMC connectivity (${found}/${all})... × failed"
      echo "The following $(( all - found )) BMCs could not be reached:"
      echo "${errors}"
      echo "Please verify all servers are present and that the BMC DHCP assignment worked, or exclude their MAC addresses via the --exclude=\"${error_macs[@]}\" parameter."
      exit 1
    fi
  fi
}

function error_guidance() {
  if [ "${PROVISION_TYPE}" = "lokomotive" ]; then
    echo "If individual nodes did not come up, you can retry later with:"
    echo "  cd lokomotive; lokoctl cluster apply --skip-pre-update-health-check --confirm --verbose"
    echo "  ln -fs ${ASSET_DIR}/cluster-assets/auth/kubeconfig ~/.kube/config"
    echo
    echo "Once the above command is successful, running the racker bootstrap command is not needed anymore if you want to change something."
    echo "To modify the settings you can then directly change the lokomotive/baremetal.lokocfg config file or the CLC snippet files lokomotive/cl/*yaml and run:"
    echo "  cd lokomotive; lokoctl cluster|component apply"
  else
    echo "If individual nodes did not come up, you can retry later with:"
    echo "  cd flatcar-container-linux; terraform apply --auto-approve -parallelism=100"
    echo
    echo "Once the above command is successful, running the racker bootstrap command is not needed anymore if you want to change something."
    echo "To modify the settings you can then directly change the flatcar-container-linux/flatcar.tf config file"
    echo "or the CLC snippet files flatcar-container-linux/cl/*yaml and run the above terraform command again."
  fi
}

function show_progress() {
  local STAGE="${STAGE-""}"
  local FAILED="${FAILED-""}"
  local ELLIPSIS="${ELLIPSIS-"..."}"
  local found=0
  local joined=0
  local name=""
  local names=""
  local mac=""
  local found_mac=""
  local all=${#MAC_ADDRESS_LIST[*]}
  if [ "${STAGE}" = "lokomotive-bringup" ] || [ "${STAGE}" = "flatcar-bringup" ] ; then
    for mac in ${MAC_ADDRESS_LIST[*]}; do
      if [ -f "${MAC_STATE}/${mac}" ]; then
        let found+=1
      fi
    done
    echo -n "➤ OS installation via PXE (${found}/${all})"
    if [ "${found}" = "${all}" ]; then
      echo "... ✓ done"
      if [ "${STAGE}" = "lokomotive-bringup" ]; then
      echo -n "➤ Kubernetes bring-up"
        names="$(get_node_names)"
        if [ "${FAILED}" = "0" ] || [ "${names}" != "" ]; then
          echo "... ✓ done"
          for name in ${names}; do
            # Only count those that we know
            found_mac="$(get_node_mac "${name}")"
            if [ "${found_mac}" != "" ] && [ "$(echo "${MAC_ADDRESS_LIST[*]}" | { grep "${found_mac}" || true ; } )" != "" ]; then
              let joined+=1
            fi
          done
          echo -n "➤ Cluster health check (${joined}/${all} nodes seen)"
          if [ "${FAILED}" = "0" ]; then
            echo "... ✓ done"
          elif [ "${FAILED}" = "" ]; then
            echo "${ELLIPSIS}"
          else
            echo "... × failed"
          fi
        elif [ "${FAILED}" != "" ]; then
          echo "... × failed"
        else
          echo "${ELLIPSIS}"
        fi
      fi
    else
      if [ "${FAILED}" = "" ]; then
        echo "${ELLIPSIS}"
      else
        echo "... × failed"
      fi
    fi
  elif [ "${STAGE}" = "lokomotive-components" ]; then
    echo -n "➤ Lokomotive component installation"
    if [ "${FAILED}" = "0" ]; then
      echo "... ✓ done"
    elif [ "${FAILED}" = "" ]; then
      echo "${ELLIPSIS}"
    else
      echo "... × failed"
    fi
  else
    true
  fi
}

function execute_and_show_progress() {
  local exec_command="$1"
  LOGFILE="logs/$(date '+%Y-%m-%d_%H-%M-%S')" # global variable pointing to last log file
  local ret=0
  ellipsis=1
  buffer=""
  # simple IPC mechanism, create a file descriptor in this process, allowing subtasks to check for existence and run as long as it is there
  exec {running_fd}>/dev/null
  running="/proc/$$/fd/${running_fd}"
  local lines_to_clear=5 # must match the maximum output of the show_progress function or be a bit longer for additional margin

  mkdir -p logs
  for x in $(seq ${lines_to_clear}); do
    echo # allocate lines to clear in advance in case we would hit the scroll buffer otherwise
  done
  # go back the printed lines
  tput cuu ${lines_to_clear}
  # save cursor position
  tput sc
  {
    # run as long as the file descriptor in the main process exists
    while [ -e "${running}" ]; do
      buffer=$(ELLIPSIS=$(printf '.%.0s' $(seq ${ellipsis})) show_progress)
      # restore cursor position
      tput rc
      # clear display downwards
      tput ed
      echo "${buffer}"
      sleep 1
      let ellipsis+=1
      if [ ${ellipsis} -gt 3 ]; then
        ellipsis=1
      fi
    done
  } &
  if [ "${STAGE}" = "flatcar-bringup" ]; then
    terraform plan -input=false &> "${LOGFILE}.plan" || true
  fi
  ${exec_command} &> "${LOGFILE}" || ret=$?
  # close file descriptor to tell subtasks that they should stop
  exec {running_fd}>&-
  # wait for subtask to finish
  wait
  tput rc
  tput ed
  FAILED="${ret}" show_progress
  return ${ret}
}

function execute_with_retry() {
  local exec_command="$1"
  local tries=0
  local ret=0
  local mac=""
  local name=""
  local names=""
  local found_mac=""
  local expected=""
  local hint_msg=""
  local exclude_opt=""
  macs_to_skip=()

  execute_and_show_progress "${exec_command}" || ret=$?
  while [ "${ret}" != 0 ]; do
    macs_to_skip=() # reset after each run
    if [ "${ret}" != "ask_again" ]; then
      hint_msg="You can see logs in ${PWD}/${LOGFILE}, run 'ipmi <MAC|DOMAIN> diag' for a short overview of a node, connect to the serial console via 'ipmi <MAC|DOMAIN>', or try to connect via SSH." # reset after each run
      if [ "${STAGE}" = "lokomotive-bringup" ] || [ "${STAGE}" = "flatcar-bringup" ] ; then
        for mac in ${MAC_ADDRESS_LIST[*]}; do
          if [ ! -f "${MAC_STATE}/${mac}" ]; then
           macs_to_skip+=("${mac}")
          fi
        done
        if [ "${#macs_to_skip[*]}" != 0 ]; then
          echo "Failed to provision the following ${#macs_to_skip[*]} nodes:"
          echo "${macs_to_skip[*]}"
          echo "${hint_msg}"
        else
          if [ "${STAGE}" = "lokomotive-bringup" ]; then
            names="$(get_node_names)"
            if [ "${names}" != "" ]; then
              expected="$(echo ${MAC_ADDRESS_LIST[*]} | tr ' ' '\n')"
              for name in ${names}; do
                found_mac="$(get_node_mac "${name}")"
                if [ "${found_mac}" != "" ]; then
                  expected=$(echo "${expected}" | { grep -v "${mac}" || true ; })
                fi
              done
              macs_to_skip=(${expected})
              if [ "${#macs_to_skip[*]}" != 0 ]; then
                echo "Failed cluster health check because the following ${#macs_to_skip[*]} nodes did not join the cluster:"
                echo "${macs_to_skip[*]}"
                echo "${hint_msg}"
              else
                echo "Failed to complete cluster health check despite all nodes joining."
                echo "${hint_msg}"
              fi
            else
              echo "Failed to bring up Kubernetes API."
              echo "${hint_msg}"
            fi
          fi
        fi
      elif [ "${STAGE}" = "lokomotive-components" ]; then
        echo "Failed to apply the Lokomotive components on the cluster."
        echo "${hint_msg}"
      fi
    fi
    if [ "${ONFAILURE}" = retry ] || [ "${ONFAILURE}" = exclude ]; then
      CHOICE=r
      let tries+=1
      if [ "${tries}" -gt "${RETRIES}" ]; then
        echo "Error after ${RETRIES} retries"
        error_guidance
        exit ${ret}
      fi
      if [ "${#macs_to_skip[*]}" != 0 ]; then
        echo "Something went wrong, removing ${#macs_to_skip[*]} nodes from config and retrying ${tries}/${RETRIES}"
        for mac in ${macs_to_skip[*]}; do
          NODE_MAC_ADDR="${mac}" PROVISION_TYPE="${PROVISION_TYPE}" "${SCRIPTFOLDER}"/exclude.sh
          MAC_ADDRESS_LIST=($(echo "${MAC_ADDRESS_LIST[*]}" | tr ' ' '\n' | grep -v "${mac}"))
          # CONTROLLERS_(BMC_)MAC etc not updated here because they are not used at this point
        done
      else
        echo "Something went wrong, retrying ${tries}/${RETRIES}"
      fi
    elif [ "${ONFAILURE}" = cancel ]; then
      CHOICE=c
    else
      exclude_opt=""
      if [ "${#macs_to_skip[*]}" != 0 ]; then
        exclude_opt=" [e]xclude nodes from cluster,"
      fi
      read -p "[r]etry,${exclude_opt} [c]ancel (default retry): " CHOICE
      if [ "${CHOICE}" = "e" ] && [ "${#macs_to_skip[*]}" != 0 ]; then
        for mac in ${macs_to_skip[*]}; do
          NODE_MAC_ADDR="${mac}" PROVISION_TYPE="${PROVISION_TYPE}" "${SCRIPTFOLDER}"/exclude.sh
          MAC_ADDRESS_LIST=($(echo "${MAC_ADDRESS_LIST[*]}" | tr ' ' '\n' | grep -v "${mac}"))
          # CONTROLLERS_(BMC_)MAC etc not updated here because they are not used at this point
        done
        CHOICE="r"
      fi
    fi
    if [ "${CHOICE}" = "" ] || [ "${CHOICE}" = "r" ]; then
      ret=0
      execute_and_show_progress "${exec_command}" || ret=$?
    elif [ "${CHOICE}" = "c" ]; then
      echo "Canceling"
      error_guidance
      exit ${ret}
    else
      ret="ask_again"
      continue
    fi
  done
}

if [ "$1" = create ]; then
  create_network
  sudo rm -rf "/opt/racker-state/matchbox/groups/"*
  get_assets
  create_certs
  create_ssh_key
  create_containers
  bmc_check
  gen_cluster_vars "${PROVISION_TYPE}"

  if [ "${PROVISION_TYPE}" = "lokomotive" ]; then
    MAC_STATE="${ASSET_DIR}/cluster-assets"
    if [ "${OLD_LOKOMOTIVE}" != "1" ]; then
      EXTRA_ARG="--skip-control-plane-update"
    else
      EXTRA_ARG=""
    fi
    STAGE="lokomotive-bringup" execute_with_retry "lokoctl cluster apply --verbose --skip-components --skip-pre-update-health-check ${EXTRA_ARG} --confirm"
    STAGE="lokomotive-components" execute_with_retry "lokoctl component apply"
    if [ -z "$USE_QEMU" ]; then
      echo "Setting up ~/.kube/config symlink for kubectl"
      ln -fs ../lokomotive/lokoctl-assets/cluster-assets/auth/kubeconfig ~/.kube/config
    fi
    echo "The cluster is ready."
    echo "Running the racker bootstrap command is not needed anymore if you want to change something."
    echo "To modify the settings you can now directly change the lokomotive/baremetal.lokocfg config file or the CLC snippet files lokomotive/cl/*yaml and run:"
    echo "  cd lokomotive; lokoctl cluster|component apply"
  else
    mkdir "${FLATCAR_ASSETS_DIR}"
    MAC_STATE="${FLATCAR_ASSETS_DIR}"
    STAGE="flatcar-init" execute_with_retry "terraform init -input=false"
    STAGE="flatcar-bringup" execute_with_retry "terraform apply --auto-approve -input=false -parallelism=100"
    echo "The nodes are provisioned with a minimal Ignition configuration (see the Container Linux Config files in flatcar-container-linux/cl/)."
    echo "Running the racker bootstrap command is not needed anymore if you want to change something."
    echo "To modify the settings you can now directly change the flatcar-container-linux/flatcar.tf config file"
    echo "or the CLC snippet files flatcar-container-linux/cl/*yaml and run:"
    echo "  cd flatcar-container-linux; terraform apply --auto-approve -parallelism=100"
  fi
else
  if [ -n "$USE_QEMU" ]; then
    destroy_all
  fi
fi


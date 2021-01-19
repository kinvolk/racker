#!/bin/bash

set -euo pipefail

# This script will be split appart, everything guarded with USE_QEMU is a dev helper while the rest goes on the mgmt node (possibly in a Docker image)
USE_QEMU=${USE_QEMU:-"1"}
if [ "$USE_QEMU" = "0" ]; then
  USE_QEMU=""
fi

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: USE_QEMU=1 $0 create|destroy" # TODO: add something like create-image to embed an Ignition config into a Flatcar image for the mgmt node?
  echo "TODO: Make sure you disable any firewall, e.g., run sudo systemctl disable --now firewalld"
  exit 1
fi
# TODO: setup trap?

SCRIPTFOLDER="$(dirname "$(readlink -f "$0")")"
cd "$SCRIPTFOLDER"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please do not run as root, sudo will be used where necessary"
  exit 1
fi

if [ "$(lokoctl version)" != "v0.5.0-335-g874975e9" ]; then
  echo "Correct lokoctl version not found in PATH, compile it from the branch kai/baremetal"
  exit 1
fi

ls controller_macs worker_macs > /dev/null || { echo "Add at least one MAC address for each file controller_macs and worker_macs" ; exit 1 ; }

CONTROLLER_AMOUNT=1
SUBNET_PREFIX="172.24.213"
if [ -n "$USE_QEMU" ]; then
  VM_MEMORY=2500
  VM_DISK=10
  INTERNAL_BRIDGE_NAME="pxe0"
  INTERNAL_BRIDGE_ADDRESS="${SUBNET_PREFIX}.1" # the bridge IP address will also be used for the management node containers, later when run in a VM, .0 should be used or no address since the external bridge can also be used to reach the nodes
  INTERNAL_BRIDGE_SIZE="24"
  INTERNAL_BRIDGE_BROADCAST="${SUBNET_PREFIX}.255"
  INTERNAL_DHCP_RANGE_LOW="${SUBNET_PREFIX}.128" # use the second half for DHCP, the first for static addressing
  INTERNAL_DHCP_RANGE_HIGH="${SUBNET_PREFIX}.254"
  INTERNAL_DHCP_NETMASK="255.255.255.0"
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

# TODO: generate these two files ("ordered", e.g., sorting alphabetically?), ARP ping or ssh into ToR switch (and exclude mgmt node itself), also get BMC MAC addrs
MAC_ADDRESS_LIST=($(cat controller_macs worker_macs))
NUM_NODES=${#MAC_ADDRESS_LIST[*]}

function get_matchbox_interface() {
  if [ -n "$USE_QEMU" ]; then
    echo "pxe0"
  else
    exit 1 # TODO: find eth interface to use for mgmt node
  fi
}

# idea: pick a stable cluster name from a wordlist, based on the MAC addr of the mgmt node
function cluster_name() {
  shuf -n 1 --random-source=/sys/class/net/"$(get_matchbox_interface)"/address wordlist.txt
}

function get_client_cert_dir() {
  local name="$(cluster_name)"
  [ -z "$name" ] && exit 1
  local p=~/"lokoctl-assets/${name}/.matchbox/"
  mkdir -p "$p"
  echo "$p"
}

# Use a private /24 subnet on an internal L2 network, part of 172.16.0.0/12 and assign the node number to the last byte
# Purpose is DHCP/PXE but also stable addressing of the nodes (TODO: the internal DHCP server using this should start at .128 and we return an error here for >=128)
function calc_ip_addr() {
  local node_nr="$1"
  if [ "${node_nr}" -ge 128 ]; then
    exit 1
  fi
  echo "${SUBNET_PREFIX}.${node_nr}"
}

function get_matchbox_ip_addr() {
  calc_ip_addr 1
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
    # Use a stable MAC address because it's also the matchbox interface, and we want to calculate a cluster name from it # TODO: later create a VM with that MAC
    sudo ip addr add dev "${INTERNAL_BRIDGE_NAME}" "${INTERNAL_BRIDGE_ADDRESS}/${INTERNAL_BRIDGE_SIZE}" broadcast "${INTERNAL_BRIDGE_BROADCAST}"

    # Setup NAT Internet access for the bridge (external, because the internal bridge DHCP does not announce a gateway)
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -t nat -A POSTROUTING -o $(ip route get 1 | grep -o -P ' dev .*? ' | cut -d ' ' -f 3) -j MASQUERADE

  else
    exit 1 # TODO: make sure to set up the private IP addr (get_matchbox_ip_addr) before running (e.g., rewriting networkd files w/ static/DHCP, run networkctl reload)
  fi
}

function create_certs() {
  # TODO: maybe skip if existing ones can be kept
  local name="$(cluster_name)"
  [ -z "$name" ] && exit 1
  local server_dir=~/"lokoctl-assets/${name}/matchbox/certs"
  local cert_dir="$(get_client_cert_dir)"
  pushd scripts/tls 1>/dev/null

  echo "Generating certificates. Check scripts/tls/cert-gen.log for details"

  export SAN="IP.1:$(get_matchbox_ip_addr)"
  ./cert-gen

  mkdir -p "${server_dir}"
  cp server.key server.crt ca.crt "${server_dir}"

  cp ca.crt client.key client.crt "${cert_dir}"

  popd 1>/dev/null
}

function create_ssh_key() {
  if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -f ~/.ssh/id_rsa -N ''
  fi
}

function get_assets() {
  local name="$(cluster_name)"
  [ -z "$name" ] && exit 1
  local DOWNLOAD_DIR=~/"lokoctl-assets/${name}/matchbox/assets"
  mkdir -p "${DOWNLOAD_DIR}"

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
      echo "Skipping download of Flatcar Linux assets, since downloaded version is up to date"
      return
    fi
  fi

  scripts/get-flatcar stable current "${DOWNLOAD_DIR}"
  # TODO: pre-download terraform providers, docker images?
}

function destroy_containers() {
  docker stop matchbox || true
  docker rm matchbox || true

  sudo docker stop dnsmasq || true
  sudo docker rm dnsmasq || true


  if [ -n "$USE_QEMU" ]; then
    sudo docker stop dnsmasq-external || true
    sudo docker rm dnsmasq-external || true
  fi
}

# DHCP/PXE on the internal bridge
function prepare_dnsmasq_conf() {
  local name="$(cluster_name)"
  [ -z "$name" ] && exit 1

  mkdir -p ~/"lokoctl-assets/${name}/dnsmasq"
  sed \
    -e "s/{{DHCP_RANGE_LOW}}/$INTERNAL_DHCP_RANGE_LOW/g" \
    -e "s/{{DHCP_RANGE_HIGH}}/$INTERNAL_DHCP_RANGE_HIGH/g" \
    -e "s/{{DHCP_NETMASK}}/$INTERNAL_DHCP_NETMASK/g" \
    -e "s/{{BRIDGE_NAME}}/$INTERNAL_BRIDGE_NAME/g" \
    -e "s/{{MATCHBOX}}/$(get_matchbox_ip_addr)/g" \
    < dnsmasq.conf.template > ~/"lokoctl-assets/${name}/dnsmasq/dnsmasq.conf"
}

# regular DHCP on the external bridge (as libvirt would do)
function prepare_dnsmasq_external_conf() {
  local name="$(cluster_name)"
  [ -z "$name" ] && exit 1

  # TODO: add static IP addrs
  mkdir -p ~/"lokoctl-assets/${name}/dnsmasq"
  sed \
    -e "s/{{DHCP_RANGE_LOW}}/$EXTERNAL_DHCP_RANGE_LOW/g" \
    -e "s/{{DHCP_RANGE_HIGH}}/$EXTERNAL_DHCP_RANGE_HIGH/g" \
    -e "s/{{DHCP_ROUTER_OPTION}}/$EXTERNAL_DHCP_ROUTER_OPTION/g" \
    -e "s/{{DHCP_NETMASK}}/$EXTERNAL_DHCP_NETMASK/g" \
    -e "s/{{BRIDGE_NAME}}/$EXTERNAL_BRIDGE_NAME/g" \
    < dnsmasq-external.conf.template > ~/"lokoctl-assets/${name}/dnsmasq/dnsmasq-external.conf"
}

function create_containers() {
  destroy_containers
  local name="$(cluster_name)"
  [ -z "$name" ] && exit 1

  mkdir -p ~/"lokoctl-assets/${name}/matchbox/groups"
  docker run --name matchbox \
    -d \
    --net=host \
    -v ~/"lokoctl-assets/$(cluster_name)/matchbox/certs:/etc/matchbox:Z" \
    -v ~/"lokoctl-assets/$(cluster_name)/matchbox/assets:/var/lib/matchbox/assets:Z" \
    -v ~/"lokoctl-assets/$(cluster_name)/matchbox:/var/lib/matchbox" \
    -v ~/"lokoctl-assets/$(cluster_name)/matchbox/groups:/var/lib/matchbox/groups" \
    quay.io/coreos/matchbox:v0.7.0 "-address=$(get_matchbox_ip_addr):8080" \
    -log-level=debug "-rpc-address=$(get_matchbox_ip_addr):8081"

  prepare_dnsmasq_conf

  sudo docker run --name dnsmasq \
    -d \
    --cap-add=NET_ADMIN \
    -v ~/"lokoctl-assets/${name}/dnsmasq/dnsmasq.conf:/etc/dnsmasq.conf:Z" \
    --net=host \
    quay.io/coreos/dnsmasq:v0.5.0 -d

  prepare_dnsmasq_external_conf

  sudo docker run --name dnsmasq-external \
    -d \
    --cap-add=NET_ADMIN \
    -v ~/"lokoctl-assets/${name}/dnsmasq/dnsmasq-external.conf:/etc/dnsmasq.conf:Z" \
    --net=host \
    quay.io/coreos/dnsmasq:v0.5.0 -d
}

function destroy_nodes() {
  if [ -n "$USE_QEMU" ]; then
  echo "Destroying nodes..."
  for num in $(seq 1 $NUM_NODES); do
    sudo virsh destroy "node${num}" || true
    sudo virsh undefine "node${num}" || true
  done

  sudo virsh pool-refresh default

  for num in $(seq 1 $NUM_NODES); do
    sudo virsh vol-delete --pool default "node${num}.qcow2" || true
  done
  fi
}

# TODO: later add the mgmt node vm
function create_nodes() {
  destroy_nodes
  if [ -n "$USE_QEMU" ]; then
    local -r common_virt_opts="--memory=${VM_MEMORY} --vcpus=1 --disk pool=default,size=${VM_DISK} --os-type=linux --os-variant=generic --noautoconsole --events on_poweroff=preserve --boot=hd,network"
    echo "Creating nodes..."
    for num in $(seq 1 $NUM_NODES); do
      sudo virt-install --name "node${num}" --network=bridge:"${INTERNAL_BRIDGE_NAME}",mac="${MAC_ADDRESS_LIST[$num - 1]}"  --network=bridge:"${EXTERNAL_BRIDGE_NAME}" ${common_virt_opts}
    done
  else
    exit 1 # TODO: use ipmitool to force pxe
  fi
}

function destroy_all() {
  destroy_nodes
  destroy_containers
  destroy_network
}

# kubectl needs to resolve the cluster names, write them to /etc/hosts
function add_to_etc_hosts() {
  local ip_addr="$1"
  local names="$2"
  sudo sed -i "/.*${names}/d" /etc/hosts
  echo "${ip_addr} ${names}" | sudo tee -a /etc/hosts
}

function gen_cluster_vars() {
  local count=1
  local ip_addr_suffix=2 # start with .2, the .1 address belongs to the mgmt node
  local name="controller"
  local controller_macs="["
  local worker_macs="["
  local controller_names="["
  local worker_names="["
  local clc_snippets="{"$'\n'
  local ip_address=""
  local controller_hosts=""
  local id=""
  for i in $(seq 1 ${CONTROLLER_AMOUNT}); do
    controller_hosts+="          $(calc_ip_addr $(( i + 1 ))) controller.$(cluster_name) controller${i}.$(cluster_name)\n"
    add_to_etc_hosts "$(calc_ip_addr $(( i + 1 )))" "controller.$(cluster_name)"
  done
  for mac in ${MAC_ADDRESS_LIST[*]}; do
    ip_address="$(calc_ip_addr ${ip_addr_suffix})"
    id="${name}${count}.$(cluster_name)"
    add_to_etc_hosts "${ip_address}" "${id}"
    if [ "$name" = "controller" ]; then
      controller_macs+="\"${mac}\", "
      controller_names+="\"${id}\", "
    else
      worker_macs+="\"${mac}\", "
      worker_names+="\"${id}\", "
    fi
    clc_snippets+="\"${id}\" = [\"${id}.yaml\"]"$'\n'
    sed -e "s/{{MAC}}/${mac}/g" -e "s#{{IP_ADDRESS}}#${ip_address}#g" -e "s/{{HOSTS}}/${controller_hosts}/g" <network.yaml.template >"${id}.yaml"
    if [ "$name" = "controller" ] && [ "$count" = "${CONTROLLER_AMOUNT}" ]; then
      count=0
      name="worker"
    fi
    let count+=1
    let ip_addr_suffix+=1
  done
  controller_macs+="]"
  worker_macs+="]"
  controller_names+="]"
  worker_names+="]"
  clc_snippets+=$'\n'"}"
  echo "cluster_name = \"$(cluster_name)\"" > lokocfg.vars
  echo "controller_macs = ${controller_macs}" >> lokocfg.vars
  echo "worker_macs = ${worker_macs}" >> lokocfg.vars
  echo "controller_names = ${controller_names}" >> lokocfg.vars
  echo "worker_names = ${worker_names}" >> lokocfg.vars
  echo "matchbox_addr = \"$(get_matchbox_ip_addr)\"" >> lokocfg.vars
  echo "clc_snippets = ${clc_snippets}" >> lokocfg.vars
}

if [ "$1" = create ]; then
  create_network
  rm -rf ~/"lokoctl-assets/$(cluster_name)/matchbox/groups/"*
  rm -rf ~/"lokoctl-assets/$(cluster_name)/terraform" ~/"lokoctl-assets/$(cluster_name)/terraform-modules"  ~/"lokoctl-assets/$(cluster_name)/cluster-assets"
  get_assets
  create_certs
  create_ssh_key
  create_containers

  (
    set -x
    # Wait a bit for Terraform to provision Matchbox (done through `lokoctl cluster apply` below).
    # This can be replaced with an approach like
    # https://kinvolk.io/docs/flatcar-container-linux/latest/provisioning/terraform/#updating-the-user-data-in-place-and-rerunning-ignition-instead-of-destroying-nodes
    # if it also falls back to ipmitool for PXE booting if the node is not reachable through SSH (yet)
    while ! curl -f "http://$(get_matchbox_ip_addr):8080/ignition?mac=${MAC_ADDRESS_LIST[0]}" > /dev/null 2> /dev/null; do
      sleep 1
    done
      create_nodes
  ) >/tmp/bringup.log 2>&1 &

  # TODO: use private IPs in null resource in lokomotive to reboot a node when the configuration changes (use ignition.config.url instead of local file):
  # https://kinvolk.io/docs/flatcar-container-linux/latest/provisioning/terraform/#updating-the-user-data-in-place-and-rerunning-ignition-instead-of-destroying-nodes

  # TODO: after running flatcar-install, use ipmitool on the node itself to permanently disable network booting (and test if it is really permanent)

  if [ "$(ssh-add -L | grep "$(head -n 1 ~/.ssh/id_rsa.pub | cut -d ' ' -f 1-2)")" = "" ]; then
    eval "$(ssh-agent)"
    ssh-add ~/.ssh/id_rsa
  fi

  gen_cluster_vars

  RET=0
  lokoctl cluster apply --verbose --skip-components || RET=$?

  if [ "$RET" = 0 ]; then
    PXERET=0
    wait $! || {
      err "Bring-up failed, the following logs may help:"
      cat /tmp/bringup.log
      PXERET=1
      RET=1
    }
    if [ "$PXERET" = 0 ]; then
      echo "Bring-up worked"
      lokoctl component apply
      echo "Now you can directly change the baremetal.lokocfg config and run: lokoctl cluster|component apply, this script here is not needed anymore (TODO: only once the terraform workaround is in place)"
    fi
  else
    kill $! || { echo "Bring-up terminated" ;}
    echo "Lokomotive failed"
  fi
  exit $RET
else
  if [ -n "$USE_QEMU" ]; then
    destroy_all
  fi
fi

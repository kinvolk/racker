#!/bin/bash

set -euo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-"lokomotive"}
CLUSTER_DIR="$PWD"
ASSET_DIR="${CLUSTER_DIR}/lokoctl-assets"
PUBLIC_IP_ADDRS=(${PUBLIC_IP_ADDRS:-"DHCP"}) # otherwise a space separated list of SECONDARY_MAC_ADDR-IP_V4_ADDR/SUBNETSIZE-GATEWAY-DNS
CONTROLLER_AMOUNT=${CONTROLLER_AMOUNT:-"1"}
CONTROLLER_TYPE=${CONTROLLER_TYPE:-"any"}
if [ "${CONTROLLER_TYPE}" = "any" ]; then
  # use the empty string to match all entries in the node type column of the nodes.csv file
  CONTROLLER_TYPE=""
fi
SUBNET_PREFIX=${SUBNET_PREFIX:-"172.24.213"}
RACKER_VERSION=$(cat /opt/racker/RACKER_VERSION 2> /dev/null || true)
if [ "${RACKER_VERSION}" = "" ]; then
  RACKER_VERSION="latest"
fi
USE_QEMU=${USE_QEMU:-"1"}
if [ "$USE_QEMU" = "0" ]; then
  USE_QEMU=""
fi

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: USE_QEMU=0|1 $0 create|destroy"
  echo "Note: Make sure you disable any firewall for DHCP on the bridge, e.g. on Fedora, run sudo systemctl disable --now firewalld"
  exit 1
fi

SCRIPTFOLDER="$(dirname "$(readlink -f "$0")")"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please do not run as root, sudo will be used where necessary"
  exit 1
fi

if [ "$(which lokoctl 2> /dev/null)" = "" ]; then
 echo "lokoctl version not found in PATH"
 exit 1
fi

function cancel() {
  echo "Canceling"
  exit 1
}
trap cancel INT

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
  NODES="$(tail -n +2 /usr/share/oem/nodes.csv | grep -v -f <(cat /sys/class/net/*/address) | sort)"
  FULL_MAC_ADDRESS_LIST=($(echo "$NODES" | cut -d , -f 1)) # sorted MAC addresses will be used to assign the IP addresses
  FULL_BMC_MAC_ADDRESS_LIST=($(echo "$NODES" | cut -d , -f 2))
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

  for mac in ${FULL_MAC_ADDRESS_LIST[*]}; do
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

    # Setup NAT Internet access for the bridge (external, because the internal bridge DHCP does not announce a gateway)
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -t nat -A POSTROUTING -o $(ip route get 1 | grep -o -P ' dev .*? ' | cut -d ' ' -f 3) -j MASQUERADE

  else
    sudo tee /etc/systemd/network/10-pxe.network <<-EOF
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
  fi
}

function create_certs() {
  local server_dir="/opt/racker-state/matchbox/certs"
  local cert_dir="/opt/racker-state/matchbox-client"
  tmp_dir=$(mktemp -d -t certs-XXXXXXXXXX)
  pushd "$tmp_dir" 1>/dev/null

  echo "Generating certificates. Check scripts/tls/cert-gen.log for details"

  export SAN="IP.1:$(get_matchbox_ip_addr)"
  "$SCRIPTFOLDER/scripts/tls/cert-gen"

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
      echo "Skipping download of Flatcar Linux assets, since downloaded version is up to date"
      return
    fi
  fi

  "$SCRIPTFOLDER/scripts/get-flatcar" stable current "${DOWNLOAD_DIR}"
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
  sudo mkdir -p "/opt/racker-state/dnsmasq"
  sudo chown -R $USER:$USER "/opt/racker-state/dnsmasq"
  sed \
    -e "s/{{DHCP_RANGE_LOW}}/$INTERNAL_DHCP_RANGE_LOW/g" \
    -e "s/{{DHCP_RANGE_HIGH}}/$INTERNAL_DHCP_RANGE_HIGH/g" \
    -e "s/{{DHCP_NETMASK}}/$INTERNAL_DHCP_NETMASK/g" \
    -e "s/{{BRIDGE_NAME}}/${PXE_INTERFACE}/g" \
    -e "s/{{MATCHBOX}}/$(get_matchbox_ip_addr)/g" \
    < "$SCRIPTFOLDER/dnsmasq.conf.template" > "/opt/racker-state/dnsmasq/dnsmasq.conf"
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
    sudo tee /opt/racker-state/matchbox-service <<-EOF
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

  if [ -n "$USE_QEMU" ]; then
  prepare_dnsmasq_external_conf

  sudo docker run --name dnsmasq-external \
    -d \
    --cap-add=NET_ADMIN \
    -v "/opt/racker-state/dnsmasq/dnsmasq-external.conf:/etc/dnsmasq.conf:Z" \
    --net=host \
    quay.io/coreos/dnsmasq:v0.5.0 -d
  fi
}

function destroy_nodes() {
  if [ -n "$USE_QEMU" ]; then
  echo "Destroying nodes..."
  for count in $(seq 1 $CONTROLLER_AMOUNT); do
    sudo virsh destroy "controller${count}.${CLUSTER_NAME}" || true
    sudo virsh undefine "controller${count}.${CLUSTER_NAME}" || true
  done
  for count in $(seq 1 $WORKER_AMOUNT); do
    sudo virsh destroy "worker${count}.${CLUSTER_NAME}" || true
    sudo virsh undefine "worker${count}.${CLUSTER_NAME}" || true
  done

  sudo virsh pool-refresh default

  for count in $(seq 1 $CONTROLLER_AMOUNT); do
    sudo virsh vol-delete --pool default "controller${count}.${CLUSTER_NAME}.qcow2" || true
  done
  for count in $(seq 1 $WORKER_AMOUNT); do
    sudo virsh vol-delete --pool default "worker${count}.${CLUSTER_NAME}.qcow2" || true
  done
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
  local name="controller"
  local controller_macs="["
  local worker_macs="["
  local controller_names="["
  local worker_names="["
  local clc_snippets="{"$'\n'
  local installer_clc_snippets="{"$'\n'
  local ip_address=""
  local controller_hosts=""
  local id=""
  local j=1
  sudo sed -i "/.*controller.${CLUSTER_NAME}/d" /etc/hosts
  for mac in ${CONTROLLERS_MAC[*]}; do
    controller_hosts+="          $(calc_ip_addr $mac) controller.${CLUSTER_NAME} controller${j}.${CLUSTER_NAME}\n"
    # special case not covered by add_to_etc_hosts function
    echo "$(calc_ip_addr $mac)" "controller.${CLUSTER_NAME}" | sudo tee -a /etc/hosts
    let j+=1
  done
  for mac in ${MAC_ADDRESS_LIST[*]}; do
    ip_address="$(calc_ip_addr $mac)"
    id="${name}${count}.${CLUSTER_NAME}"
    add_to_etc_hosts "${ip_address}" "${id}"
    if [ "$name" = "controller" ]; then
      controller_macs+="\"${mac}\", "
      controller_names+="\"${id}\", "
    else
      worker_macs+="\"${mac}\", "
      worker_names+="\"${id}\", "
    fi
    mkdir -p cl
    clc_snippets+="\"${id}\" = [\"cl/${id}.yaml\", \"cl/${id}-custom.yaml\"]"$'\n'
    sed -e "s/{{MAC}}/${mac}/g" -e "s#{{IP_ADDRESS}}#${ip_address}#g" -e "s/{{HOSTS}}/${controller_hosts}/g" -e "s#{{RACKER_VERSION}}#${RACKER_VERSION}#g" < "$SCRIPTFOLDER/network.yaml.template" > "cl/${id}.yaml"
    # PUBLIC_IP_ADDRS=(${PUBLIC_IP_ADDRS:-"DHCP"}) # otherwise a space separated list of SECONDARY_MAC_ADDR-IP_V4_ADDR/SUBNETSIZE-GATEWAY-DNS
    if [ "${PUBLIC_IP_ADDRS[0]}" != "DHCP" ]; then
      installer_clc_snippets+="\"${id}\" = [\"cl/${id}-custom.yaml\"]"$'\n'
      for entry in ${PUBLIC_IP_ADDRS[*]}; do
        unpacked=($(echo $entry | tr - ' '))
        secondary_mac="${unpacked[0]}"
        ipv4_addr_and_subnet="${unpacked[1]}"
        gateway="${unpacked[2]}"
        dns="${unpacked[3]}"
        if [ "$(grep ${mac} /usr/share/oem/nodes.csv | grep ${secondary_mac})" != "" ]; then
          tee -a "cl/${id}-custom.yaml" <<-EOF
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
    if [ "$name" = "controller" ] && [ "$count" = "${CONTROLLER_AMOUNT}" ]; then
      count=0
      name="worker"
    fi
    let count+=1
  done
  controller_macs+="]"
  worker_macs+="]"
  controller_names+="]"
  worker_names+="]"
  clc_snippets+=$'\n'"}"
  installer_clc_snippets+=$'\n'"}"
  # We escape $var as \$var for the bash heredoc to preserve it as Terraform string, use ${VAR} for the bash heredoc substitution.
  # \${var} would be for Terraform sustitution but it's not used; you can also use a nested terraform heredoc but better avoid it.
  # The "pxe_commands" variable is executed as command in a context that sets up "$mac" and "$domain" (but don't use "${mac}"
  # which would be a Terraform variable).
  tee lokocfg.vars <<-EOF
	cluster_name = "${CLUSTER_NAME}"
	asset_dir = "${ASSET_DIR}"
	controller_macs = ${controller_macs}
	worker_macs = ${worker_macs}
	controller_names = ${controller_names}
	worker_names = ${worker_names}
	matchbox_addr = "$(get_matchbox_ip_addr)"
	clc_snippets = ${clc_snippets}
	installer_clc_snippets = ${installer_clc_snippets}
EOF
  if [ -n "$USE_QEMU" ]; then
    tee -a lokocfg.vars <<-EOF
	kernel_console = []
	install_pre_reboot_cmds = ""
	pxe_commands = "sudo virt-install --name \$domain --network=bridge:${INTERNAL_BRIDGE_NAME},mac=\$mac  --network=bridge:${EXTERNAL_BRIDGE_NAME} --memory=${VM_MEMORY} --vcpus=1 --disk pool=default,size=${VM_DISK} --os-type=linux --os-variant=generic --noautoconsole --events on_poweroff=preserve --boot=hd,network"
EOF
  else
    # The first ipmitool raw command is used to disable the 60 secs timeout that clears the boot flag
    # The "ipmitool raw 0x00 0x08 0x05 0xe0 0x08 0x00 0x00 0x00" command can be replaced with "ipmitool chassis bootdev disk options=persistent,efiboot" once a new IPMI tool version is released
    tee -a lokocfg.vars <<-EOF
	kernel_console = ["console=ttyS1,57600n8", "earlyprintk=serial,ttyS1,57600n8"]
	install_pre_reboot_cmds = "docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} sh -c 'ipmitool raw 0x0 0x8 0x3 0x1f && ipmitool raw 0x00 0x08 0x05 0xe0 0x08 0x00 0x00 0x00'"
	pxe_commands = "${SCRIPTFOLDER}/pxe-boot.sh \$mac \$domain"
EOF
  fi

  if ! cmp --silent "$SCRIPTFOLDER/baremetal.lokocfg" baremetal.lokocfg; then
    cp "$SCRIPTFOLDER/baremetal.lokocfg" ./
  fi
}

if [ "$1" = create ]; then
  create_network
  sudo rm -rf "/opt/racker-state/matchbox/groups/"*
  rm -rf "${ASSET_DIR}/terraform" "${ASSET_DIR}/terraform-modules"  "${ASSET_DIR}/cluster-assets"
  get_assets
  create_certs
  create_ssh_key
  create_containers

  gen_cluster_vars

  lokoctl cluster apply --verbose --skip-components || { echo "If individual nodes did not come up, try: cd lokomotive; lokoctl cluster apply --skip-pre-update-health-check -v" ; exit 1; }
  lokoctl component apply
  if [ -z "$USE_QEMU" ]; then
    echo "Setting up ~/.kube/config symlink for kubectl"
    ln -fs "${ASSET_DIR}/cluster-assets/auth/kubeconfig" ~/.kube/config
  fi
  echo "The cluster is ready."
  echo "Running the racker bootstrap command is not needed anymore if you want to change something."
  echo "To modify the settings you can now directly change the lokomotive/baremetal.lokocfg config file or the CLC snippet files lokomotive/cl/*yaml and run:"
  echo "  cd lokomotive; lokoctl cluster|component apply"
else
  if [ -n "$USE_QEMU" ]; then
    destroy_all
  fi
fi

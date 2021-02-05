#!/bin/bash

set -euo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-"lokomotive"}
CLUSTER_DIR="$PWD"
ASSET_DIR="${CLUSTER_DIR}/lokoctl-assets"
CONTROLLER_AMOUNT=${CONTROLLER_AMOUNT:-"1"}
CONTROLLER_TYPE=${CONTROLLER_TYPE:-""} # an empty string means any node type
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
  PXE_INTERFACE="$(cat /usr/share/oem/pxe_interface || true)"
  if [ "${PXE_INTERFACE}" = "" ]; then
    echo "The PXE interface file /usr/share/oem/pxe_interface is missing"
    exit 1
  fi
  if [[ "${PXE_INTERFACE}" == *:* ]]; then
    PXE_INTERFACE="$(grep -m 1 "${PXE_INTERFACE}" /sys/class/net/*/address | cut -d / -f 5 | tail -n 1)"
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
  MATCHBOX_CMD="docker run --name matchbox \
    -d \
    --net=host \
    -v /opt/racker-state/matchbox/certs:/etc/matchbox:Z \
    -v /opt/racker-state/matchbox/assets:/var/lib/matchbox/assets:Z \
    -v /opt/racker-state/matchbox:/var/lib/matchbox \
    -v /opt/racker-state/matchbox/groups:/var/lib/matchbox/groups \
    quay.io/coreos/matchbox:v0.7.0 -address=$(get_matchbox_ip_addr):8080 \
    -log-level=debug -rpc-address=$(get_matchbox_ip_addr):8081"
  if [ -n "$USE_QEMU" ]; then
    $MATCHBOX_CMD
  else
    sudo tee /etc/systemd/system/matchbox.service <<-EOF
	[Unit]
	Description=matchbox server for PXE images and Ignition configuration
	Wants=docker.service
	After=docker.service
	[Service]
	Type=simple
	Restart=always
	RestartSec=5s
	TimeoutStartSec=0
	ExecStartPre=-docker rm -f matchbox
	ExecStartPre=${MATCHBOX_CMD}
	ExecStart=docker logs -f matchbox
	ExecStop=docker stop matchbox
	ExecStopPost=docker rm matchbox
	[Install]
	WantedBy=multi-user.target
EOF
    sudo systemctl enable matchbox.service
    sudo systemctl restart matchbox.service
  fi

  prepare_dnsmasq_conf

  DNSMASQ_CMD="docker run --name dnsmasq \
    -d \
    --cap-add=NET_ADMIN \
    -v /opt/racker-state/dnsmasq/dnsmasq.conf:/etc/dnsmasq.conf:Z \
    --net=host \
    quay.io/coreos/dnsmasq:v0.5.0 -d"
  if [ -n "$USE_QEMU" ]; then
    sudo ${DNSMASQ_CMD}
  else
    sudo tee /etc/systemd/system/dnsmasq.service <<-EOF
	[Unit]
	Description=dnsmasq DHCP/PXE/TFTP server
	Wants=docker.service
	After=docker.service
	[Service]
	Type=simple
	Restart=always
	RestartSec=5s
	TimeoutStartSec=0
	ExecStartPre=-docker rm -f dnsmasq
	ExecStartPre=${DNSMASQ_CMD}
	ExecStart=docker logs -f dnsmasq
	ExecStop=docker stop dnsmasq
	ExecStopPost=docker rm dnsmasq
	[Install]
	WantedBy=multi-user.target
EOF
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
    clc_snippets+="\"${id}\" = [\"${id}.yaml\"]"$'\n'
    sed -e "s/{{MAC}}/${mac}/g" -e "s#{{IP_ADDRESS}}#${ip_address}#g" -e "s/{{HOSTS}}/${controller_hosts}/g" -e "s#{{RACKER_VERSION}}#${RACKER_VERSION}#g" < "$SCRIPTFOLDER/network.yaml.template" >"${id}.yaml"
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
  echo "cluster_name = \"${CLUSTER_NAME}\"" > lokocfg.vars
  echo "asset_dir = \"${ASSET_DIR}\"" >> lokocfg.vars
  echo "controller_macs = ${controller_macs}" >> lokocfg.vars
  echo "worker_macs = ${worker_macs}" >> lokocfg.vars
  echo "controller_names = ${controller_names}" >> lokocfg.vars
  echo "worker_names = ${worker_names}" >> lokocfg.vars
  echo "matchbox_addr = \"$(get_matchbox_ip_addr)\"" >> lokocfg.vars
  echo "clc_snippets = ${clc_snippets}" >> lokocfg.vars
  if [ -n "$USE_QEMU" ]; then
    echo 'kernel_console = []' >> lokocfg.vars
    echo 'install_pre_reboot_cmds = ""' >> lokocfg.vars
    echo "pxe_commands = \"sudo virt-install --name \$domain --network=bridge:${INTERNAL_BRIDGE_NAME},mac=\$mac  --network=bridge:${EXTERNAL_BRIDGE_NAME} --memory=${VM_MEMORY} --vcpus=1 --disk pool=default,size=${VM_DISK} --os-type=linux --os-variant=generic --noautoconsole --events on_poweroff=preserve --boot=hd,network\"" >> lokocfg.vars
  else
    echo 'kernel_console = ["console=ttyS1,57600n8", "earlyprintk=serial,ttyS1,57600n8"]' >> lokocfg.vars
    echo "install_pre_reboot_cmds = \"docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} sh -c 'ipmitool chassis bootdev disk options=persistent,efiboot && ipmitool raw 0x00 0x08 0x05 0xe0 0x08 0x00 0x00 0x00'\"" >> lokocfg.vars
    local mapping=""
    for i in $(seq 0 $((${#MAC_ADDRESS_LIST[*]} - 1))); do
      mapping+="      ${MAC_ADDRESS_LIST[i]})
        bmcmac=${BMC_MAC_ADDRESS_LIST[i]}
        bmcipaddr=""
        step="poweroff"
        count=60
        while [ \$count -gt 0 ]; do
          count=\$((count - 1))
          sleep 1
          if [ \"\$bmcipaddr\" = \"\" ]; then
            bmcipaddr=\$(docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} sh -c \"arp-scan -q -l -x -T \$bmcmac --interface ${PXE_INTERFACE} | grep -m 1 \$bmcmac | cut -f 1\")
          fi
          if [ \"\$bmcipaddr\" = \"\" ]; then
            continue
          fi
          if [ \"\$step\" = poweroff ]; then
            docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} ipmitool -C3 -I lanplus -H \$bmcipaddr -U ${IPMI_USER} -P ${IPMI_PASSWORD} power off || continue
            step=bootdev
            continue
          elif [ \"\$step\" = bootdev ]; then
            docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} ipmitool -C3 -I lanplus -H \$bmcipaddr -U ${IPMI_USER} -P ${IPMI_PASSWORD} chassis bootdev pxe options=persistent || continue
            step=poweron
            continue
          else
            docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} ipmitool -C3 -I lanplus -H \$bmcipaddr -U ${IPMI_USER} -P ${IPMI_PASSWORD} power on || continue
            break
          fi
          break # not reached
        done
        if [ \$count -eq 0 ]; then
          echo \"error: failed forcing a PXE boot for \$domain installer\"
          exit 1
        fi
        ;;
"
    done
    tee -a lokocfg.vars <<-EOF
	pxe_commands = <<EOT
	case \$mac in
	$mapping
	      *)
	        echo "BMC MAC address not found"
	        exit 1
	esac
	EOT
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

  if [ "$(ssh-add -L | grep "$(head -n 1 ~/.ssh/id_rsa.pub | cut -d ' ' -f 1-2)")" = "" ]; then
    eval "$(ssh-agent)"
    ssh-add ~/.ssh/id_rsa
  fi

  gen_cluster_vars

  lokoctl cluster apply --verbose --skip-components
  lokoctl component apply
  if [ -z "$USE_QEMU" ]; then
    echo "Setting up ~/.kube/config symlink for kubectl"
    ln -fs "${ASSET_DIR}/cluster-assets/auth/kubeconfig" ~/.kube/config
  fi
  echo "Now you can directly change the baremetal.lokocfg config and run: lokoctl cluster|component apply, this script here is not needed anymore"
else
  if [ -n "$USE_QEMU" ]; then
    destroy_all
  fi
fi

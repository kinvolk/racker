#!/bin/bash

set -euo pipefail

PROVISION_TYPE=${PROVISION_TYPE:-"lokomotive"}
ONFAILURE=${ONFAILURE:-"ask"} # what to do on a provisioning failure, current choices: "ask", "retry", "cancel"
RETRIES=${RETRIES:-"3"} # maximal retries if ONFAILURE=retry
CLUSTER_NAME=${CLUSTER_NAME:-"lokomotive"}
CLUSTER_DIR="$PWD"
ASSET_DIR="${CLUSTER_DIR}/lokoctl-assets"
FLATCAR_ASSETS_DIR="${CLUSTER_DIR}/assets"
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
BACKUP_AWS_ACCESS_KEY=${BACKUP_AWS_ACCESS_KEY:-""}
BACKUP_AWS_SECRET_ACCESS_KEY=${BACKUP_AWS_SECRET_ACCESS_KEY:-""}
BACKUP_NAME=${BACKUP_NAME:-"lokomotive"}
BACKUP_S3_BUCKET_NAME=${BACKUP_S3_BUCKET_NAME:-""}
BACKUP_AWS_REGION=${BACKUP_AWS_REGION:-""}
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
        echo "both the gatway and dns settings are required when an IP address on the public interface is configured"
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
  local ip_address=""
  local bmc_mac=""
  local bmc_ip_address=""
  for mac in ${MAC_ADDRESS_LIST[*]}; do
    ip_address="$(calc_ip_addr ${mac})"
    echo "dhcp-host=${mac},${ip_address},infinite" >> "/opt/racker-state/dnsmasq/dnsmasq.conf"
    if [ -z "$USE_QEMU" ]; then
      bmc_mac=$(grep -m 1 "${mac}" /usr/share/oem/nodes.csv | cut -d , -f 2 | sed 's/ //g')
      bmc_ip_address="$(calc_ip_addr ${bmc_mac})"
      echo "dhcp-host=${bmc_mac},${bmc_ip_address},infinite" >> "/opt/racker-state/dnsmasq/dnsmasq.conf"
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
  echo "${ip_addr} ${names}" | sudo tee -a /etc/hosts
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

function gen_flatcar_vars() {
  local count=0
  local node_macs="["
  local node_names="["
  local clc_snippets="{"$'\n'
  local installer_clc_snippets="{"$'\n'
  local ip_Address=""
  local snippets_dir="cl"

  for mac in ${MAC_ADDRESS_LIST[*]}; do
    ip_address="$(calc_ip_addr $mac)"
    id="node-"${count}
    add_to_etc_hosts "${ip_address}" "${id}"
    node_macs+="\"${mac}\", "
    node_names+="\"${id}\", "

    mkdir -p ${snippets_dir}
    clc_snippets+="\"${id}\" = [\"${snippets_dir}/${id}.yaml\", \"${snippets_dir}/${id}-custom.yaml\"]"$'\n'
    sed -e "s/{{MAC}}/${mac}/g" -e "s#{{IP_ADDRESS}}#${ip_address}#g" -e "s/{{HOSTS}}//g" -e "s#{{RACKER_VERSION}}#${RACKER_VERSION}#g" < "$SCRIPTFOLDER/network.yaml.template" > "${snippets_dir}/${id}.yaml"
    if [ "${#PUBLIC_IP_ADDRS_LIST[*]}" != "0" ]; then
      installer_clc_snippets+="\"${id}\" = [\"${snippets_dir}/${id}-custom.yaml\"]"$'\n'
      for entry in ${PUBLIC_IP_ADDRS_LIST[*]}; do
        unpacked=($(echo $entry | tr - ' '))
        secondary_mac="${unpacked[0]}"
        ipv4_addr_and_subnet="${unpacked[1]}"
        gateway="${unpacked[2]}"
        dns="${unpacked[3]}"
        if [ "$(grep ${mac} /usr/share/oem/nodes.csv | grep ${secondary_mac})" != "" ]; then
          tee -a "${snippets_dir}/${id}-custom.yaml" <<-EOF
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
      echo > "${snippets_dir}/${id}-custom.yaml"
    fi
    let count+=1
  done
  node_macs+="]"
  node_names+="]"
  clc_snippets+=$'\n'"}"
  installer_clc_snippets+=$'\n'"}"
  # We escape $var as \$var for the bash heredoc to preserve it as Terraform string, use ${VAR} for the bash heredoc substitution.
  # \${var} would be for Terraform sustitution but it's not used; you can also use a nested terraform heredoc but better avoid it.
  # The "pxe_commands" variable is executed as command in a context that sets up "$mac" and "$domain" (but don't use "${mac}"
  # which would be a Terraform variable).
  tee terraform.tfvars <<-EOF
	asset_dir = "${FLATCAR_ASSETS_DIR}"
	node_macs = ${node_macs}
	node_names = ${node_names}
	matchbox_addr = "$(get_matchbox_ip_addr)"
	clc_snippets = ${clc_snippets}
	installer_clc_snippets = ${installer_clc_snippets}
EOF
  if [ -n "$USE_QEMU" ]; then
    tee -a terraform.tfvars <<-EOF
	kernel_console = []
	install_pre_reboot_cmds = ""
	pxe_commands = "sudo virt-install --name \$domain --network=bridge:${INTERNAL_BRIDGE_NAME},mac=\$mac  --network=bridge:${EXTERNAL_BRIDGE_NAME} --memory=${VM_MEMORY} --vcpus=1 --disk pool=default,size=${VM_DISK} --os-type=linux --os-variant=generic --noautoconsole --events on_poweroff=preserve --boot=hd,network"
EOF
  else
    # The first ipmitool raw command is used to disable the 60 secs timeout that clears the boot flag
    # The "ipmitool raw 0x00 0x08 0x05 0xe0 0x08 0x00 0x00 0x00" command can be replaced with "ipmitool chassis bootdev disk options=persistent,efiboot" once a new IPMI tool version is released
    tee -a terraform.tfvars <<-EOF
	kernel_console = ["console=ttyS1,57600n8", "earlyprintk=serial,ttyS1,57600n8"]
	install_pre_reboot_cmds = "docker run --privileged --net host --rm quay.io/kinvolk/racker:${RACKER_VERSION} sh -c 'ipmitool raw 0x0 0x8 0x3 0x1f && ipmitool raw 0x00 0x08 0x05 0xe0 0x08 0x00 0x00 0x00'"
	pxe_commands = "${SCRIPTFOLDER}/pxe-boot.sh \$mac \$domain"
EOF
  fi
  mkdir templates
  cp "$SCRIPTFOLDER"/flatcar/templates/base.yaml.tmpl templates/base.yaml.tmpl
  copy_script flatcar/variables.tf
  copy_script flatcar/versions.tf
  copy_script flatcar/flatcar.tf
}

function gen_cluster_vars() {
  local count=0
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
  local j=0
  sudo sed -i "/${SUBNET_PREFIX}./d" /etc/hosts
  sudo sed -i "/${CLUSTER_NAME}.${KUBERNETES_DOMAIN_NAME}/d" /etc/hosts
  for mac in ${CONTROLLERS_MAC[*]}; do
    sudo sed -i "/${CLUSTER_NAME}-etcd${j}.${KUBERNETES_DOMAIN_NAME}/d" /etc/hosts
    controller_hosts+="          $(calc_ip_addr $mac) ${CLUSTER_NAME}-etcd${j}.${KUBERNETES_DOMAIN_NAME} ${CLUSTER_NAME}-controller-${j}.${KUBERNETES_DOMAIN_NAME} ${CLUSTER_NAME}.${KUBERNETES_DOMAIN_NAME}\n"
    # special case not covered by add_to_etc_hosts function
    echo "$(calc_ip_addr $mac)" "${CLUSTER_NAME}.${KUBERNETES_DOMAIN_NAME} ${CLUSTER_NAME}-etcd${j}.${KUBERNETES_DOMAIN_NAME}" | sudo tee -a /etc/hosts
    let j+=1
  done
  for mac in ${MAC_ADDRESS_LIST[*]}; do
    ip_address="$(calc_ip_addr $mac)"
    id="${CLUSTER_NAME}-${name}-${count}.${KUBERNETES_DOMAIN_NAME}"
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
    if [ "${#PUBLIC_IP_ADDRS_LIST[*]}" != "0" ]; then
      installer_clc_snippets+="\"${id}\" = [\"cl/${id}-custom.yaml\"]"$'\n'
      for entry in ${PUBLIC_IP_ADDRS_LIST[*]}; do
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
  # We escape $var as \$var for the bash heredoc to preserve it as Terraform string, use ${VAR} for the bash heredoc substitution.
  # \${var} would be for Terraform sustitution but it's not used; you can also use a nested terraform heredoc but better avoid it.
  # The "pxe_commands" variable is executed as command in a context that sets up "$mac" and "$domain" (but don't use "${mac}"
  # which would be a Terraform variable).
  tee lokocfg.vars <<-EOF
	cluster_name = "${CLUSTER_NAME}"
	asset_dir = "${ASSET_DIR}"
	k8s_domain_name = "${KUBERNETES_DOMAIN_NAME}"
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

  copy_script baremetal.lokocfg

  if [ "$USE_VELERO" = "true" ]; then
    create_backup_credentials
    tee -a lokocfg.vars <<-EOF
	backup_name = "${BACKUP_NAME}"
	backup_s3_bucket_name = "${BACKUP_S3_BUCKET_NAME}"
	backup_aws_region = "${BACKUP_AWS_REGION}"
EOF
    copy_script velero.lokocfg
  fi
}

function error_guidance() {
  echo "If individual nodes did not come up, you can retry later with:"
  echo "  cd lokomotive; lokoctl cluster apply --skip-pre-update-health-check --confirm --verbose"
  echo "  ln -fs ${ASSET_DIR}/cluster-assets/auth/kubeconfig ~/.kube/config"
  echo
  echo "Once the above command is successful, running the racker bootstrap command is not needed anymore if you want to change something."
  echo "To modify the settings you can then directly change the lokomotive/baremetal.lokocfg config file or the CLC snippet files lokomotive/cl/*yaml and run:"
  echo "  cd lokomotive; lokoctl cluster|component apply"
}

function execute_with_retry() {
  exec_command="$1"
  tries=0
  ret=0

  $exec_command || ret=$?
  while [ "${ret}" != 0 ]; do
    if [ "${ONFAILURE}" = retry ]; then
      CHOICE=r
      if [ "${tries}" -gt "${RETRIES}" ]; then
        echo "Error after ${RETRIES} retries"
        error_guidance
        exit ${ret}
      fi
      let tries+=1
      echo "Something went wrong, retrying ${tries}/${RETRIES}"
    elif [ "${ONFAILURE}" = cancel ]; then
      CHOICE=c
    else
      read -p "[r]etry/[c]ancel (default retry): " CHOICE
    fi
    if [ "${CHOICE}" = "" ] || [ "${CHOICE}" = "r" ]; then
      ret=0
      $exec_command || ret=$?
    elif [ "${CHOICE}" = "c" ]; then
      echo "Canceling"
      error_guidance
      exit ${ret}
    else
      ret=1
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

  if [ "${PROVISION_TYPE}" = "lokomotive" ]; then
    gen_cluster_vars
    execute_with_retry "lokoctl cluster apply --verbose --skip-components --skip-pre-update-health-check --confirm"
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
    mkdir "${FLATCAR_ASSETS_DIR}"
    gen_flatcar_vars
    execute_with_retry "terraform init"
    execute_with_retry "terraform apply --auto-approve"
  fi
else
  if [ -n "$USE_QEMU" ]; then
    destroy_all
  fi
fi


#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: $0 COMMAND|-h|--help"
  echo "Commands:"
  echo "  create NODES_FILE MGMT_NODE_MAC MGMT_NODE_IMAGE DISK_FOLDER"
  echo "    Creates a QEMU VM for every entry in the nodes.csv file with primary and secondary NICS,"
  echo "    a public bridge with NAT, IP forwarding, and DHCP for the secondary NICs, an internal bridge for the primary NICs,"
  echo "    and IPMI simulators for the primary NICs connected to the bridge with a DHCP client in its own network namespace."
  echo "    The management node has the bridges swapped so that the primary NIC is on the public bridge while the secondary"
  echo "    NIC is on the L2 bridge and should itself serve DHCP/PXE."
  echo "    The VM image for the management node can be prepared beforehand and you can use IPMI serial console or SSH on the public bridge to access it."
  echo "    During setup the empty disk images for the other nodes are created with 10 GB and a 6 GB secondary disk in the DISK_FOLDER (must not contain whitespace)."
  echo "    Each VM node has 2.5 GB RAM (currently minimum for a working K8s cluster) except for the management node which has 1 GB RAM."
  echo
  echo "    The env var PUBLIC_BRIDGE_PREFIX defaults to 192.168.254 as prefix for the public bridge /24 subnet and can be customized."
  echo '    The env var QEMU_ARGS defaults to -nographic and can be customized to open VGA console windows (QEMU_ARGS="").'
  echo "    The IPMI user is USER and the password is PASS."
  exit 1
fi

/bin/which capsh &> /dev/null || { echo "capsh not found: Install the cpash binary from your distribution" > /dev/stderr ; exit 1 ; }
/bin/which ipmi_sim &> /dev/null || { echo "ipmi_sim not found: Install the ipmi_sim binary from your distribution" > /dev/stderr ; exit 1 ; }
/bin/which socat &> /dev/null || { echo "socat not found: Install the socat binary from your distribution" > /dev/stderr ; exit 1 ; }
/bin/which qemu-system-x86_64 &> /dev/null || { echo "qemu-system-x86_64 not found: Install the qemu-system-x86_64 binary from your distribution" > /dev/stderr ; exit 1 ; }
/bin/which qemu-img &> /dev/null || { echo "qemu-img not found: Install the qemu-img binary from your distribution" > /dev/stderr ; exit 1 ; }
/bin/which unshare &> /dev/null || { echo "unshare not found: Install the unshare binary from your distribution" > /dev/stderr ; exit 1 ; }
/bin/which nsenter &> /dev/null || { echo "nsenter not found: Install the nsenter binary from your distribution" > /dev/stderr ; exit 1 ; }
/bin/which dhclient &> /dev/null || { echo "dhclient not found: Install the dhclient binary from your distribution" > /dev/stderr ; exit 1 ; }
/bin/which ip &> /dev/null || { echo "ip not found: Install the ip binary from your distribution" > /dev/stderr ; exit 1 ; }
/bin/which docker &> /dev/null || { echo "docker not found: Install the docker binary (or Podman compability wrapper) from your distribution" > /dev/stderr ; exit 1 ; }
/bin/which sudo &> /dev/null || { echo "sudo not found: Install the sudo binary from your distribution" > /dev/stderr ; exit 1 ; }

PUBLIC_BRIDGE_PREFIX="${PUBLIC_BRIDGE_PREFIX:-"192.168.254"}"
SCRIPTFOLDER="$(dirname "$(readlink -f "$0")")"

function destroy_network() {
  echo "Destroying internal network bridge"
  sudo ip link delete internal-br type bridge || true

  echo "Destroying public network bridge"
  sudo ip link delete public-br type bridge || true
}

function create_network() {
  destroy_network

  echo "Creating public network bridge"
  sudo ip link add name public-br type bridge
  sudo ip link set public-br up
  sudo ip addr add dev public-br "${PUBLIC_BRIDGE_PREFIX}.1/24" broadcast "${PUBLIC_BRIDGE_PREFIX}.255"

  echo "Creating internal network bridge"

  sudo ip link add name internal-br type bridge
  sudo ip link set internal-br up

  # Setup NAT Internet access for the public bridge
  sudo iptables -P FORWARD ACCEPT
  sudo iptables -t nat -A POSTROUTING -o $(ip route get 1 | grep -o -P ' dev .*? ' | cut -d ' ' -f 3) -j MASQUERADE
}

# regular DHCP on the external bridge (as libvirt would do)
function prepare_dnsmasq_external_conf() {
  cat << EOF
no-daemon
dhcp-range=${PUBLIC_BRIDGE_PREFIX}.2,${PUBLIC_BRIDGE_PREFIX}.254,255.255.255.0
dhcp-option=3,${PUBLIC_BRIDGE_PREFIX}.1
log-queries
log-dhcp
except-interface=lo
interface=public-br
bind-interfaces
EOF
}

function destroy_containers() {
  echo "Destroying container dnsmasq-external"
  sudo docker stop dnsmasq-external || true
  sudo docker rm dnsmasq-external || true
}

function create_containers() {
  destroy_containers

  echo "Creating container dnsmasq-external"

  CONF=$(mktemp)
  prepare_dnsmasq_external_conf > "${CONF}"

  sudo docker run --name dnsmasq-external \
    -d \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    -v "${CONF}:/etc/dnsmasq.conf:Z" \
    --net=host \
    quay.io/poseidon/dnsmasq:d40d895ab529160657defedde36490bcc19c251f -d || { rm "${CONF}"; exit 1 ; }
  rm "${CONF}"
}

function command_file() {
  for entry in "${ENTRIES_MGMT_FIRST[@]}"; do
    unpack=(${entry})
    ID="${unpack[0]}"
    PRIMARY="${unpack[1]}"
    BMC="${unpack[2]}"
    SEC="${unpack[3]}"
    TAP0="${unpack[4]}"
    TAP1="${unpack[5]}"
    IMAGE="${unpack[6]}"
    STARTNOW="${unpack[7]}"
    ADDR="0x$(( ID + 1 ))0"
    cat << EOF
mc_setbmc ${ADDR}
mc_add ${ADDR} 0 no-device-sdrs 0x23 9 8 0x9f 0x1291 0xf02 persist_sdr
sel_enable ${ADDR} 1000 0x0a
sensor_add ${ADDR} 0 0 35 0x6f event-only
sensor_set_event_support 0x20 0 0 enable scanning per-state \
    000000000001111 000000000000000 \
    000000000001111 000000000000000
sensor_add ${ADDR} 0 1 0x01 0x01
sensor_set_value ${ADDR} 0 1 0x60 0
sensor_set_threshold ${ADDR} 0 1 settable 111000 0xa0 0x90 0x70 00 00 00
sensor_set_event_support 0x20 0 1 enable scanning per-state \
    000111111000000 000111111000000 \
    000111111000000 000111111000000
sensor_add ${ADDR} 0 2 37 0x6f
sensor_set_bit_clr_rest ${ADDR} 0 2 1 1
sensor_set_event_support ${ADDR} 0 2 enable scanning per-state \
    000000000000011 000000000000011 \
    000000000000011 000000000000011
mc_enable ${ADDR}
EOF
  done
}

function config_file() {
  echo 'name "ipmisim1"'
  for entry in "${ENTRIES_MGMT_FIRST[@]}"; do
    unpack=(${entry})
    ID="${unpack[0]}"
    PRIMARY="${unpack[1]}"
    BMC="${unpack[2]}"
    SEC="${unpack[3]}"
    TAP0="${unpack[4]}"
    TAP1="${unpack[5]}"
    IMAGE="${unpack[6]}"
    STARTNOW="${unpack[7]}"
    ADDR="0x$(( ID + 1 ))0"
    cat << EOF
set_working_mc ${ADDR}
startlan 1
addr 127.0.90.${ID}1 623
priv_limit admin
allowed_auths_callback none md2 md5 straight
allowed_auths_user none md2 md5 straight
allowed_auths_operator none md2 md5 straight
allowed_auths_admin none md2 md5 straight
guid a123456789abcdefa123456789abcdef
endlan
chassis_control "${SCRIPTFOLDER}/chassis ${ID} ${PRIMARY} ${BMC} ${SEC} ${TAP0} ${TAP1} ${IMAGE}"
poweroff_wait 1
kill_wait 1
serial 15 localhost 90${ID}2 codec VM
startcmd "${SCRIPTFOLDER}/qemu-wrap ${ID} ${PRIMARY} ${BMC} ${SEC} ${TAP0} ${TAP1} ${IMAGE} disk"
startnow ${STARTNOW}
sol "telnet:localhost:90${ID}3" 115200
user 1 true  ""     "test" user     10       none md2 md5 straight
user 2 true  "USER" "PASS" admin    10       none md2 md5 straight
EOF
  done
}

function destroy_sim() {
  for entry in "${ENTRIES_MGMT_FIRST[@]}"; do
    unpack=(${entry})
    ID="${unpack[0]}"
    PRIMARY="${unpack[1]}"
    BMC="${unpack[2]}"
    SEC="${unpack[3]}"
    TAP0="${unpack[4]}"
    TAP1="${unpack[5]}"
    IMAGE="${unpack[6]}"
    STARTNOW="${unpack[7]}"
    if [ "${ID}" != 1 ]; then
      echo "Removing ${IMAGE}"
      rm -f "${IMAGE}"
      rm -f "${IMAGE}.disk2"
    fi
    echo "Removing ${DISK_FOLDER}/node${ID}-bmc ${DISK_FOLDER}/node${ID}-bmc-work"
    sudo umount "${DISK_FOLDER}/node${ID}-bmc" || true
    sudo umount -l "${DISK_FOLDER}/node${ID}-bmc" || true
    sudo rm -rf "${DISK_FOLDER}/node${ID}-bmc" "${DISK_FOLDER}/node${ID}-bmc-work"
    echo "Destroying veth node${ID}bmc"
    sudo ip link delete "node${ID}bmc" type veth || true
    echo "Destroying TAP ${TAP0} and ${TAP1}"
    sudo ip link delete "${TAP0}" type tap || true
    sudo ip link delete "${TAP1}" type tap || true
  done
}

function create_sim() {
  destroy_sim
  for entry in "${ENTRIES_MGMT_FIRST[@]}"; do
    unpack=(${entry})
    ID="${unpack[0]}"
    PRIMARY="${unpack[1]}"
    BMC="${unpack[2]}"
    SEC="${unpack[3]}"
    TAP0="${unpack[4]}"
    TAP1="${unpack[5]}"
    IMAGE="${unpack[6]}"
    STARTNOW="${unpack[7]}"
    # Management node has swapped links with the primary NIC on the public bridge and the secondary NIC and BMC NIC on the internal bridge
    if [ "${ID}" = 1 ]; then
      target0=public-br
      target1=internal-br
    else
      target0=internal-br
      target1=public-br
    fi
    mkdir -p "${DISK_FOLDER}/node${ID}-bmc" "${DISK_FOLDER}/node${ID}-bmc-work"
    sudo mount -t overlay overlay -o lowerdir=/,upperdir="${DISK_FOLDER}/node${ID}-bmc",workdir="${DISK_FOLDER}/node${ID}-bmc-work" "${DISK_FOLDER}/node${ID}-bmc"
    sudo ip link add "node${ID}bmc" type veth peer name "node${ID}bmc0"
    sudo ip link set dev "node${ID}bmc0" address "${BMC}"
    sudo ip link set dev "node${ID}bmc" up
    sudo ip link set "node${ID}bmc" master "${target0}"
    exec {running_fd}>/dev/null
    running="/proc/$$/fd/${running_fd}"
    (
    set +e
    sudo unshare --mount-proc -n -R "${DISK_FOLDER}/node${ID}-bmc" sh -c "ip link set dev lo up; nsenter -a -t 1 ip link set node${ID}bmc0 netns \$\$; ip link set dev node${ID}bmc0 up; dhclient -d --no-pid & socat -T10 udp4-listen:623,reuseaddr,reuseport,fork exec:'nsenter -a -t 1 socat -T10 STDIO udp4\:127.0.90.${ID}1\:623' & while [ -e '${running}' ]; do sleep 1; done; kill 0; exit 0" &
    )
    sudo ip tuntap add "${TAP0}" mode tap
    sudo ip link set dev "${TAP0}" up
    sudo ip tuntap add "${TAP1}" mode tap
    sudo ip link set dev "${TAP1}" up
    sudo ip link set "${TAP0}" master "${target0}"
    sudo ip link set "${TAP1}" master "${target1}"
    if [ "${ID}" != 1 ]; then
      qemu-img create -f qcow2 "${IMAGE}" 10G
      qemu-img create -f qcow2 "${IMAGE}.disk2" 6G
    fi
  done
}

function cancel() {
  echo
  echo "Terminating"
  destroy_containers
  destroy_network
  destroy_sim
  kill 0
  exit 1
}
trap cancel INT

if [ "$1" = create ]; then
  if [ $# != 5 ]; then
    echo "Expected 4 arguments"
    exit 1
  fi
  NODES_CSV="$2"
  MGMT_NODE_MAC="$3"
  MGMT_NODE_IMAGE="$4"
  DISK_FOLDER="$5"

  NODES=$(tail -n +2 "${NODES_CSV}")
  MGMT_NODE=$(echo "${NODES}" | { grep "${MGMT_NODE_MAC}" || true ; })
  OTHER_NODES=$(echo "${NODES}" | { grep -v "${MGMT_NODE_MAC}" || true ; })
  MGMT_NODE_PRIMARY_MAC=$(echo "${MGMT_NODE}" | cut -d , -f 1 | xargs)
  OTHER_NODES_PRIMARY_MAC=$(echo "${OTHER_NODES}" | cut -d , -f 1 | xargs)
  MGMT_NODE_BMC_MAC=$(echo "${MGMT_NODE}" | cut -d , -f 2 | xargs)
  OTHER_NODES_BMC_MAC=$(echo "${OTHER_NODES}" | cut -d , -f 2 | xargs)
  MGMT_NODE_SEC_MAC=$(echo "${MGMT_NODE}" | cut -d , -f 3 | xargs)
  OTHER_NODES_SEC_MAC=$(echo "${OTHER_NODES}" | cut -d , -f 3 | xargs)
  PRIMARY_MACS=(${MGMT_NODE_PRIMARY_MAC} ${OTHER_NODES_PRIMARY_MAC})
  BMC_MACS=(${MGMT_NODE_BMC_MAC} ${OTHER_NODES_BMC_MAC})
  SEC_MACS=(${MGMT_NODE_SEC_MAC} ${OTHER_NODES_SEC_MAC})

  rm -rf /tmp/ipmi-sim
  mkdir -p /tmp/ipmi-sim

  # Array of white-space separated entries, first is the management node
  ENTRIES_MGMT_FIRST=()
  ID=1
  for i in $(seq 0 $(( ${#PRIMARY_MACS[@]} - 1 ))); do
    TAP0="node${ID}eth0"
    TAP1="node${ID}eth1"
    if [ "${ID}" = 1 ]; then
      IMAGE="${MGMT_NODE_IMAGE}"
      STARTNOW="true"
    else
      IMAGE="${DISK_FOLDER}/node${ID}.img"
      STARTNOW="false"
    fi
    ENTRIES_MGMT_FIRST+=("${ID} ${PRIMARY_MACS[$i]} ${BMC_MACS[$i]} ${SEC_MACS[$i]} ${TAP0} ${TAP1} ${IMAGE} ${STARTNOW}")
    ID=$(( ID + 1 ))
  done
  create_network
  create_containers
  create_sim

  echo "Press Ctrl-C to quit"
  config_file > /tmp/ipmi-sim/config_file
  command_file > /tmp/ipmi-sim/command_file
  # Allow the ipmi_sim process to bind to 623 because IPMI embedds the port into the protocol and with UDP forwarding from a different port it complains that the used port mismatches when trying to use the serial console
  sudo -E capsh --caps='cap_net_bind_service+eip cap_setpcap,cap_setuid,cap_setgid+ep' --keep=1 --user="$USER" --addamb=cap_net_bind_service -- -c 'exec ipmi_sim -d --config-file /tmp/ipmi-sim/config_file -f /tmp/ipmi-sim/command_file --nopersist -n'
  cancel
else
  echo "Unknown argument: $@"
fi

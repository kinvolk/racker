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

set -eu

NODES_FILE="/usr/share/oem/nodes.csv"
NODES_HEADER="Primary MAC address, BMC MAC address, Secondary MAC address, Node Type, Comments"
IFS=',' read -r -a NODES_HEADER_ARRAY <<< "$NODES_HEADER";

usage() {
  args=(
    "check                               : validate the files needed for using racker"
    "reset [-h, -racker-version, -nodes] : print racker version"
    "help                                : show usage"
  )

  echo "Usage:"
  for i in "${args[@]}"; do
    IFS=':' read arg desc <<< "${i}"
    printf " %-30s: " "$arg"
    echo "${desc}"
  done
  exit 1
}

exit_with_msg() {
  printf "$1"
  echo
  exit 1
}

is_mac_address() {
  [[ "${1:-}" =~ ^([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}$ ]] && return 0 || return 1
}

has_mac_address() {
  [[ "${1:-}" =~ ([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2} ]] && return 0 || return 1
}

field_exists() {
  [[ -z "${1:-}" ]] && return 0 || return 1
}

validate() {
  # Check if the file exists
  if [ ! -f $NODES_FILE ]; then
    exit_with_msg "Nodes file is missing: $NODES_FILE"
  fi

  # Check if the file is not empty
  num_lines=$(cat $NODES_FILE | wc -l)
  if [ $num_lines -lt 2 ]; then
    exit_with_msg "Error: The nodes file ($NODES_FILE) needs to start with a header and have at least one entry line in the form\n${NODES_HEADER}\n00:11:22:33:44:00, 00:11:22:33:44:01, 00:11:22:33:44:30, ,"
  fi

  # Check if the header looks like it has actual node contents
  header="$(cat $NODES_FILE | head -n1 )"
  for i in $header; do
    if has_mac_address "$i"; then
      exit_with_msg "Error: Looks like the header has a MAC address, the first line of the $NODES_FILE should be a header: $NODES_HEADER"
    fi
  done

  # The actual nodes information
  nodes="$(cat $NODES_FILE | tail -n+2 )"

  # Go through every node line
  line_num=2
  while IFS= read -r line; do
    # Go through the first fields (MAC addresses) and check if they are set and look like MAC addresses
    NUM_MAC_FIELDS=3
    for i in `seq $NUM_MAC_FIELDS`; do
      mac="$(echo $line | cut -d , -f $i | xargs)"
      if field_exists "$mac"; then
        exit_with_msg "Error in line $line_num: ${NODES_HEADER_ARRAY[$i - 1]} does not seem to be set"
      fi
      if ! is_mac_address "$mac"; then
        exit_with_msg "Error in line $line_num: ${NODES_HEADER_ARRAY[$i - 1]} is set as \"$mac\" and does not look like a MAC address"
      fi
    done

    NODE_TYPE_FIELD=$(($NUM_MAC_FIELDS + 1))
    node_type="$(echo $line | cut -d , -f $NODE_TYPE_FIELD)"
    if is_mac_address "$node_type"; then
      exit_with_msg "Error in line $line_num: ${NODES_HEADER_ARRAY[$NODE_TYPE_FIELD - 1]} looks like a MAC address"
    fi

    line_num=$(($line_num+1))
  done <<< "$nodes"

  echo "✓ $NODES_FILE looks valid"
}


if [ "${1:-}" = "check" ]; then
  validate
elif [ "${1:-}" = "-h" ] || [ "${1:-}" = "-help" ] || [ -z ${1:-} ]; then
  usage
else
  echo "Unknown command ${1:-}"
  usage
fi

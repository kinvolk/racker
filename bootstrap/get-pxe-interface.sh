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

PXE_INTERFACE="$(tail -n +2 /usr/share/oem/nodes.csv | grep -f <(cat /sys/class/net/*/address) | cut -d , -f 3)"
if [ "${PXE_INTERFACE}" = "" ]; then
  echo "Could not find PXE interface by secondary MAC address in /usr/share/oem/nodes.csv"
  exit 1
fi
# may have whitespace as prefix/suffix, thus use without quotes to get rid of it
PXE_INTERFACE=$(echo ${PXE_INTERFACE})
if [[ "${PXE_INTERFACE}" == *:* ]]; then
  PXE_INTERFACE="$(grep -m 1 "${PXE_INTERFACE}" /sys/class/net/*/address | cut -d / -f 5 | tail -n 1)"
else
  echo "Could not resolve PXE interface from ${PXE_INTERFACE}"
  exit 1
fi
echo "${PXE_INTERFACE}"

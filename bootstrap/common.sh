function get_node_names() {
  local names=""
  names=$(KUBECONFIG="${ASSET_DIR}/cluster-assets/auth/kubeconfig" kubectl get nodes -o json 2>/dev/null) && {
    names=$(echo "${names}" | jq -r '.items | [.[].metadata.name] | .[]') || names=""
  } || names=""
  echo "${names}"
}

function get_node_mac() {
  local name="$1"
  local mac=""
  # The name may or may not contain the k8s domain name, therefore, look for NAME.*json to not match any prefix
  mac="$(jq -r .selector.mac /opt/racker-state/matchbox/groups/install*"${name}".*json 2>/dev/null)" || mac=""
  echo "${mac}"
}

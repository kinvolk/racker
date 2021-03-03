module "flatcar-provisioning" {

  source = "git@github.com:kinvolk/lokomotive.git//assets/terraform-modules/matchbox-flatcar?ref=imran/baremetal-reprovisioning"

  count                    = length(var.node_names)
  http_endpoint            = "http://${var.matchbox_addr}:8080"
  cached_install           = "true"
  kernel_args              = ["flatcar.autologin"]
  install_to_smallest_disk = "true"
  ssh_keys                 = [file(pathexpand("~/.ssh/id_rsa.pub"))]
  asset_dir                = var.asset_dir
  kernel_console           = var.kernel_console
  pxe_commands             = var.pxe_commands
  install_pre_reboot_cmds  = var.install_pre_reboot_cmds
  node_name                = var.node_names[count.index]
  node_mac                 = var.node_macs[count.index]
  node_domain              = var.node_names[count.index]
  ignition_clc_config      = data.ct_config.node_clc_config[count.index].rendered
  installer_clc_snippets = [for path in lookup(var.installer_clc_snippets, var.node_names[count.index], []) : file(path)]
}

provider "matchbox" {
  ca          = file(pathexpand("/opt/racker-state/matchbox-client/ca.crt"))
  client_cert = file(pathexpand("/opt/racker-state/matchbox-client/client.crt"))
  client_key  = file(pathexpand("/opt/racker-state/matchbox-client/client.key"))
  endpoint    = "${var.matchbox_addr}:8081"
}

data "ct_config" "node_clc_config" {
  count = length(var.node_names)
  content = templatefile("${path.module}/templates/install.yaml.tmpl", {
    ssh_keys = jsonencode([file(pathexpand("~/.ssh/id_rsa.pub"))])
  })

  snippets = [for path in lookup(var.clc_snippets, var.node_names[count.index], []) : file(path)]
}

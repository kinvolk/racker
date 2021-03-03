variable "asset_dir" {
  type = string
}

variable "node_macs" {
  type = list(string)
}

variable "node_names" {
  type = list(string)
}

variable "clc_snippets" {
  type = map(list(string))
}

variable "installer_clc_snippets" {
  type = map(list(string))
}

variable "pxe_commands" {
  type = string
}

variable "kernel_console" {
  type = list(string)
}

variable "install_pre_reboot_cmds" {
  type = string
}

variable "matchbox_addr" {
  type = string
}

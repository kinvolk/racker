---
title: Preparing the Management Node
weight: 50
---

Racker is distributed as a container image but run locally (read more about this approach in the [development docs](../development/).

Racker assumes there is *the management node*, which runs Flatcar Container Linux and is customized with a declarative Ignition configuration. After the management node OS is installed, the rack metadata needs to be configured. This is a one time setup.

The sections below will drive users through the process of preparing the management node. Internet access is required.

## OS Installation

The management node should be provisioned with the latest Stable release of Flatcar Container Linux.
It is recommended to automate this in a PXE environment but manual installation is also possible.

### PXE-based installation with iPXE

Using the following iPXE script `install.ipxe` the management node OS installation can be automated.
The latest Flatcar Container Linux Stable release will be written to disk, then the kernel console parameters are customized, and finally IPMI is used to set persistent booting from disk in EFI mode before the automatic reboot into the installed OS happens.

The full URL for an iPXE script chain is `https://raw.githubusercontent.com/kinvolk/racker/main/management-node-ipxe/install.ipxe`.
Here are its contents:

```
#!ipxe
set base-url http://stable.release.flatcar-linux.net/amd64-usr/current
kernel ${base-url}/flatcar_production_pxe.vmlinuz initrd=flatcar_production_pxe_image.cpio.gz flatcar.first_boot=1 console=ttyS1,57600n8 earlyprintk=serial,ttyS1,57600n8 flatcar.autologin ignition.config.url=https://raw.githubusercontent.com/kinvolk/racker/main/management-node-ipxe/install-ignition.json
initrd ${base-url}/flatcar_production_pxe_image.cpio.gz
boot
```

The `flatcar.first_boot` flag will start Ignition which fetches the Ignition config from the given URL which in turn creates and enables the installation service.
When the node is not rebooting after 10 to 20 minutes there may be a problem. By accessing the serial or KVM console the installer service can be inspected with `systemctl status installer.service` and restarted with `sudo systemctl restart installer.service`.

If the default kernel console settings do not fit your hardware, you need to customize the Ignition and iPXE files.

### Alternative: Manual installation from a live OS

In principle all that needs to be done is to use a Linux live/in-memory OS and write the `flatcar_production_image.bin` file from `https://stable.release.flatcar-linux.net/amd64-usr/current/` to the target disk and reboot from disk.
The machine should be configured for permanent booting from disk.

The `flatcar-install` script which is used in the above Flatcar-based live OS can be downloaded and used to handle the image download and writing to disk.
It can be found under `https://raw.githubusercontent.com/kinvolk/init/flatcar-master/bin/flatcar-install`.

Here is an example invocation:

```
sudo ./flatcar-install -s
```

The `-s` flag will automatically find the smallest unmounted disk. Using `-d /dev/sdX` instead of `-s` can specify a particular disk to use.

Depending on your hardware you may have to mount the OEM partition `/dev/sdX6` and set kernel parameters via GRUB by creating a `grub.cfg` file on the partition.

Here is an example content for `grub.cfg` that configures autologin on the serial/KVM console and specifies the serial console settings:

```
set linux_append="flatcar.autologin"
set linux_console="console=ttyS1,57600n8 earlyprintk=serial,ttyS1,57600n8"
```

## Installing Racker

After installing the OS on the management node and booting it, the OS can be accessed through the serial or KVM console.
With autologin configured one should see a session for the `core` user. This is the only user which should be used on the management OS.
Elevating privileges is done through `sudo` which won't require a password.

The installation of Racker is done in a single command:

```
sudo docker run --rm --privileged --pid host quay.io/kinvolk/racker:latest
```

From now on Racker can be [updated](./usage/updating.md) with `racker update` or `racker upgrade` and the above command is not needed anymore.

## Setting up the rack metadata

Before racker can be used to provision the servers in the rack, it needs some basic information about the server hardware.
This metadata is stored in the following files under `/usr/share/oem/`.

* `ipmi_user` and `ipmi_password`: plain-text credentials for the BMCs
* `nodes.csv`: a comma-separated table of all the servers in the rack and their primary and secondary MAC addresses and BMC MAC addresses,
  optionally categorized by their type (HW specs)

  The management node itself is also part of the list. The secondary MAC address entries are optional if DHCP is used for
  public IP addresses, but at least for the management node it is required to identify the internal interface.

### Creating the BMC credential files

The BMCs are normally small computers sitting on the primary NIC of a server where they join the network with their own MAC address.
They run a firmware which offers remote control via the IPMI protocol.
The IPMI user and password has to be the same for all servers (except the management node).

Create the files on the management node by running these commands with the right user and password values:

```
echo MYUSER | sudo tee /usr/share/oem/ipmi_user
echo MYPASSWORD | sudo tee /usr/share/oem/ipmi_password
```

### Creating the node list with server MAC addresses

The management node assigns IP addresses for all servers in the rack on their NIC in the rack-internal network.
For that it needs the primary MAC addresses.
The BMCs also are part of that network and get IP addresses assigned. For that the management node also needs the BMC MAC addresses.
To find the right BMC for a server the management node will look in the list to find the right MAC address.

Also, the management node needs to know on which interface to serve the internal network.
This is discovered by having the management node be part of the list and its secondary MAC address is expected to be the one on the internal network.

All the other servers have their secondary MAC address on the public network and it will be used to configure static IP addresses if wanted.

Finally, the varying hardware specifications of the servers can be categorized in the form of a node type value.
The node type can be used to put controller or storage nodes in a Kubernetes cluster on a particular server hardware.

Save these values to the special `/usr/share/oem/nodes.csv` file.
You can use the VIM editor on the management node:
```
sudo vi /usr/share/oem/nodes.csv
```
Or edit the content somewhere else and later paste it after running this command (hit Ctrl-D to end the input):
```
sudo tee /usr/share/oem/nodes.csv > /dev/null
```

The first line is the header row which defines the columns that are expected:

```
Primary MAC address, BMC MAC address, Secondary MAC address, Node Type, Comments
```

The additional last column is unused and accepts free form comments.
After the first line the server data is saved in one line each. The values are separated by a comma.
The node type and comment is optional but the comma should be placed even if it does not surround a value.

For consistency, put the management node first.
It must have the secondary MAC address value be the MAC address from the NIC that is on the rack-internal network.

Afterwards, enter all the other servers of the rack by their primary MAC address which is the one on the rack-internal network, then the BMC MAC address on the rack-internal network, and the secondary MAC address which is on the public network.

Example `nodes.csv`:

```
Primary MAC address, BMC MAC address, Secondary MAC address, Node Type, Comments
00:11:22:33:44:00, 00:11:22:33:44:01, 00:11:22:33:44:30, small, mgmt node
00:11:22:33:44:10, 00:11:22:33:44:11, 00:11:22:33:44:40, small, controller
00:11:22:33:44:20, 00:11:22:33:44:21, 00:11:22:33:44:50, large, worker
```

### Creating a management SSH key

The management node needs its own SSH key to access the provisioned OS on each server.
The SSH key can also be used to access the management node from the outside instead of using the IPMI serial or KVM console.
It may also be used to access the provisioned servers from the outside.

The following command will create a `~/.ssh/id_rsa` private key which you should copy and hand out to the user:

```
racker factory gen-ssh-key
```

### Verifying the rack metadata

After the above steps have been completed, the entered data and the hardware wireing need to be checked for errors.

The existance of all metadata files and their syntax should be checked with the following command:

```
racker factory check
```

If no errors are reported, you can continue with a provisioning test.
The following command installs Flatcar Container Linux on all of the available servers through a Terraform configuration under `~/flatcar-container-linux/`.
[Terraform](https://www.terraform.io/) is a declarative provisioning tool.
On provisioning failures these problematic servers will be removed from the Terraform configuration.
Since this is only a quick test and access to the public network is not required, it does not matter if DHCP or static IP address assignment is used for the secondary NICs.
You can confirm all default choices of the bootstrap command:

```
racker bootstrap -onfailure exclude -provision flatcar
```

The provisioning may have finished with errors. You can review the status of the rack with the following command:

```
racker status
```

If the BMCs were not reachable, check their MAC addresses and the wireing of the NICs to the internal switch.
In case the internal subnet or the MAC address list was changed you should wait 2 minutes before retrying so that the BMCs had a chance to pick up the new IP addresses via DHCP.
If there was a previous DHCP configuration with a longer lease time, you can also try to power-cycle the rack to force a DHCP renewal or first switch to the old subnet with `racker bootstrap … -subnet-prefix a.b.c` and then run `ipmi --all lan set 1 ipsrc dhcp` which should trigger a DHCP renewal.
If IPMI static IP addressing was manually configured on the BMCs you have to switch the BMCs back to DHCP (either manually or by switching to the same subnet with `racker bootstrap … -subnet-prefix a.b.c` and then running `ipmi --all lan set 1 ipsrc dhcp`).

If the OS was not provisioned, connect to the problematic node via `ipmi MACADDR` and see whether the PXE-booted system hangs during the installation or whether the final OS hangs during bootup.
Check whether the internal NIC (the primary NIC) has an IP address and can reach the management node's internal IP address.
Also, inspect the log files under `~/flatcar-container-linux/logs/`.

If all went well, remove the folder with `rm -r ~/flatcar-container-linux/`.
The OS will still be provisioned on the servers until the end user provisions a new cluster.

### Schedule a racker update on next use for the end user

The final step before the rack is ready for the end user is to reset the Racker version information.
This will ensure that `racker update` will behave like `racker upgrade` on the first run and pull the latest available version:

```
racker factory reset -racker-version
```

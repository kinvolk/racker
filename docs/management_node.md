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

The `racker factory` mode will help setting up the following rack metadata files in `/usr/share/oem/`.

`ipmi_user` and `ipmi_password`: credentials for the BMCs

`nodes.csv`: a table of all the servers in the rack and their primary and secondary MAC addresses and BMC MAC addresses,
optionally categorized by their type (HW specs).
The management node itself is also part of the list. The secondary MAC address entries are optional if DHCP is used for
public IP addresses, but at least for the management node it is required to identify the internal interface.

Example `nodes.csv`:

```
Primary MAC address, BMC MAC address, Secondary MAC address, Node Type, Comments
00:11:22:33:44:00, 00:11:22:33:44:01, 00:11:22:33:44:30, red, mgmt node
00:11:22:33:44:10, 00:11:22:33:44:11, 00:11:22:33:44:40, red, controller
00:11:22:33:44:20, 00:11:22:33:44:21, 00:11:22:33:44:50, purple, worker
```

---
title: Preparing the Management Node
weight: 50
---

The installer for the management node is delivered as a container image but extracted in the host and
run locally.
The reason for this approach if that we can keep a very minimal dependency on
what's shipped in the OS (that's installed in the management node).
The assumption is that the management node runs	Flatcar	Container Linux, customized with a declarative Ignition configuration.
In the following sections an iPXE script for automated installation of the management node is provided.

After the management node OS is installed, the rack metadata needs to be configured. This is a one time setup.

## Ignition Configuration

does something like
`sudo docker run --rm --privileged --pid host quay.io/kinvolk/racker:latest`


## PXE-based installation with iPXE

ipxe script here

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

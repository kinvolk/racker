---
content_type: racker
title: Racker
linktitle: Racker
main_menu: true
weight: 40
---

Racker is a solution for provisioning Lokomotive and Flatcar Container Linux on racks, developed by [Kinvolk](https://kinvolk.io/).

Automated reprovisioning of nodes is a core principle and one of the rack servers takes the
role of a management node on a rack-internal L2 network used for PXE booting.

The assumption is that each server has a primary network interface where the BMC sits on
and a secondary interface. All primary interfaces except that of the management node are on
the internal L2 network together with the secondary interface of the management node,
while the primary interface of the management node and all secondary interfaces of all other
servers are on a public network. This allows to reach the management node's BMC from the outside
while the management node itself has full control over the BMCs of the rack, serving DHCP to
them and interfacing with IPMI to control the PXE booting.

The solution consist of an installer for the management node, which is run once, and a command line utility run on the management node at any later point.

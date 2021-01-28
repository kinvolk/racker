# Kinvolk Racker

This is Kinvolk's solution for provisioning Lokomotive and Flatcar Container Linux on racks.

Automated reprovisioning of nodes is a core principle and one of the rack servers takes the
role of a management node on a rack-internal L2 network used for PXE booting.

The assumption is that each server has a primary network interface where the BMC sits on
and a secondary interface. All primary interfaces except that of the management node are on
the internal L2 network together with the secondary interface of the mangaement node,
while the primary interface of the management node and all secondary interfaces of all other
servers are on a public network. This allows to reach the management node's BMC from the outside
while the management node itself has full controll over the BMCs of the rack, serving DHCP to
them and interfacing with IPMI to control the PXE booting.

## Installer

The installer is delivered as a container image but extracted in the host and
run locally.
The reason for this approach if that we can keep a very minimal dependency on
what's shipped in the OS (that's installed in the management node).

The modules that compose the installer (as well as how to build them) are
defined in the `./installer/conf.yaml` file.

### Build the installer

First compile the installer creator:

`make installer`

Then run the `build` tool (be sure to check out its options):

`cd ./installer && ./build`

Now push the resulting image.

### Run the installer

Once the image `racker:latest` has been created, you can run the installer on Flatcar Container Linux:

`sudo docker run --rm --privileged --pid host quay.io/kinvolk/racker:latest`

After that, all interaction is done with the `racker` command.

The `racker factory` mode will help setting up the rack metadata files in `/usr/share/oem/`.

TODO: Not implemented yet, the files have to be created manually:

`pxe_interface`: the MAC address of the management node's secondary interface

`ipmi_user` and `ipmi_password`: credentials for the BMCs

`nodes.csv`: a table of all the servers in the rack and their primary MAC addresses and BMC MAC addresses,
categorized by their type (HW specs)

Example `nodes.csv`:

```
Primary MAC address, BMC MAC address, Node Type, Comments
00:11:22:33:44:00, 00:11:22:33:44:01, red, mgmt node # for completeness the management node itself, will be ignored
00:11:22:33:44:10, 00:11:22:33:44:11, red, controller
00:11:22:33:44:20, 00:11:22:33:44:21, purple, worker
```

### Provisioning a Lokomotive Kubernetes cluster

Running `racker bootstrap` will PXE boot all servers on the rack and install Lokomotive.

From now on the cluster can be managed with `lokoctl`.

### Updating Racker

To fetch updates that are compatible with the current version, run `racker update`.

To upgrade to the latest version which may have breaking changes, run `racker upgrade`.

Both will update the `lokoctl` and `terraform` binaries, too.

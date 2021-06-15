# Kinvolk Racker

This is Kinvolk's solution for provisioning Lokomotive and Flatcar Container Linux on racks.

Automated reprovisioning of nodes is a core principle and one of the rack servers takes the
role of a management node on a rack-internal L2 network used for PXE booting.

The assumption is that each server has a primary network interface where the BMC sits on
and a secondary interface. All primary interfaces except that of the management node are on
the internal L2 network together with the secondary interface of the management node,
while the primary interface of the management node and all secondary interfaces of all other
servers are on a public network. This allows to reach the management node's BMC from the outside
while the management node itself has full control over the BMCs of the rack, serving DHCP to
them and interfacing with IPMI to control the PXE booting.

## Test it in VMs

You can use the [racker-sim](racker-sim/) `ipmi-env.sh` script to create a VM environment that simulates IPMI.
This allows you to run Racker without requiring a free rack.

## Installer

The installer is delivered as a container image but extracted in the host and
run locally.
The reason for this approach if that we can keep a very minimal dependency on
what's shipped in the OS (that's installed in the management node).

Since Racker runs locally, its container image default command extracts the Racker payload into `/opt/racker`, creates symbolic links in `/opt/bin` to its executables, sets up any systemd services, and thus expects to be run with privileged permissions.

The modules that compose the installer (as well as how to build them) are
defined in the `./installer/conf.yaml` file.

### Build the installer

First compile the installer creator:

`make all`

Now push the resulting image.

### Run the installer

Once the image `racker:latest` has been created, you can run the installer on Flatcar Container Linux:

`sudo docker run --rm --privileged --pid host quay.io/kinvolk/racker:latest`

After that, all interaction is done with the `racker` command.

The `racker factory` mode will help setting up the rack metadata files in `/usr/share/oem/`.

These files have to be created manually:

`ipmi_user` and `ipmi_password`: credentials for the BMCs

`nodes.csv`: a table of all the servers in the rack and their primary and secondary MAC addresses and BMC MAC addresses,
optionally categorized by their type (HW specs).
The management node itself is also part of the list. The secondary MAC address entries are optional if DHCP is used for
public IP addresses, but at least for the management node it is required to identify the internal interface.

Example `nodes.csv`:

```csv
Primary MAC address, BMC MAC address, Secondary MAC address, Node Type, Comments
00:11:22:33:44:00, 00:11:22:33:44:01, 00:11:22:33:44:30, red, mgmt node
00:11:22:33:44:10, 00:11:22:33:44:11, 00:11:22:33:44:40, red, controller
00:11:22:33:44:20, 00:11:22:33:44:21, 00:11:22:33:44:50, purple, worker
```

For details, read the [docs](docs/).

### Provisioning a Lokomotive Kubernetes cluster

Running `racker bootstrap` will PXE boot all servers on the rack and install Lokomotive.

From now on the cluster can be managed with `lokoctl`.

### Updating Racker

To fetch updates that are compatible with the current version, run `racker update`.

To upgrade to the latest version which may have breaking changes, run `racker upgrade`.

Both will update the `lokoctl` and `terraform` binaries, too.

### Lokomotive Baremetal Development Environment

The part of Racker which creates the Lokomotive configuration can be run stand-alone to set up libvirt QEMU instances on your laptop.
This is different from the [IPMI QEMU simulator environment](racker-sim/) which is preferred as it fully utilizes Racker.
However, for quick development of Racker/Lokomotive this is how to run it:

```
cd /var/tmp/
mkdir mycluster # "prepare.sh create" must run in an empty folder with just the controller_macs/worker_macs files
cd mycluster
echo 0c:42:a1:11:11:11 > controller_macs
echo 0c:42:a1:11:11:22 > worker_macs
# compile the right Lokomotive branch used in Racker (see installer/conf.yaml)
sudo rm -r /opt/racker/terraform/
sudo mkdir -p /opt/racker/terraform
sudo cp -r /home/$USER/kinvolk/lokomotive/assets/terraform-modules/matchbox-flatcar/* /opt/racker/terraform
PATH="$PATH:/home/$USER/kinvolk/lokomotive" /home/$USER/kinvolk/racker/bootstrap/prepare.sh create
[…]
PATH="$PATH:/home/$USER/kinvolk/lokomotive" lokoctl cluster apply # or any other things you want to do
[…]
# later destroy it again:
PATH="$PATH:/home/$USER/kinvolk/lokomotive" /home/$USER/kinvolk/racker/bootstrap/prepare.sh destroy
```

It will create two bridges, one for the internal PXE and one for the network with Internet access (using NAT).
Matchbox and dnsmasq are started as containers (when using Podman matchbox is a user container and dnsmasq a root container).
The `/opt/racker-state/` folder gets populated with the Flatcar image and the Matchbox configuration.

## Code of Conduct

Please refer to the Kinvolk [Code of Conduct](https://github.com/kinvolk/contribution/blob/master/CODE_OF_CONDUCT.md).

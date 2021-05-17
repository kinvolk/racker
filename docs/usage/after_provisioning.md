---
title: After Provisioning
weight: 65
---

Racker is used to help provision a cluster, checking its status, and keep the related tools/modules up to date.
After a cluster has been provisioned, the main tools for interacting with either Lokomotive or Flatcar have been mentioned in the sub-sections below, rather than Racker.
At this stage, the `racker` tool is used primarily only for getting the status and updating the tools related to the cluster management.

## OS Updates

While the initial Flatcar Container Linux OS version was provisioned by Racker, the auto-updating nature means that the OS can update at any time to a newer version when available.
This only requires a reboot and for Kubernetes this reboot is coordinated by the [FLUO](https://kinvolk.io/docs/lokomotive/0.7/how-to-guides/auto-update-flatcar/) component and without Kubernetes the [locksmith](https://kinvolk.io/docs/flatcar-container-linux/latest/setup/releases/update-strategies/) service handles this.

## Lokomotive Deployments

Once Lokomotive is provisioned, you will find a directory in the home folder
with a few files related to the Lokomotive cluster configuration.

Changing the configuration for the cluster itself can be done in the `baremetal.lokocfg` file.
Other `.lokocfg` files will be related to the [Lokomotive components](https://kinvolk.io/docs/lokomotive/latest/configuration-reference/components/)
they represent, depending
on what options were chosen during the provisioning phase.

For more information on the Lokomotive configuration, refer to the
[Lokomotive documentation](https://kinvolk.io/docs/lokomotive/latest/).

The `lokoctl` command is available for applying any changes to the configuration.

### Accessing the Web UI

The Lokomotive Web UI can either be preinstalled in `racker bootstrap` as a Lokomotive component or later installed through `lokoctl`.
Before it is usable, [authentication credentials](https://kinvolk.io/docs/headlamp/0.3/installation/) are required.
The easiest way is to create a Service Account with a token as secret:

```
kubectl -n kube-system create serviceaccount headlamp-admin
kubectl create clusterrolebinding headlamp-admin --serviceaccount=kube-system:headlamp-admin --clusterrole=cluster-admin
kubectl -n kube-system describe secret "$(kubectl -n kube-system get secrets | grep -m 1 headlamp-admin-token | cut -d " " -f 1)"
# copy the token printed after "token: "
```

For testing purposes without an Ingress node, the Web UI can be reached from the management node through double port forwarding, first from the Kubernetes Pod to the management node, then from the management node to the SSH client:

```
# on your computer:
ssh  -L 127.0.0.1:8080:127.0.0.1:8080 -N core@MGMTNODE # add -J USER@JUMPBOX to access the management node through a bastion host
# on the management node:
kubectl -n lokomotive-system port-forward svc/web-ui 8080:80
# now open http://127.0.0.1:8080 in your browser and paste the secret token to log in
```

### Applying a config change like registering more SSH keys

To register a new SSH public key on the cluster nodes, first go to the `~/lokomotive` directory on the management node.

Now edit the `baremetal.lokocfg` file to add your key to the `ssh_pubkeys = [file(pathexpand("~/.ssh/id_rsa.pub"))]` statement, e.g., for a pub key `~/.ssh/user.pub`:

```
ssh_pubkeys = [file(pathexpand("~/.ssh/id_rsa.pub")), file(pathexpand("~/.ssh/user.pub"))]
```

Take care of using the right (Terraform) HCL syntax, then apply the change to all nodes which is done by a reprovisioning:

```
lokoctl cluster apply
```

This should not take too long because the PXE boot will be skipped and only Ignition runs again with reformatting the rootfs.
Since this deletes OS state, controller nodes are not covered and you have to add the SSH keys there manually.

### Forcing a reprovisioning

You can reprovision a particular node, e.g., due to a temporary file system corruption or after replacing the hard disk.
To do so, first go to the `~/lokomotive` directory on the management node.

Remove the flag file named by the primary MAC address:

```
rm lokoctl-assets/cluster-assets/aa:bb:cc:dd:ee:ff
```

Now make a trivial no-op change in the Container Linux Config file of the node. E.g., alter the `Description=` value of the `boot-workaround-efi-disk-persist.service`:

```
vi cl/lokomotive-worker-0.k8s.localdomain.yaml
```

Now apply the change which is done by a full reprovisioning including a PXE boot to write the OS image:

```
lokoctl cluster apply
```

### Excluding a node

A faulty node may prevent a change operation to be completed. The node can be removed from the cluster configuration like done during the bootstrap.

First go to the `~/lokomotive` directory on the management node, then run:

```
NODE_MAC_ADDR=aa:bb:cc:dd:ee:ff PROVISION_TYPE=lokomotive /opt/racker/bootstrap/exclude.sh
```

This will remove the node from `lokocfg.vars`, its CLC YAML files from `cl/DOMAIN(-custom).yaml`, the `lokoctl-assets/cluster-assets/aa:bb:cc:dd:ee:ff` flag file, and the node's entries in `/etc/hosts`.

**Note:** If you intend to add it back later, keep a copy of the `/etc/hosts`, `lokocfg.vars`, and `cl/DOMAIN(-custom).yaml` files.

### Adding the node back

To add the node back, you can either restore the files or add the values manually back to the files.
The arrays in `lokocfg.vars` are ordered and the position of the entries have to match with those in other variables.
It's best to add the entries at the end when doing it manually. You can mimic the existing entries when editing.

* The variables `controller_macs` or `worker_macs` take the primary NIC's MAC address. The `controller_names` and `worker_names` variables need the full domain name.
* The `clc_snippets` map needs an entry to point to the `cl/DOMAIN(-custom).yaml` files and an `installer_clc_snippets` entry may be needed, too.
* The `cl/DOMAIN.yaml` file needs to have the networkd unit for the primary MAC address. You can see the expected internal IP address in `ipmi MAC diag`. The `cl/DOMAIN-custom.yaml` file may need to contain a networkd unit with the public static IP address for the secondary MAC address.
* There are single `/etc/hosts` entries with the internal IP address for the workers but the controllers have two entries, one for the common API server domain name.

## Flatcar Container Linux Deployments

After installing Flatcar Container Linux on the desired nodes, they are ready
to start being used.

Changing the configuration of the nodes can done done by editing the `cl/*yaml` files for each node or the `flatcar.tf` and `terraform.tfvars` files.
The YAML files have the Container Linux Config that gets transpiled to an Ignition config. The other files are Terraform files that use the baremetal provisioning module.

The `terraform apply` command will reprovision the nodes to apply the configuration changes.

### Applying a config change like registering more SSH keys                           

To register a new SSH public key on the cluster nodes, first go to the `~/flatcar-container-linux` directory on the management node.

Now edit the `flatcar.tf` file to add your key to the `ssh_keys = [file(pathexpand("~/.ssh/id_rsa.pub"))]` statement, e.g., for a pub key `~/.ssh/user.pub`:

```
ssh_keys = [file(pathexpand("~/.ssh/id_rsa.pub")), file(pathexpand("~/.ssh/user.pub"))]
```

Take care of using the right (Terraform) HCL syntax, then apply the change to all nodes which is done by a reprovisioning:

```
terraform apply -parallelism=100
```

This should not take too long because the PXE boot will be skipped and only Ignition runs again with reformatting the rootfs (this deletes OS state).

### Forcing a reprovisioning

You can reprovision a particular node, e.g., due to a temporary file system corruption or after replacing the hard disk.
To do so, first go to the `~/flatcar-container-linux` directory on the management node.

Remove the flag file named by the primary MAC address:

```
rm assets/aa:bb:cc:dd:ee:ff
```

Now make a trivial no-op change in the Container Linux Config file of the node. E.g., alter the `Description=` value of the `boot-workaround-efi-disk-persist.service`:

```
vi cl/node-0.yaml
```

Now apply the change which is done by a full reprovisioning including a PXE boot to write the OS image:

```
terraform apply
```

### Excluding a node

A faulty node may prevent a change operation to be completed. The node can be removed from the cluster configuration like done during the bootstrap.

First go to the `~/flatcar-container-linux` directory on the management node, then run:

```
NODE_MAC_ADDR=aa:bb:cc:dd:ee:ff PROVISION_TYPE=flatcar /opt/racker/bootstrap/exclude.sh
```

This will remove the node from `terraform.tfvars`, its CLC YAML files from `cl/`, the `assets/aa:bb:cc:dd:ee:ff` flag file, and the node's entries in `/etc/hosts`.

**Note:** If you intend to add it back later, keep a copy of the `/etc/hosts`, `terraform.tfvars`, and `cl/DOMAIN(-custom).yaml` files.

### Adding the node back

To add the node back, you can either restore the files or add the values manually back to the files.
The arrays in `terraform.tfvars` are ordered and the position of the entries have to match with those in other variables.
It's best to add the entries at the end when doing it manually. You can mimic the existing entries when editing.

* The variable `node_macs` takes the primary NIC's MAC address. The `node_names` variable needs the full domain name.
* The `clc_snippets` map needs an entry to point to the `cl/DOMAIN(-custom).yaml` files and an `installer_clc_snippets` entry may be needed, too.
* The `cl/DOMAIN.yaml` file needs to have the networkd unit for the primary MAC address. You can see the expected internal IP address in `ipmi MAC diag`. The `cl/DOMAIN-custom.yaml` file may need to contain a networkd unit with the public static IP address for the secondary MAC address.
* There are single `/etc/hosts` entries for the nodes with the internal IP address.

## Racker Status

The `racker status` command displays, among other information, the address for
the nodes, so one can use SSH or the IPMI serial console to access the nodes:

```
Provisioned: Lokomotive
Kubernetes API reached: yes
MAC address        BMC reached  Power   OS provisioned  Joined cluster   Hostnames
aa:bb:cc:dd:ee:11       ✓        on             ✓               ✓        l.k8s l-contr…
aa:bb:cc:dd:ee:22       ✓        on             ×               ×
aa:bb:cc:dd:ee:33       ✓        on             ✓               ✓        l-worker-2.k8s
```

When run as `racker status -full` it will also show the `ipmi diag` output (see below) for all nodes after the above table output.

## IPMI Helper

The IPMI interface allows to remote control a server through the BMC.
It is useful for debugging or turning servers on and off.
A small `ipmi` helper utility calls `ipmitool` with the right options.
It only needs the node's primary NIC or BMC MAC address, or full the domain name, or can run in batch mode for all node with `--all`:

```
$ ipmi -h
Usage: /opt/bin/ipmi domain|primary-mac|bmc-mac|--all diag|[ipmitool commands]
If no command is given, defaults to "sol activate" for attaching the serial console (should not be used with --all).
The "diag" command shows the BMC MAC address, BMC IP address, and the IPMI "chassis status" output.
This helper requires a tty and attaches stdin by default, for usage in scripts set the env vars USE_STDIN=0 USE_TTY=0 as needed.
```

It accepts any `ipmitool` subcommands plus the additional helper subcommand `diag`.

### The diag helper

The `ipmi NODE diag` helper is a shortcut to get a quick overview of a node:

```
$ ipmi lokomotive-worker-31.k8s.localdomain diag
BMC MAC address: aa:bb:cc:dd:ee:12
BMC IP address: 172.24.213.71
Node MAC address: aa:bb:cc:dd:ee:11
Internal IP address: 172.24.213.36
Internal host name: lokomotive-worker-31.k8s.localdomain
System Power         : on
Power Overload       : false
Power Interlock      : inactive
Main Power Fault     : false
Power Control Fault  : false
Power Restore Policy : previous
Last Power Event     : command
Chassis Intrusion    : inactive
Front-Panel Lockout  : inactive
Drive Fault          : false
Cooling/Fan Fault    : false
Sleep Button Disable : not allowed
Diag Button Disable  : not allowed
Reset Button Disable : allowed
Power Button Disable : allowed
Sleep Button Disabled: false
Diag Button Disabled : false
Reset Button Disabled: false
Power Button Disabled: false
Boot parameter version: 1
Boot parameter 5 is valid/unlocked
Boot parameter data: e008000000
 Boot Flags :
   - Boot Flag Valid
   - Options apply to all future boots
   - BIOS EFI boot
   - Boot Device Selector : Force Boot from default Hard-Drive
   - Console Redirection control : System Default
   - BIOS verbosity : Console redirection occurs per BIOS configuration setting (default)
   - BIOS Mux Control Override : BIOS uses recommended setting of the mux at the end of POST
```

### The serial console

When SSH does not work for some reason, the serial console is the only option to access the node.
The `ipmi NODE sol activate` command has a short form `ipmi NODE` to attach to the serial console:

```
$ ipmi aa:bb:cc:dd:ee:ff
Opening serial console, detach with ~~. (double ~ because you need to escape the ~ when already using SSH or a serial console, with two SSH connections it would be ~~~.)
[SOL Session operational.  Use ~? for help]
```

It will	run `ipmitool` in a Docker container and you have to make sure you detach correctly, otherwise the container keeps running.
You can look for an `ipmitool` container with `docker ps` and run `docker kill ID` to terminate it.
Proper detaching needs sending `(Enter)~.` to `ipmitool` but SSH also uses the same sequence to detach.
Assuming you have one SSH connection to the managment node, you would escape the `~` for `ipmitool` by typing it twice (`~~.`).
In case you don't use `ssh -J USER@JUMPHOST core@MGMTNODE` but manually chain multiple SSH connections, this could even become `~~~.` or more.

### The ipmitool subcommands

Various other subcommands are also available, the full list can be seen with `ipmi aa:bb:cc:dd:ee:ff help`.
The most relevant one is `chassis` which itself has subcommands again:

```
$ ipmi aa:bb:cc:dd:ee:ff chassis help
Chassis Commands:  status, power, identify, policy, restart_cause, poh, bootdev, bootparam, selftest
```

The output of the `ipmi NODE diag` helper includes the `chassis status` output.
The `power` subcommand has the `off` and `on` commands to shut a server down or turn it on:

```
$ ipmi aa:bb:cc:dd:ee:ff chassis power on
```

The `sensor` subcommand returns various hardware metrics like temperature, current, tension, power, fan speed, and so on.

The `bootdev` subcommand may be used to set booting from disk or similar if the server got misconfigured:

```
$ ipmi aa:bb:cc:dd:ee:ff chassis bootdev disk options=persistent,efiboot
# the above command currently needs to be run as follows due to a bug in ipmitool:
$ ipmi aa:bb:cc:dd:ee:ff raw 0x00 0x08 0x05 0xe0 0x08 0x00 0x00 0x00
```

The current settings can be seen with in the `diag` helper output or with `chassis bootparam get 5`.

**Note:** The servers may have a timer which disables the _valid_ bit of the boot flag, you should disable it as follows before trying to set a boot device:

```
$ ipmi aa:bb:cc:dd:ee:ff raw 0x0 0x8 0x3 0x1f
```

All sub commands that are non-interactive, i.e., almost everything except the serial console, can also run in batch mode to be applied for all servers:

```
$ ipmi --all chassis power off
```

## Adding new servers and replacing servers

When MAC addresses have changed due to a hardware replacement or when new servers were added you need to update the `/usr/share/oem/nodes.csv` file with the new MAC addresses.
You can mimic the other entries for the node type and whether a secondary MAC address is present.
Finally, run `racker bootstrap` again to provision a new cluster, which will destroy the old cluster.
In case the BMCs are not reachable, `racker bootstrap` may fail and you may need to check that the BMCs picked up the new IP addresses via DHCP.
If there was a previous DHCP configuration with a long lease time, you can also try to power-cycle the rack to force a DHCP renewal or first switch to the old subnet with `racker bootstrap … -subnet-prefix a.b.c` and then run `ipmi --all lan set 1 ipsrc dhcp` which should trigger a DHCP renewal.
If the IPMI static IP addressing was manually configured on the BMCs you have to switch the BMCs back to DHCP (either manually or by switching to the same subnet with `racker bootstrap … -subnet-prefix a.b.c` and then running `ipmi --all lan set 1 ipsrc dhcp`).

### Workaround for a running cluster

In case you can't destroy the running cluster, a workaround is to do some manual steps which can avoid recreating the cluster. Here are instructions about the required steps, where details are omitted you are expected to mimic the existing entries:

* After altering/extending the values of the `nodes.csv` file you need to allocate the internal IP addresses for the primary MAC address and the BMC MAC address. For new MAC addresses, add entries in `/opt/racker-state/dnsmasq/dnsmasq.conf` for unused IP addresses in the subnet. In case you replaced servers, update the entries of the old MAC addresses. Then run `systemctl restart dnsmasq.service`.
* Depending on whether Lokomotive or Flatcar Container Linux is used, go to the configuration folder and either edit the `lokocfg.vars` file or the `terraform.tfvars` file. The arrays are ordered and the position of the entries have to match with those in other variables. In case you replaced servers, update the entries of the old MAC address, otherwise add new entries at the end for the variables `*_macs` which takes the primary MAC address and `*_names` which takes the full domain name. The `clc_snippets` map needs an entry to point to the `cl/DOMAIN(-custom).yaml` files and an `installer_clc_snippets` entry may be needed, too.
* Create or update the `cl/DOMAIN.yaml` files to have the networkd unit for the primary MAC address. The `cl/DOMAIN-custom.yaml` file may need to contain a networkd unit for the public static IP address for the secondary MAC address.
* Add or update the entries in `/etc/hosts` for the internal IP addresses.
* Now run `lokoctl cluster apply` or `terraform apply` to provision the added nodes.
* **Note:** When creating a new cluster later by running `racker bootstrap` and it fails because the BMCs are reachable, check that they don't use old IP addresses but picked up new ones via DHCP but the automatic assignment will order the new IP addresses different to the manual assignment after the `nodes.csv` file got changed.
If there was a previous DHCP configuration with a long lease time, you can also try to power-cycle the rack to force a DHCP renewal or first switch to the old subnet with `racker bootstrap … -subnet-prefix a.b.c` and then run `ipmi --all lan set 1 ipsrc dhcp` which should trigger a DHCP renewal.
If the IPMI static IP addressing was manually configured on the BMCs you have to switch the BMCs back to DHCP (either manually or by switching to the same subnet with `racker bootstrap … -subnet-prefix a.b.c` and then running `ipmi --all lan set 1 ipsrc dhcp`).

## IPMI Credentials

The IPMI credentials under `/usr/share/oem/ipmi_(user|password)` are expected to stay valid for all nodes except the management node which doesn't have its BMC in the rack-internal network.
If you want to switch to stronger credentials, it's best to create a new IPMI account on all BMCs and when done, update the credential files and only then remove the old account.

**1.** You need to know which ID the old account has and which ID is free to use for the new account. First, find out which IPMI slot corresponds to the user name in `/usr/share/oem/ipmi_user`:

```
$ ipmi --all user list | grep "$(cat /usr/share/oem/ipmi_user)" | uniq
# The output may be:
# 2   MYUSER           true    false      true       ADMINISTRATOR
```

The first number is the slot number which you should not use for the new user because it's safer to keep this user to have a fallback until the new user is fully set up.

Now, find a free slot for the new user:

```
$ ipmi --all user list | sort -n | uniq
# The output may be:
# ID  Name           Callin  Link Auth  IPMI Msg   Channel Priv Limit
# 1                    true    false      true       USER
# 2   MYUSER           true    false      true       ADMINISTRATOR
# 3                    true    false      false      NO ACCESS
# 4                    true    false      false      NO ACCESS
# 5                    true    false      false      NO ACCESS
# 6                    true    false      false      NO ACCESS
# 7   operator         true    false      false      OPERATOR
# 8                    true    false      false      NO ACCESS
# 9                    true    false      false      NO ACCESS
# 10                   true    false      false      NO ACCESS
```

The IDs where no name is given are free but you can also repurpose an unused account.

**2.** Create the new user with the found free ID:

```
$ ipmi --all user set name NEWID MYUSER
$ ipmi --all user set password NEWID MYPASSWORD
$ ipmi --all user enable NEWID
# set the privilege to 4 which means ADMINISTRATOR
$ ipmi --all user priv NEWID 4
$ ipmi --all channel setaccess 1 NEWID callin=on ipmi=on link=off privilege=4
```

This is also how you would create additional regular users (not for Racker), but with privilege `2` for `USER` instead of `4` for `ADMINISTRATOR`.

**3.** Finally, you may switch Racker over to the new user:

```
$ echo MYUSER | sudo tee /usr/share/oem/ipmi_user
$ echo MYPASSWORD | sudo tee /usr/share/oem/ipmi_password
# to verify that it still works, run: racker status
```

**4.** Optionally, disable (or delete) the old user:

```
$ ipmi --all user disable OLDID
# delete: ipmi --all raw 0x6 0x45 0xOLDID 0xff 0xff 0xff 0xff 0xff 0xff 0xff 0xff 0xff 0xff 0xff 0xff 0xff 0xff 0xff 0xff
# beware: the ID 10 will have to be written in hex as 0xa
```

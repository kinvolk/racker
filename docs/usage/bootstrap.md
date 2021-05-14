---
title: Provisioning a cluster
weight: 60
---

The command `racker bootstrap` is used to provision either a Lokomotive Kubernetes cluster on the rack or
Flatcar Container Linux with an Ignition config on each server.
It prepares a configuration folder where the resulting cluster can be managed by the user.

When run without any arguments, `racker bootstrap` will start the racker wizard,
which can guide the user through a series of questions for configuring the
several aspects of the cluster.
All available nodes defined in `/usr/share/oem/nodes.csv` will be used for the cluster. Therefore, only one cluster can exist at a time.

Example:

```bash
$ racker bootstrap
? Choose what to provision  [Use arrows to move, type to filter]
> Lokomotive Kubernetes
  Flatcar Container Linux
```

The configuration options of the wizard have a corresponding command line parameter.
The following section presents the configuration options.

## Configuration options

There are three categories of configuration options.
One is for choosing to provision Lokomotive or Flatcar. It will be queried by the wizard if not specified on the command line.
The next category of configuration options depends on whether Lokomotive or Flatcar was chosen.
They will be queried by the wizard as long as no command line parameter is specified that is Lokomotive- or Flatcar-specific, otherwise the wizard will not query Lokomotive- or Flatcar-specific configuration options and choose the default values for the remaining unspecified options.

The last category of configuration options is only available as command line parameters.
They define how to handle failures and allow to skip failing servers upfront or ad-hoc.

### Provisioning Type Option

Provisioning Lokomotive results in a `~/lokomotive` folder on the management node which keeps the Lokomtive cluster configuration.
Similarly, provisioning Flatcar results in a `~/flatcar-container-linux` folder which keeps the Terraform configuration.
Only one can be active at a time and any existing folder has to be removed before provisioning can start.
For empty folders this happens automatically.

For non-interactive use, you can specify the following option on the command line:

```
$ racker bootstrap -h
[…]
  -provision string
        Value should be "lokomotive" or "flatcar"
[…]
```

### Lokomotive Configuration Options

This section presents the configuration options with their meaning and how they are shown in the wizard prompt.
For most options the default value will work, but if you do not have DHCP on the public network, you must supply a static IP address configuration in a specific format.
The wizard displays the default values in brackets and they can be confirmed by hitting the Enter key.

**Cluster name:** The cluster name is used to form the domain names of the cluster nodes, e.g., `lokomotive` is part of the domain name `lokomotive-controller-1.k8s.localdomain`:

```
? Choose a cluster name [? for help] (lokomotive)

```

**Control plane:** The control plane can exist of either 3 redundant controller nodes (recommended), or a single controller node. With 3 controllers the control plane stays operational when one controller is down. If two are down it can't serve requests but will recover as soon as one controller joins again, e.g., after repovisioning the node. Assuming that it's rare that two controllers are down at the same time, a 3 controller cluster provides a highly-available control plane:

```
? Select the type of control plane you want  [Use arrows to move, type to filter]
> Highly-available (HA) control plane (3 redundant controller nodes)
  Single-node control plane (no redundancy)
```

**Controller node type:** The controller nodes can be deployed on a certain server hardware when the node types are annotated in `/usr/share/oem/nodes.csv`.
The default is to choose any server hardware.
For example, assuming there are two node type annotations `small` and `large`, one could decide to use the `small` type for the Kubernetes control plane and use the remaining `small` and all `large` nodes for the Kubernetes workers:

```
? Choose a server type for the controller nodes  [Use arrows to move, type to filter, ? for more help]
> any
  small
  large
```

**IP address assignment:** The IP addresses on the public network, where the secondary NIC of the nodes is at, can either be assigned by a DHCP server in your network or manually through static assignment.
In both cases each node needs an IP address which can reach the Internet but it's not required that this address is itself reachable from the Internet.
However, being reachable from the Internet may be needed for, e.g., accessing the cluster from the outside or for special Kubernetes Ingress nodes.
The default is DHCP:

```
? Choose how you want to assign the IP addresses  [Use arrows to move, type to filter, ? for more help]
> Use DHCP
  Configure manually
```

The manual configuration happens in a text editor which expects an INI-like format for the assignment entries.
Each entry has the following format where `aa:bb:cc:dd:ee:ff` is your secondary MAC address of the node,
`11.22.33.44` is your static IP address for the node,
`/22` is your subnet in which the node can communicate in locally,
`11.22.33.1` is your local gateway and `1.2.3.4` is your DNS server:

```
[aa:bb:cc:dd:ee:ff]
ip_addr = 11.22.33.44/22
gateway = 11.22.33.1
dns = 1.2.3.4
```

The entries are identified by the MAC address and if you don't
enter an IP address, this entry will be ignored, including any DNS
and gateway settings. For ignored entries DHCP is used.
The first entry with an IP address also needs the gateway and DNS to
be configured. Any following entries will reuse the same gateway and
DNS unless they overwrite it (at which point these will be the ones
reused in following entries).

Lines which start with a `#` are ignored at any place,
but comments cannot be appended to the end of an entry line.

To cancel configuring IP addresses, leave the editor if you did not
make changes, and otherwise remove the changes or delete all content.

It is recommended to copy and edit the contents to your laptop to have a backup. From there you can paste them into the editor, or later use the command line parameter to read them in from a config file (here `ip_addrs`):

```
racker bootstrap -provision lokomotive […] -ip-addrs "$(cat ip_addrs)"
```

**Kubernetes domain name:** The Kubernetes domain name is appended as part of the full domain name of each node.
The `/etc/hosts` files are used through systemd-resolved to resolve the internal names to IP addresses on the rack-internal network.
You can also use a public domain and configure the DNS records manually to point to the external IP address.
This way you can use SSH and `kubectl` from the outside, too, instead of going through the management node.
In any case, the cluster bring up will directly work without further action:

```
? Choose a Kubernetes domain name that is appended to the host name of each node. It is used internally but you can also use a public domain and set its records manually. [? for help] (k8s.localdomain) 
```

**Subnet prefix:** The subnet prefix of the rack-internal network defines the IP addresses of the BMCs and the internal NICs.
Two racks can have the same subnet prefix because the networks don't known about each other.
Therefore, you should only change this if the default clashes with the external network.
If you had another value before, getting IPMI connectivity may take up to 2 minutes because the BMCs have to pick up the new IP addresses via DHCP.
If there was a previous DHCP configuration with a longer lease time, you can also try to power-cycle the rack to force a DHCP renewal or first switch to the old subnet with `racker bootstrap … -subnet-prefix a.b.c` and then run `ipmi --all lan set 1 ipsrc dhcp` which should trigger a DHCP renewal.
If the IPMI static IP addressing was manually configured on the BMCs you have to switch the BMCs back to DHCP (either manually or by switching to the same subnet with `racker bootstrap … -subnet-prefix a.b.c` and then running `ipmi --all lan set 1 ipsrc dhcp`).

The expected format is the first three numbers of the decimal IP address, so that .0/24 can be appended:

```
? Choose a subnet prefix for the rack-internal network, only change this if the default clashes with the external network [? for help] (172.24.213) 
```

**Lokomotive Web UI:** The Lokomotive Web UI is a Kubernetes dashboard and runs as application on top of Kubernetes, deployed as Lokomotive Component.
You can use port forwarding from the managmeent node or a Kubernetes Ingress node to access it.
You may deploy it from the start but you can also decide to add it later the same way as you can add other Lokomotive Components:

```
? Do you want to install the Lokomotive Web UI?  [Use arrows to move, type to filter, ? for more help]
> Yes
  No
```

**Kubernetes storage:** A Kubernetes storage provider can be installed to make use of additional disks in the servers.
Currently OpenEBS and Rook with Ceph are available. The worker nodes with storage can be limited to a certain server hardware when the node types are annotated in `/usr/share/oem/nodes.csv`:

```
? Choose a Kubernetes storage provider  [Use arrows to move, type to filter, ? for more help]
> None
  OpenEBS
  Rook
```

**Configuring backups:** Kubernetes backups to a AWS S3 bucket can be set up with Velero.
Ensure the following AWS resources are created before proceeding: S3 bucket, IAM user for Velero, required policies by the IAM user on the S3 bucket, Access Keys for the IAM user.
Follow these steps:

 - Create S3 bucket: [https://github.com/vmware-tanzu/velero-plugin-for-aws#create-s3-bucket](https://github.com/vmware-tanzu/velero-plugin-for-aws#create-s3-bucket)
 - Creation of IAM user and permissions for the IAM User: [https://github.com/vmware-tanzu/velero-plugin-for-aws#set-permissions-for-velero](https://github.com/vmware-tanzu/velero-plugin-for-aws#set-permissions-for-velero)

The wizard will query for the AWS details, and gives a chance to go back and not configure backups even if you hit `y` the first time:

```
? Do you want to set up backup/restore? [? for help] (y/N) 
```

**Command line parameters**

For non-interactive use, you can specify the following options on the command line which relate to the wizard options described above:

```
$ racker bootstrap -provision lokomotive -h
Usage:
  -aws-access-key string
    	Provide your AWS access key; only needed when configuring backups
  -aws-secret-key string
    	Provide your AWS secret key; only needed when configuring backups
  -backup-aws-location string
    	Provide the region of the S3 bucket you want the back up to be stored at; only needed when configuring backups (default "us-east-2")
  -backup-name string
    	Provide the name for the backup; only needed when configuring backups (default "lokomotive-backup")
  -backup-s3-bucket string
    	Provide the name of the S3 bucket you want the back up to be stored at; only needed when configuring backups
  -cluster-name string
    	The name for the cluster (default "lokomotive")
  -config-backup string
    	Whether to set up a backup to S3 using Velero. Ensure the following AWS resources are created before proceeding: 
    	 S3 bucket, IAM user for Velero, required policies by the IAM user on the S3 bucket, Access Keys for the IAM user.
    	 Following the steps outlined for the resources:
    	 Create S3 bucket: https://github.com/vmware-tanzu/velero-plugin-for-aws#create-s3-bucket 
    	 Creation of IAM user and permissions for the IAM User: https://github.com/vmware-tanzu/velero-plugin-for-aws#set-permissions-for-velero (default "false")
  -controller-type string
    	With different hardware in a rack you can specify which ones to use for the Kubernetes control plane (The node types are annotated in /usr/share/oem/nodes.csv). (default "any")
  -ip-addrs string
    	Set as "DHCP" for automatically assigning IP address, or provide the configuration of each node in the INI format "[aa:bb:cc:dd:ee:ff]\nip_addr = 11.22.33.44/22\ngateway = 11.22.33.1\ndns = 11.22.33.1" (default "DHCP")
  -k8s-domain-name string
    	The Kubernetes domain name is appended to the host name of each node. It is used internally but you can also use a public domain and set its records manually. (default "k8s.localdomain")
  -num-controllers string
    	 (default "3")
  -number-of-storage-nodes string
    	The number of nodes of the selected type to be used for storage (default "all")
  -storage-node-type string
    	With different hardware in a rack you can specify which ones to use for storage (The node types are annotated in /usr/share/oem/nodes.csv). (default "any")
  -storage-provider string
    	Setup storage for Lokomotive. Options are 'none', 'rook', 'openebs' (default "none")
  -subnet-prefix string
    	The subnet prefix is in the first three numbers of the decimal IP address format, so that .0/24 can be appended (default "172.24.213")
  -web-ui string
    	Whether to install the Web UI component (also installs metrics-server) (default "true")
```

### Flatcar Configuration Options

**IP address assignment and subnet prefix:** The public IP address configuration and the private subnet prefix are the same as with Lokomotive, described above.

**Command line parameters**

For non-interactive use, you can specify the following options on the command line which relate to the wizard options described above:

```
$ racker bootstrap -provision flatcar -h
Usage:
  -ip-addrs string
    	Set as "DHCP" for automatically assigning IP address, or provide the configuration of each node in the INI format "[aa:bb:cc:dd:ee:ff]\nip_addr = 11.22.33.44/22\ngateway = 11.22.33.1\ndns = 11.22.33.1" (default "DHCP")
  -subnet-prefix string
    	The subnet prefix is in the first three numbers of the decimal IP address format, so that .0/24 can be appended (default "172.24.213")
```

### Failure Handling Options

It may happen that, for some reason, a node is not able to be provisioned during `racker bootstrap`. In that case, the provision process will stop and ask the user what to do (exclude, retry, etc.).
This failure handling behavior is done by default but the command line parameters allow to specify a different behavior for non-interactive use:

```
$ racker bootstrap -h
  -exclude string
    	exclude these nodes from provisioning, expects a string containing a white-space separated list of MAC addresses
  -onfailure string
    	behavior on provisioning failure; options are: ask|retry|exclude|cancel. (default "ask")
  -provision string
    	Value should be "lokomotive" or "flatcar" (default "lokomotive")
  -retries string
    	if -onfailure=retry or -onfailure=exclude is set, the number of retries before giving up (default "3")
```

To to automate the provisioning use the `-onfailure` flag:

`-onfailure`: Use `cancel` to abort the provision, `retry` to try provisioning again with the same options, `exclude` to remove problematic nodes from the cluster configuration and try again. The default behavior `ask` is to interactively prompt the user what to do and should not be set when automating.

Optionally, you can tweak the retries with the `-retries` flag:

`-retries`: The number of attempts to provision the cluster on failure (used together with `-onfailure=retry` or `-onfailure=exclude`).

If some nodes should be excluded upfront from provisioning, maybe because they are known to be faulty, use the `-exclude` flag:

`-exclude`: The list of nodes to skip is specified as a single string containing MAC addresses separated by whitespace. The MAC addresses can be the primary or secondary NIC MAC address or the BMC MAC address but has to be one used in the `nodes.csv` file. On the terminal you have to quote the string, for example: \
`-exclude="aa:bb:cc:dd:ee:11 aa:bb:cc:dd:ee:22"` or `"-exclude=aa:bb:cc:dd:ee:11 aa:bb:cc:dd:ee:22"` or `-exclude "$(cat my_exclude_file)"`.
The nodes won't get provisioned regardless whether they have the same node type that is used for controller or storage nodes.

## Bootstrap Stages

Racker displays the progress of the different stages by updating the terminal output.
The first stage checks whether all BMCs are rechable through IPMI.
When encountering failures, the process should be restarted, possibly with excluding problematic nodes through the `-exclude` flag.
The second stage checks that the initial OS installation via PXE completes.
On failure, it offers to retry or exclude problematic nodes depending on the `-onfailure` flag.

Here is an example of a Flatcar Container Linux provisioning that automatically excluded two nodes:

```
➤ Checking BMC connectivity (10/10)... ✓ done
➤ OS installation via PXE (8/10)... × failed
Failed to provision the following 2 nodes:
aa:bb:cc:dd:ee:11 aa:bb:cc:dd:ee:22
You can see logs in /home/core/flatcar-container-linux/logs/2021-05-07_17-11-59, run 'ipmi <MAC|DOMAIN> diag' for a short overview of a node, connect to the serial console via 'ipmi <MAC|DOMAIN>', or try to connect via SSH.
Something went wrong, removing 2 nodes from config and retrying 1/3
➤ OS installation via PXE (8/8)... ✓ done
```

For Lokomotive there are additional stages. First the Kubernetes API bring-up, then the cluster health check, and finally the Lokomotive Component installation.
When some nodes do not join the cluster, the health check stage offers to retry or exclude problematic nodes depending on the `-onfailure` flag.
Even with all nodes present the cluster health check may still fail due to other reasons.

Here is an example of a completely successful Lokomotive provisioning:

```
➤ Checking BMC connectivity (10/10)... ✓ done
➤ OS installation via PXE (10/10)... ✓ done
➤ Kubernetes bring-up... ✓ done
➤ Cluster health check (10/10 nodes seen)... ✓ done
➤ Lokomotive component installation... ✓ done
```

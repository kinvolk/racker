---
title: Provision a cluster
weight: 60
---

`racker bootstrap` is used to provision a Lokomotive or a Flatcar Container
Linux.

When run without any arguments, this command will start the racker wizard,
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

## When boostrapping fails

It may happen that, for some reason, a node is not able to be provisioned during `racker bootstrap`. In that case, the provision process will stop and ask the user what to do (exclude, retry, etc.).

It's possible to change this behavior (to automate the provision) by using the following flags:

  `-onfailure`: Use `cancel` to abort the provision, `retry` to try provisioning again with the same options, `exclude` to remove problematic nodes from the cluster configuration, or `ask` (default behavior) to ask the user what to do.
  `-retries`: The number of attempts to provision the cluster on failure (used together with `-onfailure=retry`).

## Do not provision all nodes

If some nodes should be excluded from provisioning, maybe because they are known to be faulty, then the `-exclude` option can be used to specify a list of nodes (as MAC addresses) to ignore. They won't get provisioned even when they have the same node type that is used for controller or storage nodes.


## Racker's role after the cluster is provisioned

Racker is used to help provision a cluster, checking its status, and keep the related tools/modules up to date. So after a cluster has been provisioned, the main tools for interacting with either Lokomotive or Flatcar have been mentioned in the sub-sections below, rather than Racker.
At this stage, the `racker` tool is used primarily only for getting the status and updating the tools related to the cluster management.

### After provisioning Lokomotive

Once Lokomotive is provisioned, you will find a directory in the home folder
with a few files related to the Lokomotive cluster configuration.

Changing the configuration for the cluster itself can be done in the `baremetal.lokocfg` file.
Other `.lokocfg` files will be related to the [Lokomotive components](https://kinvolk.io/docs/lokomotive/latest/configuration-reference/components/)
they represent, depending
on what options were chosen during the provisioning phase.

For more information on the Lokomotive configuration, refer to the
[Lokomotive documentation](https://kinvolk.io/docs/lokomotive/latest/).

The `lokoctl` command is available for applying any changes to the configuration.

### After provisioning Flatcar Container Linux

After installing Flatcar Container Linux on the desired nodes, they are ready
to start being used.
The `racker status` command displays, among other information, the address for
the nodes, so one can ssh into them.

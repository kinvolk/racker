---
title: Updating & Upgrading Racker
linkTitle: Updating & Upgrading
weight: 60
---

Racker has the notion of updates (when getting a new version compatible with the
one currently deployed), and upgrades (when a new version may be incompatible
with the one currently deployed).

# Current version

The `racker version` command outputs the version of Racker that is currently in use.

# Updating Racker

Racker can be updated using the `racker update` command. This will pull the Racker container image using the same tag that's currently deployed.

When updating, the new version of racker may bring newer versions of related modules and tools, like `lokoctl` and `terraform`, that will be compatible with the ones currently in use.

# Upgrading Racker

The `racker upgrade` on the other hand, will pull whatever the latest tag for Racker is, regardless of whether it is compatible with the one currently deployed or not.

**Important:** This means that running `racker upgrade` can bring new versions of tools/modules (`lokoctl`, `terraform`, etc.) that may be incompatible with the ones currently deployed (which means that e.g. the Lokomotive configuration may have to be manually updated to fit the new version of `lokoctl`).
For this reason, upgrading Racker should be done only when no cluster is yet deployed, or when the cluster has been wiped out and the intent is to start over with the very latest Racker version.

## Notes for upgrading to Racker 0.3

The jump from Racker 0.2 to 0.3 through `racker upgrade` requires to add the following entry to the `baremetal.lokocfg` file to keep the behavior of reprovisioning worker nodes on configuration changes:

```
ignore_worker_changes = false
```

The Racker 0.3 release is using Lokomotive v0.9.0 with no modifications as all Racker changes are now upstreamed.
The [release notes of Lokomotive v0.9.0](https://github.com/kinvolk/lokomotive/releases/tag/v0.9.0) are valid except for the update steps for the Baremetal platform which are reduced to the change mentioned above.

After changing the `baremetal.lokocfg` file as metioned, run the following steps:

```
racker upgrade
lokoctl cluster apply --skip-components
curl -LO https://github.com/kinvolk/lokomotive/archive/v0.9.0.tar.gz
tar -xvzf v0.9.0.tar.gz
./lokomotive-0.9.0/scripts/update/0.8.0-0.9.0/update.sh
lokoctl components apply
```

# Upgrading / downgrading to a particular version

Sometimes it is important to fetch a particular version of Racker. For example, if an update has an important bug, or an *upgrade* has been mistakenly run, it is useful to have a way to go back to a particular version of Racker.

This can be achieved using the `racker get VERSION` command. E.g. `racker get 0.1` fetches and installs Racker version 0.1.
As with the `update` or `upgrade` commands, `racker get` also does not really applies any changes to the cluster itself, only install the related versions of the tools/modules shipped with that version.

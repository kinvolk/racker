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

# Upgrading / downgrading to a particular version

Sometimes it is important to fetch a particular version of Racker. For example, if an update has an important bug, or an *upgrade* has been mistakenly run, it is useful to have a way to go back to a particular version of Racker.

This can be achieved using the `racker get VERSION` command. E.g. `racker get 0.6` fetches and installs Racker version 0.6.
As with the `update` or `upgrade` commands, `racker get` also does not really applies any changes to the cluster itself, only install the related versions of the tools/modules shipped with that version.

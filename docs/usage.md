---
title: Using Racker
weight: 60
---

## Provisioning a Lokomotive Kubernetes cluster

Running `racker bootstrap` will PXE boot all servers on the rack and install Lokomotive.

From now on the cluster can be managed with `lokoctl`.

## Updating Racker

To fetch updates that are compatible with the current version, run `racker update`.

To upgrade to the latest version which may have breaking changes, run `racker upgrade`.

Both will update the `lokoctl` and `terraform` binaries, too.

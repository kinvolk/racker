---
content_type: racker
title: Development
weight: 60
---

Racker is built and distributed as a container image but extracted in the host and run locally. The reason for this approach if that we can keep a very minimal dependency on what’s shipped in the OS (that’s installed in the management node).

Since Racker runs locally, its container image default command extracts the Racker payload into `/opt/racker`, creates symbolic links in `/opt/bin` to its executables, sets up any systemd services, and thus expects to be run with privileged permissions:

`sudo docker run --rm --privileged --pid host quay.io/kinvolk/racker:latest`


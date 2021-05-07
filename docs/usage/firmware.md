---
title: Firmware Updates
weight: 70
---

Flatcar Container Linux OS updates include the Linux firmware package which contains firmware binaries for firmware that gets loaded at runtime.
Some devices, however, need their firmware updates flashed out of band and may even require reboots for the updates to take effect.
The vendors of those devices supply a firmware binary and instructions how to flash it.

For example, the update utility may be a static binary and a specific firmware file for your server.
These would need to be downloaded to the node and directly executed there through SSH.
One could also automate the firmware updates a bit more on a Kubernetes cluster with a special firmware update container that runs on each node.

Since the firmware updates are vendor-specific, there are no generic instructions on how to do them.
To improve this situation and provide a unified and automated experience, the [Linux Vendor Firmware Service](https://fwupd.org/) was started.
The system service `fwupd` can fetch firmware updates and flash them for supported devices.
Not all vendors or devices are part yet of this effort but it is the only generic mechanism that can be documented as an example.

## Firmware Update Container with fwupd

We will build a container image that runs fwupd and makes a one time action to update the firmware.
In the case of fwupd we need a full OS with systemd which makes it a bit more complicated to build and run the container.

**1.** Write the following contents to a `Dockerfile`:

```
FROM fedora:34
RUN dnf update -y && dnf -y install fwupd socat && dnf clean all
# Create a unit file which outputs to the container stdout
RUN mkdir -p /etc/systemd/system && echo -e '\
[Unit]\n\
Description=Firmware Update Action, ends the container after success\n\
[Service]\n\
Type=oneshot\n\
RemainAfterExit=yes\n\
Restart=on-failure\n\
RestartSec=5s\n\
ExecStart=/bin/bash -c "{ fwupdmgr refresh --force && fwupdmgr get-devices && { fwupdmgr get-updates -y || echo Error, no updates ; } && { fwupdmgr update -y || echo Error, failed to update ; } && systemctl poweroff ; } &> /dev/console"\n\
[Install]\n\
WantedBy=multi-user.target\n\
'  > /etc/systemd/system/fwupd-action.service
RUN systemctl enable fwupd-action.service
RUN echo OverrideESPMountPoint=/boot >> /etc/fwupd/uefi_capsule.conf
# Work around a problem with a missing dbus.service unit file
RUN mkdir -p /etc/systemd/system && ln -fs /usr/lib/systemd/system/dbus-broker.service /etc/systemd/system/dbus.service
# Mask udev instead of making /sys/ read-only as suggested in https://systemd.io/CONTAINER_INTERFACE/
RUN systemctl mask systemd-udevd.service systemd-modules-load.service systemd-udevd-control.socket systemd-udevd-kernel.socket
ENV container=docker
VOLUME [ "/sys/fs/cgroup" ]
# Set up a /dev/console link to have the same behavior with or without -it
CMD [ "/bin/sh", "-c", "if ! [ -e /dev/console ] ; then socat -u pty,link=/dev/console stdout & fi ; exec /sbin/init" ]
# TODO: maybe you also need to set up /usr/libexec/fwupd/efi/fwupdx64.efi(.signed) in /boot/efi/EFI/fedora/ and set DisableShimForSecureBoot
```

**2.** Now build a container image from it and push it to a registry of your choice:

```
docker build -t my-registry/fwupd:latest .
docker push my-registry/fwupd:latest
```

**3.** Then, on each node, run it with the following Docker command via SSH:

```
docker run --privileged --net host --rm -v /sys/fs/cgroup:/sys/fs/cgroup:ro -v /sys/firmware/efi/efivars:/sys/firmware/efi/efivars -v /boot:/boot my-registry/fwupd:latest
```

You can also use a Kubernetes [DaemonSet](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/) but keep in mind that the container exits directly after finishing its action and that you need to use the equivalent privileges as in the command above.


The output of the container includes the systemd messages for startup and shutdown.
In the following example log the startup and shutdown messages are omitted except for a single line (`[…]`).
We can see that the update was not successful because there were no updates available:

```
[…]
[  OK  ] Started Firmware update daemon.
Updating lvfs
Downloading…             [***************************************]
Successfully downloaded new metadata: 0 local devices supported
My Server X
│
└─My Device X:
      Device ID:          X
      Summary:            X
      Current version:    X
      Vendor:             X
      Serial Number:      X
      Device Flags:       • Internal device
                          • Updatable
                          • System requires external power source
                          • Needs a reboot after installation
                          • Device is usable for the duration of the update
Updating lvfs
Downloading…             [***************************************]
Successfully downloaded new metadata: 0 local devices supported
Devices with no available firmware updates:
 • My Device X
Error, no updates
Devices with no available firmware updates:
 • My Device X
Error, failed to update
[  OK  ] Removed slice system-modprobe.slice.
[…]
```

# Installation of the management node OS with iPXE

Using the iPXE script `install.ipxe` the management OS installation can be automated.
The latest Flatcar Container Linux Stable release will be written to disk, then the kernel console parameters are customized, and finally IPMI is used to set persistent booting from disk in EFI mode before the automatic reboot into the installed OS happens.
See the documentation on how to configure the management node once the OS is installed.

The full URL for an iPXE script chain is `https://raw.githubusercontent.com/kinvolk/racker/main/management-node-ipxe/install.ipxe`.

# Manual installation of the management node OS

In principle all that needs to be done is to use a live/in-memory OS and write the `flatcar_production_image.bin` file to the target disk and reboot.
The machine should be configured for permanent booting from disk.

You can use the [`flatcar-install`](https://raw.githubusercontent.com/kinvolk/init/flatcar-master/bin/flatcar-install) script to handle the download and writing to disk:

```
# write to smallest unmounted disk, use -d /dev/sdx to force a disk:
sudo ./flatcar-install -s
```

Depending on your hardware you may have to mount the OEM partition and set kernel parameters via GRUB.
For details see `install-ignition.yaml`.

# QEMU IPMI simulator environment

To test Racker without a special hardware you can use the QEMU test environment which sets up an IPMI emulator.
It behaves like an IPMI-compatible rack with a TOR switch for the public network on the secondary NICs and a second switch for the rack-internal network
for the primary NICs and the BMCs. The management node has swapped cables so that the primary NIC and BMC is on the public network and the secondary NIC
can manage the rack-internal network for DHCP/PXE.

Here the usage of `ipmi-env.sh` with the `nodes.csv` file in this folder where `00:11:22:33:44:00` is picked as management node:

```
wget https://stable.release.flatcar-linux.net/amd64-usr/current/flatcar_production_qemu_image.img.bz2
bunzip2 flatcar_production_qemu_image.img.bz2
QEMU_ARGS="" ./ipmi-env.sh create nodes.csv 00:11:22:33:44:00 ./flatcar_production_qemu_image.img /var/tmp/ipmi-sim
```

To access the management node use the opened QEMU VGA console,
or `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 core@192.168.254.X` where `X` is the IP address you can see in QEMU with `ip a`,
or `ipmitool -C3 -I lanplus -H 127.0.90.11 -U USER -P PASS sol activate` where you can run `echo ssh-rsa AAA... me@mail.com > .ssh/authorized_keys` to
add your SSH pub key.

Follow the Racker manual PDF on how to install Racker in the management node (`sudo docker run..` and create the `nodes.csv` file under `/usr/share/oem/` etc).
The IPMI user is `USER` and the password is `PASS`.
Here a short quick start if you skipped reading the PDF:

```
echo USER | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 core@192.168.254.X sudo tee /usr/share/oem/ipmi_user
echo PASS | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 core@192.168.254.X sudo tee /usr/share/oem/ipmi_password
cat nodes.csv | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 core@192.168.254.X sudo tee /usr/share/oem/nodes.csv
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 core@192.168.254.X
# To install Racker run: sudo docker run --rm --privileged --pid host quay.io/kinvolk/racker:latest
#                        racker factory check
# To fix the serial console settings for QEMU run: sudo sed -i 's/ttyS1,57600n8/ttyS0,115200n8/g' /opt/racker/bootstrap/prepare.sh
# Afterwards to provision a cluster run: racker bootstrap
```

The serial console with IPMI from the internal network (e.g., `ipmi NODE` with Racker) only works when the `kernel_console` variable in `lokocfg.vars` is changed to `kernel_console = ["console=ttyS0,115200n8", "earlyprintk=serial,ttyS0,115200n8"]`.

You can pass the `PUBLIC_BRIDGE_PREFIX` env var to `ipmi-env.sh` to choose another /24 subnet prefix for the public bridge, the last byte will be appended (default `192.168.254`).

The IPMI endpoints can also be reached on the host's loopback interface with the IP address `127.0.90.${ID}1` where ID is the node ID starting from 1 for the management node.

By default no VM windows are created because the `QEMU_ARGS` env var defaults to `-nographic` but you can overwrite it as done above with `QEMU_ARGS=""` to have VM windows pop up (requires X11/Wayland).

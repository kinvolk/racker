# Kinvolk Racker

This Kinvolk's solution for provisioning its software on racks.

## Installer

The installer is delivered as a container image but extracted in the host and
run locally.
The reason for this approach if that we can keep a very minimal dependency on
what's shipped in the OS (that's installed in the management node).

The modules that compose the installer (as well as how to build them) are
defined in the `./installer/conf.yaml` file.

### Build the installer

First compile the installer creator:

`make installer`

Then run the `build` tool (be sure to check out its options):

`cd ./installer && ./build`

### Run the installer

Once the image `racker:latest` has been created, you can run the installer:

`./installer/racker.sh`

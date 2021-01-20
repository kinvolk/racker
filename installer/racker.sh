#/bin/sh -e

# Setup the installer
INSTALLER_DIR="$HOME/racker/"
rm -rf $INSTALLER_DIR/*

docker run -it -v $INSTALLER_DIR:/racker-ext:Z racker:latest

# Run the installer
pushd $INSTALLER_DIR > /dev/null
./run.sh
popd > /dev/null

#/bin/sh

set -eu
# Setup the installer
INSTALLER_DIR="$HOME/racker/"
mkdir -p $INSTALLER_DIR

rm -rf $INSTALLER_DIR/*

MOUNT_POINT=/racker-ext

docker run --rm -v $INSTALLER_DIR:$MOUNT_POINT:Z racker:latest tar -C "$MOUNT_POINT" -xzf /racker/racker.tar.gz

# Run the installer
pushd $INSTALLER_DIR > /dev/null
./run.sh
popd > /dev/null

#/bin/sh

set -eu
# Setup the installer
INSTALLER_DIR="/opt/racker"
sudo mkdir -p $INSTALLER_DIR

sudo rm -rf $INSTALLER_DIR/*

MOUNT_POINT=/racker-ext

docker run --rm -v $INSTALLER_DIR:$MOUNT_POINT:Z quay.io/kinvolk/racker:kai_bootstrap-fixes tar --no-same-owner -C "$MOUNT_POINT" -xzf /racker/racker.tar.gz

# Run the installer
pushd $INSTALLER_DIR > /dev/null
./run.sh
popd > /dev/null

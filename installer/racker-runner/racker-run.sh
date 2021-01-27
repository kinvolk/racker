#/bin/sh

set -eu

RACKER_VERSION=

# Setup the installer
INSTALLER_DIR="/opt/racker"
sudo mkdir -p $INSTALLER_DIR

sudo rm -rf $INSTALLER_DIR/*

MOUNT_POINT=/racker-ext

VERSION_FILE="$MOUNT_POINT/RACKER_VERSION"

if [ -f $VERSION_FILE ]; then
    $RACKER_VERSION=":$(cat VERSION_FILE)"
fi

RACKER_VERSION=${RACKER_VERSION:-":latest"}

docker run --rm -v $INSTALLER_DIR:$MOUNT_POINT:Z quay.io/kinvolk/racker$RACKER_VERSION /bin/bash -c "tar --no-same-owner -C $MOUNT_POINT -xzf /racker/racker.tar.gz; cp /racker/RACKER_VERSION $VERSION_FILE"

# Run the installer
pushd $INSTALLER_DIR > /dev/null
./run.sh
popd > /dev/null

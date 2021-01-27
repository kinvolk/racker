#/bin/sh

set -eu

ARCHIVE="/racker/racker.tar.gz"
INSTALLER_DIR="/opt/racker"


# test if "--privileged --pid host" was used: we can run nsenter and it makes us leave this mount namespace where the archive is
if ! nsenter -a -t 1 true || [ "$(nsenter -a -t 1 ls "$ARCHIVE" 2> /dev/null)" != "" ]; then
  echo "Failed to leave container, please run the image like this: sudo docker run --rm --privileged --pid host IMAGE"
  exit 1
fi

nsenter -a -t 1 mkdir -p $INSTALLER_DIR
nsenter -a -t 1 sh -c "rm -rf $INSTALLER_DIR/*"

cat /racker/racker.tar.gz | nsenter -a -t 1 tar xzf - --no-same-owner -C $INSTALLER_DIR
cat /racker/RACKER_VERSION | nsenter -a -t 1 tee $INSTALLER_DIR/RACKER_VERSION > /dev/null
nsenter -a -t 1 mkdir -p /opt/bin
# Setting up the PATH for the current user is not easy, reuse the
# existing /opt/bin folder. If the symlink is changed or deleted, it
# should be turned into an action that cleans up the old symlinks from
# previous runs.
nsenter -a -t 1 ln -fs /opt/racker/bin/racker /opt/bin/racker
nsenter -a -t 1 ln -fs /opt/racker/bin/lokoctl /opt/bin/lokoctl
nsenter -a -t 1 ln -fs /opt/racker/bin/terraform /opt/bin/terraform

echo "Installation complete, you may now run: racker"

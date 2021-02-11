#/bin/sh

set -eu

ARCHIVE="/racker/racker.tar.gz"
INSTALLER_DIR="/opt/racker"


# test if "--privileged --pid host" was used: we can run nsenter and it makes us leave this mount namespace where the archive is
if ! nsenter -a -t 1 true || [ "$(nsenter -a -t 1 ls "$ARCHIVE" 2> /dev/null)" != "" ]; then
  echo "Failed to leave container, please run the image like this: sudo docker run --rm --privileged --pid host IMAGE"
  exit 1
fi

LOCKSMITH_ENABLED=$(nsenter -a -t 1 systemctl is-active --quiet locksmithd && echo true || echo false)
if $LOCKSMITH_ENABLED; then
  # Stop locksmith to prevent a possible reboot while bootstrapping
  nsenter -a -t 1 systemctl stop locksmithd
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
nsenter -a -t 1 ln -fs /opt/racker/bin/kubectl /opt/bin/kubectl
nsenter -a -t 1 ln -fs /opt/racker/bootstrap/ipmi /opt/bin/ipmi
nsenter -a -t 1 ln -fs /opt/racker/bootstrap/matchbox.service /etc/systemd/system/matchbox.service
nsenter -a -t 1 ln -fs /opt/racker/bootstrap/dnsmasq.service /etc/systemd/system/dnsmasq.service

# restart updated services if active
if nsenter -a -t 1 systemctl is-active --quiet dnsmasq; then
  nsenter -a -t 1 systemctl daemon-reload
  nsenter -a -t 1 systemctl restart dnsmasq
fi
if nsenter -a -t 1 systemctl is-active --quiet matchbox; then
  nsenter -a -t 1 systemctl daemon-reload
  nsenter -a -t 1 systemctl restart matchbox
fi

# Start locksmith again, if it was enabled before
if $LOCKSMITH_ENABLED; then
  nsenter -a -t 1 systemctl start locksmithd || true
fi

echo "Installation complete, you may now run: racker"

#!/bin/sh

ret=⨯
cat /proc/1/cgroup | grep /docker > /dev/null || ret=✓

echo "== Running outside of container: $ret =="

echo "== Payload: =="
ls -1 ./

sudo mkdir -p /opt/bin
# Setting up the PATH for the current user is not easy, reuse the
# existing /opt/bin folder. If the symlink is changed or deleted, it
# should be turned into an action that cleans up the old symlinks from
# previous runs.
sudo ln -fs /opt/racker/bin/lokoctl /opt/bin/lokoctl
sudo ln -fs /opt/racker/bin/terraform /opt/bin/terraform

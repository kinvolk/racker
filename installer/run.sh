#!/bin/sh

ret=⨯
cat /proc/1/cgroup | grep /docker > /dev/null || ret=✓

echo "== Running outside of container: $ret =="

echo "== Payload: =="
ls -1 ./

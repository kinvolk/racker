#!/bin/sh -e
#
# This script extracts the rack software installer shipped in this image.
#

usage() {
    cat <<EOF
Usage: $0
Extract the racker software into a mounted directory into a
directory that should be mounted at /racker-ext/.

  -h, --help                    Display this help and exit

EOF
}

ARGS=$(getopt -o "h" -l "help" \
  -n "extract.sh" -- "$@")
eval set -- "$ARGS"

while true; do
  case "$1" in
    -h|--help)
    usage
    exit 0
    ;;
    --)
      shift
      break
      ;;
  esac
done

DEST_DIR=/racker-ext/

if [ ! -d "$DEST_DIR" ]; then
    echo "Please mount a directory $DEST_DIR and try again!"
    echo
    usage
    exit 1
fi

tar -C "$DEST_DIR" -xzf /racker/racker.tar.gz

#!/bin/zsh
# Fixed-work-list, bounded-retry implementation. Originals and model files are kept on failure.
set -eu
HERE=${0:A:h}
exec python3 "$HERE/hd_pack.py" "$1" "$2" "${3:-/private/tmp/s2hd}" --quarantine --pixels

#!/usr/bin/env bash
# install.sh -- deploy ksu-addon into a ROM tree (never touches repo history)
#
#   bash install.sh                 # default: /home/icecat/data/pixelos-6.6
#   bash install.sh /path/to/tree   # explicit ROM tree
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=${1:-/home/icecat/data/pixelos-6.6}
DST=$TOP/vendor/oneplus/ksu-addon

[ -d "$TOP" ] || { echo "ERROR: no such tree: $TOP" >&2; exit 1; }
[ -f "$TOP/build/envsetup.sh" ] || { echo "ERROR: not an Android source tree (missing build/envsetup.sh)" >&2; exit 1; }

mkdir -p "$DST"
rsync -a --delete --exclude 'install.sh' "$HERE"/ "$DST"/
chmod +x "$DST"/bin/*.sh "$DST"/ksu-addon.sh

echo "OK: installed into $DST"
echo
echo "Next steps:"
echo "  cd $TOP"
echo "  bash vendor/oneplus/ksu-addon/bin/sandbox.sh status   # check for leftover sandboxes"
echo "  bash vendor/oneplus/ksu-addon/bin/ksu.sh check        # check patches apply on the current HEAD"
echo "  WITH_KSU=true JOBS=64 bash -l vendor/oneplus/ksu-addon/bin/build.sh --all-variants"

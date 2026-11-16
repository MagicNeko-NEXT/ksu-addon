#!/usr/bin/env bash
# verify.sh -- validate one artifact directory: kernel config, version string, zip MD5
#   bash bin/verify.sh /path/to/rom/outrom/<timestamp>-<variant>
set -euo pipefail
D=${1:?usage: verify.sh <artifact-dir>}
[ -d "$D" ] || { echo "ERROR: no such directory: $D" >&2; exit 1; }
echo "=== directory ==="; ls -l "$D" | awk 'NR>1{print "  "$5" "$9}'
echo "=== kernel release ==="; cat "$D"/kernel-release.txt 2>/dev/null || echo "  (no kernel-release.txt)"
if grep -q '\-dirty' "$D"/kernel-release.txt 2>/dev/null; then echo "FAIL: version string contains -dirty"; exit 1; else echo "  OK: no -dirty"; fi
echo "=== KSU config ==="
cfg=$(ls "$D"/kernel-*.config 2>/dev/null | head -1)
if [ -n "$cfg" ]; then
  grep -E '^CONFIG_KSU(=|_SUSFS=)' "$cfg" | sed 's/^/  /' || echo "  (no CONFIG_KSU)"
  if grep -q '^CONFIG_KSU=y' "$cfg"; then echo "  OK: CONFIG_KSU=y present"; else echo "  NOTE: no CONFIG_KSU (expected for the non-root package)"; fi
else echo "  (no kernel-*.config)"; fi
echo "=== zip and MD5 ==="
( cd "$D" && md5sum ./*.zip && md5sum -c MD5SUMS 2>/dev/null | tail -1 )

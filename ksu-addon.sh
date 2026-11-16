#!/usr/bin/env bash
# ksu-addon.sh -- unified entry point
#
#   ./ksu-addon.sh selftest          # sandbox round-trip self test (no build)
#   ./ksu-addon.sh check [variant]   # can the variant's patches apply on the current kernel HEAD?
#   ./ksu-addon.sh status            # sandbox state
#   ./ksu-addon.sh build [options]   # build (forwarded to bin/build.sh):
#                                    #   --dry-run --all-variants --variants a,b --only --jobs --variant
#   ./ksu-addon.sh verify <dir>      # validate an artifact directory
#   ./ksu-addon.sh install [rom]     # install into a ROM tree
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cmd=${1:-help}; shift || true
case "$cmd" in
  selftest) exec bash "$HERE/bin/sandbox.sh" selftest ;;
  status)   exec bash "$HERE/bin/sandbox.sh" status ;;
  check)    v=${1:-${KSU_VARIANT:-bakasu-susfs}}; KSU_VARIANT=$v exec bash "$HERE/bin/ksu.sh" check ;;
  build)    exec bash "$HERE/bin/build.sh" "$@" ;;
  verify)   exec bash "$HERE/bin/verify.sh" "$@" ;;
  install)  exec bash "$HERE/install.sh" "$@" ;;
  *) sed -n '2,12p' "$0" ;;
esac

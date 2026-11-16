#!/usr/bin/env bash
# sandbox.sh -- Sandboxie-style copy-on-write sandbox (Linux overlayfs)
#
#   up   out|kernel      Put an overlay on top of the target path:
#                        lower = read-only pristine state, upper = writes
#   down out|kernel|all  Unmount and discard the upper layer; the physical
#                        directory returns to its original state
#   status               Show mount state and upper-layer usage
#   selftest             Full round trip in a temporary directory:
#                        mount -> write/delete/rename -> unmount -> verify
#
# Mount options MUST include redirect_dir=on,index=on. Without them soong
# fails to rename a lower-layer directory ("Failed to rename
# out/soong/metrics_aggregation"), which is what broke earlier builds.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/../../../.." && pwd)
OVL=${KSU_OVL_DIR:-/home/icecat/data/ksu-ovl}
OUT_PATH=$TOP/out
KERN_PATH=$TOP/kernel/oneplus/sm8450
MOUNT_OPTS=redirect_dir=on,index=on

path_of() {
  case "$1" in
    out) echo "$OUT_PATH" ;;
    kernel) echo "$KERN_PATH" ;;
    *) echo "unknown sandbox: $1" >&2; exit 2 ;;
  esac
}

up() {
  local name=$1 path up work
  path=$(path_of "$name")
  up=$OVL/$name-upper
  work=$OVL/$name-work
  if mountpoint -q "$path"; then
    echo "  - $name already sandboxed"
    return 0
  fi
  [ -d "$path" ] || { echo "ERROR: target does not exist: $path" >&2; exit 1; }
  mkdir -p "$OVL"
  sudo rm -rf "$up" "$work"
  mkdir -p "$up" "$work"
  sudo mount -t overlay overlay \
    -o "lowerdir=$path,upperdir=$up,workdir=$work,$MOUNT_OPTS" "$path"
  mountpoint -q "$path" || { echo "ERROR: failed to mount $name sandbox" >&2; exit 1; }
  echo "  - $name sandbox mounted (lower=$path upper=$up)"
}

down() {
  local name=$1 path up work
  path=$(path_of "$name")
  up=$OVL/$name-upper
  work=$OVL/$name-work
  if mountpoint -q "$path"; then
    sudo umount "$path" || { echo "ERROR: failed to unmount $name (busy?)" >&2; exit 1; }
    echo "  - $name sandbox unmounted, upper layer discarded"
  else
    echo "  - $name not mounted, skipped"
  fi
  sudo rm -rf "$up" "$work" 2>/dev/null || true
}

status() {
  local name path
  for name in out kernel; do
    path=$(path_of "$name")
    if mountpoint -q "$path"; then
      printf "  %-6s sandboxed (upper uses %s)\n" "$name" \
        "$(sudo du -sh "$OVL/$name-upper" 2>/dev/null | cut -f1 || echo '?')"
    else
      echo "  $name: physical directory (no sandbox)"
    fi
  done
  if mountpoint -q "$KERN_PATH" && [ -e "$KERN_PATH/KernelSU" ]; then
    echo "  kernel view: KSU patches applied (upper layer only)"
  fi
}

selftest() {
  local D=$OVL/selftest rc=0
  echo "=== sandbox selftest ($D) ==="
  sudo umount "$D/mnt" 2>/dev/null || true
  sudo rm -rf "$D"
  mkdir -p "$D"/{lower,upper,work,mnt}
  echo "L1" > "$D/lower/keep.txt"
  echo "L2" > "$D/lower/change.txt"
  echo "L3" > "$D/lower/delete.txt"
  if ! sudo mount -t overlay overlay \
      -o "lowerdir=$D/lower,upperdir=$D/upper,workdir=$D/work,$MOUNT_OPTS" "$D/mnt"; then
    echo "ERROR: mount failed (overlayfs unsupported?)"; sudo rm -rf "$D"; exit 1
  fi
  echo "CHANGED" > "$D/mnt/change.txt"                  # overwrite a lower file
  rm -f "$D/mnt/delete.txt"                            # delete a lower file
  echo "NEW" > "$D/mnt/new.txt"                        # create a new file
  mkdir "$D/mnt/newdir" && mv "$D/mnt/newdir" "$D/mnt/renamed"  # rename
  echo "  merged view: $(ls "$D/mnt" | tr '\n' ' ')"
  [ "$(cat "$D/mnt/change.txt")" = "CHANGED" ] || { echo "ERROR: overwrite did not take effect"; rc=1; }
  [ ! -e "$D/mnt/delete.txt" ] || { echo "ERROR: delete did not take effect"; rc=1; }
  sudo umount "$D/mnt" || { echo "ERROR: unmount failed"; rc=1; }
  [ "$(cat "$D/lower/keep.txt")" = "L1" ] || { echo "ERROR: lower was modified"; rc=1; }
  [ "$(cat "$D/lower/change.txt")" = "L2" ] || { echo "ERROR: lower file was overwritten"; rc=1; }
  [ -e "$D/lower/delete.txt" ] || { echo "ERROR: lower file was deleted"; rc=1; }
  [ ! -e "$D/lower/new.txt" ] && [ ! -e "$D/lower/renamed" ] || { echo "ERROR: upper writes leaked into lower"; rc=1; }
  sudo rm -rf "$D"
  if [ $rc -eq 0 ]; then
    echo "PASS: writes/deletes/renames stay in the upper layer; lower is byte-identical after unmount"
  else
    echo "FAIL: selftest failed"
  fi
  return $rc
}

case "${1:-}" in
  up) up "${2:?need out|kernel}" ;;
  down) if [ "${2:-}" = "all" ]; then down kernel; down out; else down "${2:?need out|kernel|all}"; fi ;;
  status) status ;;
  selftest) selftest ;;
  *) echo "usage: $0 {up|down} {out|kernel|all} | status | selftest" >&2; exit 2 ;;
esac

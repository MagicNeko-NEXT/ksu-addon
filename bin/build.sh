#!/usr/bin/env bash
# build.sh -- the single build entry point for ksu-addon (overlay sandbox)
#
# Usage:
#   bash bin/build.sh                                   # non-root package only
#   WITH_KSU=true bash bin/build.sh                     # non-root, then the current variant
#   KSU_VARIANT=kernelsu-susfs WITH_KSU=true ONLY=rooted bash bin/build.sh
#   bash bin/build.sh --dry-run                         # preflight + plan only
#   WITH_KSU=true bash bin/build.sh --all-variants      # every variant, one after another
#
# Sandbox semantics (Sandboxie-style):
#   * out/ is wrapped in an overlay: lower = existing build cache, upper = writes
#   * the kernel source is wrapped in an overlay: lower = pristine, upper = patches
#   * when the build finishes both sandboxes are unmounted, the physical
#     directories are byte-identical, and the local patch commit is rolled back
set -uo pipefail

TOP=$(cd "$(dirname "$0")/../../../.." && pwd)
ADDON=$TOP/vendor/oneplus/ksu-addon
KSUSH=$ADDON/bin/ksu.sh
SANDBOX=$ADDON/bin/sandbox.sh
LOG=$TOP/build-live.log
OUT=$TOP/out/target/product/ovaltine
ARTBASE=${KSU_ARTBASE:-$TOP/outrom}   # artifacts live in <ROM>/outrom (created on demand)

WITH_KSU=${WITH_KSU:-false}
ONLY=${ONLY:-both}
VARIANT=${KSU_VARIANT:-bakasu-susfs}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 8)}
TARGET=${TARGET:-custom_ovaltine-cp2a-userdebug}
GOAL=${GOAL:-pixelos}
DRY_RUN=false
ALL_VARIANTS=${ALL_VARIANTS:-false}
VARIANTS_CSV=${VARIANTS_CSV:-}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --variant) VARIANT=$2; shift ;;
    --jobs) JOBS=$2; shift ;;
    --only) ONLY=$2; shift ;;
    --all-variants) ALL_VARIANTS=true ;;
    --variants) VARIANTS_CSV=$2; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[ksu-addon] $*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }
sbox() { bash "$SANDBOX" "$@"; }

cd "$TOP" || die "cannot enter $TOP"
mkdir -p "$ARTBASE"

# ---------- preflight ----------
if [ "$ALL_VARIANTS" = "true" ]; then
  VARIANT_LIST=$(for d in "$ADDON"/variants/*/; do
      n=$(basename "$d")
      [ -n "$(ls -1 "$d"/series/*.patch 2>/dev/null)" ] && echo "$n"
    done | tr '\n' ' ')
elif [ -n "$VARIANTS_CSV" ]; then
  VARIANT_LIST=$(echo "$VARIANTS_CSV" | tr ',' ' ')
else
  VARIANT_LIST=$VARIANT
fi
[ -n "${VARIANT_LIST// /}" ] || die "no usable variant (variants/*/series are all empty)"
log "=== build start $(date -Is) variants=[$VARIANT_LIST] WITH_KSU=$WITH_KSU ONLY=$ONLY JOBS=$JOBS ==="

for v in $VARIANT_LIST; do
  [ -n "$(ls -1 "$ADDON/variants/$v/series"/*.patch 2>/dev/null)" ] || die "variant $v has an empty series/"
done

if mountpoint -q "$TOP/out" || mountpoint -q "$TOP/kernel/oneplus/sm8450"; then
  log "WARNING: leftover sandbox detected, unmounting first"
  sbox down all || die "failed to unmount leftover sandbox"
fi

if [ "${SKIP_CHECK:-0}" != "1" ]; then
  for v in $VARIANT_LIST; do
    KSU_VARIANT=$v bash "$KSUSH" check >/dev/null || die "patch preflight failed (KSU_VARIANT=$v)"
    log "OK preflight: $v"
  done
fi

if [ "$DRY_RUN" = "true" ]; then
  log "=== DRY RUN: plan (sequential, one sandbox per variant) ==="
  if [ "$ONLY" = "both" ] || [ "$ONLY" = "non-root" ]; then
    log "1) [non-root] sandbox up out -> m -j$JOBS $GOAL -> archive -> sandbox down out"
  fi
  if [ "$WITH_KSU" = "true" ] && [ "$ONLY" != "non-root" ]; then
    n=2
    for v in $VARIANT_LIST; do
      log "$n) [$v] sandbox up out+kernel -> apply patches (local commit) -> m -> archive($v) -> cleanup -> sandbox down out"
      n=$((n+1))
    done
  fi
  log "artifacts: $ARTBASE/<timestamp>-non-root/ and <timestamp>-<variant>/ (one per variant, sequential)"
  trap 'sbox down all >/dev/null 2>&1 || true' EXIT
  exit 0
fi

source build/envsetup.sh >/dev/null 2>&1 || die "source build/envsetup.sh failed"
lunch "$TARGET" >/dev/null 2>&1 || die "lunch $TARGET failed"
log "lunch $TARGET done"

archive() { # $1 = tag
  local tag=$1 stamp art zip
  stamp=$(date +%Y%m%d-%H%M)
  art=$ARTBASE/$stamp-$tag
  mkdir -p "$art"
  zip=$(ls -t "$OUT"/PixelOS_ovaltine-*.zip 2>/dev/null | head -1 || true)
  [ -n "$zip" ] && [ -f "$zip" ] || die "no zip found in $OUT"
  cp --reflink=never "$zip" "$art/PixelOS-ovaltine-$stamp-$tag.zip"
  [ -f "$OUT/obj/KERNEL_OBJ/.config" ] && cp "$OUT/obj/KERNEL_OBJ/.config" "$art/kernel-$tag.config"
  [ -f "$OUT/obj/KERNEL_OBJ/include/config/kernel.release" ] && \
    cp "$OUT/obj/KERNEL_OBJ/include/config/kernel.release" "$art/kernel-release.txt"
  [ -f "$OUT/obj/KERNEL_OBJ/vmlinux" ] && \
    strings "$OUT/obj/KERNEL_OBJ/vmlinux" 2>/dev/null | grep -m3 -E 'BakaSU|KernelSU.*version|v[0-9]+\.[0-9]+\.[0-9]+' > "$art/ksu-version.txt" || true
  ( cd "$art" && md5sum ./*.zip > MD5SUMS )
  log "-> $tag artifact: $art/PixelOS-ovaltine-$stamp-$tag.zip"
  cat "$art/MD5SUMS" | tee -a "$LOG"
  echo "$art" >> /tmp/.ksu-artifacts
}

pass() { # $1 = tag
  log "=== BUILD PASS ($1) $(date -Is) ==="
  m -j"$JOBS" "$GOAL" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  log "=== BUILD PASS END ($1) $(date -Is) exit=$rc ==="
  [ "$rc" -eq 0 ] || die "build pass $1 failed (exit=$rc), log: $LOG"
}

: > /tmp/.ksu-artifacts
trap 'sbox down all >/dev/null 2>&1 || true' EXIT INT TERM

# ---------- pass 1: non-root ----------
if [ "$ONLY" = "both" ] || [ "$ONLY" = "non-root" ]; then
  sbox up out || die "failed to mount out sandbox"
  pass non-root
  archive non-root
  grep -q "^CONFIG_KSU=y" "$OUT/obj/KERNEL_OBJ/.config" 2>/dev/null \
    && die "non-root kernel config contains CONFIG_KSU=y, refusing to ship"
  log "OK: non-root kernel has no CONFIG_KSU"
  sbox down out || die "failed to unmount out sandbox"
fi

# ---------- pass 2: rooted, one variant at a time ----------
if [ "$WITH_KSU" = "true" ] && [ "$ONLY" != "non-root" ]; then
  for v in $VARIANT_LIST; do
    log "--- rooted variant: $v ---"
    sbox up out || die "failed to mount out sandbox ($v)"
    KSU_VARIANT=$v bash "$KSUSH" prepare || die "patch layer preparation failed ($v)"
    pass "$v"
    archive "$v"
    grep -q "^CONFIG_KSU=y" "$OUT/obj/KERNEL_OBJ/.config" 2>/dev/null \
      || die "$v kernel config is missing CONFIG_KSU=y"
    log "OK: $v kernel has CONFIG_KSU=y"
    KSU_VARIANT=$v bash "$KSUSH" cleanup
    sbox down out || die "failed to unmount out sandbox ($v)"
  done
fi

if [ -n "$(git -C "$TOP/kernel/oneplus/sm8450" status --porcelain)" ]; then
  die "kernel checkout is dirty"
fi

log "=== build finished $(date -Is) ==="
log "artifacts:"
while read -r d; do [ -d "$d" ] && log "  $d"; done < /tmp/.ksu-artifacts
log "OK: kernel checkout clean at $(git -C "$TOP/kernel/oneplus/sm8450" rev-parse --short HEAD)"

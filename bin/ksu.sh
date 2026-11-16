#!/usr/bin/env bash
# ksu.sh -- execution layer for the KSU add-on: prepare / cleanup / check
#
# Isolation model:
#   * The kernel source is wrapped in an overlay: lower = pristine checkout,
#     upper = patches. Unmounting the sandbox restores the pristine tree.
#   * Build output is wrapped in an overlay too: lower = existing cache,
#     upper = writes from this build.
#   * Version strings must not report "-dirty": prepare commits the patches
#     as a local commit (NEVER pushed), so HEAD matches the worktree and both
#     scripts/setlocalversion and the KSU Kbuild report a clean tree.
#     WARNING: that commit lives in .repo/.../.git, which is NOT on the
#     overlay, so unmounting does not remove it. cleanup() explicitly resets
#     back to the base SHA recorded by prepare().
set -euo pipefail

TOP=$(cd "$(dirname "$0")/../../../.." && pwd)
ADDON=$TOP/vendor/oneplus/ksu-addon
SANDBOX=$ADDON/bin/sandbox.sh
KREPO=$TOP/kernel/oneplus/sm8450
OUT=$TOP/out/target/product/ovaltine
KOUT=$OUT/obj/KERNEL_OBJ
OVL=${KSU_OVL_DIR:-/home/icecat/data/ksu-ovl}
VARIANT=${KSU_VARIANT:-bakasu-susfs}
SERIES_DIR=$ADDON/variants/$VARIANT/series
[ -d "$SERIES_DIR" ] || SERIES_DIR=$ADDON/series
STATE=$OVL/base-head
SANDBOX_MSG="kernelsu: sandbox build (local only, never pushed)"
PROTECTED=(m/seventeen magicneko/seventeen seventeen-testing-icatfix)

k() { git -C "$KREPO" "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }
patch_series() { ls -1 "$SERIES_DIR"/*.patch 2>/dev/null | sort || true; }
sbox() { bash "$SANDBOX" "$@"; }

need_clean_kernel() {
  local head_subject
  head_subject=$(k log -1 --format=%s 2>/dev/null || true)
  if [ "$head_subject" = "$SANDBOX_MSG" ]; then
    info "HEAD is a leftover sandbox commit, rolling back first"
    rollback_sandbox_commit
  fi
  if [ -n "$(k status --porcelain)" ]; then
    echo "ERROR: kernel checkout has uncommitted changes:" >&2
    k status --short >&2
    exit 1
  fi
}

rollback_sandbox_commit() {
  local base=""
  [ -f "$STATE" ] && base=$(cat "$STATE")
  if [ -n "$base" ] && k rev-parse --verify --quiet "$base" >/dev/null; then
    k reset -q --mixed "$base"
    info "rolled back to base ${base:0:12}"
  elif [ "$(k log -1 --format=%s 2>/dev/null)" = "$SANDBOX_MSG" ]; then
    k reset -q --mixed HEAD~1
    info "rolled back the sandbox commit (HEAD~1)"
  fi
  rm -f "$STATE"
}

check_protected_refs() {
  local bad=0 ref
  for ref in "${PROTECTED[@]}"; do
    k rev-parse --verify --quiet "$ref" >/dev/null || continue
    if k grep -q "CONFIG_KSU" "$ref" -- arch 2>/dev/null; then echo "ERROR: $ref contains CONFIG_KSU" >&2; bad=1; fi
    if k cat-file -e "$ref:KernelSU" 2>/dev/null; then echo "ERROR: $ref contains KernelSU/" >&2; bad=1; fi
  done
  [ $bad -eq 0 ] && info "OK: protected refs are free of KSU traces" || return 1
}

assert_pristine_kernel() {
  [ -d "$KREPO/KernelSU" ] && die "kernel source contains KernelSU/ -- not pristine"
  [ -e "$KREPO/fs/susfs.c" ] && die "kernel source contains fs/susfs.c -- not pristine"
  if grep -rq "CONFIG_KSU" "$KREPO/arch/arm64/configs" 2>/dev/null; then
    die "kernel config contains CONFIG_KSU -- not pristine"
  fi
  info "OK: kernel is pristine ($(k rev-parse --short HEAD))"
}

# ---------- prepare ----------
do_prepare() {
  need_clean_kernel
  assert_pristine_kernel
  local series; series=$(patch_series)
  [ -n "$series" ] || die "no patch series: $SERIES_DIR/*.patch (KSU_VARIANT=$VARIANT)"

  mkdir -p "$OVL"
  k rev-parse HEAD > "$STATE"
  info "base HEAD: $(cat "$STATE")"

  sbox up kernel
  local p
  for p in $series; do
    if ! git -C "$KREPO" apply --whitespace=nowarn "$p" 2>"$KREPO/.apply.err"; then
      echo "ERROR: failed to apply $(basename "$p") -- mainline moved, refresh the series" >&2
      cat "$KREPO/.apply.err" >&2 || true
      rm -f "$KREPO/.apply.err"
      sbox down kernel
      rollback_sandbox_commit
      die "aborted: no rooted package produced"
    fi
    info "applied $(basename "$p")"
  done
  rm -f "$KREPO/.apply.err"

  # ReSukiSU/BakaSU Kbuild requires a .git or .vendored marker next to
  # KernelSU/. Dotfiles cannot be carried by patches (gitignore), so create it.
  : > "$KREPO/KernelSU/.vendored"
  info "created KernelSU/.vendored marker"

  # Commit locally (never pushed) so version strings stay free of "-dirty".
  k add -A
  k -c user.name="Myer921" -c user.email="icecat@cat.network" \
    commit -q -m "$SANDBOX_MSG" --no-verify
  info "created local sandbox commit: $(k rev-parse --short HEAD)"

  # Kernel and external modules must be rebuilt with the same config
  # (susfs changes struct task_struct / inode layouts).
  rm -rf "$KOUT" 2>/dev/null || true
  rm -rf "$OUT/vendor_dlkm/lib/modules" "$OUT/system_dlkm/lib/modules" 2>/dev/null || true
  rm -rf "$TOP/out/soong/.intermediates/vendor/lineage/build/soong/generated_kernel_includes" 2>/dev/null || true
  info "requested rebuild of kernel and external modules"
}

# ---------- cleanup ----------
do_cleanup() {
  sbox down kernel
  rollback_sandbox_commit
  if [ -n "$(k status --porcelain)" ]; then
    echo "ERROR: kernel checkout still dirty after rollback:" >&2
    k status --short >&2
    exit 1
  fi
  info "OK: kernel back at $(k rev-parse --short HEAD), worktree clean"
}

# ---------- check ----------
do_check() {
  need_clean_kernel
  check_protected_refs
  local series; series=$(patch_series)
  [ -n "$series" ] || die "no patch series: $SERIES_DIR/*.patch (KSU_VARIANT=$VARIANT)"
  info "series: $(echo "$series" | wc -l) patch(es)"
  assert_pristine_kernel
  info "=== sandbox state ==="
  sbox status
  local p tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  git -C "$KREPO" archive HEAD | tar -x -C "$tmp"
  for p in $series; do
    # Apply for real and in order: later patches may touch files that
    # earlier patches created, so a bare --check would produce false failures.
    if ! ( cd "$tmp" && git apply --whitespace=nowarn "$p" 2>/dev/null ); then
      rm -rf "$tmp"; trap - EXIT
      die "failed to apply $(basename "$p") on the current HEAD -- refresh the series"
    fi
    info "applied $(basename "$p")"
  done
  rm -rf "$tmp"; trap - EXIT
  info "OK: series applies cleanly on the current HEAD"
}

case "${1:-}" in
  prepare) do_prepare ;;
  cleanup) do_cleanup ;;
  check)   do_check ;;
  *) echo "usage: $0 prepare|cleanup|check" >&2; exit 2 ;;
esac

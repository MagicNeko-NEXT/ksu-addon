#!/usr/bin/env bash
# ksu.sh —— vendor/oneplus/ksu-addon 的执行层：prepare / cleanup / check
#
# 隔离模型（2026-11-16 定稿）：
#   * 内核源码套 overlay：lower = 原始 checkout，upper = 补丁；编完卸载即无补丁
#   * 编译输出套 overlay：lower = non-root 缓存，upper = 本次写入；卸载即还原
#   * 版本串不带 "-dirty"：prepare 时把补丁提交成本地 commit（**不 push**），
#     HEAD 与工作区一致，于是内核 scripts/setlocalversion 与 KSU Kbuild 都不会标脏。
#     ⚠️ 该 commit 写进 .repo 里的 .git，**不在 overlay 上**，卸载沙盒不会自动消失，
#        因此 cleanup 必须显式 reset 回 prepare 前记录的基线 SHA。
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
die() { echo "✗ $*" >&2; exit 1; }
info() { echo "  $*"; }
patch_series() { ls -1 "$SERIES_DIR"/*.patch 2>/dev/null | sort || true; }
sbox() { bash "$SANDBOX" "$@"; }

need_clean_kernel() {
  local head_subject
  head_subject=$(k log -1 --format=%s 2>/dev/null || true)
  if [ "$head_subject" = "$SANDBOX_MSG" ]; then
    info "HEAD 停在沙盒提交上（上次未回滚），先回滚"
    rollback_sandbox_commit
  fi
  if [ -n "$(k status --porcelain)" ]; then
    echo "✗ 内核主 checkout 有未提交改动：" >&2
    k status --short >&2
    exit 1
  fi
}

rollback_sandbox_commit() {
  local base=""
  [ -f "$STATE" ] && base=$(cat "$STATE")
  if [ -n "$base" ] && k rev-parse --verify --quiet "$base" >/dev/null; then
    k reset -q --mixed "$base"
    info "已回滚到基线 ${base:0:12}"
  elif [ "$(k log -1 --format=%s 2>/dev/null)" = "$SANDBOX_MSG" ]; then
    k reset -q --mixed HEAD~1
    info "已回滚沙盒提交（HEAD~1）"
  fi
  rm -f "$STATE"
}

check_protected_refs() {
  local bad=0 ref
  for ref in "${PROTECTED[@]}"; do
    k rev-parse --verify --quiet "$ref" >/dev/null || continue
    if k grep -q "CONFIG_KSU" "$ref" -- arch 2>/dev/null; then echo "✗ $ref 出现 CONFIG_KSU" >&2; bad=1; fi
    if k cat-file -e "$ref:KernelSU" 2>/dev/null; then echo "✗ $ref 出现 KernelSU/ 目录" >&2; bad=1; fi
  done
  [ $bad -eq 0 ] && info "✓ 主线/测试 ref 无 KSU 痕迹" || return 1
}

assert_pristine_kernel() {
  [ -d "$KREPO/KernelSU" ] && die "内核源码里存在 KernelSU/，不是无补丁状态"
  [ -e "$KREPO/fs/susfs.c" ] && die "内核源码里存在 fs/susfs.c，不是无补丁状态"
  if grep -rq "CONFIG_KSU" "$KREPO/arch/arm64/configs" 2>/dev/null; then
    die "内核 config 里出现 CONFIG_KSU，不是无补丁状态"
  fi
  info "✓ 内核处于无补丁状态（$(k rev-parse --short HEAD)）"
}

# ---------- prepare ----------
do_prepare() {
  need_clean_kernel
  assert_pristine_kernel
  local series; series=$(patch_series)
  [ -n "$series" ] || die "没有补丁序列：$SERIES_DIR/*.patch（KSU_VARIANT=$VARIANT）"

  mkdir -p "$OVL"
  k rev-parse HEAD > "$STATE"          # 基线：编完回滚到这里
  info "基线 HEAD: $(cat "$STATE")"

  sbox up kernel
  local p
  for p in $series; do
    if ! git -C "$KREPO" apply --whitespace=nowarn "$p" 2>"$KREPO/.apply.err"; then
      echo "✗ 补丁打不上（主线已前进，需要刷新补丁序列）：$(basename "$p")" >&2
      cat "$KREPO/.apply.err" >&2 || true
      rm -f "$KREPO/.apply.err"
      sbox down kernel
      rollback_sandbox_commit
      die "中止：不产出带 root 的包"
    fi
    info "✓ $(basename "$p")"
  done
  rm -f "$KREPO/.apply.err"

  # ReSukiSU 的 Kbuild 要求 KernelSU/ 旁有 .git 或 .vendored 标记（点文件打不进补丁）
  : > "$KREPO/KernelSU/.vendored"
  info "✓ 已创建 KernelSU/.vendored 标记"

  # 提交成本地 commit（不 push）：HEAD 与工作区一致 → 版本串不带 -dirty
  k add -A
  k -c user.name="Myer921" -c user.email="icecat@cat.network" \
    commit -q -m "$SANDBOX_MSG" --no-verify
  info "✓ 已创建沙盒提交（本地，不 push）：$(k rev-parse --short HEAD)"

  # 内核与扩展模块必须同配方重编（susfs 改 task_struct / inode 布局）
  rm -rf "$KOUT" 2>/dev/null || true
  rm -rf "$OUT/vendor_dlkm/lib/modules" "$OUT/system_dlkm/lib/modules" 2>/dev/null || true
  rm -rf "$TOP/out/soong/.intermediates/vendor/lineage/build/soong/generated_kernel_includes" 2>/dev/null || true
  info "已请求重编内核与扩展模块"
}

# ---------- cleanup ----------
do_cleanup() {
  sbox down kernel
  rollback_sandbox_commit
  if [ -n "$(k status --porcelain)" ]; then
    echo "✗ 回滚后内核 checkout 仍脏：" >&2
    k status --short >&2
    exit 1
  fi
  info "✓ 内核已回到基线 $(k rev-parse --short HEAD)，工作区干净"
}

# ---------- check ----------
do_check() {
  need_clean_kernel
  check_protected_refs
  local series; series=$(patch_series)
  [ -n "$series" ] || die "没有补丁序列：$SERIES_DIR/*.patch（KSU_VARIANT=$VARIANT）"
  info "补丁 $(echo "$series" | wc -l) 个"
  assert_pristine_kernel
  info "=== 沙盒状态 ==="
  sbox status
  local p tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  git -C "$KREPO" archive HEAD | tar -x -C "$tmp"
  for p in $series; do
    # 按序真实应用（不是 --check）：后面的补丁可能依赖前面补丁新建的文件
    if ! ( cd "$tmp" && git apply --whitespace=nowarn "$p" 2>/dev/null ); then
      rm -rf "$tmp"; trap - EXIT
      die "补丁 $(basename "$p") 在当前 HEAD 上打不上：需要刷新补丁序列"
    fi
    info "✓ $(basename "$p")"
  done
  rm -rf "$tmp"; trap - EXIT
  info "✓ 补丁序列可在当前 HEAD 上干净应用"
}

case "${1:-}" in
  prepare) do_prepare ;;
  cleanup) do_cleanup ;;
  check)   do_check ;;
  *) echo "用法: $0 prepare|cleanup|check" >&2; exit 2 ;;
esac

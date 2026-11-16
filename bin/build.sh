#!/usr/bin/env bash
# build.sh —— ksu-addon 唯一构建入口（overlay 沙盒版）
#
# 用法：
#   bash bin/build.sh                          # 只出 non-root 包
#   WITH_KSU=true bash bin/build.sh            # 先 non-root，再当前变体的 rooted 包
#   KSU_VARIANT=kernelsu-susfs WITH_KSU=true ONLY=rooted bash bin/build.sh
#   bash bin/build.sh --dry-run                # 只做预检与计划，不编译
#
# 沙盒语义（Sandboxie 式）：
#   * out/ 罩 overlay：lower = 现有编译缓存，upper = 本次写入
#   * 内核源码罩 overlay：lower = 原始 checkout，upper = 补丁
#   * 构建结束 down all，物理目录一字未变；补丁提交在 cleanup 里显式回滚
set -uo pipefail

TOP=$(cd "$(dirname "$0")/../../../.." && pwd)
ADDON=$TOP/vendor/oneplus/ksu-addon
KSUSH=$ADDON/bin/ksu.sh
SANDBOX=$ADDON/bin/sandbox.sh
LOG=$TOP/build-live.log
OUT=$TOP/out/target/product/ovaltine
ARTBASE=${KSU_ARTBASE:-$TOP/outrom}   # ROM 树下的 outrom/（不存在则创建）

WITH_KSU=${WITH_KSU:-false}
ONLY=${ONLY:-both}
VARIANT=${KSU_VARIANT:-bakasu-susfs}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 8)}
TARGET=${TARGET:-custom_ovaltine-cp2a-userdebug}
GOAL=${GOAL:-pixelos}
DRY_RUN=false
ALL_VARIANTS=${ALL_VARIANTS:-false}
VARIANTS_CSV=${VARIANTS_CSV:-}
ROOTED_TAG=$VARIANT

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --variant) VARIANT=$2; ROOTED_TAG=$2; shift ;;
    --jobs) JOBS=$2; shift ;;
    --only) ONLY=$2; shift ;;
    --all-variants) ALL_VARIANTS=true ;;
    --variants) VARIANTS_CSV=$2; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[ksu-addon] $*" | tee -a "$LOG"; }
die() { log "✗ $*"; exit 1; }
sbox() { bash "$SANDBOX" "$@"; }

cd "$TOP" || die "进不去 $TOP"

# ---------- 预检 ----------
mkdir -p "$ARTBASE"
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
[ -n "${VARIANT_LIST// /}" ] || die "没有可用变体（variants/*/series 均为空）"
log "本次变体：$VARIANT_LIST"

SERIES=$ADDON/variants/$VARIANT/series
[ -d "$SERIES" ] || die "没有变体 $VARIANT（缺 $SERIES）"
for v in $VARIANT_LIST; do
  [ -n "$(ls -1 "$ADDON/variants/$v/series"/*.patch 2>/dev/null)" ] || die "变体 $v 的 series/ 为空"
done
log "=== 构建开始 $(date -Is) variants=[$VARIANT_LIST] WITH_KSU=$WITH_KSU ONLY=$ONLY JOBS=$JOBS ==="

if mountpoint -q "$TOP/out" || mountpoint -q "$TOP/kernel/oneplus/sm8450"; then
  log "! 发现残留沙盒，先卸载"
  sbox down all || die "残留沙盒卸载失败"
fi

if [ "${SKIP_CHECK:-0}" != "1" ]; then
  for v in $VARIANT_LIST; do
    KSU_VARIANT=$v bash "$KSUSH" check >/dev/null || die "补丁预检失败（KSU_VARIANT=$v）"
    log "✓ 预检通过：$v"
  done
fi

if [ "$DRY_RUN" = "true" ]; then
  log "=== DRY RUN：计划如下（依次构建，每个变体各自沙盒）==="
  if [ "$ONLY" = "both" ] || [ "$ONLY" = "non-root" ]; then
    log "1) [non-root] sandbox up out → m -j$JOBS $GOAL → archive → sandbox down out"
  fi
  if [ "$WITH_KSU" = "true" ] && [ "$ONLY" != "non-root" ]; then
    n=2
    for v in $VARIANT_LIST; do
      log "$n) [$v] sandbox up out+kernel → 打补丁(本地提交) → m → archive($v) → cleanup → sandbox down out"
      n=$((n+1))
    done
  fi
  log "产物目录：$ARTBASE/<时间戳>-non-root/ 与 <时间戳>-<变体>/（每个变体一份，逐次生成）"
  trap 'sbox down all >/dev/null 2>&1 || true' EXIT
  exit 0
fi

source build/envsetup.sh >/dev/null 2>&1 || die "source build/envsetup.sh 失败"
lunch "$TARGET" >/dev/null 2>&1 || die "lunch $TARGET 失败"
log "lunch $TARGET 完成"

archive() { # $1 = 标签
  local tag=$1 stamp art zip
  stamp=$(date +%Y%m%d-%H%M)
  art=$ARTBASE/$stamp-$tag
  mkdir -p "$art"
  zip=$(ls -t "$OUT"/PixelOS_ovaltine-*.zip 2>/dev/null | head -1 || true)
  [ -n "$zip" ] && [ -f "$zip" ] || die "没找到 zip（$OUT）"
  cp --reflink=never "$zip" "$art/PixelOS-ovaltine-$stamp-$tag.zip"
  [ -f "$OUT/obj/KERNEL_OBJ/.config" ] && cp "$OUT/obj/KERNEL_OBJ/.config" "$art/kernel-$tag.config"
  [ -f "$OUT/obj/KERNEL_OBJ/include/config/kernel.release" ] && \
    cp "$OUT/obj/KERNEL_OBJ/include/config/kernel.release" "$art/kernel-release.txt"
  [ -f "$OUT/obj/KERNEL_OBJ/vmlinux" ] && \
    strings "$OUT/obj/KERNEL_OBJ/vmlinux" 2>/dev/null | grep -m3 -E 'BakaSU|KernelSU.*version|v[0-9]+\.[0-9]+\.[0-9]+' > "$art/ksu-version.txt" || true
  ( cd "$art" && md5sum ./*.zip > MD5SUMS )
  log "→ $tag 产物：$art/PixelOS-ovaltine-$stamp-$tag.zip"
  cat "$art/MD5SUMS" | tee -a "$LOG"
  echo "$art" >> /tmp/.ksu-artifacts
}

pass() { # $1 = 标签
  log "=== BUILD PASS ($1) $(date -Is) ==="
  m -j"$JOBS" "$GOAL" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  log "=== BUILD PASS END ($1) $(date -Is) exit=$rc ==="
  [ "$rc" -eq 0 ] || die "第 $1 遍构建失败（exit=$rc），日志：$LOG"
}

: > /tmp/.ksu-artifacts
trap 'sbox down all >/dev/null 2>&1 || true' EXIT INT TERM

# ---------- 第一遍：non-root ----------
if [ "$ONLY" = "both" ] || [ "$ONLY" = "non-root" ]; then
  sbox up out || die "out 沙盒挂载失败"
  pass non-root
  archive non-root
  grep -q "^CONFIG_KSU=y" "$OUT/obj/KERNEL_OBJ/.config" 2>/dev/null \
    && die "non-root 包内核配置含 CONFIG_KSU=y，拒绝交付"
  log "✓ non-root 包内核无 CONFIG_KSU"
  sbox down out || die "out 沙盒卸载失败"
fi

# ---------- 第二遍：rooted（逐个变体，各自沙盒） ----------
if [ "$WITH_KSU" = "true" ] && [ "$ONLY" != "non-root" ]; then
  for v in $VARIANT_LIST; do
    log "--- rooted 变体：$v ---"
    sbox up out || die "out 沙盒挂载失败（$v）"
    KSU_VARIANT=$v bash "$KSUSH" prepare || die "补丁层准备失败（$v）"
    pass "$v"
    archive "$v"
    grep -q "^CONFIG_KSU=y" "$OUT/obj/KERNEL_OBJ/.config" 2>/dev/null \
      || die "$v 包内核配置没有 CONFIG_KSU=y"
    log "✓ $v 包内核含 CONFIG_KSU=y"
    KSU_VARIANT=$v bash "$KSUSH" cleanup
    sbox down out || die "out 沙盒卸载失败（$v）"
  done
fi

if [ -n "$(git -C "$TOP/kernel/oneplus/sm8450" status --porcelain)" ]; then
  die "内核主 checkout 变脏"
fi

log "=== 构建结束 $(date -Is) ==="
log "产物："
while read -r d; do [ -d "$d" ] && log "  $d"; done < /tmp/.ksu-artifacts
log "✓ 内核主 checkout 干净：$(git -C "$TOP/kernel/oneplus/sm8450" rev-parse --short HEAD)"

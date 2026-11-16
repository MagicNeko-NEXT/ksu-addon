#!/usr/bin/env bash
# sandbox.sh —— Sandboxie 式 copy-on-write 沙盒（Linux overlayfs）
#
#   up   out|kernel   在目标路径上罩一层 overlay：lower=只读原状，upper=写入层
#   down out|kernel|all  卸载并丢弃 upper，物理目录回到原状
#   status            查看挂载状态与 upper 占用
#   selftest          在临时目录做一次完整的 up→写→删→down 往返，验证沙盒可用
#
# 挂载参数必须带 redirect_dir=on,index=on：
#   否则 soong 重命名 lower 层目录会失败（Failed to rename out/soong/metrics_aggregation）。
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
    *) echo "未知沙盒: $1" >&2; exit 2 ;;
  esac
}

up() {
  local name=$1 path up work
  path=$(path_of "$name")
  up=$OVL/$name-upper
  work=$OVL/$name-work
  if mountpoint -q "$path"; then
    echo "  · $name 已在沙盒中"
    return 0
  fi
  [ -d "$path" ] || { echo "✗ 目标不存在: $path" >&2; exit 1; }
  mkdir -p "$OVL"
  sudo rm -rf "$up" "$work"
  mkdir -p "$up" "$work"
  sudo mount -t overlay overlay \
    -o "lowerdir=$path,upperdir=$up,workdir=$work,$MOUNT_OPTS" "$path"
  mountpoint -q "$path" || { echo "✗ $name 沙盒挂载失败" >&2; exit 1; }
  echo "  · $name 沙盒已挂载（lower=$path upper=$up）"
}

down() {
  local name=$1 path up work
  path=$(path_of "$name")
  up=$OVL/$name-upper
  work=$OVL/$name-work
  if mountpoint -q "$path"; then
    sudo umount "$path" || { echo "✗ $name 卸载失败（仍有进程占用？）" >&2; exit 1; }
    echo "  · $name 沙盒已卸载，增量被丢弃"
  else
    echo "  · $name 未挂载，跳过"
  fi
  sudo rm -rf "$up" "$work" 2>/dev/null || true
}

status() {
  local name path
  for name in out kernel; do
    path=$(path_of "$name")
    if mountpoint -q "$path"; then
      printf "  %-6s 沙盒中（upper 占用 %s）\n" "$name" \
        "$(sudo du -sh "$OVL/$name-upper" 2>/dev/null | cut -f1 || echo '?')"
    else
      echo "  $name: 直通物理目录"
    fi
  done
  if mountpoint -q "$KERN_PATH" && [ -e "$KERN_PATH/KernelSU" ]; then
    echo "  内核补丁视图：已应用 KSU（仅存在于 upper 层）"
  fi
}

selftest() {
  local D=$OVL/selftest rc=0
  echo "=== 沙盒自检（$D）==="
  sudo umount "$D/mnt" 2>/dev/null || true
  sudo rm -rf "$D"
  mkdir -p "$D"/{lower,upper,work,mnt}
  echo "L1" > "$D/lower/keep.txt"
  echo "L2" > "$D/lower/change.txt"
  echo "L3" > "$D/lower/delete.txt"
  if ! sudo mount -t overlay overlay \
      -o "lowerdir=$D/lower,upperdir=$D/upper,workdir=$D/work,$MOUNT_OPTS" "$D/mnt"; then
    echo "✗ 挂载失败（内核不支持 overlayfs？）"; sudo rm -rf "$D"; exit 1
  fi
  echo "CHANGED" > "$D/mnt/change.txt"   # 覆盖 lower 文件
  rm -f "$D/mnt/delete.txt"             # 删除 lower 文件
  echo "NEW" > "$D/mnt/new.txt"         # 新建文件
  mkdir "$D/mnt/newdir" && mv "$D/mnt/newdir" "$D/mnt/renamed"  # lower 无此目录，测试重命名
  echo "  挂载视图: $(ls "$D/mnt" | tr '\n' ' ')"
  [ "$(cat "$D/mnt/change.txt")" = "CHANGED" ] || { echo "✗ 覆盖未生效"; rc=1; }
  [ ! -e "$D/mnt/delete.txt" ] || { echo "✗ 删除未生效"; rc=1; }
  sudo umount "$D/mnt" || { echo "✗ 卸载失败"; rc=1; }
  [ "$(cat "$D/lower/keep.txt")" = "L1" ] || { echo "✗ lower 被写坏"; rc=1; }
  [ "$(cat "$D/lower/change.txt")" = "L2" ] || { echo "✗ lower 覆盖物被写"; rc=1; }
  [ -e "$D/lower/delete.txt" ] || { echo "✗ lower 文件被删"; rc=1; }
  [ ! -e "$D/lower/new.txt" ] && [ ! -e "$D/lower/renamed" ] || { echo "✗ upper 写入泄漏到 lower"; rc=1; }
  sudo rm -rf "$D"
  if [ $rc -eq 0 ]; then
    echo "✓ 自检通过：写入/删除/重命名只落在 upper，卸载后 lower 一字未变"
  else
    echo "✗ 自检失败"
  fi
  return $rc
}

case "${1:-}" in
  up) up "${2:?需要 out|kernel}" ;;
  down) if [ "${2:-}" = "all" ]; then down kernel; down out; else down "${2:?需要 out|kernel|all}"; fi ;;
  status) status ;;
  selftest) selftest ;;
  *) echo "用法: $0 {up|down} {out|kernel|all} | status | selftest" >&2; exit 2 ;;
esac

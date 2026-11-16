#!/usr/bin/env bash
# install.sh —— 把 ksu-addon 部署到 ROM 树（不改任何仓库历史）
#
#   bash install.sh                 # 默认部署到 /home/icecat/data/pixelos-6.6
#   bash install.sh /path/to/tree   # 指定 ROM 树
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=${1:-/home/icecat/data/pixelos-6.6}
DST=$TOP/vendor/oneplus/ksu-addon

[ -d "$TOP" ] || { echo "✗ 目标树不存在: $TOP" >&2; exit 1; }
[ -f "$TOP/build/envsetup.sh" ] || { echo "✗ 这不像 Android 源码树（缺 build/envsetup.sh）" >&2; exit 1; }

mkdir -p "$DST"
rsync -a --delete --exclude 'install.sh' "$HERE"/ "$DST"/
chmod +x "$DST"/bin/*.sh

echo "✓ 已部署到 $DST"
echo
echo "接下来："
echo "  cd $TOP"
echo "  bash vendor/oneplus/ksu-addon/bin/sandbox.sh status     # 检查沙盒是否干净"
echo "  bash vendor/oneplus/ksu-addon/bin/ksu.sh check          # 检查补丁能否干净应用"
echo "  WITH_KSU=true JOBS=64 bash -l vendor/oneplus/ksu-addon/bin/build.sh"

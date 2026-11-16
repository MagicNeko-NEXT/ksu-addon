#!/usr/bin/env bash
# ksu-addon.sh —— 统一入口
#
#   ./ksu-addon.sh selftest          # 沙盒往返自检（不编译）
#   ./ksu-addon.sh check [variant]   # 补丁能否在当前内核 HEAD 上按序应用
#   ./ksu-addon.sh status            # 沙盒状态
#   .ksu-addon.sh build [选项]      # 构建（透传参数）：--dry-run、--all-variants、--variants a,b、--only、--jobs、--variant
#   ./ksu-addon.sh verify <产物目录>  # 校验产物
#   ./ksu-addon.sh install [rom树]    # 部署到 ROM 树
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

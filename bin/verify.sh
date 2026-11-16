#!/usr/bin/env bash
# verify.sh —— 校验一个构建产物目录：内核配置、版本串、zip 的 MD5
#   bash bin/verify.sh /home/icecat/data/ovaltine-debug/ksu/<时间戳>-<变体>
set -euo pipefail
D=${1:?用法: verify.sh <产物目录>}
[ -d "$D" ] || { echo "✗ 目录不存在: $D" >&2; exit 1; }
echo "=== 目录 ==="; ls -l "$D" | awk 'NR>1{print "  "$5" "$9}'
echo "=== 内核版本串 ==="; cat "$D"/kernel-release.txt 2>/dev/null || echo "  (无 kernel-release.txt)"
if grep -q '\-dirty' "$D"/kernel-release.txt 2>/dev/null; then echo "✗ 版本串带 -dirty"; exit 1; else echo "  ✓ 无 -dirty"; fi
echo "=== KSU 配置 ==="
cfg=$(ls "$D"/kernel-*.config 2>/dev/null | head -1)
if [ -n "$cfg" ]; then
  grep -E '^CONFIG_KSU(=|_SUSFS=)' "$cfg" | sed 's/^/  /' || echo "  (无 CONFIG_KSU)"
  if grep -q '^CONFIG_KSU=y' "$cfg"; then echo "  ✓ 含 CONFIG_KSU=y"; else echo "  ! 该包不含 CONFIG_KSU（应为 non-root 变体）"; fi
else echo "  (无 kernel-*.config)"; fi
echo "=== zip 与 MD5 ==="
( cd "$D" && md5sum ./*.zip && md5sum -c MD5SUMS 2>/dev/null | tail -1 )

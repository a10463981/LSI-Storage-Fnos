#!/bin/bash
# 静态守卫：禁止任何可能波及宿主的卸载写法。
#
# 背景：早期 build/lib.sh 用递归卸载清理 rootfs 的 /dev，
# 传播链没完全隔离时会把**宿主的 /dev/pts** 一起卸掉，已经发生过两次。
#
# 规则（只检查非注释行）：
#   R1  禁止递归卸载（umount -R / --recursive）
#   R2  禁止对字面量宿主路径卸载：/dev /dev/pts /proc /sys /run
#   R3  出现 `mount --rbind` 的脚本，必须同时出现 `rfs_enter_ns` 或 `unshare -m`
#
# 用法: bash build/verify/check-mounts.sh [仓库根]
set -uo pipefail
ROOT=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
SELF=$(readlink -f "${BASH_SOURCE[0]}")
fail=0

files=$(find "$ROOT/build" "$ROOT/pkg" "$ROOT/dev" -type f \
          \( -name '*.sh' -o -name 'main' -o -name '*_init' -o -name '*_callback' \
             -o -name 'reset-password' \) 2>/dev/null \
        | grep -v '/build/work/' | grep -v '/build/dist/' | grep -v '/build/vendor/' \
        | grep -v '/build/verify/' | grep -v "^$SELF$")

echo "扫描 $(echo "$files" | wc -l) 个脚本（仅非注释行）…"

strip() { sed -E 's/[[:space:]]+#.*$//' "$1" | grep -vE '^[[:space:]]*#'; }

for f in $files; do
  body=$(strip "$f")

  # R1
  if echo "$body" | grep -qE 'umount[[:space:]]+(-R|--recursive)'; then
    echo "FAIL[R1] $f: 出现递归卸载"
    echo "$body" | grep -nE 'umount[[:space:]]+(-R|--recursive)' | sed 's/^/        /'
    fail=1
  fi

  # R2
  if echo "$body" | grep -qE 'umount([[:space:]]+[^|;&]*)?[[:space:]](/dev|/dev/pts|/proc|/sys|/run)([[:space:]]|$|["'"'"'])'; then
    echo "FAIL[R2] $f: 对宿主路径卸载"
    echo "$body" | grep -nE 'umount([[:space:]]+[^|;&]*)?[[:space:]](/dev|/dev/pts|/proc|/sys|/run)([[:space:]]|$|["'"'"'])' | sed 's/^/        /'
    fail=1
  fi

  # R3
  if echo "$body" | grep -qE 'mount[[:space:]]+--rbind'; then
    if ! echo "$body" | grep -qE 'rfs_enter_ns|unshare[[:space:]]+-m'; then
      echo "FAIL[R3] $f: 有 mount --rbind 但没有 rfs_enter_ns / unshare -m"
      fail=1
    fi
  fi
done

if [ "$fail" = 0 ]; then
  echo "OK: 未发现危险的卸载写法"
  exit 0
fi
echo "守卫失败：先修掉上面这些问题，再打包。"
exit 1

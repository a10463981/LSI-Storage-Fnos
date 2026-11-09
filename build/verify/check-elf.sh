#!/bin/bash
# 扫描 rootfs 内全部 ELF，断言没有 "not found" 的动态依赖。
#
# ★ 纪律：只看 "not found"，**不看 "undefined symbol"**。
#   实测 libgateway.so 的 ldd -r 会报几十条 undefined symbol（launcher::PluginManager、
#   plugins::BasePlugin 等），那些符号由主程序在运行时以全局符号表提供，静态检查看不到，
#   属正常现象。历史上曾据此误判"包不完整"，浪费一轮排查。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
R=${1:-$RFS}
LD="LD_LIBRARY_PATH=/opt/lsi/LSA/libs:/opt/lsi/LSA/libs2:/opt/lsi/LSIStorageAuthority/bin:/opt/lsi/LSIStorageAuthority/plugins"
bad=0; checked=0
while IFS= read -r f; do
  inner=${f#"$R"}
  out=$(chroot "$R" /bin/bash -c "$LD ldd '$inner' 2>&1" 2>/dev/null || true)
  case "$out" in *"not found"*) echo "MISSING: $inner"; echo "$out" | grep 'not found' | sed 's/^/    /'; bad=$((bad+1));; esac
  checked=$((checked+1))
done < <(find "$R/opt/lsi" -type f \( -perm -u+x -o -name '*.so*' \) 2>/dev/null | head -400)
echo "ELF 检查: $checked 个文件, 缺失 $bad 个"
[ "$bad" -eq 0 ] || exit 1

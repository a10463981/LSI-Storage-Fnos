#!/bin/bash
# 阶段 30：解 LSA zip → 选基线 deb → chroot 内 dpkg -i。
# 基线默认 gcc_8.3.x（原因见 lib.sh 里 LSA_BASELINE 的注释：CPU ISA 兼容性优先于 glibc）。
# 不走 install_deb.sh：那是交互式包装（问端口、问 OpenSLP），不可脚本化。
# 代价是配置里的端口占位符没人替换 —— 由 40-patch.sh 补上，运行期再定点注入实际端口。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
rfs_enter_ns "$@"
LZ=$(cat "$WORK/00/lsa.path")
rfs_mount      # 命名空间内挂载，离开即自动卸载

D="$WORK/30"; rm -rf "$D"; mkdir -p "$D/outer"
log 30 "解外层 zip"
unzip -q -o "$LZ" -d "$D/outer" || die "外层 zip 解压失败"

INNER=$(find "$D/outer" -type f -name 'LSA_Linux.zip' | head -1)
if [ -n "$INNER" ]; then
  log 30 "解内层 $(basename "$INNER")（约 165MB，稍慢）"
  mkdir -p "$D/inner"
  unzip -q -o "$INNER" -d "$D/inner" || die "内层 zip 解压失败"
  SRCROOT="$D/inner"
else
  SRCROOT="$D/outer"
fi

# 内层 zip 直接解出 gcc_* 基线目录（没有 ext/ 这一层）
BASEDIR=$(find "$SRCROOT" -maxdepth 3 -type d -name "$LSA_BASELINE" | head -1)
if [ -z "$BASEDIR" ]; then
  die "未找到基线目录 $LSA_BASELINE，实际可用：
$(find "$SRCROOT" -maxdepth 3 -type d -name 'gcc_*' -printf '  %p\n')"
fi

DEBS=$(ls -1 "$BASEDIR"/*.deb 2>/dev/null)
[ -n "$DEBS" ] || die "$BASEDIR 下没有 .deb"
DEB_N=$(echo "$DEBS" | wc -l)
log 30 "基线=$LSA_BASELINE，共 $DEB_N 个 deb"
echo "$DEBS" | while read -r d; do log 30 "    $(basename "$d")  $(du -h "$d" | cut -f1)"; done
report "- LSA 基线: $LSA_BASELINE / $DEB_N 个 deb"

rm -rf "$RFS/tmp/lsadeb"; mkdir -p "$RFS/tmp/lsadeb"
cp $DEBS "$RFS/tmp/lsadeb/"
log 30 "dpkg -i（三个包一起装，dpkg 自行处理相互依赖；postinst 跳过 systemd 属正常）"
in_rfs "dpkg -i /tmp/lsadeb/*.deb" || die "dpkg 安装失败"
rm -rf "$RFS/tmp/lsadeb"

[ -d "$RFS/opt/lsi/LSIStorageAuthority" ] || die "安装后目录不存在"
[ -x "$RFS/opt/lsi/LSIStorageAuthority/bin/LSA" ] || warn "bin/LSA 不可执行，稍后核对"
[ -f "$RFS/etc/init.d/LsiSASH" ] || warn "未找到 /etc/init.d/LsiSASH"

report "- LSA 装完后: $(rfs_mb) MB（opt/lsi = $(du -sm "$RFS/opt/lsi" | cut -f1) MB）"
ok "阶段 30 完成（$(rfs_mb) MB）"

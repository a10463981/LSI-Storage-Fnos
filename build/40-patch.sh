#!/bin/bash
# 阶段 40：固化全部补丁。这一步之后，用户机器上只做"参数注入"，不做安装。
#
# 补丁 1-3（结构性）：符号链接，缺一不可 —— 已真机验证
# 补丁 4（参数性）：端口占位符替换为启动默认值；运行期再定点注入实际端口
# 补丁 5：日志级别降到 ERROR（LSA.conf 里有明确映射表，64=FUNCTION_ENTRY 是刷盘元凶）
# 补丁 6：预置无口令账号，运行期只 chpasswd，不 useradd
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
rfs_enter_ns "$@"              # useradd 需要 /dev/null 与 /proc
rfs_mount

LSA="$RFS/opt/lsi/LSIStorageAuthority"
[ -d "$LSA" ] || die "LSA 未安装，先跑 30-install-lsa.sh"

log 40 "补丁 1：libcrypt.so.2 → libcrypt.so.1"
CRYPT=$(ls "$RFS"/usr/lib/x86_64-linux-gnu/libcrypt.so.1 2>/dev/null | head -1)
[ -n "$CRYPT" ] || die "找不到 libcrypt.so.1"
ln -sfn libcrypt.so.1 "$RFS/usr/lib/x86_64-linux-gnu/libcrypt.so.2"

log 40 "补丁 2：libslp.so.1 → libslp.so.1.0.0"
if [ -e "$RFS/opt/lsi/LSA/libs2/libslp.so.1.0.0" ]; then
  ln -sfn libslp.so.1.0.0 "$RFS/opt/lsi/LSA/libs2/libslp.so.1"
else
  warn "libslp.so.1.0.0 不存在，跳过（libs2: $(ls "$RFS"/opt/lsi/LSA/libs2 2>/dev/null | head -5 | tr '\n' ' ')）"
fi

log 40 "补丁 3：ui/js → ../js（否则前端灰屏）"
UI="$LSA/server/html/ui"
mkdir -p "$UI"
if [ -d "$LSA/server/html/js" ]; then ln -sfn ../js "$UI/js"; else warn "server/html/js 不存在，跳过"; fi

# ---- 补丁 3b：slpd 需要的日志目录 ----
# init 脚本把 slpd 的输出写到 /usr/local/var/log/slpd.log，base 镜像没这个目录，
# 结果是 slpd 静默启动失败 → libgateway.so 加载失败 → root API 永远 400 → 前端灰屏。
mkdir -p "$RFS/usr/local/var/log" "$RFS/usr/local/var/run" "$RFS/usr/local/var/lib"
chmod 755 "$RFS/usr/local" "$RFS/usr/local/var" "$RFS/usr/local/var/log" 2>/dev/null || true
log 40 "补丁 3b：/usr/local/var/log 已创建（slpd 依赖）"

# ---- 补丁 3c：修 init 脚本里 slpd 分支对 LD_LIBRARY_PATH 的覆盖 ----
# 根因（实测）：/etc/init.d/LsiSASH 第 46 行在"slpd 未运行"分支里执行
#   export LD_LIBRARY_PATH=/opt/lsi/LSA/libs2
# 把调用方传进来的路径整体覆盖掉。之后第 84/85 行虽然做了 prepend，
# 但 base 里已经不含 /opt/lsi/LSA/libs，于是 LSA 进程找不到自带的 OpenSSL 3.2，
# libcurl.so.4 报 "version `OPENSSL_3.2.0' not found"，libgateway.so 加载失败，
# 网关管理器为空 → root API 永远 400 → 前端灰屏。
# 这就是"有时候能起（slpd 已在跑时不走该分支）、有时候起不来"的真正原因。
INIT="$RFS/etc/init.d/LsiSASH"
if grep -qE '^[[:space:]]*export LD_LIBRARY_PATH=/opt/lsi/LSA/libs2[[:space:]]*$' "$INIT"; then
  sed -i -E 's#^([[:space:]]*export LD_LIBRARY_PATH=)/opt/lsi/LSA/libs2([[:space:]]*)$#\1/opt/lsi/LSA/libs:/opt/lsi/LSA/libs2\2#' "$INIT"
  log 40 "补丁 3c：init 脚本 slpd 分支的 LD_LIBRARY_PATH 已补上 /opt/lsi/LSA/libs"
  report "- 补丁 3c: LsiSASH LD_LIBRARY_PATH 修正（本基线需要）"
elif grep -qE '^[[:space:]]*export LD_LIBRARY_PATH=/opt/lsi/LSA/libs:/opt/lsi/LSA/libs2[[:space:]]*$' "$INIT"; then
  log 40 "补丁 3c：本基线已自带正确路径，无需修改"
else
  warn "补丁 3c：init 脚本里没找到预期的 LD_LIBRARY_PATH 形态，需人工核对："
  grep -n 'export LD_LIBRARY_PATH' "$INIT" | sed 's/^/    /' >&2
fi
grep -n 'export LD_LIBRARY_PATH=/opt/lsi/LSA/libs' "$INIT" | sed 's/^/    /'

# ---- 补丁 3d：OpenLDAP 2.4 soname 兼容 ----
# gcc_8.3.x 基线（SLES 15）的 LSA 二进制链接 libldap-2.4.so.2（OpenLDAP 2.4 soname），
# Ubuntu 24.04 只提供 libldap.so.2（OpenLDAP 2.6）。
#
# 为什么这样做是安全的：
#   1. 本应用只使用 LSA 的 Web 界面，认证走宿主 OS 账号（LSA.conf: ldap_mode = 0），
#      LDAP 目录服务这条通路**永远不会被执行**；
#   2. 动态链接器只需要满足加载期的 SONAME 解析，不会被调用就不会走到 ABI 差异；
#   3. 已验证：创建该链接后 `ldd bin/LSA` 与 `ldd server/nginx` 均无 "not found"，
#      且 LSA 在真机上正常起停（README §1）。
#
# 风险边界：如果将来有人把 ldap_mode 改成 1（接 AD/LDAP 做认证），这个链接就成了
# ABI 不匹配的真隐患，必须先换成真正的 OpenLDAP 2.4 库。
if [ ! -e "$RFS/usr/lib/x86_64-linux-gnu/libldap-2.4.so.2" ] && [ -e "$RFS/usr/lib/x86_64-linux-gnu/libldap.so.2" ]; then
  ln -sfn libldap.so.2 "$RFS/usr/lib/x86_64-linux-gnu/libldap-2.4.so.2"
  log 40 "补丁 3d：libldap-2.4.so.2 → libldap.so.2（gcc_8.3.x 基线需要）"
  report "- 补丁 3d: libldap-2.4 soname 兼容"
fi

# ---- 补丁 3e：去掉 LSA 前端的 X-Frame-Options ----
# LSA 的 nginx.conf 在 server 级和 location / 里各写了一行
#   add_header X-Frame-Options "SAMEORIGIN";
# 如果 fnOS 的应用入口是用 iframe 内嵌（不同端口就是不同源），
# 这一行会让 :2464 的页面被浏览器**直接拒绝渲染 → 白屏**，
# 而用 curl 测是永远测不出来的（curl 不执行 frame 策略）。
# 我们整个部署都在同一台 NAS 上、且只在内网，去掉它的代价很小，
# 换来的是"不论平台用新标签页还是 iframe 打开，都能正常显示"。
NGX2="$LSA/server/conf/nginx.conf"
if grep -qE '^[[:space:]]*add_header[[:space:]]+X-Frame-Options' "$NGX2"; then
    sed -i -E 's|^([[:space:]]*)(add_header[[:space:]]+X-Frame-Options.*)$|\1# \2  # disabled by LSI-Storage-Fnos|' "$NGX2"
  log 40 "补丁 3e：已注释掉 $(grep -cE 'disabled by LSI-Storage-Fnos' "$NGX2") 处 X-Frame-Options"
  report "- 补丁 3e: 移除 LSA 前端 X-Frame-Options（允许被 iframe 内嵌）"
else
  log 40 "补丁 3e：nginx.conf 里没有 X-Frame-Options，跳过"
fi

# ---- 补丁 4：端口占位符 ----
CONF="$LSA/conf/LSA.conf"; NGX="$LSA/server/conf/nginx.conf"
[ -f "$CONF" ] || die "未找到 $CONF"
[ -f "$NGX" ]  || die "未找到 $NGX"
[ -f "$CONF.dist" ] || cp -a "$CONF" "$CONF.dist"
[ -f "$NGX.dist" ]  || cp -a "$NGX"  "$NGX.dist"

HITS=$( (grep -cE 'nginx_default|LSA_Default' "$CONF" "$NGX" 2>/dev/null || true) | awk -F: '{s+=$2} END{print s+0}')
log 40 "  占位符命中 $HITS 处（首次构建应为 8；重复构建为 0 属正常）"
sed -i 's/nginx_default/2463/g; s/LSA_Default/9000/g' "$CONF" "$NGX"
if grep -qE 'nginx_default|LSA_Default' "$CONF" "$NGX"; then
  die "占位符未清干净，配置结构可能变化，需人工核对"
fi

# ---- 补丁 5：日志级别 ----
# LSA.conf 自带映射：NOLOG=0 PERF=1 CRITICAL=2 ERROR=4 WARNING=8 INFO=16 DEBUG=32
# FUNCTION_ENTRY=64 EVERYTHING=255。出厂是 64（每行 Fn Entry 都落盘），改成 4。
if grep -qE '^[[:space:]]*log_level[[:space:]]*=' "$CONF" 2>/dev/null; then
  OLD=$(grep -E '^[[:space:]]*log_level[[:space:]]*=' "$CONF" | head -1 | sed 's/.*=[[:space:]]*//')
  sed -i -E 's#^([[:space:]]*log_level[[:space:]]*=[[:space:]]*).*#\14#' "$CONF"
  NEW=$(grep -E '^[[:space:]]*log_level[[:space:]]*=' "$CONF" | head -1 | sed 's/.*=[[:space:]]*//')
  log 40 "  日志级别 $OLD → $NEW（4=ERROR）"
  report "- 日志级别: $OLD → $NEW"
else
  warn "未找到 log_level，依赖运行期日志上限"
  report "- 日志级别: 未找到配置项"
fi
for f in "$LSA/bin/storelibdebug.txt" "$LSA/bin/storelibdebugit.txt"; do
  [ -f "$f" ] && { : > "$f"; log 40 "  已清空 $(basename "$f")"; }
done

# ---- 补丁 6：预置账号 ----
if ! in_rfs "id lsiadmin" >/dev/null 2>&1; then
  in_rfs "useradd -m -u 2000 -s /bin/bash lsiadmin" || die "useradd LSI-Storage-Fnos 失败"
  in_rfs "passwd -l lsiadmin >/dev/null 2>&1 || true"
fi
in_rfs "id lsiadmin" 2>/dev/null | sed 's/^/    /'
report "- 账号: $(in_rfs 'id lsiadmin' 2>/dev/null)"

# ---- 只读组（尽力而为，需在 fnOS 上实测是否生效）----
if grep -qE '^[[:space:]]*readonly_access_groups' "$CONF" 2>/dev/null; then
  sed -i -E 's#^([[:space:]]*readonly_access_groups[[:space:]]*=[[:space:]]*).*#\1lsiadmin#' "$CONF"
  ok "readonly_access_groups = lsiadmin"
else
  warn "未发现 readonly_access_groups 字段（记为待实测项）"
fi

[ -e "$RFS/usr/lib/x86_64-linux-gnu/libcrypt.so.2" ] || die "补丁1 未生效"
report "- 补丁完成: $(rfs_mb) MB"
ok "阶段 40 完成（$(rfs_mb) MB）"

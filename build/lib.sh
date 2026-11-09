#!/bin/bash
# 构建流水线公共库。所有阶段脚本 source 本文件。
set -euo pipefail

PROJ=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK="$PROJ/build/work"
DIST="$PROJ/build/dist"
RFS="$WORK/rootfs"
PKG_SRC="$PROJ/pkg"

# ---- 版本钉（改这里就是改版本，别散落在各处） ----
ROOTFS_URL="http://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-amd64.tar.gz"
ROOTFS_SHA="e77b6f10c2590cef872b33ee9f635a0e3fd1f57fb074c0e52b5c7f56147a0c86"
# ===========================================================================
# LSA 基线选择 —— 不要"优化"成 gcc_14.2.x 或 gcc_11.2.x
# ===========================================================================
# Broadcom 为同一版本提供三套基线（按编译器/发行版）：
#   gcc_8.3.x  → SLES 15    glibc 2.28   最低 CPU ISA
#   gcc_11.2.x → RHEL 9     glibc 2.34   较高 ISA（x86-64-v2 级）
#   gcc_14.2.x → Ubuntu 24.04 glibc 2.39 更高 ISA
#
# 直觉上会选 gcc_14.2.x（"我们的 rootfs 就是 Ubuntu 24.04，最匹配"），
# 但实测证明这是错的：**CPU ISA 是比 glibc 更硬的约束**。
#   在 QEMU 的 "Common KVM processor"（无 AVX/AVX2/SSE4.2）上：
#     gcc_14.2.x 的 server/nginx → "CPU ISA level is lower than required"
#     gcc_11.2.x 的 server/nginx → 同样报错
#     gcc_8.3.x  的 server/nginx → 正常运行
# 而绝大多数 fnOS 用户跑在虚拟机里，CPU 模型经常就是这种最小配置。
#
# 选 gcc_8.3.x 的唯一代价：它链接 libldap-2.4.so.2（SLES 的 OpenLDAP 2.4 soname），
# 而 Ubuntu 24.04 只有 libldap.so.2（OpenLDAP 2.6）。因为本应用用 OS 认证
# （ldap_mode = 0），LDAP 通路永不执行，用符号链接满足加载期符号解析即可
# —— 见 40-patch.sh 的补丁 3d。
#
# 想换更高基线，必须先在目标机型上验证：
#   chroot <rootfs> /bin/bash -c 'cd /opt/lsi/LSIStorageAuthority/server && ./nginx -p . -t'
# 只要输出 "CPU ISA level is lower than required"，就不许换。
# ===========================================================================
LSA_BASELINE="${LSA_BASELINE:-gcc_8.3.x}"
APK_MAX_MB=400                     # fpk 压缩包体积硬上限（用户接受 200-400MB）

# LSA 安装包：由环境变量 LSA_ZIP 指定，或放到 build/vendor/ 下自动发现
LSA_ZIP="${LSA_ZIP:-}"
VENDOR="$PROJ/build/vendor"

C_OK=$'\033[1;32m'; C_INFO=$'\033[1;34m'; C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'
log()  { printf '%s[%s]%s %s\n' "$C_INFO" "$1" "$C_OFF" "$2"; }
warn() { printf '%s[WARN]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
need_root() { [ "$(id -u)" = "0" ] || die "构建需要 root（chroot/mount）"; }

rfs_mb() { du -sm "$RFS" 2>/dev/null | cut -f1; }
now()    { date '+%H:%M:%S'; }

# rootfs 里的 chroot 封装：统一带上 PATH，避免 mini 环境缺 /usr/sbin
in_rfs() { chroot "$RFS" /usr/bin/env -i \
             PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
             HOME=/root LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
             /bin/bash -lc "$*"; }

# ---------------------------------------------------------------------------
# 挂载安全（P0）
#
# 事故记录：早期版本用 `umount -R "$RFS/dev"` 清理，把**宿主的 /dev/pts** 卸掉了两次。
# 根因是挂载传播没被完全隔离，`-R` 递归卸载顺着传播链回到了宿主。
#
# 现在的做法是结构性的：整个阶段脚本先把自己 re-exec 进一个私有挂载命名空间，
# 命名空间销毁时内核自动卸载全部挂载 —— 脚本里**一次显式 umount 都不需要写**。
# 这比"小心翼翼地记着自己挂了什么"更可靠，因为忘了写 umount 也不会泄漏。
# ---------------------------------------------------------------------------
RV_IN_NS=${RV_IN_NS:-0}

rfs_enter_ns() {
  [ "$RV_IN_NS" = "1" ] && return 0
  need unshare
  printf '%s[ns]%s 进入私有挂载命名空间（卸载由内核完成，脚本不再执行 umount）\n' "$C_INFO" "$C_OFF"
  exec env RV_IN_NS=1 unshare -m --propagation private bash "$(readlink -f "$0")" "$@"
}

# 只在命名空间内调用；离开命名空间自动还原，不留残留
rfs_mount() {
  [ "${RV_IN_NS:-0}" = "1" ] || die "rfs_mount 必须在 rfs_enter_ns 之后调用"
  mkdir -p "$RFS/proc" "$RFS/dev" "$RFS/sys" "$RFS/run"
  mount --rbind /proc "$RFS/proc" || die "rbind /proc 失败"
  mount --rbind /dev  "$RFS/dev"  || die "rbind /dev 失败"
  mount --rbind /sys  "$RFS/sys"  || die "rbind /sys 失败"
}

# 兼容旧调用点：命名空间内是空操作；命名空间外直接报错，避免有人写回显式卸载。
rfs_umount() {
  if [ "${RV_IN_NS:-0}" = "1" ]; then
    log ns "挂载随命名空间销毁，跳过显式 umount"
    return 0
  fi
  die "rfs_umount 在命名空间外被调用：请先用 rfs_enter_ns，禁止对宿主路径直接 umount"
}

find_lsa_zip() {
  if [ -n "$LSA_ZIP" ] && [ -f "$LSA_ZIP" ]; then echo "$LSA_ZIP"; return 0; fi
  local f
  f=$(ls -1 "$VENDOR"/*LSA_Linux.zip "$VENDOR"/*LSA*.zip 2>/dev/null | head -1 || true)
  [ -n "$f" ] && { echo "$f"; return 0; }
  return 1
}

# 记录构建报告条目
report() { printf '%s\n' "$*" >> "$WORK/BUILD-REPORT.md"; }

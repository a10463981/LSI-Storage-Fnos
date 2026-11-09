#!/bin/bash
# 阶段 20：chroot 内安装 LSA 运行时依赖。
# 注意：passwd 包提供 chpasswd/useradd，运行期设置口令要用。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
rfs_enter_ns "$@"
rfs_mount      # 命名空间内挂载，离开即自动卸载

log 20 "apt-get update"
in_rfs "apt-get update" || die "apt update 失败（检查 DNS / 源可用性）"

log 20 "安装依赖"
in_rfs "apt-get install -y --no-install-recommends \
  libldap2 libsasl2-2 libaio1t64 libtinfo6 zlib1g libstdc++6 passwd psmisc" \
  || die "依赖安装失败"

for c in chpasswd useradd ldconfig killall; do
  in_rfs "command -v $c" >/dev/null 2>&1 || die "chroot 内缺少 $c（passwd 包未装成功）"
done

report "- 依赖装完后: $(rfs_mb) MB"
ok "阶段 20 完成（$(rfs_mb) MB）"

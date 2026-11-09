#!/bin/bash
# 骨架载荷：Ubuntu base + 依赖 + raidview 账号，**不含 LSA**。
#
# 用途：在没有 LSA 安装包的情况下，验证平台链路——
#   打包 → 安装 → 解包 → chpasswd → 起停 → 零残留。
# 它刻意不假装是完整载荷：payload 里带 {"kind":"skeleton"}，
# install/main 会打印明确警告，且不做 LSA 文件检查。
#
# 产物: build/work/skel/rootfs.tar.gz
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
rfs_enter_ns "$@"

SK="$WORK/skel"; RS="$SK/rootfs"
TAR="$WORK/00/ubuntu-base-24.04.5-base-amd64.tar.gz"
[ -f "$TAR" ] || die "缺少 rootfs tar，请先跑 build/00-fetch.sh"

rm -rf "$SK"; mkdir -p "$RS"
log 90 "解压 rootfs → $RS"
tar -xzf "$TAR" -C "$RS" || die "解压失败"

rm -f "$RS"/etc/apt/sources.list.d/*.sources "$RS"/etc/apt/sources.list 2>/dev/null || true
cat > "$RS/etc/apt/sources.list.d/tuna.list" <<'EOF'
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble main universe
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble-updates main universe
EOF
printf 'nameserver 223.5.5.5\nnameserver 1.1.1.1\n' > "$RS/etc/resolv.conf"
mkdir -p "$RS/etc/apt/apt.conf.d"
printf 'APT::Install-Recommends "false";\nAPT::Install-Suggests "false";\n' \
  > "$RS/etc/apt/apt.conf.d/99norecommends"

RFS_BAK=$RFS; RFS=$RS
rfs_mount

log 90 "apt update + 依赖（约 1-2 分钟）"
in_rfs "apt-get update" >/dev/null || die "apt update 失败"
in_rfs "apt-get install -y --no-install-recommends libldap2 libsasl2-2 libaio1t64 libtinfo6 zlib1g libstdc++6 passwd" \
  >/dev/null || die "依赖安装失败"

if ! in_rfs "id raidview" >/dev/null 2>&1; then
  in_rfs "useradd -m -u 2000 -s /bin/bash raidview" || die "useradd 失败"
  in_rfs "passwd -l raidview >/dev/null 2>&1 || true"
fi
log 90 "账号: $(in_rfs 'id raidview')"

log 90 "清理"
rm -rf "$RS"/var/lib/apt/lists/* "$RS"/var/cache/apt/archives/*.deb 2>/dev/null || true
rm -rf "$RS"/usr/share/doc/* "$RS"/usr/share/man/* "$RS"/usr/share/info/* 2>/dev/null || true
RFS=$RFS_BAK

log 90 "打包"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -czpf "$SK/rootfs.tar.gz" -C "$RS" . || die "tar 失败"
rm -rf "$RS"

SZ=$(du -m "$SK/rootfs.tar.gz" | cut -f1)
log 90 "骨架载荷: $SK/rootfs.tar.gz  ${SZ} MB"
ok "阶段 90 完成"

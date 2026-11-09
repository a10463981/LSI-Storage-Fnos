#!/bin/bash
# 阶段 10：解压 rootfs，写 apt 源（必须 HTTP）与 DNS。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
TAR="$WORK/00/ubuntu-base-24.04.5-base-amd64.tar.gz"
[ -f "$TAR" ] || die "缺少 rootfs tar，请先跑 00-fetch.sh"

rm -rf "$RFS"; mkdir -p "$RFS"
log 10 "解压 rootfs → $RFS"
tar -xzf "$TAR" -C "$RFS" || die "解压失败"

# 源必须用 HTTP：base 镜像不带 ca-certificates，HTTPS 会报 No system certificates available
rm -f "$RFS"/etc/apt/sources.list.d/*.sources "$RFS"/etc/apt/sources.list 2>/dev/null || true
cat > "$RFS/etc/apt/sources.list.d/tuna.list" <<'EOF'
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble main universe
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble-updates main universe
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble-backports main universe
EOF

cat > "$RFS/etc/resolv.conf" <<'EOF'
nameserver 223.5.5.5
nameserver 1.1.1.1
EOF

# 屏蔽 apt 在容器/最小环境下的无关告警
mkdir -p "$RFS/etc/apt/apt.conf.d"
echo 'APT::Install-Recommends "false";' > "$RFS/etc/apt/apt.conf.d/99norecommends"
echo 'APT::Install-Suggests "false";'   >> "$RFS/etc/apt/apt.conf.d/99norecommends"

report "- rootfs 解压后: $(rfs_mb) MB"
ok "阶段 10 完成（rootfs $(rfs_mb) MB）"

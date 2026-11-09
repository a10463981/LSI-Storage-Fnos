#!/bin/bash
# 阶段 70：打包 rootfs 载荷。
# 用 gzip 而不是 zstd：fnOS 上 gzip/tar 必定存在，zstd 不保证。
# 体积略大（约多 20-30MB），换取运行期零依赖 —— 这是正确的取舍。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need tar; need gzip; need du

OUT="$WORK/70/rootfs.tar.gz"; mkdir -p "$WORK/70"
rm -f "$OUT"

# 打包前清运行态污染
rm -rf "$RFS"/run/* "$RFS"/tmp/* "$RFS"/var/tmp/* 2>/dev/null || true
rm -rf "$RFS"/opt/lsi/LSIStorageAuthority/logs/* 2>/dev/null || true
mkdir -p "$RFS/opt/lsi/LSIStorageAuthority/logs" "$RFS/run"
: > "$RFS/etc/resolv.conf" 2>/dev/null || true

# 构建指纹：用来在真机上确认"rootfs 到底有没有被换掉"
{
  echo "app_version=$(grep -E '^version' "$PROJ/pkg/manifest" | head -1 | sed 's/.*=[[:space:]]*//')"
  echo "lsa_baseline=${LSA_BASELINE}"
  echo "built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "built_on=$(hostname)"
} > "$RFS/etc/lsi-storage-fnos-build"
log 70 "构建指纹: $(tr '\n' ' ' < "$RFS/etc/lsi-storage-fnos-build")"

log 70 "打包 rootfs（gzip -6，可重复：排序+固定 mtime/owner）"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -czpf "$OUT" -C "$RFS" . || die "tar 失败"

SZ_MB=$(du -m "$OUT" | cut -f1)
RAW_MB=$(rfs_mb)
log 70 "rootfs 原始 ${RAW_MB}MB → 压缩 ${SZ_MB}MB（压缩比 $(awk -v a="$RAW_MB" -v b="$SZ_MB" 'BEGIN{printf "%.2f", a/b}') : 1）"
report "- rootfs 载荷: 原始 ${RAW_MB} MB → 压缩 ${SZ_MB} MB"
[ "$SZ_MB" -le "$APK_MAX_MB" ] || die "载荷 ${SZ_MB}MB 超出上限 ${APK_MAX_MB}MB"

echo "$OUT"
ok "阶段 70 完成（载荷 ${SZ_MB}MB）"

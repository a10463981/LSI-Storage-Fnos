#!/bin/bash
# 阶段 00：下载并校验基础 rootfs、定位 LSA 安装包。任何校验失败立即中止。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need curl; need sha256sum; need unzip; need tar
mkdir -p "$WORK/00" "$VENDOR"

# ---- rootfs ----
TAR="$WORK/00/ubuntu-base-24.04.5-base-amd64.tar.gz"
log 00 "下载 rootfs（清华 TUNA；USTC 对大文件返回 403）"
if [ -f "$TAR" ] && echo "$ROOTFS_SHA  $TAR" | sha256sum -c --status 2>/dev/null; then
  ok "rootfs 已缓存且校验通过"
else
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$TAR.part" "$ROOTFS_URL" \
    || die "rootfs 下载失败: $ROOTFS_URL"
  mv "$TAR.part" "$TAR"
  echo "$ROOTFS_SHA  $TAR" | sha256sum -c --status || die "rootfs SHA256 不匹配（供应链完整性，不可降级为警告）"
  ok "rootfs 下载并校验通过"
fi
report "- rootfs: $(basename "$TAR") sha256=$ROOTFS_SHA size=$(du -h "$TAR" | cut -f1)"

# ---- LSA 安装包 ----
LZ=$(find_lsa_zip) || die "未找到 LSA 安装包。
  LSA 是 Broadcom 专有软件，仓库里不携带。请自行下载后放入：
    $VENDOR/
  或通过环境变量指定：  LSA_ZIP=/path/to/008.018.012.000_MR_7.38_LSA_Linux.zip make image"
LZ_SHA=$(sha256sum "$LZ" | cut -d' ' -f1)
log 00 "LSA 安装包: $(basename "$LZ")  $(du -h "$LZ" | cut -f1)"
log 00 "LSA sha256: $LZ_SHA"
report "- LSA: $(basename "$LZ") sha256=$LZ_SHA size=$(du -h "$LZ" | cut -f1)"
echo "$LZ" > "$WORK/00/lsa.path"
ok "阶段 00 完成"

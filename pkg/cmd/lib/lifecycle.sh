#!/bin/bash
# 安装/升级/卸载相关的公共逻辑。被 install/upgrade/uninstall 钩子 source。

# 载荷位置：<target>/rootfs.tar.gz（构建产物随包发布）
rv_payload() { echo "$RV_TARGET/rootfs.tar.gz"; }
rv_payload_kind() {
  local f="$RV_TARGET/.payload.json"
  if [ -f "$f" ]; then
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("kind","full"))' "$f" 2>/dev/null || echo full
  else
    echo full
  fi
}

rv_check_space() {
  local need_mb=${1:-1000} free_mb
  # 优先用平台给的卷根路径，避免硬编码 /vol1
  local probe="${TRIM_APPDEST_VOL:-$VAR}"
  free_mb=$(df -m "$probe" 2>/dev/null | awk 'NR==2{print $4}')
  free_mb=${free_mb:-0}
  if [ "$free_mb" -lt "$need_mb" ]; then
    echo "数据卷剩余空间 ${free_mb}MB，小于所需 ${need_mb}MB。" >&2
    echo "rootfs 展开约需 400MB，加上原包与日志建议预留 1GB 以上。" >&2
    return 1
  fi
  echo "数据卷剩余空间 ${free_mb}MB，满足要求（≥${need_mb}MB）"
  return 0
}

rv_extract_rootfs() {
  local src dst kind
  src=$(rv_payload)
  dst=$RFS
  kind=$(rv_payload_kind)

  if [ ! -f "$src" ]; then
    echo "载荷缺失: $src" >&2
    return 1
  fi
  echo "解包运行环境到 $dst（约 300MB，视磁盘速度 1~3 分钟）"
  rm -rf "$dst"
  mkdir -p "$dst"
  if ! tar -xzpf "$src" -C "$dst"; then
    echo "解包失败（磁盘空间不足或载荷损坏）" >&2
    rm -rf "$dst"
    return 1
  fi

  if [ "$kind" = "skeleton" ]; then
    echo "!! 这是骨架载荷（不含 LSA），仅用于验证平台链路，不能用于生产。" >&2
    return 0
  fi

  local f
  for f in opt/lsi/LSIStorageAuthority/bin/LSA \
           etc/init.d/LsiSASH \
           opt/lsi/LSIStorageAuthority/server/conf/nginx.conf \
           usr/lib/x86_64-linux-gnu/libcrypt.so.2; do
    if [ ! -e "$dst/$f" ]; then
      echo "解包后缺少 $f，载荷不完整" >&2
      return 1
    fi
  done
  echo "解包完成，占用 $(du -sm "$dst" | cut -f1) MB"
  return 0
}

rv_stop_all() {
  if [ -x "$RV_CMD_DIR/main" ]; then
    "$RV_CMD_DIR/main" stop >/dev/null 2>&1 || true
  fi
  # 兜底：清理任何还挂在 rootfs 上的挂载
  local left
  left=$(awk -v p="$RFS" '$2 ~ p {print $2}' /proc/mounts 2>/dev/null)
  if [ -n "$left" ]; then
    echo "清理残留挂载: $(echo "$left" | tr '\n' ' ')"
    echo "$left" | sort -r | while read -r m; do
      umount -l "$m" 2>/dev/null || umount -f "$m" 2>/dev/null || true
    done
  fi
  # 兜底：回收 chroot 内任何残留进程
  local pids
  pids=$(rv_procs_in_root "$RFS")
  if [ -n "$pids" ]; then
    echo "回收残留进程: $(echo $pids | tr '\n' ' ')"
    kill -TERM $pids 2>/dev/null || true
    sleep 2
    pids=$(rv_procs_in_root "$RFS")
    if [ -n "$pids" ]; then kill -KILL $pids 2>/dev/null || true; fi
  fi
}

# 升级：先保留旧 rootfs，新的解包并校验通过后才删旧的；失败自动回滚。
# 之所以要"保留"，是因为解包可能因磁盘不足/载荷损坏中途失败，
# 而那时旧目录已经被删掉 —— 用户会得到一个既不能跑、也无法回退的应用。
rv_upgrade_rootfs() {
  local old="${RFS}.prev"
  rv_stop_all
  rm -rf "$old"
  if [ -d "$RFS" ]; then
    mv "$RFS" "$old" || { echo "无法保留旧 rootfs（磁盘满或权限问题）" >&2; return 1; }
    echo "旧 rootfs 已保留在 $old，作为回滚点"
  fi
  if rv_extract_rootfs; then
    rm -rf "$old"
    echo "升级完成，回滚点已清理"
    return 0
  fi
  echo "解包失败，开始回滚…" >&2
  rm -rf "$RFS"
  if [ -d "$old" ]; then
    mv "$old" "$RFS" && echo "已回滚到升级前的 rootfs" >&2
  else
    echo "回滚点不存在，应用需要重新安装" >&2
  fi
  return 1
}

# 启动前自愈：上次升级中途失败留下的 .prev 直接恢复
rv_recover_prev() {
  local old="${RFS}.prev"
  [ -d "$old" ] || return 0
  if [ ! -x "$RFS/opt/lsi/LSIStorageAuthority/bin/LSA" ]; then
    echo "检测到未完成的升级，从回滚点恢复…" >&2
    rm -rf "$RFS"
    mv "$old" "$RFS" && echo "已恢复" >&2
  else
    rm -rf "$old"
  fi
  return 0
}

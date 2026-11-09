#!/bin/bash
# 组装 fpk 并调用 fnpack。
#
# 三个实测教训写在这里，别再踩：
#  1. fnpack 的产物落在**执行命令时的 cwd**，不是 -d 指定的目录 → 必须 cd 过去。
#  2. 不能用管道接 fnpack（`| head`/`| tee` 会把退出码变成管道末端命令的 0）→ 失败被吞。
#  3. `checksum` 由 fnpack 自动注入，manifest 里绝不能手写。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
bash "$PROJ/build/verify/check-mounts.sh" || die "挂载安全守卫未通过，拒绝打包"
need rsync 2>/dev/null || true

SRC="$PROJ/pkg"
OUT="$DIST"; rm -rf "$OUT"; mkdir -p "$OUT"

log 80 "复制包源到 $OUT/pkg"
cp -a "$SRC" "$OUT/pkg"
rm -f "$OUT/pkg/manifest.FIELDS.md"

PAYLOAD="${PAYLOAD:-$WORK/70/rootfs.tar.gz}"
PK="$OUT/pkg"
mkdir -p "$PK/app"
if [ -f "$PAYLOAD" ]; then
  log 80 "载荷: $PAYLOAD ($(du -m "$PAYLOAD" | cut -f1) MB)"
  cp "$PAYLOAD" "$PK/app/rootfs.tar.gz"
  echo '{"kind":"full","lsa":"008.018.012.000"}' > "$PK/app/.payload.json"
elif [ "${SKELETON:-0}" = "1" ] && [ -f "$WORK/skel/rootfs.tar.gz" ]; then
  log 80 "载荷: 骨架（不含 LSA）"
  cp "$WORK/skel/rootfs.tar.gz" "$PK/app/rootfs.tar.gz"
  echo '{"kind":"skeleton","lsa":null}' > "$PK/app/.payload.json"
else
  die "没有载荷。先跑 'make image'（完整）或 'SKELETON=1 make pkg'（骨架）"
fi

chmod 755 "$PK"/cmd/* "$PK"/cmd/lib/*.sh "$PK"/app/runtime/*.sh "$PK"/app/runtime/*.py 2>/dev/null || true
chmod 644 "$PK"/app/rootfs.tar.gz 2>/dev/null || true

log 80 "包源体积: $(du -sm "$PK" | cut -f1) MB"
log 80 "调 fnpack（cwd=$OUT，产物落在 cwd）"
cd "$OUT" || die "无法进入 $OUT"
if ! fnpack build -d "$PK" > "$OUT/fnpack.log" 2>&1; then
  cat "$OUT/fnpack.log" >&2
  die "fnpack build 失败"
fi
cat "$OUT/fnpack.log" | sed 's/^/    /'

FPK=$(ls -1 "$OUT"/*.fpk 2>/dev/null | head -1)
[ -n "$FPK" ] || die "fnpack 未产出 .fpk（检查 manifest/appname）"
SZ=$(du -m "$FPK" | cut -f1)
log 80 "产物: $FPK  ${SZ} MB"
file "$FPK" | sed 's/^/    /'
ok "打包完成"

#!/bin/bash
# 阶段 60：冒烟测试。构建期必跑，不过不许出产物。
#   --quick : nginx 端口在 240s 内监听即通过（瘦身批次用，快）
#   --full  : root API 600s 内返回 200（发布前用，严）
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
MODE=${1:---full}
RUN_DIR="$WORK/60-run"; rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"

# 复用运行时库（RFS/RUN 预置，覆盖自动解析）
RFS="$RFS" RUN="$RUN_DIR" CONF_FILE="$RUN_DIR/config"
# shellcheck disable=SC1091
. "$PROJ/pkg/cmd/lib/common.sh"

FRONT=24631; BACK=39001
[ "$MODE" = "--full" ] && log 60 "冒烟（完整模式：等待 API 200，最长 600s）" || log 60 "冒烟（快速模式：等待端口监听，最长 240s）"

rv_lsa_inject_ports "$FRONT" "$BACK" || die "端口注入失败 —— 配置结构可能已变化"
rm -f "$RUN_DIR/stop.flag"
: > "$RUN_DIR/lsa.log"
"$PROJ/pkg/app/runtime/launch.sh" "$RFS" "$RUN_DIR" >>"$RUN_DIR/lsa.log" 2>&1 &
LPID=$!

cleanup() {
  touch "$RUN_DIR/stop.flag" 2>/dev/null || true
  sleep 3
  kill -TERM "$LPID" 2>/dev/null || true
  sleep 1
  kill -KILL "$LPID" 2>/dev/null || true
  local pids; pids=$(rv_procs_in_root "$RFS")
  [ -n "$pids" ] && { kill -KILL $pids 2>/dev/null || true; }
  local left; left=$(awk -v p="$RFS" '$2 ~ p {print $2}' /proc/mounts 2>/dev/null)
  if [ -n "$left" ]; then
    warn "冒烟结束后仍有挂载残留（命名空间应自动清理，这里是二道保险）"
    echo "$left" | sort -r | while read -r m; do umount -l "$m" 2>/dev/null || true; done
  fi
}
trap cleanup EXIT

ok_flag=0
if [ "$MODE" = "--full" ]; then
  LIMIT=200   # 200 × 3s = 600s
else
  LIMIT=80    # 80 × 3s = 240s
fi
for i in $(seq 1 $LIMIT); do
  if ! kill -0 "$LPID" 2>/dev/null; then
    die "启动器已退出（第 $((i*3))s）。日志尾部：
$(tail -30 "$RUN_DIR/lsa.log")"
  fi
  if rv_port_listen "$FRONT"; then
    if [ "$MODE" = "--quick" ]; then ok_flag=1; break; fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 \
           "http://127.0.0.1:$FRONT/LSI/Storage/MR/API/1.0/" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then ok_flag=1; log 60 "API 就绪，用时 $((i*3))s"; break; fi
  fi
  [ $((i % 10)) -eq 0 ] && log 60 "  等待中… $((i*3))s"
  sleep 3
done

if [ "$ok_flag" != 1 ]; then
  echo "--- lsa.log 尾部 ---" >&2; tail -40 "$RUN_DIR/lsa.log" >&2 || true
  echo "--- 进程 ---" >&2; ps -ef | grep -E 'Lsia|LSA|nginx|slpd' | grep -v grep >&2 || true
  echo "--- 端口 ---" >&2; ss -lnt 2>/dev/null | grep -E ":($FRONT|$BACK)" >&2 || true
  echo "--- LSA 日志 ---" >&2
  tail -30 "$RFS/opt/lsi/LSIStorageAuthority/logs/lsa.txt" 2>/dev/null >&2 || true
  die "冒烟失败（模式 $MODE）"
fi

ok "冒烟通过（模式 $MODE）"

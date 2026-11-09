#!/bin/bash
# 不装 fpk，直接在目标机上验证运行环境是否可用（E2 用）。
#
# 用法（在 .15 上，需 root）：
#   sudo ./dev/run-local.sh /path/to/rootfs.tar.gz
#   sudo ./dev/run-local.sh --stop
#
# 它把 rootfs 解到 /var/tmp/lsi-storage-fnos-dev/rootfs，注入测试端口，起 LSA 与门户。
# 所有挂载都在 launch.sh 的独立 mount 命名空间里，命名空间销毁自动卸载，零残留。
set -u
BASE=/var/tmp/lsi-storage-fnos-dev
RFS=$BASE/rootfs
RUN=$BASE/run
SRC_DIR=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
GATE=2463
FRONT=2464

[ "$(id -u)" = "0" ] || { echo "需要 root" >&2; exit 1; }
mkdir -p "$RUN"

stop_it() {
  touch "$RUN/stop.flag" 2>/dev/null || true
  sleep 3
  if [ -f "$RUN/gate.pid" ]; then kill -TERM "$(cat "$RUN/gate.pid")" 2>/dev/null || true; rm -f "$RUN/gate.pid"; fi
  if [ -f "$RUN/ns.pid" ]; then kill -TERM "$(cat "$RUN/ns.pid")" 2>/dev/null || true; fi
  # 按 /proc/PID/root 回收（chroot 内进程 cmdline 不含宿主路径）
  # chroot 后进程 cmdline 不含宿主路径，只能按 /proc/PID/root 判归属
  local_pids=$(for p in /proc/[0-9]*; do r=$(readlink -f "$p/root" 2>/dev/null); [ "$r" = "$RFS" ] && echo "${p#/proc/}"; done)
  [ -n "$local_pids" ] && kill -KILL $local_pids 2>/dev/null || true
  sleep 1
  # 挂载都在 launch.sh 的私有命名空间里，命名空间销毁自动卸载。
  # 这里只做只读复验，**不对任何路径执行 umount**（历史上 umount -R 曾误卸宿主 /dev/pts）。
  left=$(awk -v p="$RFS" '$2 ~ p {print $2}' /proc/mounts 2>/dev/null)
  if [ -n "$left" ]; then
    echo "警告: 仍有挂载残留（命名空间应已销毁，这通常是进程未退干净）: $left" >&2
    echo "      请先确认没有 chroot 内进程存活；不要手工递归卸载。" >&2
  fi
  echo "已停止"
}

if [ "${1:-}" = "--stop" ]; then stop_it; exit 0; fi

TAR=${1:-}
[ -f "$TAR" ] || { echo "用法: $0 <rootfs.tar.gz>" >&2; exit 1; }

echo "== 解包到 $RFS =="
rm -rf "$RFS"; mkdir -p "$RFS"
tar -xzpf "$TAR" -C "$RFS" || { echo "解包失败" >&2; exit 1; }
echo "占用 $(du -sm "$RFS" | cut -f1) MB"

# 注入端口（复用运行时逻辑）
export RFS RUN
# shellcheck disable=SC1091
. "$SRC_DIR/pkg/cmd/lib/common.sh"
rv_lsa_inject_ports "$FRONT" "$GATE" >/dev/null 2>&1 || {
  # 后端端口随便取一个
  BACK=$(rv_pick_port); rv_lsa_inject_ports "$FRONT" "$BACK" || { echo "端口注入失败" >&2; exit 1; }
}

rm -f "$RUN/stop.flag"
echo "== 启动 LSA（独立 mount 命名空间） =="
nohup "$SRC_DIR/pkg/app/runtime/launch.sh" "$RFS" "$RUN" >>"$RUN/lsa.log" 2>&1 &
echo $! > "$RUN/ns.pid"

echo "== 启动门户 =="
GATE_PORT=$GATE FRONT_PORT=$FRONT RFS=$RFS RUN=$RUN \
  nohup python3 "$SRC_DIR/pkg/app/runtime/gate.py" >>"$RUN/gate.out" 2>&1 &
echo $! > "$RUN/gate.pid"

sleep 2
echo
echo "门户已启动: http://<本机IP>:$GATE/"
echo "查看状态:   curl -s http://127.0.0.1:$GATE/status"
echo "停止:       sudo $0 --stop"
echo "日志:       $RUN/lsa.log  $RUN/gate.out"

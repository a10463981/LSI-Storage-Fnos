#!/bin/bash
# 启动前检查。任何硬失败都给出中文原因，不抛栈、不静默。
# 约定：warn 项不阻断（无卡是合法状态），fail 项阻断（缺 python3、端口被占、文件缺失）。

pf_mem_mb() { awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0; }
pf_disk_mb() { df -m "$1" 2>/dev/null | awk 'NR==2{print $4}' || echo 0; }

pf_report() { rv_say "preflight: $*"; }

preflight() {
  local fail=0

  [ "$(id -u)" = "0" ] || { rv_err "需要 root 运行（chroot/mount 必需）"; return 1; }

  # 1. rootfs 完整性（抽查关键文件，避免每次全量校验太慢）
  local kind="full"
  command -v rv_payload_kind >/dev/null 2>&1 && kind=$(rv_payload_kind)
  local miss=""
  if [ "$kind" = "skeleton" ]; then
    rv_say "警告: 当前为骨架载荷（不含 LSA），仅供平台链路验证"
    [ -x "$RFS/bin/bash" ] || miss="$miss bin/bash"
  else
    # 注意：这些路径是相对 chroot 根的，不是相对 /opt/lsi/...
    for f in opt/lsi/LSIStorageAuthority/bin/LSA \
             etc/init.d/LsiSASH \
             opt/lsi/LSIStorageAuthority/server/conf/nginx.conf \
             opt/lsi/LSIStorageAuthority/conf/LSA.conf \
             usr/lib/x86_64-linux-gnu/libcrypt.so.2; do
      [ -e "$RFS/$f" ] || miss="$miss $f"
    done
  fi
  if [ -n "$miss" ]; then
    rv_err "安装文件缺失:$miss"
    rv_err "请重新安装应用（rootfs 可能损坏）"
    fail=1
  fi

  # 2. python3（门户服务依赖）
  if ! command -v python3 >/dev/null 2>&1; then
    rv_err "系统缺少 python3，门户页无法启动。请安装 python3 后重试。"
    fail=1
  fi

  # 3. 磁盘
  local free_mb; free_mb=$(pf_disk_mb "$VAR")
  if [ "${free_mb:-0}" -lt 500 ]; then
    rv_err "数据卷剩余空间仅 ${free_mb}MB，至少需要 500MB 供日志与运行态使用"
    fail=1
  else
    pf_report "磁盘剩余 ${free_mb}MB"
  fi

  # 4. 内存（LSA 常驻需要数百 MB；不足只警告，仍尝试启动）
  local mem; mem=$(pf_mem_mb)
  if [ "${mem:-0}" -lt 400 ]; then
    rv_err "可用内存仅 ${mem}MB，LSA 极可能启动失败。请释放内存后重试。"
    fail=1
  elif [ "${mem:-0}" -lt 800 ]; then
    rv_say "警告: 可用内存 ${mem}MB 偏紧（建议 ≥800MB），启动可能较慢"
  else
    pf_report "可用内存 ${mem}MB"
  fi

  # 5. 端口
  cfg_load
  local gate front
  gate=$(cfg_get gate_port 2463); front=$(cfg_get front_port 2464)
  if rv_port_listen "$gate"; then
    # 占用者是不是我们自己的门户？
    #   正常情况用 pidfile 判断；pidfile 丢失（异常退出）时按进程环境变量里的 RUN 反查，
    #   否则会误判成"被别的程序占用"而拒绝启动——真实踩过。
    ours=0
    if rv_alive "$RUN/gate.pid"; then
      ours=1
    else
      for _p in /proc/[0-9]*; do
        [ -r "$_p/environ" ] || continue
        if tr '\0' '\n' < "$_p/environ" 2>/dev/null | grep -qx "RUN=$RUN"            && tr '\0' '\n' < "$_p/environ" 2>/dev/null | grep -qx "SOCK_PATH=.*gate.py" ; then :; fi
        if tr '\0' '\n' < "$_p/environ" 2>/dev/null | grep -qx "RUN=$RUN"; then
          _cl=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)
          case "$_cl" in *gate.py*) ours=1; break;; esac
        fi
      done
    fi
    if [ "$ours" != 1 ]; then
      rv_err "端口 ${gate} 已被其他程序占用，门户无法启动。请关闭占用该端口的服务后重试。"
      fail=1
    fi
  fi
  if rv_port_listen "$front" && ! rv_alive "$RUN/lsa.ns.pid"; then
    rv_err "端口 ${front} 已被其他程序占用。可在 $CONF_FILE 中把 front_port 改成其他端口后重试。"
    fail=1
  fi

  # 6. RAID 相关（仅提示，不阻断 —— 无卡是合法状态）
  if grep -qs megaraid_sas /sys/class/scsi_host/*/proc_name 2>/dev/null; then
    pf_report "megaraid_sas 已绑定控制器"
  elif ls /sys/bus/pci/devices/*/vendor 2>/dev/null | xargs -r grep -l '^0x1000$' 2>/dev/null | head -1 | grep -q .; then
    rv_say "警告: 检测到 Broadcom RAID 硬件，但 megaraid_sas 未绑定（可能需要 modprobe megaraid_sas）"
  else
    rv_say "提示: 本机未检测到 MegaRAID 控制器（界面可打开，控制器列表将为空）"
  fi
  [ -e /dev/megaraid_sas_ioctl_node ] && pf_report "管理设备节点存在" || rv_say "提示: /dev/megaraid_sas_ioctl_node 不存在"

  return $fail
}

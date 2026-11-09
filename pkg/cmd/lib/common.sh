#!/bin/bash
# raidview 运行时公共库。被 cmd/ 下所有钩子 source。
#
# 目录模型（与 fnOS 平台约定一致，实测自 /var/apps/<name>/）：
#   /var/apps/<name>/cmd/            ← 本目录（钩子与 main）
#   /var/apps/<name>/target -> ...   ← 应用载荷（app/ 的内容 + rootfs.tar.gz）
#   /var/apps/<name>/var    -> /vol1/@appdata/<name>   ← 运行态（rootfs、run、logs）
#   /var/apps/<name>/etc    -> /vol1/@appconf/<name>
# 平台会注入 TRIM_PKGVAR / TRIM_PKGETC / TRIM_APPDEST 等环境变量，优先使用。

RV_CMD_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # /var/apps/<name>/cmd
RV_APP_ROOT=$(cd "$RV_CMD_DIR/.." && pwd)                     # /var/apps/<name>
RV_NAME=$(basename "$RV_APP_ROOT")

# 真正的应用名以 manifest 的 appname 为准。
# 为什么会不一致：install_callback 运行在**安装暂存目录**里
# （/vol1/appcenter-downloads/<appname>-<version>-tpk/），那一刻
# basename(dirname(cmd)) 是 "raidview-0.1.9-tpk" 而不是 "raidview"。
# 曾因此把 GATE_PREFIX 算成 /app/raidview-0.1.9-tpk，导致面板访问 /app/raidview 全部 404。
RV_APPNAME="$RV_NAME"
for _mf in "$RV_APP_ROOT/manifest" "/var/apps/$RV_NAME/manifest"; do
  if [ -f "$_mf" ]; then
    _an=$(sed -nE 's/^appname[[:space:]]*=[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$_mf" | head -1)
    [ -n "$_an" ] && { RV_APPNAME="$_an"; break; }
  fi
done

# 载荷目录：优先 TRIM_APPDEST，其次 <root>/target
if [ -n "${RV_TARGET:-}" ]; then :
elif [ -n "${TRIM_APPDEST:-}" ] && [ -d "${TRIM_APPDEST}" ]; then RV_TARGET="$TRIM_APPDEST"
else RV_TARGET="$RV_APP_ROOT/target"; fi
RV_TARGET=$(readlink -f "$RV_TARGET" 2>/dev/null || echo "$RV_TARGET")

# 运行态目录
if [ -z "${VAR:-}" ]; then
  if [ -n "${TRIM_PKGVAR:-}" ] && [ -d "${TRIM_PKGVAR}" ]; then VAR="$TRIM_PKGVAR"
  elif [ -d "$RV_APP_ROOT/var" ]; then VAR=$(readlink -f "$RV_APP_ROOT/var")
  else VAR="$RV_APP_ROOT/var"; fi
fi
if [ -z "${ETC:-}" ]; then
  if [ -n "${TRIM_PKGETC:-}" ] && [ -d "${TRIM_PKGETC}" ]; then ETC="$TRIM_PKGETC"
  elif [ -d "$RV_APP_ROOT/etc" ]; then ETC=$(readlink -f "$RV_APP_ROOT/etc")
  else ETC="$RV_APP_ROOT/etc"; fi
fi

RFS=${RFS:-$VAR/rootfs}
RUN=${RUN:-$VAR/run}
LOGDIR=${LOGDIR:-$VAR/logs}
CONF_FILE=${CONF_FILE:-$ETC/raidview.conf}
LOG=$LOGDIR/raidview.log

mkdir -p "$RUN" "$LOGDIR" "$VAR/state" 2>/dev/null || true

LSA_ROOT=/opt/lsi/LSIStorageAuthority          # 相对 chroot
LSA_LD="/opt/lsi/LSA/libs:/opt/lsi/LSA/libs2"  # 自带 OpenSSL 3.2 必须在最前

rv_log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }
rv_say()  { printf '%s\n' "$*"; rv_log "$*"; }
rv_err()  { printf '错误: %s\n' "$*" >&2; rv_log "ERROR: $*"; }

# ---------- 配置 ----------
cfg_load() { [ -f "$CONF_FILE" ] && . "$CONF_FILE" || true; }
cfg_get() { local k=$1 d=$2 v=""; eval "v=\${$k:-}"; if [ -n "$v" ]; then echo "$v"; else echo "$d"; fi; }

# ---------- 进程 ----------
rv_alive() { local f=$1; [ -f "$f" ] || return 1; local p; p=$(cat "$f" 2>/dev/null | tr -d '[:space:]'); [ -n "$p" ] || return 1; kill -0 "$p" 2>/dev/null; }

rv_kill_pidfile() {
  local f=$1 p
  rv_alive "$f" || { rm -f "$f"; return 0; }
  p=$(cat "$f" | tr -d '[:space:]')
  kill -TERM "$p" 2>/dev/null || true
  local i
  for i in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null || true; sleep 0.3; fi
  rm -f "$f"
}

# chroot 后进程 cmdline 不含宿主路径，pgrep -f 必然失效。
# 唯一可靠判定：/proc/PID/root 指向哪个目录。
rv_procs_in_root() {
  local target
  target=$(readlink -f "$1" 2>/dev/null) || return 0
  [ -n "$target" ] || return 0
  local p r
  for p in /proc/[0-9]*; do
    [ -d "$p" ] || continue
    r=$(readlink -f "$p/root" 2>/dev/null) || continue
    if [ "$r" = "$target" ]; then echo "${p#/proc/}"; fi
  done
}

rv_procs_kill_in_root() {
  local rfs=$1 pids i
  pids=$(rv_procs_in_root "$rfs")
  [ -z "$pids" ] && return 0
  rv_say "回收 chroot 内残留进程: $(echo $pids | tr '\n' ' ')"
  kill -TERM $pids 2>/dev/null || true
  for i in $(seq 1 10); do
    sleep 0.5
    pids=$(rv_procs_in_root "$rfs")
    [ -z "$pids" ] && return 0
  done
  rv_say "强杀残留进程: $(echo $pids | tr '\n' ' ')"
  kill -KILL $pids 2>/dev/null || true
}

# ---------- 端口 ----------
rv_port_listen() {
  local p=$1
  if command -v ss >/dev/null 2>&1; then
    ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$p" <<'PY' 2>/dev/null
import socket,sys
s=socket.socket(); s.settimeout(0.5)
try:
    s.connect(("127.0.0.1",int(sys.argv[1]))); sys.exit(0)
except OSError:
    sys.exit(1)
PY
  else
    return 1
  fi
}

rv_pick_port() {
  local dump p
  dump=$(ss -lntH 2>/dev/null | awk '{print $4}')
  for p in $(seq 41000 41999); do
    echo "$dump" | grep -qE "[:.]${p}$" || { echo "$p"; return 0; }
  done
  return 1
}

# ---------- LSA ----------
# 定点注入端口：只改键值，不重建整个文件（LSA 运行时会回写 LSA.conf）
rv_lsa_inject_ports() {
  local front=$1 back=$2
  local conf="$RFS/opt/lsi/LSIStorageAuthority/conf/LSA.conf"
  local ngx="$RFS/opt/lsi/LSIStorageAuthority/server/conf/nginx.conf"
  [ -f "$conf" ] || { rv_err "缺少 $conf"; return 1; }
  [ -f "$ngx" ]  || { rv_err "缺少 $ngx"; return 1; }

  sed -i -E "s#^([[:space:]]*listening_port[[:space:]]*=[[:space:]]*).*#\1${back}#"        "$conf"
  sed -i -E "s#^([[:space:]]*client_listening_port[[:space:]]*=[[:space:]]*).*#\1${front}#" "$conf"
  sed -i -E "s#^([[:space:]]*listen[[:space:]]+)[0-9]+#\1${front}#"                        "$ngx"
  sed -i -E "s#^([[:space:]]*listen[[:space:]]+\[::\]:)[0-9]+#\1${front}#"                 "$ngx"
  sed -i -E "s#^([[:space:]]*fastcgi_pass[[:space:]]+)127\.0\.0\.1:[0-9]+#\1 127.0.0.1:${back}#" "$ngx"

  # 断言：改完必须能读回。静默失败的 sed 会表现为"改了端口还连不上"，极难排查。
  grep -qE "listening_port[[:space:]]*=[[:space:]]*${back}$"        "$conf" || { rv_err "注入 listening_port 失败"; return 1; }
  grep -qE "client_listening_port[[:space:]]*=[[:space:]]*${front}$" "$conf" || { rv_err "注入 client_listening_port 失败"; return 1; }
  return 0
}

rv_lsa_ensure_account() {
  grep -qE '^raidview:' "$RFS/etc/shadow" 2>/dev/null || rv_err "chroot 内缺少账号 raidview"
  return 0
}

# ---------- 登录账号与口令 ----------
# 账号名不再是固定常量：用户可以在「设置登录口令」页自己指定（默认 raidview）。
# 账号落在 chroot 内（LSA 用 OS 认证），名字记在 $VAR/config.json。
#
# 状态文件（$VAR/state/）：
#   shadow.<account>         口令哈希行（升级替换 rootfs 后重放用，非明文）
#   credential-setup-done    "已经拥有可用账号与口令"
#   setup-in-progress        防并发提交的锁

RV_DEFAULT_USER=raidview
RV_CONFIG_JSON='{}'

rv_state_dir()    { echo "$VAR/state"; }
rv_config_json()  { echo "$VAR/config.json"; }
rv_setup_marker() { echo "$(rv_state_dir)/credential-setup-done"; }
rv_setup_lock()   { echo "$(rv_state_dir)/setup-in-progress"; }
rv_shadow_file()  { echo "$(rv_state_dir)/shadow.$(rv_account_name)"; }

# 合法 Linux 用户名：小写字母或下划线开头，允许数字/连字符/下划线，≤32
rv_valid_account() {
  echo "$1" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$'
}

# 当前账号名：config.json 里记的，没有就用默认值
rv_account_name() {
  local f n=""
  f=$(rv_config_json)
  if [ -f "$f" ]; then
    n=$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(d.get("account") or "")
except Exception:
    print("")' "$f" 2>/dev/null)
  fi
  [ -n "$n" ] && echo "$n" || echo "$RV_DEFAULT_USER"
}

rv_set_account_name() {
  local name=$1 f
  f=$(rv_config_json)
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  python3 - "$f" "$name" <<'PYEOF' || return 1
import json, os, sys
path, name = sys.argv[1], sys.argv[2]
d = {}
try:
    d = json.load(open(path)) or {}
except Exception:
    d = {}
d["account"] = name
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
os.replace(tmp, path)
os.chmod(path, 0o600)
PYEOF
  return 0
}

rv_password_ready() { [ -f "$(rv_setup_marker)" ]; }

# 把已保存的哈希重放进 chroot（升级后 rootfs 被换掉时必需）
rv_lsa_apply_saved_password() {
  local user shadowf line
  user=$(rv_account_name)
  shadowf=$(rv_shadow_file)
  [ -f "$shadowf" ] || return 1
  [ -f "$RFS/etc/shadow" ] || { rv_err "chroot 内没有 /etc/shadow"; return 1; }
  grep -qE "^${user}:" "$RFS/etc/shadow" || { rv_err "chroot 内没有账号 ${user}"; return 1; }
  line=$(cat "$shadowf")
  python3 - "$RFS/etc/shadow" "$user" "$line" <<'PYEOF' 2>/dev/null || return 1
import sys
path, user, line = sys.argv[1], sys.argv[2], sys.argv[3].rstrip("\n")
src = open(path, encoding="utf-8", errors="surrogateescape").read().splitlines()
out = [line if l.startswith(user + ":") else l for l in src]
open(path, "w", encoding="utf-8", errors="surrogateescape").write("\n".join(out) + "\n")
PYEOF
  return 0
}

# 确保 chroot 内有这个账号（没有就建）；幂等
rv_lsa_ensure_account_named() {
  local user=$1
  rv_valid_account "$user" || { rv_err "账号名不合法：$user"; return 2; }
  if ! grep -qE "^${user}:" "$RFS/etc/passwd" 2>/dev/null; then
    # -M 不建家目录；shell 给 /bin/bash，LSA 的 PAM 认证需要可用 shell
    chroot "$RFS" useradd -M -s /bin/bash "$user" 2>/dev/null || {
      rv_err "在运行环境内创建账号 $user 失败"; return 1; }
    rv_say "已在运行环境内创建账号 $user"
  fi
  grep -qE "^${user}:" "$RFS/etc/shadow" || {
    # 极小概率：useradd 建了 passwd 但没有 shadow 行
    chroot "$RFS" useradd -M -s /bin/bash "$user" >/dev/null 2>&1 || true
  }
  return 0
}

# 把 LSA 的只读组改成这个账号（改前备份，格式断言）
rv_lsa_set_readonly_group() {
  local user=$1 conf="$RFS/opt/lsi/LSIStorageAuthority/conf/LSA.conf"
  [ -f "$conf" ] || { rv_err "缺少 LSA.conf"; return 1; }
  [ -f "$conf.raidview.bak" ] || cp -a "$conf" "$conf.raidview.bak" 2>/dev/null || true
  if grep -qE '^[[:space:]]*readonly_access_groups[[:space:]]*=' "$conf"; then
    sed -i -E "s#^([[:space:]]*readonly_access_groups[[:space:]]*=[[:space:]]*).*#\1${user}#" "$conf"
    # 断言：改完必须能读回，且仍然是一个 key = value 形式的行
    grep -qE "^[[:space:]]*readonly_access_groups[[:space:]]*=[[:space:]]*${user}$" "$conf" || {
      rv_err "写 readonly_access_groups 失败"; return 1; }
    rv_say "readonly_access_groups = $user"
  else
    rv_err "LSA.conf 里没有 readonly_access_groups，未修改"
    return 1
  fi
  return 0
}

# 设置账号 + 口令（一次调用完成全部动作）
#   用法: rv_lsa_set_password <account> <plaintext>
rv_lsa_set_password() {
  local user=$1 pw=$2 st
  st=$(rv_state_dir)
  mkdir -p "$st"; chmod 700 "$st" 2>/dev/null || true

  rv_valid_account "$user" || { rv_err "账号名不合法（需匹配 ^[a-z_][a-z0-9_-]{0,31}$）"; return 2; }
  [ -n "$pw" ] || { rv_err "口令为空"; return 2; }
  [ "${#pw}" -ge 8 ] || { rv_err "口令长度不足 8 位"; return 2; }
  [ -f "$RFS/etc/shadow" ] || { rv_err "chroot 内没有 /etc/shadow"; return 1; }

  rv_lsa_ensure_account_named "$user" || return 1

  # 明文只经 stdin 交给 chpasswd
  printf '%s:%s\n' "$user" "$pw" | chroot "$RFS" chpasswd 2>/dev/null || {
    rv_err "chpasswd 失败（运行环境内 passwd 包缺失？）"; return 1; }

  # 旧账号的 shadow 备份若存在且换了名字，清掉旧的
  local old; old=$(rv_account_name)
  rv_set_account_name "$user" || { rv_err "写入 config.json 失败"; return 1; }
  if [ -n "$old" ] && [ "$old" != "$user" ]; then
    rm -f "$(rv_state_dir)/shadow.$old" 2>/dev/null || true
  fi

  grep -E "^${user}:" "$RFS/etc/shadow" > "$(rv_state_dir)/shadow.${user}" 2>/dev/null
  chmod 600 "$(rv_state_dir)/shadow.${user}" 2>/dev/null || true

  rv_lsa_set_readonly_group "$user" || rv_say "警告: 只读组未更新（不影响登录）"

  : > "$(rv_setup_marker)"; chmod 600 "$(rv_setup_marker)" 2>/dev/null || true
  rm -f "$(rv_setup_lock)" 2>/dev/null || true
  rv_say "已设置账号 ${user} 的登录口令（不记录明文）"
  return 0
}

# 清除账号口令状态：让「设置登录口令」页面重新出现
rv_lsa_clear_password() {
  local user; user=$(rv_account_name)
  rm -f "$(rv_setup_marker)" "$(rv_setup_lock)" 2>/dev/null || true
  rm -f "$(rv_state_dir)/shadow.${user}" 2>/dev/null || true
  if grep -qE "^${user}:" "$RFS/etc/shadow" 2>/dev/null; then
    chroot "$RFS" passwd -l "$user" >/dev/null 2>&1 || true
  fi
}

# ---------- 日志上限 ----------
# 不依赖任何未文档化的 LSA 日志级别开关；这是硬保险。
rv_prune_logs() {
  local d="$RFS/opt/lsi/LSIStorageAuthority/logs" cap_mb=${1:-128}
  [ -d "$d" ] || return 0
  find "$d" -name 'lsa*.txt' -mtime +3 -delete 2>/dev/null || true
  local total
  total=$(du -sm "$d" 2>/dev/null | cut -f1); total=${total:-0}
  [ "$total" -le "$cap_mb" ] && return 0
  ls -1t "$d"/lsa*.txt 2>/dev/null | tail -n +2 | while read -r f; do
    rm -f "$f"
    total=$(du -sm "$d" 2>/dev/null | cut -f1); total=${total:-0}
    [ "$total" -le "$cap_mb" ] && break
  done
}

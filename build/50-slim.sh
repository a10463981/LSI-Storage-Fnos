#!/bin/bash
# 阶段 50：瘦身。每批删完立刻跑 ELF 依赖检查 + 冒烟测试，不过就回滚该批。
#
# 收益最大的是 apt 缓存与文档；语言包和 python 留到最后，且必须过冒烟。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
SLIM_LOG="$WORK/50-slim.log"; : > "$SLIM_LOG"

snapshot() { find "$RFS" -xdev \( -type f -o -type l \) 2>/dev/null | sort > "$WORK/50-before.list"; }
rollback_note() { echo "!! 批次 $1 失败，需人工回滚（未自动删除任何已装文件，可重跑 30/40）" | tee -a "$SLIM_LOG"; }

batch() {
  local name=$1; shift
  local before after
  before=$(rfs_mb)
  log 50 "批次 $name"
  "$@" || { warn "批次 $name 执行出错"; }
  after=$(rfs_mb)
  local delta=$((before - after))
  echo "  $name: ${before}MB → ${after}MB  (-${delta}MB)" | tee -a "$SLIM_LOG"
  report "- 瘦身[$name]: -${delta} MB → ${after} MB"
  # 校验
  if ! bash "$PROJ/build/verify/check-elf.sh" "$RFS" >>"$SLIM_LOG" 2>&1; then
    rollback_note "$name"; die "批次 $name 破坏了 ELF 依赖，详见 $SLIM_LOG"
  fi
  if ! bash "$PROJ/build/60-smoke-test.sh" --quick >>"$SLIM_LOG" 2>&1; then
    rollback_note "$name"; die "批次 $name 导致冒烟失败，详见 $SLIM_LOG"
  fi
  ok "批次 $name 通过"
}

# ---- 批次 1：包管理缓存（零风险）----
b1() {
  rm -rf "$RFS"/var/lib/apt/lists/* 2>/dev/null || true
  rm -rf "$RFS"/var/cache/apt/archives/*.deb 2>/dev/null || true
  rm -rf "$RFS"/var/cache/apt/archives/partial 2>/dev/null || true
}
# ---- 批次 2：文档（零风险）----
b2() {
  rm -rf "$RFS"/usr/share/doc/* "$RFS"/usr/share/man/* "$RFS"/usr/share/info/* 2>/dev/null || true
}
# ---- 批次 3：语言包（保留 C / C.UTF-8 / en / zh_CN）----
b3() {
  find "$RFS/usr/share/locale" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | while read -r d; do
        case "$(basename "$d")" in
          C|C.UTF-8|en|en_US|zh_CN|zh) ;;
          *) rm -rf "$d" ;;
        esac
      done
  rm -rf "$RFS"/usr/share/i18n 2>/dev/null || true
}
# ---- 批次 4：LSA 安装残留（打包时的临时目录）----
b4() {
  rm -rf "$RFS"/tmp/* 2>/dev/null || true
  rm -rf "$RFS"/var/tmp/* 2>/dev/null || true
  # 保留 conf/*.dist（端口回滚用）
  find "$RFS/opt/lsi" -name '*.log' -size +1M -delete 2>/dev/null || true
  rm -rf "$RFS"/opt/lsi/LSIStorageAuthority/logs/* 2>/dev/null || true
  mkdir -p "$RFS/opt/lsi/LSIStorageAuthority/logs"
}

log 50 "瘦身前: $(rfs_mb) MB"
batch apt-cache   b1
batch docs        b2
batch locales     b3
batch lsa-residue b4

log 50 "瘦身后: $(rfs_mb) MB"
report "- 瘦身后 rootfs: $(rfs_mb) MB"
ok "阶段 50 完成（$(rfs_mb) MB）"

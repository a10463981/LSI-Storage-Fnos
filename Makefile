# LSI-Storage-Fnos —— 内置 LSA 的 fnOS RAID 监控应用
#
#   make image      构建 rootfs 载荷（需要 root + 网络 + LSA 安装包）
#   make skeleton   构建骨架 rootfs（不含 LSA，仅用于验证平台链路）
#   make pkg        组装 fpk 源目录并调用 fnpack（产物落在 build/dist/）
#   make all        image + pkg
#   make clean

SHELL := /bin/bash
PROJ  := $(CURDIR)
WORK  := $(PROJ)/build/work
DIST  := $(PROJ)/build/dist

.PHONY: all image skeleton pkg clean check stage00 stage10 stage20 stage30 stage40 stage50 stage60 stage70 verify-manifest

all: image pkg

image: stage00 stage10 stage20 stage30 stage40 stage50 stage60 stage70
	@echo "== 载荷构建完成 =="
	@ls -lh $(WORK)/70/rootfs.tar.gz

stage00: ; @bash build/00-fetch.sh
stage10: ; @bash build/10-unpack-rootfs.sh
stage20: ; @bash build/20-apt-deps.sh
stage30: ; @bash build/30-install-lsa.sh
stage40: ; @bash build/40-patch.sh
stage50: ; @bash build/50-slim.sh
stage60: ; @bash build/60-smoke-test.sh --full
stage70: ; @bash build/70-package.sh

skeleton: ; @bash build/90-skeleton.sh

# fnpack 的产物落在**执行命令时的 cwd**，不是 -d 指定的目录，所以必须 cd 过去。
# 也不能用管道接 fnpack（`| head` 会把退出码变成 head 的 0），失败会被吞掉。
# 静态守卫：挂载/卸载写法检查。打包前必跑。
check:
	@bash build/verify/check-mounts.sh

pkg: check
	@bash build/80-pack.sh

verify-manifest:
	@echo "平台模板取自 fnpack create（已实测）。如需再确认："
	@echo "  fnpack create tmpl -t native && cat tmpl/manifest && cat tmpl/app/ui/config"

clean:
	@rm -rf $(WORK) $(DIST)
	@echo "已清理"

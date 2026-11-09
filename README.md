# 博通控制器管理（raidview）

> ## ⚠️ 非官方第三方集成包
>
> **本项目与 Broadcom Inc. 无隶属关系，未获其授权、赞助或背书。**
>
> - "Broadcom"、"LSI"、"MegaRAID"、"LSI Storage Authority (LSA)" 是 Broadcom Inc. 的商标或注册商标。
> - 本仓库**不包含**任何 Broadcom 专有二进制（LSA 的 deb、`/opt/lsi` 下的一切、Ubuntu rootfs 均不在仓库中，也不在任何 Release 资产中）。
> - 使用本项目前，你需要**自行**从 Broadcom 或你的服务器厂商处获取 LSA 安装包，并遵守你与 Broadcom 之间的许可条款。
> - 图标中的 Broadcom 标识仅用于指明本应用所管理硬件的厂商；商标权归 Broadcom Inc. 所有。
>
> 详见 [LICENSE](LICENSE) 中 "NOTE ON THIRD-PARTY SOFTWARE" 一节。

把 Broadcom LSI Storage Authority（LSA）的完整运行环境（Ubuntu 24.04 chroot）打进一个 fnOS 应用包，
装完点开就是图形化的 MegaRAID 管理界面。**不需要 storcli，不需要在别处另装 LSA。**

当前版本 **0.2.3**，已在真实 fnOS（Debian 12 系，`.15`）上跑通：安装 → 启动 → 预热门 → 登录 → 停止零残留。

---

## 这个项目能做什么、不能做什么

| | |
|---|---|
| ✅ 支持 | **fnOS 裸机**且 RAID 卡在本机；**PVE/ESXi 整卡直通给 fnOS** |
| ❌ 不支持 | fnOS 跑在虚拟机里、卡在宿主机上且未直通 —— 这种情况下 fnOS 内核看不到卡，chroot 里的 LSA 同样看不到 |
| ❌ 不支持 | storcli 作为数据源（本项目的立场是：普通用户不会用命令行工具，只做图形界面） |
| ⚠️ 未验证 | 有卡环境下的全部功能（控制器/VD/PD/重建/电池/事件）、`readonly_access_groups` 的真实拦截效果、`backup.exclude` 是否被平台执行 |

**本应用只读**：不创建/删除阵列、不改缓存策略、不刷固件。但请注意 —— 它内置的是 Broadcom 的
LSA 管理控制台，**LSA 本身具备写能力**；本项目的"只读"是指我们不提供写入口，不等于 LSA 被改造成只读。

---

## 构建前提（重要）

**本仓库不含 LSA 安装包，也无法提供。** 构建前你需要自己准备好：

```
008.018.012.000_MR_7.38_LSA_Linux.zip        # 约 166 MB
```

获取渠道（都需要你自己操作，任选其一）：

- 你的服务器厂商支持页（Dell / HPE / 浪潮 / 华为…）搜 "LSI Storage Authority"，通常不需要注册
- Broadcom 支持站 → MegaRAID 9460-8i 产品页 → Management Software（需要注册账号）

拿到后放到 `build/vendor/`，或用环境变量指定：

```bash
mkdir -p build/vendor && cp /path/to/008.018.012.000_MR_7.38_LSA_Linux.zip build/vendor/
# 或
LSA_ZIP=/path/to/xxx.zip make image
```

> 没有这个包，`make image` 会在第一阶段明确报错退出，不会产出半成品。

---

## 构建与安装

```bash
make image     # 00→70：拉 rootfs → 装依赖 → 装 LSA → 打补丁 → 瘦身 → 冒烟 → 打载荷
make pkg       # 组装 + fnpack
# 产物：build/dist/raidview.fpk
```

需要：x86_64 Linux、root、能访问清华 TUNA 镜像、`fnpack`（fnOS 官方打包工具）。

```bash
# 装到 fnOS
sudo appcenter-cli install-fpk raidview.fpk
sudo /var/apps/raidview/cmd/main start
curl -s http://127.0.0.1:2463/status
```

首次打开会要求设置**登录账号与口令**（默认账号 `raidview`，可自定义）。

---

## 目录结构

```
build/     七阶段构建流水线 + 两个静态守卫（ELF 依赖 / 挂载安全）
pkg/       fpk 源：manifest、9 个生命周期钩子、运行时、web、安装向导
dev/       不装包直接验证运行环境的脚本
docs/      有卡环境验证清单
```

---

## 许可证

代码部分 **MIT**（见 [LICENSE](LICENSE)）。
LSA、Ubuntu rootfs、Broadcom 商标**不在** MIT 覆盖范围内，权利归各自所有者。

---

# 以下为实现细节与踩坑记录

把 Broadcom LSI Storage Authority 的完整运行环境（Ubuntu 24.04 chroot）打进 fpk，
装到 fnOS 上点开就能看到图形界面。**不依赖 storcli，不在别处另装 LSA，装完即用。**

**当前状态：已在真实 fnOS（192.168.100.15 / text-nas）上跑通**
安装 → 启动 → 预热门 READY → 登录页 → 停止 → 零残留，连续 5 轮启停无残留；卸载清理干净。

- 有卡机器怎么验：见 [`docs/有卡环境验证清单.md`](docs/有卡环境验证清单.md)
- 平台字段的实测/推测标注：见 [`pkg/manifest.FIELDS.md`](pkg/manifest.FIELDS.md)

---

## 0. 安全红线：挂载与卸载

**构建脚本里一次显式 `umount` 都不许写。**

早期版本用 `umount -R "$RFS/dev"` 清理 chroot 的挂载，传播链没完全隔离时
把**宿主的 `/dev/pts`** 一起卸掉了，发生过两次（和之前误删 `/dev` 是同一类事故）。

现在的做法是结构性的：每个需要挂载的阶段脚本开头调用 `rfs_enter_ns`，
把自己 re-exec 进 `unshare -m --propagation private`，
命名空间销毁时**内核自动卸载全部挂载**——忘了写清理也不会泄漏。

```bash
make check      # 静态守卫：裸 umount -R / 对宿主路径 umount / 无命名空间的 rbind 一律报错
```
`make pkg` 会先跑这个守卫，不通过就拒绝打包。

---

## 1. 首次使用：设置登录口令

**不再有"随机生成、只显示一次"那种设计**——那种做法把关键信息放在用户最容易错过的时刻，错过之后就既没有口令也没有入口。

### 正常流程（两条路，任选其一都能得到可用口令）

**路径 A · 安装时设（推荐）**
在 fnOS 应用中心装本应用时，会弹出一个「登录口令」步骤（fnOS 原生安装向导，文件是 `pkg/wizard/install`）。
填一个 ≥8 位的口令，装完直接用。

**路径 B · 安装时留空 → 首次打开时设**
向导里留空，装完点开应用，第一屏就是「设置登录口令」：

```
┌─────────────────────────────────────────────┐
│ 设置登录口令                                  │
│ 首次使用，先给管理界面设一个口令                 │
│                                             │
│ 这个账号只用于登录本应用内置的 RAID 管理界面，     │
│ 与你的 fnOS 账号无关。                         │
│                                             │
│ 登录账号名  [raidview        ]                  │
│ 小写字母/下划线开头，≤32 位，与 fnOS 账号无关      │
│                                             │
│ 口令（至少 8 位）        [………………] [显示]      │
│ 再输一次                [………………] [显示]      │
│                                             │
│ 或者用系统生成的口令                            │
│   Xk7mQ2pR9vLtQw3e                          │
│   [生成一个] [复制] [填入上面]                  │
│                                             │
│ ☑ 我已记下这个口令（后面登录要用）               │
│ [保存并继续]                                  │
└─────────────────────────────────────────────┘
```

- 两次输入必须一致，**服务端会独立再校验一遍**（不信任前端）
- 「生成一个」在**浏览器本地**用 `crypto.getRandomValues` 生成 16 位，不经服务器
- 必须勾选「我已记下这个口令」才允许提交
- 账号名**可自定义**（默认 `raidview`，规则 `^[a-z_][a-z0-9_-]{0,31}$`；应用内部账号，与 fnOS 账号无关）
- 提交后在 chroot 内建号（不存在时 `useradd`）并 `chpasswd` 设口令（明文只走 stdin），同步 `readonly_access_groups`，然后进入正常流程
- **设置完成后不会再出现**：落标记 `$VAR/state/credential-setup-done`

### 账号名的落地方式

| 环节 | 行为 |
|---|---|
| 提交 | `cmd/main set-password <account>`（账号走 argv 不敏感；口令走 stdin） |
| 建号 | 在 **chroot 内** `useradd -M -s /bin/bash <account>`，不碰宿主 fnOS 的用户库 |
| 只读组 | 同步把 `LSA.conf` 的 `readonly_access_groups` 改成该账号（改前备份 `LSA.conf.raidview.bak`，改后有格式断言） |
| 记录 | `$VAR/config.json` 记 `{"account": "..."}`（0600，不含口令） |
| 升级 | `credential-setup-done` 已存在时**不动**既有账号，只在全新安装/重置时生效 |

实测（`.15`）：自定义 `myraidadmin` → chroot 内建号成功（uid 2001）、口令哈希可复算、
`readonly_access_groups = myraidadmin`；再改回 `raidview` 同样生效；`Bad Name`/`123abc`/`UPPER`/`-x` 全部 400。

### 忘记口令

```bash
sudo /var/apps/raidview/cmd/reset-password
```
它会清掉口令状态并把账号重新锁上；重新打开 `http://<本机IP>:2463/` 就会**再次进入设置页**，由你自己设一个新的（不是再发一个随机串）。

### 安全约束（代码级）

| 约束 | 实现 |
|---|---|
| 口令不进日志 | 所有日志只记"已设置/成功/失败"，从不记明文；实测 `grep` 全量日志 0 命中 |
| 口令不进状态接口 | `/status` 已删除 `initial_password` 字段；页面上也不再展示 |
| 口令不进 argv | `cmd/main set-password` 从 **stdin** 读取；`chpasswd` 也从管道喂 |
| 口令只存哈希 | `$VAR/state/shadow.<账号>`（0600）存 shadow 行，不是明文；升级替换 rootfs 后重放它 |
| 防重复提交 | `$VAR/state/setup-in-progress` 用 `O_EXCL` 加锁；已设置过再 POST 直接 409 |
| 服务端独立校验 | 长度 ≥8、两次一致、长度上限 128、拒绝换行、要求 ack |

### 实测记录（`.15`，全新安装模拟）

```
[1] need_setup=true      / = 设置登录口令        ← 装完第一屏就是它
[2] POST /setup → 303    need_setup=false       ← 设完立即进入正常流程
    账号: raidview P ...                        ← P = 口令已生效
[3] 停止再启动            / = RAID 监控           ← 重启后不再出现设置页
[4] reset-password       / = 设置登录口令        ← 账号状态 L（已锁）
[5] 重设 → 303           need_setup=false       ← 可反复重置
    明文泄漏检查: 0 处
```

**登录能力验证**（LSA 用 OS 账号认证：`ldap_mode = 0`、`bypass_authentication = 0`）：

```
shadow 哈希前缀: $y$j9T$22aKm1iOwQz/Bz...     ← yescrypt
Second-Pass-88   -> MATCH ✓                   ← 刚设的口令可复算出同一哈希
MyRaid-2026      -> no                        ← 上一次的口令已失效
definitely-wrong -> no
```

哈希能复算 = PAM 能通过 = LSA 登录页能登进去。

---

## 2. 在真机上验证过的结果

| 项 | 结果 |
|---|---|
| `fnpack build` | 通过，产物 `raidview.fpk` = **103 MB** |
| `appcenter-cli install-fpk` | 通过，rootfs 展开 254 MB |
| `cmd/main start` | rc=0，门户 :2463 立即监听 |
| 冷启动到 READY | **18–25 秒**（无卡机器） |
| `cmd/main status` | running / rc=0 |
| LSA root API | HTTP 200 |
| LSA `/servers` | `count: 2`，含 displayId / hostname / health |
| 门户 `/` | 正常渲染；`/enter` → 302 到 LSA |
| 首启口令 | 生成 → 展示 → `/ack` 删除，chroot 内账号状态 `P`（可登录） |
| `cmd/reset-password` | 通过，重设后门户再次展示 |
| `cmd/main stop` | rc=0，进程/挂载/端口三项归零 |
| 5 轮启停 | 5/5 全部 `start=0 stop=0 gate=200 残留(0/0/0)` |
| `appcenter-cli uninstall` | 通过，`/var/apps/raidview` **与** `@appdata/raidview`(268MB) 全部清除 |
| 升级钩子（直接驱动） | 坏载荷 → 回滚成功、rootfs 仍可用；好载荷 → 替换成功、回滚点清理 |
| `appcenter-cli` 升级 | **无 upgrade 命令**；`install-fpk` 对已装应用是 no-op（同版本/高版本都一样） |
| CPU 预检 | 正确识别 `Common KVM processor`（无 AVX）并在安装期通过 |
| 挂载安全 | 4 个阶段脚本改为命名空间内挂载；跑完后宿主 `/dev/pts` 完好、rootfs 零残留 |
| 运行时内存 | slpd 1MB + nginx 5MB + LSA 24MB ≈ **30 MB** |
| 磁盘占用 | `@appcenter` 104MB + `@appdata` 269MB |

---

## 3. 三个必须知道的实测结论

### 3.1 「灰屏」的真正根因（此前一直没定位到）

LSA 的 `/etc/init.d/LsiSASH` 第 46 行，在 **slpd 未运行**的分支里执行：

```sh
export LD_LIBRARY_PATH=/opt/lsi/LSA/libs2
```

它把调用方传入的路径**整体覆盖**掉。后续第 84/85 行只做 prepend，
base 里已经不含 `/opt/lsi/LSA/libs` —— 而 LSA 自带的 OpenSSL 3.2 就在那里。
于是 LSA 进程用系统 OpenSSL 3.0.13，`libcurl.so.4` 报
`version 'OPENSSL_3.2.0' not found`，`libgateway.so` 加载失败，
网关管理器为空 → root API 永远返回 **400** → 前端灰屏。

**这解释了此前"有时能起、有时起不来"的全部现象**：slpd 恰好在跑时不走该分支，
路径没被覆盖，就能起来；slpd 不在时必挂。也解释了"不要 pkill slpd"这条经验规则的来历。

**修法**：构建期把第 46 行改成 `/opt/lsi/LSA/libs:/opt/lsi/LSA/libs2`（补丁 3c）。
修完后 **无卡机器也能在 12–25 秒内到 200**。

### 3.2 基线选择的第一约束是 CPU ISA，不是 glibc

三套 `gcc_*` 基线的实测结果（同一台真机）：

| 基线 | glibc 底线 | 结果 |
|---|---|---|
| `gcc_14.2.x` | 2.39 | ❌ `nginx: CPU ISA level is lower than required` |
| `gcc_11.2.x` | 2.34 | ❌ 同样 ISA 报错 |
| **`gcc_8.3.x`** | 2.28 | ✅ **可运行**（需补 `libldap-2.4.so.2` 兼容链接） |

`.15` 的 CPU 是 `Common KVM processor`，**没有 AVX/AVX2/SSE4.2**。
前两套基线编译出的二进制要求更高 ISA，直接拒绝启动。

`gcc_8.3.x` 的代价是它的 LSA 二进制链接 `libldap-2.4.so.2`（SLES 的 soname），
而 Ubuntu 24.04 只有 `libldap.so.2`（OpenLDAP 2.6）。因为本应用用 OS 认证
（`ldap_mode = 0`），LDAP 通路不会被执行，用符号链接满足加载期解析即可（补丁 3d）。

> **这是整套方案里最关键的一次踩坑**：只看 glibc 会选错基线，装到虚拟机上必挂。

### 3.3 无卡机器能到 READY，不是长期 400

修掉 2.1 之后，`.15`（无 RAID 卡）上 LSA 正常就绪，`/servers` 返回
`count: 2`、`health` 字段齐全，只是控制器列表为空。

**所以预热门不需要"无卡超时兜底"**：无卡与有卡走同一条就绪路径，
差别只在 LSA 界面里看得到 0 个控制器。门户顶部仍会常驻一条黄色提示说明原因。

---

## 4. 目录树

```
raidview/
├── Makefile                   image / skeleton / pkg / clean
├── build/
│   ├── lib.sh                 版本钉（rootfs SHA256、LSA 基线）、chroot 封装、构建报告
│   ├── 00-fetch.sh            TUNA 下载 rootfs + SHA256 硬校验；定位 LSA zip
│   ├── 10-unpack-rootfs.sh    解压；写 HTTP apt 源（base 无 ca-certificates）
│   ├── 20-apt-deps.sh         6 个依赖 + passwd（chpasswd）+ psmisc（killall）
│   ├── 30-install-lsa.sh      解双层 zip → 选基线 → dpkg -i 三个 deb
│   ├── 40-patch.sh            六类补丁，见 §5
│   ├── 50-slim.sh             4 批瘦身，每批必须过 ELF 检查 + 冒烟
│   ├── 60-smoke-test.sh       --quick 等端口 / --full 等 API 200
│   ├── 70-package.sh          打 rootfs.tar.gz，体积断言 ≤400MB
│   ├── 80-pack.sh             组装 pkg/ 并调 fnpack（产物落 cwd）
│   └── verify/check-elf.sh    扫 ELF 只看 "not found"
├── dev/run-local.sh           不装 fpk 直接验证运行环境
└── pkg/
    ├── manifest               INI 格式，见 §6
    ├── manifest.FIELDS.md     每个字段的实测/推测标注
    ├── ICON.PNG ICON_256.PNG
    ├── config/{privilege,resource}
    ├── cmd/                   main + 8 个钩子 + reset-password + lib/
    └── app/                   → 安装到 target/
        ├── ui/{config,images/}
        ├── runtime/{launch.sh,gate.py,web/index.html}
        ├── server/ www/
        └── rootfs.tar.gz      构建产物（不入库）
```

---

## 5. 构建期补丁清单（`40-patch.sh`）

| # | 补丁 | 为什么 |
|---|---|---|
| 1 | `libcrypt.so.2 → libcrypt.so.1` | LSA 要 `.so.2` soname，Ubuntu 只有 `.so.1` |
| 2 | `libslp.so.1 → libslp.so.1.0.0` | 缺 soname，插件加载失败 |
| 3 | `server/html/ui/js → ../js` | 否则前端静态资源 404 → 灰屏 |
| **3b** | `mkdir /usr/local/var/log` | init 脚本把 slpd 日志写这里，目录不存在 → slpd 起不来 |
| **3c** | 改 init 脚本第 46 行的 `LD_LIBRARY_PATH` | **灰屏根因**，见 §3.1 |
| **3d** | `libldap-2.4.so.2 → libldap.so.2` | gcc_8.3.x 基线需要，见 §3.2 |
| 4 | 8 处端口占位符替换 | 绕过交互式安装器的代价 |
| 5 | `log_level` 64 → 4 | 64 = FUNCTION_ENTRY，每行都落盘；4 = ERROR |
| 6 | 预置 `raidview` 账号（锁定） | 仅作为默认值；用户在设置页改成别的名字时会动态 `useradd` |

---

## 6. manifest（INI 格式，实测）

```ini
appname               = raidview
version               = 0.1.3
display_name          = MegaRAID 监控
desc                  = ...
platform              = x86
source                = thirdparty
maintainer            = raidview
distributor           = raidview
desktop_uidir         = ui
desktop_applaunchname = raidview.Application
service_port          = 2463
checkport             = false
os_min_version        = 1.2.0401
changelog             = ...
```

- **不写** `checksum`（fnpack 自动注入）
- **不写** `install_type`（写了会装到系统分区）
- `desktop_applaunchname` 必须与 `app/ui/config` 的 `.url` 键**逐字符相同**
- `app/ui/config` 用 `type: url` + `protocol: http` + `url: /`，端口由 `service_port` 提供
- **必须有 `ICON.PNG` 与 `ICON_256.PNG`**（fnpack 会校验，缺了报错）
- **不能有 `wizard/install/` 目录**（实测报 `File "install" is not valid due to JSON format`）

---

## 7. 构建与部署

```bash
# LSA 包（专有，不入库）
mkdir -p build/vendor && cp 008.018.012.000_MR_7.38_LSA_Linux.zip build/vendor/

make image     # 00→70
make pkg       # 组装 + fnpack，产物 build/dist/raidview.fpk
```

| 阶段 | 实测耗时 |
|---|---|
| 00–30 | 约 6 分钟（下载 29MB + apt + 解 165MB zip + dpkg） |
| 40 | < 10 秒 |
| 50 slim | 约 6 分钟（4 批 × ELF 扫描 + 冒烟） |
| 60 smoke | 6–30 秒（API 6 秒就绪） |
| 70 + 80 | 约 3 分钟 |

**实测体积**：rootfs 159 MB → 载荷 92 MB → **fpk 103 MB**（远低于 400 MB 上限）。

部署：

```bash
scp build/dist/raidview.fpk admin@<host>:/tmp/
ssh admin@<host>
sudo appcenter-cli install-fpk /tmp/raidview.fpk
sudo /var/apps/raidview/cmd/main start
curl -s http://127.0.0.1:2463/status
```

---

## 8. 运行时设计要点

| 机制 | 说明 |
|---|---|
| `unshare -m --propagation private` | 全部挂载在独立 mount 命名空间内，命名空间销毁自动卸载 |
| PID1 常驻 + `stop.flag` | chroot 内 slpd/nginx/LSA 都会 daemonize，用常驻 shell 作锚点，收到标记后调 `init.d stop` |
| `/proc/PID/root` 判归属 | chroot 后进程 cmdline 不含宿主路径，`pgrep -f` 必然失效 |
| `--make-rslave` 容错 | `.15` 上它会返回 EINVAL，加上 `set -e` 会直接中止启动，必须 `|| true` |
| 预热门 | 用 LSA 前端同一个判据（root API）探测；就绪前不显示错误，只显示进度 |
| 日志上限 | 运行期裁剪 `lsa*.txt`，128MB / 3 天，不依赖未文档化的开关 |

---

### 8.1 从面板打开 vs 直接访问端口（0.1.9 修复）

**症状**：浏览器直接输入 `http://<nas-ip>:2463` 能用；点桌面/面板图标白屏。

**根因**（实测，不是猜）：fnOS 面板**不是**把 `service_port` 直接开个新标签页，而是
**用它自己的 nginx 在 `/app/<name>` 上反代到应用目录里的 unix socket**。

证据：

```
# 面板 nginx 把 /app/ 交给 trim_http_cgi
/usr/trim/nginx/conf/conf.d/trim_http_cgi.conf:
    location /app/ { proxy_pass http://unix:/var/run/trim_http_cgi.socket:; }

# 正常工作的第三方应用，target/ 下都有一个 600 的 unix socket
$ ls -l /var/apps/mail-archiver-fnos/target/app.sock
srw------- mail-archiver-fnos mail-archiver-fnos
$ curl --unix-socket …/app.sock http://localhost/     → HTTP 302   ← 应用在 socket 上应答

# 它们的 ui/config 是 iframe + gateway
{ "type": "iframe", "protocol": "", "gatewayPrefix": "/app/<name>",
  "gatewaySocket": "app.sock", "port": "", "url": "/app/<name>" }
```

我们 0.1.8 之前写的是 `type: url` + `protocol: http` + `url: "/"`。在 fnOS 的语义里
**`url` 是面板自己域名下的路径**（`trim.media` 的 `/v` 就是被 nginx 的 `location /v` 接走的），
所以 `url: "/"` 等于让面板打开它自己的根路径 —— 不是我们的应用。

**0.1.9 的改法**（与 `mail-archiver` / `rustfs` 同款）：

| 改动 | 内容 |
|---|---|
| `app/ui/config` | 改成 `type: iframe` + `gatewayPrefix: /app/raidview` + `gatewaySocket: app.sock` + `url: /app/raidview` |
| `gate.py` | 额外监听 unix socket `$TRIM_APPDEST/app.sock`（`socketserver.ThreadingUnixStreamServer`，mode 600） |
| `gate.py` | 路径前缀处理：经面板进来时路径是 `/app/raidview/...`，先剥前缀再路由；`/app/raidview` 无尾斜杠时 302 补斜杠（否则相对链接解析错） |
| 页面 | 所有链接/`fetch` 改成**相对路径**（`status`、`enter`、`setup`），这样直连 `/` 和经面板 `/app/raidview/` 都能正确解析 |
| 端口 | `service_port = 2463` 保留，**直连端口照旧可用** |

**实测**：

```
$ ls -l /vol1/@appcenter/raidview/app.sock
srw------- 1 root root 0
$ curl --unix-socket /vol1/@appcenter/raidview/app.sock http://localhost/   → HTTP 200   ← 我们自己的页面
$ curl http://127.0.0.1:5666/app/raidview/                                  → HTTP 200 「invalid token」
$ curl http://127.0.0.1:5666/app/mail-archiver-fnos/                        → HTTP 200 「invalid token」  ← 对照，同款响应
$ curl http://127.0.0.1:2463/                                               → HTTP 200   ← 直连仍然可用
```

`invalid token` 是面板 broker 的**鉴权门**（在解析应用之前就返回，`/app/nonexistent/` 也是同一句），
所以 curl 拿不到真实页面 —— 这条只能由浏览器点一次来最终确认。

**0.2.0/0.2.1 追加修复：「not found」其实是应用自己吐的**

现象：0.1.9 装好后从面板点是 **"not found"**（不是白屏）。

定位方法：把每一层都打一遍，看谁会说 "not found"。

```
$ curl -s -i --unix-socket …/app.sock http://localhost/app/raidview/ | head -1
HTTP/1.0 404 Not Found
$ curl -s --unix-socket …/app.sock http://localhost/app/raidview/ | tail -1
not found                      ← 和用户看到的字符串一模一样
```

**根因**：`install_callback` 运行在平台的**安装暂存目录**里
（`/vol1/appcenter-downloads/raidview-0.2.1-tpk/`），那一刻
`basename(dirname(cmd))` 得到的应用名是 `raidview-0.2.1-tpk`，于是
`GATE_PREFIX` 被算成 `/app/raidview-0.2.1-tpk`。面板转发过来的是 `/app/raidview/`，
前缀对不上 → 落到路由的 else 分支 → 我们自己的 404，正文就是 `not found`。

**三层修复**：

| 层 | 修法 |
|---|---|
| 应用名来源 | 不再用目录名，改从 `manifest` 的 `appname` 读（暂存目录里的 manifest 同样是正确值） |
| 前缀解析 | `strip_prefix` 除配置值外，**兜底剥掉任意 `/app/<某个名字>`**；`/app/<name>` 无尾斜杠统一 302 补斜杠 |
| 启动自愈 | `cmd/main start` 校验在跑的门户的 `GATE_PREFIX`，与实际应用名不符就重启它；`install_callback` 优先用 `/var/apps/<appname>/cmd/main` 启动，避免把暂存路径带进运行期 |
| 附带 | `preflight` 的端口占用判定放宽：pidfile 丢失时按进程环境里的 `RUN` 反查，不再误判"被别的程序占用" |

**实测（完整模拟用户：卸载 → 安装 → 不碰任何命令 → 等 40 秒）**：

```
gate 前缀: GATE_PREFIX=/app/raidview          ← 正确
socket   : srw------- root root
面板路径 : :5666/app/raidview/        → 200
          :5666/app/raidview/status   → 200
直连     : :2463/                     → 200
socket   : /app/raidview/  → 200   /app/raidview/status → 200
```

> 注意：未登录的 curl 访问面板路径仍会看到 `invalid token`（面板 broker 的鉴权门，
> 对照应用同样如此）。浏览器带着会话打开时，broker 会正常转发到我们的 socket ——
> 用户之前看到的 `not found` 正是**穿过鉴权门之后**由我们返回的 404，反证转发链路本身是通的。

**取舍说明**：如果把面板做成 HTTPS 而应用仍是 HTTP，iframe 里的 `location.href` 跳到
`http://…:2464/` 会被浏览器的混合内容策略拦掉。届时只有两条路：给 LSA 前端上 TLS，
或者改成新标签页打开。当前面板是 **HTTP（:5666 实测）**，不受影响。

### 8.2 fnOS 网关身份识别（SSO）调查结论

**结论先说：机制存在且干净，但本应用默认不启用自动登录。** 理由在最后一节。

#### 平台确实会把 fnOS 身份注入给应用

`trim_http_cgi`（面板 broker，Go 写的，`/usr/trim/bin/trim_http_cgi`）里同时存在这些字符串：

```
X-Trim-User
X-Trim-Username
X-Trim-Isadmin
invalid token
/var/run/trim_http_cgi.socket
/var/run/trim_sac.socket          ← 鉴权服务（trim_sac）的 socket
```

配合另两个工具可以确认链路：

```bash
$ ls /usr/trim/bin/ | grep -iE 'token|sac'
check_token        # 用法: check_token [token]
trim_sac           # 鉴权服务
libntoken.so       # 导出 tokensrv_connect / tokensrv_query1 / tokensrv_query2

# check_token 里的提示串：
#   usage: check_token [token]
#   token string must be 44 bytes base64-encoded.
#   [tokensrv_query1] uid:%u, is_admin:%ld
#   [tokensrv_query2] uid:%u, is_admin:%ld, username:%s
```

也就是说：**token（44 字节 base64）→ 本地服务 → uid / username / is_admin**，
broker 拿到之后把 `X-Trim-Username`、`X-Trim-Isadmin` 这些**HTTP 头**注入到转发给应用的请求里。
`mail-archiver-fnos` 的描述里那句「从桌面图标打开即免二次登录」，用的就是这套。

> 未取到的一环：没能在运行时**抓包看到 broker 实际注入的头**
> （无有效 fnOS 会话 token，broker 在转发前就返回 `invalid token`；
> 未登录 curl 拿不到那三个头）。上面的结论来自二进制字符串 + `check_token` 的用法，
> 属**强证据但非运行时抓包**。

#### 为什么本应用不默认开

要"打开即登录 LSA"，gate 必须拿 fnOS 身份后**替用户登录 LSA**。而 LSA 是 OS 认证，
登录需要**明文的账号口令**——我们现在只存 shadow 哈希（不可逆），拿不出来。
所以只能二选一：

| 方案 | 代价 |
|---|---|
| **存可逆口令**（加密保存，服务端代登录） | 等于把口令变成"可还原的"，安全性下降一个档次；且要维护 LSA 会话 cookie 的刷新 |
| **`bypass_authentication=1`** | LSA 面板变成**任何能访问 2464 的人都能进**，而它有删盘/刷固件能力。不可接受 |

更根本的问题：**LSA 不是只读界面。** SSO 意味着「任何能进 fnOS 面板的人都能进 RAID 管理界面」。
我们写了 `readonly_access_groups`，但这个只读组**是否真能拦住写操作，至今未验证**（要真卡 + 浏览器）。
在它被验证之前，自动登录等于把阵列管理权交给所有面板用户。

#### 因此

- **默认关闭**，不提供开关（避免"开了但没人验证过只读"的假安全）。
- 已经做了一件低风险的事：面板入口（`/app/raidview/*`）现在能正常工作，用户点图标后
  看到的是设置页/预热页，登录 LSA 仍需输入一次口令（浏览器可记住）。
- 若将来要做，实现路径与前置条件写在这里：① 真卡环境验证 `readonly_access_groups` 确实拦住写操作；
  ② gate 读取 `X-Trim-Username`/`X-Trim-Isadmin` 做身份判定；③ 口令改为可逆存储并加会话代理；
  ④ 默认仍只对 `X-Trim-Isadmin: 1` 的用户放行，且直连端口仍要求口令。

---

## 9. 已知限制与未验证项

| # | 项 | 状态与说明 |
|---|---|---|
| 1 | **平台侧升级无法触发** | `appcenter-cli` 没有 upgrade 命令；`install-fpk` 对已装应用是 **no-op**（实测同版本、更高版本都跳过）。升级只能走 App Center UI 的更新流程。**我们的 `upgrade_*` 钩子逻辑已用"直接驱动"的方式验证过（含失败回滚）**，但"平台是否按顺序调用"仍未验证 |
| 2 | ~~卸载残留 `@appdata`~~ | ✅ 已修：`uninstall_callback` 主动清理（带 basename 安全校验）。实测 268MB 全部释放，`/var/apps` 与 `@appdata` 均清除 |
| 3 | ~~构建脚本误卸宿主 `/dev/pts`~~ | ✅ 已修：4 个阶段脚本改为 `unshare -m --propagation private` 内挂载，脚本里零显式 umount；`make check` 静态守卫拦截裸 `umount -R` |
| 4 | **有卡环境完全没验证** | 只有无卡机器。控制器/VD/PD 枚举、重建进度、电池、事件日志都没在真卡上看过。清单见 `docs/有卡环境验证清单.md` |
| 5 | **`readonly_access_groups` 未验证** | 该键确实被 `libutility.so` 引用（是真特性），但"只读是否拦住写操作"没验证过。**不要把它当安全保证**；验证方法见有卡清单 §12 |
| 6 | **`backup.exclude` 未验证** | 配置已写入并随包安装，但平台是否照做没验证（要做一次真实备份才能确认）。若未生效，每次备份会多带约 372MB |
| 7 | LSA 前端是明文 HTTP | 登录口令过局域网明文。是否支持 HTTPS 未测 |
| 8 | 无卡时只有黄色提示 | LSA 界面里控制器列表为空（正确行为）；未做专门的"无卡视图" |
| 9 | `os_min_version = 1.2.0401` | 抄自已装应用，未在更低版本验证 |
| 10 | `dev/run-local.sh` | 路径已改到 `pkg/app/runtime`、并去掉 umount；未在真机重跑（仅开发用） |

---

## 10. 关键教训（给下一个人）

1. **基线别只看 glibc**。CPU ISA 是更硬的约束，虚拟机常被配成 `qemu64`，没有 AVX。
2. **厂商 init 脚本会改环境变量**。启动前 `cat /proc/PID/environ` 看真实值，别信自己传的。
3. **`install_init` 在 app.tgz 解包之前运行**。任何依赖 `target/` 的检查都必须放到 `install_callback`。
4. **`cmd/main` 非零退出会被平台当成安装失败**。只要 supervisor 起来了就返回 0。
5. **`fnpack build` 的产物落在 cwd**，且不能用管道接它（退出码会被吞）。

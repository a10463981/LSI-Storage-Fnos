# 博通控制器管理（raidview）0.2.5

> **非官方第三方集成包**，与 Broadcom Inc. 无隶属关系，未获其授权或背书。
> Broadcom、LSI、MegaRAID、LSI Storage Authority 是 Broadcom Inc. 的商标或注册商标。
>
> ⚠️ **本 fpk 内含 Broadcom LSA 的专有二进制**（LSA deb、`/opt/lsi` 全部组件、Ubuntu rootfs），
> 仅面向个人使用场景分发，**存在被要求下架的可能**。
> 源码仓库不含任何 Broadcom 二进制；你也可以自备 LSA 包自行构建（见文末）。

---

## 安装

```bash
# 传到 fnOS 上
sudo appcenter-cli install-fpk raidview-0.2.5.fpk
sudo /var/apps/raidview/cmd/main start
```

也可以走 fnOS 应用中心的「手动安装 fpk」。

### 安装前提

| 项 | 要求 |
|---|---|
| 系统 | fnOS（x86_64），已在 1.2.x 验证 |
| CPU | 无需 AVX/AVX2/SSE4.2（gcc 8.3.x 基线，兼容虚拟 CPU） |
| 权限 | 应用以 **root** 运行 |
| 磁盘 | 约 **400 MB**（@appcenter 67MB + @appdata 172MB + 解包余量） |
| 内存 | 运行期约 **30 MB** |
| 硬件 | 需要 **MegaRAID 卡**且本机内核可见。**没卡也能装能开**，界面会提示"未检测到控制器" |
| 端口 | 2463 门户 / 2464 LSA 前端 / 41000 内部 / 427 SLP |

**不支持**：fnOS 在虚拟机内、RAID 卡在宿主机且未直通。

### 首次使用（设置账号与口令）

装完点开应用，**第一屏就是「设置登录口令」**：

1. 账号名（默认 `raidview`，可自定义；小写字母或下划线开头，≤32 位）
2. 口令（≥8 位，两次一致）
3. 勾选「我已记下这个口令」→ 提交

提交后是**完成页，上面用大字写着你的账号名** —— 登录 RAID 界面时填这个。

> **首次登录 LSA 需 20–40 秒**（本机实测 31 秒），期间界面无反馈是正常的，**请勿重复提交**。

忘记口令：`sudo /var/apps/raidview/cmd/reset-password`，再重新打开应用重设。
卸载残留自查：`sudo /var/apps/raidview/cmd/audit-residue`。

---

## 本次更新（0.2.5）

### 修复 / 加固

- **设置凭据后立即自检**：校验 `passwd -S` 为可用态、且 shadow 哈希能用该口令复算。
  不通过**当场在设置页报错**，不让你到登录页才发现登不上。
- **新增设置完成页**：不再设完就跳转，改为明确显示**登录账号名**（大字）+ 提示
  「首次登录需 20–40 秒」+「忘记口令怎么办」。
- **修复完成页渲染异常**（0.2.4 的 CSS `100%` 与 Python `%` 格式化冲突，导致响应中断）。
- **新增 `cmd/audit-residue`**：只读卸载残留审计脚本。

### 排查记录（如实说明）

有反馈"首启设置密码后登录报 `Invalid Credentials`"。在 0.2.3 上用浏览器真实登录复测了三种场景
（不走向导后设密码 / 用默认账号名 / 设置后完整重启 / 卸载重装后设新账号），**全部登录成功，未能复现**。
"LSA 启动时缓存 OS 用户库"的假设因此被证伪，故**没有**加入"设置后重启后端"的逻辑。

排查中发现的真实隐患：**登录一次要 31 秒**（`POST /1.0/servers/<id>/login` 实测 30888 ms），
期间无反馈极易被当成失败。本版已把这个预期写进界面。

---

## 从 0.2.2 起累积的重要修复

| 版本 | 内容 |
|---|---|
| 0.2.3 | 更名「博通控制器管理」；换 Broadcom 标识图标；补非官方声明 |
| 0.2.2 | 登录账号名可自定义；账号在运行环境内动态创建，只读组同步更新 |
| 0.2.1 | 修复「从 fnOS 面板打开报 not found」——`/app/*` 前缀通用剥离 + 网关前缀自愈 |
| 0.2.0 | 应用名改从 manifest 读取，避免安装暂存目录污染运行期配置 |
| 0.1.9 | 面板入口改为平台原生 gateway（unix socket + `/app/<name>` 反代） |
| 0.1.8 | 安装向导/首启设置页设登录口令；`/status` 不再返回任何口令 |
| 0.1.7 | 跳转链接改用请求 Host 头；未就绪不再返回 JSON；去掉 LSA 前端 X-Frame-Options |
| 0.1.6 | 安装前 CPU 指令集预检；基线定为 gcc_8.3.x（兼容无 AVX 的虚拟 CPU） |
| 0.1.5 | 卸载清理 `@appdata`；构建脚本挂载改入私有命名空间，杜绝误卸宿主 `/dev/pts` |

---

## 自行构建（不依赖本 Release 的 fpk）

```bash
# 1. 自备 LSA 安装包（本仓库不提供，需自行从厂商/Broadcom 获取）
mkdir -p build/vendor
cp 008.018.012.000_MR_7.38_LSA_Linux.zip build/vendor/

# 2. 构建
make image && make pkg
# 产物 build/dist/raidview.fpk
```

需要 x86_64 Linux、root、能访问清华 TUNA 镜像、`fnpack`（fnOS 官方打包工具）。

---

## 已知限制

- **不支持**：fnOS 在虚拟机内、卡在宿主机且未直通的场景。
- **未验证**：有卡环境下的全部功能（控制器枚举、VD/PD、重建进度、电池、事件）、
  `readonly_access_groups` 是否真的拦住写操作、`backup.exclude` 是否被平台执行。
- 内置 LSA 前端是明文 HTTP；登录口令过局域网为明文传输。

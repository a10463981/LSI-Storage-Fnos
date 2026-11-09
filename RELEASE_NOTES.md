# 博通控制器管理 v0.1.01

> **非官方第三方集成包**，与 Broadcom Inc. 无隶属关系，未获其授权或背书。
> Broadcom、LSI、MegaRAID、LSI Storage Authority 是 Broadcom Inc. 的商标或注册商标。
>
> ⚠️ **本 fpk 内含 Broadcom LSA 的专有二进制**（LSA deb、`/opt/lsi` 全部组件、Ubuntu rootfs），
> 仅面向个人使用场景分发，**存在被要求下架的可能**。
> 源码仓库不含任何 Broadcom 二进制；你也可以自备 LSA 包自行构建（见文末）。

---

## 这是什么

在 fnOS 上内置 Broadcom LSI Storage Authority 的完整运行环境，装完点开就是图形化的
MegaRAID 管理界面。**不需要 storcli，不需要在别处另装 LSA。**

- 本机阵列卡，或 **PVE/ESXi 整卡直通**给 fnOS 的阵列卡
- 应用以 root 运行，自带 chroot 运行环境，与你系统的软件包互不干扰
- 端口：2463（门户）、2464（LSA 前端）；内部 41000、SLP 427

**本应用只读**：不创建/删除阵列、不改缓存策略、不刷固件。
但内置的是 Broadcom 原版 LSA 控制台，LSA 本身具备写能力——"只读"指我们不提供写入口。

---

## 安装

```bash
sudo appcenter-cli install-fpk LSI-Storage-Fnos.fpk
sudo /var/apps/LSI-Storage-Fnos/cmd/main start
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

**不支持**：fnOS 在虚拟机内、RAID 卡在宿主机且未直通（内核看不到卡，内置 LSA 同样看不到）。

### 首次使用（设置账号与口令）

装完点开应用，**第一屏就是「设置登录口令」**：

1. 账号名（默认 `lsiadmin`，可自定义；小写字母或下划线开头，≤32 位）
2. 口令（≥8 位，两次一致）
3. 勾选「我已记下这个口令」→ 提交

提交后是**完成页，上面用大字写着你的账号名** —— 登录 RAID 界面时填这个。

> **首次登录 LSA 需 20–40 秒**（本机实测 31 秒），期间界面无反馈是正常的，**请勿重复提交**。

忘记口令：`sudo /var/apps/LSI-Storage-Fnos/cmd/reset-password`，再重新打开应用重设。
卸载残留自查：`sudo /var/apps/LSI-Storage-Fnos/cmd/audit-residue`。

---

## 本次发布

**首个正式版本。** 能力与限制如上。

已在真实 fnOS 上验证：安装 → 自动拉起 → 预热门 → 设置凭据 → 真实登录 → 连续启停零残留；
面板图标入口（`/app/LSI-Storage-Fnos`）与直连端口（2463）均正常。

### 已知限制

- **有卡环境未验证**：控制器枚举、虚拟盘/物理盘状态、重建进度、电池与事件信息，
  以及 `readonly_access_groups` 是否真的拦住写操作，均需真卡确认。
- `backup.exclude` 是否被平台执行未验证。
- 内置 LSA 前端为明文 HTTP，登录口令过局域网为明文传输。

---

## 自行构建（不依赖本 Release 的 fpk）

```bash
mkdir -p build/vendor
cp 008.018.012.000_MR_7.38_LSA_Linux.zip build/vendor/   # 需自行从厂商/Broadcom 获取
make image && make pkg
# 产物 build/dist/LSI-Storage-Fnos.fpk
```

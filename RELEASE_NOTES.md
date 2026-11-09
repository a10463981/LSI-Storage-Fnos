# 博通控制器管理 0.2.3

> **非官方第三方集成包**，与 Broadcom Inc. 无隶属关系，未获其授权或背书。
> 本仓库与 Release 资产**均不包含**任何 Broadcom 专有二进制（LSA / rootfs），
> 你需要自行获取 LSA 安装包后再构建。

## 本次更新

- **应用更名为「博通控制器管理」**，图标换为 Broadcom 品牌标识（红色圆形 mark）。
- manifest 补上**非官方第三方集成声明**（`desc` 首段），避免被误认为 Broadcom 官方出品。
- 账号名可自定义（默认 `raidview`），安装向导与首启设置页都可填。

## 从 0.2.2 起累积的重要修复

| 版本 | 内容 |
|---|---|
| 0.2.2 | 登录账号名可自定义；账号在运行环境内动态创建，`readonly_access_groups` 同步更新 |
| 0.2.1 | 修复「从 fnOS 面板打开报 not found」——`/app/*` 前缀通用剥离 + 网关前缀自愈 |
| 0.2.0 | 应用名改从 manifest 读取，避免安装暂存目录污染运行期配置 |
| 0.1.9 | 面板入口改为平台原生 gateway（unix socket + `/app/<name>` 反代） |
| 0.1.8 | 安装向导/首启设置页设登录口令；`/status` 不再返回任何口令 |
| 0.1.7 | 跳转链接改用请求 Host 头；未就绪不再返回 JSON；去掉 LSA 前端 X-Frame-Options |
| 0.1.6 | 安装前 CPU 指令集预检；基线定为 gcc_8.3.x（兼容无 AVX 的虚拟 CPU） |
| 0.1.5 | 卸载清理 `@appdata`（268MB）；构建脚本挂载改入私有命名空间，杜绝误卸宿主 `/dev/pts` |

## 构建

```bash
# 1. 自备 LSA（本仓库不提供）
mkdir -p build/vendor
cp 008.018.012.000_MR_7.38_LSA_Linux.zip build/vendor/

# 2. 构建
make image && make pkg
# 产物 build/dist/raidview.fpk
```

## 已知限制

- **不支持**：fnOS 在虚拟机内、卡在宿主且未直通的场景（内核看不到卡）。
- **未验证**：有卡环境的全部功能、`readonly_access_groups` 的真实拦截效果、`backup.exclude` 是否被平台执行。
- 内置 LSA 前端为明文 HTTP；登录口令过局域网明文。

## 致谢与商标

Broadcom、LSI、MegaRAID、LSI Storage Authority 是 Broadcom Inc. 的商标或注册商标。
本项目的代码以 MIT 许可发布；第三方组件的权利归各自所有者。

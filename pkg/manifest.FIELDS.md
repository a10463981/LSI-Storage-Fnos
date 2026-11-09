# manifest / config 字段：实测确认 vs 推测

## 权威来源

1. `fnpack create <name> -t native` 生成的官方最低模板（本机 fnpack 1.2.4 实跑）
2. 8 个已装应用的真实 manifest（.15 上 `cat /var/apps/*/manifest`）
3. 我们自己的 `raidview.fpk` 已用这套字段 **构建成功并安装运行**（.15 实测）

## manifest 字段逐个标注

| 字段 | 值 | 状态 | 依据 |
|---|---|---|---|
| `appname` | raidview | ✅ 实测 | 模板必填 |
| `version` | 0.1.3 | ✅ 实测 | 模板必填；同版本重复安装不会替换文件 |
| `display_name` | MegaRAID 监控 | ✅ 实测 | 模板必填 |
| `desc` | … | ✅ 实测 | 模板必填 |
| `platform` | x86 | ✅ 实测 | 模板必填 |
| `source` | thirdparty | ✅ 实测 | 模板必填 |
| `maintainer` | raidview | ✅ 实测 | 模板必填 |
| `distributor` | raidview | ✅ 实测 | 模板必填 |
| `desktop_uidir` | ui | ✅ 实测 | 模板必填；对应 `app/ui/` |
| `desktop_applaunchname` | raidview.Application | ✅ 实测 | 必须与 `app/ui/config` 的 `.url` 键逐字符相同 |
| `service_port` | 2463 | ✅ 实测 | 两个真实应用用过；我们的安装运行也验证了 |
| `checkport` | false | ✅ 实测 | 平台不替我们探端口，端口冲突要自己处理 |
| `os_min_version` | 1.2.0401 | ⚠️ 推测 | 取自 mail-archiver-fnos 的已装值，未在更低版本上验证 |
| `changelog` | … | ✅ 实测 | 8/8 真实应用都有；模板没有但实际必填 |
| `checksum` | **不写** | ✅ 实测 | fnpack 构建时自动注入 |
| `install_type` | **不写** | ✅ 实测 | 只有官方包写 `root`（装系统分区）；第三方不写才会装到用户选的卷 |

## config/privilege

```json
{ "defaults": { "run-as": "root" } }
```

✅ 实测：`code.editor`（第三方上架应用）就是这个形态，无 `username`/`groupname`。
`join-groups` 只出现在 package 形态里，root 形态不需要。

fnpack 会解析这个文件，**必须是合法 JSON**，否则构建直接失败。

## config/resource

```json
{
  "backup": {
    "enabled": true,
    "check_storage": true,
    "exclude": {
      "@appcenter": ["rootfs.tar.gz"],
      "@appdata": ["rootfs/", "logs/", "run/", "*.log", "*.pid"],
      ...
    }
  }
}
```

⚠️ **未完全验证**：`backup` 的完整 schema 是从 `trim.media` 抄的（它多一个 `guide` 占位符）。
`{}` 也能通过构建（fnpack 只校验 JSON 合法性），但那样平台的备份会把这 269MB 的 rootfs 一起复制。

`exclude` 的路径写法（是否需要前缀、是否支持通配）**未验证**，需在真机备份日志里确认。

## app/ui/config

```json
{
    ".url": {
        "raidview.Application": {
            "title": "MegaRAID 监控",
            "icon": "images/icon_{0}.png",
            "type": "url",
            "protocol": "http",
            "url": "/",
            "allUsers": false
        }
    }
}
```

✅ 实测：这套写法安装后应用入口正常（`/enter` 302 到 2464，`service_port` 生效）。

参考形态：
- `trim.media`：`type: url` + `protocol: http` + `url: /v`（无 port 字段，靠 `service_port`）
- `code.editor`：`type: iframe` + `url: /cgi/ThirdParty/<app>/index.cgi/`
- `rustfs-fnos`：`type: iframe` + `gatewayPrefix` + `gatewaySocket`（走 unix socket 反代）

## 包里不能有的东西

| 项 | 原因 |
|---|---|
| `wizard/install/` 目录 | 实测报 `Packing failed. File "install" is not valid due to JSON format or content validation failure` |
| 缺 `ICON.PNG` / `ICON_256.PNG` | fnpack 校验必需 |
| 手写 `checksum` | 会被构建期注入值覆盖或冲突 |

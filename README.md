# zcode-winpatch

给 [magpie](https://usemagpie.com) 的 zcode 插件做 **客户端环境对齐（Windows 基线）**，让 Linux VPS 上的请求与 ZCode 官方桌面端的预期客户端特征保持一致，避免 Start Plan 通道的 `3012` 异常判定。

## 问题

在 Linux 服务器上跑 magpie + zcode 插件时，请求会被 ZCode 拒绝：

```
ZCode: request has been blocked due to unusual activity. (405, code 3012)
```

或者签到时报：

```
ZCODE WEEKEND BUILD: claim it in the ZCode app (captcha verify failed)
```

**换 IP、换代理、换家宽都没用** —— 判定依据不是 IP，是**客户端平台标识**。

## 根因

`zcode.z.ai` 的 Start Plan（免费/活动额度通道）会校验请求头里的操作系统标识，
并按官方桌面端（Windows）的取值范围判定合法性。
插件自带的 18 个请求头（`X-ZCode-App-Version`、`x-zcode-trace-id`、
`x-zcode-query-source` 等）已经齐了，但平台值直接取自 `process.platform`，
在 Linux 上原样上报，与官方客户端的预期基线不一致：

| Header | Linux 下的值（被判异常） | Windows 基线值 |
|---|---|---|
| `X-Platform` | `linux-x64` | `win32-x64` |
| `X-Os-Category` | `linux` | `windows` |
| `X-Os-Version` | `6.12.113+deb13-arm64` | `10.0.22631` |
| `X-Client-Language` | 环境默认 | `zh-CN` |
| `X-Client-Timezone` | `UTC` | `Asia/Shanghai` |

非 Windows 取值的请求被判定为异常，回 `3012`，账号进入风控冷却
（跟着账号走，只有等或联系官方）。

## 用法

```bash
# 1. 先装插件
magpie plugin add zcode

# 2. 对齐环境基线
./patch.sh

# 3. 验证
./patch.sh --verify
```

打完后 magpie 会自动重启，请求恢复正常。

### 其它选项

```bash
./patch.sh --dry-run          # 只检查会改什么，不写
./patch.sh --verify           # 只验证是否已打补丁（可写进 CI/健康检查）
./patch.sh --path DIR         # 手动指定插件目录
```

### 插件升级后

`magpie plugin update` 会用 npm 上的原始文件覆盖 `index.mjs`，补丁随之丢失。
**升级后重跑 `./patch.sh` 即可。** 脚本是幂等的，重复执行不会出错。

## 改了什么

五处改动，全部在 `index.mjs`：

```js
const WSBASE = { platform: "win32", arch: "x64", release: "10.0.22631" }
const platform   = () => `${WSBASE.platform}-${WSBASE.arch}`
const osVersion  = () => `${WSBASE.platform} ${WSBASE.release} ${WSBASE.arch}`
const osCategory = () => "windows"
out.set("X-Os-Version", WSBASE.release)

function intl() {
  return { locale: "zh-CN", timeZone: "Asia/Shanghai" }
}
```

## 安全设计

- **先备份**：首次运行把原件存为 `index.mjs.orig`，不覆盖已有备份
- **语法检查**：改完用 `node --check` 验证，失败自动回滚
- **幂等**：已打过补丁的会跳过，不会重复注入
- **可回滚**：`cp index.mjs.orig index.mjs && systemctl restart magpie-web`

## 已验证环境

- Debian 11 / x86_64 / OpenVZ
- magpie 0.1.3177
- `@magpie-community/opencode-zcode-auth` 0.1.51

实测结果：模型请求正常返回，额度真实扣减，签到不再报 captcha。

## 注意

- 这是**对齐客户端特征基线**，不是解除风控。别拿它做高频自动化请求，
  保持真实客户端的请求节奏（一天几次签到 + 正常对话）才稳。
- 插件版本大改后，`index.mjs` 的函数结构可能变化，脚本会报
  `[=] 无需改动` 并在 `--verify` 里显示未打补丁 —— 这时需要按新版手工核对。

## License

MIT

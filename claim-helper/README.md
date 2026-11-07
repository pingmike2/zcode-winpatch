# claim-helper — 手动过滑块领取 ZCode Start Plan 辅助页

VPS 上常驻的网页：选账号 → 点领取 → 风控放行直接领（code:0），被拦自动弹阿里云滑块，过了带 `X-Aliyun-Captcha-Verify-Param` 头重发 claim。

- 多账号：下拉列表读 `/root/.config/magpie/plugin-auth.json` 里所有 `zcode*` 账号，显示名取 `accountId`（真实邮箱），`?acc=<id>` 直达指定账号，`?plan=<plan_id>` 换套餐。
- 免验证窗口：请求先不带 verify 头直发；`code:3007` 才弹滑块。风控按请求打分，同一账号时高时低：低分窗口内直领成功，高分窗口必弹滑块（多号各自独立打分，命中率因号而异）。
- 入口：监听全接口，公网 v6 直达 `http://[<VPS IPv6>]:12696/`（页面顶部会显示本机入口 ip:port）。临时隧道（`cloudflared tunnel --url "http://[::1]:12696" --edge-ip-version 6` + 本机纯 v6 时 SSH 转发必须绑 `[::1]:12696`）只是手机无 v6 网络时的备选，隧道地址随进程变化，重启换新即可。
- 部署：脚本放 `/tmp/zcode-captcha-claim.mjs`（node 24 运行），unit 见 `zcode-claim-page.service`，`systemctl enable --now zcode-claim-page`。日志 `/tmp/zcode-claim-captcha.log`。
- 响应码：0 成功 / 1003 已领 / 3007 需验证码 / 1004 条件不符；验证码 F 码：F008 重提、F014 超时、F019 窗口 90 秒、F015 交互不通过。

# 通用静态代理环境 Skill

为 Windows 配置、迁移和核验固定代理出口的 Codex Skill，不绑定代理提供商。

## 功能

- HTTP、HTTPS、SOCKS5 用户名密码接入模板。
- Claude Desktop、Claude Code、Edge、Chrome 和可选专用 API 路由器的代理配置。
- 按应用限制非本机回环出站，代理失效时禁止直接连接，包括 IPv4 和 IPv6。
- 远端 DNS、经代理的 DoH、外部 DNS 端口保护与入口引导记录。
- 系统代理漂移修复、后台启动、核验与排障流程。

## 安装与使用

下载仓库，将 `configure-static-proxy-network` 文件夹放入目标电脑的 `~/.codex/skills/`，随后调用：

```text
$configure-static-proxy-network
请配置我的固定代理出口，并在不切断当前管理连接的情况下完成核验。
```

先准备自己的固定出口 IP、入口主机、端口、协议、认证方式，以及返回 JSON 顶层 `ip` 字符串的 HTTPS 出口检测接口。密码在目标电脑安全输入，不要放入聊天、仓库或 issue。

参数生成器仅生成文件，不修改网络：

```text
python configure-static-proxy-network/scripts/materialize.py --exit-ip <你的固定公网出口> --upstream-host <入口主机> --upstream-port <端口> --protocol <http或https或socks5> --check-url <HTTPS检测接口> --output <新的输出目录>
```

详情见 [Skill 入口](configure-static-proxy-network/SKILL.md) 和 [参数说明](configure-static-proxy-network/references/parameterization.md)。

## 部署边界

这是供代理助手适配的模板集，不是一键安装器。`ExampleUser`、`__CURRENT_USER_SID__`、路径、应用版本和网卡信息须按目标机器替换；`.template` 不能直接执行。白名单免密、其他隧道协议与 IPv6 入口需要另行适配。

只保护实际配置并核验的应用，不代表整机流量全部受保护。保留 ToDesk；当前 ChatGPT/Codex 管理程序和共享 Node 默认不纳入相同应用防火墙限制。相同出口不隐藏设备身份。

第三方业务路由器、代理核心二进制、登录状态及所有真实凭据均不包含在仓库中。按需部署可选项目；不适用项应明确记录，不能伪造审计通过。依赖版本和应用配置接口应在部署时重新核对。

## 验证状态

已做三种协议的离线生成、PowerShell/JavaScript 语法与包完整性检查。尚未在你的新电脑或任意提供商上实测；部署后必须核验真实出口、DNS、断代理时禁止直连、程序版本覆盖和后台启动行为。

`dist/` 提供脱敏后的安装压缩包与 SHA-256 校验文件。

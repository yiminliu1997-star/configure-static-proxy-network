# Claude 网络守护 v1.0

为已部署的 Windows 静态代理环境提供状态窗口和两项后台计划任务。守护程序定期核验代理出口、DNS、防火墙规则和 Claude 可执行文件覆盖。异常时锁定并停止已识别的 Claude Desktop、Claude Code 和专用路由器，修复后需手动解锁。关闭状态窗口后后台任务继续运行。

## 构建与部署

需要 Windows x64、Windows PowerShell 5.1、.NET Framework 和可用的管理员账户。请将源码复制到用于运行的独立目录，再按顺序执行。

1. 先按仓库的 [Skill 说明](../README.md) 部署并验证现有代理、DNS、防火墙和 Claude 专用路由器。v1.0 需要本机代理 `127.0.0.1:12460`、本机 DNS 端口 `53` 和路由器 `127.0.0.1:18791`。
2. 将 `config.example.json` 复制为 `config.json`，填写目标机器的路径、账户与任务名。审计脚本与目标配置应来自已完成参数配置的 Skill，出口检测地址从目标配置的 `exitCheck.url` 读取，响应须含顶层 `ip` 字段。
3. 核对 `EgressGuard\targets.json` 和对应的有效阻断规则。清单需覆盖 Claude Desktop 包内全部 EXE、已安装的 Claude Code 版本和专用路由器。确认已配置禁用 Claude 自动升级的策略。
4. 在该目录执行 `.\Build.ps1` 生成 `ClaudeNetworkGuard.exe`。双击此文件可打开状态窗口。
5. 从管理员 Windows PowerShell 执行 `.\Manage.ps1 -Action Preflight` 核验配置，再执行 `.\Manage.ps1 -Action Install` 安装后台任务。检查窗口状态，确认完整审计通过、两个后台任务正常后，执行 `.\Manage.ps1 -Action Arm` 启用异常停止。

锁定后先修复报告中的异常，再在窗口点击“检查通过后手动解锁”。要移除守护任务，在管理员 Windows PowerShell 执行 `.\Manage.ps1 -Action Uninstall`。卸载时已锁定的路由器保持停用，需要单独核验并恢复。

## 覆盖范围

新增了对 Claude Desktop 安装包内辅助程序的识别和版本覆盖检查，包括 Cowork、SSH 辅助程序和随包 GitHub MCP。依赖直连的功能可能受防绕行规则限制。包外的共享运行时、独立 MCP、虚拟机或容器内部流量仍需单独验证。守护程序按周期检测，系统防火墙承担已覆盖程序的连接拦截。

状态文件读取遇到替换期间的短暂占用或文件缺失时，每 50 毫秒重试，最多等待约 1 秒。持续读取失败仍会上报错误并触发既有保护。JSON 内容损坏会直接报错。

`Test-ReadIO.ps1` 和 `Test-ReadIO.cs` 覆盖短暂占用、持续占用、文件缺失、内容损坏及并发替换。配置好测试目录中的 `config.json` 后，可用 Windows PowerShell 执行前者。后者与 `LightGuard.cs` 一起编译，入口选择 `/main:ReadTests`，引用与 `Build.ps1` 相同，执行时传入独立测试目录。测试仅操作独立测试文件。

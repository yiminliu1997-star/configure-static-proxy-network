# Claude 网络守护 v1.1

为已部署的 Windows 静态代理环境提供状态窗口和两项后台计划任务。守护程序定期核验代理出口、DNS、防火墙规则和 Claude 可执行文件覆盖。异常时锁定并停止已识别的 Claude Desktop、Claude Code 和专用路由器，修复后需手动解锁。关闭状态窗口后后台任务继续运行。

## 构建与部署

需要 Windows x64、Windows PowerShell 5.1、.NET Framework 和可用的管理员账户。请将源码复制到用于运行的独立目录，再按顺序执行。

1. 先按仓库的 [Skill 说明](../README.md) 部署并验证现有代理、DNS、防火墙和 Claude 专用路由器。v1.1 需要本机代理 `127.0.0.1:12460`、本机 DNS 端口 `53` 和路由器 `127.0.0.1:18791`。
2. 将 `config.example.json` 复制为 `config.json`，填写目标机器的路径、账户与任务名。审计脚本与目标配置应来自已完成参数配置的 Skill，出口检测地址从目标配置的 `exitCheck.url` 读取，响应须含顶层 `ip` 字段。
3. 核对 `EgressGuard\targets.json` 和对应的有效阻断规则。清单需覆盖 Claude Desktop 包内全部 EXE、已安装的 Claude Code 版本和专用路由器。确认已配置禁用 Claude 自动升级的策略。
4. 按下方“v1.1 新增保护的部署前置条件”完成 WebRTC 和回环限制预检，再在该目录执行 `.\Build.ps1` 生成 `ClaudeNetworkGuard.exe`。双击此文件可打开状态窗口。
5. 从管理员 Windows PowerShell 执行 `.\Manage.ps1 -Action Preflight` 核验配置，再执行 `.\Manage.ps1 -Action Install` 安装后台任务。检查窗口状态，确认完整审计通过、两个后台任务正常后，执行 `.\Manage.ps1 -Action Arm` 启用异常停止。

锁定后先修复报告中的异常，再在窗口点击“检查通过后手动解锁”。要移除守护任务，在管理员 Windows PowerShell 执行 `.\Manage.ps1 -Action Uninstall`。卸载时已锁定的路由器保持停用，需要单独核验并恢复。

## 覆盖范围

新增了对 Claude Desktop 安装包内辅助程序的识别和版本覆盖检查，包括 Cowork、SSH 辅助程序和随包 GitHub MCP。依赖直连的功能可能受防绕行规则限制。包外的共享运行时、独立 MCP、虚拟机或容器内部流量仍需单独验证。守护程序按周期检测，系统防火墙承担已覆盖程序的连接拦截。

状态文件读取遇到替换期间的短暂占用或文件缺失时，每 50 毫秒重试，最多等待约 1 秒。持续读取失败仍会上报错误并触发既有保护。JSON 内容损坏会直接报错。

出口和路由器 HTTP 核验首次超时后立即重试一次，每次最多 6 秒。连续超时、请求错误或响应缺少有效 IP 时记录提醒并继续运行。成功取得有效出口 IP 且与指定值不符时锁定。路由器代理端口不符及其他防绕行检查失败仍触发锁定。

状态窗口打开时显示黄色提醒、提醒计数和托盘提示。关闭窗口后提醒写入后台日志。`Test-ExitPolicy.ps1` 验证出口异常提醒与其他保护失败的锁定决策，`Test-Timeout.ps1` 验证 HTTP 超时重试。

`Test-ReadIO.ps1` 和 `Test-ReadIO.cs` 覆盖短暂占用、持续占用、文件缺失、内容损坏及并发替换。配置好测试目录中的 `config.json` 后，可用 Windows PowerShell 执行前者。后者与 `LightGuard.cs` 一起编译，入口选择 `/main:ReadTests`，引用与 `Build.ps1` 相同，执行时传入独立测试目录。测试仅操作独立测试文件。

## v1.1 更新

- 主页分为代理与出口、防直连与端口限制、DNS 与 WebRTC、Claude 版本与配置、后台守护、文件与配置完整性六类；支持展开明细，异常与提醒优先排列。顶部显示出口、总数和检查时间。分类不会改变后台判定或执行频率。
- 新增 Edge/Chrome 各三项 WebRTC 注册表策略检查，涵盖机器/用户和 32/64 位视图。策略检查不等于浏览器实际泄漏测试。
- 新增原生 WFP 回环限制和两项完整性检查：仅允许 TCP 127.0.0.1:12460，Claude Code 另允许 18791；其他回环地址、端口、UDP 均阻断。覆盖清单中的 Claude 路径，不给 Chrome/Edge 添加这层限制。
- 本机验收为 104 项；数量随运行进程和安装版本变化，不硬编码为固定总数。已有出口检测超时仅提醒、有效 IP 不符锁定的策略不变。

## v1.1 新增保护的部署前置条件

升级正在运行的环境前应备份，先安装和验证新保护，再更新 Probe；不要因缺少新文件而触发生产环境锁定。UI 可单独替换 `ClaudeNetworkGuard.UI.exe`，不需重启后台看守。

1. 配置 Edge 的 `WebRtcLocalhostIpHandling` 和 Chrome 的 `WebRtcIPHandling` 为 `disable_non_proxied_udp`；检查 URL 覆盖及本地 IP 暴露例外。由 `WebRtcChecks.ps1` 只读验证，特别确认 Session 0 读取的策略；本仓库不擅自修改浏览器策略。
2. 检查目标程序的本机连接及 hooks/MCP/登录回调。只允许代理端口可能影响本地集成；先备份并按需停用冲突集成，不自动放行任意本机服务。ClaudePet HTTP hooks 是一个实际遇到的例子，其他机器不可按固定端口盲目删除。
3. 安装 Visual Studio C++ Build Tools 与 Windows SDK，执行 `LoopbackGuard\Build.ps1`。在**未安装该 WFP 子层的独立测试环境**，以管理员运行 `LoopbackGuard.exe selftest` 和 `LoopbackGuard.exe selftest-persistent`。测试只绑定测试程序，成功时清理测试过滤器；若失败，检查是否留有测试规则，不能带着失败结果部署。
4. 根据本机已确认的目标配置执行 `LoopbackGuard\Prepare-Manifest.ps1`，审核本机生成的 `targets.tsv`。该文件含本机程序路径，不提交到仓库。当前版本按既定标签区分 Code/路由器并排除 Edge/Chrome，自定义标签需同步调整生成器和 `LoopbackChecks.ps1`。
5. 管理员执行 `LoopbackGuard\LoopbackGuard.exe install LoopbackGuard\targets.tsv`，随后执行 `audit` 同参数。安装使用事务；审计核对路径、地址、端口、协议、动作、持久标志及规则数。已有子层时拒绝重复安装，不隐式覆盖。
6. 执行完整 `Manage.ps1 -Action Preflight`，确认 Session 0 持续健康后才启用自动停止。浏览器策略生效和实际网络请求需在目标机器验证，不能仅凭编译成功认定部署成功。

WFP 规则不依赖 UI 或安装器持续运行。既有非回环防火墙规则保持原样；未声称重启验证或零泄漏。按 EXE 路径保护仍不覆盖外部共享运行时、虚拟机或其他进程代发；允许代理端口本身不是对监听进程的身份认证。

`Manage.ps1 -Action Uninstall` **不会删除 WFP 规则**。有意撤销本次回环限制时，应先协调监控对这两项的检查，再由管理员执行 `LoopbackGuard\LoopbackGuard.exe remove unused`，仅删除此程序自己的子层和过滤器；否则会被既有监控判为保护缺失并锁定。不要通过删除锁定文件绕过核验。

## v1.1 验证

`Test-WebRtcChecks.ps1` 覆盖安全/缺失/宽松策略、覆盖规则、例外及读取错误；`Test-Categories.ps1` 在 STA Windows PowerShell 中使用本机健康报告验证分类和提醒/异常/锁定停用显示，不修改生产状态。构建后执行。

原生独立测试包含允许端口的双向通信、禁止端口、IPv6、UDP、其他 127/8 地址、持久规则读回、缺失规则检测和撤销后恢复。上线后另用受保护专用 Node 的独立进程验证本机非允许端口被阻断、主代理出口正常。所有本机日志、出口值、配置及凭据均不包含在公开源码中。

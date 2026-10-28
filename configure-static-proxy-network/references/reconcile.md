# 恢复与核验流程

## 发现及备份

目标见 desired-state.json，rootHint 只是提示。识别当前用户、SID、实际运行目录、所有上网网卡、监听端口所有者、应用安装路径及运行版本。读取工作目录 AGENTS.md（若存在）。进程参数可能含秘密，只在内存分析，输出前脱敏。

确认当前聊天依赖的代理及核心 PID，保持运行。ToDesk 明确排除，不修改其配置。备份本次要改的 JSON、环境变量、WinINet、Edge 策略、任务 XML、自有防火墙规则、网卡 DNS 及 DHCP/静态模式；新时间戳目录 ACL 限当前用户及 SYSTEM。失败仅回滚本次修改。

管理员操作使用已检查的独立脚本及 UAC，隐藏非交互窗口。自动审批拒绝时说明动作及原因，不通过换壳绕过。已明确授权恢复时无需再次询问常规修复许可。

## 代理与引导解析

独立 proxy-core.exe 在127.0.0.1:12460提供 mixed 入站，按所选 HTTP/HTTPS/SOCKS5 协议连接 __PROXY_UPSTREAM_HOST__:__PROXY_UPSTREAM_PORT__；TLS参数见目标JSON；最终出口__PROXY_EXIT_IP__，没有 direct 备用。不依赖樱花猫。

复用 root/credential.xml 的 DPAPI PSCredential，只能在对应 Windows 用户/机器上下文解密。可以检查旧的 OpenAI.Codex MSIX LocalCache/Local/StaticProxy 可信备份，但运行目录应保持新 root。无法恢复凭据时要求用户安全补充，不输出秘密。

二进制不随技能分发。优先复用本机可信兼容版本，核对来源/版本/哈希及 check -c；缺少时从可信发行源取得并校验，不能假定任意 sing-box 构建兼容。Control.ps1 将凭据写入短暂 runtime.json，启动后删除；保留同等 ACL 及清理保护。

系统 DNS 依赖代理，必须保留 __PROXY_UPSTREAM_HOST__ 的本地静态引导记录打破循环。入口IP不是固定出口。bootstrap.json 中最后可用入口继续使用；通过可用代理查询 DoH 更新，逐个用独立临时端口及真实凭据确认出口；HTTPS 还必须验证证书和服务器名称。不能重启健康主代理做测试。

所有入口失效时，可用仍可用的既有网络或经过验证的直连 HTTPS DoH 仅解析代理入口域名。不要给目标站点开放 DNS 回退，不关闭整机保护。取得不了可信可达入口则报告阻塞。

## Windows 与聊天客户端

### 无窗口守护（2026-10-26 已部署）

四项任务 StaticProxy-Proxy、StaticProxy-DNS、Claude Model Router Watchdog、StaticProxy-SystemProxyGuard 使用 Windows 任务计划程序原生 S4U/非交互登录，当前用户、Limited、登录触发、PT0S 和原失败重试策略保持不变。worker 位于 Session 0，不在用户桌面产生终端窗口；不能仅凭 powershell.exe 的 -WindowStyle Hidden 判断无窗口。用户关闭其他终端窗口不会关闭 Session 0 的 worker。不可恢复成 Interactive，否则可能再次出现可被误关的窗口。

这是系统原生任务会话配置，不依赖自编译的 BackgroundHost.exe、VBScript、第三方服务或关闭系统防护。此前自编译启动器曾被应用程序控制阻止，未采用，不要重试或绕过该阻止。

S4U 有网络身份验证及加密数据访问限制，不能假设在任何机器或未登录状态都能解密 DPAPI。本机已在当前用户登录后实测 Session 0：credential.xml 解密、独立临时代理实际固定出口、现有代理访问、HKCU 设置读取及系统代理自动恢复全部成功。登录触发保持不变；尚未实际重启/注销，不宣称未登录启动或重启验证通过。更换用户、凭据或系统后必须重做预检；失败时保留健康核心和原可用任务，不改凭据加密范围或降级防护来迁就任务。

模板在 assets/runtime/NonInteractive/：先将 Probe.ps1、Register-Probe.ps1、Migrate.ps1 放入运行 root 下新建的受限 ACL 备份子目录。Register-Probe.ps1 只新建一次性 StaticProxy-NonInteractive-Probe，权限不足时经正常 UAC 运行；不覆盖同名陌生任务。Probe.ps1 复用 root/DnsGuard/Verify-Entry.ps1（先检查；新机可适配随包的 assets/runtime/DnsGuard/Verify-Entry.ps1），不输出秘密。只有 probe-result.json 显示 SessionId=0 且 Credential/Proxy/Entry/Registry 全为 true 才迁移。结束后清理自己的测试任务。

迁移前导出四项任务 XML，并将 12460、53、18791 的 LocalPort、LocalAddress、OwningProcess 存入本次目录 listeners.before.json。Migrate.ps1 逐项改为 S4U，按完整 PowerShell 可执行路径和 -File 脚本路径唯一识别旧交互 worker，仅结束该单个 worker PID，等待任务释放后启动新实例。禁止 Stop-ScheduledTask、taskkill /T 或终止全部 PowerShell/Node，因为可能杀死网络核心。已存在的 Node watchdog 由 launch-watchdog.ps1 等待接管，不重启业务路由器。若核心 PID 变化或进程识别不唯一，停止迁移，按备份逐项排障，不盲目杀进程。

验收：四项任务实际 S4U/Running；每个动作脚本有唯一 Session 0 worker；ProxyGuard、DNS、Proxy 心跳新鲜；系统代理测试绕过项可自动恢复；入口更新在新会话成功；三项核心 PID 不变，连续出口与 DNS 请求成功。Session 0 隔离保证无用户桌面窗口，并非声称系统内部完全不分配控制台对象。任务即使被人为终止仍会失效，不能承诺永不停止。回滚仅针对本次任务 principal，并同样只交接 worker，不能停止进程树。

2026-10-23补充保护：用户要求防止系统代理再次被其他程序关闭。root/ProxyGuard/Guard.ps1 每500毫秒核对 WinINet flags、地址、绕过列表、PAC和自动发现，不符时通过 Windows-Proxy.ps1 恢复目标。任务 StaticProxy-SystemProxyGuard 当前用户登录触发、S4U/Limited、PT0S、失败重试999次/PT1M。不停止代理或修改防火墙；ProxyGuard/status.json 为心跳，events.jsonl仅记录脱敏的变更/恢复状态，不提供写入程序归因。检查这项任务及新鲜心跳。用户已要求停止追查历史来源，没有启用额外注册表审计。

新增无凭据模板 assets/runtime/ProxyGuard/{Guard,State,Install-Guard,Disable-Guard}.ps1。Install-Guard使用执行时新建的 install-context.json（User、Sid、Root和本次Backup），不要复制旧用户上下文。需要有意切换代理时先执行 Disable-Guard.ps1，否则配置会被自动恢复；它不会取消防绕行。测试只在代理保持开启时临时增加 proxy-guard-test.invalid 绕过项并等待恢复，不能关闭实际代理测试。

Control.ps1 的健康检查已取消对 www.microsoft.com 的额外依赖：通过 HTTPS 检查 Proxy 的精确出口即为成功，不应因单个网站拒绝而无法启用代理。Worker从实际监听端口取得核心PID，避免旧pid文件导致循环。路由器任务的launch-watchdog.ps1应等待已经存在的专用Node watchdog（以可执行文件路径及完整脚本路径确认），没有时才新建，避免重启任务生成重复watchdog。

用户 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY=目标 localProxy，NO_PROXY=目标值。合并 ~/.codex/.env 中同名键，保留其他内容。当前进程环境不会自动刷新，不能终止当前聊天。

用 Windows-Proxy.ps1 的 WinINet per-connection API 设置 flags=3、固定代理、bypass、空 PAC、关闭自动发现。只写 ProxyEnable 注册表曾留下 DIRECT 状态，导致 Edge 绕过；检查 Connections/DefaultConnectionSettings flags 和实际API/浏览行为。

StaticProxy-Proxy 任务：当前用户登录触发，S4U/Limited，PS5 隐藏 Control.ps1 -Action Worker，PT0S无限运行、失败PT1M重试至少3次。Worker 先验证出口再设置系统代理，避免重复核心冲突。普通应用入口应可使用，不强制专用快捷方式。Launch-ChatGPT.ps1 仅可选，先适配当前安装位置，不再假设旧 MSIX。

登录后自动启动不等于未登录前服务已启动；没有实际重启就不能声称实测重启通过。

## Claude 与第三方路由器

发现所有在用 Desktop/Code 版本。基线 Desktop 在 WindowsApps/Claude_3.1623.0.0_x64__pzs8sxrjxfjjc/app/Claude.exe，Code 在 LocalAppData/Claude-3p/claude-code/2.1.304/aed62990b91e/claude.exe；不能永久硬编码。

从 LocalAppData/Claude-3p/configLibrary/_meta.json 的 appliedId 找已应用配置，只合并 egressProxyUrl=localProxy、删除冲突 egressProxyPacUrl。保留提供商、模型、密钥、部署模式和登录状态；不要为验证切换1p/3p或自行登录。

合并 ~/.claude/settings.json 的 env：三个代理变量、NO_PROXY、CLAUDE_CODE_PROXY_RESOLVES_HOSTS=1。用户环境也设置远端解析变量以覆盖新进程。遥测禁用和重试次数不是这次基线，不另行添加。

第三方路由器位于目标JSON的router.rootHint，保留 router.mjs、models.json、secrets.json、watchdog.mjs。proxy-check及所有提供商请求显式使用 claude-egress.mjs 的 HTTPS Agent proxyEnv，不能只假设 Node 继承系统代理。Agent NO_PROXY为空。Node必须支持Agent proxyEnv，基线v24.19.0。

路由器127.0.0.1:18791，使用 root/EgressGuard/runtime/node.exe 独立可信副本，**不限制Codex共享Node**。watchdog使用process.execPath启动router。launch-watchdog.ps1等待子进程并在失败时返回非零。Claude Model Router Watchdog任务登录启动、Limited、PT0S、重试999次/PT1M。

业务路由器和密钥不在模板内；丢失时先恢复本机可信备份，不凭空重建第三方配置。迁移只停止确认命令行属于此路由器的进程，先watchdog后router，不能停止全部node.exe。

## 应用防绕行

组 StaticProxy-Claude-Edge-EgressGuard-v1：当前 Desktop、Code、Edge、Chrome、专用router Node每个路径 outbound Block、Enabled、Profile Any、Protocol Any，远端地址为目标JSON的三个非loopback范围。本地代理和路由器可达。显式Block优先于Allow，不能用Block Any加Allow proxy。组名虽未包含Chrome，实际保护范围包含Chrome；以发现的程序路径和当前targets.json核对。

重新生成 targets.json，覆盖升级后实际程序。ActiveStore检查规则及应用/端口/地址过滤器和profile启用状态。历史Firewall.ps1只补缺失，不修复同名规则漂移；需针对本组更新或重建。其他组的同名冲突不能直接覆盖。不要全局重置防火墙。

新规则验证后可清理被替代的自有旧路径规则。外部工具/其他子进程没有自动受保护；记录边界。允许localhost不是针对恶意本机转发程序的隔离。

## DNS

独立 dns-core.exe。test-config.json 模板的 bootstrap 列表为空，必须注入已验证地址才能部署。Worker生成dns-config.json：127.0.0.1和::1上53/TCP+UDP，hijack-dns；仅精确域名__PROXY_UPSTREAM_HOST__用hosts引导，其余经12460访问1.1.1.1:443 DoH，TLS名cloudflare-dns.com、/dns-query，无直连备用。

先在空闲15353独立测试 A/AAAA、UDP/TCP，确认主代理健康，再开启53生产监听并核验所有者。端口被其他程序占用不能直接杀进程。

StaticProxy-DNS任务用户登录启动、Limited、PT0S、重试3次/PT1M。Worker每6小时通过代理更新入口，失败保留最后可用地址、10分钟重试；历史代码只检TCP/TLS，应补独立出口验证。更新的pins下次DNS核心启动才生效，不要把文件更新等同运行中加载。

所有承担上网流量的网卡IPv4 DNS=127.0.0.1，IPv6 DNS=::1，保留原DNS/DHCP模式；不写死旧Ethernet index12。Edge用户策略DnsOverHttpsMode=off（使用受保护系统DNS，上游仍加密）、NetworkPredictionOptions=2。

组 StaticProxy-DnsGuard-v1：全应用TCP/UDP出站远端端口53和853、非loopback地址Block两条；dns-core.exe全协议非loopback Block一条；所有profile。不能全局禁IPv6或封全部443；未受应用规则限制的程序自带DoH不在全局覆盖范围。

Configure-System.ps1历史模板有旧SID、网卡及备份路径，先适配；切换前验证本地DNS、引导记录、固定出口。每次事务新建备份，不能覆盖最初system.before.json。

## 实际核验

1. 再运行只读审计，检查当前版本覆盖。明确指定12460访问 __PROXY_CHECK_URL__，顶层ip必须等于目标；router /proxy-check核对出口及peer。
2. 现有Edge打开IP页和Claude登录页。自动化受策略阻止时由用户刷新补证，不能换工具绕过。IP页仅证明该请求，需结合固定代理与有效进程防火墙判断其他请求。无新浏览证据标未验证。
3. 新Code进程读取真实settings。可用无效测试凭据触发官方请求；401/Invalid API Key证明可达，不等于登录成功。第三方后端最小实际请求核对代理日志，控制成本。第三方 API count_tokens404不等于网络失败。不能输出令牌/正文。
4. 专用受保护Node直连外部IPv4/IPv6失败，明确代理成功。可用223.5.5.5:443及[2400:3200::1]:443；没有可达性正对照时，仅超时不能单独证明拦截。结合OS规则及错误类型说明限制。
5. 用独立进程指向确认无人监听的12579测试代理故障，不触碰12460。15354独立DNS配置上游指向12579，目标查询应失败，引导域名仍本地可解。不得回退。清理本次临时进程和含凭据文件。
6. 正常DNS验证IPv4 UDP、IPv6 TCP、A/AAAA。物理网卡观测53/853（可附5353/5355/137），新鲜查询期间出站Tx=0，分清入站广播Rx。不要中断已有捕获或改其过滤器。PktMon曾导出空ETL/PCAP，**空文件不证明无泄漏**；用可工作的NIC计数器并以包括__PROXY_UPSTREAM_PORT__流量的独立正对照证明观测有效。历史Capture-Dns.ps1添加过滤器前未充分检查别人的捕获，使用前先检查。
7. 检查四项任务（包括SystemProxyGuard）的用户、动作、登录触发、启用/运行、无限运行和重试，并验证Session 0及新鲜心跳。不能为验证重启电脑/退出当前聊天。尚未实测的重启或官方登录明确标记。

保存时间戳及pass/fail/not-verified，失败修复后重复相关验证，不能把缺凭据或无法观测写成通过。

## 回滚及资料

按本次备份回滚。Remove-Protection、Restore-System-DNS模板是历史撤销脚本，未经适配不要运行，会取消保护。DNS回滚仅恢复本次网卡DNS/策略/本组规则/任务，保留主代理与应用保护；恢复旧Sakura不是默认目标。

技能不含二进制、秘密、完整第三方业务路由器或登录数据；缺失时说明具体缺口。

版本变化可核对：[Desktop代理](https://claude.com/docs/third-party/claude-desktop/network-proxy)、[Code环境变量](https://code.claude.com/docs/en/env-vars)、[Node代理](https://nodejs.org/api/http.html#built-in-proxy-support)、[sing-box DoH](https://sing-box.sagernet.org/configuration/dns/server/https/)、[hosts](https://sing-box.sagernet.org/configuration/dns/server/hosts/)、[Chromium代理](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md)。



审计 Session 0 的进程命令行可能需要管理员只读权限；普通权限无法读取时应标为 unknown，不能据此认定任务未运行。正常 UAC 后再次运行 Audit-State.ps1 才能完成这项核验。



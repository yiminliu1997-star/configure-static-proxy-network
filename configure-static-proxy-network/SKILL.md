---
name: configure-static-proxy-network
description: 在 Windows 上配置用户指定的 通用静态出口 IP，包含首次搭建、迁移、代理、防绕行、DNS 和无窗口守护。通用迁移版；先收集目标出口与接入参数，不使用其他电脑的固定 IP 或凭据。
---

# 配置 通用静态 IP（通用迁移版）

此技能没有预设出口 IP。目标必须由用户提供或从其授权访问的 代理提供商控制台确认，不能把检测到的任意出口自动当作正确目标。说明里的路径、版本、SID是历史示例，迁移时重新发现。

## 先填参数，再配置网络

1. 获取用户购买的目标固定出口 IP、入口主机、入口端口。区分出口IP、上游接入点及本机监听地址。代理密码由用户在新机安全输入，不写进聊天或技能。
2. 原始 references/desired-state.json 的出口及入口字段为 null。所有运行脚本以 .template 结尾，不能直接运行或仅删除后缀使用。
3. 使用 Python 3 执行 scripts/materialize.py，必填 --exit-ip、--upstream-host、--upstream-port、--protocol、--check-url、--output；输出目录必须为技能外的新目录。示例语法见 [参数化与迁移](references/parameterization.md)。工具只生成配置副本，不连接代理、不安装、不更改系统网络。
4. 如果当前目录已经存在 parameters-filled.json，参数化步骤已完成；核对它与用户目标相符后继续。生成目录内仍需适配本机路径、用户、网卡、应用版本及传输协议，不是可直接批量执行的一键安装器。
5. 从生成副本读取 [配置步骤](references/setup.md)、[恢复流程](references/reconcile.md) 和 [踩坑指南](references/pitfalls.md)，备份后分阶段部署、测试。先确认提供商协议、认证和固定出口绑定规则；支持 HTTP、HTTPS、SOCKS5 的用户名密码模板，其他认证或协议先适配再验证。
6. 验收所有出口必须等于用户指定的目标。审计、DNS引导测试、Node Agent和脚本中使用同一目标。失败时报告实际观测与目标差异，不切换到其他出口或直连。

## 必须保留的边界

- 保持当前聊天和健康核心进程，不关闭主代理或断网来做测试。故障测试用独立端口。
- 保留ToDesk及其他无关配置；本方案只限制指定应用，不能宣称整机所有流量均受保护。
- 当前ChatGPT/Codex主程序及共享Node默认不加入与Claude/浏览器相同的防绕行规则。
- 不复制旧电脑credential.xml、Cookie、登录状态或秘密；本包不含二进制或业务提供商密钥。
- 用户路径、SID、网卡与程序版本必须重新发现。S4U/Session 0须先预检DPAPI和网络；失败时保留可用连接，不降低保护。
- 配置模板里的本机监听端口是默认设计值，冲突时必须统一调整所有引用；不能结束占用端口的陌生进程。
- 不擅自登录账户、更换套餐或付费IP。相同出口不保证服务端将新电脑识别为旧设备。
- 用户只询问或整理技能时不部署网络。旧报告不作为新机验证依据。

## 资源

- [参数化与迁移](references/parameterization.md)：首次使用必读。
- [配置步骤](references/setup.md)：从控制台到逐项验收。
- [恢复与核验](references/reconcile.md)：具体实现和回滚边界。
- [踩坑与排障](references/pitfalls.md)：历史证据及处理办法。
- [目标配置](references/desired-state.json)：原包留空，由参数化工具填充。
- scripts/materialize.py：只生成副本。
- scripts/Audit-State.ps1.template 和 assets/runtime/：模板，参数化后才生成原始扩展名。

出口检测使用用户选定的 HTTPS JSON 接口，响应须有顶层 ip 字符串；不要默认为提供商专用接口。生成文件仅供适配后部署，不在本次整理任务运行网络脚本。

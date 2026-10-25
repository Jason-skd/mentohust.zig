# mentohust.zig

一个使用 Zig 编写的锐捷校园网认证 client。项目复用
[rj-connect.zig](https://github.com/Jason-skd/rj-connect.zig) 的确定性协议引擎，
将协议动作连接到目标系统的网络、时钟、运行事实和生命周期，并作为长期运行的前台进程维持在线状态。

> 当前仓库已完成 M1/M2 针对 `rj-connect v0.1.1` 的 API 收敛迁移；生命周期尚未接入生产 CLI，
> 真实平台 adapter 与认证链路仍留待 M3，因此有效配置目前会以 `platform_adapter_unavailable` 退出。

## 项目概览

当前依赖的公开 `Session` 只覆盖目标 macOS 1.35 有线 EAP-MD5 profile。它负责协议算法、
私有字段构造、编号、状态转移、校验和终端通知；PEAP、Direct、SAM/SMP 与旧私有分支不属于
当前公开 client 交付路径。默认无限重试暂时性失败；用户可以限制每次掉线后追加的认证尝试次数。

项目把职责拆成以下边界：

| 边界 | 职责 |
| --- | --- |
| `rj-connect.zig` | 报文编解码、目标 profile 算法、认证状态机、会话动作、Deadline 和协议错误 |
| `mentohust.zig` | CLI、运行生命周期、重试调度、日志、平台能力注入和部署装配 |
| 系统适配层 | 原始 Ethernet、时钟、信号、watchdog，以及读取接口事实和 DHCP 租约 |
| 系统网络管理组件 | DHCP、IP、路由和 DNS 配置 |
| 使用者 | 指定网卡、凭据、服务名、目标部署所需运行事实和外部服务管理器 |

协议行为以锁定版本的 `rj-connect.zig` 契约为准。产品范围和验收边界以本仓库的
[ROADMAP.md](ROADMAP.md) 为准；网络 I/O、时钟、系统适配和部署差异仍由 client 提供。

client 向协议引擎注入 `Facts` 与 `Credentials`，并负责提供 Ethernet、时钟、事件等待、信号和 watchdog。
`Facts` 包含源 MAC、服务名、磁盘序列号、IPv6 槽、IPv4 租约、备用 DNS 文本和 OS 位宽；
client 如何在具体平台取得或组织这些值不属于协议引擎职责。

## 快速开始

构建 CLI 并运行测试：

```sh
zig build
zig build test
zig-out/bin/mentohust --help
```

M2 已实现以下配置契约：

| 配置 | CLI | 环境变量 | 默认值 |
| --- | --- | --- | --- |
| 网卡 | `-i, --interface` | `MENTOHUST_INTERFACE` | 必需 |
| 用户名 | `-u, --username` | `MENTOHUST_USERNAME` | 必需 |
| 密码 | 不接受 CLI 参数 | `MENTOHUST_PASSWORD` | 必需 |
| 认证方法 | `--method` | `MENTOHUST_METHOD` | `auto`，当前公开 profile 为 EAP-MD5 |
| 追加重试上限 | `--retry-limit` | `MENTOHUST_RETRY_LIMIT` | `unlimited` |
| 首次重试延迟 | `--backoff-initial` | `MENTOHUST_BACKOFF_INITIAL` | `1s` |
| 最大重试延迟 | `--backoff-max` | `MENTOHUST_BACKOFF_MAX` | `60s` |
| 关闭总时限 | `--shutdown-timeout` | `MENTOHUST_SHUTDOWN_TIMEOUT` | `5s` |

非密码配置按 CLI、环境变量、默认值的顺序解析；必需值缺失时可从交互终端补齐。密码接受
环境变量或关闭回显的终端提示。无终端且缺少必需值时，进程直接失败。

运行时约束如下：

- 必须显式指定网络接口；缺少接口时不会猜测。
- 密码不接受 CLI 明文参数，只从环境变量或关闭回显的终端提示读取。
- 凭据不持久化、不写日志；读取后会清除进程环境中的密码副本。
- client 不配置 IP、路由或 DNS；这些由系统网络管理组件负责。
- 收到 `SIGINT` 或 `SIGTERM` 后，在协议允许时只发送一次 Logoff；日志、取消、发送和清理共享
  一个硬总时限。
- 人类可读状态写入 stderr，覆盖认证、掉线、重试和最终退出类别。

退出状态：`0` 正常结束，`2` 配置或输入错误，`3` 认证拒绝，`4` 暂时失败预算耗尽，
`5` 安全、终端 I/O 或平台能力失败，`6` 内部错误，`130`/`143` 分别表示 `SIGINT`/`SIGTERM`。

真实认证与生产 adapter 尚未接入，因此不能把当前可执行文件部署为可用的校园网 client。
Padavan 仍是本仓库的部署目标，但 `rj-connect v0.1.1` 的公开 profile 只声明目标 macOS 1.35；
Padavan 兼容性必须在 M3/M4 通过真实联调后再声明。

## 开发验证

提交前执行：

```sh
zig fmt --check build.zig build.zig.zon src
zig build
zig build test
```

当前离线测试使用真实 EAP-MD5 Session 验证认证后持续驻留、网络帧与信号唤醒、绝对 deadline、
掉线恢复、预算重置、日志失败清理和 watchdog 保护的有界关闭。事件等待与具体平台 adapter
仍需在 M3 接入生产 CLI；测试通过不等于真实校园网兼容。

## 文档索引

- [ROADMAP.md](ROADMAP.md)：成品目标、范围、依赖边界、里程碑与发布验收。
- [CHANGELOG.md](CHANGELOG.md)：依赖迁移、行为变化和已知限制。
- [GLOSSARY.md](GLOSSARY.md)：项目运行生命周期、兼容承诺和配置安全术语。
- [rj-connect.zig](https://github.com/Jason-skd/rj-connect.zig)：认证协议引擎与协议研究资料的权威来源。

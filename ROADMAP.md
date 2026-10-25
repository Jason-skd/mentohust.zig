# MentoHUST Zig

## 成品目标

交付一个可移植、长期运行的锐捷校园网认证 CLI。它复用 `rj-connect.zig` 的确定性协议引擎，
在目标系统上完成原始 Ethernet 收发、运行事实采集、在线维持、重试和有界关闭，并由外部
服务管理器托管进程。

当前依赖 `rj-connect v0.1.1` 的公开 `Session` 是目标 macOS 1.35 有线 EAP-MD5 profile。
它负责算法细节、私有字段、状态转换、报文构造和校验；client 负责平台能力、运行事实、凭据
和部署差异。PEAP、Direct、SAM/SMP 与旧私有分支留在依赖的研究模块，不属于当前公开交付接口。

## 范围与支持承诺

### 当前版本功能

- 提供前台运行的 CLI，暂不承诺稳定的公共库 API。
- 仅把 `rj-connect v0.1.1` 公开目标 EAP-MD5 profile 作为当前认证路径。
- client 注入 `Facts`（源 MAC、服务名、磁盘序列号、IPv6、IPv4 租约、备用 DNS 文本和 OS 位宽）
  与凭据；client 如何取得这些值属于平台 adapter 和部署装配。
- client 负责原始 Ethernet、时钟、信号、watchdog、重试调度、日志和进程生命周期。
- 系统网络管理组件负责 DHCP、IP、路由和 DNS 配置；client 不修改这些状态。
- 默认无限重试；用户可以限制每次掉线后的追加尝试次数。
- 凭据拒绝、配置错误和不支持的 EAP 方法属于不可恢复失败，直接退出并返回可区分状态。

### 配置与安全边界

- 网络接口必须显式指定；用户名和密码按 CLI、环境变量、交互提示的既有优先级解析。
- 密码不接受 CLI 明文参数，不持久化或写入日志；读取后清除环境和临时缓冲副本。
- client 不自行实现通用协议算法；协议算法由 `rj-connect` 负责，平台与部署差异由 adapter 注入。
- `SIGINT` 和 `SIGTERM` 触发有界优雅退出；协议允许时发送一次 Logoff。

### 部署与支持边界

- Padavan 仍是本仓库计划中的首个真实部署环境，但 v0.1.1 公共 profile 的目标证据来自 macOS 1.35。
- Padavan、Linux/mipsel 或其他部署不得因编译通过而声明兼容，必须完成真实服务器联调和验收。
- 任何未实测的认证路径、平台和校园网部署都明确列为兼容边界。

## 验收要求

- 开发机完成目标 EAP-MD5 profile 的端到端 adapter 协作和自动化验证。
- 自动化验证覆盖 facts 缺失/非法、凭据优先级、无终端缺凭据、暂时性失败重试、重试预算耗尽、
  错误凭据、掉线和有界优雅退出。
- 真实部署验收记录硬件、架构、内核、固件、认证路径和已测校园网环境。
- 未实测的 profile、平台和部署明确写入发布限制。
- `zig fmt --check build.zig build.zig.zon src`、`zig build` 和 `zig build test` 通过。

## 里程碑

### M0：产品边界与文档

- 状态：已实施（01822e6）
- 交付：README、ROADMAP、CHANGELOG 和术语表定义成品、职责和安全边界。

### M1：依赖集成与平台缝

- 状态：已实施（469a4bf）
- 目标：锁定 `rj-connect v0.1.1` 与 `zig-clap`，建立 Ethernet、运行 facts、时钟、信号和
  watchdog 的 client adapter 边界及协作测试。旧 TLS/MSCHAPv2/PEAP 端口随公开 API 收敛移除。

### M2：CLI 与长期运行生命周期

- 状态：已实施（a6afde2）；生产 CLI 集成待 M3
- 目标：完成参数、凭据来源、目标 profile 初始化、重试预算、指数退避、日志和有界退出，并覆盖
  当前公开 profile 的失败分类。旧的动态凭据、DHCP、TLS、MSCHAPv2 和 Direct action 流程不再属于
  当前 client 生命周期。
- 验收：认证成功后持续驻留；网络与信号及时唤醒；绝对 deadline 不因伪唤醒重置；掉线恢复后
  重置预算；日志和清理失败可区分，信号关闭受硬总时限保护。

### M3：真实认证链路

- 状态：待实施
- 目标：实现平台 adapter 和可中断事件等待，读取接口和 `Facts`，注入凭据，驱动 v0.1.1 EAP-MD5 Session，完成
  Ethernet 收发、服务器帧处理和真实服务器联调。若目标部署需要不同算法或字段，不在 client 中
  复制协议细节，应先由 `rj-connect` 提供明确 profile 或能力边界。

### M4：部署验收

- 状态：待实施，受 M3 真实联调阻塞
- 目标：先确认目标 profile 与 Padavan/实际校园网的兼容性；只有真实认证、持续在线、掉线恢复和
  有界关闭均通过后，才能发布对应平台和部署的版本承诺。

## 目标变更

- `rj-connect v0.1.1` 将公开 Session 收敛为目标 macOS 1.35 EAP-MD5 profile；本仓库同步移除
  对 PEAP、Direct、SAM/SMP、TLS 和 MSCHAPv2 公开 action/adapter 的依赖。
- 已实施的 M1/M2 需要针对该破坏性 API 变更回补；未实施的 M3/M4 改为 facts 装配、目标 profile
  联调和部署兼容性验证，不再规划两条公开认证路径。
- Padavan 仍是部署目标，但不再被文档预先视为与 macOS 1.35 profile 兼容；兼容性由 M3/M4 证据决定。

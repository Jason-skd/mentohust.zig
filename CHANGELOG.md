## a6afde2

### Fixed

- 认证成功后没有协议 deadline 时继续等待网络或信号，不再以 `NoProgress` 退出。
- 网络可读、信号和超时由同一等待端口处理；退避可被信号中断，伪唤醒不重置绝对 deadline。
- 恢复成功后重置追加重试预算；正常运行日志失败、等待失败及清理失败保留可区分的最终状态。
- 关闭日志、取消和 Logoff 共用信号到达时的总期限；发送失败或清理超时不再报告关闭完成。

### Tests

- 增加真实 EAP-MD5 Session 的驻留、提前收包、超时、掉线恢复、预算重置、日志失败和信号关闭回归；
  阻塞 Logoff 使用有界事件同步验证 watchdog 武装顺序。

### Limits

- 本次只完成平台无关 M2 模块及等待契约；生产等待器、系统 adapter 与 CLI 装配仍属 M3。

## 469a4bf

### Changed

- `rj-connect` 依赖从 `v.0.1.0` 固定到 `v.0.1.1`，并记录 Zig 包 hash 以保持可复现构建。
- 同步 v0.1.1 的破坏性公开 API：Session 初始化改为注入 `Facts` 与 `Credentials`，生命周期只处理
  `send_frame`，平台端口收敛为 Ethernet、facts、时钟、信号和 watchdog。
- CLI 不再宣称公开支持 PEAP；PEAP、Direct、SAM/SMP、TLS 和 MSCHAPv2 研究分支不属于当前
  client 交付接口。

### Fixed

- 回补 M1/M2 中对旧 Session Config、外部凭据请求、DHCP/TLS/MSCHAPv2 action 和 Direct 状态的依赖，
  使默认构建与测试重新通过。

### Limits

- v0.1.1 公开 profile 的目标证据来自 macOS 1.35 有线 EAP-MD5；Padavan/Linux/mipsel 兼容性仍待
  M3/M4 真实 adapter 和服务器联调，不因离线测试或编译通过而宣称支持。
- 生命周期模块尚未接入生产 CLI；具体平台 adapter 与真实认证链路仍待 M3。

## 3c7fbc9

### Fixed

- 关闭信号现在先武装 watchdog，再让取消、Logoff、TLS、网络、终端和日志清理共享硬总时限；
  超时或清理失败仍保留原始 `SIGINT`/`SIGTERM` 退出状态。
- 日志写入失败不再阻断协议取消和 Logoff；正常运行中的日志故障在清理后以内部错误退出。
- 配置、终端 I/O、OOM、认证拒绝、重试耗尽、安全和内部故障使用可区分的退出状态与最终日志类别。
- 密码从环境变量读取后立即清除环境和临时缓冲副本；密码提示期间处理终止信号并恢复终端回显。
- 平台端口统一接收绝对 deadline，`mentohust` 版本改为从 `build.zig.zon` 派生。

### Tests

- 增加阻塞 adapter/watchdog、日志失败清理、安全失败、配置失败、内部失败、全部终止分支、
  环境密码清除和退出码分类覆盖。

### Limits

- 生命周期模块尚未接入生产 CLI；具体 watchdog 与系统 adapter 仍留待 M3。
- 正式构建验收平台为 macOS 与 Linux/mipsel，Windows 不在当前支持矩阵。

## 7b3a233

### Added

- 实施 M2：新增 `mentohust` CLI，使用 `zig-clap` 解析网卡、用户名、认证方法、
  重试预算、指数退避和关闭时限，并按 CLI、环境变量、默认值顺序解析配置。
- 密码只从 `MENTOHUST_PASSWORD` 或关闭回显的终端提示读取；无终端且缺少必需值时直接失败。
- 新增平台无关的长期运行生命周期：认证动作调度、暂时失败重试、在线后预算重置、
  重认证、可区分失败分类、单次 Logoff 和有界关闭。
- 新增可注入的人类可读 stderr 日志，覆盖认证、掉线、重试、重认证和关闭状态。

### Usage

- `zig build` 生成 `zig-out/bin/mentohust`；`zig build test` 验证配置、失败分类、
  重试预算、重认证动作适配、信号关闭和日志。
- 运行 `zig-out/bin/mentohust --help` 查看当前参数；密码不从命令行传递。
- 退出状态为 `0` 正常结束、`2` 配置错误、`3` 认证拒绝、`4` 暂时失败预算耗尽、
  `5` 安全或平台依赖失败、`6` 内部错误、`130`/`143` 对应 `SIGINT`/`SIGTERM`。

### Limits

- 真实 Ethernet、TLS、MSCHAPv2、系统网络、时钟和信号 adapter 尚未接入；有效配置目前以
  `platform_adapter_unavailable` 和状态 `5` 退出，不能用于真实校园网认证。
- PEAP 部署材料参数推迟到 M3，与真实认证链路一起确定和验证。

## 90067a7

### Changed

- 默认 `zig build` 编译 M1 模块；尚未实现的模板 CLI 入口推迟到 M2 引入。
- 应用模块和包身份统一使用 `mentohust` 名称。
- `coordinator.dispatch` 从产生动作的 `Outcome` 取得 generation 和 action，并拒绝越界动作。
- MSCHAPv2 验证 adapter 返回验证结论和客户端成功响应载荷，不再回显服务器请求数据。

### Tests

- 协作测试断言实际发送帧、TLS 输入、MSCHAPv2 challenge 和凭据，以及各系统端口的错误身份。

### Usage

- `zig build` 验证模块编译；`zig build test` 验证依赖、端口契约和 adapter 协作。

### Limits

- 仍未实现认证 CLI 和具体平台 adapter；离线测试不证明真实校园网认证或 Padavan 部署已经通过。

## e248a46

### Added

- 实施 M1：建立原始 Ethernet、系统网络状态、TLS、MSCHAPv2、时钟和信号的系统端口，以及
  `rj-connect` Session 动作到这些端口的桥接。
- 使用真实协议 Session 覆盖 EAP-MD5、PEAPv0 / EAP-MSCHAPv2、DHCP、取消、stale generation、
  adapter 错误传播和直接通信生命周期动作的协作测试。

### Changed

- 依赖固定到包含 `LICENSE` 的 `rj-connect.zig` `v.0.1.0` tag 和 `zig-clap` 的可编译上游
  提交；`zig-clap` 的 `0.12.0` tag 不兼容当前 Zig 0.18。

### Usage

- `zig build test` 现在验证依赖解析、端口契约和 adapter 协作，但仍没有可运行的认证命令。

### Limits

- 尚未实现具体平台的原始 Ethernet、DHCP 读取、TLS、MSCHAPv2、时钟和信号 adapter。
- 离线协作测试不证明真实校园网认证或 Padavan 部署已经通过。

## 01822e6

### Added

- 补齐项目概览、成品范围、跨平台承诺、运行契约、验收要求、实施里程碑和术语表。
- 明确项目交付长期运行的认证 CLI，支持 EAP-MD5 与 PEAPv0 / EAP-MSCHAPv2。

### Usage

- 当前仓库仍是项目模板，尚无认证命令；只可运行 `zig build test` 验证模板。
- 计划中的 CLI 要求显式指定网络接口。密码不接受明文命令行参数，只从环境变量或关闭回显的
  终端提示读取。
- 默认在暂时性故障后无限重试，也可限制每次掉线后的追加尝试次数；不可恢复失败直接退出。

### Limits

- 认证 client 尚未实现，`0.0.0` 版本不提供真实网络认证能力。
- `v0.1.0` 的开发验收和真实部署验收尚待完成；当前没有已经验证通过的校园网或路由器型号。
- 目标平台覆盖具备所需系统能力的 Zig 目标，但首版计划只在 Padavan 验收环境完成真实部署验证。
- 不同校园网的私有字段、认证方法和部署参数可能不同，单个环境通过不等于其他环境兼容。

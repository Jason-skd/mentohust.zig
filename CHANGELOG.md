# Changelog

## v0.1.0

首个发布版本。`mentohust.zig` 提供现代化 Ruijie（锐捷）校园网认证 CLI，当前交付 `macos` 与
`mentohust` 两个有线 EAP-MD5 profile。

### Added

- 生产 CLI、配置解析、凭据输入、状态日志、重试策略、可中断等待和硬时限关闭。
- macOS BPF 与 Linux `AF_PACKET` 原始 Ethernet adapter。
- 认证、在线驻留、暂时性故障重试、重认证、信号关闭和单次 Logoff 生命周期。
- `--profile` 及 `macos`、`mentohust` 两个公开协议路径。
- Linux/mipsel 静态 musl 交叉构建、运行集成测试和真实接口验收能力。
- MIT 许可证和独立贡献指南。

### Usage

```sh
zig build
sudo zig-out/bin/mentohust --interface en0 --username alice
```

Padavan 或 legacy 部署：

```sh
sudo zig-out/bin/mentohust --interface eth0 --username alice --profile mentohust
```

非密码项按 CLI、环境变量、默认值依次解析：

| 配置          | CLI                  | 环境变量                     | 默认值                        |
| ------------- | -------------------- | ---------------------------- | ----------------------------- |
| 网卡          | `-i, --interface`    | `MENTOHUST_INTERFACE`        | 必需                          |
| 用户名        | `-u, --username`     | `MENTOHUST_USERNAME`         | 必需                          |
| 密码          | 不接受 CLI 参数      | `MENTOHUST_PASSWORD`         | 必需                          |
| 认证方法      | `--method`           | `MENTOHUST_METHOD`           | `auto`；当前仅 `auto` / `md5` |
| profile       | `--profile`          | `MENTOHUST_PROFILE`          | `macos`；可设 `mentohust`     |
| 追加重试上限  | `--retry-limit`      | `MENTOHUST_RETRY_LIMIT`      | `unlimited`                   |
| 首次重试延迟  | `--backoff-initial`  | `MENTOHUST_BACKOFF_INITIAL`  | `1s`                          |
| 最大重试延迟  | `--backoff-max`      | `MENTOHUST_BACKOFF_MAX`      | `60s`                         |
| 关闭总时限    | `--shutdown-timeout` | `MENTOHUST_SHUTDOWN_TIMEOUT` | `5s`                          |
| 服务名        | `--service-name`     | `MENTOHUST_SERVICE_NAME`     | 空；最多 32 字节 GBK 原始字节 |
| 磁盘序列号    | `--disk-serial`      | `MENTOHUST_DISK_SERIAL`      | 空；最多 64 字节可打印 ASCII  |
| 备用 DNS 文本 | `--alternate-dns`    | `MENTOHUST_ALTERNATE_DNS`    | 空；最多 247 字节可打印 ASCII |
| DHCP 标志     | `--dhcp`             | `MENTOHUST_DHCP`             | `disabled`；可设 `enabled`    |
| 网关          | `--gateway`          | `MENTOHUST_GATEWAY`          | `0.0.0.0`                     |
| DNS           | `--dns`              | `MENTOHUST_DNS`              | `0.0.0.0`                     |

密码最多 240 字节。密码提示关闭终端回显；环境变量副本在解析后清除。client 不配置 DHCP、IP、
路由或 DNS。原始 Ethernet 在 Linux 上需要 root 或 `CAP_NET_RAW`，在 macOS 上需要 BPF 权限。

退出码：`0` 正常结束、`2` 配置/输入错误、`3` 认证拒绝、`4` 重试预算耗尽、`5` 平台能力或
安全失败、`6` 内部错误，`130` / `143` 对应 `SIGINT` / `SIGTERM`。

### Validation

- `zig fmt --check build.zig build.zig.zon src`、`zig build` 和 `zig build test` 通过。
- `zig build check -Dtarget=mipsel-linux-musleabi -Doptimize=ReleaseSafe` 通过。
- 公开 EAP-MD5 profile 已完成真实接口认证和优雅关闭验收；具体验收环境不进入公开文档。

### Limits

- 当前只公开 EAP-MD5 的 `macos` 与 `mentohust` profile；PEAP、Direct、SAM/SMP、TLS 和
  MSCHAPv2 不属于 `v0.1.0` 公开接口。
- 不同校园网可能使用不同认证方法或私有字段，部署前应确认当前 profile 是否适用。
- 长时间在线、真实掉线恢复、预算重置和重连稳定性仍待后续版本验收。
- 持久安装、升级和回滚流程尚未形成发布验收结论；应用应由外部服务管理器托管。
- `macos` facts 中的部署字段由使用方提供；接口地址、网关、DNS 和 DHCP 标志不被验证为同一租约。
- `getifaddrs()` 无法取消，macOS facts 的 deadline 是返回前检查的尽力而为上限。

## e06ba91

### Changed

- macOS facts adapter 现在显式区分运行时接口观测（源 MAC、IPv4/掩码、IPv6、OS 位宽）和部署输入
  （服务名、磁盘序列号、DHCP 标志、网关、DNS、备用 DNS 文本）；协议 `Lease` 中混排的字段只在
  组合时形成，不表示 client 读取了 DHCP 租约。
- 接口存在多个 IPv4 地址时，按网络字节序选择数值最小的地址，掩码随所选地址；该规则有独立行为测试。
- macOS facts 只在开始认证尝试前和需要生成 EAP Request 响应前刷新。Success、Failure、Logoff
  及不需要响应的帧不再读取系统接口。
- 普通 adapter 操作使用独立的 5 秒总期限，关闭发送仍使用 `--shutdown-timeout` 共享总期限。
  `retry_scheduled` 日志字段改为 `retry_attempt`，避免与首次总尝试混淆。
- Runtime 启动快照直接用于 Session 初始化，不再重复读取 facts；`main` 只负责装配和退出码，
  profile 到 Session 的构造移入独立函数。

### Fixed

- 普通发送或 facts 读取遇到 `DeadlineExceeded` 时按暂时性故障清理并重试，不再误分类为内部错误。
- facts 读取在执行后再次检查 deadline；超过期限会返回 `DeadlineExceeded`。由于 `getifaddrs()`
  进入后无法中断，该期限仍是返回前检查的尽力而为上限。

### Tests

- 增加多 IPv4 地址选择、EAP Request-only facts 刷新、facts/发送期限传递、普通发送超时重试、
  facts 超时重试及过期 deadline 优先失败覆盖。
- 明确 fake watchdog 测试只验证生命周期武装顺序；真实硬退出继续由独立进程 probe 覆盖。
  测试名称和失败分类名称不再绑定过期的 `v0.1.1` 字面量。

### Limits

- 接口运行时快照不读取 DHCP 租约，也不验证 IPv4 地址、网关或 DNS 是否属于同一租约。
- `getifaddrs()` 无法取消；facts deadline 不能抢占已经进入的系统调用。

## c1f019b

### Added

- 生产 CLI 现在读取接口 facts、注入凭据并驱动 v0.1.1 EAP-MD5 Session，不再在有效配置后直接
  返回 `platform_adapter_unavailable`。
- Linux 使用绑定显式接口的非阻塞 `AF_PACKET`，macOS 使用 BPF；接收过滤覆盖 EAPOL、目标 MAC
  和本机回显，BPF 保留同一读取批次中的全部记录并拒绝截断。
- 网络等待和退避统一等待内核信号队列与绝对 deadline。终端提示复用同一信号源；watchdog
  使用可唤醒并回收的线程，在关闭操作阻塞时执行硬退出。
- 读取接口 MAC、IPv4/掩码、IPv6 和 OS 位宽，在每次尝试及处理服务器帧前刷新快照。
  增加服务名、磁盘序列号、DHCP 标志、网关、DNS 和备用 DNS 文本的显式部署参数。

### Usage

构建需要目标平台的 libc。macOS 使用系统 SDK，Linux/mipsel 的 musl 交叉编译命令为：

```sh
zig build check -Dtarget=mipsel-linux-musleabi
```

完整 CLI 配置契约如下；非密码项按 CLI、环境变量、默认值依次解析：

| 配置          | CLI                  | 环境变量                     | 默认值                                        |
| ------------- | -------------------- | ---------------------------- | --------------------------------------------- |
| 网卡          | `-i, --interface`    | `MENTOHUST_INTERFACE`        | 必需                                          |
| 用户名        | `-u, --username`     | `MENTOHUST_USERNAME`         | 必需                                          |
| 密码          | 不接受 CLI 参数      | `MENTOHUST_PASSWORD`         | 必需                                          |
| 认证方法      | `--method`           | `MENTOHUST_METHOD`           | `auto`；`auto` / `md5` 均使用当前公开 profile |
| 追加重试上限  | `--retry-limit`      | `MENTOHUST_RETRY_LIMIT`      | `unlimited`                                   |
| 首次重试延迟  | `--backoff-initial`  | `MENTOHUST_BACKOFF_INITIAL`  | `1s`                                          |
| 最大重试延迟  | `--backoff-max`      | `MENTOHUST_BACKOFF_MAX`      | `60s`                                         |
| 关闭总时限    | `--shutdown-timeout` | `MENTOHUST_SHUTDOWN_TIMEOUT` | `5s`                                          |
| 服务名        | `--service-name`     | `MENTOHUST_SERVICE_NAME`     | 空；最多 32 字节 GBK 原始字节                 |
| 磁盘序列号    | `--disk-serial`      | `MENTOHUST_DISK_SERIAL`      | 空；最多 64 字节可打印 ASCII                  |
| 备用 DNS 文本 | `--alternate-dns`    | `MENTOHUST_ALTERNATE_DNS`    | 空；最多 247 字节可打印 ASCII                 |
| DHCP 标志     | `--dhcp`             | `MENTOHUST_DHCP`             | `disabled`；可设 `enabled`                    |
| 网关          | `--gateway`          | `MENTOHUST_GATEWAY`          | `0.0.0.0`                                     |
| DNS           | `--dns`              | `MENTOHUST_DNS`              | `0.0.0.0`                                     |

必需配置缺失时可从终端补齐；无终端则直接失败。密码最多 240 字节，终端输入关闭回显，
读取后清除环境和临时缓冲副本；配置持有的密码在退出时清零。服务名不自动从 UTF-8 转码为 GBK。

网关、DNS 和 DHCP 标志由使用者或外部网络管理服务提供，未提供时按上述默认值注入；这些字段
不是自动检测到的 DHCP 租约。IPv4 地址尚未配置时地址/掩码为零，IPv6 缺失时对应槽为空。
client 不获取租约、不配置 IP、路由或 DNS，也不自动取得磁盘序列号。

Linux 原始 Ethernet 需要 root 或 `CAP_NET_RAW`；macOS 需要访问 BPF 设备的权限。BPF 在持有
描述符期间申请混杂接收以捕获发现多播，并在关闭时释放。普通发送也有有界等待，关闭发送共享
生命周期的总 deadline。

退出码：`0` 正常结束、`2` 配置/输入错误、`3` 认证拒绝、`4` 重试预算耗尽、`5` 平台能力或安全失败、
`6` 内部错误，`130` / `143` 对应 `SIGINT` / `SIGTERM`。初始接口不存在、读取失败或原始网络权限不足
不会被报告为认证成功。

### Tests

- 行为测试覆盖部署参数优先级、非法 facts、缺失接口、facts 刷新及重试、帧筛选、BPF 多记录/截断、
  内核信号排队、网络 readiness、退避唤醒和绝对 deadline。
- 隔离进程验证 watchdog 硬退出、等待中的终止信号，以及真实 socket 描述符上的 EAP-MD5 Session
  交互、认证成功和单次 Logoff；伪终端验证密码输入不回显及中断后的回显恢复和缓冲清零。
- macOS 原生执行测试，Linux/mipsel 完成生产 CLI、测试和进程验收程序的交叉编译；不要求测试访问
  有特权的真实 Ethernet 接口。

### Limits

- M3 代码和自动化装配已实施，真实服务器联调待收尾；未验证真实网卡的原始收发、校园网持续在线、
  真实掉线恢复或 Padavan 硬件/固件。当前没有可宣布兼容的校园网部署。
- `rj-connect v0.1.1` 公开 profile 的目标证据来自 macOS 1.35；其他算法和私有字段需求应先由协议依赖
  提供明确能力，client 不复制协议实现。
- CLI 当前仅实现 macOS/Linux 的 Ethernet adapter。交叉编译使用 musl，并不代表 Padavan 的
  内核、ABI、系统 libc 或认证服务器已经兼容；原生 Linux 执行和实际设备部署仍待验证。

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

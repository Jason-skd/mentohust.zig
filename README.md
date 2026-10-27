# mentohust.zig

使用 Zig 编写的锐捷校园网认证 CLI，复用
[rj-connect.zig](https://github.com/Jason-skd/rj-connect.zig) 的确定性协议引擎，
作为前台进程处理 Ethernet 收发、在线驻留、掉线重试和有界退出。

## 项目概览

当前锁定 `rj-connect v0.1.2`，公开 `Session` 提供两个具名有线 EAP-MD5 profile：`macos` 与
`mentohust`。M3 的平台 adapter、生产 CLI 装配和 Padavan/eth3 legacy profile 实机认证已完成；
已测组合在认证成功后 2 秒内恢复外网，并完成有界关闭。持续在线、真实掉线恢复和更大范围部署
覆盖仍属 M4 待验收项。

| 边界 | 职责 |
| --- | --- |
| `rj-connect.zig` | 协议算法、私有字段、报文编解码、Session 状态和 deadline |
| `mentohust.zig` | CLI、凭据、重试策略、日志、平台 adapter 和生命周期装配 |
| 平台 adapter | Linux packet socket / macOS BPF、接口 facts、单调时钟、信号队列和 watchdog |
| 系统网络管理组件 | DHCP、IP、路由和 DNS 配置 |
| 使用者 | 显式指定网卡、凭据和部署事实，由外部服务管理器托管进程 |

macOS profile 的 facts 来源必须区分。`rj-connect` 的 `Lease` 是协议表示，不代表 client
读取了 DHCP 租约：

| facts | 权威来源 |
| --- | --- |
| `source_mac`、`ip`、`netmask`、`ipv6_*`、`os_bits` | 指定接口的运行时快照 |
| `service_name`、`disk_serial`、`alternate_dns_text`、`dhcp_enabled`、`gateway`、`dns` | CLI / 环境变量中的显式部署配置 |

同一接口存在多个 IPv4 地址时，adapter 按网络字节序选择数值最小的 IPv4 地址，掩码随所选地址。
这一点是确定性选择规则，不表示 client 获取或验证了 DHCP 租约。

PEAP、Direct、SAM/SMP 不属于当前公开交付路径。密码只从环境变量或关闭回显的终端提示读取，
不接受 CLI 明文参数，不持久化、不写日志。默认无限重试暂时性失败；配置错误、凭据拒绝和
不支持的 EAP 方法以可区分状态退出。

## 快速开始

需要 `build.zig.zon` 指定的 Zig 0.18 开发版本，以及对应目标的 libc 头文件和库；macOS 使用系统 SDK。

```sh
zig build
zig build test
zig-out/bin/mentohust --help
```

在准备好联调的目标环境中运行，网卡名按实际设备替换；原始 Ethernet 需要 root 或相应系统权限：

```sh
sudo zig-out/bin/mentohust --interface en0 --username alice
# Padavan/旧 MentoHUST 兼容部署：
sudo zig-out/bin/mentohust --interface eth3 --username alice --profile mentohust
```

CLI 提示输入密码，认证成功后持续驻留。`SIGINT` / `SIGTERM` 唤醒网络等待或重试退避，
在协议允许时发送一次 Logoff，并以共享硬总时限完成关闭。

`--profile macos` 读取接口 MAC、IPv4/掩码、IPv6 和 OS 位宽，并接受服务名、磁盘序列号、
DHCP 标志、网关、DNS 和备用 DNS 文本等部署事实；`--profile mentohust` 只使用接口 MAC 和
凭据，不刷新 macOS facts。默认 profile 为 `macos`。完整参数、优先级、默认值和限制见
[CHANGELOG.md](CHANGELOG.md)。client 不配置系统 IP、路由或 DNS。

macOS facts 在开始一次认证尝试前读取；处理服务器帧时，只在需要生成 EAP Request 响应前刷新。
成功、失败、Logoff 和其他不需要响应的帧不读取 facts。普通 facts 读取和发送使用独立的 5 秒
routine adapter 总期限；关闭发送使用 `--shutdown-timeout` 的共享总期限。`getifaddrs()` 进入后
无法中断，因此 facts 读取的 deadline 是“返回前检查”的尽力而为上限，不是系统调用级抢占。

## 开发验证

```sh
zig fmt --check build.zig build.zig.zon src
zig build
zig build test
zig build check -Dtarget=mipsel-linux-musleabi
```

测试包含真实 EAP-MD5 Session 的重试与关闭协作、内核信号队列、描述符等待、BPF 批次解析、
伪终端密码输入与回显恢复，以及独立进程中的 watchdog 硬退出和 Ethernet adapter 协作。
所有并发验收都有明确的超时和资源清理边界。

本机 macOS 测试执行与 Linux/mipsel 交叉编译不证明真实原始接口收发、校园网认证或 Padavan 兼容；
这些仍需真实服务器、设备和固件联调。

## 文档索引

- [ROADMAP.md](ROADMAP.md)：成品目标、里程碑、范围和发布验收。
- [CHANGELOG.md](CHANGELOG.md)：版本变化、配置契约、用法和限制。
- [GLOSSARY.md](GLOSSARY.md)：产品边界、生命周期和安全术语。
- [rj-connect.zig](https://github.com/Jason-skd/rj-connect.zig)：目标协议 profile 与协议研究的权威来源。

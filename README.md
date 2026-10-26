# mentohust.zig

使用 Zig 编写的锐捷校园网认证 CLI，复用
[rj-connect.zig](https://github.com/Jason-skd/rj-connect.zig) 的确定性协议引擎，
作为前台进程处理 Ethernet 收发、在线驻留、掉线重试和有界退出。

## 项目概览

当前锁定的 `rj-connect v0.1.1` 公开 Session 对应目标 macOS 1.35 有线 EAP-MD5 profile。
M3 的平台 adapter 和生产 CLI 装配已实现；真实校园网服务器联调尚未完成，当前没有已经验收的
校园网、路由器或固件组合。Padavan 仍是首个计划部署环境，编译成功不构成兼容承诺。

| 边界 | 职责 |
| --- | --- |
| `rj-connect.zig` | 协议算法、私有字段、报文编解码、Session 状态和 deadline |
| `mentohust.zig` | CLI、凭据、重试策略、日志、平台 adapter 和生命周期装配 |
| 平台 adapter | Linux packet socket / macOS BPF、接口 facts、单调时钟、信号队列和 watchdog |
| 系统网络管理组件 | DHCP、IP、路由和 DNS 配置 |
| 使用者 | 显式指定网卡、凭据和部署事实，由外部服务管理器托管进程 |

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
```

CLI 提示输入密码，认证成功后持续驻留。`SIGINT` / `SIGTERM` 唤醒网络等待或重试退避，
在协议允许时发送一次 Logoff，并以共享硬总时限完成关闭。

接口 MAC、IPv4/掩码、IPv6 和 OS 位宽由 adapter 读取；服务名、磁盘序列号、DHCP 标志、
网关、DNS 和备用 DNS 文本由使用者提供。完整参数、优先级、默认值和限制见
[CHANGELOG.md](CHANGELOG.md)。client 不配置系统 IP、路由或 DNS。

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

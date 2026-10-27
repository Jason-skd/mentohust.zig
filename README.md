# mentohust.zig

## 项目简介

`mentohust.zig` 是一个面向 Ruijie（锐捷）校园网的认证 CLI 客户端，适合使用 EAP-MD5 认证、
又希望摆脱官方 GUI 客户端的用户。你可以在 macOS 终端、Linux 服务器、NAS 或路由器上运行它，
完成认证并让连接持续在线。

项目以现代 Zig 实现，认证协议追求与目标 Ruijie 客户端一比一复刻。对于当前支持的认证方式，
它可以作为官方客户端的非 GUI 替代方案：不需要桌面环境，适合 SSH、远程维护和无人值守运行。

与常见 MentoHUST 启动方式相比，`mentohust.zig` 不接受命令行密码参数，因此密码不会通过
`ps` 等进程列表泄漏；密码只由隐藏终端输入或受保护的环境变量提供，不写日志，也不持久化。

## 功能特性

- **无需 GUI**：在终端、服务器和路由器上完成校园网认证。
- **协议行为一致**：按一比一复刻目标实现认证报文和交互细节，尽量保持与官方客户端一致。
- **密码更安全**：不通过命令参数传密码，避免出现在进程列表、日志和持久化配置中。
- **适合自动化**：支持环境变量、稳定日志和可区分退出码，便于 systemd、procd 等服务管理器托管。
- **保持在线**：认证成功后持续驻留，暂时性故障时按退避策略自动重试。
- **关闭可控**：`Ctrl+C` 或 `SIGTERM` 会停止重试，在时限内发送 Logoff 并退出。
- **兼容旧环境**：提供 `mentohust` profile，用于 Padavan 和既有 MentoHUST 部署。
- **问题可定位**：认证拒绝、配置错误、权限不足和重试耗尽会返回不同状态。

## 快速开始

1. 将适用于本机架构的 `mentohust` 可执行文件放入 `PATH`。
2. 准备校园网账号和连接校园网的有线网卡名称；两者的说明见下方使用示例。
3. 运行程序，按提示输入密码，并让进程保持运行。

```sh
sudo mentohust --interface YOUR_INTERFACE --username YOUR_ACCOUNT
```

`YOUR_INTERFACE` 和 `YOUR_ACCOUNT` 都是占位符，需要替换成实际值。默认使用 `macos` profile；
Linux 或 Padavan 等 legacy 环境的完整命令见下方。

## 使用示例

### 常用使用方式

macOS 使用默认的 `macos` profile：

```sh
sudo mentohust --interface en0 --username YOUR_ACCOUNT
```

Linux 或 Padavan 使用 legacy profile：

```sh
sudo mentohust --interface eth0 --username YOUR_ACCOUNT --profile mentohust
```

Padavan 通常已经以 root 身份登录，可以省略 `sudo`。运行后终端会提示输入密码，输入内容不会
回显。认证成功后保持进程运行；需要停止时按 `Ctrl+C`，或向进程发送 `SIGTERM`。

### 完整使用指南

#### 查找正确的网卡

| 环境    | 查看命令                                                     | 应该选择                          |
| ------- | ------------------------------------------------------------ | --------------------------------- |
| macOS   | `networksetup -listallhardwareports`、`route -n get default` | 有线网络对应的接口，例如 `en0`    |
| Linux   | `ip route show default`                                      | 校园网默认路由中 `dev` 后面的接口 |
| Padavan | `ip route`、`nvram get wan0_ifname_t`                        | WAN 默认路由使用的接口            |

如果电脑同时连接 Wi-Fi，应选择连接校园网的**有线接口**。认证前还需要确保该接口已经取得 IP，
并且系统存在默认路由；本工具负责认证，不代替 DHCP 或系统网络配置。

#### 选择认证 profile

| profile     | 适用场景                                          |
| ----------- | ------------------------------------------------- |
| `macos`     | macOS 有线网络，默认值                            |
| `mentohust` | Padavan，以及按旧 MentoHUST 方式部署的 Linux 环境 |

当前版本面向 EAP-MD5。不同学校的认证方式和私有字段可能不同；如果服务器直接拒绝认证，应检查
账号、密码、profile 以及学校是否使用当前尚未支持的认证方式。

#### 安全提供密码

推荐直接使用隐藏的终端提示。需要交给 systemd、procd 等非交互服务托管时，应在服务配置中
注入 `MENTOHUST_PASSWORD`，并限制配置文件权限，不要把密码写进普通 shell 脚本或命令行参数。

在交互式 shell 中预置环境变量时，可以使用隐藏输入：

```sh
read -r -s MENTOHUST_PASSWORD
printf '\n'
export MENTOHUST_PASSWORD
sudo --preserve-env=MENTOHUST_PASSWORD \
  mentohust --interface eth0 --username YOUR_ACCOUNT --profile mentohust
unset MENTOHUST_PASSWORD
```

网卡和用户名也可以分别通过 `MENTOHUST_INTERFACE`、`MENTOHUST_USERNAME` 提供。完整参数、
默认值和限制见 [CHANGELOG.md](CHANGELOG.md)。

#### 权限、日志和退出

macOS 需要访问 BPF 设备；Linux 需要 root 或 `CAP_NET_RAW`。状态日志写入 stderr。

| 退出码        | 含义与处理建议                                       |
| ------------- | ---------------------------------------------------- |
| `0`           | 正常结束                                             |
| `2`           | 账号、网卡或其他配置无效，检查命令参数               |
| `3`           | 认证被服务器拒绝，检查账号、密码、profile 和认证方式 |
| `4`           | 暂时性故障达到重试上限，检查网络后重试               |
| `5`           | 网卡、权限或平台能力不可用                           |
| `6`           | 内部错误，保留日志用于排查                           |
| `130` / `143` | 收到 `Ctrl+C` / `SIGTERM`                            |

认证成功但仍无法访问网络时，继续检查系统 IP、网关、路由和 DNS。首次在某个校园网使用前，
建议保留原有认证方式作为回滚手段。

#### 兼容范围

当前公开 `macos` 与 `mentohust` 两个 EAP-MD5 profile，支持 macOS 和 Linux 的原始 Ethernet
adapter。兼容性由学校实际使用的认证方式决定；未支持的协议方法不会被宣称可用。

## 许可证信息

本项目使用 [MIT License](LICENSE)。

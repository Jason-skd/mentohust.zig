# Contributing to mentohust.zig

## 项目概览

`mentohust.zig` 是 Ruijie（锐捷）校园网认证 CLI client。协议计算由 `rj-connect.zig` 负责，
本仓库负责 CLI、平台 adapter、运行事实、凭据、日志和进程生命周期。

| 边界               | 职责                                                            |
| ------------------ | --------------------------------------------------------------- |
| `rj-connect.zig`   | 协议算法、私有字段、报文编解码、Session 状态和 deadline         |
| `mentohust.zig`    | CLI、配置、凭据、重试策略、日志和生命周期装配                   |
| 平台 adapter       | macOS BPF、Linux `AF_PACKET`、接口 facts、时钟、信号和 watchdog |
| 系统网络管理       | DHCP、IP、路由和 DNS 配置                                       |
| 使用者或服务管理器 | 指定接口、提供部署材料并托管前台进程                            |

仓库当前公开 `macos` 与 `mentohust` 两个有线 EAP-MD5 profile。长期产品边界以
[ROADMAP.md](ROADMAP.md) 为准，版本行为与限制以 [CHANGELOG.md](CHANGELOG.md) 为准。

## 技术栈与项目骨架

### 技术栈

- Zig 版本以 `build.zig.zon` 的 `minimum_zig_version` 为准。
- 协议依赖固定为 `rj-connect.zig v0.1.2`。
- CLI 解析使用固定上游 commit 的 `zig-clap`。
- 系统接口通过 `src/system.h` 转换为 Zig C ABI。

### 推荐工具链

- 安装 `build.zig.zon` 指定的 Zig 版本。
- macOS 开发使用系统 SDK；Linux 交叉构建使用 Zig 自带的 musl 头文件。
- 真实接口验收需要目标系统、原始 Ethernet 权限和实际校园网认证环境。

### 项目骨架

```text
build.zig                 Zig 构建、测试、运行和安装入口
build.zig.zon             包版本、依赖锁定和工具链版本
src/main.zig              CLI 装配和退出码
src/config.zig            CLI、环境变量和默认值解析
src/runtime.zig           adapter 运行时装配
src/ethernet.zig          BPF / AF_PACKET 原始 Ethernet 边界
src/lifecycle.zig         认证、驻留、重试和关闭状态推进
src/logging.zig           stderr 状态日志
src/*_test.zig            就近行为测试和进程级协作验收
```

## 开发验证

提交前至少运行：

```sh
zig fmt --check build.zig build.zig.zon src
zig build
zig build test
zig build check -Dtarget=mipsel-linux-musleabi -Doptimize=ReleaseSafe
```

测试覆盖 EAP-MD5 Session 的重试与关闭协作、内核信号队列、描述符等待、BPF 批次解析、终端
密码输入与回显恢复，以及独立进程中的 watchdog 硬退出和 Ethernet adapter 协作。

新增行为应在最近责任层获得测试。缺陷修复应包含能够复现原失败模式的回归场景。自动化测试和
交叉编译不能替代真实接口、校园网服务器或目标平台的兼容性验收。

## 文档索引

- [README.md](README.md)：用户定位、功能、快速开始和完整使用指南。
- [ROADMAP.md](ROADMAP.md)：成品目标、验收要求、里程碑和目标变更。
- [CHANGELOG.md](CHANGELOG.md)：按版本记录行为、配置、用法和已知限制。
- [GLOSSARY.md](GLOSSARY.md)：产品边界、生命周期和安全术语。
- [AGENTS.md](AGENTS.md)：仓库 AI 协作与工程治理。
- [rj-connect.zig](https://github.com/Jason-skd/rj-connect.zig)：协议 profile 和协议研究的权威来源。

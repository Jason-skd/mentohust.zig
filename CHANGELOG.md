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

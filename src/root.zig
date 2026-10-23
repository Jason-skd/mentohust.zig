//! Internal application modules. Public API stability is deferred until after
//! the `v0.1.0` CLI contract is implemented.

pub const coordinator = @import("coordinator.zig");
pub const platform = @import("platform.zig");
pub const config = @import("config.zig");

test {
    _ = coordinator;
    _ = platform;
    _ = config;
    _ = @import("dependencies_test.zig");
    _ = @import("coordinator_test.zig");
    _ = @import("config_test.zig");
}

//! Internal application modules. Public API stability is deferred until after
//! the `v0.1.0` CLI contract is implemented.

pub const coordinator = @import("coordinator.zig");
pub const platform = @import("platform.zig");
pub const config = @import("config.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const logging = @import("logging.zig");
pub const terminal = @import("terminal.zig");

test {
    _ = coordinator;
    _ = platform;
    _ = config;
    _ = lifecycle;
    _ = logging;
    _ = terminal;
    _ = @import("dependencies_test.zig");
    _ = @import("coordinator_test.zig");
    _ = @import("config_test.zig");
    _ = @import("lifecycle_test.zig");
    _ = @import("logging_test.zig");
}

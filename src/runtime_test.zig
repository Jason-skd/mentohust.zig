const builtin = @import("builtin");
const std = @import("std");
const runtime = @import("runtime.zig");
const system = @import("system.zig");
const c = system.c;

test "queued termination wakes backoff and is not consumed by waiting" {
    var signals = try runtime.Signals.init();
    defer signals.deinit();
    try std.testing.expect((try signals.tryNext()) == null);
    const sent = if (builtin.os.tag == .linux) c.raise(c.SIGTERM) else c.kill(c.getpid(), c.SIGTERM);
    try std.testing.expectEqual(@as(c_int, 0), sent);
    const deadline = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromSeconds(2));
    try signals.wait(std.testing.io, null, c.POLLIN, deadline);
    try signals.wait(std.testing.io, null, c.POLLIN, deadline);
    try std.testing.expectEqual(.terminate, (try signals.tryNext()).?);
    try std.testing.expect((try signals.tryNext()) == null);
}

test "wait preserves network readiness and expired deadlines return immediately" {
    var signals = try runtime.Signals.init();
    defer signals.deinit();
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_DGRAM, 0, &pair));
    defer system.close(pair[0]);
    defer system.close(pair[1]);
    try system.nonblocking(pair[0]);
    try std.testing.expectEqual(@as(isize, 5), c.write(pair[1], "ready", 5));
    const deadline = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromSeconds(2));
    try signals.wait(std.testing.io, pair[0], c.POLLIN, deadline);
    var buffer: [16]u8 = undefined;
    const count = c.read(pair[0], &buffer, buffer.len);
    try std.testing.expectEqual(@as(isize, 5), count);
    try std.testing.expectEqualStrings("ready", buffer[0..5]);
    try signals.wait(std.testing.io, pair[0], c.POLLIN, .zero);
}

test "runtime rejects invalid and missing interfaces before opening raw Ethernet" {
    var signals = try runtime.Signals.init();
    defer signals.deinit();
    try std.testing.expectError(error.InvalidInterface, runtime.Runtime.init(std.testing.io, &signals, &@as([256]u8, @splat('x')), .{}));
    try std.testing.expectError(error.FactsUnavailable, runtime.Runtime.init(std.testing.io, &signals, "m3-missing0", .{}));
}

test "facts read rejects an expired deadline before inspecting the interface" {
    var signals = try runtime.Signals.init();
    defer signals.deinit();
    var unavailable: runtime.Runtime = .{
        .io = std.testing.io,
        .signals = &signals,
        .name = @splat(0),
        .deployment = .{},
        .initial_facts = .{ .source_mac = @splat(0) },
        .ethernet = .{ .fd = -1, .source_mac = @splat(0) },
        .watchdog = .{ .io = std.testing.io },
    };
    try std.testing.expectError(error.DeadlineExceeded, unavailable.readFacts(.zero));
}

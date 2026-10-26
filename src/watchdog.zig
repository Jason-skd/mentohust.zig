//! Hard shutdown protection with a joined worker and no detached borrows.
const std = @import("std");
const platform = @import("platform.zig");

pub const Watchdog = struct {
    io: std.Io,
    canceled: std.Io.Event = .unset,
    thread: ?std.Thread = null,

    pub fn port(self: *Watchdog) platform.Watchdog {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn deinit(self: *Watchdog) void {
        self.disarm();
        self.* = undefined;
    }

    fn armAdapter(context: *anyopaque, timeout: platform.Duration, exit_code: u8) platform.Watchdog.Error!void {
        const self: *Watchdog = @ptrCast(@alignCast(context));
        self.disarm();
        if (timeout.toNanoseconds() <= 0) return error.WatchdogFailed;
        const deadline = std.Io.Clock.awake.now(self.io).addDuration(timeout);
        self.canceled.reset();
        self.thread = std.Thread.spawn(.{}, worker, .{ self, deadline, exit_code }) catch return error.WatchdogFailed;
    }

    fn worker(self: *Watchdog, deadline: std.Io.Timestamp, exit_code: u8) void {
        while (!self.canceled.isSet()) {
            if (std.Io.Clock.awake.now(self.io).compare(.gte, deadline)) std.process.exit(exit_code);
            self.canceled.waitTimeout(self.io, .{ .deadline = deadline.withClock(.awake) }) catch continue;
        }
    }

    fn disarm(self: *Watchdog) void {
        if (self.thread) |thread| {
            self.canceled.set(self.io);
            thread.join();
            self.thread = null;
        }
    }

    fn disarmAdapter(context: *anyopaque) void {
        const self: *Watchdog = @ptrCast(@alignCast(context));
        self.disarm();
    }
    const vtable: platform.Watchdog.VTable = .{ .arm = armAdapter, .disarm = disarmAdapter };
};

test "disarming a watchdog joins the worker and permits rearming" {
    var watchdog: Watchdog = .{ .io = std.testing.io };
    defer watchdog.deinit();
    const port = watchdog.port();
    try std.testing.expectError(error.WatchdogFailed, port.arm(.fromSeconds(0), 99));
    try port.arm(.fromSeconds(60), 99);
    port.disarm();
    try std.testing.expect(watchdog.thread == null);
    try port.arm(.fromSeconds(60), 99);
    port.disarm();
}

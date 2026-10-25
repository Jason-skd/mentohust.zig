const std = @import("std");
const config = @import("config.zig");
const lifecycle = @import("lifecycle.zig");
const platform = @import("platform.zig");
const rj = @import("rj-connect");

const Harness = struct {
    now: platform.Timestamp = timestamp(0),
    event_count: usize = 0,
    watchdog_arms: usize = 0,
    watchdog_disarms: usize = 0,

    fn ports(self: *Harness) platform.Ports {
        return .{
            .ethernet = .{ .context = self, .vtable = &ethernet_vtable },
            .network = .{ .context = self, .vtable = &network_vtable },
            .clock = .{ .context = self, .vtable = &clock_vtable },
            .stop = .{ .context = self, .vtable = &stop_vtable },
            .watchdog = .{ .context = self, .vtable = &watchdog_vtable },
        };
    }

    fn reporter(self: *Harness) lifecycle.Reporter {
        return .{ .context = self, .vtable = &reporter_vtable };
    }
};

fn timestamp(nanoseconds: i96) platform.Timestamp {
    return .fromNanoseconds(nanoseconds);
}

fn harness(context: *anyopaque) *Harness {
    return @ptrCast(@alignCast(context));
}

fn ethernetSend(_: *anyopaque, _: []const u8, _: platform.Deadline) platform.Ethernet.Error!void {}
fn ethernetReceive(_: *anyopaque, _: platform.Deadline) platform.Ethernet.Error!?[]const u8 {
    return null;
}
fn networkReadFacts(_: *anyopaque, _: platform.Deadline) platform.NetworkState.Error!rj.session.Facts {
    return .{ .source_mac = .{ 0, 1, 2, 3, 4, 5 } };
}
fn clockNow(context: *anyopaque) platform.Clock.Error!platform.Timestamp {
    return harness(context).now;
}
fn clockWaitUntil(context: *anyopaque, deadline: platform.Timestamp) platform.Clock.Error!void {
    harness(context).now = deadline;
}
fn stopTryNext(_: *anyopaque) platform.Stop.Error!?platform.Stop.Request {
    return .interrupt;
}
fn watchdogArm(context: *anyopaque, _: platform.Duration, _: u8) platform.Watchdog.Error!void {
    harness(context).watchdog_arms += 1;
}
fn watchdogDisarm(context: *anyopaque) void {
    harness(context).watchdog_disarms += 1;
}
fn reportEvent(context: *anyopaque, _: lifecycle.Event) lifecycle.Reporter.Error!void {
    harness(context).event_count += 1;
}

const ethernet_vtable: platform.Ethernet.VTable = .{ .send = ethernetSend, .tryReceive = ethernetReceive };
const network_vtable: platform.NetworkState.VTable = .{ .readFacts = networkReadFacts };
const clock_vtable: platform.Clock.VTable = .{ .now = clockNow, .waitUntil = clockWaitUntil };
const stop_vtable: platform.Stop.VTable = .{ .tryNext = stopTryNext };
const watchdog_vtable: platform.Watchdog.VTable = .{ .arm = watchdogArm, .disarm = watchdogDisarm };
const reporter_vtable: lifecycle.Reporter.VTable = .{ .write = reportEvent };

fn policy() lifecycle.Policy {
    return .{
        .backoff_initial = .fromSeconds(1),
        .backoff_max = .fromSeconds(8),
        .shutdown_timeout = .fromSeconds(5),
    };
}

test "tracker applies bounded exponential retry delays" {
    var tracker = try lifecycle.Tracker.init(.{
        .retry_limit = .{ .limited = 2 },
        .backoff_initial = .fromSeconds(1),
        .backoff_max = .fromSeconds(4),
        .shutdown_timeout = .fromSeconds(5),
    });
    const now = timestamp(0);
    try std.testing.expectEqual(@as(i96, std.time.ns_per_s), tracker.scheduleRetry(now).?.nanoseconds);
    try std.testing.expectEqual(@as(i96, 2 * std.time.ns_per_s), tracker.scheduleRetry(now).?.nanoseconds);
    try std.testing.expect(tracker.scheduleRetry(now) == null);
}

test "failure classification follows the v0.1.1 session contract" {
    try std.testing.expectEqual(
        lifecycle.FailureClass.authentication_rejected,
        lifecycle.classifyFailureReason(.server_failure),
    );
    try std.testing.expectEqual(
        lifecycle.FailureClass.transient,
        lifecycle.classifyFailureReason(.auth_timeout),
    );
    try std.testing.expectEqual(
        lifecycle.FailureClass.configuration,
        lifecycle.classifySessionError(error.InvalidFacts),
    );
}

test "signal shutdown remains bounded before the first authentication attempt" {
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .facts = .{ .source_mac = .{ 0, 1, 2, 3, 4, 5 } },
        .credentials = .{ .username = "alice", .password = "secret" },
    });
    defer session.deinit();

    var fake: Harness = .{};
    const ports = fake.ports();
    const termination = lifecycle.run(&session, ports, policy(), fake.reporter());
    try std.testing.expectEqual(lifecycle.Termination.signal, std.meta.activeTag(termination));
    try std.testing.expectEqual(platform.Stop.Request.interrupt, termination.signal);
    try std.testing.expectEqual(@as(usize, 1), fake.watchdog_arms);
    try std.testing.expectEqual(@as(usize, 1), fake.watchdog_disarms);
}

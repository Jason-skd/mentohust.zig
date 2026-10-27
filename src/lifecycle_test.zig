const std = @import("std");
const config = @import("config.zig");
const lifecycle = @import("lifecycle.zig");
const platform = @import("platform.zig");
const rj = @import("rj-connect");

const Wake = struct {
    after: platform.Duration = .zero,
    event: union(enum) {
        eap: []const u8,
        logoff,
        signal: platform.Stop.Request,
        timeout,
        spurious,
        receive_failure: platform.Ethernet.Error,
        wait_failure,
        stop_failure,
        clock_failure,
    },
};

const Harness = struct {
    now: platform.Timestamp = timestamp(0),
    events: [128]lifecycle.Event = undefined,
    event_count: usize = 0,
    watchdog_arms: usize = 0,
    watchdog_disarms: usize = 0,
    watchdog_exit_code: ?u8 = null,
    watchdog_timeout: ?platform.Duration = null,
    watchdog_error: bool = false,
    stop_immediately: bool = true,
    stop_after_receives: ?usize = null,
    pending_stop: ?platform.Stop.Request = null,
    stop_error: bool = false,
    clock_error: bool = false,
    receive_calls: usize = 0,
    wait_calls: usize = 0,
    waits: [128]platform.Wait.Options = undefined,
    script: []const Wake = &.{},
    script_index: usize = 0,
    receive_buffer: [512]u8 = undefined,
    queued_frame: ?[]const u8 = null,
    receive_error: ?platform.Ethernet.Error = null,
    facts_error: ?platform.NetworkState.Error = null,
    facts_calls: usize = 0,
    current_facts: rj.session.Facts = .{ .source_mac = .{ 0, 1, 2, 3, 4, 5 } },
    sent_types: [64]u8 = undefined,
    sent_at: [64]platform.Timestamp = undefined,
    send_count: usize = 0,
    logoff_count: usize = 0,
    cleanup_deadline: platform.Deadline = null,
    cleanup_send_error: ?platform.Ethernet.Error = null,
    cleanup_send_delay: platform.Duration = .zero,
    shutdown_report_delay: platform.Duration = .zero,
    failed_report: ?std.meta.Tag(lifecycle.Event) = null,
    blocked_cleanup: ?*BlockedCleanup = null,

    fn ports(self: *Harness) platform.Ports {
        return .{
            .ethernet = .{ .context = self, .vtable = &ethernet_vtable },
            .network = .{ .context = self, .vtable = &network_vtable },
            .clock = .{ .context = self, .vtable = &clock_vtable },
            .wait = .{ .context = self, .vtable = &wait_vtable },
            .stop = .{ .context = self, .vtable = &stop_vtable },
            .watchdog = .{ .context = self, .vtable = &watchdog_vtable },
        };
    }

    fn reporter(self: *Harness) lifecycle.Reporter {
        return .{ .context = self, .vtable = &reporter_vtable };
    }

    fn countEvents(self: *const Harness, tag: std.meta.Tag(lifecycle.Event)) usize {
        var count: usize = 0;
        for (self.events[0..self.event_count]) |event| {
            if (std.meta.activeTag(event) == tag) count += 1;
        }
        return count;
    }
};

const BlockedCleanup = struct {
    armed: std.atomic.Value(bool) = .init(false),
    observed_armed: std.atomic.Value(bool) = .init(false),
    send_started: std.Io.Event = .unset,
    release_send: std.Io.Event = .unset,

    fn releaseAfterSend(self: *BlockedCleanup) void {
        _ = waitBounded(&self.send_started);
        self.observed_armed.store(self.armed.load(.acquire), .release);
        self.release_send.set(std.testing.io);
    }
};

fn waitBounded(event: *std.Io.Event) bool {
    const io = std.testing.io;
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(2), .clock = .awake });
    while (!event.isSet()) {
        event.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => {
                if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) return false;
            },
            error.Canceled => return false,
        };
    }
    return true;
}

fn timestamp(nanoseconds: i96) platform.Timestamp {
    return .fromNanoseconds(nanoseconds);
}

fn harness(context: *anyopaque) *Harness {
    return @ptrCast(@alignCast(context));
}

fn ethernetSend(context: *anyopaque, frame: []const u8, deadline: platform.Deadline) platform.Ethernet.Error!void {
    const fake = harness(context);
    if (fake.send_count == fake.sent_types.len) return error.SendFailed;
    fake.sent_types[fake.send_count] = frame[15];
    fake.sent_at[fake.send_count] = fake.now;
    fake.send_count += 1;
    if (frame[15] == 2) {
        fake.logoff_count += 1;
        fake.cleanup_deadline = deadline;
        if (fake.blocked_cleanup) |blocked| {
            blocked.send_started.set(std.testing.io);
            if (!waitBounded(&blocked.release_send)) return error.SendFailed;
            return error.DeadlineExceeded;
        }
        fake.now = fake.now.addDuration(fake.cleanup_send_delay);
        if (fake.cleanup_send_error) |err| return err;
    }
}

fn ethernetReceive(context: *anyopaque, _: platform.Deadline) platform.Ethernet.Error!?[]const u8 {
    const fake = harness(context);
    fake.receive_calls += 1;
    if (fake.receive_error) |err| {
        fake.receive_error = null;
        return err;
    }
    const frame = fake.queued_frame;
    fake.queued_frame = null;
    return frame;
}

fn networkReadFacts(context: *anyopaque, _: platform.Deadline) platform.NetworkState.Error!rj.session.Facts {
    const fake = harness(context);
    fake.facts_calls += 1;
    if (fake.facts_error) |err| {
        fake.facts_error = null;
        return err;
    }
    return fake.current_facts;
}

fn clockNow(context: *anyopaque) platform.Clock.Error!platform.Timestamp {
    const fake = harness(context);
    if (fake.clock_error) {
        fake.clock_error = false;
        return error.ClockFailed;
    }
    return fake.now;
}

fn waitForEvent(context: *anyopaque, options: platform.Wait.Options) platform.Wait.Error!void {
    const fake = harness(context);
    if (fake.wait_calls == fake.waits.len) return error.WaitFailed;
    fake.waits[fake.wait_calls] = options;
    fake.wait_calls += 1;
    if (fake.script_index == fake.script.len) {
        if (fake.stop_after_receives != null) return;
        return error.WaitFailed;
    }
    const wake = fake.script[fake.script_index];
    fake.script_index += 1;
    fake.now = fake.now.addDuration(wake.after);
    switch (wake.event) {
        .eap => |bytes| fake.queued_frame = serverFrame(bytes, &fake.receive_buffer),
        .logoff => {
            fake.queued_frame = serverFrame(&.{}, &fake.receive_buffer);
            fake.receive_buffer[15] = 2;
        },
        .signal => |signal| fake.pending_stop = signal,
        .timeout => fake.now = options.deadline orelse return error.WaitFailed,
        .spurious => {},
        .receive_failure => |err| fake.receive_error = err,
        .wait_failure => return error.WaitFailed,
        .stop_failure => fake.stop_error = true,
        .clock_failure => fake.clock_error = true,
    }
}

fn stopTryNext(context: *anyopaque) platform.Stop.Error!?platform.Stop.Request {
    const fake = harness(context);
    if (fake.stop_error) {
        fake.stop_error = false;
        return error.SignalWaitFailed;
    }
    if (fake.pending_stop) |signal| {
        fake.pending_stop = null;
        return signal;
    }
    if (fake.stop_immediately) return .interrupt;
    if (fake.stop_after_receives) |count| {
        if (fake.receive_calls >= count) return .interrupt;
    }
    return null;
}

fn watchdogArm(context: *anyopaque, timeout: platform.Duration, exit_code: u8) platform.Watchdog.Error!void {
    const fake = harness(context);
    fake.watchdog_arms += 1;
    fake.watchdog_exit_code = exit_code;
    fake.watchdog_timeout = timeout;
    if (fake.watchdog_error) return error.WatchdogFailed;
    if (fake.blocked_cleanup) |blocked| blocked.armed.store(true, .release);
}

fn watchdogDisarm(context: *anyopaque) void {
    const fake = harness(context);
    fake.watchdog_disarms += 1;
    if (fake.blocked_cleanup) |blocked| blocked.armed.store(false, .release);
}

fn reportEvent(context: *anyopaque, event: lifecycle.Event) lifecycle.Reporter.Error!void {
    const fake = harness(context);
    if (event == .shutdown_started) fake.now = fake.now.addDuration(fake.shutdown_report_delay);
    if (fake.failed_report) |tag| {
        if (std.meta.activeTag(event) == tag) {
            fake.failed_report = null;
            return error.WriteFailed;
        }
    }
    if (fake.event_count == fake.events.len) return error.WriteFailed;
    fake.events[fake.event_count] = event;
    fake.event_count += 1;
}

const ethernet_vtable: platform.Ethernet.VTable = .{ .send = ethernetSend, .tryReceive = ethernetReceive };
const network_vtable: platform.NetworkState.VTable = .{ .readFacts = networkReadFacts };
const clock_vtable: platform.Clock.VTable = .{ .now = clockNow };
const wait_vtable: platform.Wait.VTable = .{ .wait = waitForEvent };
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

fn serverFrame(eap: []const u8, output: []u8) []const u8 {
    const header = [_]u8{ 0, 1, 2, 3, 4, 5, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x88, 0x8e, 1, 0, 0, @intCast(eap.len) };
    @memcpy(output[0..18], &header);
    @memcpy(output[18..][0..eap.len], eap);
    return output[0 .. 18 + eap.len];
}

fn authenticate(session: *rj.session.Session) !void {
    var started = try session.step(timestamp(0), .start);
    defer started.deinit(std.testing.allocator);
    const packets = [_][]const u8{
        &.{ 1, 1, 0, 5, 1 },
        &.{ 1, 2, 0, 22, 4, 16, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        &.{ 3, 2, 0, 4 },
    };
    for (packets) |packet| {
        var bytes: [64]u8 = undefined;
        var outcome = try session.step(timestamp(0), .{ .frame = .{
            .generation = session.currentGeneration(),
            .bytes = serverFrame(packet, &bytes),
        } });
        outcome.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(rj.session.Phase.authenticated, session.phase());
}

test "authenticated idle session stays resident until a shutdown signal" {
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .facts = .{ .source_mac = .{ 0, 1, 2, 3, 4, 5 } },
        .credentials = .{ .username = "alice", .password = "secret" },
    });
    defer session.deinit();
    try authenticate(&session);
    var fake: Harness = .{ .stop_immediately = false, .stop_after_receives = 2 };
    const termination = lifecycle.run(&session, fake.ports(), policy(), fake.reporter());
    try std.testing.expectEqual(lifecycle.Termination.signal, std.meta.activeTag(termination));
    try std.testing.expectEqual(@as(usize, 2), fake.receive_calls);
}

const identity = [_]u8{ 1, 1, 0, 5, 1 };
const challenge = [_]u8{ 1, 2, 0, 22, 4, 16, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
const success = [_]u8{ 3, 2, 0, 4 };

fn initSession() !rj.session.Session {
    return rj.session.Session.init(std.testing.allocator, .{
        .facts = .{ .source_mac = .{ 0, 1, 2, 3, 4, 5 } },
        .credentials = .{ .username = "alice", .password = "secret" },
        .max_start_attempts = 1,
    });
}

fn expectSignal(termination: lifecycle.Termination, signal: platform.Stop.Request) !void {
    try std.testing.expectEqual(lifecycle.Termination.signal, std.meta.activeTag(termination));
    try std.testing.expectEqual(signal, termination.signal);
}

test "facts are refreshed before start and server response" {
    var session = try initSession();
    defer session.deinit();
    var fake: Harness = .{
        .stop_immediately = false,
        .script = &.{
            .{ .event = .{ .eap = &identity } },
            .{ .event = .{ .signal = .terminate } },
        },
        .current_facts = .{ .source_mac = .{ 0, 1, 2, 3, 4, 5 }, .lease = .{ .ip = .{ 10, 1, 2, 3 } } },
    };
    const termination = lifecycle.run(&session, fake.ports(), policy(), fake.reporter());
    try expectSignal(termination, .terminate);
    try std.testing.expectEqual(@as(usize, 2), fake.facts_calls);
    try std.testing.expectEqual([4]u8{ 10, 1, 2, 3 }, session.factsSnapshot().?.lease.ip);
}

test "missing facts retry with a fresh snapshot and malformed facts stop before sending" {
    var session = try initSession();
    defer session.deinit();
    var fake: Harness = .{
        .stop_immediately = false,
        .facts_error = error.FactsUnavailable,
        .script = &.{
            .{ .event = .timeout },
            .{ .event = .{ .signal = .terminate } },
        },
    };
    try expectSignal(lifecycle.run(&session, fake.ports(), policy(), fake.reporter()), .terminate);
    try std.testing.expectEqual(@as(usize, 2), fake.facts_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.retry_scheduled));
    var invalid_session = try initSession();
    defer invalid_session.deinit();
    var invalid: Harness = .{ .stop_immediately = false, .current_facts = .{ .source_mac = .{ 0, 1, 2, 3, 4, 5 }, .os_bits = 0 } };
    const termination = lifecycle.run(&invalid_session, invalid.ports(), policy(), invalid.reporter());
    try std.testing.expectEqual(@as(u8, 2), termination.exitCode());
    try std.testing.expectEqual(@as(usize, 0), invalid.send_count);
}

test "network readiness authenticates before timeout and remains online without a deadline" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{
        .{ .after = .fromSeconds(1), .event = .{ .eap = &identity } },
        .{ .after = .fromSeconds(1), .event = .{ .eap = &challenge } },
        .{ .after = .fromSeconds(1), .event = .{ .eap = &success } },
        .{ .after = .fromSeconds(60), .event = .spurious },
        .{ .after = .fromSeconds(60), .event = .{ .signal = .terminate } },
    };
    var fake: Harness = .{ .stop_immediately = false, .script = &script };
    try expectSignal(lifecycle.run(&session, fake.ports(), policy(), fake.reporter()), .terminate);
    try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.online));
    try std.testing.expectEqual(@as(usize, 0), fake.countEvents(.protocol_failure));
    try std.testing.expectEqual(@as(usize, 5), fake.wait_calls);
    try std.testing.expect(fake.waits[3].deadline == null);
    try std.testing.expect(fake.waits[4].deadline == null);
    try std.testing.expect(fake.waits[0].receive);
    try std.testing.expectEqual(@as(i96, std.time.ns_per_s), fake.sent_at[1].nanoseconds);
    try std.testing.expectEqual(@as(i96, 2 * std.time.ns_per_s), fake.sent_at[2].nanoseconds);
    try std.testing.expectEqual(@as(usize, 1), fake.logoff_count);
    try std.testing.expectEqual(rj.session.Phase.idle, session.phase());
}

test "transient receive failure cancels backs off and authenticates again" {
    for ([_]platform.Ethernet.Error{ error.ReceiveFailed, error.InterfaceClosed }) |cause| {
        var session = try initSession();
        defer session.deinit();
        const script = [_]Wake{
            .{ .event = .{ .receive_failure = cause } }, .{ .event = .timeout },
            .{ .event = .{ .eap = &identity } },         .{ .event = .{ .eap = &challenge } },
            .{ .event = .{ .eap = &success } },          .{ .event = .{ .signal = .terminate } },
        };
        var fake: Harness = .{ .stop_immediately = false, .script = &script };
        try expectSignal(lifecycle.run(&session, fake.ports(), policy(), fake.reporter()), .terminate);
        try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.transient_error));
        try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.retry_scheduled));
        try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.online));
        try std.testing.expect(!fake.waits[1].receive);
        try std.testing.expectEqual(@as(usize, 2), fake.logoff_count);
    }
}

test "spurious wakes preserve the original absolute timeout" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{
        .{ .after = .fromSeconds(1), .event = .spurious },
        .{ .after = .fromSeconds(1), .event = .spurious },
        .{ .event = .timeout },
    };
    var fake: Harness = .{ .stop_immediately = false, .script = &script };
    var settings = policy();
    settings.retry_limit = .{ .limited = 0 };
    const result = lifecycle.run(&session, fake.ports(), settings, fake.reporter());
    try std.testing.expectEqual(lifecycle.Termination.retry_exhausted, std.meta.activeTag(result));
    try std.testing.expectEqual(rj.session.FailureReason.start_timeout, result.retry_exhausted.reason.?);
    for (fake.waits[0..3]) |wait| {
        try std.testing.expectEqual(@as(i96, 30 * std.time.ns_per_s), wait.deadline.?.nanoseconds);
    }
}

test "queued frames cannot starve a due protocol timer" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{.{ .after = .fromSeconds(30), .event = .{ .eap = &identity } }};
    var fake: Harness = .{ .stop_immediately = false, .script = &script };
    var settings = policy();
    settings.retry_limit = .{ .limited = 0 };
    const result = lifecycle.run(&session, fake.ports(), settings, fake.reporter());
    try std.testing.expectEqual(lifecycle.Termination.retry_exhausted, std.meta.activeTag(result));
    try std.testing.expectEqual(@as(usize, 2), fake.send_count);
    try std.testing.expectEqual(@as(u8, 2), fake.sent_types[1]);
}

test "shutdown interrupts backoff without waiting for retry" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{ .{ .event = .timeout }, .{ .event = .{ .signal = .terminate } } };
    var fake: Harness = .{ .stop_immediately = false, .script = &script };
    try expectSignal(lifecycle.run(&session, fake.ports(), policy(), fake.reporter()), .terminate);
    try std.testing.expect(!fake.waits[1].receive);
    try std.testing.expectEqual(@as(i96, 31 * std.time.ns_per_s), fake.waits[1].deadline.?.nanoseconds);
    try std.testing.expectEqual(@as(i96, 30 * std.time.ns_per_s), fake.now.nanoseconds);
    try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.authentication_started));
}

test "backoff wakes neither shorten nor extend the retry deadline" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{
        .{ .event = .timeout },                  .{ .event = .spurious }, .{ .event = .timeout },
        .{ .event = .{ .signal = .interrupt } },
    };
    var fake: Harness = .{ .stop_immediately = false, .script = &script };
    try expectSignal(lifecycle.run(&session, fake.ports(), policy(), fake.reporter()), .interrupt);
    try std.testing.expect(!fake.waits[1].receive);
    try std.testing.expect(!fake.waits[2].receive);
    try std.testing.expectEqual(fake.waits[1].deadline.?.nanoseconds, fake.waits[2].deadline.?.nanoseconds);
    try std.testing.expectEqual(@as(usize, 2), fake.countEvents(.authentication_started));
    try std.testing.expectEqual(@as(i96, 31 * std.time.ns_per_s), fake.sent_at[2].nanoseconds);
}

test "successful recovery resets the budget for a later disconnect" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{
        .{ .event = .timeout },                  .{ .event = .timeout },
        .{ .event = .{ .eap = &identity } },     .{ .event = .{ .eap = &challenge } },
        .{ .event = .{ .eap = &success } },      .{ .event = .logoff },
        .{ .event = .timeout },                  .{ .event = .{ .eap = &identity } },
        .{ .event = .{ .eap = &challenge } },    .{ .event = .{ .eap = &success } },
        .{ .event = .{ .signal = .terminate } },
    };
    var fake: Harness = .{ .stop_immediately = false, .script = &script };
    var settings = policy();
    settings.retry_limit = .{ .limited = 1 };
    try expectSignal(lifecycle.run(&session, fake.ports(), settings, fake.reporter()), .terminate);
    try std.testing.expectEqual(@as(usize, 2), fake.countEvents(.online));
    try std.testing.expectEqual(@as(usize, 2), fake.countEvents(.retry_scheduled));
    for (fake.events[0..fake.event_count]) |event| {
        if (event == .retry_scheduled) try std.testing.expectEqual(@as(u32, 1), event.retry_scheduled.attempt);
    }
}

test "repeated timeout exhausts the exact additional attempt budget" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{ .{ .event = .timeout }, .{ .event = .timeout }, .{ .event = .timeout } };
    var fake: Harness = .{ .stop_immediately = false, .script = &script };
    var settings = policy();
    settings.retry_limit = .{ .limited = 1 };
    const result = lifecycle.run(&session, fake.ports(), settings, fake.reporter());
    try std.testing.expectEqual(lifecycle.Termination.retry_exhausted, std.meta.activeTag(result));
    try std.testing.expectEqual(@as(usize, 2), fake.countEvents(.authentication_started));
    try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.retry_scheduled));
}

test "explicit authentication rejection never schedules a retry" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{
        .{ .event = .{ .eap = &identity } },
        .{ .event = .{ .eap = &.{ 4, 1, 0, 4 } } },
    };
    var fake: Harness = .{ .stop_immediately = false, .script = &script };
    const result = lifecycle.run(&session, fake.ports(), policy(), fake.reporter());
    try std.testing.expectEqual(lifecycle.Termination.authentication_rejected, std.meta.activeTag(result));
    try std.testing.expectEqual(@as(usize, 0), fake.countEvents(.retry_scheduled));
    try std.testing.expectEqual(@as(usize, 1), fake.logoff_count);
}

test "wait signal and clock failures still cancel the active session" {
    const cases = [_]struct { event: Wake, cause: anyerror }{
        .{ .event = .{ .event = .wait_failure }, .cause = error.WaitFailed },
        .{ .event = .{ .event = .stop_failure }, .cause = error.SignalWaitFailed },
        .{ .event = .{ .event = .clock_failure }, .cause = error.ClockFailed },
    };
    for (cases) |case| {
        var session = try initSession();
        defer session.deinit();
        const script = [_]Wake{case.event};
        var fake: Harness = .{ .stop_immediately = false, .script = &script };
        const result = lifecycle.run(&session, fake.ports(), policy(), fake.reporter());
        try std.testing.expectEqual(lifecycle.Termination.internal_failure, std.meta.activeTag(result));
        try std.testing.expectEqual(case.cause, result.internal_failure);
        try std.testing.expectEqual(@as(usize, 1), fake.logoff_count);
        try std.testing.expectEqual(@as(usize, 1), fake.watchdog_arms);
        try std.testing.expectEqual(@as(usize, 1), fake.watchdog_disarms);
    }
}

test "normal reporting failure cancels and returns internal failure" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{
        .{ .event = .{ .eap = &identity } }, .{ .event = .{ .eap = &challenge } },
        .{ .event = .{ .eap = &success } },
    };
    var fake: Harness = .{ .stop_immediately = false, .script = &script, .failed_report = .online };
    const result = lifecycle.run(&session, fake.ports(), policy(), fake.reporter());
    try std.testing.expectEqual(lifecycle.Termination.internal_failure, std.meta.activeTag(result));
    try std.testing.expectEqual(error.WriteFailed, result.internal_failure);
    try std.testing.expectEqual(@as(usize, 1), fake.logoff_count);
}

test "shutdown logging or send failure preserves signal without false completion" {
    for ([_]?platform.Ethernet.Error{ null, error.SendFailed, error.DeadlineExceeded }) |send_error| {
        var session = try initSession();
        defer session.deinit();
        const script = [_]Wake{.{ .event = .{ .signal = .terminate } }};
        var fake: Harness = .{
            .stop_immediately = false,
            .script = &script,
            .failed_report = .shutdown_started,
            .cleanup_send_error = send_error,
        };
        try expectSignal(lifecycle.run(&session, fake.ports(), policy(), fake.reporter()), .terminate);
        try std.testing.expectEqual(@as(u8, 143), fake.watchdog_exit_code.?);
        try std.testing.expectEqual(@as(usize, 1), fake.logoff_count);
        try std.testing.expectEqual(@as(i96, 5 * std.time.ns_per_s), fake.cleanup_deadline.?.nanoseconds);
        try std.testing.expectEqual(@as(usize, if (send_error == null) 1 else 0), fake.countEvents(.shutdown_completed));
    }
}

test "late cleanup returns signal without reporting shutdown completed" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{.{ .event = .{ .signal = .interrupt } }};
    var fake: Harness = .{ .stop_immediately = false, .script = &script, .cleanup_send_delay = .fromSeconds(6) };
    try expectSignal(lifecycle.run(&session, fake.ports(), policy(), fake.reporter()), .interrupt);
    try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.shutdown_failure));
    try std.testing.expectEqual(@as(usize, 0), fake.countEvents(.shutdown_completed));
    try std.testing.expectEqual(@as(u8, 130), fake.watchdog_exit_code.?);
}

test "watchdog arm failure does not enter unbounded signal cleanup" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{.{ .event = .{ .signal = .interrupt } }};
    var fake: Harness = .{ .stop_immediately = false, .script = &script, .watchdog_error = true };
    try expectSignal(lifecycle.run(&session, fake.ports(), policy(), fake.reporter()), .interrupt);
    try std.testing.expectEqual(@as(usize, 0), fake.logoff_count);
    try std.testing.expectEqual(@as(usize, 0), fake.watchdog_disarms);
    try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.shutdown_failure));
}

test "watchdog is armed before blocked Logoff and remains armed until send returns" {
    var session = try initSession();
    defer session.deinit();
    var blocked: BlockedCleanup = .{};
    const thread = try std.Thread.spawn(.{}, BlockedCleanup.releaseAfterSend, .{&blocked});
    defer thread.join();
    const script = [_]Wake{.{ .event = .{ .signal = .terminate } }};
    var fake: Harness = .{ .stop_immediately = false, .script = &script, .blocked_cleanup = &blocked };
    try expectSignal(lifecycle.run(&session, fake.ports(), policy(), fake.reporter()), .terminate);
    try std.testing.expect(blocked.observed_armed.load(.acquire));
    try std.testing.expect(!blocked.armed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fake.logoff_count);
    try std.testing.expectEqual(@as(u8, 143), fake.watchdog_exit_code.?);
    try std.testing.expectEqual(@as(i96, 5 * std.time.ns_per_s), fake.watchdog_timeout.?.nanoseconds);
    try std.testing.expectEqual(@as(usize, 0), fake.countEvents(.shutdown_completed));
}

test "shutdown reporting consumes the same deadline as Logoff" {
    for ([_]i64{ 2, 6 }) |seconds| {
        var session = try initSession();
        defer session.deinit();
        const script = [_]Wake{.{ .event = .{ .signal = .terminate } }};
        var fake: Harness = .{ .stop_immediately = false, .script = &script, .shutdown_report_delay = .fromSeconds(seconds) };
        try expectSignal(lifecycle.run(&session, fake.ports(), policy(), fake.reporter()), .terminate);
        if (seconds == 2) {
            try std.testing.expectEqual(@as(i96, 5 * std.time.ns_per_s), fake.cleanup_deadline.?.nanoseconds);
            try std.testing.expectEqual(@as(usize, 1), fake.logoff_count);
        } else {
            try std.testing.expectEqual(@as(usize, 0), fake.logoff_count);
            try std.testing.expectEqual(@as(usize, 0), fake.countEvents(.shutdown_completed));
            try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.shutdown_failure));
        }
    }
}

test "retry reporting failure is an internal error after cleanup" {
    for ([_]std.meta.Tag(lifecycle.Event){ .disconnected, .retry_scheduled }) |tag| {
        var session = try initSession();
        defer session.deinit();
        const script = [_]Wake{.{ .event = .timeout }};
        var fake: Harness = .{ .stop_immediately = false, .script = &script, .failed_report = tag };
        const result = lifecycle.run(&session, fake.ports(), policy(), fake.reporter());
        try std.testing.expectEqual(lifecycle.Termination.internal_failure, std.meta.activeTag(result));
        try std.testing.expectEqual(error.WriteFailed, result.internal_failure);
        try std.testing.expectEqual(@as(usize, 1), fake.logoff_count);
        try std.testing.expectEqual(rj.session.Phase.idle, session.phase());
    }
}

test "late transient cleanup cannot silently schedule another retry" {
    var session = try initSession();
    defer session.deinit();
    const script = [_]Wake{.{ .event = .timeout }};
    var fake: Harness = .{ .stop_immediately = false, .script = &script, .cleanup_send_delay = .fromSeconds(6) };
    const result = lifecycle.run(&session, fake.ports(), policy(), fake.reporter());
    try std.testing.expectEqual(lifecycle.Termination.internal_failure, std.meta.activeTag(result));
    try std.testing.expectEqual(error.ShutdownTimedOut, result.internal_failure);
    try std.testing.expectEqual(@as(usize, 0), fake.countEvents(.retry_scheduled));
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

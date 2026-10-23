const std = @import("std");
const config = @import("config.zig");
const lifecycle = @import("lifecycle.zig");
const platform = @import("platform.zig");
const rj = @import("rj-connect");

const Harness = struct {
    now: platform.Timestamp = timestamp(0),
    wait_calls: usize = 0,
    stop_after_waits: ?usize = null,
    stop_request: platform.Stop.Request = .interrupt,
    stop_error: ?platform.Stop.Error = null,
    receive_frames: []const []const u8 = &.{},
    receive_index: usize = 0,
    send_count: usize = 0,
    send_error: ?platform.Ethernet.Error = null,
    reject_cleanup_deadline: bool = false,
    block_cleanup_send: bool = false,
    blocked_send_started: std.atomic.Value(bool) = .init(false),
    blocked_send_release: std.atomic.Value(bool) = .init(false),
    watchdog_thread: ?std.Thread = null,
    network_error: ?platform.NetworkState.Error = null,
    tls_error: ?platform.Tls.Error = null,
    clock_error: ?platform.Clock.Error = null,
    advance_clock_on_send: platform.Duration = .zero,
    last_sent: [2048]u8 = undefined,
    last_sent_len: usize = 0,
    events: [32]lifecycle.Event = undefined,
    event_count: usize = 0,
    reporter_error: ?lifecycle.Reporter.Error = null,
    fail_reporter_after_writes: ?usize = null,
    watchdog_error: ?platform.Watchdog.Error = null,
    watchdog_arm_count: usize = 0,
    watchdog_disarm_count: usize = 0,
    last_watchdog_timeout: ?platform.Duration = null,
    last_watchdog_exit_code: ?u8 = null,

    fn ports(self: *Harness) platform.Ports {
        return .{
            .ethernet = .{ .context = self, .vtable = &ethernet_vtable },
            .network = .{ .context = self, .vtable = &network_vtable },
            .tls = .{ .context = self, .vtable = &tls_vtable },
            .mschapv2 = .{ .context = self, .vtable = &mschap_vtable },
            .clock = .{ .context = self, .vtable = &clock_vtable },
            .stop = .{ .context = self, .vtable = &stop_vtable },
            .watchdog = .{ .context = self, .vtable = &watchdog_vtable },
        };
    }

    fn reporter(self: *Harness) lifecycle.Reporter {
        return .{ .context = self, .vtable = &reporter_vtable };
    }

    fn countEvents(self: Harness, tag: std.meta.Tag(lifecycle.Event)) usize {
        var count: usize = 0;
        for (self.events[0..self.event_count]) |event| {
            if (std.meta.activeTag(event) == tag) count += 1;
        }
        return count;
    }
};

fn harness(context: *anyopaque) *Harness {
    return @ptrCast(@alignCast(context));
}

fn ethernetSend(
    context: *anyopaque,
    frame: []const u8,
    deadline: platform.Deadline,
) platform.Ethernet.Error!void {
    const fake = harness(context);
    if (fake.send_error) |err| return err;
    if (deadline != null and fake.reject_cleanup_deadline) return error.DeadlineExceeded;
    if (deadline != null and fake.block_cleanup_send) {
        fake.blocked_send_started.store(true, .release);
        while (!fake.blocked_send_release.load(.acquire)) {
            std.Thread.yield() catch {};
        }
        return error.DeadlineExceeded;
    }
    if (frame.len > fake.last_sent.len) return error.SendFailed;
    fake.send_count += 1;
    @memcpy(fake.last_sent[0..frame.len], frame);
    fake.last_sent_len = frame.len;
    fake.now = fake.now.addDuration(fake.advance_clock_on_send);
}

fn ethernetReceive(
    context: *anyopaque,
    _: platform.Deadline,
) platform.Ethernet.Error!?[]const u8 {
    const fake = harness(context);
    if (fake.receive_index >= fake.receive_frames.len) return null;
    const frame = fake.receive_frames[fake.receive_index];
    fake.receive_index += 1;
    return frame;
}

fn networkReadDhcpLease(
    context: *anyopaque,
    _: platform.Deadline,
) platform.NetworkState.Error!rj.session.DhcpLease {
    if (harness(context).network_error) |err| return err;
    return .{
        .ip = .{ 192, 0, 2, 10 },
        .netmask = .{ 255, 255, 255, 0 },
        .gateway = .{ 192, 0, 2, 1 },
        .dns = .{ 192, 0, 2, 53 },
    };
}

fn tlsProcess(
    context: *anyopaque,
    _: rj.session.TunnelOperation,
    _: []const u8,
    _: platform.Deadline,
) platform.Tls.Error!rj.session.TunnelOutput {
    if (harness(context).tls_error) |err| return err;
    return .{ .status = .more_data };
}

fn mschapAuthenticate(
    _: *anyopaque,
    _: []const u8,
    _: rj.session.Credentials,
    _: platform.Deadline,
) platform.Mschapv2.Error![]const u8 {
    return &.{ 2, 0x22 };
}

fn mschapVerify(
    _: *anyopaque,
    _: []const u8,
    _: rj.session.Credentials,
    _: platform.Deadline,
) platform.Mschapv2.Error!platform.Mschapv2.Verification {
    return .{ .verified = true, .response_data = &.{3} };
}

fn clockNow(context: *anyopaque) platform.Clock.Error!platform.Timestamp {
    const fake = harness(context);
    if (fake.clock_error) |err| return err;
    return fake.now;
}

fn clockWaitUntil(context: *anyopaque, deadline: platform.Timestamp) platform.Clock.Error!void {
    const fake = harness(context);
    fake.wait_calls += 1;
    fake.now = deadline;
}

fn stopTryNext(context: *anyopaque) platform.Stop.Error!?platform.Stop.Request {
    const fake = harness(context);
    if (fake.stop_error) |err| return err;
    const threshold = fake.stop_after_waits orelse return null;
    return if (fake.wait_calls >= threshold) fake.stop_request else null;
}

fn watchdogArm(
    context: *anyopaque,
    timeout: platform.Duration,
    exit_code: u8,
) platform.Watchdog.Error!void {
    const fake = harness(context);
    if (fake.watchdog_error) |err| return err;
    fake.watchdog_arm_count += 1;
    fake.last_watchdog_timeout = timeout;
    fake.last_watchdog_exit_code = exit_code;
    if (fake.block_cleanup_send) {
        fake.watchdog_thread = std.Thread.spawn(.{}, releaseBlockedSend, .{fake}) catch
            return error.WatchdogFailed;
    }
}

fn watchdogDisarm(context: *anyopaque) void {
    const fake = harness(context);
    fake.watchdog_disarm_count += 1;
    if (fake.watchdog_thread) |thread| {
        thread.join();
        fake.watchdog_thread = null;
    }
}

fn releaseBlockedSend(fake: *Harness) void {
    while (!fake.blocked_send_started.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    fake.blocked_send_release.store(true, .release);
}

fn report(context: *anyopaque, event: lifecycle.Event) lifecycle.Reporter.Error!void {
    const fake = harness(context);
    if (fake.reporter_error) |err| return err;
    if (fake.fail_reporter_after_writes) |limit| {
        if (fake.event_count >= limit) return error.WriteFailed;
    }
    fake.events[fake.event_count] = event;
    fake.event_count += 1;
}

const ethernet_vtable: platform.Ethernet.VTable = .{
    .send = ethernetSend,
    .tryReceive = ethernetReceive,
};
const network_vtable: platform.NetworkState.VTable = .{ .readDhcpLease = networkReadDhcpLease };
const tls_vtable: platform.Tls.VTable = .{ .process = tlsProcess };
const mschap_vtable: platform.Mschapv2.VTable = .{
    .authenticate = mschapAuthenticate,
    .verify = mschapVerify,
};
const clock_vtable: platform.Clock.VTable = .{
    .now = clockNow,
    .waitUntil = clockWaitUntil,
};
const stop_vtable: platform.Stop.VTable = .{ .tryNext = stopTryNext };
const watchdog_vtable: platform.Watchdog.VTable = .{
    .arm = watchdogArm,
    .disarm = watchdogDisarm,
};
const reporter_vtable: lifecycle.Reporter.VTable = .{ .write = report };

fn timestamp(nanoseconds: i96) platform.Timestamp {
    return .fromNanoseconds(nanoseconds);
}

fn policy(
    retry_limit: config.RetryLimit,
    backoff_initial: std.Io.Duration,
    backoff_max: std.Io.Duration,
    shutdown_timeout: std.Io.Duration,
) lifecycle.Policy {
    return .{
        .retry_limit = retry_limit,
        .backoff_initial = backoff_initial,
        .backoff_max = backoff_max,
        .shutdown_timeout = shutdown_timeout,
    };
}

test "retry tracker schedules exponential deterministic delays and resets after online" {
    var tracker = try lifecycle.Tracker.init(policy(
        .{ .limited = 4 },
        .fromSeconds(1),
        .fromSeconds(5),
        .fromSeconds(1),
    ));

    try std.testing.expectEqual(@as(u32, 0), tracker.retryAttempt());
    try std.testing.expectEqual(@as(i96, std.time.ns_per_s), tracker.retryDelay().toNanoseconds());
    _ = tracker.scheduleRetry(timestamp(0)).?;
    try std.testing.expectEqual(@as(i96, 2 * std.time.ns_per_s), tracker.retryDelay().toNanoseconds());
    _ = tracker.scheduleRetry(timestamp(0)).?;
    try std.testing.expectEqual(@as(i96, 4 * std.time.ns_per_s), tracker.retryDelay().toNanoseconds());
    _ = tracker.scheduleRetry(timestamp(0)).?;
    try std.testing.expectEqual(@as(i96, 5 * std.time.ns_per_s), tracker.retryDelay().toNanoseconds());
    _ = tracker.scheduleRetry(timestamp(0)).?;
    try std.testing.expect(tracker.scheduleRetry(timestamp(0)) == null);

    tracker.reset();
    try std.testing.expectEqual(@as(u32, 0), tracker.retryAttempt());
    try std.testing.expectEqual(@as(i96, std.time.ns_per_s), tracker.retryDelay().toNanoseconds());
}

test "lifecycle exhausts the configured additional-attempt budget" {
    var fake: Harness = .{};
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .start_timeout = .fromSeconds(1),
        .held_timeout = .fromSeconds(1),
        .max_start_attempts = 1,
        .max_auth_failures = 1,
    });
    defer session.deinit();

    const termination = lifecycle.run(
        &session,
        fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(
            .{ .limited = 1 },
            .fromSeconds(1),
            .fromSeconds(4),
            .fromSeconds(1),
        ),
        fake.reporter(),
    );
    try std.testing.expectEqual(
        rj.session.FailureReason.start_timeout,
        termination.retry_exhausted.reason.?,
    );
    try std.testing.expectEqual(@as(usize, 4), fake.send_count);
    try std.testing.expectEqual(@as(usize, 5), fake.wait_calls);
    try std.testing.expectEqual(@as(usize, 2), fake.countEvents(.authentication_started));
    try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.retry_scheduled));
}

test "signal cancels one active attempt and sends one Logoff" {
    var fake: Harness = .{
        .stop_after_waits = 1,
        .stop_request = .interrupt,
    };
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .start_timeout = .fromSeconds(10),
        .held_timeout = .fromSeconds(1),
    });
    defer session.deinit();

    const termination = lifecycle.run(
        &session,
        fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(.unlimited, .fromSeconds(1), .fromSeconds(4), .fromSeconds(2)),
        fake.reporter(),
    );
    try std.testing.expectEqual(platform.Stop.Request.interrupt, termination.signal);
    try std.testing.expectEqual(@as(u8, 130), termination.exitCode());
    try std.testing.expectEqual(@as(usize, 2), fake.send_count);
    try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.shutdown_started));
    try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.shutdown_completed));
}

test "shutdown timeout preserves the originating signal status" {
    var fake: Harness = .{
        .stop_after_waits = 1,
        .advance_clock_on_send = .fromSeconds(5),
    };
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .start_timeout = .fromSeconds(10),
    });
    defer session.deinit();

    const termination = lifecycle.run(
        &session,
        fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(.unlimited, .fromSeconds(1), .fromSeconds(2), .fromSeconds(1)),
        fake.reporter(),
    );

    try std.testing.expectEqual(platform.Stop.Request.interrupt, termination.signal);
    try std.testing.expectEqual(@as(u8, 130), termination.exitCode());
    try std.testing.expectEqual(@as(usize, 1), fake.watchdog_arm_count);
    try std.testing.expectEqual(@as(usize, 1), fake.watchdog_disarm_count);
    try std.testing.expectEqual(@as(?u8, 130), fake.last_watchdog_exit_code);
}

test "logging failure cannot bypass signal cleanup" {
    var fake: Harness = .{
        .stop_after_waits = 1,
        .fail_reporter_after_writes = 1,
    };
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .start_timeout = .fromSeconds(10),
    });
    defer session.deinit();

    const termination = lifecycle.run(
        &session,
        fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(.unlimited, .fromSeconds(1), .fromSeconds(4), .fromSeconds(2)),
        fake.reporter(),
    );

    try std.testing.expectEqual(platform.Stop.Request.interrupt, termination.signal);
    try std.testing.expectEqual(@as(usize, 2), fake.send_count);
    try std.testing.expectEqual(@as(usize, 1), fake.watchdog_disarm_count);
}

test "cleanup deadline failure still exits with the signal status" {
    var fake: Harness = .{
        .stop_after_waits = 1,
        .reject_cleanup_deadline = true,
    };
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .start_timeout = .fromSeconds(10),
    });
    defer session.deinit();

    const termination = lifecycle.run(
        &session,
        fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(.unlimited, .fromSeconds(1), .fromSeconds(4), .fromSeconds(2)),
        fake.reporter(),
    );

    try std.testing.expectEqual(platform.Stop.Request.interrupt, termination.signal);
    try std.testing.expectEqual(@as(u8, 130), termination.exitCode());
}

test "blocking cleanup adapter cannot hang signal exit" {
    var fake: Harness = .{
        .stop_after_waits = 1,
        .block_cleanup_send = true,
    };
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .start_timeout = .fromSeconds(10),
    });
    defer session.deinit();

    const termination = lifecycle.run(
        &session,
        fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(.unlimited, .fromSeconds(1), .fromSeconds(4), .fromSeconds(2)),
        fake.reporter(),
    );

    try std.testing.expectEqual(platform.Stop.Request.interrupt, termination.signal);
    try std.testing.expect(fake.blocked_send_started.load(.acquire));
    try std.testing.expect(fake.watchdog_thread == null);
}

test "remote Logoff is classified as a transient disconnect and consumes its retry budget" {
    var logoff_frame: [rj.protocol.eapol.header_size]u8 = undefined;
    rj.protocol.eapol.encodeLogoff(
        .{ 0x01, 0x80, 0xc2, 0x00, 0x00, 0x03 },
        .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        &logoff_frame,
    );
    const frames = [_][]const u8{&logoff_frame};
    var fake: Harness = .{ .receive_frames = &frames };
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .start_timeout = .fromSeconds(10),
    });
    defer session.deinit();

    const termination = lifecycle.run(
        &session,
        fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(.{ .limited = 0 }, .fromSeconds(1), .fromSeconds(2), .fromSeconds(1)),
        fake.reporter(),
    );

    try std.testing.expectEqual(
        rj.session.FailureReason.server_logoff,
        termination.retry_exhausted.reason.?,
    );
    try std.testing.expectEqual(@as(usize, 1), fake.countEvents(.disconnected));
}

test "credential rejection terminates after one bounded Logoff" {
    const identity = identityRequest(0x16);
    const challenge = md5ChallengeRequest(0x17);
    const failure = terminalRequest(.failure, 0x17);
    const frames = [_][]const u8{ &identity, &challenge, &failure };
    var fake: Harness = .{ .receive_frames = &frames };
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .start_timeout = .fromSeconds(10),
        .max_auth_failures = 1,
    });
    defer session.deinit();

    const termination = lifecycle.run(
        &session,
        fake.ports(),
        .{ .username = "alice", .password = "wrong" },
        policy(.unlimited, .fromSeconds(1), .fromSeconds(2), .fromSeconds(5)),
        fake.reporter(),
    );

    try std.testing.expectEqual(
        rj.session.FailureReason.server_failure,
        termination.authentication_rejected.reason.?,
    );
    try std.testing.expectEqual(@as(u8, 3), termination.exitCode());
    try std.testing.expectEqual(@as(usize, 4), fake.send_count);
}

test "certificate rejection terminates as a security failure" {
    const identity = identityRequest(0x16);
    const peap = peapRequest(0x17);
    const frames = [_][]const u8{ &identity, &peap };
    var fake: Harness = .{
        .receive_frames = &frames,
        .tls_error = error.CertificateRejected,
    };
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .allowed_methods = .{ .md5_challenge = true, .peap = true },
        .peap = .{
            .v3_application_data = "app-data",
            .v3_dll_data = "dll-data",
        },
    });
    defer session.deinit();

    const termination = lifecycle.run(
        &session,
        fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(.unlimited, .fromSeconds(1), .fromSeconds(2), .fromSeconds(5)),
        fake.reporter(),
    );

    try std.testing.expectEqual(error.CertificateRejected, termination.security_failure.cause.?);
    try std.testing.expectEqual(@as(u8, 5), termination.exitCode());
}

test "invalid DHCP lease terminates as a configuration failure" {
    const identity = identityRequest(0x16);
    const challenge = md5ChallengeRequest(0x17);
    const success = terminalRequest(.success, 0x17);
    const frames = [_][]const u8{ &identity, &challenge, &success };
    var fake: Harness = .{
        .receive_frames = &frames,
        .network_error = error.LeaseInvalid,
    };
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .start_timeout = .fromSeconds(10),
        .dhcp_second_auth = true,
    });
    defer session.deinit();

    const termination = lifecycle.run(
        &session,
        fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(.unlimited, .fromSeconds(1), .fromSeconds(2), .fromSeconds(5)),
        fake.reporter(),
    );

    try std.testing.expectEqual(error.LeaseInvalid, termination.configuration_failure.cause.?);
    try std.testing.expectEqual(@as(u8, 2), termination.exitCode());
}

test "clock and reporter failures terminate as internal failures after cleanup" {
    var clock_fake: Harness = .{ .clock_error = error.ClockFailed };
    var clock_session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
    });
    defer clock_session.deinit();
    const clock_termination = lifecycle.run(
        &clock_session,
        clock_fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(.unlimited, .fromSeconds(1), .fromSeconds(2), .fromSeconds(5)),
        clock_fake.reporter(),
    );
    try std.testing.expectEqual(error.ClockFailed, clock_termination.internal_failure);
    try std.testing.expectEqual(@as(u8, 6), clock_termination.exitCode());

    var report_fake: Harness = .{ .reporter_error = error.WriteFailed };
    var report_session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
    });
    defer report_session.deinit();
    const report_termination = lifecycle.run(
        &report_session,
        report_fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(.unlimited, .fromSeconds(1), .fromSeconds(2), .fromSeconds(5)),
        report_fake.reporter(),
    );
    try std.testing.expectEqual(error.WriteFailed, report_termination.internal_failure);
    try std.testing.expectEqual(@as(u8, 6), report_termination.exitCode());
}

test "runtime logging failure still performs protocol cleanup" {
    var fake: Harness = .{ .fail_reporter_after_writes = 1 };
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .start_timeout = .fromSeconds(1),
    });
    defer session.deinit();

    const termination = lifecycle.run(
        &session,
        fake.ports(),
        .{ .username = "alice", .password = "secret" },
        policy(.unlimited, .fromSeconds(1), .fromSeconds(2), .fromSeconds(5)),
        fake.reporter(),
    );

    try std.testing.expectEqual(error.WriteFailed, termination.internal_failure);
    try std.testing.expect(fake.send_count >= 2);
    try std.testing.expectEqual(rj.session.ActivePhase.idle, session.phase());
    try std.testing.expectEqual(@as(usize, 1), fake.watchdog_arm_count);
    try std.testing.expectEqual(@as(usize, 1), fake.watchdog_disarm_count);
}

test "failure classification distinguishes retryable, rejected, security, and internal errors" {
    try std.testing.expectEqual(
        lifecycle.FailureClass.transient,
        lifecycle.classifyFailureReason(.server_logoff),
    );
    try std.testing.expectEqual(
        lifecycle.FailureClass.authentication_rejected,
        lifecycle.classifyFailureReason(.server_failure),
    );
    try std.testing.expectEqual(
        lifecycle.FailureClass.transient,
        lifecycle.classifySessionError(error.InvalidFrame),
    );
    try std.testing.expectEqual(
        lifecycle.FailureClass.security,
        lifecycle.classifySessionError(error.UnsupportedEapMethod),
    );
    try std.testing.expectEqual(
        lifecycle.FailureClass.security,
        lifecycle.classifyCoordinatorError(error.CertificateRejected),
    );
    try std.testing.expectEqual(
        lifecycle.FailureClass.transient,
        lifecycle.classifyCoordinatorError(error.ReceiveFailed),
    );
    try std.testing.expectEqual(
        lifecycle.FailureClass.authentication_rejected,
        lifecycle.classifyCoordinatorError(error.VerificationFailed),
    );
    try std.testing.expectEqual(
        lifecycle.FailureClass.internal,
        lifecycle.classifyCoordinatorError(error.ResourceExhausted),
    );
    try std.testing.expectEqual(
        lifecycle.FailureClass.internal,
        lifecycle.classifyCoordinatorError(error.DeadlineExceeded),
    );
}

test "every termination branch has a distinct public exit status" {
    const failure: lifecycle.StepFailure = .{ .cause = error.Failure };
    const terminations = [_]lifecycle.Termination{
        .{ .signal = .interrupt },
        .{ .signal = .terminate },
        .{ .authentication_rejected = failure },
        .{ .retry_exhausted = failure },
        .{ .security_failure = failure },
        .{ .configuration_failure = failure },
        .{ .internal_failure = error.Failure },
    };
    const expected = [_]u8{ 130, 143, 3, 4, 5, 2, 6 };
    for (terminations, expected) |termination, exit_code| {
        try std.testing.expectEqual(exit_code, termination.exitCode());
    }
}

fn eapolHeader(
    packet_type: rj.protocol.eapol.PacketType,
    body_len: u16,
) [rj.protocol.eapol.header_size]u8 {
    return .{
        0x01, 0x80, 0xc2, 0x00,                     0x00,                    0x03,
        0xaa, 0xbb, 0xcc, 0xdd,                     0xee,                    0xff,
        0x88, 0x8e, 0x01, @backingInt(packet_type), @intCast(body_len >> 8), @intCast(body_len),
    };
}

fn identityRequest(identifier: u8) [rj.protocol.eapol.header_size + 5]u8 {
    var frame: [rj.protocol.eapol.header_size + 5]u8 = undefined;
    @memcpy(frame[0..rj.protocol.eapol.header_size], &eapolHeader(.eap, 5));
    frame[rj.protocol.eapol.header_size..].* = .{ 1, identifier, 0, 5, 1 };
    return frame;
}

fn md5ChallengeRequest(identifier: u8) [rj.protocol.eapol.header_size + 22]u8 {
    var frame: [rj.protocol.eapol.header_size + 22]u8 = undefined;
    @memcpy(frame[0..rj.protocol.eapol.header_size], &eapolHeader(.eap, 22));
    frame[rj.protocol.eapol.header_size..][0..5].* = .{ 1, identifier, 0, 22, 4 };
    frame[rj.protocol.eapol.header_size + 5] = 16;
    for (0..16) |index| frame[rj.protocol.eapol.header_size + 6 + index] = @intCast(index);
    return frame;
}

fn peapRequest(identifier: u8) [rj.protocol.eapol.header_size + 6]u8 {
    var frame: [rj.protocol.eapol.header_size + 6]u8 = undefined;
    @memcpy(frame[0..rj.protocol.eapol.header_size], &eapolHeader(.eap, 6));
    frame[rj.protocol.eapol.header_size..].* = .{ 1, identifier, 0, 6, 25, 0x20 };
    return frame;
}

fn terminalRequest(
    code: rj.protocol.eapol.EapCode,
    identifier: u8,
) [rj.protocol.eapol.header_size + 4]u8 {
    var frame: [rj.protocol.eapol.header_size + 4]u8 = undefined;
    @memcpy(frame[0..rj.protocol.eapol.header_size], &eapolHeader(.eap, 4));
    frame[rj.protocol.eapol.header_size..].* = .{ @backingInt(code), identifier, 0, 4 };
    return frame;
}

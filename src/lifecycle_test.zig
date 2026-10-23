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
    advance_clock_on_send: platform.Duration = .zero,
    last_sent: [2048]u8 = undefined,
    last_sent_len: usize = 0,
    events: [32]lifecycle.Event = undefined,
    event_count: usize = 0,
    reporter_error: ?lifecycle.Reporter.Error = null,

    fn ports(self: *Harness) platform.Ports {
        return .{
            .ethernet = .{ .context = self, .vtable = &ethernet_vtable },
            .network = .{ .context = self, .vtable = &network_vtable },
            .tls = .{ .context = self, .vtable = &tls_vtable },
            .mschapv2 = .{ .context = self, .vtable = &mschap_vtable },
            .clock = .{ .context = self, .vtable = &clock_vtable },
            .stop = .{ .context = self, .vtable = &stop_vtable },
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

fn ethernetSend(context: *anyopaque, frame: []const u8) platform.Ethernet.Error!void {
    const fake = harness(context);
    if (fake.send_error) |err| return err;
    if (frame.len > fake.last_sent.len) return error.SendFailed;
    fake.send_count += 1;
    @memcpy(fake.last_sent[0..frame.len], frame);
    fake.last_sent_len = frame.len;
    fake.now = fake.now.addDuration(fake.advance_clock_on_send);
}

fn ethernetReceive(context: *anyopaque) platform.Ethernet.Error!?[]const u8 {
    const fake = harness(context);
    if (fake.receive_index >= fake.receive_frames.len) return null;
    const frame = fake.receive_frames[fake.receive_index];
    fake.receive_index += 1;
    return frame;
}

fn networkReadDhcpLease(_: *anyopaque) platform.NetworkState.Error!rj.session.DhcpLease {
    return .{
        .ip = .{ 192, 0, 2, 10 },
        .netmask = .{ 255, 255, 255, 0 },
        .gateway = .{ 192, 0, 2, 1 },
        .dns = .{ 192, 0, 2, 53 },
    };
}

fn tlsProcess(
    _: *anyopaque,
    _: rj.session.TunnelOperation,
    _: []const u8,
) platform.Tls.Error!rj.session.TunnelOutput {
    return .{ .status = .more_data };
}

fn mschapAuthenticate(
    _: *anyopaque,
    _: []const u8,
    _: rj.session.Credentials,
) platform.Mschapv2.Error![]const u8 {
    return &.{ 2, 0x22 };
}

fn mschapVerify(
    _: *anyopaque,
    _: []const u8,
    _: rj.session.Credentials,
) platform.Mschapv2.Error!platform.Mschapv2.Verification {
    return .{ .verified = true, .response_data = &.{3} };
}

fn clockNow(context: *anyopaque) platform.Clock.Error!platform.Timestamp {
    return harness(context).now;
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

fn report(context: *anyopaque, event: lifecycle.Event) lifecycle.Reporter.Error!void {
    const fake = harness(context);
    if (fake.reporter_error) |err| return err;
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

test "shutdown deadline prevents an unbounded successful exit" {
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

    try std.testing.expectEqual(error.ShutdownTimedOut, termination.internal_failure);
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

fn terminalRequest(
    code: rj.protocol.eapol.EapCode,
    identifier: u8,
) [rj.protocol.eapol.header_size + 4]u8 {
    var frame: [rj.protocol.eapol.header_size + 4]u8 = undefined;
    @memcpy(frame[0..rj.protocol.eapol.header_size], &eapolHeader(.eap, 4));
    frame[rj.protocol.eapol.header_size..].* = .{ @backingInt(code), identifier, 0, 4 };
    return frame;
}

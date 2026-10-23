const std = @import("std");
const rj = @import("rj-connect");
const coordinator = @import("coordinator.zig");
const platform = @import("platform.zig");

const Harness = struct {
    send_count: usize = 0,
    last_sent: [128]u8 = undefined,
    last_sent_len: usize = 0,
    send_error: ?platform.Ethernet.Error = null,
    receive_error: ?platform.Ethernet.Error = null,
    receive_frame: ?[]const u8 = null,
    dhcp_reads: usize = 0,
    dhcp_lease: rj.session.DhcpLease = .{
        .ip = .{ 192, 0, 2, 10 },
        .netmask = .{ 255, 255, 255, 0 },
        .gateway = .{ 192, 0, 2, 1 },
        .dns = .{ 192, 0, 2, 53 },
    },
    tls_outputs: [4]rj.session.TunnelOutput = undefined,
    tls_output_count: usize = 0,
    tls_output_index: usize = 0,
    tls_operations: [8]rj.session.TunnelOperation = undefined,
    tls_operation_count: usize = 0,
    tls_error: ?platform.Tls.Error = null,
    mschap_challenge: [16]u8 = undefined,
    mschap_challenge_len: usize = 0,
    mschap_authenticate_calls: usize = 0,
    mschap_verify_calls: usize = 0,
    mschap_response: [2]u8 = .{ 2, 0x22 },
    mschap_verified: bool = true,
    mschap_error: ?platform.Mschapv2.Error = null,
    clock_value: platform.Timestamp = timestamp(0),
    clock_calls: usize = 0,
    wait_calls: usize = 0,
    last_wait_deadline: ?platform.Timestamp = null,
    stop_request: ?platform.Stop.Request = null,
    stop_calls: usize = 0,

    fn ports(self: *Harness) platform.Ports {
        return .{
            .ethernet = .{ .context = self, .vtable = &ethernet_vtable },
            .network = .{ .context = self, .vtable = &network_vtable },
            .tls = .{ .context = self, .vtable = &tls_vtable },
            .mschapv2 = .{ .context = self, .vtable = &mschapv2_vtable },
            .clock = .{ .context = self, .vtable = &clock_vtable },
            .stop = .{ .context = self, .vtable = &stop_vtable },
        };
    }
};

fn harness(context: *anyopaque) *Harness {
    return @ptrCast(@alignCast(context));
}

fn ethernetSend(context: *anyopaque, frame: []const u8) platform.Ethernet.Error!void {
    const fake = harness(context);
    if (fake.send_error) |err| return err;
    fake.send_count += 1;
    const len = @min(frame.len, fake.last_sent.len);
    @memcpy(fake.last_sent[0..len], frame[0..len]);
    fake.last_sent_len = len;
}

fn ethernetReceive(context: *anyopaque) platform.Ethernet.Error!?[]const u8 {
    const fake = harness(context);
    if (fake.receive_error) |err| return err;
    const frame = fake.receive_frame;
    fake.receive_frame = null;
    return frame;
}

fn networkReadDhcpLease(context: *anyopaque) platform.NetworkState.Error!rj.session.DhcpLease {
    const fake = harness(context);
    fake.dhcp_reads += 1;
    return fake.dhcp_lease;
}

fn tlsProcess(
    context: *anyopaque,
    operation: rj.session.TunnelOperation,
    bytes: []const u8,
) platform.Tls.Error!rj.session.TunnelOutput {
    _ = bytes;
    const fake = harness(context);
    if (fake.tls_error) |err| return err;
    fake.tls_operations[fake.tls_operation_count] = operation;
    fake.tls_operation_count += 1;
    if (fake.tls_output_index >= fake.tls_output_count) {
        return .{ .status = .more_data };
    }
    const output = fake.tls_outputs[fake.tls_output_index];
    fake.tls_output_index += 1;
    return output;
}

fn mschapAuthenticate(
    context: *anyopaque,
    challenge: []const u8,
    credentials: rj.session.Credentials,
) platform.Mschapv2.Error![]const u8 {
    _ = credentials;
    const fake = harness(context);
    if (fake.mschap_error) |err| return err;
    fake.mschap_authenticate_calls += 1;
    fake.mschap_challenge_len = @min(challenge.len, fake.mschap_challenge.len);
    @memcpy(fake.mschap_challenge[0..fake.mschap_challenge_len], challenge[0..fake.mschap_challenge_len]);
    return fake.mschap_response[0..];
}

fn mschapVerify(
    context: *anyopaque,
    challenge: []const u8,
    credentials: rj.session.Credentials,
) platform.Mschapv2.Error!bool {
    _ = challenge;
    _ = credentials;
    const fake = harness(context);
    if (fake.mschap_error) |err| return err;
    fake.mschap_verify_calls += 1;
    return fake.mschap_verified;
}

fn clockNow(context: *anyopaque) platform.Clock.Error!platform.Timestamp {
    const fake = harness(context);
    fake.clock_calls += 1;
    return fake.clock_value;
}

fn clockWaitUntil(context: *anyopaque, deadline: platform.Timestamp) platform.Clock.Error!void {
    const fake = harness(context);
    fake.wait_calls += 1;
    fake.last_wait_deadline = deadline;
}

fn stopTryNext(context: *anyopaque) platform.Stop.Error!?platform.Stop.Request {
    const fake = harness(context);
    fake.stop_calls += 1;
    const request = fake.stop_request;
    fake.stop_request = null;
    return request;
}

const ethernet_vtable: platform.Ethernet.VTable = .{
    .send = ethernetSend,
    .tryReceive = ethernetReceive,
};

const network_vtable: platform.NetworkState.VTable = .{
    .readDhcpLease = networkReadDhcpLease,
};

const tls_vtable: platform.Tls.VTable = .{
    .process = tlsProcess,
};

const mschapv2_vtable: platform.Mschapv2.VTable = .{
    .authenticate = mschapAuthenticate,
    .verify = mschapVerify,
};

const clock_vtable: platform.Clock.VTable = .{
    .now = clockNow,
    .waitUntil = clockWaitUntil,
};

const stop_vtable: platform.Stop.VTable = .{
    .tryNext = stopTryNext,
};

fn timestamp(nanoseconds: i96) platform.Timestamp {
    return .fromNanoseconds(nanoseconds);
}

fn frameInput(session: *const rj.session.Session, bytes: []const u8) rj.session.Input {
    return .{ .frame = .{
        .generation = session.currentGeneration(),
        .bytes = bytes,
    } };
}

fn eapolHeader(packet_type: rj.protocol.eapol.PacketType, body_len: u16) [18]u8 {
    return .{
        0x01, 0x80, 0xc2, 0x00,                     0x00,                    0x03,
        0xaa, 0xbb, 0xcc, 0xdd,                     0xee,                    0xff,
        0x88, 0x8e, 0x01, @backingInt(packet_type), @intCast(body_len >> 8), @intCast(body_len),
    };
}

fn identityRequest(identifier: u8) [23]u8 {
    var frame: [23]u8 = undefined;
    @memcpy(frame[0..18], &eapolHeader(.eap, 5));
    frame[18..23].* = .{ 1, identifier, 0, 5, 1 };
    return frame;
}

fn md5ChallengeRequest(identifier: u8) [40]u8 {
    var frame: [40]u8 = undefined;
    @memcpy(frame[0..18], &eapolHeader(.eap, 22));
    frame[18..23].* = .{ 1, identifier, 0, 22, 4 };
    frame[23] = 16;
    for (0..16) |index| frame[24 + index] = @intCast(index);
    return frame;
}

fn peapRequest(identifier: u8) [24]u8 {
    var frame: [24]u8 = undefined;
    @memcpy(frame[0..18], &eapolHeader(.eap, 6));
    frame[18..24].* = .{ 1, identifier, 0, 6, 25, 0x20 };
    return frame;
}

fn terminalSuccess(identifier: u8) [22]u8 {
    var frame: [22]u8 = undefined;
    @memcpy(frame[0..18], &eapolHeader(.eap, 4));
    frame[18..22].* = .{ 3, identifier, 0, 4 };
    return frame;
}

fn innerRequest(
    output: []u8,
    identifier: u8,
    eap_type: rj.protocol.eap.Type,
    data: []const u8,
) []const u8 {
    return rj.protocol.eap.encode(.request, identifier, eap_type, data, output) catch unreachable;
}

fn dispatchSends(
    ports: *const platform.Ports,
    outcome: *const rj.session.Outcome,
) !void {
    for (outcome.actions) |action| {
        try std.testing.expectEqual(rj.session.Action.send_frame, std.meta.activeTag(action));
        const result = try coordinator.dispatch(ports, outcome.generation, action, null);
        try std.testing.expectEqual(coordinator.Result.handled, result);
    }
}

fn expectRequestCredentials(result: coordinator.Result) !rj.session.CredentialPurpose {
    return switch (result) {
        .request_credentials => |purpose| purpose,
        else => error.ExpectedCredentialRequest,
    };
}

fn expectSessionInput(result: coordinator.Result) !rj.session.Input {
    return switch (result) {
        .session_input => |input| input,
        else => error.ExpectedSessionInput,
    };
}

test "EAP-MD5 session collaborates with all platform ports" {
    var fake: Harness = .{};
    const ports = fake.ports();
    const credentials: rj.session.Credentials = .{ .username = "alice", .password = "secret" };

    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .dhcp_second_auth = true,
    });
    defer session.deinit();

    const now = try ports.clock.now();
    try std.testing.expectEqual(fake.clock_value, now);

    var started = try session.step(now, .start);
    defer started.deinit(std.testing.allocator);
    try ports.clock.waitUntil(started.next_deadline.?);
    try dispatchSends(&ports, &started);
    try std.testing.expectEqual(@as(usize, 1), fake.send_count);
    try std.testing.expectEqual(@as(usize, 1), fake.wait_calls);

    const identity = identityRequest(0x16);
    fake.receive_frame = &identity;
    const inbound = (try ports.ethernet.tryReceive()).?;
    var acquired = try session.step(timestamp(std.time.ns_per_s), frameInput(&session, inbound));
    defer acquired.deinit(std.testing.allocator);
    const identity_request = try expectRequestCredentials(
        try coordinator.dispatch(&ports, acquired.generation, acquired.actions[0], null),
    );
    try std.testing.expectEqual(rj.session.CredentialPurpose.identity, identity_request);

    var identified = try session.step(timestamp(2 * std.time.ns_per_s), .{ .credentials = credentials });
    defer identified.deinit(std.testing.allocator);
    try dispatchSends(&ports, &identified);

    const challenge = md5ChallengeRequest(0x17);
    var challenged = try session.step(timestamp(3 * std.time.ns_per_s), frameInput(&session, &challenge));
    defer challenged.deinit(std.testing.allocator);
    const challenge_request = try expectRequestCredentials(
        try coordinator.dispatch(&ports, challenged.generation, challenged.actions[0], null),
    );
    try std.testing.expectEqual(rj.session.CredentialPurpose.md5_challenge, challenge_request);

    var answered = try session.step(timestamp(4 * std.time.ns_per_s), .{
        .credentials = .{ .username = "alice", .password = "" },
    });
    defer answered.deinit(std.testing.allocator);
    try dispatchSends(&ports, &answered);

    const success = terminalSuccess(0x17);
    var waiting = try session.step(timestamp(5 * std.time.ns_per_s), frameInput(&session, &success));
    defer waiting.deinit(std.testing.allocator);
    try std.testing.expectEqual(rj.session.Action.poll_dhcp, waiting.actions[0]);
    const dhcp_input = try expectSessionInput(
        try coordinator.dispatch(&ports, waiting.generation, waiting.actions[0], null),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.dhcp_reads);
    try std.testing.expect(dhcp_input.external_result.generation.eql(waiting.generation));

    var second_cycle = try session.step(timestamp(6 * std.time.ns_per_s), dhcp_input);
    defer second_cycle.deinit(std.testing.allocator);
    try dispatchSends(&ports, &second_cycle);
    try std.testing.expectEqual(rj.session.DhcpStep.second, session.dhcpStep());

    fake.stop_request = .terminate;
    try std.testing.expectEqual(platform.Stop.Request.terminate, (try ports.stop.tryNext()).?);
    try std.testing.expectEqual(@as(?platform.Stop.Request, null), try ports.stop.tryNext());
}

test "PEAP session collaborates with TLS and MSCHAPv2 adapters" {
    var fake: Harness = .{};
    const ports = fake.ports();
    const credentials: rj.session.Credentials = .{ .username = "alice", .password = "secret" };
    const initial_generation = rj.session.Generation.initial;

    var identity_buffer: [16]u8 = undefined;
    const inner_identity = innerRequest(&identity_buffer, 1, .identity, &.{});
    fake.tls_outputs[0] = .{
        .status = .established,
        .outbound_tls = "client-hello",
        .plaintext = inner_identity,
    };
    fake.tls_outputs[1] = .{ .status = .established, .outbound_tls = "client-identity" };
    fake.tls_outputs[2] = .{ .status = .established, .outbound_tls = "client-response" };
    fake.tls_outputs[3] = .{ .status = .established, .outbound_tls = "client-success" };
    fake.tls_output_count = 4;

    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .allowed_methods = .{ .md5_challenge = true, .peap = true },
        .peap = .{
            .v3_application_data = "app-data",
            .v3_dll_data = "dll-data",
        },
    });
    defer session.deinit();

    var started = try session.step(timestamp(0), .start);
    defer started.deinit(std.testing.allocator);
    try dispatchSends(&ports, &started);

    const identity = identityRequest(0x16);
    var acquired = try session.step(timestamp(std.time.ns_per_s), frameInput(&session, &identity));
    defer acquired.deinit(std.testing.allocator);
    const identity_request = try expectRequestCredentials(
        try coordinator.dispatch(&ports, acquired.generation, acquired.actions[0], null),
    );
    try std.testing.expectEqual(rj.session.CredentialPurpose.identity, identity_request);

    var identified = try session.step(timestamp(2 * std.time.ns_per_s), .{ .credentials = credentials });
    defer identified.deinit(std.testing.allocator);
    try dispatchSends(&ports, &identified);

    const request = peapRequest(0x17);
    var selected = try session.step(timestamp(3 * std.time.ns_per_s), frameInput(&session, &request));
    defer selected.deinit(std.testing.allocator);
    const tls_input = try expectSessionInput(
        try coordinator.dispatch(&ports, selected.generation, selected.actions[0], credentials),
    );
    try std.testing.expectEqual(rj.session.TunnelOperation.process_server_tls, fake.tls_operations[0]);

    var identity_batch = try session.step(timestamp(4 * std.time.ns_per_s), tls_input);
    defer identity_batch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), identity_batch.actions.len);
    try std.testing.expectEqual(
        coordinator.Result.handled,
        try coordinator.dispatch(&ports, identity_batch.generation, identity_batch.actions[0], credentials),
    );
    const peap_identity = try expectRequestCredentials(
        try coordinator.dispatch(&ports, identity_batch.generation, identity_batch.actions[1], credentials),
    );
    try std.testing.expectEqual(rj.session.CredentialPurpose.peap_identity, peap_identity);

    var protected_identity = try session.step(timestamp(5 * std.time.ns_per_s), .{ .credentials = credentials });
    defer protected_identity.deinit(std.testing.allocator);
    _ = try expectSessionInput(
        try coordinator.dispatch(&ports, protected_identity.generation, protected_identity.actions[0], credentials),
    );

    var challenge_buffer: [32]u8 = undefined;
    const challenge = innerRequest(&challenge_buffer, 2, .mschapv2, &.{ 1, 0x11 });
    var challenge_batch = try session.step(timestamp(6 * std.time.ns_per_s), .{ .tunnel_output = .{
        .generation = session.currentGeneration(),
        .output = .{
            .status = .established,
            .outbound_tls = "client-identity",
            .plaintext = challenge,
        },
    } });
    defer challenge_batch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), challenge_batch.actions.len);
    try std.testing.expectEqual(
        coordinator.Result.handled,
        try coordinator.dispatch(&ports, challenge_batch.generation, challenge_batch.actions[0], credentials),
    );
    try std.testing.expectError(
        error.CredentialsRequired,
        coordinator.dispatch(&ports, challenge_batch.generation, challenge_batch.actions[1], null),
    );
    const mschap_input = try expectSessionInput(
        try coordinator.dispatch(&ports, challenge_batch.generation, challenge_batch.actions[1], credentials),
    );
    try std.testing.expectEqualSlices(u8, &.{ 1, 0x11 }, fake.mschap_challenge[0..fake.mschap_challenge_len]);
    try std.testing.expectEqual(@as(usize, 1), fake.mschap_authenticate_calls);

    var mschap_response = try session.step(timestamp(7 * std.time.ns_per_s), mschap_input);
    defer mschap_response.deinit(std.testing.allocator);
    _ = try expectSessionInput(
        try coordinator.dispatch(&ports, mschap_response.generation, mschap_response.actions[0], credentials),
    );

    var success_buffer: [32]u8 = undefined;
    const success_request = innerRequest(&success_buffer, 3, .mschapv2, &.{ 3, 0 });
    var success_batch = try session.step(timestamp(8 * std.time.ns_per_s), .{ .tunnel_output = .{
        .generation = session.currentGeneration(),
        .output = .{
            .status = .established,
            .outbound_tls = "client-response",
            .plaintext = success_request,
        },
    } });
    defer success_batch.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        coordinator.Result.handled,
        try coordinator.dispatch(&ports, success_batch.generation, success_batch.actions[0], credentials),
    );
    const verified_input = try expectSessionInput(
        try coordinator.dispatch(&ports, success_batch.generation, success_batch.actions[1], credentials),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.mschap_verify_calls);

    var verified = try session.step(timestamp(9 * std.time.ns_per_s), verified_input);
    defer verified.deinit(std.testing.allocator);
    _ = try expectSessionInput(
        try coordinator.dispatch(&ports, verified.generation, verified.actions[0], credentials),
    );

    const terminal = terminalSuccess(0x17);
    var waiting = try session.step(timestamp(10 * std.time.ns_per_s), frameInput(&session, &terminal));
    defer waiting.deinit(std.testing.allocator);
    const dhcp_input = try expectSessionInput(
        try coordinator.dispatch(&ports, waiting.generation, waiting.actions[0], credentials),
    );
    try std.testing.expectEqual(rj.session.ExternalResult.dhcp_lease, std.meta.activeTag(dhcp_input.external_result.result));
    try std.testing.expectEqual(@as(usize, 4), fake.tls_operation_count);
    try std.testing.expectEqual(@as(usize, 1), fake.dhcp_reads);

    const stale_bytes = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(stale_bytes);
    const stale = try expectSessionInput(
        try coordinator.dispatch(&ports, initial_generation, .{ .tunnel_input = .{
            .operation = .process_server_tls,
            .bytes = stale_bytes,
        } }, credentials),
    );
    try std.testing.expectError(
        error.StaleGeneration,
        session.step(timestamp(11 * std.time.ns_per_s), stale),
    );
}

test "adapter failures and cancellation remain distinguishable" {
    var fake: Harness = .{ .send_error = error.SendFailed };
    const ports = fake.ports();

    var session = try rj.session.Session.init(std.testing.allocator, .{
        .source_mac = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
    });
    defer session.deinit();

    var started = try session.step(timestamp(0), .start);
    defer started.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.SendFailed,
        coordinator.dispatch(&ports, started.generation, started.actions[0], null),
    );

    fake.send_error = null;
    var canceled = try session.step(timestamp(std.time.ns_per_s), .cancel);
    defer canceled.deinit(std.testing.allocator);
    try dispatchSends(&ports, &canceled);
    try std.testing.expectEqual(@as(usize, 1), fake.send_count);

    fake.tls_error = error.CertificateRejected;
    const tunnel_bytes = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(tunnel_bytes);
    try std.testing.expectError(
        error.CertificateRejected,
        coordinator.dispatch(&ports, started.generation, .{ .tunnel_input = .{
            .operation = .process_server_tls,
            .bytes = tunnel_bytes,
        } }, null),
    );
}

test "direct lifecycle actions do not cross system ports" {
    var fake: Harness = .{};
    const ports = fake.ports();
    const result: rj.session.DirectAuthResult = .{
        .success = true,
        .server_message_gbk = null,
    };

    try std.testing.expectEqual(
        coordinator.Result{ .direct_auth_result = result },
        try coordinator.dispatch(&ports, .initial, .{ .direct_auth_result = result }, null),
    );
    try std.testing.expectEqual(
        coordinator.Result.reauth_required,
        try coordinator.dispatch(&ports, .initial, .reauth_required, null),
    );
}

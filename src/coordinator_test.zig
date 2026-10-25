const std = @import("std");
const coordinator = @import("coordinator.zig");
const platform = @import("platform.zig");
const rj = @import("rj-connect");

const Harness = struct {
    sent: []const u8 = &.{},

    fn ports(self: *Harness) platform.Ports {
        return .{
            .ethernet = .{ .context = self, .vtable = &ethernet_vtable },
            .network = undefined,
            .clock = undefined,
            .wait = undefined,
            .stop = undefined,
            .watchdog = undefined,
        };
    }
};

fn ethernetSend(context: *anyopaque, frame: []const u8, _: platform.Deadline) platform.Ethernet.Error!void {
    harness(context).sent = frame;
}

fn harness(context: *anyopaque) *Harness {
    return @ptrCast(@alignCast(context));
}

const ethernet_vtable: platform.Ethernet.VTable = .{ .send = ethernetSend, .tryReceive = undefined };

fn timestamp(nanoseconds: i96) platform.Timestamp {
    return .fromNanoseconds(nanoseconds);
}

test "v0.1.1 session exposes target facts and sends its start frame" {
    var session = try rj.session.Session.init(std.testing.allocator, .{
        .facts = .{ .source_mac = .{ 0, 1, 2, 3, 4, 5 } },
        .credentials = .{ .username = "alice", .password = "secret" },
    });
    defer session.deinit();

    var outcome = try session.step(timestamp(0), .start);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(rj.session.Phase.connecting, outcome.phase);
    try std.testing.expectEqual(@as(usize, 1), outcome.actions.len);

    var fake: Harness = .{};
    var ports = fake.ports();
    const result = try coordinator.dispatch(&ports, &outcome, 0, null);
    try std.testing.expectEqual(coordinator.Result.handled, result);
    try std.testing.expect(fake.sent.len > 0);
}

test "dispatch rejects an action index outside the outcome" {
    var fake: Harness = .{};
    var ports = fake.ports();
    const actions = [_]rj.session.Action{};
    const outcome: rj.session.Outcome = .{
        .actions = &actions,
        .previous_phase = .idle,
        .phase = .idle,
        .next_deadline = null,
        .failure = null,
        .generation = .initial,
        .terminal = null,
    };
    try std.testing.expectError(
        error.ActionOutOfRange,
        coordinator.dispatch(&ports, &outcome, 0, null),
    );
}

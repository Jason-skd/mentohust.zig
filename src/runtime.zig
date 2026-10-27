//! Production assembly of the client-owned system capabilities.
const std = @import("std");
const system = @import("system.zig");
const c = system.c;
const platform = @import("platform.zig");
const facts = @import("facts.zig");
const Ethernet = @import("ethernet.zig").Ethernet;
pub const Signals = @import("signals.zig").Signals;
pub const Watchdog = @import("watchdog.zig").Watchdog;
const rj = @import("rj-connect");

pub const Runtime = struct {
    io: std.Io,
    signals: *Signals,
    name: [c.IF_NAMESIZE:0]u8,
    deployment: facts.Deployment,
    initial_facts: rj.session.Facts,
    ethernet: Ethernet,
    watchdog: Watchdog,

    pub fn init(io: std.Io, signals: *Signals, interface_name: []const u8, deployment: facts.Deployment) !Runtime {
        if (interface_name.len == 0 or interface_name.len >= c.IF_NAMESIZE or std.mem.indexOfScalar(u8, interface_name, 0) != null)
            return error.InvalidInterface;
        var name: [c.IF_NAMESIZE:0]u8 = @splat(0);
        @memcpy(name[0..interface_name.len], interface_name);
        const snapshot: facts.Snapshot = .{ .name = std.mem.sliceTo(&name, 0), .deployment = deployment };
        const initial_facts = try snapshot.read();
        return .{
            .io = io,
            .signals = signals,
            .name = name,
            .deployment = deployment,
            .initial_facts = initial_facts,
            .ethernet = try Ethernet.init(snapshot.name, initial_facts.source_mac),
            .watchdog = .{ .io = io },
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.watchdog.deinit();
        self.ethernet.deinit();
        self.* = undefined;
    }

    pub fn ports(self: *Runtime) platform.Ports {
        return .{
            .ethernet = .{ .context = self, .vtable = &ethernet_vtable },
            .network = .{ .context = self, .vtable = &network_vtable },
            .clock = .{ .context = self, .vtable = &clock_vtable },
            .wait = .{ .context = self, .vtable = &wait_vtable },
            .stop = self.signals.stop(),
            .watchdog = self.watchdog.port(),
        };
    }

    pub fn readFacts(self: *Runtime, deadline: platform.Deadline) platform.NetworkState.Error!rj.session.Facts {
        if (deadlineExpired(self.io, deadline)) return error.DeadlineExceeded;
        const snapshot: facts.Snapshot = .{ .name = std.mem.sliceTo(&self.name, 0), .deployment = self.deployment };
        const result = try snapshot.read();
        if (deadlineExpired(self.io, deadline)) return error.DeadlineExceeded;
        if (!std.mem.eql(u8, &result.source_mac, &self.ethernet.source_mac)) return error.FactsUnavailable;
        return result;
    }

    fn send(context: *anyopaque, bytes: []const u8, deadline: platform.Deadline) platform.Ethernet.Error!void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.ethernet.send(self.io, self.signals, bytes, deadline);
    }

    fn tryReceive(context: *anyopaque, deadline: platform.Deadline) platform.Ethernet.Error!?[]const u8 {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (deadline) |end| if (std.Io.Clock.awake.now(self.io).compare(.gte, end)) return error.DeadlineExceeded;
        return self.ethernet.tryReceive();
    }

    fn readFactsAdapter(context: *anyopaque, deadline: platform.Deadline) platform.NetworkState.Error!rj.session.Facts {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.readFacts(deadline);
    }

    fn now(context: *anyopaque) platform.Clock.Error!platform.Timestamp {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return std.Io.Clock.awake.now(self.io);
    }

    fn wait(context: *anyopaque, options: platform.Wait.Options) platform.Wait.Error!void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (options.receive and self.ethernet.hasBuffered()) return;
        return self.signals.wait(self.io, if (options.receive) self.ethernet.fd else null, c.POLLIN, options.deadline);
    }

    const ethernet_vtable: platform.Ethernet.VTable = .{ .send = send, .tryReceive = tryReceive };
    const network_vtable: platform.NetworkState.VTable = .{ .readFacts = readFactsAdapter };
    const clock_vtable: platform.Clock.VTable = .{ .now = now };
    const wait_vtable: platform.Wait.VTable = .{ .wait = wait };
};

fn deadlineExpired(io: std.Io, deadline: platform.Deadline) bool {
    const end = deadline orelse return false;
    return std.Io.Clock.awake.now(io).compare(.gte, end);
}

test {
    _ = @import("system.zig");
    _ = @import("facts.zig");
    _ = @import("ethernet.zig");
    _ = @import("watchdog.zig");
    _ = @import("runtime_test.zig");
}

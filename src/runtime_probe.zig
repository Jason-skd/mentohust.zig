//! Isolated process checks for hard exit and real descriptor/session assembly.
const std = @import("std");
const builtin = @import("builtin");
const app = @import("mentohust");
const c = @import("system");
const rj = @import("rj-connect");
const client_mac = [6]u8{ 0, 1, 2, 3, 4, 5 };
const server_mac = [6]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };

pub fn main(init: std.process.Init) !void {
    var signals = try app.runtime.Signals.init();
    defer signals.deinit();
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    const Watchdog = app.runtime.Watchdog;
    var guard: Watchdog = .{ .io = init.io };
    defer guard.deinit();
    if (std.mem.eql(u8, mode, "watchdog")) {
        try guard.port().arm(.fromNanoseconds(50 * std.time.ns_per_ms), 99);
        while (true) _ = c.poll(null, 0, -1);
    }
    try guard.port().arm(.fromSeconds(10), 98);
    if (std.mem.eql(u8, mode, "signal")) {
        // A separate thread ensures delivery races safely with the wait call.
        const sender = try std.Thread.spawn(.{}, sendStop, .{});
        defer sender.join();
        const end = std.Io.Clock.awake.now(init.io).addDuration(.fromSeconds(2));
        while (true) {
            try signals.wait(init.io, null, c.POLLIN, end);
            if (try signals.tryNext()) |stop| {
                if (stop != .terminate) return error.WrongSignal;
                break;
            }
            if (std.Io.Clock.awake.now(init.io).compare(.gte, end)) return error.SignalTimedOut;
        }
    } else if (std.mem.eql(u8, mode, "session")) {
        try runSession(init, &signals);
    } else if (std.mem.eql(u8, mode, "prompt") or std.mem.eql(u8, mode, "prompt-signal")) {
        try runPrompt(init, &signals, std.mem.eql(u8, mode, "prompt-signal"));
    } else return error.UnknownMode;
}

const PromptDriver = struct {
    io: std.Io,
    master: c_int,
    slave: c_int,
    interrupt: bool,
    failure: ?anyerror = null,

    fn run(self: *PromptDriver) void {
        self.drive() catch |err| {
            self.failure = err;
            sendStop();
        };
    }

    fn drive(self: *PromptDriver) !void {
        var descriptor: c.struct_pollfd = .{ .fd = self.master, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&descriptor, 1, 2000) != 1) return error.PromptTimedOut;
        var output: [128]u8 = undefined;
        const count = c.read(self.master, &output, output.len);
        if (count <= 0 or std.mem.indexOf(u8, output[0..@intCast(count)], "Password: ") == null) return error.MissingPrompt;
        const end = std.Io.Clock.awake.now(self.io).addDuration(.fromSeconds(2));
        while (true) {
            var term: c.struct_termios = undefined;
            if (c.tcgetattr(self.slave, &term) != 0) return error.TerminalFailed;
            if (term.c_lflag & c.ECHO == 0) break;
            if (std.Io.Clock.awake.now(self.io).compare(.gte, end)) return error.EchoNotDisabled;
            std.Thread.yield() catch return error.TerminalFailed;
        }
        const text: []const u8 = if (self.interrupt) "test-secret" else "test-secret\n";
        if (c.write(self.master, text.ptr, text.len) != text.len) return error.TerminalFailed;
        if (self.interrupt) sendStop();
    }
};

fn runPrompt(init: std.process.Init, signals: *app.runtime.Signals, interrupt: bool) !void {
    const master = c.posix_openpt(c.O_RDWR | c.O_NOCTTY);
    if (master < 0) {
        std.log.err("posix_openpt failed: {t}", .{std.c.errno(master)});
        return error.PtyUnavailable;
    }
    defer _ = c.close(master);
    if (c.fcntl(master, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.PtyUnavailable;
    if (c.grantpt(master) != 0 or c.unlockpt(master) != 0) return error.PtyUnavailable;
    const name = c.ptsname(master);
    if (name == null) return error.PtyUnavailable;
    const slave = c.open(name, c.O_RDWR | c.O_NOCTTY);
    if (slave < 0) return error.PtyUnavailable;
    defer _ = c.close(slave);
    var original: c.struct_termios = undefined;
    if (c.tcgetattr(slave, &original) != 0 or original.c_lflag & c.ECHO == 0) return error.TerminalFailed;
    var driver: PromptDriver = .{ .io = init.io, .master = master, .slave = slave, .interrupt = interrupt };
    const thread = try std.Thread.spawn(.{}, PromptDriver.run, .{&driver});
    var joined = false;
    defer if (!joined) thread.join();
    var prompt = app.terminal.TerminalPrompt.init(init.io, signals);
    prompt.input = .{ .handle = slave, .flags = .{ .nonblocking = false } };
    prompt.output = .{ .handle = slave, .flags = .{ .nonblocking = false } };
    var bytes: [app.config.max_prompt_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &bytes);
    const result = prompt.interface().read(.secret, "Password: ", &bytes);
    thread.join();
    joined = true;
    if (driver.failure) |err| return err;
    if (interrupt) {
        if (result) |_| return error.PromptWasNotInterrupted else |err| if (err != error.Interrupted) return err;
        if (prompt.interruptedSignal() != .terminate or !std.mem.allEqual(u8, &bytes, 0)) return error.InterruptedPromptFailed;
    } else if (!std.mem.eql(u8, try result, "test-secret")) return error.WrongPassword;
    var restored: c.struct_termios = undefined;
    if (c.tcgetattr(slave, &restored) != 0 or restored.c_lflag != original.c_lflag) return error.EchoNotRestored;
    var output: [128]u8 = undefined;
    const count = c.read(master, &output, output.len);
    if (count > 0 and std.mem.indexOf(u8, output[0..@intCast(count)], "test-secret") != null) return error.PasswordEchoed;
}

fn sendStop() void {
    _ = c.kill(c.getpid(), c.SIGTERM);
}

const Server = struct {
    fd: c_int,
    failure: ?anyerror = null,
    logoffs: usize = 0,

    fn run(self: *Server) void {
        self.exchange() catch |err| {
            self.failure = err;
            sendStop();
        };
    }

    fn receive(self: *Server, output: []u8) ![]const u8 {
        var descriptor: c.struct_pollfd = .{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&descriptor, 1, 2000) != 1 or descriptor.revents & c.POLLIN == 0) return error.ServerTimedOut;
        const count = c.read(self.fd, output.ptr, output.len);
        if (count <= 0) return error.ServerReadFailed;
        return output[0..@intCast(count)];
    }

    fn send(self: *Server, bytes: []const u8) !void {
        var buffer: [2048]u8 = @splat(0);
        const payload = if (builtin.os.tag == .macos) blk: {
            const header: *align(1) c.struct_bpf_hdr = @ptrCast(&buffer);
            header.bh_caplen = @intCast(bytes.len);
            header.bh_datalen = @intCast(bytes.len);
            header.bh_hdrlen = @sizeOf(c.struct_bpf_hdr);
            @memcpy(buffer[@sizeOf(c.struct_bpf_hdr)..][0..bytes.len], bytes);
            break :blk buffer[0 .. @sizeOf(c.struct_bpf_hdr) + bytes.len];
        } else bytes;
        if (c.write(self.fd, payload.ptr, payload.len) != payload.len) return error.ServerWriteFailed;
    }

    fn exchange(self: *Server) !void {
        const eapol = rj.protocol.eapol;
        var input: [2048]u8 = undefined;
        var output: [128]u8 = undefined;
        const start = try eapol.decode(try self.receive(&input));
        if (start.packet_type != .start or !std.mem.eql(u8, &start.source, &client_mac)) return error.UnexpectedStart;
        try self.send(try eapol.encodeEap(client_mac, server_mac, .request, 1, .identity, "", &output));
        const identity = try eapol.decode(try self.receive(&input));
        if (identity.eap.?.type != .identity or !std.mem.eql(u8, identity.eap.?.data, "alice")) return error.UnexpectedIdentity;
        const challenge = [_]u8{ 16, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        try self.send(try eapol.encodeEap(client_mac, server_mac, .request, 2, .md5_challenge, &challenge, &output));
        const response = try eapol.decode(try self.receive(&input));
        if (response.eap.?.type != .md5_challenge or response.eap.?.identifier != 2 or response.eap.?.data[0] != 16) return error.UnexpectedResponse;
        try self.send(try eapol.encodeEap(client_mac, server_mac, .success, 2, null, "", &output));
        const logoff = try eapol.decode(try self.receive(&input));
        if (logoff.packet_type != .logoff) return error.UnexpectedLogoff;
        self.logoffs += 1;
    }
};

const Report = struct {
    online: bool = false,
    closed: bool = false,

    fn write(context: *anyopaque, event: app.lifecycle.Event) app.lifecycle.Reporter.Error!void {
        const self: *Report = @ptrCast(@alignCast(context));
        switch (event) {
            .online => {
                self.online = true;
                sendStop();
            },
            .shutdown_completed => self.closed = true,
            else => {},
        }
    }
    const vtable: app.lifecycle.Reporter.VTable = .{ .write = write };
};

fn readFacts(_: *anyopaque, _: app.platform.Deadline) app.platform.NetworkState.Error!rj.session.Facts {
    return .{ .source_mac = client_mac };
}
const network_vtable: app.platform.NetworkState.VTable = .{ .readFacts = readFacts };

fn runSession(init: std.process.Init, signals: *app.runtime.Signals) !void {
    var pair: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_DGRAM, 0, &pair) != 0) return error.SocketPairFailed;
    defer _ = c.close(pair[1]);
    var runtime: app.runtime.Runtime = .{
        .io = init.io,
        .signals = signals,
        .name = @splat(0),
        .deployment = .{},
        .ethernet = .{ .fd = pair[0], .source_mac = client_mac },
        .watchdog = .{ .io = init.io },
    };
    defer runtime.deinit();
    if (c.fcntl(pair[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.NonblockingFailed;
    var server: Server = .{ .fd = pair[1] };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    var joined = false;
    defer if (!joined) thread.join();
    var session = try rj.session.Session.init(init.gpa, .{
        .facts = .{ .source_mac = client_mac },
        .credentials = .{ .username = "alice", .password = "secret" },
        .start_timeout = .fromSeconds(2),
        .auth_timeout = .fromSeconds(2),
    });
    defer session.deinit();
    var ports = runtime.ports();
    ports.network = .{ .context = &runtime, .vtable = &network_vtable };
    var report: Report = .{};
    const termination = app.lifecycle.run(&session, ports, .{
        .retry_limit = .{ .limited = 0 },
        .backoff_initial = .fromSeconds(1),
        .backoff_max = .fromSeconds(1),
        .shutdown_timeout = .fromSeconds(1),
    }, .{ .context = &report, .vtable = &Report.vtable });
    thread.join();
    joined = true;
    if (server.failure) |err| return err;
    if (server.logoffs != 1) return error.WrongLogoffCount;
    if (termination.exitCode() != 143 or !report.online or !report.closed) return error.SessionFailed;
}

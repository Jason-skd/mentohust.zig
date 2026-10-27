//! Raw Ethernet ownership, frame selection, and Darwin BPF batch handling.
const builtin = @import("builtin");
const std = @import("std");
const system = @import("system.zig");
const c = system.c;
const platform = @import("platform.zig");
const Signals = @import("signals.zig").Signals;

pub const OpenError = error{ InterfaceUnavailable, PermissionDenied, UnsupportedLink, IoFailed };
pub const default_send_timeout = std.Io.Duration.fromSeconds(5);
const ethertype: u16 = 0x888e;

pub const Ethernet = struct {
    fd: c_int,
    source_mac: [6]u8,
    buffer: [65536]u8 = undefined,
    read_size: usize = 65536,
    batch_len: usize = 0,
    cursor: usize = 0,

    pub fn init(name: [:0]const u8, source_mac: [6]u8) OpenError!Ethernet {
        if (builtin.os.tag == .macos) return openBpf(name, source_mac);
        if (builtin.os.tag != .linux) return error.UnsupportedLink;
        const index = c.if_nametoindex(name);
        if (index == 0) return error.InterfaceUnavailable;
        const protocol = std.mem.nativeToBig(u16, ethertype);
        const fd = c.socket(c.AF_PACKET, c.SOCK_RAW | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, protocol);
        if (fd < 0) return openError(std.c.errno(fd));
        errdefer system.close(fd);
        var address = std.mem.zeroes(c.struct_sockaddr_ll);
        address.sll_family = c.AF_PACKET;
        address.sll_protocol = protocol;
        address.sll_ifindex = @intCast(index);
        if (c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.InterfaceUnavailable;
        for ([_][6]u8{ .{ 1, 0x80, 0xc2, 0, 0, 3 }, .{ 1, 0xd0, 0xf8, 0, 0, 3 } }) |group| {
            var membership = std.mem.zeroes(c.struct_packet_mreq);
            membership.mr_ifindex = @intCast(index);
            membership.mr_type = c.PACKET_MR_MULTICAST;
            membership.mr_alen = 6;
            @memcpy(membership.mr_address[0..6], &group);
            if (c.setsockopt(fd, c.SOL_PACKET, c.PACKET_ADD_MEMBERSHIP, &membership, @sizeOf(@TypeOf(membership))) != 0) return error.IoFailed;
        }
        return .{ .fd = fd, .source_mac = source_mac };
    }

    pub fn deinit(self: *Ethernet) void {
        system.close(self.fd);
        self.* = undefined;
    }

    pub fn hasBuffered(self: *const Ethernet) bool {
        return self.cursor < self.batch_len;
    }

    /// Direct callers without a lifecycle deadline still get a bounded send.
    /// Lifecycle-managed sends always pass an absolute deadline.
    pub fn send(self: *Ethernet, io: std.Io, signals: *Signals, bytes: []const u8, deadline: platform.Deadline) platform.Ethernet.Error!void {
        const end = deadline orelse std.Io.Clock.awake.now(io).addDuration(default_send_timeout);
        while (true) {
            if (std.Io.Clock.awake.now(io).compare(.gte, end)) return error.DeadlineExceeded;
            const rc = if (builtin.os.tag == .macos)
                c.write(self.fd, bytes.ptr, bytes.len)
            else
                c.send(self.fd, bytes.ptr, bytes.len, c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
            if (rc >= 0) {
                if (@as(usize, @intCast(rc)) != bytes.len) return error.SendFailed;
                return;
            }
            switch (std.c.errno(rc)) {
                .INTR => continue,
                .AGAIN => {
                    if (signals.isPending() catch return error.SendFailed) return error.SendFailed;
                    signals.wait(io, self.fd, c.POLLOUT, end) catch return error.SendFailed;
                    if (signals.isPending() catch return error.SendFailed) return error.SendFailed;
                },
                .BADF, .NODEV, .NXIO => return error.InterfaceClosed,
                else => return error.SendFailed,
            }
        }
    }

    pub fn tryReceive(self: *Ethernet) platform.Ethernet.Error!?[]const u8 {
        // Process at most one rejected record per call so unrelated traffic
        // cannot starve the lifecycle's signal and deadline checks.
        if (builtin.os.tag == .macos) {
            if (!self.hasBuffered()) {
                const count = c.read(self.fd, &self.buffer, self.read_size);
                if (count < 0) return receiveError(std.c.errno(count));
                if (count == 0) return error.InterfaceClosed;
                self.batch_len = @intCast(count);
                self.cursor = 0;
            }
            const frame = nextBpfRecord(self.buffer[0..self.batch_len], &self.cursor) catch {
                self.cursor = self.batch_len;
                return error.ReceiveFailed;
            };
            return if (accepts(frame, self.source_mac)) frame else null;
        }
        const count = c.recv(self.fd, &self.buffer, self.buffer.len, c.MSG_DONTWAIT | c.MSG_TRUNC);
        if (count < 0) return receiveError(std.c.errno(count));
        if (count == 0) return error.InterfaceClosed;
        if (count > self.buffer.len) return error.ReceiveFailed;
        const frame = self.buffer[0..@intCast(count)];
        return if (accepts(frame, self.source_mac)) frame else null;
    }
};

fn receiveError(err: std.c.E) platform.Ethernet.Error!?[]const u8 {
    return switch (err) {
        .AGAIN, .INTR => null,
        .BADF, .NODEV, .NXIO => error.InterfaceClosed,
        else => error.ReceiveFailed,
    };
}

fn openError(err: std.c.E) OpenError {
    return switch (err) {
        .ACCES, .PERM => error.PermissionDenied,
        .NODEV, .NXIO, .NOENT => error.InterfaceUnavailable,
        else => error.IoFailed,
    };
}

fn openBpf(name: [:0]const u8, source_mac: [6]u8) OpenError!Ethernet {
    var fd: c_int = -1;
    for (0..256) |index| {
        var path: [32]u8 = undefined;
        const path_text = std.fmt.bufPrint(path[0 .. path.len - 1], "/dev/bpf{d}", .{index}) catch unreachable;
        path[path_text.len] = 0;
        const fd_path = path[0..path_text.len :0];
        fd = c.open(fd_path, c.O_RDWR | c.O_NONBLOCK | c.O_CLOEXEC);
        if (fd >= 0) break;
        const err = std.c.errno(fd);
        if (err != .BUSY) return openError(err);
    }
    if (fd < 0) return error.IoFailed;
    errdefer system.close(fd);
    var request = std.mem.zeroes(c.struct_ifreq);
    if (name.len >= request.ifr_name.len) return error.InterfaceUnavailable;
    @memcpy(request.ifr_name[0..name.len], name);
    if (c.ioctl(fd, c.BIOCSETIF, &request) != 0) return error.InterfaceUnavailable;
    var link_type: c_uint = 0;
    if (c.ioctl(fd, c.BIOCGDLT, &link_type) != 0) return error.IoFailed;
    if (link_type != c.DLT_EN10MB) return error.UnsupportedLink;
    // Receive discovery multicast independently of OS supplicant subscriptions.
    // The descriptor owns the promiscuous-mode reference until close.
    if (c.ioctl(fd, c.BIOCPROMISC, @as(?*anyopaque, null)) != 0) return error.IoFailed;
    var read_size: c_uint = 0;
    if (c.ioctl(fd, c.BIOCGBLEN, &read_size) != 0 or read_size == 0 or read_size > 65536) return error.IoFailed;
    var enabled: c_uint = 1;
    var disabled: c_uint = 0;
    if (c.ioctl(fd, c.BIOCIMMEDIATE, &enabled) != 0 or
        c.ioctl(fd, c.BIOCSHDRCMPLT, &enabled) != 0 or
        c.ioctl(fd, c.BIOCSSEESENT, &disabled) != 0) return error.IoFailed;
    var instructions = [_]c.struct_bpf_insn{
        .{ .code = c.BPF_LD | c.BPF_H | c.BPF_ABS, .jt = 0, .jf = 0, .k = 12 },
        .{ .code = c.BPF_JMP | c.BPF_JEQ | c.BPF_K, .jt = 0, .jf = 1, .k = ethertype },
        .{ .code = c.BPF_RET | c.BPF_K, .jt = 0, .jf = 0, .k = 65535 },
        .{ .code = c.BPF_RET | c.BPF_K, .jt = 0, .jf = 0, .k = 0 },
    };
    var program: c.struct_bpf_program = .{ .bf_len = instructions.len, .bf_insns = &instructions };
    if (c.ioctl(fd, c.BIOCSETF, &program) != 0) return error.IoFailed;
    return .{ .fd = fd, .source_mac = source_mac, .read_size = read_size };
}

fn accepts(frame: []const u8, source: [6]u8) bool {
    if (frame.len < 14 or std.mem.readInt(u16, frame[12..14], .big) != ethertype) return false;
    if (std.mem.eql(u8, frame[6..12], &source)) return false;
    return std.mem.eql(u8, frame[0..6], &source) or frame[0] & 1 != 0;
}

fn nextBpfRecord(batch: []const u8, cursor: *usize) error{InvalidRecord}![]const u8 {
    if (builtin.os.tag != .macos) unreachable;
    const min_header = @offsetOf(c.struct_bpf_hdr, "bh_hdrlen") + @sizeOf(c_ushort);
    if (cursor.* > batch.len or batch.len - cursor.* < min_header) return error.InvalidRecord;
    const bytes = batch[cursor.*..];
    // A BPF record is only word-aligned, not necessarily aligned for the C type.
    const header: *align(1) const c.struct_bpf_hdr = @ptrCast(bytes.ptr);
    const length: usize = header.bh_caplen;
    const offset: usize = header.bh_hdrlen;
    if (offset < min_header or offset > bytes.len or length > bytes.len - offset or length != header.bh_datalen) return error.InvalidRecord;
    const total = offset + length;
    const aligned = std.mem.alignForward(usize, total, c.BPF_ALIGNMENT);
    cursor.* += @min(aligned, bytes.len);
    return bytes[offset..total];
}

test "Ethernet selection excludes unrelated traffic and local transmission echoes" {
    const mac = [6]u8{ 0, 1, 2, 3, 4, 5 };
    var frame = [_]u8{ 0, 1, 2, 3, 4, 5, 0, 6, 7, 8, 9, 10, 0x88, 0x8e };
    try std.testing.expect(accepts(&frame, mac));
    @memcpy(frame[6..12], &mac);
    try std.testing.expect(!accepts(&frame, mac));
    frame[6] = 8;
    frame[0] = 8;
    try std.testing.expect(!accepts(&frame, mac));
    frame[0] = 1;
    try std.testing.expect(accepts(&frame, mac));
    frame[12] = 8;
    try std.testing.expect(!accepts(&frame, mac));
    try std.testing.expect(!accepts(frame[0..5], mac));
}

test "a corrupt BPF batch is discarded so receive can recover" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var ethernet: Ethernet = .{ .fd = -1, .source_mac = .{ 0, 1, 2, 3, 4, 5 }, .batch_len = 4 };
    try std.testing.expectError(error.ReceiveFailed, ethernet.tryReceive());
    try std.testing.expect(!ethernet.hasBuffered());
}

test "BPF batch preserves both records and rejects truncated capture lengths" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bytes: [128]u8 = @splat(0);
    var first: *align(1) c.struct_bpf_hdr = @ptrCast(&bytes);
    first.bh_hdrlen = 18;
    first.bh_caplen = 3;
    first.bh_datalen = 3;
    @memcpy(bytes[18..21], "one");
    var second: *align(1) c.struct_bpf_hdr = @ptrCast(bytes[24..].ptr);
    second.bh_hdrlen = 18;
    second.bh_caplen = 3;
    second.bh_datalen = 3;
    @memcpy(bytes[42..45], "two");
    var cursor: usize = 0;
    try std.testing.expectEqualStrings("one", try nextBpfRecord(bytes[0..45], &cursor));
    try std.testing.expectEqualStrings("two", try nextBpfRecord(bytes[0..45], &cursor));
    try std.testing.expectEqual(@as(usize, 45), cursor);
    cursor = 0;
    first.bh_caplen = 129;
    try std.testing.expectError(error.InvalidRecord, nextBpfRecord(&bytes, &cursor));
}

//! Target system headers are the authority for socket, signal, and BPF layouts.
pub const c = @import("system");
const std = @import("std");

pub fn close(fd: c_int) void {
    _ = c.close(fd);
}

pub fn nonblocking(fd: c_int) error{IoFailed}!void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0 or
        c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.IoFailed;
}

/// One syscall, preserving EINTR so callers can recheck their absolute deadline.
pub fn poll(io: std.Io, fds: []c.struct_pollfd, deadline: ?std.Io.Timestamp) error{WaitFailed}!void {
    const timeout = if (deadline) |end| timeoutMillis(std.Io.Clock.awake.now(io), end) else -1;
    const rc = c.poll(fds.ptr, @intCast(fds.len), timeout);
    if (rc < 0 and std.c.errno(rc) != .INTR) return error.WaitFailed;
    for (fds) |fd| {
        if (fd.revents & c.POLLNVAL != 0) return error.WaitFailed;
    }
}

fn timeoutMillis(now: std.Io.Timestamp, end: std.Io.Timestamp) c_int {
    const remaining = end.nanoseconds - now.nanoseconds;
    if (remaining <= 0) return 0;
    return @intCast(@min(@divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(c_int)));
}

test "poll timeout rounds up without moving the absolute deadline" {
    try std.testing.expectEqual(@as(c_int, 0), timeoutMillis(.fromNanoseconds(2), .fromNanoseconds(1)));
    try std.testing.expectEqual(@as(c_int, 1), timeoutMillis(.zero, .fromNanoseconds(1)));
    try std.testing.expectEqual(std.math.maxInt(c_int), timeoutMillis(.zero, .fromNanoseconds(std.math.maxInt(i64))));
}

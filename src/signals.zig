//! An owned kernel signal queue. Install on the main thread before starting
//! I/O workers; Linux workers must inherit the blocked termination-signal mask.
const builtin = @import("builtin");
const std = @import("std");
const system = @import("system.zig");
const c = system.c;
const platform = @import("platform.zig");

pub const Signals = struct {
    fd: c_int,
    saved: if (builtin.os.tag == .macos) [2]std.posix.Sigaction else c.sigset_t,

    pub fn init() error{SignalUnavailable}!Signals {
        if (builtin.os.tag == .macos) {
            const fd = c.kqueue();
            if (fd < 0) return error.SignalUnavailable;
            errdefer system.close(fd);
            if (c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.SignalUnavailable;
            var changes = [_]c.struct_kevent{
                .{ .ident = c.SIGINT, .filter = c.EVFILT_SIGNAL, .flags = c.EV_ADD | c.EV_CLEAR, .fflags = 0, .data = 0, .udata = null },
                .{ .ident = c.SIGTERM, .filter = c.EVFILT_SIGNAL, .flags = c.EV_ADD | c.EV_CLEAR, .fflags = 0, .data = 0, .udata = null },
            };
            if (c.kevent(fd, &changes, changes.len, null, 0, null) < 0) return error.SignalUnavailable;
            const ignore: std.posix.Sigaction = .{
                .handler = .{ .handler = std.posix.SIG.IGN },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            var result: Signals = .{ .fd = fd, .saved = undefined };
            std.posix.sigaction(.INT, &ignore, &result.saved[0]);
            std.posix.sigaction(.TERM, &ignore, &result.saved[1]);
            return result;
        } else if (builtin.os.tag == .linux) {
            var mask: c.sigset_t = undefined;
            _ = c.sigemptyset(&mask);
            _ = c.sigaddset(&mask, c.SIGINT);
            _ = c.sigaddset(&mask, c.SIGTERM);
            var saved: c.sigset_t = undefined;
            if (c.sigprocmask(c.SIG_BLOCK, &mask, &saved) != 0) return error.SignalUnavailable;
            errdefer _ = c.sigprocmask(c.SIG_SETMASK, &saved, null);
            const fd = c.signalfd(-1, &mask, c.SFD_NONBLOCK | c.SFD_CLOEXEC);
            if (fd < 0) return error.SignalUnavailable;
            return .{ .fd = fd, .saved = saved };
        } else return error.SignalUnavailable;
    }

    pub fn deinit(self: *Signals) void {
        if (builtin.os.tag == .macos) {
            std.posix.sigaction(.INT, &self.saved[0], null);
            std.posix.sigaction(.TERM, &self.saved[1], null);
        } else if (builtin.os.tag == .linux) {
            _ = c.sigprocmask(c.SIG_SETMASK, &self.saved, null);
        }
        system.close(self.fd);
        self.* = undefined;
    }

    pub fn isPending(self: *Signals) error{WaitFailed}!bool {
        var descriptor: c.struct_pollfd = .{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        const rc = c.poll(&descriptor, 1, 0);
        if (rc < 0) {
            if (std.c.errno(rc) == .INTR) return true;
            return error.WaitFailed;
        }
        if (descriptor.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return error.WaitFailed;
        return descriptor.revents & c.POLLIN != 0;
    }

    pub fn stop(self: *Signals) platform.Stop {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn tryNext(self: *Signals) platform.Stop.Error!?platform.Stop.Request {
        const signal = if (builtin.os.tag == .macos) blk: {
            var event: c.struct_kevent = undefined;
            const zero: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
            const rc = c.kevent(self.fd, null, 0, &event, 1, &zero);
            if (rc == 0) return null;
            if (rc < 0) {
                if (std.c.errno(rc) == .INTR) return null;
                return error.SignalWaitFailed;
            }
            break :blk event.ident;
        } else blk: {
            var info: c.struct_signalfd_siginfo = undefined;
            const rc = c.read(self.fd, &info, @sizeOf(@TypeOf(info)));
            if (rc < 0) {
                if (std.c.errno(rc) == .AGAIN or std.c.errno(rc) == .INTR) return null;
                return error.SignalWaitFailed;
            }
            if (rc != @sizeOf(@TypeOf(info))) return error.SignalWaitFailed;
            break :blk info.ssi_signo;
        };
        return switch (signal) {
            c.SIGINT => .interrupt,
            c.SIGTERM => .terminate,
            else => error.SignalWaitFailed,
        };
    }

    /// Does not consume signals or input readiness. Null input disables network
    /// wakes during backoff while retaining the signal queue in the poll set.
    pub fn wait(self: *Signals, io: std.Io, input: ?c_int, events: c_short, deadline: platform.Deadline) error{WaitFailed}!void {
        var fds = [_]c.struct_pollfd{
            .{ .fd = self.fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = input orelse -1, .events = events, .revents = 0 },
        };
        try system.poll(io, &fds, deadline);
        if (fds[0].revents & (c.POLLERR | c.POLLHUP) != 0) return error.WaitFailed;
        // Network errors wake the caller, whose next receive maps the failure.
    }

    fn tryNextAdapter(context: *anyopaque) platform.Stop.Error!?platform.Stop.Request {
        const self: *Signals = @ptrCast(@alignCast(context));
        return self.tryNext();
    }
    const vtable: platform.Stop.VTable = .{ .tryNext = tryNextAdapter };
};

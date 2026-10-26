//! POSIX terminal prompts sharing the command's owned signal source.
const std = @import("std");
const config = @import("config.zig");
const platform = @import("platform.zig");
const Signals = @import("signals.zig").Signals;
const c = @import("system.zig").c;

pub const TerminalPrompt = struct {
    io: std.Io,
    signals: *Signals,
    input: std.Io.File,
    output: std.Io.File,
    interrupted_signal: ?platform.Stop.Request = null,

    pub fn init(io: std.Io, signals: *Signals) TerminalPrompt {
        return .{ .io = io, .signals = signals, .input = .stdin(), .output = .stderr() };
    }

    pub fn interface(self: *TerminalPrompt) config.Prompt {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn interruptedSignal(self: TerminalPrompt) ?platform.Stop.Request {
        return self.interrupted_signal;
    }

    fn checkStop(self: *TerminalPrompt) config.Prompt.Error!void {
        if (self.signals.tryNext() catch return error.ReadFailed) |signal| {
            self.interrupted_signal = signal;
            return error.Interrupted;
        }
    }

    fn read(context: *anyopaque, kind: config.PromptKind, label: []const u8, output: *[config.max_prompt_bytes]u8) config.Prompt.Error![]const u8 {
        const self: *TerminalPrompt = @ptrCast(@alignCast(context));
        self.interrupted_signal = null;
        errdefer std.crypto.secureZero(u8, output);
        try self.checkStop();
        if (!(self.input.isTty(self.io) catch return error.ReadFailed)) return error.NotTerminal;
        self.output.writeStreamingAll(self.io, label) catch return error.WriteFailed;
        const restore_echo = if (kind == .secret) try disableEcho(self.input) else null;
        var echo_restored = false;
        defer if (!echo_restored) {
            if (restore_echo) |termios| restoreEcho(self.input, termios) catch {};
        };
        const line = try self.readLineInterruptible(output);
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (kind == .secret) self.output.writeStreamingAll(self.io, "\n") catch return error.WriteFailed;
        try self.checkStop();
        if (restore_echo) |termios| try restoreEcho(self.input, termios);
        echo_restored = true;
        return trimmed;
    }

    fn readLineInterruptible(self: *TerminalPrompt, output: *[config.max_prompt_bytes]u8) config.Prompt.Error![]const u8 {
        var total: usize = 0;
        while (true) {
            try self.checkStop();
            self.signals.wait(self.io, self.input.handle, c.POLLIN, null) catch return error.ReadFailed;
            try self.checkStop();
            // The queue can wake spuriously; do not turn that into a blocking read.
            var descriptor: c.struct_pollfd = .{ .fd = self.input.handle, .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&descriptor, 1, 0);
            if (ready < 0) {
                if (std.c.errno(ready) == .INTR) continue;
                return error.ReadFailed;
            }
            if (descriptor.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL) != 0) return error.ReadFailed;
            if (descriptor.revents & c.POLLIN == 0) continue;
            const count = c.read(self.input.handle, output[total..].ptr, output.len - total);
            if (count < 0) {
                if (std.c.errno(count) == .INTR or std.c.errno(count) == .AGAIN) continue;
                return error.ReadFailed;
            }
            if (count == 0) return error.ReadFailed;
            total += @intCast(count);
            if (std.mem.indexOfScalar(u8, output[0..total], '\n')) |end| return output[0..end];
            if (total == output.len) return error.TooLong;
        }
    }

    const vtable: config.Prompt.VTable = .{ .read = read };
};

fn disableEcho(file: std.Io.File) config.Prompt.Error!std.posix.termios {
    const original = std.posix.tcgetattr(file.handle) catch return error.ReadFailed;
    var hidden = original;
    hidden.lflag.ECHO = false;
    std.posix.tcsetattr(file.handle, .NOW, hidden) catch return error.ReadFailed;
    return original;
}

fn restoreEcho(file: std.Io.File, termios: std.posix.termios) config.Prompt.Error!void {
    std.posix.tcsetattr(file.handle, .NOW, termios) catch return error.ReadFailed;
}

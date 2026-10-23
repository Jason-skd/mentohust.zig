//! POSIX terminal prompt adapter with signal-safe echo restoration.

const std = @import("std");
const config = @import("config.zig");
const platform = @import("platform.zig");

var pending_signal: std.atomic.Value(u8) = .init(0);

pub const TerminalPrompt = struct {
    io: std.Io,
    input: std.Io.File,
    output: std.Io.File,
    interrupted_signal: ?platform.Stop.Request = null,

    pub fn init(io: std.Io) TerminalPrompt {
        return .{
            .io = io,
            .input = .stdin(),
            .output = .stderr(),
        };
    }

    pub fn interface(self: *TerminalPrompt) config.Prompt {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn interruptedSignal(self: TerminalPrompt) ?platform.Stop.Request {
        return self.interrupted_signal;
    }

    fn read(
        context: *anyopaque,
        kind: config.PromptKind,
        label: []const u8,
        output: *[config.max_prompt_bytes]u8,
    ) config.Prompt.Error![]const u8 {
        const self: *TerminalPrompt = @ptrCast(@alignCast(context));
        self.interrupted_signal = null;
        pending_signal.store(0, .seq_cst);

        if (!(self.input.isTty(self.io) catch return error.ReadFailed)) {
            return error.NotTerminal;
        }

        const signals = installPromptSignals();
        defer signals.restore();
        self.output.writeStreamingAll(self.io, label) catch return error.WriteFailed;

        const restore_echo = if (kind == .secret) try disableEcho(self.input) else null;
        defer if (restore_echo) |termios| restoreEcho(self.input, termios);

        var reader_buffer: [config.max_prompt_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &reader_buffer);
        var reader = self.input.readerStreaming(self.io, &reader_buffer);
        const line_result = reader.interface.takeDelimiterExclusive('\n');
        if (pendingRequest()) |signal| {
            self.interrupted_signal = signal;
            return error.Interrupted;
        }
        const line = line_result catch |err| switch (err) {
            error.StreamTooLong => return error.TooLong,
            else => return error.ReadFailed,
        };
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len > output.len) return error.TooLong;
        @memcpy(output[0..trimmed.len], trimmed);

        if (kind == .secret) {
            self.output.writeStreamingAll(self.io, "\n") catch return error.WriteFailed;
        }
        if (pendingRequest()) |signal| {
            self.interrupted_signal = signal;
            std.crypto.secureZero(u8, output);
            return error.Interrupted;
        }
        return output[0..trimmed.len];
    }

    const vtable: config.Prompt.VTable = .{ .read = read };
};

const InstalledSignals = struct {
    interrupt: std.posix.Sigaction,
    terminate: std.posix.Sigaction,

    fn restore(self: InstalledSignals) void {
        std.posix.sigaction(.INT, &self.interrupt, null);
        std.posix.sigaction(.TERM, &self.terminate, null);
    }
};

fn installPromptSignals() InstalledSignals {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handlePromptSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var signals: InstalledSignals = undefined;
    std.posix.sigaction(.INT, &action, &signals.interrupt);
    std.posix.sigaction(.TERM, &action, &signals.terminate);
    return signals;
}

fn handlePromptSignal(signal: std.posix.SIG) callconv(.c) void {
    const code: u8 = switch (signal) {
        .INT => 130,
        .TERM => 143,
        else => return,
    };
    pending_signal.store(code, .seq_cst);
}

fn pendingRequest() ?platform.Stop.Request {
    return switch (pending_signal.load(.seq_cst)) {
        130 => .interrupt,
        143 => .terminate,
        else => null,
    };
}

fn disableEcho(file: std.Io.File) config.Prompt.Error!std.posix.termios {
    const original = std.posix.tcgetattr(file.handle) catch return error.ReadFailed;
    var hidden = original;
    hidden.lflag.ECHO = false;
    std.posix.tcsetattr(file.handle, .NOW, hidden) catch return error.ReadFailed;
    return original;
}

fn restoreEcho(file: std.Io.File, termios: std.posix.termios) void {
    std.posix.tcsetattr(file.handle, .NOW, termios) catch {};
}

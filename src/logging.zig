//! Human-readable lifecycle reporting.

const std = @import("std");
const lifecycle = @import("lifecycle.zig");

pub const StderrReporter = struct {
    io: std.Io,
    file: std.Io.File = .stderr(),

    pub fn reporter(self: *StderrReporter) lifecycle.Reporter {
        return .{ .context = self, .vtable = &vtable };
    }

    fn write(context: *anyopaque, event: lifecycle.Event) lifecycle.Reporter.Error!void {
        const self: *StderrReporter = @ptrCast(@alignCast(context));
        var buffer: [1024]u8 = undefined;
        var writer = self.file.writerStreaming(self.io, &buffer);
        formatEvent(event, &writer.interface) catch return error.WriteFailed;
        writer.flush() catch return error.WriteFailed;
    }

    const vtable: lifecycle.Reporter.VTable = .{ .write = write };
};

pub fn formatEvent(event: lifecycle.Event, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (event) {
        .authentication_started => |started| {
            try writer.writeAll("mentohust: info authentication_started ");
            if (started.retry_attempt) |attempt| {
                try writer.print("retry_attempt={d}\n", .{attempt});
            } else {
                try writer.writeAll("retry_attempt=initial\n");
            }
        },
        .online => try writer.writeAll("mentohust: info online\n"),
        .disconnected => try writer.writeAll("mentohust: warn disconnected\n"),
        .protocol_failure => |reason| try writer.print(
            "mentohust: warn protocol_failure reason={t}\n",
            .{reason},
        ),
        .transient_error => |err| try writer.print(
            "mentohust: warn transient_error error={s}\n",
            .{@errorName(err)},
        ),
        .retry_scheduled => |retry| {
            try writer.print("mentohust: info retry_scheduled attempt={d} delay=", .{retry.attempt});
            try retry.delay.format(writer);
            try writer.writeByte('\n');
        },
        .reauthentication_required => try writer.writeAll(
            "mentohust: info reauthentication_required\n",
        ),
        .direct_authentication_failed => try writer.writeAll(
            "mentohust: error direct_authentication_failed\n",
        ),
        .shutdown_started => |signal| try writer.print(
            "mentohust: info shutdown_started signal={t}\n",
            .{signal},
        ),
        .shutdown_completed => |signal| try writer.print(
            "mentohust: info shutdown_completed signal={t}\n",
            .{signal},
        ),
        .shutdown_failure => |err| try writer.print(
            "mentohust: error shutdown_failure error={s}\n",
            .{@errorName(err)},
        ),
    }
}

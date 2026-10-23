const std = @import("std");
const lifecycle = @import("lifecycle.zig");
const logging = @import("logging.zig");

test "lifecycle events format as single human-readable lines" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try logging.formatEvent(.{ .authentication_started = .{ .retry_attempt = null } }, &output.writer);
    try logging.formatEvent(.{ .retry_scheduled = .{
        .attempt = 2,
        .delay = .fromSeconds(4),
    } }, &output.writer);
    try logging.formatEvent(.{ .protocol_failure = .start_timeout }, &output.writer);
    try logging.formatEvent(.{ .shutdown_completed = .terminate }, &output.writer);

    try std.testing.expectEqualStrings(
        "mentohust: info authentication_started retry_attempt=initial\n" ++
            "mentohust: info retry_scheduled attempt=2 delay=4s\n" ++
            "mentohust: warn protocol_failure reason=start_timeout\n" ++
            "mentohust: info shutdown_completed signal=terminate\n",
        output.written(),
    );
}

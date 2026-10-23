const clap = @import("clap");
const build_options = @import("build_options");
const mentohust = @import("mentohust");
const std = @import("std");

const EnvironmentAdapter = struct {
    values: *const std.process.Environ.Map,

    fn environment(self: *EnvironmentAdapter) mentohust.config.Environment {
        return .{ .context = self, .vtable = &vtable };
    }

    fn get(context: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *EnvironmentAdapter = @ptrCast(@alignCast(context));
        return self.values.get(name);
    }

    const vtable: mentohust.config.Environment.VTable = .{ .get = get };
};

pub fn main(init: std.process.Init) void {
    const code = execute(init) catch |err| blk: {
        writeError(init.io, @errorName(err)) catch {};
        break :blk @as(u8, 6);
    };
    std.process.exit(code);
}

fn execute(init: std.process.Init) !u8 {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();

    var environment: EnvironmentAdapter = .{ .values = init.environ_map };
    var prompt = mentohust.terminal.TerminalPrompt.init(init.io);
    var diagnostic: clap.Diagnostic = .{};
    const parsed = mentohust.config.parse(
        init.gpa,
        &args,
        environment.environment(),
        prompt.interface(),
        &diagnostic,
    );
    mentohust.config.clearEnvironmentSecret(init.environ_map, "MENTOHUST_PASSWORD");
    const action = parsed catch |err| {
        if (prompt.interruptedSignal()) |signal| {
            return switch (signal) {
                .interrupt => 130,
                .terminate => 143,
            };
        }
        const code = mentohust.config.parseExitCode(err);
        try reportConfigError(init.io, diagnostic, err);
        return code;
    };

    switch (action) {
        .help => {
            try mentohust.config.writeHelp(init.io, .stdout());
            return 0;
        },
        .version => {
            const output = try std.fmt.allocPrint(
                init.gpa,
                "mentohust {s}\n",
                .{build_options.version},
            );
            defer init.gpa.free(output);
            try std.Io.File.stdout().writeStreamingAll(init.io, output);
            return 0;
        },
        .run => |configuration| {
            var owned = configuration;
            defer owned.deinit();
            try writeConfigurationSummary(init.io, owned);
            try std.Io.File.stderr().writeStreamingAll(
                init.io,
                "mentohust: error platform_adapter_unavailable " ++
                    "reason=authenticated-platform-adapters-arrive-in-M3\n",
            );
            return 5;
        },
    }
}

fn reportConfigError(
    io: std.Io,
    diagnostic: clap.Diagnostic,
    err: anyerror,
) !void {
    if (diagnostic.arg.len != 0 or
        diagnostic.name.short != null or
        diagnostic.name.long != null)
    {
        try diagnostic.reportToFile(io, .stderr(), err);
        return;
    }

    var buffer: [512]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &buffer,
        "mentohust: error configuration reason={s}\n",
        .{@errorName(err)},
    );
    try std.Io.File.stderr().writeStreamingAll(io, message);
}

fn writeConfigurationSummary(io: std.Io, configuration: mentohust.config.Configuration) !void {
    var buffer: [512]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &buffer,
        "mentohust: info configuration_valid interface={s} method={t}\n",
        .{ configuration.interface, configuration.method },
    );
    try std.Io.File.stderr().writeStreamingAll(io, message);
}

fn writeError(io: std.Io, name: []const u8) !void {
    var buffer: [512]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &buffer,
        "mentohust: error internal reason={s}\n",
        .{name},
    );
    try std.Io.File.stderr().writeStreamingAll(io, message);
}

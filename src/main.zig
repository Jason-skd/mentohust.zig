const clap = @import("clap");
const build_options = @import("build_options");
const mentohust = @import("mentohust");
const rj = @import("rj-connect");
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
        writeFailure(init.io, "internal", err) catch {};
        break :blk @as(u8, 6);
    };
    std.process.exit(code);
}

fn execute(init: std.process.Init) !u8 {
    var signals = mentohust.runtime.Signals.init() catch |err| {
        try writeFailure(init.io, "platform_adapter_failed", err);
        return 5;
    };
    defer signals.deinit();
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();

    var environment: EnvironmentAdapter = .{ .values = init.environ_map };
    var prompt = mentohust.terminal.TerminalPrompt.init(init.io, &signals);
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

            var runtime = mentohust.runtime.Runtime.init(
                init.io,
                &signals,
                owned.interface,
                owned.deployment,
            ) catch |err| {
                try writeFailure(init.io, "platform_adapter_failed", err);
                return switch (err) {
                    error.InvalidInterface, error.InvalidFacts => 2,
                    else => 5,
                };
            };
            defer runtime.deinit();

            const initial_facts = runtime.readFacts(null) catch |err| {
                try writeFailure(init.io, "platform_adapter_failed", err);
                return 5;
            };
            var session = rj.session.Session.init(init.gpa, .{
                .facts = initial_facts,
                .credentials = .{
                    .username = owned.username,
                    .password = owned.password.slice(),
                },
            }) catch |err| {
                try writeFailure(init.io, "session_initialization_failed", err);
                const class = mentohust.lifecycle.classifySessionError(err);
                return switch (class) {
                    .authentication_rejected => 3,
                    .transient => 4,
                    .configuration => 2,
                    .security => 5,
                    .internal => 6,
                };
            };
            defer session.deinit();

            var reporter = mentohust.logging.StderrReporter{ .io = init.io };
            const termination = mentohust.lifecycle.run(
                &session,
                runtime.ports(),
                .{
                    .retry_limit = owned.retry_limit,
                    .backoff_initial = owned.backoff_initial,
                    .backoff_max = owned.backoff_max,
                    .shutdown_timeout = owned.shutdown_timeout,
                },
                reporter.reporter(),
            );
            return termination.exitCode();
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

fn writeFailure(io: std.Io, category: []const u8, err: anyerror) !void {
    var buffer: [512]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &buffer,
        "mentohust: error {s} reason={s}\n",
        .{ category, @errorName(err) },
    );
    try std.Io.File.stderr().writeStreamingAll(io, message);
}

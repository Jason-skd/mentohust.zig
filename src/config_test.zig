const std = @import("std");
const config = @import("config.zig");

const EnvEntry = struct {
    name: []const u8,
    value: []const u8,
};

const EnvStub = struct {
    entries: []const EnvEntry = &.{},

    fn environment(self: *EnvStub) config.Environment {
        return .{ .context = self, .vtable = &vtable };
    }

    fn get(context: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *EnvStub = @ptrCast(@alignCast(context));
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    const vtable: config.Environment.VTable = .{ .get = get };
};

const PromptStub = struct {
    values: []const []const u8 = &.{},
    next_value: usize = 0,
    kinds: [8]config.PromptKind = undefined,
    kind_count: usize = 0,
    not_terminal: bool = false,

    fn prompt(self: *PromptStub) config.Prompt {
        return .{ .context = self, .vtable = &vtable };
    }

    fn read(
        context: *anyopaque,
        kind: config.PromptKind,
        label: []const u8,
        output: *[config.max_prompt_bytes]u8,
    ) config.Prompt.Error![]const u8 {
        _ = label;
        const self: *PromptStub = @ptrCast(@alignCast(context));
        if (self.not_terminal) return error.NotTerminal;
        if (self.next_value >= self.values.len) return error.ReadFailed;
        const value = self.values[self.next_value];
        self.next_value += 1;
        self.kinds[self.kind_count] = kind;
        self.kind_count += 1;
        if (value.len > output.len) return error.TooLong;
        @memcpy(output[0..value.len], value);
        return output[0..value.len];
    }

    const vtable: config.Prompt.VTable = .{ .read = read };
};

fn parseArgs(
    allocator: std.mem.Allocator,
    arguments: []const u8,
    environment: config.Environment,
    prompt: config.Prompt,
) !config.Action {
    var iter = try std.process.Args.IteratorGeneral(.{}).init(allocator, arguments);
    defer iter.deinit();
    _ = iter.next();
    return config.parse(allocator, &iter, environment, prompt, null);
}

test "CLI overrides environment values and retains lower-precedence options" {
    var env: EnvStub = .{ .entries = &.{
        .{ .name = "MENTOHUST_INTERFACE", .value = "env0" },
        .{ .name = "MENTOHUST_USERNAME", .value = "env-user" },
        .{ .name = "MENTOHUST_PASSWORD", .value = "env-password" },
        .{ .name = "MENTOHUST_METHOD", .value = "peap" },
        .{ .name = "MENTOHUST_RETRY_LIMIT", .value = "7" },
        .{ .name = "MENTOHUST_BACKOFF_INITIAL", .value = "2s" },
        .{ .name = "MENTOHUST_BACKOFF_MAX", .value = "10s" },
        .{ .name = "MENTOHUST_SHUTDOWN_TIMEOUT", .value = "3s" },
    } };
    var prompt: PromptStub = .{};

    var action = try parseArgs(
        std.testing.allocator,
        "mentohust --interface cli0 --username cli-user --method md5 " ++
            "--retry-limit unlimited --backoff-initial 500ms",
        env.environment(),
        prompt.prompt(),
    );
    defer action.run.deinit();

    try std.testing.expectEqualStrings("cli0", action.run.interface);
    try std.testing.expectEqualStrings("cli-user", action.run.username);
    try std.testing.expectEqualStrings("env-password", action.run.password.slice());
    try std.testing.expectEqual(config.Method.md5, action.run.method);
    try std.testing.expectEqual(config.RetryLimit.unlimited, action.run.retry_limit);
    try std.testing.expectEqual(@as(i96, 500 * std.time.ns_per_ms), action.run.backoff_initial.toNanoseconds());
    try std.testing.expectEqual(@as(i96, 10 * std.time.ns_per_s), action.run.backoff_max.toNanoseconds());
    try std.testing.expectEqual(@as(i96, 3 * std.time.ns_per_s), action.run.shutdown_timeout.toNanoseconds());
    try std.testing.expectEqual(@as(usize, 0), prompt.kind_count);
}

test "missing required values are prompted and defaults are resolved" {
    var env: EnvStub = .{};
    var prompt: PromptStub = .{ .values = &.{ "wlan0", "alice", "secret" } };

    var action = try parseArgs(
        std.testing.allocator,
        "mentohust",
        env.environment(),
        prompt.prompt(),
    );
    defer action.run.deinit();

    try std.testing.expectEqualStrings("wlan0", action.run.interface);
    try std.testing.expectEqualStrings("alice", action.run.username);
    try std.testing.expectEqualStrings("secret", action.run.password.slice());
    try std.testing.expectEqual(config.Method.auto, action.run.method);
    try std.testing.expectEqual(config.RetryLimit.unlimited, action.run.retry_limit);
    try std.testing.expectEqual(@as(i96, std.time.ns_per_s), action.run.backoff_initial.toNanoseconds());
    try std.testing.expectEqual(@as(i96, 60 * std.time.ns_per_s), action.run.backoff_max.toNanoseconds());
    try std.testing.expectEqual(@as(i96, 5 * std.time.ns_per_s), action.run.shutdown_timeout.toNanoseconds());
    try std.testing.expectEqual(config.PromptKind.visible, prompt.kinds[0]);
    try std.testing.expectEqual(config.PromptKind.visible, prompt.kinds[1]);
    try std.testing.expectEqual(config.PromptKind.secret, prompt.kinds[2]);
}

test "no terminal fails when required credentials are absent" {
    var env: EnvStub = .{ .entries = &.{
        .{ .name = "MENTOHUST_INTERFACE", .value = "eth0" },
        .{ .name = "MENTOHUST_USERNAME", .value = "alice" },
    } };
    var prompt: PromptStub = .{ .not_terminal = true };

    try std.testing.expectError(
        error.NotTerminal,
        parseArgs(
            std.testing.allocator,
            "mentohust",
            env.environment(),
            prompt.prompt(),
        ),
    );
}

test "password is not accepted on the command line" {
    var env: EnvStub = .{ .entries = &.{
        .{ .name = "MENTOHUST_INTERFACE", .value = "eth0" },
        .{ .name = "MENTOHUST_USERNAME", .value = "alice" },
        .{ .name = "MENTOHUST_PASSWORD", .value = "secret" },
    } };
    var prompt: PromptStub = .{};

    try std.testing.expectError(
        error.InvalidArgument,
        parseArgs(
            std.testing.allocator,
            "mentohust --password secret",
            env.environment(),
            prompt.prompt(),
        ),
    );
}

test "invalid environment values and durations stay distinguishable" {
    var invalid_retry: EnvStub = .{ .entries = &.{
        .{ .name = "MENTOHUST_INTERFACE", .value = "eth0" },
        .{ .name = "MENTOHUST_USERNAME", .value = "alice" },
        .{ .name = "MENTOHUST_PASSWORD", .value = "secret" },
        .{ .name = "MENTOHUST_RETRY_LIMIT", .value = "many" },
    } };
    var prompt: PromptStub = .{};
    try std.testing.expectError(
        error.InvalidRetryLimit,
        parseArgs(std.testing.allocator, "mentohust", invalid_retry.environment(), prompt.prompt()),
    );

    var invalid_backoff: EnvStub = .{ .entries = &.{
        .{ .name = "MENTOHUST_INTERFACE", .value = "eth0" },
        .{ .name = "MENTOHUST_USERNAME", .value = "alice" },
        .{ .name = "MENTOHUST_PASSWORD", .value = "secret" },
        .{ .name = "MENTOHUST_BACKOFF_INITIAL", .value = "61s" },
        .{ .name = "MENTOHUST_BACKOFF_MAX", .value = "60s" },
    } };
    try std.testing.expectError(
        error.BackoffInitialExceedsMax,
        parseArgs(std.testing.allocator, "mentohust", invalid_backoff.environment(), prompt.prompt()),
    );
}

test "invalid interface text is rejected before it can reach logs or adapters" {
    var env: EnvStub = .{ .entries = &.{
        .{ .name = "MENTOHUST_INTERFACE", .value = "eth0\nspoof" },
        .{ .name = "MENTOHUST_USERNAME", .value = "alice" },
        .{ .name = "MENTOHUST_PASSWORD", .value = "secret" },
    } };
    var prompt: PromptStub = .{};

    try std.testing.expectError(
        error.InvalidInterface,
        parseArgs(std.testing.allocator, "mentohust", env.environment(), prompt.prompt()),
    );
}

test "duration parser validates units and overflow" {
    try std.testing.expectEqual(
        @as(i96, 1500 * std.time.ns_per_ms),
        (try config.parseDuration("1500ms")).toNanoseconds(),
    );
    try std.testing.expectEqual(
        @as(i96, 2 * std.time.ns_per_min),
        (try config.parseDuration("2m")).toNanoseconds(),
    );
    try std.testing.expectError(error.InvalidDuration, config.parseDuration("10d"));
    try std.testing.expectError(error.InvalidDuration, config.parseDuration("seconds"));
    try std.testing.expectError(
        error.DurationOverflow,
        config.parseDuration("18446744073709551615h"),
    );
}

test "parse failures remain distinguishable at the exit boundary" {
    try std.testing.expectEqual(@as(u8, 2), config.parseExitCode(error.InvalidInterface));
    try std.testing.expectEqual(@as(u8, 5), config.parseExitCode(error.WriteFailed));
    try std.testing.expectEqual(@as(u8, 6), config.parseExitCode(error.OutOfMemory));
}

test "environment password is removed after configuration resolution" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("MENTOHUST_PASSWORD", "secret");
    try environment.put("MENTOHUST_USERNAME", "alice");

    config.clearEnvironmentSecret(&environment, "MENTOHUST_PASSWORD");

    try std.testing.expect(!environment.contains("MENTOHUST_PASSWORD"));
    try std.testing.expectEqualStrings("alice", environment.get("MENTOHUST_USERNAME").?);
}

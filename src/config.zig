//! CLI, environment, and interactive credential resolution.

const clap = @import("clap");
const std = @import("std");
const facts = @import("facts.zig");

pub const max_prompt_bytes = 512;

pub const Method = enum {
    auto,
    md5,
};

pub const RetryLimit = union(enum) {
    unlimited,
    limited: u32,
};

pub const Secret = struct {
    bytes: []u8,

    pub fn deinit(self: *Secret, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.bytes);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn slice(self: Secret) []const u8 {
        return self.bytes;
    }
};

pub const Configuration = struct {
    allocator: std.mem.Allocator,
    interface: []u8,
    username: []u8,
    password: Secret,
    method: Method,
    retry_limit: RetryLimit,
    backoff_initial: std.Io.Duration,
    backoff_max: std.Io.Duration,
    shutdown_timeout: std.Io.Duration,
    deployment: facts.Deployment,

    pub fn deinit(self: *Configuration) void {
        self.allocator.free(self.deployment.service_name);
        self.allocator.free(self.deployment.disk_serial);
        self.allocator.free(self.deployment.alternate_dns_text);
        self.password.deinit(self.allocator);
        self.allocator.free(self.username);
        self.allocator.free(self.interface);
        self.* = undefined;
    }
};

pub const Action = union(enum) {
    help,
    version,
    run: Configuration,
};

pub const Environment = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (context: *anyopaque, name: []const u8) ?[]const u8,
    };

    pub fn get(self: Environment, name: []const u8) ?[]const u8 {
        return self.vtable.get(self.context, name);
    }
};

pub const PromptKind = enum {
    visible,
    secret,
};

pub const Prompt = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        Interrupted,
        NotTerminal,
        ReadFailed,
        TooLong,
        WriteFailed,
    };

    pub const VTable = struct {
        read: *const fn (
            context: *anyopaque,
            kind: PromptKind,
            label: []const u8,
            output: *[max_prompt_bytes]u8,
        ) Error![]const u8,
    };

    pub fn read(
        self: Prompt,
        kind: PromptKind,
        label: []const u8,
        output: *[max_prompt_bytes]u8,
    ) Error![]const u8 {
        return self.vtable.read(self.context, kind, label, output);
    }
};

pub const Params = clap.parseParamsComptime(
    \\-i, --interface <STR>              Network interface used for raw Ethernet.
    \\-u, --username <STR>               Authentication username.
    \\    --method <METHOD>              Authentication method: auto or md5. Default: auto.
    \\    --retry-limit <RETRY>          Additional attempts after each loss: N or unlimited. Default: unlimited.
    \\    --backoff-initial <DURATION>   Delay before the first retry. Default: 1s.
    \\    --backoff-max <DURATION>       Maximum retry delay. Default: 60s.
    \\    --shutdown-timeout <DURATION>  Total graceful shutdown deadline. Default: 5s.
    \\-h, --help                         Display this help and exit.
    \\    --service-name <STR>            Service name bytes (GBK), at most 32 bytes.
    \\    --disk-serial <STR>             ASCII disk serial, at most 64 bytes.
    \\    --alternate-dns <STR>           ASCII alternate DNS text, at most 247 bytes.
    \\    --dhcp <DHCP>                   IPv4 facts mode: enabled or disabled. Default: disabled.
    \\    --gateway <IPV4>                IPv4 gateway fact. Default: 0.0.0.0.
    \\    --dns <IPV4>                    IPv4 DNS fact. Default: 0.0.0.0.
    \\    --version                      Display the version and exit.
    \\
);

pub const DhcpMode = enum { enabled, disabled };

pub const Parsers = .{
    .DHCP = clap.parsers.enumeration(DhcpMode),
    .IPV4 = facts.parseIpv4,
    .STR = clap.parsers.string,
    .METHOD = clap.parsers.enumeration(Method),
    .RETRY = parseRetryLimit,
    .DURATION = parseDuration,
};

pub fn parse(
    allocator: std.mem.Allocator,
    iter: anytype,
    environment: Environment,
    prompt: Prompt,
    diagnostic: ?*clap.Diagnostic,
) !Action {
    var parsed = try clap.parseEx(clap.Help, &Params, Parsers, iter, .{
        .allocator = allocator,
        .diagnostic = diagnostic,
    });
    defer parsed.deinit();

    if (parsed.args.help != 0) return .help;
    if (parsed.args.version != 0) return .version;

    const method = if (parsed.args.method) |value|
        value
    else if (environment.get("MENTOHUST_METHOD")) |value|
        std.meta.stringToEnum(Method, value) orelse return error.InvalidMethod
    else
        Method.auto;

    const retry_limit = if (parsed.args.@"retry-limit") |value|
        value
    else if (environment.get("MENTOHUST_RETRY_LIMIT")) |value|
        parseRetryLimit(value) catch return error.InvalidRetryLimit
    else
        RetryLimit.unlimited;

    const backoff_initial = if (parsed.args.@"backoff-initial") |value|
        value
    else if (environment.get("MENTOHUST_BACKOFF_INITIAL")) |value|
        parseDuration(value) catch return error.InvalidBackoffInitial
    else
        std.Io.Duration.fromSeconds(1);

    const backoff_max = if (parsed.args.@"backoff-max") |value|
        value
    else if (environment.get("MENTOHUST_BACKOFF_MAX")) |value|
        parseDuration(value) catch return error.InvalidBackoffMax
    else
        std.Io.Duration.fromSeconds(60);

    const shutdown_timeout = if (parsed.args.@"shutdown-timeout") |value|
        value
    else if (environment.get("MENTOHUST_SHUTDOWN_TIMEOUT")) |value|
        parseDuration(value) catch return error.InvalidShutdownTimeout
    else
        std.Io.Duration.fromSeconds(5);

    try validateDurations(backoff_initial, backoff_max, shutdown_timeout);

    const service_name = try allocator.dupe(u8, parsed.args.@"service-name" orelse environment.get("MENTOHUST_SERVICE_NAME") orelse "");
    errdefer allocator.free(service_name);
    const disk_serial = try allocator.dupe(u8, parsed.args.@"disk-serial" orelse environment.get("MENTOHUST_DISK_SERIAL") orelse "");
    errdefer allocator.free(disk_serial);
    const alternate_dns = try allocator.dupe(u8, parsed.args.@"alternate-dns" orelse environment.get("MENTOHUST_ALTERNATE_DNS") orelse "");
    errdefer allocator.free(alternate_dns);
    const dhcp = parsed.args.dhcp orelse if (environment.get("MENTOHUST_DHCP")) |text|
        std.meta.stringToEnum(DhcpMode, text) orelse return error.InvalidDhcpMode
    else
        DhcpMode.disabled;
    const deployment: facts.Deployment = .{
        .service_name = service_name,
        .disk_serial = disk_serial,
        .alternate_dns_text = alternate_dns,
        .dhcp_enabled = dhcp == .enabled,
        .gateway = parsed.args.gateway orelse try facts.parseIpv4(environment.get("MENTOHUST_GATEWAY") orelse "0.0.0.0"),
        .dns = parsed.args.dns orelse try facts.parseIpv4(environment.get("MENTOHUST_DNS") orelse "0.0.0.0"),
    };
    try deployment.validate();

    var prompt_buffer: [max_prompt_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &prompt_buffer);

    const interface = try resolveValue(
        allocator,
        parsed.args.interface,
        environment.get("MENTOHUST_INTERFACE"),
        prompt,
        .visible,
        "Network interface: ",
        &prompt_buffer,
        error.EmptyInterface,
    );
    errdefer allocator.free(interface);
    const username = try resolveValue(
        allocator,
        parsed.args.username,
        environment.get("MENTOHUST_USERNAME"),
        prompt,
        .visible,
        "Username: ",
        &prompt_buffer,
        error.EmptyUsername,
    );
    errdefer allocator.free(username);
    const password = try resolveValue(
        allocator,
        null,
        environment.get("MENTOHUST_PASSWORD"),
        prompt,
        .secret,
        "Password: ",
        &prompt_buffer,
        error.EmptyPassword,
    );
    errdefer {
        std.crypto.secureZero(u8, password);
        allocator.free(password);
    }

    try validateValues(interface, username, password);

    return .{ .run = .{
        .allocator = allocator,
        .interface = interface,
        .username = username,
        .password = .{ .bytes = password },
        .method = method,
        .retry_limit = retry_limit,
        .backoff_initial = backoff_initial,
        .backoff_max = backoff_max,
        .shutdown_timeout = shutdown_timeout,
        .deployment = deployment,
    } };
}

pub fn parseExitCode(err: anyerror) u8 {
    return switch (err) {
        error.OutOfMemory => 6,
        error.ReadFailed, error.WriteFailed => 5,
        error.Interrupted => 6,
        else => 2,
    };
}

/// Clears the process environment copy of a secret before removing the entry.
pub fn clearEnvironmentSecret(
    environment: *std.process.Environ.Map,
    name: []const u8,
) void {
    if (environment.getPtr(name)) |value| {
        std.crypto.secureZero(u8, @constCast(value.*));
    }
    _ = environment.swapRemove(name);
}

fn resolveValue(
    allocator: std.mem.Allocator,
    cli_value: ?[]const u8,
    environment_value: ?[]const u8,
    prompt: Prompt,
    prompt_kind: PromptKind,
    label: []const u8,
    prompt_buffer: *[max_prompt_bytes]u8,
    comptime empty_error: anyerror,
) ![]u8 {
    const value = if (cli_value) |cli|
        cli
    else if (environment_value) |environment|
        environment
    else
        try prompt.read(prompt_kind, label, prompt_buffer);
    if (value.len == 0) return empty_error;
    return allocator.dupe(u8, value);
}

pub fn writeHelp(io: std.Io, file: std.Io.File) !void {
    try clap.helpToFile(io, file, clap.Help, &Params, .{});
}

pub fn parseRetryLimit(value: []const u8) error{InvalidRetryLimit}!RetryLimit {
    if (std.mem.eql(u8, value, "unlimited")) return .unlimited;
    const attempts = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidRetryLimit;
    return .{ .limited = attempts };
}

pub fn parseDuration(value: []const u8) error{
    InvalidDuration,
    DurationOverflow,
}!std.Io.Duration {
    if (value.len == 0) return error.InvalidDuration;

    var number_end: usize = 0;
    while (number_end < value.len and std.ascii.isDigit(value[number_end])) : (number_end += 1) {}
    if (number_end == 0) return error.InvalidDuration;

    const amount = std.fmt.parseUnsigned(u64, value[0..number_end], 10) catch
        return error.DurationOverflow;
    const unit = value[number_end..];
    const multiplier: u64 = if (unit.len == 0 or std.mem.eql(u8, unit, "s"))
        std.time.ns_per_s
    else if (std.mem.eql(u8, unit, "ms"))
        std.time.ns_per_ms
    else if (std.mem.eql(u8, unit, "m"))
        std.time.ns_per_min
    else if (std.mem.eql(u8, unit, "h"))
        std.time.ns_per_hour
    else
        return error.InvalidDuration;

    const nanoseconds = std.math.mul(u64, amount, multiplier) catch
        return error.DurationOverflow;
    if (nanoseconds > std.math.maxInt(i96)) return error.DurationOverflow;
    return std.Io.Duration.fromNanoseconds(@intCast(nanoseconds));
}

fn validateDurations(
    backoff_initial: std.Io.Duration,
    backoff_max: std.Io.Duration,
    shutdown_timeout: std.Io.Duration,
) !void {
    if (backoff_initial.toNanoseconds() <= 0) return error.InvalidBackoffInitial;
    if (backoff_max.toNanoseconds() <= 0) return error.InvalidBackoffMax;
    if (backoff_initial.toNanoseconds() > backoff_max.toNanoseconds()) {
        return error.BackoffInitialExceedsMax;
    }
    if (shutdown_timeout.toNanoseconds() <= 0) return error.InvalidShutdownTimeout;
}

fn validateValues(interface: []const u8, username: []const u8, password: []const u8) !void {
    if (!validText(interface, 255)) return error.InvalidInterface;
    if (!validText(username, 255)) return error.InvalidUsername;
    if (password.len > 240) return error.InvalidCredentials;
}

fn validText(value: []const u8, max_len: usize) bool {
    if (value.len == 0 or value.len > max_len) return false;
    for (value) |byte| {
        if (std.ascii.isControl(byte)) return false;
    }
    return true;
}

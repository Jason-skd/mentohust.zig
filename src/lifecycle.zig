//! Long-running authentication lifecycle independent of concrete platform adapters.

const std = @import("std");
const config = @import("config.zig");
const coordinator = @import("coordinator.zig");
const platform = @import("platform.zig");
const rj = @import("rj-connect");

pub const Policy = struct {
    retry_limit: config.RetryLimit = .unlimited,
    backoff_initial: std.Io.Duration,
    backoff_max: std.Io.Duration,
    shutdown_timeout: std.Io.Duration,

    pub fn validate(self: Policy) !void {
        if (self.backoff_initial.toNanoseconds() <= 0 or
            self.backoff_max.toNanoseconds() <= 0 or
            self.backoff_initial.toNanoseconds() > self.backoff_max.toNanoseconds() or
            self.shutdown_timeout.toNanoseconds() <= 0)
        {
            return error.InvalidPolicy;
        }
    }
};

pub const FailureClass = enum {
    transient,
    authentication_rejected,
    configuration,
    security,
    internal,
};

pub const StepFailure = struct {
    reason: ?rj.session.FailureReason = null,
    cause: ?anyerror = null,
};

pub const Termination = union(enum) {
    signal: platform.Stop.Request,
    authentication_rejected: StepFailure,
    retry_exhausted: StepFailure,
    security_failure: StepFailure,
    configuration_failure: StepFailure,
    internal_failure: anyerror,

    pub fn exitCode(self: Termination) u8 {
        return switch (self) {
            .signal => |signal| switch (signal) {
                .interrupt => 130,
                .terminate => 143,
            },
            .authentication_rejected => 3,
            .retry_exhausted => 4,
            .security_failure => 5,
            .configuration_failure => 2,
            .internal_failure => 6,
        };
    }
};

pub const Event = union(enum) {
    authentication_started: struct {
        retry_attempt: ?u32,
    },
    online,
    disconnected,
    protocol_failure: rj.session.FailureReason,
    transient_error: anyerror,
    retry_scheduled: struct {
        attempt: u32,
        delay: std.Io.Duration,
    },
    reauthentication_required,
    direct_authentication_failed,
    shutdown_started: platform.Stop.Request,
    shutdown_completed: platform.Stop.Request,
    shutdown_failure: anyerror,
};

pub const Reporter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{WriteFailed};

    pub const VTable = struct {
        write: *const fn (context: *anyopaque, event: Event) Error!void,
    };

    pub fn write(self: Reporter, event: Event) Error!void {
        return self.vtable.write(self.context, event);
    }
};

pub const Tracker = struct {
    policy: Policy,
    retry_count: u32 = 0,

    pub fn init(policy: Policy) !Tracker {
        try policy.validate();
        return .{ .policy = policy };
    }

    pub fn reset(self: *Tracker) void {
        self.retry_count = 0;
    }

    /// Returns the next retry time, or null when the configured budget is exhausted.
    pub fn scheduleRetry(self: *Tracker, now: std.Io.Timestamp) ?std.Io.Timestamp {
        if (self.policy.retry_limit == .limited and
            self.retry_count >= self.policy.retry_limit.limited)
        {
            return null;
        }

        const delay = self.retryDelay();
        self.retry_count +|= 1;
        return now.addDuration(delay);
    }

    pub fn retryAttempt(self: Tracker) u32 {
        return self.retry_count;
    }

    pub fn retryDelay(self: Tracker) std.Io.Duration {
        var delay = self.policy.backoff_initial;
        var index = self.retry_count;
        while (index > 0 and delay.toNanoseconds() < self.policy.backoff_max.toNanoseconds()) {
            const doubled = std.math.mul(i96, delay.toNanoseconds(), 2) catch
                self.policy.backoff_max.toNanoseconds();
            delay = std.Io.Duration.fromNanoseconds(@min(
                doubled,
                self.policy.backoff_max.toNanoseconds(),
            ));
            index -= 1;
        }
        return delay;
    }
};

pub fn run(
    session: *rj.session.Session,
    ports: platform.Ports,
    credentials: rj.session.Credentials,
    policy: Policy,
    reporter: Reporter,
) Termination {
    return runInner(session, ports, credentials, policy, reporter) catch |err| .{
        .internal_failure = err,
    };
}

const RunError = error{
    InvalidPolicy,
    InvalidActionOrder,
    NestedStepLimitExceeded,
    MissingFailureReason,
    ShutdownTimedOut,
};

fn runInner(
    session: *rj.session.Session,
    ports: platform.Ports,
    credentials: rj.session.Credentials,
    policy: Policy,
    reporter: Reporter,
) (RunError || Reporter.Error)!Termination {
    var tracker = try Tracker.init(policy);
    var online = false;
    var pending_start: ?std.Io.Timestamp = null;
    var started_once = false;

    while (true) {
        const now = ports.clock.now() catch |err| {
            return .{ .internal_failure = err };
        };

        const stop = ports.stop.tryNext() catch |err| {
            return .{ .internal_failure = err };
        };
        if (stop) |signal| {
            return stopAndCleanup(session, ports, policy.shutdown_timeout, signal, reporter);
        }

        if (!started_once and session.phase() == .idle) {
            started_once = true;
            try reporter.write(.{ .authentication_started = .{
                .retry_attempt = null,
            } });
            const outcome = session.step(now, .start) catch |err| {
                const resolution = try handleSessionError(
                    session,
                    ports,
                    now,
                    err,
                    &tracker,
                    &online,
                    reporter,
                );
                if (resolution.termination) |termination| return termination;
                pending_start = resolution.pending_start;
                continue;
            };
            const processed = try processStep(
                session,
                ports,
                credentials,
                &tracker,
                &online,
                now,
                0,
                outcome,
                reporter,
            );
            if (processed.termination) |termination| return termination;
            pending_start = processed.pending_start;
            continue;
        }

        if (pending_start) |start_at| {
            if (now.compare(.gte, start_at)) {
                const retry_attempt = if (tracker.retryAttempt() == 0 and !online)
                    null
                else
                    tracker.retryAttempt();
                try reporter.write(.{ .authentication_started = .{
                    .retry_attempt = retry_attempt,
                } });
                pending_start = null;
                const outcome = session.step(now, .start) catch |err| {
                    const resolution = try handleSessionError(
                        session,
                        ports,
                        now,
                        err,
                        &tracker,
                        &online,
                        reporter,
                    );
                    if (resolution.termination) |termination| return termination;
                    pending_start = resolution.pending_start;
                    continue;
                };
                const processed = try processStep(
                    session,
                    ports,
                    credentials,
                    &tracker,
                    &online,
                    now,
                    0,
                    outcome,
                    reporter,
                );
                if (processed.termination) |termination| return termination;
                pending_start = processed.pending_start;
                continue;
            }
            ports.clock.waitUntil(start_at) catch |err| {
                return .{ .internal_failure = err };
            };
            continue;
        }

        const frame = ports.ethernet.tryReceive() catch |err| {
            const resolution = try handleAdapterError(
                session,
                ports,
                now,
                err,
                &tracker,
                &online,
                reporter,
            );
            if (resolution.termination) |termination| return termination;
            pending_start = resolution.pending_start;
            continue;
        };
        if (frame) |bytes| {
            const outcome = session.step(now, .{ .frame = .{
                .generation = session.currentGeneration(),
                .bytes = bytes,
            } }) catch |err| {
                const resolution = try handleSessionError(
                    session,
                    ports,
                    now,
                    err,
                    &tracker,
                    &online,
                    reporter,
                );
                if (resolution.termination) |termination| return termination;
                pending_start = resolution.pending_start;
                continue;
            };
            const processed = try processStep(
                session,
                ports,
                credentials,
                &tracker,
                &online,
                now,
                0,
                outcome,
                reporter,
            );
            if (processed.termination) |termination| return termination;
            pending_start = processed.pending_start;
            continue;
        }

        const protocol_deadline = session.nextDeadline();
        const wake_at = earliest(pending_start, protocol_deadline);
        if (wake_at) |deadline| {
            if (now.compare(.gte, deadline)) {
                if (protocol_deadline != null and
                    deadline.toNanoseconds() == protocol_deadline.?.toNanoseconds())
                {
                    const outcome = session.step(now, .{ .timer = session.currentGeneration() }) catch |err| {
                        const resolution = try handleSessionError(
                            session,
                            ports,
                            now,
                            err,
                            &tracker,
                            &online,
                            reporter,
                        );
                        if (resolution.termination) |termination| return termination;
                        pending_start = resolution.pending_start;
                        continue;
                    };
                    const processed = try processStep(
                        session,
                        ports,
                        credentials,
                        &tracker,
                        &online,
                        now,
                        0,
                        outcome,
                        reporter,
                    );
                    if (processed.termination) |termination| return termination;
                    pending_start = processed.pending_start;
                }
                continue;
            }

            ports.clock.waitUntil(deadline) catch |err| {
                return .{ .internal_failure = err };
            };
            continue;
        }

        return .{ .internal_failure = error.NoProgress };
    }
}

const Processed = struct {
    pending_start: ?std.Io.Timestamp = null,
    termination: ?Termination = null,
};

fn processStep(
    session: *rj.session.Session,
    ports: platform.Ports,
    credentials: rj.session.Credentials,
    tracker: *Tracker,
    online: *bool,
    now: std.Io.Timestamp,
    depth: usize,
    initial_outcome: rj.session.Outcome,
    reporter: Reporter,
) (RunError || Reporter.Error)!Processed {
    if (depth >= 16) return error.NestedStepLimitExceeded;

    var outcome = initial_outcome;
    var owned = true;
    defer if (owned) outcome.deinit(session.allocator);

    var followup: ?rj.session.Input = null;
    var credentials_requested = false;
    var reauth_requested = false;
    var direct_authentication_failed = false;

    for (outcome.actions, 0..) |_, index| {
        const result = coordinator.dispatch(&ports, &outcome, index, credentials) catch |err| {
            owned = false;
            outcome.deinit(session.allocator);
            const resolution = try handleAdapterError(
                session,
                ports,
                now,
                err,
                tracker,
                online,
                reporter,
            );
            return .{
                .pending_start = resolution.pending_start,
                .termination = resolution.termination,
            };
        };

        switch (result) {
            .handled => {},
            .request_credentials => credentials_requested = true,
            .session_input => |input| {
                if (followup != null or index + 1 != outcome.actions.len) {
                    return error.InvalidActionOrder;
                }
                followup = input;
            },
            .reauth_required => reauth_requested = true,
            .direct_auth_result => |direct_result| {
                if (direct_result.success) {
                    noteOnline(tracker, online, reporter) catch return error.WriteFailed;
                } else {
                    direct_authentication_failed = true;
                }
            },
        }
    }

    if (followup) |input| {
        const next = session.step(now, input) catch |err| {
            owned = false;
            outcome.deinit(session.allocator);
            const resolution = try handleSessionError(
                session,
                ports,
                now,
                err,
                tracker,
                online,
                reporter,
            );
            return .{
                .pending_start = resolution.pending_start,
                .termination = resolution.termination,
            };
        };
        outcome.deinit(session.allocator);
        owned = false;
        return processStep(
            session,
            ports,
            credentials,
            tracker,
            online,
            now,
            depth + 1,
            next,
            reporter,
        );
    }

    if (credentials_requested) {
        const next = session.step(now, .{ .credentials = credentials }) catch |err| {
            owned = false;
            outcome.deinit(session.allocator);
            const resolution = try handleSessionError(
                session,
                ports,
                now,
                err,
                tracker,
                online,
                reporter,
            );
            return .{
                .pending_start = resolution.pending_start,
                .termination = resolution.termination,
            };
        };
        outcome.deinit(session.allocator);
        owned = false;
        return processStep(
            session,
            ports,
            credentials,
            tracker,
            online,
            now,
            depth + 1,
            next,
            reporter,
        );
    }

    if (direct_authentication_failed) {
        try reporter.write(.direct_authentication_failed);
        owned = false;
        outcome.deinit(session.allocator);
        const resolution = try cleanupFailure(
            session,
            ports,
            now,
            tracker,
            online,
            .authentication_rejected,
            .{ .reason = .direct_result_rejected },
            reporter,
        );
        return .{
            .pending_start = resolution.pending_start,
            .termination = resolution.termination,
        };
    }

    if (reauth_requested) {
        try reporter.write(.reauthentication_required);
        try reporter.write(.{ .authentication_started = .{ .retry_attempt = null } });
        tracker.reset();
        online.* = false;
        const next = session.step(now, .start) catch |err| {
            owned = false;
            outcome.deinit(session.allocator);
            const resolution = try handleSessionError(
                session,
                ports,
                now,
                err,
                tracker,
                online,
                reporter,
            );
            return .{
                .pending_start = resolution.pending_start,
                .termination = resolution.termination,
            };
        };
        outcome.deinit(session.allocator);
        owned = false;
        return processStep(
            session,
            ports,
            credentials,
            tracker,
            online,
            now,
            depth + 1,
            next,
            reporter,
        );
    }

    if (outcome.phase == .direct and outcome.phase.direct == .active) {
        try noteOnline(tracker, online, reporter);
    }

    if (outcome.failure) |reason| {
        try reporter.write(.{ .protocol_failure = reason });
        const class = classifyFailureReason(reason);
        if (class == .transient and outcome.phase == .idle) {
            try reporter.write(.disconnected);
            online.* = false;
            const retry_at = tracker.scheduleRetry(now) orelse {
                return .{ .termination = .{ .retry_exhausted = .{ .reason = reason } } };
            };
            try reporter.write(.{ .retry_scheduled = .{
                .attempt = tracker.retryAttempt(),
                .delay = now.durationTo(retry_at),
            } });
            return .{ .pending_start = retry_at };
        }
        if (class != .transient and outcome.phase != .idle) {
            owned = false;
            outcome.deinit(session.allocator);
            const resolution = try cleanupFailure(
                session,
                ports,
                now,
                tracker,
                online,
                class,
                .{ .reason = reason },
                reporter,
            );
            return .{
                .pending_start = resolution.pending_start,
                .termination = resolution.termination,
            };
        }
        if (class != .transient) {
            return .{ .termination = terminationFor(class, .{ .reason = reason }) };
        }
    } else if (outcome.phase == .idle and followup == null) {
        return .{ .termination = .{ .internal_failure = error.MissingFailureReason } };
    }

    return .{};
}

fn noteOnline(tracker: *Tracker, online: *bool, reporter: Reporter) Reporter.Error!void {
    tracker.reset();
    if (!online.*) {
        online.* = true;
        try reporter.write(.online);
    }
}

fn handleSessionError(
    session: *rj.session.Session,
    ports: platform.Ports,
    now: std.Io.Timestamp,
    err: rj.session.Error,
    tracker: *Tracker,
    online: *bool,
    reporter: Reporter,
) (RunError || Reporter.Error)!FailureResolution {
    const class = classifySessionError(err);
    if (class == .transient) {
        reporter.write(.{ .transient_error = err }) catch return error.WriteFailed;
    }
    return cleanupFailure(session, ports, now, tracker, online, class, .{ .cause = err }, reporter);
}

fn handleAdapterError(
    session: *rj.session.Session,
    ports: platform.Ports,
    now: std.Io.Timestamp,
    err: coordinator.Error,
    tracker: *Tracker,
    online: *bool,
    reporter: Reporter,
) (RunError || Reporter.Error)!FailureResolution {
    const class = classifyCoordinatorError(err);
    if (class == .transient) {
        reporter.write(.{ .transient_error = err }) catch return error.WriteFailed;
    }
    return cleanupFailure(session, ports, now, tracker, online, class, .{ .cause = err }, reporter);
}

const FailureResolution = struct {
    pending_start: ?std.Io.Timestamp = null,
    termination: ?Termination = null,
};

fn cleanupFailure(
    session: *rj.session.Session,
    ports: platform.Ports,
    now: std.Io.Timestamp,
    tracker: *Tracker,
    online: *bool,
    class: FailureClass,
    failure: StepFailure,
    reporter: Reporter,
) (RunError || Reporter.Error)!FailureResolution {
    if (session.phase() != .idle) {
        var canceled = session.step(now, .cancel) catch |err| switch (err) {
            error.InvalidState => {
                if (session.phase() == .idle) {
                    return resolveAfterCleanup(now, tracker, online, class, failure, reporter);
                }
                return error.InvalidActionOrder;
            },
            else => {
                reporter.write(.{ .shutdown_failure = err }) catch return error.WriteFailed;
                return resolveAfterCleanup(now, tracker, online, class, failure, reporter);
            },
        };
        defer canceled.deinit(session.allocator);
        for (canceled.actions, 0..) |_, index| {
            _ = coordinator.dispatch(&ports, &canceled, index, null) catch |err| {
                reporter.write(.{ .shutdown_failure = err }) catch return error.WriteFailed;
            };
        }
    }
    return resolveAfterCleanup(now, tracker, online, class, failure, reporter);
}

fn resolveAfterCleanup(
    now: std.Io.Timestamp,
    tracker: *Tracker,
    online: *bool,
    class: FailureClass,
    failure: StepFailure,
    reporter: Reporter,
) Reporter.Error!FailureResolution {
    if (class == .transient) {
        online.* = false;
        try reporter.write(.disconnected);
        const retry_at = tracker.scheduleRetry(now) orelse {
            return .{ .termination = .{ .retry_exhausted = failure } };
        };
        try reporter.write(.{ .retry_scheduled = .{
            .attempt = tracker.retryAttempt(),
            .delay = now.durationTo(retry_at),
        } });
        return .{ .pending_start = retry_at };
    }
    return .{ .termination = terminationFor(class, failure) };
}

fn stopAndCleanup(
    session: *rj.session.Session,
    ports: platform.Ports,
    shutdown_timeout: std.Io.Duration,
    signal: platform.Stop.Request,
    reporter: Reporter,
) (RunError || Reporter.Error)!Termination {
    try reporter.write(.{ .shutdown_started = signal });
    const started = ports.clock.now() catch |err| {
        return .{ .internal_failure = err };
    };
    const deadline = started.addDuration(shutdown_timeout);

    if (session.phase() != .idle) {
        var canceled = session.step(started, .cancel) catch |err| switch (err) {
            error.InvalidState => {
                if (session.phase() != .idle) return .{ .internal_failure = err };
                return finishShutdown(ports, deadline, signal, reporter);
            },
            else => {
                reporter.write(.{ .shutdown_failure = err }) catch return error.WriteFailed;
                return .{ .internal_failure = err };
            },
        };
        defer canceled.deinit(session.allocator);

        for (canceled.actions, 0..) |_, index| {
            _ = coordinator.dispatch(&ports, &canceled, index, null) catch |err| {
                reporter.write(.{ .shutdown_failure = err }) catch return error.WriteFailed;
            };
        }
    }

    return finishShutdown(ports, deadline, signal, reporter);
}

fn finishShutdown(
    ports: platform.Ports,
    deadline: std.Io.Timestamp,
    signal: platform.Stop.Request,
    reporter: Reporter,
) (RunError || Reporter.Error)!Termination {
    const now = ports.clock.now() catch |err| {
        return .{ .internal_failure = err };
    };
    if (now.compare(.gt, deadline)) return .{ .internal_failure = error.ShutdownTimedOut };
    try reporter.write(.{ .shutdown_completed = signal });
    return .{ .signal = signal };
}

fn terminationFor(class: FailureClass, failure: StepFailure) Termination {
    return switch (class) {
        .transient => .{ .retry_exhausted = failure },
        .authentication_rejected => .{ .authentication_rejected = failure },
        .configuration => .{ .configuration_failure = failure },
        .security => .{ .security_failure = failure },
        .internal => .{ .internal_failure = failure.cause orelse error.InternalFailure },
    };
}

fn earliest(a: ?std.Io.Timestamp, b: ?std.Io.Timestamp) ?std.Io.Timestamp {
    if (a == null) return b;
    if (b == null) return a;
    return if (a.?.compare(.lte, b.?)) a.? else b.?;
}

pub fn classifyFailureReason(reason: rj.session.FailureReason) FailureClass {
    return switch (reason) {
        .server_failure,
        .direct_result_rejected,
        .mschapv2_failed,
        => .authentication_rejected,
        .canceled => .internal,
        .start_timeout,
        .auth_timeout,
        .dhcp_timeout,
        .server_logoff,
        .direct_send_failed,
        .direct_result_timeout,
        .smp_initialization_timeout,
        .tls_failed,
        => .transient,
    };
}

pub fn classifySessionError(err: rj.session.Error) FailureClass {
    return switch (err) {
        error.InvalidConfig, error.InvalidCredentials => .configuration,
        error.UnsupportedEapMethod,
        error.UnsupportedPeapMode,
        error.MissingDependency,
        error.MissingDirectParameters,
        => .security,
        error.InvalidFrame,
        error.DuplicateFrame,
        error.StaleIdentifier,
        error.TimerNotDue,
        error.StaleGeneration,
        => .transient,
        error.InvalidInput,
        error.InvalidTunnelInput,
        error.InvalidState,
        error.TimeWentBackwards,
        error.TimestampOverflow,
        error.GenerationOverflow,
        error.OutOfMemory,
        => .internal,
    };
}

pub fn classifyCoordinatorError(err: coordinator.Error) FailureClass {
    return switch (err) {
        error.InterfaceClosed, error.ReceiveFailed, error.SendFailed => .transient,
        error.IoFailed, error.LeaseUnavailable => .transient,
        error.LeaseInvalid => .configuration,
        error.CertificateRejected => .security,
        error.ProtocolFailed, error.TlsIoFailed => .transient,
        error.ResourceExhausted => .internal,
        error.ChallengeInvalid => .transient,
        error.ComputationFailed, error.VerificationFailed => .authentication_rejected,
        error.ActionOutOfRange, error.CredentialsRequired => .internal,
    };
}

//! Long-running authentication lifecycle independent of concrete adapters.

const std = @import("std");
const config = @import("config.zig");
const coordinator = @import("coordinator.zig");
const platform = @import("platform.zig");
const rj = @import("rj-connect");

pub const Policy = struct {
    retry_limit: config.RetryLimit = .unlimited,
    backoff_initial: std.Io.Duration,
    backoff_max: std.Io.Duration,
    /// Upper bound for one routine adapter operation batch. This is separate
    /// from the shared shutdown budget.
    operation_timeout: std.Io.Duration = .fromSeconds(5),
    shutdown_timeout: std.Io.Duration,

    pub fn validate(self: Policy) !void {
        if (self.backoff_initial.toNanoseconds() <= 0 or
            self.backoff_max.toNanoseconds() <= 0 or
            self.backoff_initial.toNanoseconds() > self.backoff_max.toNanoseconds() or
            self.operation_timeout.toNanoseconds() <= 0 or
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
    authentication_started: struct { retry_attempt: ?u32 },
    online,
    disconnected,
    protocol_failure: rj.session.FailureReason,
    transient_error: anyerror,
    retry_scheduled: struct { retry_attempt: u32, delay: std.Io.Duration },
    authentication_rejected: StepFailure,
    retry_exhausted: StepFailure,
    configuration_failure: StepFailure,
    security_failure: StepFailure,
    internal_failure: anyerror,
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
    policy: Policy,
    reporter: Reporter,
) Termination {
    const termination = runInner(session, ports, policy, reporter) catch |err|
        terminateAfterInternalError(session, ports, policy, err, reporter);
    reportTermination(reporter, termination);
    return termination;
}

const RunError = error{ InvalidPolicy, MissingFailureReason } ||
    platform.Clock.Error || platform.Stop.Error || platform.Wait.Error;

fn runInner(
    session: *rj.session.Session,
    ports: platform.Ports,
    policy: Policy,
    reporter: Reporter,
) (RunError || Reporter.Error)!Termination {
    var tracker = try Tracker.init(policy);
    var online = false;
    var pending_start: ?std.Io.Timestamp = null;
    var started_once = session.phase() != .idle;

    if (session.phase() == .authenticated) try noteOnline(&tracker, &online, reporter);

    while (true) {
        const now = try ports.clock.now();
        const stop = try ports.stop.tryNext();
        if (stop) |signal| return stopAndCleanup(session, ports, now, policy.shutdown_timeout, signal, reporter);

        if (!started_once and session.phase() == .idle) {
            started_once = true;
            const processed = try startAttempt(
                session,
                ports,
                policy,
                &tracker,
                &online,
                now,
                null,
                reporter,
            );
            if (processed.termination) |termination| return termination;
            pending_start = processed.pending_start;
            continue;
        }

        if (pending_start) |start_at| {
            if (now.compare(.gte, start_at)) {
                pending_start = null;
                const processed = try startAttempt(
                    session,
                    ports,
                    policy,
                    &tracker,
                    &online,
                    now,
                    tracker.retryAttempt(),
                    reporter,
                );
                if (processed.termination) |termination| return termination;
                pending_start = processed.pending_start;
                continue;
            }
            try ports.wait.wait(.{ .deadline = start_at, .receive = false });
            continue;
        }

        if (session.nextDeadline()) |deadline| {
            if (now.compare(.gte, deadline)) {
                const outcome = session.step(now, .{ .timer = session.currentGeneration() }) catch |err| {
                    const resolution = try handleSessionError(
                        session,
                        ports,
                        now,
                        policy.shutdown_timeout,
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
                    policy,
                    &tracker,
                    &online,
                    now,
                    outcome,
                    reporter,
                );
                if (processed.termination) |termination| return termination;
                pending_start = processed.pending_start;
                continue;
            }
        }

        const frame = ports.ethernet.tryReceive(null) catch |err| {
            const resolution = try handleAdapterError(
                session,
                ports,
                now,
                policy.shutdown_timeout,
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
            if (coordinator.requiresFactsRefresh(bytes)) {
                refreshFacts(session, ports, now, now.addDuration(policy.operation_timeout)) catch |err| {
                    const resolution = try handleFactsError(session, ports, now, policy.shutdown_timeout, err, &tracker, &online, reporter);
                    if (resolution.termination) |termination| return termination;
                    pending_start = resolution.pending_start;
                    continue;
                };
            }
            const outcome = session.step(now, .{ .frame = .{
                .generation = session.currentGeneration(),
                .bytes = bytes,
            } }) catch |err| {
                const resolution = try handleSessionError(
                    session,
                    ports,
                    now,
                    policy.shutdown_timeout,
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
                policy,
                &tracker,
                &online,
                now,
                outcome,
                reporter,
            );
            if (processed.termination) |termination| return termination;
            pending_start = processed.pending_start;
            continue;
        }

        // Successful sessions have no protocol timer. Null means block for
        // external readiness, not failure or a nonblocking polling interval.
        try ports.wait.wait(.{ .deadline = session.nextDeadline(), .receive = true });
    }
}

const Processed = struct {
    pending_start: ?std.Io.Timestamp = null,
    termination: ?Termination = null,
};

fn startAttempt(
    session: *rj.session.Session,
    ports: platform.Ports,
    policy: Policy,
    tracker: *Tracker,
    online: *bool,
    now: std.Io.Timestamp,
    retry_attempt: ?u32,
    reporter: Reporter,
) (RunError || Reporter.Error)!Processed {
    try reporter.write(.{ .authentication_started = .{ .retry_attempt = retry_attempt } });
    refreshFacts(session, ports, now, now.addDuration(policy.operation_timeout)) catch |err| {
        const resolution = try handleFactsError(session, ports, now, policy.shutdown_timeout, err, tracker, online, reporter);
        return .{ .pending_start = resolution.pending_start, .termination = resolution.termination };
    };
    const outcome = session.step(now, .start) catch |err| {
        const resolution = try handleSessionError(
            session,
            ports,
            now,
            policy.shutdown_timeout,
            err,
            tracker,
            online,
            reporter,
        );
        return .{ .pending_start = resolution.pending_start, .termination = resolution.termination };
    };
    return processStep(session, ports, policy, tracker, online, now, outcome, reporter);
}

fn processStep(
    session: *rj.session.Session,
    ports: platform.Ports,
    policy: Policy,
    tracker: *Tracker,
    online: *bool,
    now: std.Io.Timestamp,
    initial_outcome: rj.session.Outcome,
    reporter: Reporter,
) (RunError || Reporter.Error)!Processed {
    var outcome = initial_outcome;
    defer outcome.deinit(session.allocationOwner());
    const deadline = now.addDuration(policy.operation_timeout);

    for (outcome.actions, 0..) |_, index| {
        _ = coordinator.dispatch(&ports, &outcome, index, deadline) catch |err| {
            const resolution = try handleAdapterError(
                session,
                ports,
                now,
                policy.shutdown_timeout,
                err,
                tracker,
                online,
                reporter,
            );
            return .{ .pending_start = resolution.pending_start, .termination = resolution.termination };
        };
    }

    if (outcome.phase == .authenticated) try noteOnline(tracker, online, reporter);

    if (outcome.failure) |reason| {
        try reporter.write(.{ .protocol_failure = reason });
        const class = classifyFailureReason(reason);
        const resolution = cleanupFailure(
            session,
            ports,
            now,
            policy.shutdown_timeout,
            tracker,
            online,
            class,
            .{ .reason = reason },
            reporter,
        );
        return .{ .pending_start = resolution.pending_start, .termination = resolution.termination };
    }

    if (outcome.phase == .idle) return .{ .termination = .{ .internal_failure = error.MissingFailureReason } };
    return .{};
}

fn noteOnline(tracker: *Tracker, online: *bool, reporter: Reporter) Reporter.Error!void {
    tracker.reset();
    if (!online.*) {
        online.* = true;
        try reporter.write(.online);
    }
}

const FactsError = platform.NetworkState.Error || rj.session.Error;

fn refreshFacts(
    session: *rj.session.Session,
    ports: platform.Ports,
    now: platform.Timestamp,
    deadline: platform.Timestamp,
) FactsError!void {
    if (session.profile() != .macos_1_35_wired) return;
    const fresh = try ports.network.readFacts(deadline);
    var updated = try session.step(now, .{ .facts = fresh });
    defer updated.deinit(session.allocationOwner());
}

fn handleFactsError(
    session: *rj.session.Session,
    ports: platform.Ports,
    now: platform.Timestamp,
    shutdown_timeout: platform.Duration,
    err: FactsError,
    tracker: *Tracker,
    online: *bool,
    reporter: Reporter,
) Reporter.Error!FailureResolution {
    const class: FailureClass = switch (err) {
        error.DeadlineExceeded, error.FactsUnavailable, error.IoFailed => .transient,
        else => classifySessionError(@errorCast(err)),
    };
    if (class == .transient) try reporter.write(.{ .transient_error = err });
    return cleanupFailure(session, ports, now, shutdown_timeout, tracker, online, class, .{ .cause = err }, reporter);
}

fn handleSessionError(
    session: *rj.session.Session,
    ports: platform.Ports,
    now: std.Io.Timestamp,
    shutdown_timeout: std.Io.Duration,
    err: rj.session.Error,
    tracker: *Tracker,
    online: *bool,
    reporter: Reporter,
) (RunError || Reporter.Error)!FailureResolution {
    const class = classifySessionError(err);
    if (class == .transient) reporter.write(.{ .transient_error = err }) catch return error.WriteFailed;
    return cleanupFailure(session, ports, now, shutdown_timeout, tracker, online, class, .{ .cause = err }, reporter);
}

fn handleAdapterError(
    session: *rj.session.Session,
    ports: platform.Ports,
    now: std.Io.Timestamp,
    shutdown_timeout: std.Io.Duration,
    err: coordinator.Error,
    tracker: *Tracker,
    online: *bool,
    reporter: Reporter,
) (RunError || Reporter.Error)!FailureResolution {
    const class = classifyCoordinatorError(err);
    if (class == .transient) reporter.write(.{ .transient_error = err }) catch return error.WriteFailed;
    return cleanupFailure(session, ports, now, shutdown_timeout, tracker, online, class, .{ .cause = err }, reporter);
}

const FailureResolution = struct {
    pending_start: ?std.Io.Timestamp = null,
    termination: ?Termination = null,
};

const SessionCleanup = union(enum) { completed, failed: anyerror };

fn cancelAndDispatch(
    session: *rj.session.Session,
    ports: platform.Ports,
    now: std.Io.Timestamp,
    deadline: std.Io.Timestamp,
    reporter: Reporter,
) SessionCleanup {
    if (session.phase() == .idle) return .completed;
    var canceled = session.step(now, .cancel) catch |err| switch (err) {
        error.InvalidState => return if (session.phase() == .idle) .completed else .{ .failed = err },
        else => {
            reportBestEffort(reporter, .{ .shutdown_failure = err });
            return .{ .failed = err };
        },
    };
    defer canceled.deinit(session.allocationOwner());
    for (canceled.actions, 0..) |_, index| {
        _ = coordinator.dispatch(&ports, &canceled, index, deadline) catch |err| {
            reportBestEffort(reporter, .{ .shutdown_failure = err });
            return .{ .failed = err };
        };
    }
    return .completed;
}

fn cleanupFailure(
    session: *rj.session.Session,
    ports: platform.Ports,
    now: std.Io.Timestamp,
    shutdown_timeout: std.Io.Duration,
    tracker: *Tracker,
    online: *bool,
    class: FailureClass,
    failure: StepFailure,
    reporter: Reporter,
) FailureResolution {
    var recovered_at = now;
    if (session.phase() != .idle) {
        ports.watchdog.arm(shutdown_timeout, cleanupExitCode(class, failure)) catch |err| {
            reportBestEffort(reporter, .{ .shutdown_failure = err });
            return .{ .termination = cleanupAbortTermination(class, failure, err) };
        };
        defer ports.watchdog.disarm();
        const deadline = now.addDuration(shutdown_timeout);
        switch (cancelAndDispatch(session, ports, now, deadline, reporter)) {
            .completed => {},
            .failed => |err| return .{ .termination = cleanupAbortTermination(class, failure, err) },
        }
        recovered_at = ports.clock.now() catch |err| {
            reportBestEffort(reporter, .{ .shutdown_failure = err });
            return .{ .termination = cleanupAbortTermination(class, failure, err) };
        };
        if (recovered_at.compare(.gt, deadline)) {
            reportBestEffort(reporter, .{ .shutdown_failure = error.ShutdownTimedOut });
            return .{ .termination = cleanupAbortTermination(class, failure, error.ShutdownTimedOut) };
        }
    }
    return resolveAfterCleanup(recovered_at, tracker, online, class, failure, reporter);
}

fn resolveAfterCleanup(
    now: std.Io.Timestamp,
    tracker: *Tracker,
    online: *bool,
    class: FailureClass,
    failure: StepFailure,
    reporter: Reporter,
) FailureResolution {
    if (class == .transient) {
        online.* = false;
        reporter.write(.disconnected) catch return .{ .termination = .{ .internal_failure = error.WriteFailed } };
        const retry_at = tracker.scheduleRetry(now) orelse return .{ .termination = .{ .retry_exhausted = failure } };
        reporter.write(.{ .retry_scheduled = .{
            .retry_attempt = tracker.retryAttempt(),
            .delay = now.durationTo(retry_at),
        } }) catch return .{ .termination = .{ .internal_failure = error.WriteFailed } };
        return .{ .pending_start = retry_at };
    }
    return .{ .termination = terminationFor(class, failure) };
}

fn terminateAfterInternalError(
    session: *rj.session.Session,
    ports: platform.Ports,
    policy: Policy,
    err: anyerror,
    reporter: Reporter,
) Termination {
    const now = ports.clock.now() catch |clock_err| {
        reportBestEffort(reporter, .{ .shutdown_failure = clock_err });
        return .{ .internal_failure = clock_err };
    };
    var tracker: Tracker = .{ .policy = policy };
    var online = false;
    const resolution = cleanupFailure(
        session,
        ports,
        now,
        policy.shutdown_timeout,
        &tracker,
        &online,
        .internal,
        .{ .cause = err },
        reporter,
    );
    return resolution.termination orelse .{ .internal_failure = err };
}

fn stopAndCleanup(
    session: *rj.session.Session,
    ports: platform.Ports,
    started: std.Io.Timestamp,
    shutdown_timeout: std.Io.Duration,
    signal: platform.Stop.Request,
    reporter: Reporter,
) Termination {
    ports.watchdog.arm(shutdown_timeout, signalExitCode(signal)) catch |err| {
        reportBestEffort(reporter, .{ .shutdown_failure = err });
        return .{ .signal = signal };
    };
    defer ports.watchdog.disarm();
    const deadline = started.addDuration(shutdown_timeout);
    reportBestEffort(reporter, .{ .shutdown_started = signal });
    const before_cancel = ports.clock.now() catch |err| {
        reportBestEffort(reporter, .{ .shutdown_failure = err });
        return .{ .signal = signal };
    };
    if (before_cancel.compare(.gte, deadline)) {
        reportBestEffort(reporter, .{ .shutdown_failure = error.ShutdownTimedOut });
        return .{ .signal = signal };
    }
    switch (cancelAndDispatch(session, ports, before_cancel, deadline, reporter)) {
        .completed => {},
        .failed => return .{ .signal = signal },
    }
    const now = ports.clock.now() catch |err| {
        reportBestEffort(reporter, .{ .shutdown_failure = err });
        return .{ .signal = signal };
    };
    if (now.compare(.gt, deadline)) reportBestEffort(reporter, .{ .shutdown_failure = error.ShutdownTimedOut }) else reportBestEffort(reporter, .{ .shutdown_completed = signal });
    return .{ .signal = signal };
}

fn cleanupAbortTermination(class: FailureClass, failure: StepFailure, cause: anyerror) Termination {
    return switch (class) {
        .transient, .internal => .{ .internal_failure = cause },
        else => terminationFor(class, failure),
    };
}

fn cleanupExitCode(class: FailureClass, failure: StepFailure) u8 {
    return switch (class) {
        .transient, .internal => 6,
        else => terminationFor(class, failure).exitCode(),
    };
}

fn signalExitCode(signal: platform.Stop.Request) u8 {
    return switch (signal) {
        .interrupt => 130,
        .terminate => 143,
    };
}

fn reportBestEffort(reporter: Reporter, event: Event) void {
    reporter.write(event) catch {};
}

fn reportTermination(reporter: Reporter, termination: Termination) void {
    switch (termination) {
        .signal => {},
        .authentication_rejected => |failure| reportBestEffort(reporter, .{ .authentication_rejected = failure }),
        .retry_exhausted => |failure| reportBestEffort(reporter, .{ .retry_exhausted = failure }),
        .configuration_failure => |failure| reportBestEffort(reporter, .{ .configuration_failure = failure }),
        .security_failure => |failure| reportBestEffort(reporter, .{ .security_failure = failure }),
        .internal_failure => |err| reportBestEffort(reporter, .{ .internal_failure = err }),
    }
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

pub fn classifyFailureReason(reason: rj.session.FailureReason) FailureClass {
    return switch (reason) {
        .server_failure => .authentication_rejected,
        .canceled => .internal,
        .start_timeout, .auth_timeout, .server_logoff => .transient,
    };
}

pub fn classifySessionError(err: rj.session.Error) FailureClass {
    return switch (err) {
        error.InvalidConfig, error.InvalidFacts, error.InvalidCredentials => .configuration,
        error.UnsupportedEapMethod, error.UnsupportedProfileInput => .security,
        error.InvalidFrame, error.DuplicateFrame, error.StaleIdentifier, error.StaleTerminalIdentifier, error.TimerNotDue, error.StaleGeneration => .transient,
        error.InvalidState, error.TimeWentBackwards, error.TimestampOverflow, error.GenerationOverflow, error.OutOfMemory => .internal,
    };
}

pub fn classifyCoordinatorError(err: coordinator.Error) FailureClass {
    return switch (err) {
        error.DeadlineExceeded, error.InterfaceClosed, error.ReceiveFailed, error.SendFailed => .transient,
        error.ActionOutOfRange => .internal,
    };
}

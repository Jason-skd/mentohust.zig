//! System capabilities consumed by the authentication client.
//!
//! The protocol dependency owns authentication semantics. Concrete adapters own
//! platform I/O and provide the runtime facts required by the selected profile.

const std = @import("std");
const rj = @import("rj-connect");

pub const Timestamp = std.Io.Timestamp;
pub const Duration = std.Io.Duration;
pub const Deadline = ?Timestamp;

pub const Ethernet = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        DeadlineExceeded,
        InterfaceClosed,
        ReceiveFailed,
        SendFailed,
    };

    pub const VTable = struct {
        send: *const fn (context: *anyopaque, frame: []const u8, deadline: Deadline) Error!void,
        tryReceive: *const fn (context: *anyopaque, deadline: Deadline) Error!?[]const u8,
    };

    pub fn send(self: Ethernet, frame: []const u8, deadline: Deadline) Error!void {
        return self.vtable.send(self.context, frame, deadline);
    }

    pub fn tryReceive(self: Ethernet, deadline: Deadline) Error!?[]const u8 {
        return self.vtable.tryReceive(self.context, deadline);
    }
};

pub const NetworkState = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        DeadlineExceeded,
        FactsUnavailable,
        IoFailed,
        InvalidFacts,
    };

    pub const VTable = struct {
        readFacts: *const fn (context: *anyopaque, deadline: Deadline) Error!rj.session.Facts,
    };

    pub fn readFacts(self: NetworkState, deadline: Deadline) Error!rj.session.Facts {
        return self.vtable.readFacts(self.context, deadline);
    }
};

pub const Clock = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        ClockFailed,
        Interrupted,
    };

    pub const VTable = struct {
        now: *const fn (context: *anyopaque) Error!Timestamp,
        waitUntil: *const fn (context: *anyopaque, deadline: Timestamp) Error!void,
    };

    pub fn now(self: Clock) Error!Timestamp {
        return self.vtable.now(self.context);
    }

    pub fn waitUntil(self: Clock, deadline: Timestamp) Error!void {
        return self.vtable.waitUntil(self.context, deadline);
    }
};

pub const Stop = struct {
    //! Signal adapters interrupt waits and report bounded shutdown requests.

    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{SignalWaitFailed};
    pub const Request = enum { interrupt, terminate };

    pub const VTable = struct {
        tryNext: *const fn (context: *anyopaque) Error!?Request,
    };

    pub fn tryNext(self: Stop) Error!?Request {
        return self.vtable.tryNext(self.context);
    }
};

pub const Watchdog = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{WatchdogFailed};

    pub const VTable = struct {
        /// Arms a hard process exit after `timeout` unless disarmed first.
        arm: *const fn (context: *anyopaque, timeout: Duration, exit_code: u8) Error!void,
        disarm: *const fn (context: *anyopaque) void,
    };

    pub fn arm(self: Watchdog, timeout: Duration, exit_code: u8) Error!void {
        return self.vtable.arm(self.context, timeout, exit_code);
    }

    pub fn disarm(self: Watchdog) void {
        self.vtable.disarm(self.context);
    }
};

pub const Ports = struct {
    ethernet: Ethernet,
    network: NetworkState,
    clock: Clock,
    stop: Stop,
    watchdog: Watchdog,
};

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
        /// Sends one complete frame. A null deadline selects the adapter's
        /// bounded default; lifecycle-managed sends supply their own absolute
        /// deadline so routine I/O never inherits the shutdown policy.
        send: *const fn (context: *anyopaque, frame: []const u8, deadline: Deadline) Error!void,
        /// Nonblocking probe. The borrowed frame remains valid until the next
        /// Ethernet call; null means no queued frame. Blocking belongs to Wait.
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
        /// Reads one fresh facts snapshot.
        ///
        /// The deadline is best-effort because POSIX `getifaddrs` cannot be
        /// canceled once entered. The adapter must reject an already-expired
        /// deadline before reading and report `DeadlineExceeded` if it observes
        /// expiry before returning; a null deadline requests no bound.
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
    };

    pub const VTable = struct {
        now: *const fn (context: *anyopaque) Error!Timestamp,
    };

    pub fn now(self: Clock) Error!Timestamp {
        return self.vtable.now(self.context);
    }
};

pub const Wait = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{WaitFailed};
    pub const Options = struct {
        /// Absolute time in the same monotonic domain as Clock.now. An expired
        /// deadline returns immediately; null waits indefinitely for readiness.
        deadline: Deadline,
        /// False during retry backoff: queued frames must not cause busy wakes.
        receive: bool,
    };

    pub const VTable = struct {
        /// Blocks until Ethernet is readable (when requested), a stop is queued,
        /// or the absolute deadline is reached. Null means no timer, not polling.
        /// A queued signal must wake this call even if queued before it starts;
        /// waiting never consumes the signal or frame. EINTR and spurious wakes
        /// return normally so the caller rechecks readiness and the same deadline.
        wait: *const fn (context: *anyopaque, options: Options) Error!void,
    };

    pub fn wait(self: Wait, options: Options) Error!void {
        return self.vtable.wait(self.context, options);
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
    wait: Wait,
    stop: Stop,
    watchdog: Watchdog,
};

//! System capabilities consumed by the authentication coordinator.
//!
//! Every port has an opaque context and a function table. Concrete adapters own
//! their buffers and mappings; the coordinator only borrows bytes for one call.

const std = @import("std");
const rj = @import("rj-connect");

pub const Timestamp = std.Io.Timestamp;
pub const Duration = std.Io.Duration;

pub const Ethernet = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        InterfaceClosed,
        ReceiveFailed,
        SendFailed,
    };

    pub const VTable = struct {
        send: *const fn (context: *anyopaque, frame: []const u8) Error!void,
        tryReceive: *const fn (context: *anyopaque) Error!?[]const u8,
    };

    pub fn send(self: Ethernet, frame: []const u8) Error!void {
        return self.vtable.send(self.context, frame);
    }

    pub fn tryReceive(self: Ethernet) Error!?[]const u8 {
        return self.vtable.tryReceive(self.context);
    }
};

pub const NetworkState = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        IoFailed,
        LeaseInvalid,
        LeaseUnavailable,
    };

    pub const VTable = struct {
        readDhcpLease: *const fn (context: *anyopaque) Error!rj.session.DhcpLease,
    };

    pub fn readDhcpLease(self: NetworkState) Error!rj.session.DhcpLease {
        return self.vtable.readDhcpLease(self.context);
    }
};

pub const Tls = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        CertificateRejected,
        ProtocolFailed,
        ResourceExhausted,
        TlsIoFailed,
    };

    pub const VTable = struct {
        /// Returned slices remain valid until the adapter's next call.
        process: *const fn (
            context: *anyopaque,
            operation: rj.session.TunnelOperation,
            bytes: []const u8,
        ) Error!rj.session.TunnelOutput,
    };

    pub fn process(
        self: Tls,
        operation: rj.session.TunnelOperation,
        bytes: []const u8,
    ) Error!rj.session.TunnelOutput {
        return self.vtable.process(self.context, operation, bytes);
    }
};

pub const Mschapv2 = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Verification = struct {
        verified: bool,
        /// Client EAP-MSCHAPv2 success payload returned by the adapter.
        response_data: []const u8 = &.{},
    };

    pub const Error = error{
        ChallengeInvalid,
        ComputationFailed,
        ResourceExhausted,
        VerificationFailed,
    };

    pub const VTable = struct {
        /// Returned slices remain valid until the adapter's next call.
        authenticate: *const fn (
            context: *anyopaque,
            challenge: []const u8,
            credentials: rj.session.Credentials,
        ) Error![]const u8,
        verify: *const fn (
            context: *anyopaque,
            challenge: []const u8,
            credentials: rj.session.Credentials,
        ) Error!Verification,
    };

    pub fn authenticate(
        self: Mschapv2,
        challenge: []const u8,
        credentials: rj.session.Credentials,
    ) Error![]const u8 {
        return self.vtable.authenticate(self.context, challenge, credentials);
    }

    pub fn verify(
        self: Mschapv2,
        challenge: []const u8,
        credentials: rj.session.Credentials,
    ) Error!Verification {
        return self.vtable.verify(self.context, challenge, credentials);
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
    //! Signal adapters must interrupt `Clock.waitUntil` when a request arrives,
    //! and block-bounded adapters must finish or cancel within lifecycle deadlines.

    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{SignalWaitFailed};
    pub const Request = enum {
        interrupt,
        terminate,
    };

    pub const VTable = struct {
        tryNext: *const fn (context: *anyopaque) Error!?Request,
    };

    pub fn tryNext(self: Stop) Error!?Request {
        return self.vtable.tryNext(self.context);
    }
};

pub const Ports = struct {
    ethernet: Ethernet,
    network: NetworkState,
    tls: Tls,
    mschapv2: Mschapv2,
    clock: Clock,
    stop: Stop,
};

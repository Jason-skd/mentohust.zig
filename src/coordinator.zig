//! Maps deterministic session actions to system capabilities.

const platform = @import("platform.zig");
const rj = @import("rj-connect");

pub const Error = platform.Ethernet.Error || error{ActionOutOfRange};

pub const Result = enum { handled };

/// Facts are required before replying to an EAP Request, because request
/// responses embed the current interface addresses and deployment values.
/// Success, Failure, Logoff, and unrelated EAPOL frames do not allocate facts.
pub fn requiresFactsRefresh(frame: []const u8) bool {
    const decoded = rj.protocol.eapol.decode(frame) catch return false;
    return decoded.packet_type == .eap and
        decoded.eap != null and
        decoded.eap.?.code == .request;
}

/// Sends one owned action through the injected Ethernet adapter.
///
/// The action and generation are read from the same outcome so a caller cannot
/// accidentally dispatch an action from a different authentication attempt.
/// A non-null deadline belongs to the action batch; null delegates to the
/// adapter's bounded default.
pub fn dispatch(
    ports: *const platform.Ports,
    outcome: *const rj.session.Outcome,
    action_index: usize,
    deadline: platform.Deadline,
) Error!Result {
    if (action_index >= outcome.actions.len) return error.ActionOutOfRange;
    return switch (outcome.actions[action_index]) {
        .send_frame => |frame| blk: {
            try ports.ethernet.send(frame, deadline);
            break :blk .handled;
        },
    };
}

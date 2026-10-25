//! Maps deterministic session actions to system capabilities.

const platform = @import("platform.zig");
const rj = @import("rj-connect");

pub const Error = platform.Ethernet.Error || error{ActionOutOfRange};

pub const Result = enum { handled };

/// Sends one owned action through the injected Ethernet adapter.
///
/// The action and generation are read from the same outcome so a caller cannot
/// accidentally dispatch an action from a different authentication attempt.
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

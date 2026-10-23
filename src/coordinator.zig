//! Maps deterministic session actions to system capabilities.

const platform = @import("platform.zig");
const rj = @import("rj-connect");

pub const Error = platform.Ethernet.Error ||
    platform.NetworkState.Error ||
    platform.Tls.Error ||
    platform.Mschapv2.Error ||
    error{
        ActionOutOfRange,
        CredentialsRequired,
    };

/// Borrowed coordinator output.
///
/// `session_input` and `direct_auth_result` borrow from `Outcome.actions` and
/// the credentials passed to `dispatch`. Adapter-produced slices are
/// additionally valid only until that adapter's next call. Consume either case
/// before those borrows end and before reusing the originating adapter.
pub const Result = union(enum) {
    handled,
    session_input: rj.session.Input,
    request_credentials: rj.session.CredentialPurpose,
    direct_auth_result: rj.session.DirectAuthResult,
    reauth_required,
};

/// Maps one action from `outcome` to a system capability.
///
/// Generation and action ownership are both taken from `outcome`, so an action
/// cannot be paired with an unrelated authentication attempt.
pub fn dispatch(
    ports: *const platform.Ports,
    outcome: *const rj.session.Outcome,
    action_index: usize,
    credentials: ?rj.session.Credentials,
    deadline: platform.Deadline,
) Error!Result {
    if (action_index >= outcome.actions.len) return error.ActionOutOfRange;
    const action = outcome.actions[action_index];
    const generation = outcome.generation;
    return switch (action) {
        .send_frame => |frame| blk: {
            try ports.ethernet.send(frame, deadline);
            break :blk .handled;
        },
        .request_credentials => |purpose| .{ .request_credentials = purpose },
        .poll_dhcp => .{ .session_input = externalResultInput(
            generation,
            .{ .dhcp_lease = try ports.network.readDhcpLease(deadline) },
        ) },
        .tunnel_input => |input| .{ .session_input = .{ .tunnel_output = .{
            .generation = generation,
            .output = try ports.tls.process(input.operation, input.bytes, deadline),
        } } },
        .authenticate_mschapv2 => |challenge| blk: {
            const value = credentials orelse return error.CredentialsRequired;
            break :blk .{ .session_input = externalResultInput(
                generation,
                .{ .mschapv2_response = .{
                    .credentials = value,
                    .response_data = try ports.mschapv2.authenticate(
                        challenge.request_data,
                        value,
                        deadline,
                    ),
                } },
            ) };
        },
        .verify_mschapv2 => |challenge| blk: {
            const value = credentials orelse return error.CredentialsRequired;
            const verification = try ports.mschapv2.verify(challenge.request_data, value, deadline);
            break :blk .{ .session_input = externalResultInput(
                generation,
                .{ .mschapv2_success = .{
                    .verified = verification.verified,
                    .response_data = verification.response_data,
                } },
            ) };
        },
        .direct_auth_result => |result| .{ .direct_auth_result = result },
        .reauth_required => .reauth_required,
    };
}

fn externalResultInput(
    generation: rj.session.Generation,
    result: rj.session.ExternalResult,
) rj.session.Input {
    return .{ .external_result = .{
        .generation = generation,
        .result = result,
    } };
}

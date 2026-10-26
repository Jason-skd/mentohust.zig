//! Interface snapshots plus explicit deployment facts, without changing system
//! network configuration. Borrowed deployment strings outlive the session.
const builtin = @import("builtin");
const std = @import("std");
const system = @import("system.zig");
const c = system.c;
const platform = @import("platform.zig");
const rj = @import("rj-connect");

pub const Deployment = struct {
    service_name: []const u8 = "",
    disk_serial: []const u8 = "",
    alternate_dns_text: []const u8 = "",
    dhcp_enabled: bool = false,
    gateway: [4]u8 = @splat(0),
    dns: [4]u8 = @splat(0),

    pub fn validate(self: Deployment) error{InvalidFacts}!void {
        (rj.session.Facts{
            .source_mac = @splat(0),
            .service_name = self.service_name,
            .disk_serial = self.disk_serial,
            .alternate_dns_text = self.alternate_dns_text,
        }).validate() catch return error.InvalidFacts;
        for (self.disk_serial) |byte| if (byte < 0x20 or byte > 0x7e) return error.InvalidFacts;
        for (self.alternate_dns_text) |byte| if (byte < 0x20 or byte > 0x7e) return error.InvalidFacts;
    }
};

pub const Snapshot = struct {
    name: [:0]const u8,
    deployment: Deployment,

    pub fn read(self: Snapshot) platform.NetworkState.Error!rj.session.Facts {
        try self.deployment.validate();
        var list: [*c]c.struct_ifaddrs = null;
        if (c.getifaddrs(&list) != 0) return error.IoFailed;
        defer if (list != null) c.freeifaddrs(list);
        var result: rj.session.Facts = .{
            .source_mac = @splat(0),
            .service_name = self.deployment.service_name,
            .disk_serial = self.deployment.disk_serial,
            .alternate_dns_text = self.deployment.alternate_dns_text,
            .os_bits = if (@sizeOf(usize) == 4) 0x20 else 0x40,
            .lease = .{
                .dhcp_enabled = self.deployment.dhcp_enabled,
                .gateway = self.deployment.gateway,
                .dns = self.deployment.dns,
            },
        };
        var found = false;
        var node = list;
        while (node != null) : (node = node.*.ifa_next) {
            const entry = node.*;
            if (!std.mem.eql(u8, std.mem.span(entry.ifa_name), self.name) or entry.ifa_addr == null) continue;
            if (entry.ifa_flags & c.IFF_LOOPBACK != 0) continue;
            const address = entry.ifa_addr;
            if (builtin.os.tag == .linux and address.*.sa_family == c.AF_PACKET) {
                const link: *const c.struct_sockaddr_ll = @ptrCast(@alignCast(address));
                if (link.sll_halen == 6 and link.sll_hatype == 1) {
                    result.source_mac = link.sll_addr[0..6].*;
                    found = true;
                }
            } else if (builtin.os.tag == .macos and address.*.sa_family == c.AF_LINK) {
                const link: *const c.struct_sockaddr_dl = @ptrCast(@alignCast(address));
                const offset = @offsetOf(c.struct_sockaddr_dl, "sdl_data") + @as(usize, link.sdl_nlen);
                if (link.sdl_type == 6 and link.sdl_alen == 6 and offset + 6 <= link.sdl_len) {
                    const raw: [*]const u8 = @ptrCast(link);
                    result.source_mac = raw[offset..][0..6].*;
                    found = true;
                }
            } else if (address.*.sa_family == c.AF_INET and entry.ifa_netmask != null) {
                const ipv4: *const c.struct_sockaddr_in = @ptrCast(@alignCast(address));
                const mask: *const c.struct_sockaddr_in = @ptrCast(@alignCast(entry.ifa_netmask));
                const ip = std.mem.toBytes(ipv4.sin_addr.s_addr);
                if (std.mem.allEqual(u8, &result.lease.ip, 0) or std.mem.order(u8, &ip, &result.lease.ip) == .lt) {
                    result.lease.ip = ip;
                    result.lease.netmask = std.mem.toBytes(mask.sin_addr.s_addr);
                }
            } else if (address.*.sa_family == c.AF_INET6) {
                const ipv6: *const c.struct_sockaddr_in6 = @ptrCast(@alignCast(address));
                const raw: *const [16]u8 = @ptrCast(&ipv6.sin6_addr);
                addIpv6(&result, raw.*);
            }
        }
        if (!found or result.source_mac[0] & 1 != 0 or std.mem.allEqual(u8, &result.source_mac, 0)) return error.FactsUnavailable;
        result.validate() catch return error.InvalidFacts;
        return result;
    }
};

fn addIpv6(facts: *rj.session.Facts, address: [16]u8) void {
    if (std.mem.allEqual(u8, &address, 0) or address[0] == 0xff or
        (std.mem.allEqual(u8, address[0..15], 0) and address[15] == 1)) return;
    var normalized = address;
    if (address[0] == 0xfe and address[1] & 0xc0 == 0x80) {
        // Darwin can embed the interface scope in the link-local address.
        if (builtin.os.tag == .macos) @memset(normalized[2..4], 0);
        if (facts.ipv6_link_local == null or std.mem.order(u8, &normalized, &facts.ipv6_link_local.?) == .lt)
            facts.ipv6_link_local = normalized;
    } else if (facts.ipv6_global == null or std.mem.order(u8, &normalized, &facts.ipv6_global.?) == .lt) {
        facts.ipv6_third = facts.ipv6_global;
        facts.ipv6_global = normalized;
    } else if (!std.mem.eql(u8, &normalized, &facts.ipv6_global.?) and
        (facts.ipv6_third == null or std.mem.order(u8, &normalized, &facts.ipv6_third.?) == .lt))
    {
        facts.ipv6_third = normalized;
    }
    facts.ipv6_state = 5;
}

pub fn parseIpv4(text: []const u8) error{InvalidIpv4}![4]u8 {
    var result: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    for (&result) |*octet| {
        const part = it.next() orelse return error.InvalidIpv4;
        if (part.len == 0 or part.len > 3) return error.InvalidIpv4;
        for (part) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidIpv4;
        octet.* = std.fmt.parseUnsigned(u8, part, 10) catch return error.InvalidIpv4;
    }
    if (it.next() != null) return error.InvalidIpv4;
    return result;
}

test "deployment facts reject oversized or non-ASCII serials and DNS text" {
    try std.testing.expectError(error.InvalidFacts, (Deployment{ .service_name = &@as([33]u8, @splat('x')) }).validate());
    try std.testing.expectError(error.InvalidFacts, (Deployment{ .disk_serial = "\n" }).validate());
    try std.testing.expectError(error.InvalidFacts, (Deployment{ .alternate_dns_text = &@as([248]u8, @splat('x')) }).validate());
    try (Deployment{}).validate();
}

test "IPv4 inputs require four bounded decimal octets" {
    try std.testing.expectEqual([4]u8{ 10, 2, 3, 255 }, try parseIpv4("10.2.3.255"));
    for ([_][]const u8{ "1.2.3", "256.1.1.1", "1.2.3.4.5", "1..2.3", "+1.2.3.4" }) |text|
        try std.testing.expectError(error.InvalidIpv4, parseIpv4(text));
}

test "missing interface facts fail without raw socket privileges" {
    const snapshot: Snapshot = .{ .name = "m3-missing0", .deployment = .{} };
    try std.testing.expectError(error.FactsUnavailable, snapshot.read());
}

test "a real Ethernet interface snapshot retains explicit deployment facts" {
    var list: [*c]c.struct_ifaddrs = null;
    if (c.getifaddrs(&list) != 0) return error.IoFailed;
    defer if (list != null) c.freeifaddrs(list);
    var node = list;
    while (node != null) : (node = node.*.ifa_next) {
        const snapshot: Snapshot = .{
            .name = std.mem.span(node.*.ifa_name),
            .deployment = .{ .service_name = "campus", .gateway = .{ 10, 0, 0, 1 } },
        };
        const actual = snapshot.read() catch |err| switch (err) {
            error.FactsUnavailable => continue,
            else => return err,
        };
        try std.testing.expect(!std.mem.allEqual(u8, &actual.source_mac, 0));
        try std.testing.expectEqualStrings("campus", actual.service_name);
        try std.testing.expectEqual([4]u8{ 10, 0, 0, 1 }, actual.lease.gateway);
        try std.testing.expectEqual(@as(u8, if (@sizeOf(usize) == 4) 0x20 else 0x40), actual.os_bits);
        return;
    }
    return error.SkipZigTest;
}

test "IPv6 slots are deterministic and ignore multicast and loopback" {
    var facts: rj.session.Facts = .{ .source_mac = @splat(0) };
    addIpv6(&facts, @splat(0));
    addIpv6(&facts, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    try std.testing.expectEqual(@as(u8, 0), facts.ipv6_state);
    addIpv6(&facts, .{ 0x20, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 });
    addIpv6(&facts, .{ 0x20, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    try std.testing.expectEqual(@as(u8, 1), facts.ipv6_global.?[15]);
    try std.testing.expectEqual(@as(u8, 2), facts.ipv6_third.?[15]);
}

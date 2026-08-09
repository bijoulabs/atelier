//! Attribution for the server's remote authoring surface: who, on which
//! machine, submitted a mutation. Identity is derived from the network,
//! never from client claims: the stateless MCP profile means a later call
//! cannot be tied to an earlier initialize, and anything the client says
//! about itself is trivially forged. When the host runs Tailscale,
//! `tailscale whois` maps the peer address to a node name and user login,
//! authenticated by the tailnet itself. Tailscale is an opportunistic
//! enrichment, not a dependency: without the binary (or for a
//! non-tailnet peer) the ladder degrades to loopback-is-local and
//! everything-else-is-an-ip, with zero configuration.

const std = @import("std");
const net = std.Io.net;

/// How an identity was established, most to least trustworthy.
pub const Source = enum { tailscale, local, ip };

/// One resolved peer identity. `user` is the tailnet login when known
/// (tagged nodes have none); `machine` is the node's short name, the bare
/// ip when whois had no answer, or "" for local. Strings are owned by the
/// allocator that produced the value.
pub const Identity = struct {
    user: ?[]const u8,
    machine: []const u8,
    source: Source,
};

/// Upper bound on `tailscale whois --json` output. The payload is a few
/// KB of node metadata plus an unbounded profile picture URL; a quarter
/// megabyte is far past anything real.
pub const whois_bytes_max = 256 * 1024;

/// The slice of the whois JSON this module cares about.
///
/// NOTE: field names deliberately break the snake_case convention to
/// mirror the external JSON exactly; std.json matches by name.
const WhoisShape = struct {
    Node: struct {
        Name: []const u8 = "",
        ComputedName: []const u8 = "",
    } = .{},
    UserProfile: struct {
        LoginName: []const u8 = "",
    } = .{},
};

/// Parses `tailscale whois --json` output into an `Identity` with
/// `alloc`-owned strings, or null when the bytes do not amount to one
/// (garbage, or a JSON object naming neither user nor node). Pure so the
/// fixture tests need no subprocess; `resolve` owns the shell-out.
pub fn parseWhois(alloc: std.mem.Allocator, bytes: []const u8) !?Identity {
    const parsed = std.json.parseFromSlice(WhoisShape, alloc, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const machine_src = blk: {
        const computed = parsed.value.Node.ComputedName;
        if (computed.len > 0) break :blk computed;
        const full = parsed.value.Node.Name;
        const dot = std.mem.indexOfScalar(u8, full, '.') orelse full.len;
        break :blk full[0..dot];
    };
    const login = parsed.value.UserProfile.LoginName;
    if (machine_src.len == 0 and login.len == 0) return null;

    return .{
        .user = if (login.len > 0) try alloc.dupe(u8, login) else null,
        .machine = try alloc.dupe(u8, machine_src),
        .source = .tailscale,
    };
}

/// The peer's address as bare text: no port, no brackets, no zone. This
/// is what lands in a whois argv and in attribution labels.
pub fn formatBareIp(alloc: std.mem.Allocator, addr: net.IpAddress) ![]u8 {
    switch (addr) {
        .ip4 => |a| {
            return std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}", .{
                a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3],
            });
        },
        .ip6 => {
            // NOTE: this std's IpAddress.format always appends the port
            // ("[addr]:port" for v6), so the bare form is carved out of
            // the printed one rather than reimplementing v6 compression.
            const printed = try std.fmt.allocPrint(alloc, "{f}", .{addr});
            defer alloc.free(printed);
            if (printed.len > 0 and printed[0] == '[') {
                if (std.mem.lastIndexOfScalar(u8, printed, ']')) |end| {
                    return alloc.dupe(u8, printed[1..end]);
                }
            }
            const colon = std.mem.lastIndexOfScalar(u8, printed, ':') orelse printed.len;
            return alloc.dupe(u8, printed[0..colon]);
        },
    }
}

/// Whether the peer is the serve machine itself (loopback or the
/// unspecified address, including the v4-mapped-in-v6 forms). Local
/// callers are the owner: their commits carry the repository's own
/// identity, exactly like the CLI.
pub fn isLoopback(addr: net.IpAddress) bool {
    switch (addr) {
        .ip4 => |a| {
            if (a.bytes[0] == 127) return true;
            return std.mem.allEqual(u8, &a.bytes, 0);
        },
        .ip6 => |a| {
            if (a.isLoopBack()) return true;
            if (std.mem.allEqual(u8, &a.bytes, 0)) return true;
            // ::ffff:127.x.y.z, a v4 loopback arriving through a v6 socket.
            const v4_mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
            if (std.mem.eql(u8, a.bytes[0..12], &v4_mapped_prefix)) return a.bytes[12] == 127;
            return false;
        },
    }
}

/// The `git commit --author` value for a remote mutation, or null when
/// the peer is local and the repository's own identity should stand. A
/// login that is not email-shaped gets the neutral synthetic domain
/// `@remote`; so does a peer with no login at all (tagged node, bare ip).
pub fn gitAuthor(alloc: std.mem.Allocator, id: Identity) !?[]u8 {
    if (id.source == .local) return null;
    std.debug.assert(id.machine.len > 0);
    const user = id.user orelse "unknown";
    const email_shaped = blk: {
        const at = std.mem.indexOfScalar(u8, user, '@') orelse break :blk false;
        break :blk at > 0 and at < user.len - 1;
    };
    if (email_shaped) {
        return try std.fmt.allocPrint(alloc, "{s} via {s} <{s}>", .{ user, id.machine, user });
    }
    return try std.fmt.allocPrint(alloc, "{s} via {s} <{s}@remote>", .{ user, id.machine, user });
}

/// A one-phrase human label for tool results and the shares.log identity
/// column: "user from machine", the bare machine/ip, or "local". Tabs
/// and newlines are flattened to spaces because whois output crosses a
/// process boundary and this string lands in a TSV ledger.
pub fn label(alloc: std.mem.Allocator, id: Identity) ![]u8 {
    const raw = blk: {
        if (id.source == .local) break :blk try alloc.dupe(u8, "local");
        if (id.user) |user| {
            break :blk try std.fmt.allocPrint(alloc, "{s} from {s}", .{ user, id.machine });
        }
        break :blk try alloc.dupe(u8, id.machine);
    };
    for (raw) |*c| {
        if (c.* == '\t' or c.* == '\n' or c.* == '\r') c.* = ' ';
    }
    return raw;
}

/// One cached whois answer; strings are cache-owned page_allocator dupes.
const Cached = struct {
    id: Identity,
    at_sec: i64,
};

/// Whois answers by bare-ip text, so one subprocess per peer per TTL
/// rather than per request (every request is its own connection). Bounded
/// by clearing wholesale at a cap; entries are page_allocator-owned, the
/// same reasoning as serve.zig's SSE client list.
var cache: std.StringHashMapUnmanaged(Cached) = .empty;
var cache_mu: std.Io.Mutex = .init;
const cache_ttl_sec = 60;
const cache_entries_max = 256;

fn cacheGet(io: std.Io, ip_text: []const u8, now_sec: i64) ?Identity {
    cache_mu.lock(io) catch return null;
    defer cache_mu.unlock(io);
    const entry = cache.get(ip_text) orelse return null;
    if (now_sec - entry.at_sec > cache_ttl_sec) return null;
    return entry.id;
}

fn cachePut(io: std.Io, ip_text: []const u8, id: Identity, now_sec: i64) void {
    const gpa = std.heap.page_allocator;
    cache_mu.lock(io) catch return;
    defer cache_mu.unlock(io);
    if (cache.count() >= cache_entries_max) clearCacheLocked(gpa);
    if (cache.contains(ip_text)) return; // a racing resolver already filled it
    const key = gpa.dupe(u8, ip_text) catch return;
    const owned: Identity = .{
        .user = if (id.user) |u| gpa.dupe(u8, u) catch return else null,
        .machine = gpa.dupe(u8, id.machine) catch return,
        .source = id.source,
    };
    cache.put(gpa, key, .{ .id = owned, .at_sec = now_sec }) catch return;
}

/// Frees every cache entry; the mutex must already be held. Wholesale
/// clearing is crude but bounded and simple, and 256 distinct peers per
/// minute is far past any real tailnet.
fn clearCacheLocked(gpa: std.mem.Allocator) void {
    var entries = cache.iterator();
    while (entries.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        if (entry.value_ptr.id.user) |u| gpa.free(u);
        gpa.free(entry.value_ptr.id.machine);
    }
    cache.clearRetainingCapacity();
}

/// Resolves a peer address to an identity, with `alloc`-owned strings.
/// The ladder: loopback is the owner; otherwise ask `tailscale whois`
/// (cached per ip for `cache_ttl_sec`); any failure at all, binary
/// missing, non-tailnet peer, unparseable output, degrades to the bare
/// ip. Never errors and never blocks a mutation on attribution quality.
pub fn resolve(alloc: std.mem.Allocator, io: std.Io, addr: net.IpAddress) Identity {
    if (isLoopback(addr)) return .{ .user = null, .machine = "", .source = .local };

    const ip_text = formatBareIp(alloc, addr) catch
        return .{ .user = null, .machine = "peer", .source = .ip };
    const now_sec = std.Io.Clock.now(.real, io).toSeconds();

    if (cacheGet(io, ip_text, now_sec)) |cached| return dupeIdentity(alloc, cached);

    const resolved: Identity = blk: {
        const run = std.process.run(alloc, io, .{
            .argv = &.{ "tailscale", "whois", "--json", ip_text },
            .stdout_limit = .limited(whois_bytes_max),
            .stderr_limit = .limited(4096),
        }) catch break :blk .{ .user = null, .machine = ip_text, .source = .ip };
        switch (run.term) {
            .exited => |code| if (code != 0) break :blk .{ .user = null, .machine = ip_text, .source = .ip },
            else => break :blk .{ .user = null, .machine = ip_text, .source = .ip },
        }
        const parsed = parseWhois(alloc, run.stdout) catch null;
        break :blk parsed orelse .{ .user = null, .machine = ip_text, .source = .ip };
    };

    cachePut(io, ip_text, resolved, now_sec);
    return resolved;
}

fn dupeIdentity(alloc: std.mem.Allocator, id: Identity) Identity {
    // Cache entries can be freed by a cap-triggered clear on another
    // thread once the mutex is released, so callers get their own copy;
    // on allocation failure attribution degrades rather than failing the
    // mutation that asked for it.
    return .{
        .user = if (id.user) |u| alloc.dupe(u8, u) catch null else null,
        .machine = alloc.dupe(u8, id.machine) catch "peer",
        .source = id.source,
    };
}

const t = std.testing;

test "parseWhois reads the login and the computed node name" {
    const sample =
        \\{"Node":{"ID":1,"Name":"laptop.example.ts.net.","ComputedName":"laptop"},
        \\ "UserProfile":{"ID":2,"LoginName":"alice@example.com","DisplayName":"Alice"}}
    ;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const id = (try parseWhois(arena.allocator(), sample)).?;
    try t.expectEqualStrings("alice@example.com", id.user.?);
    try t.expectEqualStrings("laptop", id.machine);
    try t.expectEqual(Source.tailscale, id.source);
}

test "parseWhois falls back to the dns name and handles tagged nodes" {
    // Tagged (userless) nodes have no UserProfile; older outputs may lack
    // ComputedName, whose fallback is the FQDN trimmed at the first dot.
    const sample =
        \\{"Node":{"Name":"builder.example.ts.net."}}
    ;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const id = (try parseWhois(arena.allocator(), sample)).?;
    try t.expectEqual(@as(?[]const u8, null), id.user);
    try t.expectEqualStrings("builder", id.machine);
}

test "parseWhois of garbage or an empty peer is null, not an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(@as(?Identity, null), try parseWhois(arena.allocator(), "not json at all"));
    try t.expectEqual(@as(?Identity, null), try parseWhois(arena.allocator(), "{}"));
}

test "formatBareIp strips ports and brackets from both families" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v4 = try net.IpAddress.parseIp4("100.64.1.2", 8789);
    try t.expectEqualStrings("100.64.1.2", try formatBareIp(a, v4));
    const v6 = try net.IpAddress.parseIp6("fd7a:115c:a1e0::1", 8789);
    try t.expectEqualStrings("fd7a:115c:a1e0::1", try formatBareIp(a, v6));
}

test "isLoopback covers v4, v6, unspecified, and v4-mapped forms" {
    try t.expect(isLoopback(try net.IpAddress.parseIp4("127.0.0.1", 1)));
    try t.expect(isLoopback(try net.IpAddress.parseIp4("127.8.9.1", 1)));
    try t.expect(isLoopback(try net.IpAddress.parseIp4("0.0.0.0", 1)));
    try t.expect(isLoopback(try net.IpAddress.parseIp6("::1", 1)));
    try t.expect(isLoopback(try net.IpAddress.parseIp6("::", 1)));
    try t.expect(isLoopback(try net.IpAddress.parseIp6("::ffff:127.0.0.1", 1)));
    // Negative space: tailnet and LAN peers are not local.
    try t.expect(!isLoopback(try net.IpAddress.parseIp4("100.64.1.2", 1)));
    try t.expect(!isLoopback(try net.IpAddress.parseIp6("fd7a:115c:a1e0::1", 1)));
    try t.expect(!isLoopback(try net.IpAddress.parseIp6("::ffff:10.0.0.1", 1)));
}

test "gitAuthor formats attribution and leaves local commits alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(?[]u8, null), try gitAuthor(a, .{ .user = null, .machine = "", .source = .local }));
    try t.expectEqualStrings(
        "alice@example.com via laptop <alice@example.com>",
        (try gitAuthor(a, .{ .user = "alice@example.com", .machine = "laptop", .source = .tailscale })).?,
    );
    // A non-email login gets a neutral synthetic domain.
    try t.expectEqualStrings(
        "alice via laptop <alice@remote>",
        (try gitAuthor(a, .{ .user = "alice", .machine = "laptop", .source = .tailscale })).?,
    );
    // Tagged nodes and bare-ip peers still get attributed.
    try t.expectEqualStrings(
        "unknown via builder <unknown@remote>",
        (try gitAuthor(a, .{ .user = null, .machine = "builder", .source = .tailscale })).?,
    );
    try t.expectEqualStrings(
        "unknown via 192.0.2.7 <unknown@remote>",
        (try gitAuthor(a, .{ .user = null, .machine = "192.0.2.7", .source = .ip })).?,
    );
}

test "label reads naturally and cannot grow extra TSV columns" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("local", try label(a, .{ .user = null, .machine = "", .source = .local }));
    try t.expectEqualStrings(
        "alice@example.com from laptop",
        try label(a, .{ .user = "alice@example.com", .machine = "laptop", .source = .tailscale }),
    );
    try t.expectEqualStrings("192.0.2.7", try label(a, .{ .user = null, .machine = "192.0.2.7", .source = .ip }));
    // Whois output crosses a process boundary; a hostile node name must
    // not be able to inject tabs or newlines into shares.log.
    try t.expectEqualStrings(
        "evil from a b c",
        try label(a, .{ .user = "evil", .machine = "a\tb\nc", .source = .tailscale }),
    );
}

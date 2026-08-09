//! The MCP (Model Context Protocol) endpoint behind POST /mcp: remote
//! authoring for any agent on the network the server trusts. Speaks the
//! stateless streamable-HTTP profile: every POST is a complete JSON-RPC
//! exchange answered with plain application/json, no sessions (no
//! Mcp-Session-Id is ever issued), no server-initiated stream. All
//! framing lives here behind a socket-free `handle` so the whole
//! endpoint is testable without a connection.

const std = @import("std");
const net = std.Io.net;
const identity = @import("identity.zig");

/// What serve.handleMcp should put on the wire; the split keeps HTTP
/// status decisions here with the framing that mandates them.
pub const HandleResult = union(enum) {
    /// A complete JSON-RPC response body: HTTP 200 application/json.
    json: []u8,
    /// A notification (or a stray response object): HTTP 202, no body.
    accepted,
    /// Not JSON at all: HTTP 400 with this JSON-RPC error body.
    parse_error: []u8,
};

/// Handles one raw /mcp request body. Never errors: allocation failure
/// degrades to dropping the connection (null-ish accepted), the same
/// posture as the rest of the server.
pub fn handle(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    peer: net.IpAddress,
    body: []const u8,
) HandleResult {
    _ = io;
    _ = root;
    _ = peer;
    _ = body;
    // Stub until the framing lands: everything is method-not-found, so
    // the route plumbing is exercisable end to end.
    const payload = alloc.dupe(
        u8,
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}",
    ) catch return .accepted;
    return .{ .json = payload };
}

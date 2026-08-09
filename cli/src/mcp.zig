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
const json = @import("json.zig");

/// Protocol revisions this endpoint knows how to speak. `initialize`
/// echoes a requested version from this set and otherwise answers with
/// the newest one, the spec's negotiation rule for stateless servers.
pub const supported_protocol_versions = [_][]const u8{ "2025-03-26", "2025-06-18" };
const protocol_version_latest = supported_protocol_versions[supported_protocol_versions.len - 1];

/// NOTE: the binary's one version string lives in main.zig; referencing
/// it lazily here is a file-level import cycle (main imports serve
/// imports mcp), which Zig resolves fine for a const.
const server_version = @import("main.zig").version;

/// The authoring contract, delivered to every connecting agent through
/// `initialize`. This is the skill's workflow restated for teammates who
/// arrive over the wire instead of through the local CLI.
const instructions_text =
    "This is an atelier document library served by its owner. Call " ++
    "get_brand_guidelines before authoring anything and follow it; its rules " ++
    "win over your defaults. Author complete HTML documents with " ++
    "write_document or new_from_template, and stamp every page you create " ++
    "with <meta name=\"atelier:agent\" content=\"your-agent-name\"> plus " ++
    "<meta name=\"atelier:client\" content=\"...\"> when the work is for a " ++
    "specific client. Run check_document and fix every error before calling " ++
    "the work done; treat warnings as brand drift to justify or fix. Pass " ++
    "commit_message on writes (say why, one line, no trailers) so the " ++
    "library's git history stays an audit trail; your identity on this " ++
    "network is recorded automatically. Export with share_document when a " ++
    "document leaves the team; the PDF lands under /shares/ on this server. " ++
    "Pages are served on this host at their library path with .html " ++
    "dropped. The ledger reindexes itself within about a second of any " ++
    "write; call reindex only when the owner runs the server without live " ++
    "reload. Never try to start or stop the server; the owner runs it.";

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

/// One tool the endpoint offers. `input_schema` is a complete JSON
/// Schema literal; the table is comptime so tools/list is a constant.
const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

/// The tool registry; each authoring commit extends it together with the
/// dispatch arm in `callTool`.
const tool_defs = [_]ToolDef{};

/// The constant tools/list result, assembled at comptime from the table.
const tools_list_json = blk: {
    var out: []const u8 = "{\"tools\":[";
    for (tool_defs, 0..) |def, i| {
        if (i > 0) out = out ++ ",";
        out = out ++ "{\"name\":\"" ++ def.name ++ "\",\"description\":\"" ++
            def.description ++ "\",\"inputSchema\":" ++ def.input_schema ++ "}";
    }
    break :blk out ++ "]}";
};

/// Everything a tool handler needs; one struct so signatures stay put
/// while the tool set grows.
const ToolContext = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    peer: net.IpAddress,
    arguments: std.json.ObjectMap,
};

/// Handles one raw /mcp request body. Never errors: allocation failure
/// degrades to dropping the connection with a bare 202, the same
/// swallow-and-close posture as the rest of the server.
pub fn handle(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    peer: net.IpAddress,
    body: []const u8,
) HandleResult {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        const payload = errorBody(alloc, .null, -32700, "parse error") catch return .accepted;
        return .{ .parse_error = payload };
    };
    const value = parsed.value;
    if (value == .array) return asJson(errorBody(alloc, .null, -32600, "batching not supported"));
    if (value != .object) return asJson(errorBody(alloc, .null, -32600, "invalid request"));
    const request = value.object;

    const method_value = request.get("method") orelse {
        // An object without a method is either a stray client response
        // (result or error), which the spec says to swallow with a 202,
        // or plain nonsense.
        if (request.get("result") != null or request.get("error") != null) return .accepted;
        return asJson(errorBody(alloc, request.get("id") orelse .null, -32600, "invalid request"));
    };
    if (method_value != .string) {
        return asJson(errorBody(alloc, request.get("id") orelse .null, -32600, "invalid request"));
    }
    const method = method_value.string;

    // Notifications carry no id and get no body, whatever the method;
    // erroring a notification is a spec violation.
    const id: std.json.Value = request.get("id") orelse return .accepted;

    if (std.mem.eql(u8, method, "initialize")) return asJson(initializeBody(alloc, id, request));
    if (std.mem.eql(u8, method, "ping")) return asJson(resultBody(alloc, id, "{}"));
    if (std.mem.eql(u8, method, "tools/list")) return asJson(resultBody(alloc, id, tools_list_json));
    if (std.mem.eql(u8, method, "tools/call")) {
        return callTool(alloc, io, root, peer, id, request);
    }
    return asJson(errorBody(alloc, id, -32601, "method not found"));
}

/// Wraps a builder's outcome for `handle`; a failed allocation becomes
/// the bare 202 drop.
fn asJson(payload: anyerror![]u8) HandleResult {
    const bytes = payload catch return .accepted;
    return .{ .json = bytes };
}

/// Dispatches tools/call to the named tool. Protocol-shaped failures
/// (missing or unknown name, non-object arguments) are JSON-RPC errors;
/// tool execution failures are `isError` results, per MCP semantics.
fn callTool(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    peer: net.IpAddress,
    id: std.json.Value,
    request: std.json.ObjectMap,
) HandleResult {
    _ = io;
    _ = root;
    _ = peer;
    const params_value = request.get("params") orelse {
        return asJson(errorBody(alloc, id, -32602, "params.name is required"));
    };
    if (params_value != .object) return asJson(errorBody(alloc, id, -32602, "params must be an object"));
    const name_value = params_value.object.get("name") orelse {
        return asJson(errorBody(alloc, id, -32602, "params.name is required"));
    };
    if (name_value != .string) return asJson(errorBody(alloc, id, -32602, "params.name is required"));
    return asJson(errorBody(alloc, id, -32602, "unknown tool"));
}

/// The initialize result: negotiated protocol version, tools-only
/// capabilities, server identity, and the authoring contract.
fn initializeBody(alloc: std.mem.Allocator, id: std.json.Value, request: std.json.ObjectMap) ![]u8 {
    const requested = blk: {
        const params = request.get("params") orelse break :blk "";
        if (params != .object) break :blk "";
        const version_value = params.object.get("protocolVersion") orelse break :blk "";
        if (version_value != .string) break :blk "";
        break :blk version_value.string;
    };
    const negotiated = blk: {
        for (supported_protocol_versions) |known| {
            if (std.mem.eql(u8, requested, known)) break :blk known;
        }
        break :blk protocol_version_latest;
    };

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    try result.appendSlice(alloc, "{\"protocolVersion\":\"");
    try result.appendSlice(alloc, negotiated);
    try result.appendSlice(alloc, "\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"atelier\",\"version\":\"");
    try result.appendSlice(alloc, server_version);
    try result.appendSlice(alloc, "\"},\"instructions\":");
    try json.appendString(&result, alloc, instructions_text);
    try result.appendSlice(alloc, "}");
    const owned = try result.toOwnedSlice(alloc);
    defer alloc.free(owned);
    return resultBody(alloc, id, owned);
}

/// A complete success envelope around an already-serialized result value.
fn resultBody(alloc: std.mem.Allocator, id: std.json.Value, result_json: []const u8) ![]u8 {
    std.debug.assert(result_json.len >= 2); // at least {} or []
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdValue(&out, alloc, id);
    try out.appendSlice(alloc, ",\"result\":");
    try out.appendSlice(alloc, result_json);
    try out.appendSlice(alloc, "}");
    return out.toOwnedSlice(alloc);
}

/// A complete error envelope.
fn errorBody(alloc: std.mem.Allocator, id: std.json.Value, code: i64, message: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdValue(&out, alloc, id);
    const middle = try std.fmt.allocPrint(alloc, ",\"error\":{{\"code\":{d},\"message\":", .{code});
    defer alloc.free(middle);
    try out.appendSlice(alloc, middle);
    try json.appendString(&out, alloc, message);
    try out.appendSlice(alloc, "}}");
    return out.toOwnedSlice(alloc);
}

/// Echoes a request id: integers and strings verbatim, anything else
/// (including a missing id, which callers never pass here for requests)
/// as null. Floats are legal JSON-RPC ids but no real client sends one;
/// flattening them to null beats emitting a lossy round-trip.
fn appendIdValue(out: *std.ArrayList(u8), alloc: std.mem.Allocator, id: std.json.Value) !void {
    switch (id) {
        .integer => |n| {
            const printed = try std.fmt.allocPrint(alloc, "{d}", .{n});
            defer alloc.free(printed);
            try out.appendSlice(alloc, printed);
        },
        .string => |s| try json.appendString(out, alloc, s),
        else => try out.appendSlice(alloc, "null"),
    }
}

const t = std.testing;

/// Runs `handle` against a loopback peer with a throwaway root; framing
/// never touches the filesystem, so "/" is a fine stand-in.
fn call(alloc: std.mem.Allocator, body: []const u8) HandleResult {
    const loopback = net.IpAddress.parseIp4("127.0.0.1", 1) catch unreachable;
    return handle(alloc, t.io, "/", loopback, body);
}

test "handle answers garbage with a parse error and null id" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const result = call(arena.allocator(), "not json at all");
    try t.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"parse error\"}}",
        result.parse_error,
    );
}

test "handle rejects batches and non-objects as invalid requests" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const batch = call(arena.allocator(), "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]");
    try t.expect(std.mem.indexOf(u8, batch.json, "-32600") != null);
    const scalar = call(arena.allocator(), "\"ping\"");
    try t.expect(std.mem.indexOf(u8, scalar.json, "-32600") != null);
    const methodless = call(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":7}");
    try t.expect(std.mem.indexOf(u8, methodless.json, "-32600") != null);
    try t.expect(std.mem.indexOf(u8, methodless.json, "\"id\":7") != null);
}

test "handle accepts notifications with no body, even unknown ones" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expect(call(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") == .accepted);
    try t.expect(call(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\"}") == .accepted);
    try t.expect(call(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"method\":\"nobody/knows/this\"}") == .accepted);
}

test "handle echoes integer and string ids verbatim" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const int_id = call(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"ping\"}");
    try t.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{}}", int_id.json);
    const string_id = call(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":\"a-1\",\"method\":\"ping\"}");
    try t.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"a-1\",\"result\":{}}", string_id.json);
}

test "handle answers unknown methods with method-not-found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const result = call(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/list\"}");
    try t.expect(std.mem.indexOf(u8, result.json, "-32601") != null);
}

test "initialize negotiates the protocol version and carries the contract" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const known = call(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"," ++
        "\"params\":{\"protocolVersion\":\"2025-03-26\"}}");
    const known_parsed = try std.json.parseFromSlice(std.json.Value, a, known.json, .{});
    const known_result = known_parsed.value.object.get("result").?.object;
    try t.expectEqualStrings("2025-03-26", known_result.get("protocolVersion").?.string);

    const unknown = call(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"," ++
        "\"params\":{\"protocolVersion\":\"1999-01-01\"}}");
    const unknown_parsed = try std.json.parseFromSlice(std.json.Value, a, unknown.json, .{});
    const unknown_result = unknown_parsed.value.object.get("result").?.object;
    try t.expectEqualStrings("2025-06-18", unknown_result.get("protocolVersion").?.string);

    try t.expect(unknown_result.get("capabilities").?.object.get("tools") != null);
    try t.expectEqualStrings("atelier", unknown_result.get("serverInfo").?.object.get("name").?.string);
    const instructions = unknown_result.get("instructions").?.string;
    try t.expect(instructions.len > 0);
    try t.expect(std.mem.indexOf(u8, instructions, "get_brand_guidelines") != null);
    // House prose rule holds even over the wire.
    try t.expect(std.mem.indexOf(u8, instructions, "\u{2014}") == null);
}

test "tools/list answers with a tools array" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = call(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}");
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.json, .{});
    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    for (tools.items) |tool| {
        try t.expect(tool.object.get("name") != null);
        try t.expectEqualStrings("object", tool.object.get("inputSchema").?.object.get("type").?.string);
    }
}

test "tools/call without params or name is invalid params, not a crash" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const no_params = call(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\"}");
    try t.expect(std.mem.indexOf(u8, no_params.json, "-32602") != null);
    const no_name = call(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{}}");
    try t.expect(std.mem.indexOf(u8, no_name.json, "-32602") != null);
    const bad_params = call(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":3}");
    try t.expect(std.mem.indexOf(u8, bad_params.json, "-32602") != null);
}

test "tools/call on an unknown tool is invalid params, not a crash" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const result = call(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"no_such_tool\",\"arguments\":{}}}");
    try t.expect(std.mem.indexOf(u8, result.json, "-32602") != null);
}

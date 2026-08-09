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
const library = @import("library.zig");
const index = @import("index.zig");
const check = @import("check.zig");
const template = @import("template.zig");

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

/// Upper bound on one document read or written over this endpoint,
/// matching the CLI's page-read cap and serve's /mcp body cap.
pub const document_bytes_max = 4 * 1024 * 1024;

/// What one tool invocation produced: text for the agent, and whether it
/// is reporting a failure (MCP's isError, distinct from protocol errors).
const ToolResult = struct {
    text: []const u8,
    is_error: bool = false,
};

/// One tool the endpoint offers. `input_schema` is a complete JSON
/// Schema literal; the table is comptime so tools/list is a constant.
const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    handler: *const fn (ctx: *const ToolContext) anyerror!ToolResult,
};

/// The tool registry; each authoring commit extends it together with a
/// handler below.
const tool_defs = [_]ToolDef{
    .{
        .name = "get_brand_guidelines",
        .description = "The library's brand guidelines; read and follow them before authoring anything.",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        .handler = toolGetBrandGuidelines,
    },
    .{
        .name = "list_documents",
        .description = "Every document in the library: path, title, section, served url, kind, mtime, revision count, and atelier meta.",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        .handler = toolListDocuments,
    },
    .{
        .name = "read_document",
        .description = "A document's source. Text files only; PDFs and images say where to fetch them instead.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"," ++
            "\"description\":\"library-relative, e.g. advisory/one; .html is appended when the last segment has no extension\"}}," ++
            "\"required\":[\"path\"]}",
        .handler = toolReadDocument,
    },
    .{
        .name = "check_document",
        .description = "Lint one page (or the whole library when path is omitted): title, agent stamp, broken internal refs, brand drift. Fix every error before calling work done.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"," ++
            "\"description\":\"one page to check; omit to check every page\"}}}",
        .handler = toolCheckDocument,
    },
    .{
        .name = "list_templates",
        .description = "The library's templates and each one's placeholders, for new_from_template.",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        .handler = toolListTemplates,
    },
};

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
    const params_value = request.get("params") orelse {
        return asJson(errorBody(alloc, id, -32602, "params.name is required"));
    };
    if (params_value != .object) return asJson(errorBody(alloc, id, -32602, "params must be an object"));
    const name_value = params_value.object.get("name") orelse {
        return asJson(errorBody(alloc, id, -32602, "params.name is required"));
    };
    if (name_value != .string) return asJson(errorBody(alloc, id, -32602, "params.name is required"));

    const empty_arguments: std.json.ObjectMap = .empty;
    const arguments = blk: {
        const v = params_value.object.get("arguments") orelse break :blk empty_arguments;
        if (v != .object) break :blk empty_arguments;
        break :blk v.object;
    };

    inline for (tool_defs) |def| {
        if (std.mem.eql(u8, name_value.string, def.name)) {
            const ctx: ToolContext = .{
                .alloc = alloc,
                .io = io,
                .root = root,
                .peer = peer,
                .arguments = arguments,
            };
            const outcome = def.handler(&ctx) catch {
                return asJson(errorBody(alloc, id, -32603, "internal error"));
            };
            const envelope = toolEnvelope(alloc, outcome) catch return .accepted;
            return asJson(resultBody(alloc, id, envelope));
        }
    }
    return asJson(errorBody(alloc, id, -32602, "unknown tool"));
}

/// Wraps a tool outcome in MCP's content envelope.
fn toolEnvelope(alloc: std.mem.Allocator, outcome: ToolResult) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"content\":[{\"type\":\"text\",\"text\":");
    try json.appendString(&out, alloc, outcome.text);
    try out.appendSlice(alloc, if (outcome.is_error) "}],\"isError\":true}" else "}],\"isError\":false}");
    return out.toOwnedSlice(alloc);
}

/// Formats a one-line lowercase tool failure, the same voice as the
/// CLI's own error messages.
fn toolError(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ToolResult {
    return .{ .text = try std.fmt.allocPrint(alloc, fmt, args), .is_error = true };
}

/// A string argument by name, or null when absent or not a string.
fn argString(arguments: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = arguments.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

/// A library-relative path acceptable to this endpoint: bounded, no
/// absolute or traversal forms, no dot segments (dot names are tool
/// state and .git lives behind one), no control bytes, no backslashes.
/// The shape itself confines the path, the same philosophy as
/// theme.isThemeName; nothing here touches the filesystem.
pub fn isSafeRelPath(rel: []const u8) bool {
    if (rel.len == 0 or rel.len > 512) return false;
    for (rel) |c| {
        if (c < 0x20 or c == 0x7f) return false;
        if (c == '\\') return false;
    }
    if (rel[0] == '/') return false;
    var segments = std.mem.splitScalar(u8, rel, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (segment[0] == '.') return false;
    }
    return true;
}

/// serve's clean-URL rule for tool arguments: a last segment with no
/// extension names an .html page.
fn cleanRel(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const last = std.fs.path.basename(raw);
    if (std.mem.indexOfScalar(u8, last, '.') != null) return alloc.dupe(u8, raw);
    return std.fmt.allocPrint(alloc, "{s}.html", .{raw});
}

/// Extensions read_document will inline; everything else is served
/// bytes, not JSON-string material.
fn isTextExtension(rel: []const u8) bool {
    const text_extensions = [_][]const u8{ ".html", ".md", ".css", ".js", ".json", ".svg", ".txt" };
    const ext = std.fs.path.extension(rel);
    for (text_extensions) |known| {
        if (std.mem.eql(u8, ext, known)) return true;
    }
    return false;
}

/// Re-resolves the library from disk, the same per-request pattern as
/// serve's theme data and index regeneration: manifest and theme edits
/// take effect without a restart.
fn resolveLib(ctx: *const ToolContext) !library.Library {
    return library.resolve(ctx.alloc, ctx.io, .{
        .explicit = ctx.root,
        .start_dir = "/",
        .config_path = "/nonexistent",
    });
}

fn toolGetBrandGuidelines(ctx: *const ToolContext) anyerror!ToolResult {
    const abs = try std.fs.path.join(ctx.alloc, &.{ ctx.root, "brand-guidelines.md" });
    const content = std.Io.Dir.cwd().readFileAlloc(ctx.io, abs, ctx.alloc, .limited(document_bytes_max)) catch {
        return toolError(ctx.alloc, "no brand-guidelines.md in this library; author in a restrained, neutral style", .{});
    };
    return .{ .text = content };
}

fn toolReadDocument(ctx: *const ToolContext) anyerror!ToolResult {
    const raw = argString(ctx.arguments, "path") orelse return toolError(ctx.alloc, "path is required", .{});
    const rel = try cleanRel(ctx.alloc, raw);
    if (!isSafeRelPath(rel)) return toolError(ctx.alloc, "bad path: {s}", .{raw});
    if (!isTextExtension(rel)) {
        return toolError(ctx.alloc, "binary file; fetch /{s} from this server over http instead", .{rel});
    }
    const abs = try std.fs.path.join(ctx.alloc, &.{ ctx.root, rel });
    const content = std.Io.Dir.cwd().readFileAlloc(ctx.io, abs, ctx.alloc, .limited(document_bytes_max)) catch {
        return toolError(ctx.alloc, "no document at {s}", .{rel});
    };
    return .{ .text = content };
}

fn toolListDocuments(ctx: *const ToolContext) anyerror!ToolResult {
    const lib = try resolveLib(ctx);
    const items = try index.collectItems(ctx.alloc, ctx.io, lib);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.alloc);
    try out.append(ctx.alloc, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.append(ctx.alloc, ',');
        std.debug.assert(item.path.len > 1);
        std.debug.assert(item.path[0] == '/');
        const rel = item.path[1..];
        try out.appendSlice(ctx.alloc, "{\"path\":");
        try json.appendString(&out, ctx.alloc, rel);
        try out.appendSlice(ctx.alloc, ",\"title\":");
        try json.appendString(&out, ctx.alloc, item.label);
        try out.appendSlice(ctx.alloc, ",\"section\":");
        try json.appendString(&out, ctx.alloc, item.section);
        try out.appendSlice(ctx.alloc, ",\"kind\":");
        try json.appendString(&out, ctx.alloc, item.kind);
        try out.appendSlice(ctx.alloc, ",\"url\":");
        const url = if (std.mem.endsWith(u8, item.path, ".html"))
            item.path[0 .. item.path.len - ".html".len]
        else
            item.path;
        try json.appendString(&out, ctx.alloc, url);
        const numbers = try std.fmt.allocPrint(ctx.alloc, ",\"mtime\":{d},\"revs\":{d},\"meta\":{{", .{
            item.mtime_sec,
            item.revs,
        });
        try out.appendSlice(ctx.alloc, numbers);
        for (item.meta, 0..) |meta, j| {
            if (j > 0) try out.append(ctx.alloc, ',');
            try json.appendString(&out, ctx.alloc, meta.key);
            try out.append(ctx.alloc, ':');
            try json.appendString(&out, ctx.alloc, meta.value);
        }
        try out.appendSlice(ctx.alloc, "}}");
    }
    try out.append(ctx.alloc, ']');
    return .{ .text = try out.toOwnedSlice(ctx.alloc) };
}

fn toolCheckDocument(ctx: *const ToolContext) anyerror!ToolResult {
    const lib = try resolveLib(ctx);
    var rels: std.ArrayList([]const u8) = .empty;
    if (argString(ctx.arguments, "path")) |raw| {
        const rel = try cleanRel(ctx.alloc, raw);
        if (!isSafeRelPath(rel)) return toolError(ctx.alloc, "bad path: {s}", .{raw});
        try rels.append(ctx.alloc, rel);
    } else {
        const items = try index.collectItems(ctx.alloc, ctx.io, lib);
        for (items) |item| {
            if (!std.mem.eql(u8, item.kind, "page")) continue;
            try rels.append(ctx.alloc, item.path[1..]);
        }
    }

    var findings_json: std.ArrayList(u8) = .empty;
    var errors: usize = 0;
    var warnings: usize = 0;
    for (rels.items) |rel| {
        const abs = try std.fs.path.join(ctx.alloc, &.{ lib.root, rel });
        const html = std.Io.Dir.cwd().readFileAlloc(ctx.io, abs, ctx.alloc, .limited(document_bytes_max)) catch {
            return toolError(ctx.alloc, "no page at {s}", .{rel});
        };
        const findings = try check.checkPage(ctx.alloc, ctx.io, lib, rel, html);
        for (findings) |finding| {
            if (findings_json.items.len > 0) try findings_json.append(ctx.alloc, ',');
            switch (finding.severity) {
                .err => errors += 1,
                .warn => warnings += 1,
            }
            try findings_json.appendSlice(ctx.alloc, "{\"path\":");
            try json.appendString(&findings_json, ctx.alloc, rel);
            try findings_json.appendSlice(ctx.alloc, ",\"severity\":");
            try findings_json.appendSlice(ctx.alloc, switch (finding.severity) {
                .err => "\"error\"",
                .warn => "\"warning\"",
            });
            try findings_json.appendSlice(ctx.alloc, ",\"message\":");
            try json.appendString(&findings_json, ctx.alloc, finding.message);
            try findings_json.append(ctx.alloc, '}');
        }
    }
    const text = try std.fmt.allocPrint(ctx.alloc, "{{\"pages\":{d},\"errors\":{d},\"warnings\":{d},\"findings\":[{s}]}}", .{
        rels.items.len,
        errors,
        warnings,
        findings_json.items,
    });
    return .{ .text = text };
}

fn toolListTemplates(ctx: *const ToolContext) anyerror!ToolResult {
    const templates_abs = try std.fs.path.join(ctx.alloc, &.{ ctx.root, "templates" });
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.alloc);
    try out.append(ctx.alloc, '[');
    if (std.Io.Dir.openDirAbsolute(ctx.io, templates_abs, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(ctx.io);
        var empty_vars = std.StringHashMap([]const u8).init(ctx.alloc);
        defer empty_vars.deinit();
        var listed: usize = 0;
        var entries = dir.iterate();
        while (entries.next(ctx.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".html")) continue;
            const source = dir.readFileAlloc(ctx.io, entry.name, ctx.alloc, .limited(document_bytes_max)) catch continue;
            const filled = try template.fill(ctx.alloc, source, &empty_vars);
            if (listed > 0) try out.append(ctx.alloc, ',');
            listed += 1;
            try out.appendSlice(ctx.alloc, "{\"name\":");
            try json.appendString(&out, ctx.alloc, entry.name[0 .. entry.name.len - ".html".len]);
            try out.appendSlice(ctx.alloc, ",\"placeholders\":[");
            for (filled.unfilled, 0..) |placeholder, i| {
                if (i > 0) try out.append(ctx.alloc, ',');
                try json.appendString(&out, ctx.alloc, placeholder);
            }
            try out.appendSlice(ctx.alloc, "]}");
        }
    } else |_| {} // no templates directory is an empty list, not a failure
    try out.append(ctx.alloc, ']');
    return .{ .text = try out.toOwnedSlice(ctx.alloc) };
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

/// Like `call` but against a real library root.
fn callAt(alloc: std.mem.Allocator, root: []const u8, body: []const u8) HandleResult {
    const loopback = net.IpAddress.parseIp4("127.0.0.1", 1) catch unreachable;
    return handle(alloc, t.io, root, loopback, body);
}

const ToolOutcome = struct { text: []const u8, is_error: bool };

/// Unwraps a tools/call response down to its text content and isError.
fn toolOutcome(alloc: std.mem.Allocator, result: HandleResult) !ToolOutcome {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.json, .{});
    const r = parsed.value.object.get("result").?.object;
    return .{
        .text = r.get("content").?.array.items[0].object.get("text").?.string,
        .is_error = r.get("isError").?.bool,
    };
}

test "isSafeRelPath admits page paths and rejects the negative space" {
    const good = [_][]const u8{
        "memo.html",           "advisory/one.html", "a/b/c.css", "notes.md",
        "templates/memo.html", "logo.svg",
    };
    for (good) |p| try t.expect(isSafeRelPath(p));
    const bad = [_][]const u8{
        "",            "/abs.html", "..",           "../x.html",
        "a/../b.html", "a\\b.html", ".hidden.html", "a/.hidden.html",
        ".git/config", "a//b.html", "a/./b.html",   "x\x00y.html",
    };
    for (bad) |p| try t.expect(!isSafeRelPath(p));
    // Length fence: 512 bytes is the cap.
    const long: [513]u8 = @splat('a');
    try t.expect(!isSafeRelPath(&long));
}

test "get_brand_guidelines returns the canon or a clear absence" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });

    const absent = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"get_brand_guidelines\"}}"));
    try t.expect(absent.is_error);

    try tmp.dir.writeFile(t.io, .{ .sub_path = "brand-guidelines.md", .data = "# brand\nBe restrained." });
    const found = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"get_brand_guidelines\"}}"));
    try t.expect(!found.is_error);
    try t.expectEqualStrings("# brand\nBe restrained.", found.text);
}

test "read_document round-trips pages and fences the rest" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.createDirPath(t.io, "advisory");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "advisory/one.html", .data = "<title>One</title>" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "deck.pdf", .data = "%PDF" });

    // Clean-URL rule: an extensionless path reads the .html page.
    const page = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"read_document\",\"arguments\":{\"path\":\"advisory/one\"}}}"));
    try t.expect(!page.is_error);
    try t.expectEqualStrings("<title>One</title>", page.text);

    const binary = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"read_document\",\"arguments\":{\"path\":\"deck.pdf\"}}}"));
    try t.expect(binary.is_error);
    try t.expect(std.mem.indexOf(u8, binary.text, "/deck.pdf") != null);

    const traversal = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"read_document\",\"arguments\":{\"path\":\"../escape\"}}}"));
    try t.expect(traversal.is_error);

    const missing = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"read_document\",\"arguments\":{\"path\":\"ghost\"}}}"));
    try t.expect(missing.is_error);
}

test "list_documents reports paths, titles, and served urls" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.createDirPath(t.io, "advisory");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "advisory/one.html", .data = "<title>One Pager</title>" });

    const outcome = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"list_documents\"}}"));
    try t.expect(!outcome.is_error);
    const docs = try std.json.parseFromSlice(std.json.Value, a, outcome.text, .{});
    const first = docs.value.array.items[0].object;
    try t.expectEqualStrings("advisory/one.html", first.get("path").?.string);
    try t.expectEqualStrings("One Pager", first.get("title").?.string);
    try t.expectEqualStrings("/advisory/one", first.get("url").?.string);
    try t.expectEqualStrings("advisory", first.get("section").?.string);
    try t.expectEqualStrings("page", first.get("kind").?.string);
}

test "check_document reports structured findings without failing the call" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bare.html", .data = "<html><body>hi</body></html>" });

    const outcome = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"check_document\",\"arguments\":{\"path\":\"bare\"}}}"));
    try t.expect(!outcome.is_error);
    const report = try std.json.parseFromSlice(std.json.Value, a, outcome.text, .{});
    const summary = report.value.object;
    try t.expectEqual(@as(i64, 1), summary.get("pages").?.integer);
    try t.expect(summary.get("errors").?.integer > 0);
    const findings = summary.get("findings").?.array;
    try t.expect(findings.items.len > 0);
    try t.expectEqualStrings("bare.html", findings.items[0].object.get("path").?.string);
    // The whole-library mode sees the same page.
    const all = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"check_document\"}}"));
    const all_report = try std.json.parseFromSlice(std.json.Value, a, all.text, .{});
    try t.expectEqual(@as(i64, 1), all_report.value.object.get("pages").?.integer);
}

test "list_templates names each master and its placeholders" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.createDirPath(t.io, "templates");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "templates/memo.html", .data = "{{BRAND_ACCENT}} {{CLIENT}}" });

    const outcome = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"list_templates\"}}"));
    try t.expect(!outcome.is_error);
    const templates = try std.json.parseFromSlice(std.json.Value, a, outcome.text, .{});
    const first = templates.value.array.items[0].object;
    try t.expectEqualStrings("memo", first.get("name").?.string);
    const placeholders = first.get("placeholders").?.array;
    try t.expectEqual(@as(usize, 2), placeholders.items.len);
    try t.expectEqualStrings("BRAND_ACCENT", placeholders.items[0].string);
    try t.expectEqualStrings("CLIENT", placeholders.items[1].string);
}

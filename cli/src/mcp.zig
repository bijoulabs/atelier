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
const history = @import("history.zig");
const share = @import("share.zig");
const pdf = @import("pdf.zig");

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

/// The one-liner that connects a Claude Code agent to this endpoint;
/// `atelier connect` and the serve banner both print it, so how to join
/// is a command away, not a docs hunt. Other agents use the same URL
/// with their own streamable-HTTP MCP syntax. Caller owns the result.
pub fn connectLine(alloc: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    std.debug.assert(host.len > 0);
    return std.fmt.allocPrint(
        alloc,
        "claude mcp add --transport http atelier http://{s}:{d}/mcp",
        .{ host, port },
    );
}

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
    .{
        .name = "write_document",
        .description = "Write a complete document into the library. Creates by default and refuses an existing path; pass overwrite to update. Pass commit_message so the change lands in the library's history under your identity.",
        .input_schema = "{\"type\":\"object\",\"properties\":{" ++
            "\"path\":{\"type\":\"string\",\"description\":\"library-relative destination, e.g. advisory/two; .html is appended when the last segment has no extension\"}," ++
            "\"content\":{\"type\":\"string\",\"description\":\"the complete file content\"}," ++
            "\"overwrite\":{\"type\":\"boolean\",\"default\":false}," ++
            "\"commit_message\":{\"type\":\"string\",\"description\":\"why, one line, no trailers; omit to leave the write uncommitted\"}}," ++
            "\"required\":[\"path\",\"content\"]}",
        .handler = toolWriteDocument,
    },
    .{
        .name = "new_from_template",
        .description = "Scaffold a new document from a library template. Brand tokens fill from the active theme; your vars win over them. Refuses to overwrite.",
        .input_schema = "{\"type\":\"object\",\"properties\":{" ++
            "\"template\":{\"type\":\"string\",\"description\":\"a name from list_templates\"}," ++
            "\"dest\":{\"type\":\"string\",\"description\":\"library-relative destination\"}," ++
            "\"vars\":{\"type\":\"object\",\"additionalProperties\":{\"type\":\"string\"},\"description\":\"placeholder values, e.g. {\\\"CLIENT\\\":\\\"Acme\\\"}\"}," ++
            "\"commit_message\":{\"type\":\"string\"}}," ++
            "\"required\":[\"template\",\"dest\"]}",
        .handler = toolNewFromTemplate,
    },
    .{
        .name = "reindex",
        .description = "Rebuild the library's index.html now. Normally unnecessary: the server reindexes within about a second of any write when live reload is on; this exists for servers running with reload off.",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        .handler = toolReindex,
    },
    .{
        .name = "share_document",
        .description = "Export a page as a provenance-stamped PDF for someone outside the team, and record the send in the share ledger. Prefer this over render_pdf for anything leaving the building.",
        .input_schema = "{\"type\":\"object\",\"properties\":{" ++
            "\"path\":{\"type\":\"string\",\"description\":\"the page to share\"}," ++
            "\"recipient\":{\"type\":\"string\",\"description\":\"who it is prepared for; letters, digits, spaces, dots, dashes\"}," ++
            "\"commit_message\":{\"type\":\"string\",\"description\":\"why; commits the PDF and the ledger entry\"}}," ++
            "\"required\":[\"path\"]}",
        .handler = toolShareDocument,
    },
    .{
        .name = "render_pdf",
        .description = "Render a page (optionally at a past commit sha) to an unstamped PDF under /shares/ on this server.",
        .input_schema = "{\"type\":\"object\",\"properties\":{" ++
            "\"path\":{\"type\":\"string\",\"description\":\"the page to render\"}," ++
            "\"rev\":{\"type\":\"string\",\"description\":\"a commit sha (7 to 40 hex digits) to render the page as it was then\"}}," ++
            "\"required\":[\"path\"]}",
        .handler = toolRenderPdf,
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

/// What write_document may target: a safe path whose extension is
/// authorable text, excluding everything the binary generates or owns a
/// validated write path for (the ledger, the manifest, the share ledger,
/// the owner-authored canon, the theme editor's directory, the export
/// directory). templates/ stays writable: masters are content and git
/// records who changed them.
pub fn isWritableRelPath(rel: []const u8) bool {
    if (!isSafeRelPath(rel)) return false;
    const writable_extensions = [_][]const u8{ ".html", ".css", ".js", ".svg", ".md", ".txt" };
    const ext = std.fs.path.extension(rel);
    const ext_ok = for (writable_extensions) |known| {
        if (std.mem.eql(u8, ext, known)) break true;
    } else false;
    if (!ext_ok) return false;
    const owned_files = [_][]const u8{ "index.html", "atelier.json", "shares.log", "brand-guidelines.md" };
    for (owned_files) |owned| {
        if (std.mem.eql(u8, rel, owned)) return false;
    }
    if (std.mem.startsWith(u8, rel, "themes/")) return false;
    if (std.mem.startsWith(u8, rel, "shares/")) return false;
    return true;
}

/// A boolean argument by name; absent or non-boolean is `fallback`.
fn argBool(arguments: std.json.ObjectMap, name: []const u8, fallback: bool) bool {
    const value = arguments.get(name) orelse return fallback;
    if (value != .bool) return fallback;
    return value.bool;
}

/// Resolves who is asking and runs the optional commit, returning the
/// attribution-and-commit tail every mutating tool ends its report with:
/// "as <label>; committed <sha>" or the reason there is no commit. Must
/// be called with library.write_mu held, so the commit cannot interleave
/// with a concurrent writer's staging.
fn attributeAndCommit(
    ctx: *const ToolContext,
    rel_paths: []const []const u8,
    commit_message: ?[]const u8,
) ![]u8 {
    const who = identity.resolve(ctx.alloc, ctx.io, ctx.peer);
    const who_label = identity.label(ctx.alloc, who) catch "unknown";
    const commit_note: []const u8 = blk: {
        const message = commit_message orelse break :blk "no commit requested";
        if (message.len == 0) break :blk "no commit requested";
        const author = identity.gitAuthor(ctx.alloc, who) catch null;
        const outcome = history.commitPaths(ctx.alloc, ctx.io, ctx.root, rel_paths, message, author);
        if (outcome.committed) break :blk try std.fmt.allocPrint(ctx.alloc, "committed {s}", .{outcome.sha});
        break :blk try std.fmt.allocPrint(ctx.alloc, "not committed: {s}", .{outcome.note});
    };
    return std.fmt.allocPrint(ctx.alloc, "as {s}; {s}", .{ who_label, commit_note });
}

/// The served URL for a library-relative path: clean for pages, verbatim
/// for everything else.
fn servedUrl(alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, rel, ".html")) {
        return std.fmt.allocPrint(alloc, "/{s}", .{rel[0 .. rel.len - ".html".len]});
    }
    return std.fmt.allocPrint(alloc, "/{s}", .{rel});
}

fn toolWriteDocument(ctx: *const ToolContext) anyerror!ToolResult {
    const raw = argString(ctx.arguments, "path") orelse return toolError(ctx.alloc, "path is required", .{});
    const content = argString(ctx.arguments, "content") orelse return toolError(ctx.alloc, "content is required", .{});
    const rel = try cleanRel(ctx.alloc, raw);
    if (!isWritableRelPath(rel)) {
        return toolError(ctx.alloc, "cannot write {s}: only .html/.css/.js/.svg/.md/.txt documents, and never index.html, atelier.json, shares.log, brand-guidelines.md, themes/, or shares/", .{rel});
    }
    const abs = try std.fs.path.join(ctx.alloc, &.{ ctx.root, rel });

    library.write_mu.lock(ctx.io) catch return toolError(ctx.alloc, "server shutting down", .{});
    defer library.write_mu.unlock(ctx.io);

    if (!argBool(ctx.arguments, "overwrite", false)) {
        if (std.Io.Dir.cwd().access(ctx.io, abs, .{})) |_| {
            return toolError(ctx.alloc, "refusing to overwrite {s}; pass overwrite true to update it", .{rel});
        } else |_| {} // no existing file to protect; the write surfaces real errors
    }
    if (std.fs.path.dirname(abs)) |parent| try std.Io.Dir.cwd().createDirPath(ctx.io, parent);
    try library.writeFileAtomic(ctx.io, ctx.alloc, abs, content);

    const tail = try attributeAndCommit(ctx, &.{rel}, argString(ctx.arguments, "commit_message"));
    const url = try servedUrl(ctx.alloc, rel);
    return .{ .text = try std.fmt.allocPrint(ctx.alloc, "wrote {s} (served at {s}) {s}", .{ rel, url, tail }) };
}

fn toolNewFromTemplate(ctx: *const ToolContext) anyerror!ToolResult {
    const template_name = argString(ctx.arguments, "template") orelse {
        return toolError(ctx.alloc, "template is required", .{});
    };
    const dest = argString(ctx.arguments, "dest") orelse return toolError(ctx.alloc, "dest is required", .{});
    const dest_rel = try cleanRel(ctx.alloc, dest);
    if (!isWritableRelPath(dest_rel)) return toolError(ctx.alloc, "cannot write {s}", .{dest_rel});

    var user_vars = std.StringHashMap([]const u8).init(ctx.alloc);
    defer user_vars.deinit();
    if (ctx.arguments.get("vars")) |vars_value| {
        if (vars_value == .object) {
            var entries = vars_value.object.iterator();
            while (entries.next()) |entry| {
                if (entry.value_ptr.* != .string) continue; // only strings substitute into a template
                try user_vars.put(entry.key_ptr.*, entry.value_ptr.*.string);
            }
        }
    }

    const lib = try resolveLib(ctx);
    library.write_mu.lock(ctx.io) catch return toolError(ctx.alloc, "server shutting down", .{});
    defer library.write_mu.unlock(ctx.io);

    var diag: template.ScaffoldDiag = .{};
    const scaffolded = template.scaffold(ctx.alloc, ctx.io, lib, template_name, dest, &user_vars, &diag) catch |e| switch (e) {
        error.TemplateNotFound => return toolError(ctx.alloc, "no template named {s}; list_templates shows what exists", .{template_name}),
        error.DestinationExists => return toolError(ctx.alloc, "refusing to overwrite {s}; write_document with overwrite true updates it", .{dest_rel}),
        else => return e,
    };

    const tail = try attributeAndCommit(ctx, &.{scaffolded.dest_rel}, argString(ctx.arguments, "commit_message"));
    const url = try servedUrl(ctx.alloc, scaffolded.dest_rel);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(ctx.alloc);
    const head = try std.fmt.allocPrint(ctx.alloc, "wrote {s} (served at {s}) {s}", .{ scaffolded.dest_rel, url, tail });
    try text.appendSlice(ctx.alloc, head);
    if (scaffolded.unfilled.len > 0) {
        try text.appendSlice(ctx.alloc, "; unfilled:");
        for (scaffolded.unfilled) |placeholder| {
            try text.append(ctx.alloc, ' ');
            try text.appendSlice(ctx.alloc, placeholder);
        }
    }
    return .{ .text = try text.toOwnedSlice(ctx.alloc) };
}

fn toolReindex(ctx: *const ToolContext) anyerror!ToolResult {
    const lib = try resolveLib(ctx);
    library.write_mu.lock(ctx.io) catch return toolError(ctx.alloc, "server shutting down", .{});
    defer library.write_mu.unlock(ctx.io);
    const page = try index.generate(ctx.alloc, ctx.io, lib);
    const dest = try std.fs.path.join(ctx.alloc, &.{ lib.root, "index.html" });
    try library.writeFileAtomic(ctx.io, ctx.alloc, dest, page);
    return .{ .text = "index.html rebuilt" };
}

/// What may name a share recipient: it lands in a filename and in the
/// stamped page, so the shape is fenced like paths are. Letters, digits,
/// spaces, dots, dashes, underscores; no leading dot; at most 64 bytes.
pub fn isSafeRecipient(recipient: []const u8) bool {
    if (recipient.len == 0 or recipient.len > 64) return false;
    if (recipient[0] == '.') return false;
    for (recipient) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', ' ', '.', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// Resolves a page argument shared by the export tools: clean-URL rule,
/// shape fence, must name an .html page.
fn pageRelArg(ctx: *const ToolContext) anyerror!union(enum) { rel: []u8, failed: ToolResult } {
    const raw = argString(ctx.arguments, "path") orelse {
        return .{ .failed = try toolError(ctx.alloc, "path is required", .{}) };
    };
    const rel = try cleanRel(ctx.alloc, raw);
    if (!isSafeRelPath(rel) or !std.mem.endsWith(u8, rel, ".html")) {
        return .{ .failed = try toolError(ctx.alloc, "bad page path: {s}", .{raw}) };
    }
    return .{ .rel = rel };
}

/// Maps a pdf.render failure to the tool-result voice the CLI uses.
fn renderFailure(ctx: *const ToolContext, e: anyerror, failure: ?pdf.Failure) anyerror!ToolResult {
    switch (e) {
        error.NoChromium => {
            return toolError(ctx.alloc, "install chromium (or google-chrome-stable) on the serve machine for pdf rendering", .{});
        },
        error.ChromiumFailed => {
            const f = failure.?;
            return toolError(ctx.alloc, "{s} failed with exit code {d}", .{ f.bin, f.code });
        },
        else => return e,
    }
}

fn toolShareDocument(ctx: *const ToolContext) anyerror!ToolResult {
    const rel = switch (try pageRelArg(ctx)) {
        .failed => |failed| return failed,
        .rel => |rel| rel,
    };
    const recipient = argString(ctx.arguments, "recipient");
    if (recipient) |who_for| {
        if (!isSafeRecipient(who_for)) {
            return toolError(ctx.alloc, "bad recipient: letters, digits, spaces, dots, dashes, underscores only", .{});
        }
    }

    const lib = try resolveLib(ctx);
    const stem = blk: {
        const base = std.fs.path.basename(rel);
        break :blk base[0 .. base.len - ".html".len];
    };
    const date = try share.isoDate(ctx.alloc, std.Io.Clock.now(.real, ctx.io).toSeconds());
    const out_name = if (recipient) |who_for|
        try std.fmt.allocPrint(ctx.alloc, "{s}-{s}-{s}.pdf", .{ stem, who_for, date })
    else
        try std.fmt.allocPrint(ctx.alloc, "{s}-{s}.pdf", .{ stem, date });
    const shares_abs = try std.fs.path.join(ctx.alloc, &.{ lib.root, "shares" });
    const out_abs = try std.fs.path.join(ctx.alloc, &.{ shares_abs, out_name });
    const out_rel = try std.fmt.allocPrint(ctx.alloc, "shares/{s}", .{out_name});

    library.write_mu.lock(ctx.io) catch return toolError(ctx.alloc, "server shutting down", .{});
    defer library.write_mu.unlock(ctx.io);
    try std.Io.Dir.cwd().createDirPath(ctx.io, shares_abs);

    const who = identity.resolve(ctx.alloc, ctx.io, ctx.peer);
    const who_label = identity.label(ctx.alloc, who) catch "unknown";
    var failure: ?pdf.Failure = null;
    const shared = share.sharePage(ctx.alloc, ctx.io, lib, rel, recipient, out_abs, who_label, &failure) catch |e| switch (e) {
        error.PageNotFound => return toolError(ctx.alloc, "no page at {s}", .{rel}),
        else => return renderFailure(ctx, e, failure),
    };

    const tail = try attributeAndCommit(ctx, &.{ out_rel, "shares.log" }, argString(ctx.arguments, "commit_message"));
    return .{ .text = try std.fmt.allocPrint(ctx.alloc, "shared {s}: pdf at /{s} {s}; logged: {s}", .{
        rel,
        out_rel,
        tail,
        std.mem.trimEnd(u8, shared.log_line, "\n"),
    }) };
}

fn toolRenderPdf(ctx: *const ToolContext) anyerror!ToolResult {
    const rel = switch (try pageRelArg(ctx)) {
        .failed => |failed| return failed,
        .rel => |rel| rel,
    };
    const rev = argString(ctx.arguments, "rev");
    if (rev) |sha| {
        // The CLI takes any revspec because argv is the operator's own;
        // network input is gated to bare shas before it can reach git.
        if (!history.isCommitSha(sha)) {
            return toolError(ctx.alloc, "rev must be a commit sha of 7 to 40 hex digits; the page's history widget lists them", .{});
        }
    }

    const lib = try resolveLib(ctx);
    const stem = blk: {
        const base = std.fs.path.basename(rel);
        break :blk base[0 .. base.len - ".html".len];
    };
    const out_name = if (rev) |sha|
        try std.fmt.allocPrint(ctx.alloc, "{s}-{s}.pdf", .{ stem, sha })
    else
        try std.fmt.allocPrint(ctx.alloc, "{s}.pdf", .{stem});
    const shares_abs = try std.fs.path.join(ctx.alloc, &.{ lib.root, "shares" });
    const out_abs = try std.fs.path.join(ctx.alloc, &.{ shares_abs, out_name });

    library.write_mu.lock(ctx.io) catch return toolError(ctx.alloc, "server shutting down", .{});
    defer library.write_mu.unlock(ctx.io);
    try std.Io.Dir.cwd().createDirPath(ctx.io, shares_abs);

    var rev_temp: ?[]const u8 = null;
    defer if (rev_temp) |temp| std.Io.Dir.cwd().deleteFile(ctx.io, temp) catch {}; // best effort; dot-files never index
    const page_abs = blk: {
        if (rev) |sha| {
            const temp = pdf.materializeRev(ctx.alloc, ctx.io, lib.root, rel, sha) catch |e| switch (e) {
                error.GitUnavailable => return toolError(ctx.alloc, "git is unavailable on the serve machine; rev needs it", .{}),
                error.GitShowFailed => return toolError(ctx.alloc, "git show {s}:{s} failed; check the revision and page", .{ sha, rel }),
                else => return e,
            };
            rev_temp = temp;
            break :blk temp;
        }
        const abs = try std.fs.path.join(ctx.alloc, &.{ lib.root, rel });
        if (std.Io.Dir.cwd().access(ctx.io, abs, .{})) |_| {} else |_| {
            return toolError(ctx.alloc, "no page at {s}", .{rel});
        }
        break :blk abs;
    };

    var failure: ?pdf.Failure = null;
    pdf.render(ctx.alloc, ctx.io, page_abs, out_abs, &failure) catch |e| return renderFailure(ctx, e, failure);
    return .{ .text = try std.fmt.allocPrint(ctx.alloc, "wrote /shares/{s}", .{out_name}) };
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

test "connectLine is the one-liner an agent needs" {
    const line = try connectLine(t.allocator, "studio-host", 8789);
    defer t.allocator.free(line);
    try t.expectEqualStrings(
        "claude mcp add --transport http atelier http://studio-host:8789/mcp",
        line,
    );
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

test "isWritableRelPath fences what the binary owns and the wrong types" {
    const good = [_][]const u8{
        "memo.html", "advisory/one.html",     "css/site.css", "notes.md",
        "logo.svg",  "templates/master.html",
    };
    for (good) |p| try t.expect(isWritableRelPath(p));
    const bad = [_][]const u8{
        // The binary's own files and validated write paths.
        "index.html",          "atelier.json",  "shares.log",
        "brand-guidelines.md", "themes/x.json", "themes/x.css",
        "shares/x.html",
        // Wrong types for an authoring surface.
              "deck.pdf",      "tool.exe",
        "photo.png",
        // Shape violations stay violations.
                  "../x.html",     "/abs.html",
        ".hidden.html",
    };
    for (bad) |p| try t.expect(!isWritableRelPath(p));
}

test "write_document creates, refuses, overwrites, and reports" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });

    const created = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"write_document\",\"arguments\":{\"path\":\"notes/deep/first\",\"content\":\"<title>F</title>\"}}}"));
    try t.expect(!created.is_error);
    try t.expect(std.mem.indexOf(u8, created.text, "wrote notes/deep/first.html") != null);
    try t.expect(std.mem.indexOf(u8, created.text, "as local") != null);
    const written = try tmp.dir.readFileAlloc(t.io, "notes/deep/first.html", a, .limited(4096));
    try t.expectEqualStrings("<title>F</title>", written);
    // No stray atomic-write temp.
    try t.expectError(error.FileNotFound, tmp.dir.readFileAlloc(t.io, "notes/deep/.first.html.tmp", a, .limited(64)));

    const refused = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"write_document\",\"arguments\":{\"path\":\"notes/deep/first\",\"content\":\"clobber\"}}}"));
    try t.expect(refused.is_error);
    const kept = try tmp.dir.readFileAlloc(t.io, "notes/deep/first.html", a, .limited(4096));
    try t.expectEqualStrings("<title>F</title>", kept);

    const replaced = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"write_document\",\"arguments\":{\"path\":\"notes/deep/first\",\"content\":\"v2\",\"overwrite\":true}}}"));
    try t.expect(!replaced.is_error);
    const second = try tmp.dir.readFileAlloc(t.io, "notes/deep/first.html", a, .limited(4096));
    try t.expectEqualStrings("v2", second);
}

test "write_document fences the library's own files" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{\"name\":\"Keep\"}" });

    const fenced_targets = [_][]const u8{ "atelier.json", "index.html", "themes/evil.css", "../escape" };
    inline for (fenced_targets) |target| {
        const outcome = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
            "\"params\":{\"name\":\"write_document\",\"arguments\":{\"path\":\"" ++ target ++ "\",\"content\":\"x\",\"overwrite\":true}}}"));
        try t.expect(outcome.is_error);
    }
    const manifest = try tmp.dir.readFileAlloc(t.io, "atelier.json", a, .limited(4096));
    try t.expectEqualStrings("{\"name\":\"Keep\"}", manifest);
}

test "write_document commits when asked and reports the outcome" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });

    // Outside a repository the write stands and the report says why the
    // commit did not happen. (The tmp dir sits inside this project's own
    // repo via .zig-cache, so init a nested one to keep git contained.)
    inline for (.{
        .{ "git", "-C", root, "init", "-q" },
        .{ "git", "-C", root, "config", "user.name", "Owner" },
        .{ "git", "-C", root, "config", "user.email", "owner@example.com" },
    }) |argv| {
        const run = std.process.run(a, t.io, .{
            .argv = &argv,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch return error.SkipZigTest;
        switch (run.term) {
            .exited => |code| if (code != 0) return error.SkipZigTest,
            else => return error.SkipZigTest,
        }
    }

    const committed = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"write_document\",\"arguments\":{\"path\":\"memo\",\"content\":\"<title>M</title>\"," ++
        "\"commit_message\":\"add the memo\"}}}"));
    try t.expect(!committed.is_error);
    try t.expect(std.mem.indexOf(u8, committed.text, "committed ") != null);

    const log_run = try std.process.run(a, t.io, .{
        .argv = &.{ "git", "-C", root, "log", "-1", "--format=%an|%s" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    // Loopback peers are the owner: no author override.
    try t.expectEqualStrings("Owner|add the memo", std.mem.trimEnd(u8, log_run.stdout, "\n"));
}

test "new_from_template scaffolds with brand seeding and reports unfilled" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.createDirPath(t.io, "templates");
    try tmp.dir.writeFile(t.io, .{
        .sub_path = "templates/memo.html",
        .data = "{{BRAND_PAPER}}|{{CLIENT}}|{{MISSING}}",
    });

    const outcome = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"new_from_template\",\"arguments\":{\"template\":\"memo\",\"dest\":\"notes/second\"," ++
        "\"vars\":{\"CLIENT\":\"Globex\"}}}}"));
    try t.expect(!outcome.is_error);
    try t.expect(std.mem.indexOf(u8, outcome.text, "unfilled: MISSING") != null);
    const written = try tmp.dir.readFileAlloc(t.io, "notes/second.html", a, .limited(4096));
    const expected = try std.fmt.allocPrint(a, "{s}|Globex|{{{{MISSING}}}}", .{library.Theme.neutral.paper});
    try t.expectEqualStrings(expected, written);

    const missing_template = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"new_from_template\",\"arguments\":{\"template\":\"ghost\",\"dest\":\"anything\"}}}"));
    try t.expect(missing_template.is_error);
}

test "reindex rebuilds the ledger on demand" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "page.html", .data = "<title>P</title>" });

    const outcome = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"reindex\"}}"));
    try t.expect(!outcome.is_error);
    const ledger = try tmp.dir.readFileAlloc(t.io, "index.html", a, .limited(1024 * 1024));
    try t.expect(std.mem.indexOf(u8, ledger, "P") != null);
}

test "isSafeRecipient rejects path and control characters" {
    try t.expect(isSafeRecipient("Globex"));
    try t.expect(isSafeRecipient("Globex Corp"));
    try t.expect(isSafeRecipient("om-vc_2.0"));
    try t.expect(!isSafeRecipient(""));
    try t.expect(!isSafeRecipient(".hidden"));
    try t.expect(!isSafeRecipient("a/b"));
    try t.expect(!isSafeRecipient("a\\b"));
    try t.expect(!isSafeRecipient("a\tb"));
    const long: [65]u8 = @splat('a');
    try t.expect(!isSafeRecipient(&long));
}

test "share_document renders into shares/ and records the six-column ledger" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{\"name\":\"Test Firm\"}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "memo.html", .data = "<html><body><h1>Memo</h1></body></html>" });

    const outcome = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"share_document\",\"arguments\":{\"path\":\"memo\",\"recipient\":\"Globex\"}}}"));
    if (outcome.is_error and std.mem.indexOf(u8, outcome.text, "chromium") != null) return error.SkipZigTest;
    try t.expect(!outcome.is_error);
    try t.expect(std.mem.indexOf(u8, outcome.text, "/shares/memo-Globex-") != null);
    try t.expect(std.mem.indexOf(u8, outcome.text, "as local") != null);

    const log = try tmp.dir.readFileAlloc(t.io, "shares.log", a, .limited(4096));
    var columns = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log, "\n"), '\t');
    var column_count: usize = 0;
    var last: []const u8 = "";
    while (columns.next()) |column| {
        column_count += 1;
        last = column;
    }
    try t.expectEqual(@as(usize, 6), column_count);
    try t.expectEqualStrings("local", last);

    const bad_recipient = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"share_document\",\"arguments\":{\"path\":\"memo\",\"recipient\":\"../evil\"}}}"));
    try t.expect(bad_recipient.is_error);
}

test "render_pdf gates network revs on sha shape" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "memo.html", .data = "<html><body>hi</body></html>" });

    // Revspecs that are not bare shas never reach a git argv from the
    // network, unlike the CLI where argv is the operator's own.
    const gated = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"render_pdf\",\"arguments\":{\"path\":\"memo\",\"rev\":\"HEAD\"}}}"));
    try t.expect(gated.is_error);
    try t.expect(std.mem.indexOf(u8, gated.text, "sha") != null);

    const missing = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"render_pdf\",\"arguments\":{\"path\":\"ghost\"}}}"));
    try t.expect(missing.is_error);

    const rendered = try toolOutcome(a, callAt(a, root, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"render_pdf\",\"arguments\":{\"path\":\"memo\"}}}"));
    if (rendered.is_error and std.mem.indexOf(u8, rendered.text, "chromium") != null) return error.SkipZigTest;
    try t.expect(!rendered.is_error);
    try t.expect(std.mem.indexOf(u8, rendered.text, "/shares/memo.pdf") != null);
    const pdf_bytes = try tmp.dir.readFileAlloc(t.io, "shares/memo.pdf", a, .limited(16 * 1024 * 1024));
    try t.expect(std.mem.startsWith(u8, pdf_bytes, "%PDF"));
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

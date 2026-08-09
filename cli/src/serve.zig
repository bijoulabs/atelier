const std = @import("std");
const library = @import("library.zig");
const index = @import("index.zig");
const history = @import("history.zig");
const theme = @import("theme.zig");
const json = @import("json.zig");
const mcp = @import("mcp.zig");

pub const Route = union(enum) {
    file: []const u8,
    snapshot: Snapshot,
    history: []const u8,
    diff: Diff,
    diffs_bundle,
    theme_editor,
    theme_data,
    theme_save,
    theme_apply,
    mcp,
    reload,
    bad,

    /// A whole-tree time-travel view: `rel` resolved against the library
    /// as of commit `sha` instead of the working tree.
    pub const Snapshot = struct { sha: []const u8, rel: []const u8 };

    /// A rendered comparison of one page across two versions. `from` and
    /// `to` are each a commit sha or the literal `current` (the working
    /// tree); mapPath validates both before this route exists.
    pub const Diff = struct { rel: []const u8, from: []const u8, to: []const u8 };
};

/// Maps an HTTP request target to a `Route`. Pure and testable: strips a
/// trailing `?query`, routes `/__reload` to `.reload`, rejects backslashes
/// and any `..` path segment as `.bad`, then peels the two prefixed route
/// families (`/__history/<page>` to `.history`, `/@<sha>/<page>` to
/// `.snapshot` when `<sha>` is 7 to 40 hex digits) before resolving
/// everything else to a working-tree `.file`. All three page-carrying
/// routes share `relFromPath`'s clean-URL rules, so `/@<sha>/foo` pins
/// exactly the page `/foo` names live.
///
/// The returned `.file`/`.history` slices and both `.snapshot` fields are
/// heap-allocated with `alloc`; callers own them. `.reload` and `.bad`
/// allocate nothing.
pub fn mapPath(alloc: std.mem.Allocator, raw_target: []const u8) !Route {
    var target = raw_target;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        query = target[q + 1 ..];
        target = target[0..q];
    }
    if (std.mem.eql(u8, target, "/__reload")) return .reload;
    if (std.mem.eql(u8, target, "/__assets/diffs.js")) return .diffs_bundle;
    if (std.mem.eql(u8, target, "/__theme")) return .theme_editor;
    if (std.mem.eql(u8, target, "/__theme/data")) return .theme_data;
    if (std.mem.eql(u8, target, "/__theme/save")) return .theme_save;
    if (std.mem.eql(u8, target, "/__theme/apply")) return .theme_apply;
    if (std.mem.eql(u8, target, "/mcp")) return .mcp;
    if (std.mem.indexOfScalar(u8, target, '\\') != null) return .bad;
    if (!std.mem.startsWith(u8, target, "/")) return .bad;
    var it = std.mem.splitScalar(u8, target[1..], '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return .bad;
    if (std.mem.startsWith(u8, target, "/__history/")) {
        return .{ .history = try relFromPath(alloc, target["/__history".len..]) };
    }
    if (std.mem.startsWith(u8, target, "/__diff/")) {
        const from = queryParam(query, "from") orelse return .bad;
        const to = queryParam(query, "to") orelse return .bad;
        if (!isVersionRef(from)) return .bad;
        if (!isVersionRef(to)) return .bad;
        const rel = try relFromPath(alloc, target["/__diff".len..]);
        errdefer alloc.free(rel);
        const from_owned = try alloc.dupe(u8, from);
        errdefer alloc.free(from_owned);
        return .{ .diff = .{ .rel = rel, .from = from_owned, .to = try alloc.dupe(u8, to) } };
    }
    if (std.mem.startsWith(u8, target, "/@")) {
        const after = target[2..];
        const cut = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        const sha = after[0..cut];
        if (!history.isCommitSha(sha)) return .bad;
        const rest = if (cut == after.len) "/" else after[cut..];
        const rel = try relFromPath(alloc, rest);
        errdefer alloc.free(rel);
        return .{ .snapshot = .{ .sha = try alloc.dupe(u8, sha), .rel = rel } };
    }
    return .{ .file = try relFromPath(alloc, target) };
}

/// Finds the `Content-Length` value in a raw header block (request line
/// included), case-insensitively, or null when absent or unparsable.
fn parseContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}

/// Finds the value of `name` in a raw query string of `a=b&c=d` pairs, or
/// null when absent. No percent-decoding: the only values atelier reads
/// through this are commit shas and the literal `current`, and anything
/// else fails validation right after.
fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// Whether `s` names a version a diff can be taken against: a commit sha
/// or the literal `current` (the working tree). Case-sensitive on
/// purpose; `current` is a protocol token, not prose.
fn isVersionRef(s: []const u8) bool {
    return std.mem.eql(u8, s, "current") or history.isCommitSha(s);
}

/// Maps an absolute URL path (leading `/`, already traversal-checked by
/// `mapPath`) to a library-relative file path: `/` means `index.html`,
/// and a last segment with no extension of its own gets `.html` appended
/// (clean URLs). Heap-allocated with `alloc`; the caller owns the result.
fn relFromPath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    std.debug.assert(std.mem.startsWith(u8, path, "/"));
    const out = if (std.mem.eql(u8, path, "/"))
        try alloc.dupe(u8, "index.html")
    else blk: {
        const rel = path[1..];
        const last = std.fs.path.basename(rel);
        if (std.mem.indexOfScalar(u8, last, '.') != null) break :blk try alloc.dupe(u8, rel);
        break :blk try std.fmt.allocPrint(alloc, "{s}.html", .{rel});
    };
    // Negative space: mapPath's rejects make an empty or absolute result
    // impossible, and the join in handleConn depends on that.
    std.debug.assert(out.len > 0);
    std.debug.assert(!std.fs.path.isAbsolute(out));
    return out;
}

/// Maps a file's extension to a MIME type; unrecognized extensions (or
/// none) fall back to `application/octet-stream`.
pub fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const map = .{
        .{ ".html", "text/html; charset=utf-8" }, .{ ".css", "text/css" },
        .{ ".js", "text/javascript" },            .{ ".json", "application/json" },
        .{ ".png", "image/png" },                 .{ ".svg", "image/svg+xml" },
        .{ ".jpg", "image/jpeg" },                .{ ".jpeg", "image/jpeg" },
        .{ ".pdf", "application/pdf" },           .{ ".ico", "image/x-icon" },
        .{ ".woff2", "font/woff2" },
    };
    inline for (map) |m| if (std.mem.eql(u8, ext, m[0])) return m[1];
    return "application/octet-stream";
}

/// Upper bound on how large a single served file is allowed to be.
const file_bytes_max = 32 * 1024 * 1024;

/// The vendored @pierre/diffs + Shiki bundle served at /__assets/diffs.js.
/// NOTE: this is the one third-party artifact in an otherwise
/// zero-dependency repo, admitted as a committed, license-noted blob
/// (Apache-2.0); `zig build` never runs npm. Provenance, the size fence,
/// and the regeneration recipe live in `assets/REGENERATE.md`.
const diffs_bundle_js = @embedFile("assets/pierre_diffs.js");

/// Reads one version of `rel`: the working tree for `current`, `git show`
/// for a commit sha. Null when that version does not exist or cannot be
/// read; the caller turns that into a specific 404.
fn loadVersion(alloc: std.mem.Allocator, io: std.Io, root: []const u8, ref: []const u8, rel: []const u8) ?[]u8 {
    if (std.mem.eql(u8, ref, "current")) {
        const abs = std.fs.path.join(alloc, &.{ root, rel }) catch return null;
        return std.Io.Dir.cwd().readFileAlloc(io, abs, alloc, .limited(file_bytes_max)) catch null;
    }
    return history.showFile(alloc, io, root, ref, rel, file_bytes_max);
}

const net = std.Io.net;

/// Blocking GET-only HTTP/1.1 accept loop over `lib.root`, listening on
/// `0.0.0.0:port`. Every accepted connection is handed to `handleConn` on
/// its own detached `std.Thread` (Task 7 adds SSE clients that must outlive
/// a single request-response, so per-connection threads are load-bearing,
/// not incidental); a spawn failure just closes that one connection and the
/// loop continues. Never returns normally.
///
/// Takes no allocator: nothing in this accept loop or in `handleConn` (see
/// its doc comment) allocates against a caller-supplied allocator anymore,
/// so there is nothing here for the process-lifetime arena `main` used to
/// hand in to back.
///
/// NOTE: reconciled against the installed 0.17.0-dev.704 std, which has no
/// `std.net` anymore; the brief's `std.net.Address` / `addr.listen(.{...})`
/// / `server.accept()` / `stream.read(&buf)` / `stream.writeAll(...)` all
/// moved under the `Io` capability as `std.Io.net` (`net.IpAddress`,
/// `address.listen(io, .{...})` returning `net.Server`, `server.accept(io)`
/// returning `net.Stream` directly (no `.stream` wrapper field to unwrap),
/// `stream.read(io, data: [][]u8)` (vectored), and `stream.close(io)`).
/// `run` and `handleConn` both gained an `io: std.Io` parameter as a
/// result, threaded the same way `resolveFromArgs`/`pdf.render` already do.
pub fn run(io: std.Io, lib: library.Library, port: u16, reload: bool) !void {
    const addr = try net.IpAddress.parseIp4("0.0.0.0", port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    std.debug.print("atelier serving {s} on http://0.0.0.0:{d}\n", .{ lib.root, port });

    if (reload) {
        if (std.Thread.spawn(.{}, scanLoop, .{ io, lib })) |scan_th| {
            scan_th.detach();
        } else |_| {} // no live reload if the scanner thread can't be spawned; serving still works
    }

    while (true) {
        const stream = server.accept(io) catch continue;
        // NOTE: this std's accept returns no separate address; the POSIX
        // backend fills `socket.address` from accept(2)'s sockaddr
        // out-param, so `stream.socket.address` IS the peer address (see
        // Io/Threaded.zig netAcceptPosix). The MCP handlers resolve it to
        // a tailnet identity for attribution.
        const peer = stream.socket.address;
        const th = std.Thread.spawn(.{}, handleConn, .{ io, lib.root, stream, peer, reload }) catch {
            stream.close(io);
            continue;
        };
        th.detach();
    }
}

/// Serves a single request on `stream`, then closes it (`Connection: close`
/// on every response, per the brief). Reads at most 4096 bytes in one shot
/// (no loop-until-headers-complete; a real browser GET fits easily), parses
/// only the request line (headers/body, if any, are ignored), and dispatches
/// on method and `mapPath`'s route. Any parse failure (short read, no
/// `\r\n`, missing method/target) just drops the connection with no
/// response, matching the brief's `orelse return` / `catch return` shape.
///
/// The per-connection arena is backed by `std.heap.page_allocator`, not a
/// caller-supplied allocator, and deliberately so: `handleConn` runs on its
/// own detached thread per connection (see `run`'s doc comment), and SSE
/// keeps a `/__reload` connection's thread alive indefinitely while ordinary
/// page loads come and go on other threads at the same time. `ArenaAllocator`
/// can only reclaim its most-recent allocation on `free`/`resize`, so handing
/// it a shared long-lived allocator (e.g. the process's one arena) means
/// overlapping connections permanently strand every allocation that wasn't
/// the last one freed, in a process that is meant to keep running
/// indefinitely (`atelier serve`). `page_allocator` reclaims each connection's
/// pages independently on `deinit`, regardless of overlap with other
/// connections; this is the same allocator `treeSignature` already uses for
/// its per-scan walker allocations, for the same reason.
fn handleConn(io: std.Io, root: []const u8, stream: net.Stream, peer: net.IpAddress, reload: bool) void {
    // Every path closes `stream` except a successfully-registered SSE
    // client (Task 7): that connection has to stay open so the scanner can
    // push events down it later, well after this function has returned.
    var keep_open = false;
    defer if (!keep_open) stream.close(io);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Bounded request read: accumulate until the blank line ends the
    // headers or the 8 KB cap trips (a real browser request fits with
    // room to spare; anything larger is not worth serving).
    var buf: [8192]u8 = undefined;
    var have: usize = 0;
    const header_end = blk: {
        while (true) {
            if (std.mem.indexOf(u8, buf[0..have], "\r\n\r\n")) |at| break :blk at + 4;
            if (have == buf.len) return;
            var iov: [1][]u8 = .{buf[have..]};
            const n = stream.read(io, &iov) catch return;
            if (n == 0) return;
            have += n;
        }
    };
    const head = buf[0..header_end];
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    const is_post = std.mem.eql(u8, method, "POST");
    if (!std.mem.eql(u8, method, "GET") and !is_post) {
        return writeBody(stream, io, "405 Method Not Allowed", "text/plain", "GET only\n");
    }

    const route = mapPath(a, target) catch return;
    // POST exists for the theme editor's save and apply and for /mcp, the
    // remote authoring surface. This is a deliberate access-model
    // decision: the port is unauthenticated and intended for trusted
    // private networks (a tailnet), and anyone who can reach it is
    // trusted with full authoring. Every mutation is path-validated,
    // size-capped, serialized under library.write_mu, attributed to the
    // peer (identity.zig), and, when asked, committed to the library's
    // own git history, which is the audit trail.
    const wants_post = route == .theme_save or route == .theme_apply or route == .mcp;
    if (is_post != wants_post) {
        return writeBody(stream, io, "405 Method Not Allowed", "text/plain", "wrong method\n");
    }
    switch (route) {
        .bad => return writeBody(stream, io, "400 Bad Request", "text/plain", "bad path\n"),
        .theme_editor => return writeBody(stream, io, "200 OK", "text/html; charset=utf-8", theme_editor_html),
        .theme_data => return handleThemeData(a, io, root, stream),
        .theme_save, .theme_apply, .mcp => {
            const content_length = parseContentLength(head) orelse {
                return writeBody(stream, io, "411 Length Required", "text/plain", "length required\n");
            };
            if (content_length > bodyCapFor(route)) {
                return writeBody(stream, io, "413 Content Too Large", "text/plain", "body too large\n");
            }
            // curl holds the body back until the server blesses an
            // Expect: 100-continue; real MCP clients rarely send it, but
            // the manual-test client of record does.
            if (headerHasExpectContinue(head)) writeContinue(stream, io);
            const body = readBody(a, io, stream, buf[header_end..have], content_length, bodyCapFor(route)) orelse return;
            if (route == .mcp) return handleMcp(a, io, root, stream, peer, body);
            if (route == .theme_apply) return handleThemeApply(a, io, root, stream, body);
            return handleThemeSave(a, io, root, stream, body);
        },
        .diffs_bundle => {
            // The one deliberate exemption from the global no-store: the
            // bundle is immutable per binary, and it is 2.3 MB the browser
            // should not refetch on every diff view.
            return writeBodyCached(stream, io, "200 OK", "text/javascript; charset=utf-8", "public, max-age=31536000, immutable", diffs_bundle_js);
        },
        .diff => |d| {
            const old_content = loadVersion(a, io, root, d.from, d.rel) orelse {
                return writeBody(stream, io, "404 Not Found", "text/plain", "from version not found\n");
            };
            const new_content = loadVersion(a, io, root, d.to, d.rel) orelse {
                return writeBody(stream, io, "404 Not Found", "text/plain", "to version not found\n");
            };
            const page = renderDiffPage(a, d.rel, d.from, d.to, old_content, new_content) catch return;
            return writeBody(stream, io, "200 OK", "text/html; charset=utf-8", page);
        },
        .history => |rel| {
            const commits = history.pageLog(a, io, root, rel);
            const rendered = history.renderJson(a, commits) catch return;
            return writeBody(stream, io, "200 OK", "application/json", rendered);
        },
        .snapshot => |snap| {
            const body = history.showFile(a, io, root, snap.sha, snap.rel, file_bytes_max) orelse {
                return writeBody(stream, io, "404 Not Found", "text/plain", "not found\n");
            };
            const is_html = std.mem.eql(u8, std.fs.path.extension(snap.rel), ".html");
            if (is_html and !std.mem.eql(u8, snap.rel, "index.html")) {
                var page = body;
                page = injectAtBodyEnd(a, page, home_snippet) catch page;
                page = injectAtBodyEnd(a, page, history_snippet) catch page;
                // No reload snippet: a snapshot is immutable, and a tab
                // pinned to one should not refresh out from under the
                // viewer when the working tree changes.
                return writeBody(stream, io, "200 OK", contentType(snap.rel), page);
            }
            return writeBody(stream, io, "200 OK", contentType(snap.rel), body);
        },
        .reload => {
            if (!reload) return writeBody(stream, io, "404 Not Found", "text/plain", "not found\n");
            var hdr_buf: [128]u8 = undefined;
            var w = stream.writer(io, &hdr_buf);
            w.interface.writeAll(sse_headers) catch return;
            w.interface.flush() catch return;
            if (registerClient(io, stream)) keep_open = true;
            return;
        },
        .file => |rel| {
            const abs = std.fs.path.join(a, &.{ root, rel }) catch return;
            const body = std.Io.Dir.cwd().readFileAlloc(io, abs, a, .limited(file_bytes_max)) catch {
                return writeBody(stream, io, "404 Not Found", "text/plain", "not found\n");
            };
            const is_html = std.mem.eql(u8, std.fs.path.extension(rel), ".html");
            if (is_html) {
                var page = body;
                // Navigation back to the index, and the page's own time
                // travel, on every page except the index itself (whose
                // regenerated file history is noise, not authorship);
                // the index instead gets the way into the theme editor.
                if (std.mem.eql(u8, rel, "index.html")) {
                    page = injectAtBodyEnd(a, page, theme_chip_snippet) catch page;
                } else {
                    page = injectAtBodyEnd(a, page, home_snippet) catch page;
                    page = injectAtBodyEnd(a, page, history_snippet) catch page;
                }
                if (reload) page = injectSnippet(a, page) catch page;
                return writeBody(stream, io, "200 OK", contentType(rel), page);
            }
            return writeBody(stream, io, "200 OK", contentType(rel), body);
        },
    }
}

/// The theme editor page served at /__theme, our own code embedded at
/// build time (`assets/theme_editor.html`); like every served page it
/// makes no external requests.
const theme_editor_html = @embedFile("assets/theme_editor.html");

/// Upper bound on a theme-save request body. A full theme with a fat
/// palette is under 4 KB; 64 KB leaves an order of magnitude of slack.
const save_body_bytes_max = 64 * 1024;

/// Upper bound on an /mcp request body: a whole document plus its JSON
/// escaping overhead, matching the 4 MB page-read cap the commands use.
pub const mcp_body_bytes_max = 4 * 1024 * 1024;

/// The body cap for a POST route. Pure so the pairing of route and cap
/// is pinned by test rather than scattered across the switch.
fn bodyCapFor(route: Route) usize {
    return switch (route) {
        .theme_save, .theme_apply => save_body_bytes_max,
        .mcp => mcp_body_bytes_max,
        // Negative space: no other route reads a body.
        else => unreachable,
    };
}

/// Whether the raw header block asks for a 100-continue handshake, the
/// same case-insensitive scan as `parseContentLength`.
fn headerHasExpectContinue(headers: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "expect")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.ascii.eqlIgnoreCase(value, "100-continue");
    }
    return false;
}

/// Blesses a pending Expect: 100-continue so the client sends the body.
/// Errors are swallowed: a peer that vanished here surfaces as the short
/// read in `readBody` right after.
fn writeContinue(stream: net.Stream, io: std.Io) void {
    var hdr_buf: [64]u8 = undefined;
    var w = stream.writer(io, &hdr_buf);
    w.interface.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch return;
    w.interface.flush() catch return;
}

/// Serves POST /mcp: hands the raw body to mcp.handle (which owns all
/// JSON-RPC framing) and maps its socket-free result onto the wire. 202
/// carries no body per the streamable HTTP spec's notification rule.
fn handleMcp(a: std.mem.Allocator, io: std.Io, root: []const u8, stream: net.Stream, peer: net.IpAddress, body: []const u8) void {
    switch (mcp.handle(a, io, root, peer, body)) {
        .json => |payload| return writeBody(stream, io, "200 OK", "application/json", payload),
        .accepted => return writeBody(stream, io, "202 Accepted", "text/plain", ""),
        .parse_error => |payload| return writeBody(stream, io, "400 Bad Request", "application/json", payload),
    }
}

/// Reads a POST body of exactly `len` bytes: whatever arrived past the
/// headers first (`pre`), then the socket until complete. Null on any
/// short read; the connection just drops, like every other parse
/// failure in `handleConn`.
fn readBody(alloc: std.mem.Allocator, io: std.Io, stream: net.Stream, pre: []const u8, len: usize, cap: usize) ?[]u8 {
    std.debug.assert(len <= cap);
    const body = alloc.alloc(u8, len) catch return null;
    const pre_n = @min(pre.len, len);
    @memcpy(body[0..pre_n], pre[0..pre_n]);
    var got = pre_n;
    while (got < len) {
        var iov: [1][]u8 = .{body[got..]};
        const n = stream.read(io, &iov) catch return null;
        if (n == 0) return null;
        got += n;
    }
    std.debug.assert(got == len);
    return body;
}

/// Serves /__theme/data: the resolved active theme plus every named
/// starting point (embedded presets, then the library's own themes/,
/// which shadow same-named presets in the editor's picker the same way
/// resolution does). The library is re-resolved per request so the
/// editor always sees the manifest as it is on disk now, not as it was
/// when serve started.
fn handleThemeData(a: std.mem.Allocator, io: std.Io, root: []const u8, stream: net.Stream) void {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "{\"active\":") catch return;
    const active: theme.Theme = blk: {
        const fresh = library.resolve(a, io, .{ .explicit = root, .start_dir = "/", .config_path = "/nonexistent" }) catch break :blk theme.Theme.neutral;
        break :blk fresh.theme;
    };
    appendThemeObject(&out, a, active) catch return;
    out.appendSlice(a, ",\"themes\":{") catch return;
    var first = true;
    for (theme.preset_names) |name| {
        const preset = theme.parseThemeFile(a, theme.presetSource(name).?) catch continue;
        appendThemeEntry(&out, a, name, preset, &first) catch return;
    }
    const themes_dir = std.fs.path.join(a, &.{ root, "themes" }) catch return;
    if (std.Io.Dir.openDirAbsolute(io, themes_dir, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const name = entry.name[0 .. entry.name.len - ".json".len];
            if (!theme.isThemeName(name)) continue;
            const raw = dir.readFileAlloc(io, entry.name, a, .limited(theme.theme_bytes_max)) catch continue;
            const parsed = theme.parseThemeFile(a, raw) catch continue; // invalid files just don't list
            appendThemeEntry(&out, a, name, parsed, &first) catch return;
        }
    } else |_| {} // no themes/ directory: presets alone
    out.appendSlice(a, "}}") catch return;
    writeBody(stream, io, "200 OK", "application/json", out.items);
}

/// Appends `"name":<theme object>` with a leading comma after the first
/// entry. Later entries win in JSON parsing, which is how a library
/// theme shadows a same-named preset in the editor.
fn appendThemeEntry(out: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, th: theme.Theme, first: *bool) !void {
    if (!first.*) try out.appendSlice(a, ",");
    first.* = false;
    try json.appendString(out, a, name);
    try out.appendSlice(a, ":");
    try appendThemeObject(out, a, th);
}

/// Appends one theme as a JSON object (the standalone theme-file shape).
fn appendThemeObject(out: *std.ArrayList(u8), a: std.mem.Allocator, th: theme.Theme) !void {
    const rendered = try theme.renderThemeJson(a, th);
    try out.appendSlice(a, rendered);
}

/// Serves POST /__theme/save: validates hard (the whole write surface of
/// the server is this function) and writes `<library>/themes/<name>.json`.
fn handleThemeSave(a: std.mem.Allocator, io: std.Io, root: []const u8, stream: net.Stream, body: []const u8) void {
    const SaveRequest = struct { name: []const u8 = "", theme: std.json.Value = .null };
    const parsed = std.json.parseFromSlice(SaveRequest, a, body, .{ .ignore_unknown_fields = true }) catch {
        return writeBody(stream, io, "400 Bad Request", "text/plain", "bad save request: want {\"name\":\"...\",\"theme\":{...}}\n");
    };
    if (!theme.isThemeName(parsed.value.name)) {
        return writeBody(stream, io, "400 Bad Request", "text/plain", "bad theme name: want [a-z0-9-], 1 to 64 chars\n");
    }
    if (parsed.value.theme != .object) {
        return writeBody(stream, io, "400 Bad Request", "text/plain", "theme must be an object\n");
    }
    const saved = theme.parseThemeValue(a, parsed.value.theme) catch |e| switch (e) {
        error.NestedBase => return writeBody(stream, io, "400 Bad Request", "text/plain", "saved themes must not declare base\n"),
        else => return,
    };
    if (!theme.fieldLimitsOk(saved)) {
        return writeBody(stream, io, "400 Bad Request", "text/plain", "theme field too large\n");
    }
    const rendered = theme.renderThemeJson(a, saved) catch return;
    const themes_dir = std.fs.path.join(a, &.{ root, "themes" }) catch return;
    // All library mutations serialize on write_mu; a theme save must not
    // interleave with an MCP write's git staging or an index regeneration.
    library.write_mu.lock(io) catch return;
    defer library.write_mu.unlock(io);
    std.Io.Dir.cwd().createDirPath(io, themes_dir) catch {
        return writeBody(stream, io, "500 Internal Server Error", "text/plain", "cannot create themes/\n");
    };
    const file_path = std.fmt.allocPrint(a, "{s}/{s}.json", .{ themes_dir, parsed.value.name }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = rendered }) catch {
        return writeBody(stream, io, "500 Internal Server Error", "text/plain", "write failed\n");
    };
    const rel_path = std.fmt.allocPrint(a, "themes/{s}.json", .{parsed.value.name}) catch return;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "{\"path\":") catch return;
    json.appendString(&out, a, rel_path) catch return;
    out.appendSlice(a, "}") catch return;
    writeBody(stream, io, "200 OK", "application/json", out.items);
}

/// Serves POST /__theme/apply: adopts a named theme by rewriting the
/// manifest's `theme` field (see `theme.adoptTheme`). The name must
/// already resolve, so this can never point the manifest at nothing.
fn handleThemeApply(a: std.mem.Allocator, io: std.Io, root: []const u8, stream: net.Stream, body: []const u8) void {
    const ApplyRequest = struct { name: []const u8 = "" };
    const parsed = std.json.parseFromSlice(ApplyRequest, a, body, .{ .ignore_unknown_fields = true }) catch {
        return writeBody(stream, io, "400 Bad Request", "text/plain", "bad apply request: want {\"name\":\"...\"}\n");
    };
    library.write_mu.lock(io) catch return;
    defer library.write_mu.unlock(io);
    theme.adoptTheme(a, io, root, parsed.value.name) catch |e| switch (e) {
        error.UnknownTheme => return writeBody(stream, io, "400 Bad Request", "text/plain", "unknown theme name\n"),
        else => return writeBody(stream, io, "500 Internal Server Error", "text/plain", "could not update atelier.json\n"),
    };
    const rel_name = std.fmt.allocPrint(a, "{{\"applied\":\"{s}\"}}", .{parsed.value.name}) catch return;
    writeBody(stream, io, "200 OK", "application/json", rel_name);
}

/// Writes a status line, `Content-Type`/`Content-Length`, the two headers
/// mandatory on every response (`Cache-Control: no-store`,
/// `Connection: close`), then `body`. Errors (a full pipe, a reset peer)
/// are swallowed: the connection is closing either way, in `handleConn`'s
/// `defer stream.close(io)`.
///
/// NOTE: the brief's reference `writeHead` hand-builds the header into a
/// fixed `hbuf` via `std.fmt.bufPrint` and separately `stream.writeAll`s it
/// before the body; on this std, `stream.writeAll` doesn't exist directly
/// on `net.Stream` (writes go through a buffered `Io.Writer` obtained via
/// `stream.writer(io, buffer)`), which already does its own internal
/// buffering/formatting, so the intermediate `hbuf`/`bufPrint` step is
/// dropped in favor of `w.interface.print` straight into that writer; same
/// bytes on the wire, one fewer manual buffer.
fn writeBody(stream: net.Stream, io: std.Io, status: []const u8, ctype: []const u8, body: []const u8) void {
    writeBodyCached(stream, io, status, ctype, "no-store", body);
}

/// `writeBody` with an explicit `Cache-Control`. Only the vendored diffs
/// bundle uses a value other than `no-store`; see the `.diffs_bundle`
/// arm in `handleConn` for why.
fn writeBodyCached(stream: net.Stream, io: std.Io, status: []const u8, ctype: []const u8, cache: []const u8, body: []const u8) void {
    var send_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &send_buf);
    w.interface.print(
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: {s}\r\nConnection: close\r\n\r\n",
        .{ status, ctype, body.len, cache },
    ) catch return;
    w.interface.writeAll(body) catch return;
    w.interface.flush() catch return;
}

/// The `/__reload` response header block. Deliberately does not go through
/// `writeBody`: no `Content-Length` (this is a stream, not a fixed body)
/// and no `Connection: close` (the whole point is that this connection
/// stays open).
const sse_headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n\r\n";

/// The `<script>` tag injected into every `.html` response when reload is
/// enabled; opens an SSE connection to `/__reload` and reloads the page on
/// the first (and only) event that route ever sends.
const snippet = "<script>new EventSource('/__reload').onmessage=()=>location.reload();</script>";

/// The navigation chip injected at serve time into every non-index HTML
/// page: a fixed "back to the atelier" link. Documents stay self-contained
/// on disk; only the served bytes carry it, the same contract as the
/// reload snippet. Deliberately brand-neutral (translucent dark on
/// anything) since the binary carries no brand, and hidden in print so a
/// browser print matches the document.
pub const home_snippet = "<style>@media print{#atelier-home{display:none}}</style>" ++
    "<a id=\"atelier-home\" href=\"/\" style=\"position:fixed;top:14px;left:14px;z-index:9999;" ++
    "font:600 10px/1 ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase;" ++
    "text-decoration:none;color:#fff;background:rgba(20,18,15,.78);padding:7px 11px;border-radius:2px\">" ++
    "&larr; Atelier</a>";

/// The settings chip injected at serve time into the served index only:
/// the discoverable way into the theme editor, which exists only while
/// serving (so the link must never be written into index.html itself).
/// Mirrors the home chip's brand-neutral look, docked top right where
/// pages keep their history chip; the index has no history, so the
/// corner is free.
pub const theme_chip_snippet = "<style>@media print{#atelier-theme{display:none}}</style>" ++
    "<a id=\"atelier-theme\" href=\"/__theme\" style=\"position:fixed;top:14px;right:14px;z-index:9999;" ++
    "font:600 10px/1 ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase;" ++
    "text-decoration:none;color:#fff;background:rgba(20,18,15,.78);padding:7px 11px;border-radius:2px\">" ++
    "Theme</a>";

/// The time-travel widget injected at serve time into every non-index
/// HTML page, live or snapshot (never written to files, the same contract
/// as the reload and home snippets). A chip in the top right, mirroring
/// the home chip's brand-neutral look on the left, that fetches the
/// page's commit list from `/__history<path>` and stays hidden when the
/// list comes back empty (no git, no repo, no history). Clicking it opens
/// a panel of commits; picking one navigates to `/@<sha><path>`, whose
/// path prefix keeps every relative asset request inside the same
/// snapshot. On a snapshot view the chip shows the pinned sha (and
/// renders even with an empty list, so the way back to `current` never
/// disappears). Subjects go through `textContent`, never innerHTML.
///
/// Each row also carries a from/to radio pair feeding the `diff` action,
/// which links to `/__diff<path>?from=X&to=Y`. One-sided picks fill the
/// other side by convention: a lone `from` diffs against `current`, a
/// lone `to` diffs against its parent (the next row down). On a snapshot
/// view the pinned sha and `current` come pre-selected.
pub const history_snippet = "<style>@media print{#atelier-history,#atelier-history-panel{display:none}}" ++
    "#atelier-history{position:fixed;top:14px;right:14px;z-index:9999;display:none;" ++
    "font:600 10px/1 ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase;" ++
    "color:#fff;background:rgba(20,18,15,.78);padding:7px 11px;border-radius:2px;cursor:pointer}" ++
    "#atelier-history-panel{position:fixed;top:40px;right:14px;z-index:9999;display:none;" ++
    "max-height:60vh;overflow:auto;min-width:300px;background:rgba(20,18,15,.92);" ++
    "font:11px/1.5 ui-monospace,monospace;padding:6px 0;border-radius:2px}" ++
    "#atelier-history-panel>div{display:flex;align-items:center;gap:6px;padding:5px 12px}" ++
    "#atelier-history-panel>div:hover{background:rgba(255,255,255,.12)}" ++
    "#atelier-history-panel input{margin:0;accent-color:#fff}" ++
    "#atelier-history-panel a{color:#fff;text-decoration:none;white-space:nowrap}" ++
    "#atelier-history-panel a.now{opacity:.55}" ++
    "#atelier-diff-go{display:block;text-align:center;margin:6px 12px 4px;padding:5px 0;" ++
    "border:1px solid rgba(255,255,255,.4);border-radius:2px;" ++
    "letter-spacing:.14em;text-transform:uppercase;font-weight:600}" ++
    "#atelier-diff-go.off{opacity:.3;pointer-events:none}</style>" ++
    "<div id=\"atelier-history\"></div><div id=\"atelier-history-panel\"></div>" ++
    "<script>(()=>{" ++
    "const m=location.pathname.match(/^\\/@([0-9a-fA-F]{7,40})(\\/.*)?$/);" ++
    "const pin=m?m[1]:null;const path=m?(m[2]||'/'):location.pathname;" ++
    "const chip=document.getElementById('atelier-history');" ++
    "const panel=document.getElementById('atelier-history-panel');" ++
    "fetch('/__history'+path).then(r=>r.json()).then(list=>{" ++
    "if(!list.length&&!pin)return;" ++
    "chip.textContent=pin?'\\u23f1 '+pin:'history';chip.style.display='block';" ++
    // refs, newest first, with the working tree in front: the parent of
    // refs[i] is refs[i+1], which drives the one-sided pick defaults.
    "const refs=['current'].concat(list.map(c=>c.sha));" ++
    "const sel={from:pin,to:pin?'current':null};" ++
    "const go=document.createElement('a');go.id='atelier-diff-go';go.textContent='diff';" ++
    "const sync=()=>{let f=sel.from,t=sel.to;" ++
    "if(f&&!t)t='current';" ++
    "if(!f&&t){const i=refs.indexOf(t);f=i>=0&&i+1<refs.length?refs[i+1]:null;}" ++
    "if(f&&t&&f!==t){go.href='/__diff'+path+'?from='+f+'&to='+t;go.classList.remove('off');}" ++
    "else{go.removeAttribute('href');go.classList.add('off');}};" ++
    "const row=(ref,label,now)=>{const div=document.createElement('div');" ++
    "const rf=document.createElement('input');rf.type='radio';rf.name='atelier-dfrom';rf.title='diff from';" ++
    "const rt=document.createElement('input');rt.type='radio';rt.name='atelier-dto';rt.title='diff to';" ++
    "rf.checked=sel.from===ref;rt.checked=sel.to===ref;" ++
    "rf.onchange=()=>{sel.from=ref;sync();};rt.onchange=()=>{sel.to=ref;sync();};" ++
    "const a=document.createElement('a');a.href=ref==='current'?path:'/@'+ref+path;" ++
    "a.textContent=label;if(now)a.className='now';" ++
    "div.append(rf,rt,a);panel.appendChild(div);};" ++
    "row('current','current',!pin);" ++
    "list.forEach(c=>row(c.sha,c.date+'  '+c.subject+'  '+c.sha,pin===c.sha));" ++
    "panel.appendChild(go);sync();" ++
    "chip.onclick=()=>{panel.style.display=panel.style.display==='block'?'none':'block';};" ++
    "}).catch(()=>{});" ++
    "})();</script>";

/// The style block of the diff shell page: deliberately brand-neutral
/// (the binary carries no brand), monospace, dark-aware. The rendered
/// diff itself is styled by the vendored renderer inside its shadow DOM.
const diff_page_css = ":root{color-scheme:light dark}" ++
    "body{margin:0;background:#fff;color:#1b1a17;font:12px/1.5 ui-monospace,monospace}" ++
    "@media(prefers-color-scheme:dark){body{background:#16130f;color:#eee}}" ++
    "header{display:flex;gap:16px;align-items:center;padding:12px 16px;" ++
    "font:600 10px/1 ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase}" ++
    "header a{color:inherit;text-decoration:none;opacity:.75}header a:hover{opacity:1}" ++
    "#diff-pair{opacity:.55}" ++
    "#diff-toggle{margin-left:auto;font:inherit;letter-spacing:inherit;text-transform:inherit;" ++
    "color:inherit;background:none;border:1px solid currentColor;opacity:.55;" ++
    "padding:6px 10px;border-radius:2px;cursor:pointer}#diff-toggle:hover{opacity:1}" ++
    "#diff-root{padding:0 16px 16px}";

/// The module script of the diff shell page: reads the embedded JSON,
/// renders via the vendored bundle, and re-renders on the split/unified
/// toggle (the renderer has no restyle-in-place API, so a fresh instance
/// per toggle is the supported path).
const diff_page_js = "import{DEFAULT_THEMES,DIFFS_TAG_NAME,FileDiff}from'/__assets/diffs.js';" ++
    "const d=JSON.parse(document.getElementById('diff-data').textContent);" ++
    "const root=document.getElementById('diff-root');let style='split';" ++
    "const render=()=>{root.textContent='';" ++
    "const fd=new FileDiff({theme:DEFAULT_THEMES,diffStyle:style,diffIndicators:'bars',overflow:'wrap'});" ++
    "const c=document.createElement(DIFFS_TAG_NAME);root.appendChild(c);" ++
    "fd.render({oldFile:{name:d.name,contents:d.old},newFile:{name:d.name,contents:d.new},fileContainer:c});};" ++
    "render();" ++
    "document.getElementById('diff-toggle').onclick=e=>{" ++
    "style=style==='split'?'unified':'split';" ++
    "e.target.textContent=style==='split'?'unified':'split';render();};";

/// Renders the diff shell page for `rel` comparing `from` to `to` (each a
/// sha or `current`, already validated by `mapPath`). Both versions are
/// embedded as JSON with angle brackets escaped, so page content cannot
/// break out of the data element; `rel` is HTML-escaped where it appears
/// as text. Caller owns the returned buffer.
pub fn renderDiffPage(
    alloc: std.mem.Allocator,
    rel: []const u8,
    from: []const u8,
    to: []const u8,
    old_content: []const u8,
    new_content: []const u8,
) ![]u8 {
    std.debug.assert(rel.len > 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "<!doctype html><html><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>diff \u{b7} ");
    try appendHtmlEscaped(&out, alloc, rel);
    try out.appendSlice(alloc, "</title><style>" ++ diff_page_css ++ "</style></head><body><header>" ++
        "<a id=\"diff-back\" href=\"");
    const page_path = try relToPagePath(alloc, rel);
    defer alloc.free(page_path);
    try appendHtmlEscaped(&out, alloc, page_path);
    try out.appendSlice(alloc, "\">&larr; ");
    try appendHtmlEscaped(&out, alloc, rel);
    try out.appendSlice(alloc, "</a><span id=\"diff-pair\">");
    try out.appendSlice(alloc, from);
    try out.appendSlice(alloc, " &rarr; ");
    try out.appendSlice(alloc, to);
    try out.appendSlice(alloc, "</span><button id=\"diff-toggle\">unified</button></header>" ++
        "<div id=\"diff-root\"></div><script type=\"application/json\" id=\"diff-data\">{\"name\":");
    try history.appendJsonString(&out, alloc, rel);
    try out.appendSlice(alloc, ",\"old\":");
    try history.appendJsonString(&out, alloc, old_content);
    try out.appendSlice(alloc, ",\"new\":");
    try history.appendJsonString(&out, alloc, new_content);
    try out.appendSlice(alloc, "}</script><script type=\"module\">" ++ diff_page_js ++
        "</script></body></html>");
    return try out.toOwnedSlice(alloc);
}

/// Maps a library-relative file path back to its clean URL: the inverse
/// of `relFromPath` for pages (`index.html` is `/`, `.html` drops).
fn relToPagePath(alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
    std.debug.assert(rel.len > 0);
    std.debug.assert(!std.fs.path.isAbsolute(rel));
    if (std.mem.eql(u8, rel, "index.html")) return try alloc.dupe(u8, "/");
    if (std.mem.endsWith(u8, rel, ".html")) {
        return try std.fmt.allocPrint(alloc, "/{s}", .{rel[0 .. rel.len - ".html".len]});
    }
    return try std.fmt.allocPrint(alloc, "/{s}", .{rel});
}

/// Appends `s` with the four HTML-significant characters replaced by
/// entities, for embedding untrusted text in element content or a
/// double-quoted attribute.
fn appendHtmlEscaped(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        '"' => try out.appendSlice(alloc, "&quot;"),
        else => try out.append(alloc, c),
    };
}

/// Inserts `payload` immediately before the LAST `</body>` in `html`, or
/// appends it at the end when there is no `</body>` at all. Caller owns
/// the returned buffer.
pub fn injectAtBodyEnd(alloc: std.mem.Allocator, html: []const u8, payload: []const u8) ![]u8 {
    const at = std.mem.lastIndexOf(u8, html, "</body>") orelse html.len;
    std.debug.assert(at <= html.len);
    var out = try alloc.alloc(u8, html.len + payload.len);
    @memcpy(out[0..at], html[0..at]);
    @memcpy(out[at .. at + payload.len], payload);
    @memcpy(out[at + payload.len ..], html[at..]);
    std.debug.assert(out.len == html.len + payload.len);
    return out;
}

/// Inserts the reload `snippet` before the last `</body>` (see
/// `injectAtBodyEnd`).
pub fn injectSnippet(alloc: std.mem.Allocator, html: []const u8) ![]u8 {
    return injectAtBodyEnd(alloc, html, snippet);
}

/// Folds the library tree's shape (path, mtime, size of every file) into a
/// single `u64` so the scanner can detect "something changed" with one
/// cheap comparison instead of diffing a snapshot. `.git`/dot directories
/// are pruned from the walk entirely (not just skipped file-by-file); this
/// mirrors `index.zig`'s `collectItems`, which prunes the same way for the
/// same reason. `templates/` is deliberately NOT pruned here (unlike
/// `collectItems`): a template edit should still trigger a reload.
///
/// NOTE: the brief's reference signature takes a bare `std.fs.Dir`; this
/// std has no `std.fs.Dir` at all anymore (`std.fs` is just path helpers),
/// only `std.Io.Dir`, whose directory operations all require the `io`
/// capability. `root_dir`/`io` here are the direct analogue.
pub fn treeSignature(root_dir: std.Io.Dir, io: std.Io) u64 {
    var h = std.hash.Wyhash.init(0);
    var walker = root_dir.walkSelectively(std.heap.page_allocator) catch return 0; // no walk, no reload; serving is unaffected
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            const is_dot = entry.basename.len > 0 and entry.basename[0] == '.';
            if (!is_dot) walker.enter(io, entry) catch {}; // unreadable subtree degrades to "unchanged"
            continue;
        }
        if (entry.kind != .file) continue;
        // The root index.html is generated (by us, on this very signal);
        // watching it would make auto-indexing self-triggering.
        if (std.mem.eql(u8, entry.path, "index.html")) continue;
        const st = entry.dir.statFile(io, entry.basename, .{}) catch continue; // racing deletes are fine; the next scan settles
        h.update(entry.path);
        h.update(std.mem.asBytes(&st.mtime.nanoseconds));
        h.update(std.mem.asBytes(&st.size));
    }
    return h.final();
}

/// Live SSE clients (accepted `/__reload` connections) and the mutex
/// guarding them. Streams are stored by value (a `Stream` is just a
/// copyable fd wrapper); they are registered from a `handleConn` whose
/// per-connection arena is torn down as soon as that function returns, so
/// this list is the only thing keeping them alive. It grows and shrinks
/// (via `registerClient`/`broadcast`'s `swapRemove`) for as long as
/// `atelier serve` runs, driven by connections that can overlap with each
/// other, so like the per-connection arenas in `handleConn`, it must be
/// backed by an allocator that actually reclaims freed memory rather than
/// only the most recent allocation; `std.heap.page_allocator` is used
/// directly for that reason (never a connection's own arena, and never a
/// single shared arena either).
///
/// NOTE: the brief's reference code guards this with a `std.Thread.Mutex`;
/// this std has no such type (grepping the whole `std/Thread*` tree turns
/// up nothing named `Mutex`). The only blocking mutex left standing is
/// `std.Io.Mutex`, whose `lock`/`unlock` take the `io` capability like
/// everything else in this codebase's networking/fs layer, so that's what
/// guards `clients` here instead.
var clients: std.ArrayList(net.Stream) = .empty;
var clients_mu: std.Io.Mutex = .init;

/// Registers `stream` as a live SSE client. Returns `false` (registration
/// failed, caller should close the connection) only on allocation failure
/// or a cancellation of the mutex lock; both are vanishingly rare.
fn registerClient(io: std.Io, stream: net.Stream) bool {
    clients_mu.lock(io) catch return false;
    defer clients_mu.unlock(io);
    clients.append(std.heap.page_allocator, stream) catch return false;
    return true;
}

/// Sends one `data: reload\n\n` SSE event to every registered client.
/// A client whose write fails (browser tab closed, pipe reset) is closed
/// and dropped from `clients` via `swapRemove`; the loop deliberately does
/// NOT advance `i` after a drop, since `swapRemove` moves the last element
/// into slot `i` and that element still needs its turn.
fn broadcast(io: std.Io) void {
    clients_mu.lock(io) catch return;
    defer clients_mu.unlock(io);
    var i: usize = 0;
    while (i < clients.items.len) {
        const s = clients.items[i];
        var buf: [32]u8 = undefined;
        var w = s.writer(io, &buf);
        const sent = blk: {
            w.interface.writeAll("data: reload\n\n") catch break :blk false;
            w.interface.flush() catch break :blk false;
            break :blk true;
        };
        if (sent) {
            i += 1;
        } else {
            s.close(io);
            _ = clients.swapRemove(i);
        }
    }
}

/// Regenerates the library's `index.html`. Best effort: on any failure
/// the stale index keeps serving, which beats a crashed scanner. Backed
/// by a fresh page-allocator arena per call, for the same reclamation
/// reason as `handleConn`.
fn regenerateIndex(io: std.Io, lib: library.Library) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Re-resolve the library so a manifest or themes/ edit (including an
    // editor save) recolors the index on the next scan tick without a
    // restart; the startup snapshot is only the fallback.
    const fresh: library.Library = library.resolve(a, io, .{
        .explicit = lib.root,
        .start_dir = "/",
        .config_path = "/nonexistent",
    }) catch lib;
    // Serialized and atomic: the scanner and the MCP reindex tool can
    // both regenerate, and a GET of index.html mid-write must see the
    // old ledger or the new one, never a truncated file.
    library.write_mu.lock(io) catch return;
    defer library.write_mu.unlock(io);
    const page = index.generate(a, io, fresh) catch return;
    const dest = std.fs.path.join(a, &.{ lib.root, "index.html" }) catch return;
    library.writeFileAtomic(io, a, dest, page) catch {};
}

/// Polls `treeSignature` every 500ms; on change, regenerates the index
/// (see `regenerateIndex`) and broadcasts a reload event, in that order,
/// so refreshed tabs fetch the new ledger. Spawned once from `run` (only
/// when reload is enabled) and never returns; a failure to open the root
/// just ends the thread quietly (no reload or auto-index, but the server
/// itself is unaffected).
///
/// NOTE: the brief's reference loop sleeps via `std.Thread.sleep`; this std
/// has no such function either (only `std.Io.sleep(io, duration, clock)`),
/// so sleeping is threaded through `io` like everything else here.
fn scanLoop(io: std.Io, lib: library.Library) void {
    var dir = std.Io.Dir.openDirAbsolute(io, lib.root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var last = treeSignature(dir, io);
    while (true) {
        std.Io.sleep(io, .fromMilliseconds(500), .awake) catch return;
        const now_sig = treeSignature(dir, io);
        if (now_sig != last) {
            last = now_sig;
            regenerateIndex(io, lib);
            broadcast(io);
        }
    }
}

const t = std.testing;

// `mapPath`'s `.file` result is heap-allocated (see its doc comment); the
// brief's own note flags that leaving these unfreed trips the
// leak-checking `t.allocator`, so each case here is freed after the
// assertion instead of inlining the `try mapPath(...)).file` expression.
test "mapPath basics" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "/", .want = "index.html" },
        .{ .in = "/foo", .want = "foo.html" },
        .{ .in = "/advisory/one", .want = "advisory/one.html" },
        .{ .in = "/logo.png", .want = "logo.png" },
        .{ .in = "/foo?x=1", .want = "foo.html" },
    };
    for (cases) |c| {
        const route = try mapPath(t.allocator, c.in);
        defer t.allocator.free(route.file);
        try t.expectEqualStrings(c.want, route.file);
    }
}

test "mapPath routes /mcp exactly, with or without a query" {
    try t.expect((try mapPath(t.allocator, "/mcp")) == .mcp);
    try t.expect((try mapPath(t.allocator, "/mcp?x=1")) == .mcp);
    // Negative space: near-misses are ordinary files, never the endpoint.
    const near_misses = [_][]const u8{ "/mcpx", "/MCP", "/mcp/extra", "/mcp.html" };
    for (near_misses) |target| {
        const route = try mapPath(t.allocator, target);
        try t.expect(route == .file);
        t.allocator.free(route.file);
    }
}

test "bodyCapFor gives the theme routes their small cap and mcp its big one" {
    try t.expectEqual(save_body_bytes_max, bodyCapFor(.theme_save));
    try t.expectEqual(save_body_bytes_max, bodyCapFor(.theme_apply));
    try t.expectEqual(mcp_body_bytes_max, bodyCapFor(.mcp));
}

test "headerHasExpectContinue scans case-insensitively" {
    try t.expect(headerHasExpectContinue("POST /mcp HTTP/1.1\r\nExpect: 100-continue\r\n\r\n"));
    try t.expect(headerHasExpectContinue("POST /mcp HTTP/1.1\r\nexpect: 100-Continue\r\n\r\n"));
    try t.expect(!headerHasExpectContinue("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n"));
    // Negative space: the token in a header value other than Expect.
    try t.expect(!headerHasExpectContinue("POST /x HTTP/1.1\r\nX-Note: 100-continue\r\n\r\n"));
}

test "mapPath reload and traversal" {
    try t.expect((try mapPath(t.allocator, "/__reload")) == .reload);
    try t.expect((try mapPath(t.allocator, "/../etc/passwd")) == .bad);
    try t.expect((try mapPath(t.allocator, "/a/../../b")) == .bad);
    try t.expect((try mapPath(t.allocator, "/a\\b")) == .bad);
}

test "mapPath snapshot routes pin a sha and keep clean-URL rules" {
    const cases = [_]struct { in: []const u8, sha: []const u8, rel: []const u8 }{
        .{ .in = "/@abc1234/foo", .sha = "abc1234", .rel = "foo.html" },
        .{ .in = "/@abc1234/", .sha = "abc1234", .rel = "index.html" },
        .{ .in = "/@abc1234", .sha = "abc1234", .rel = "index.html" },
        .{ .in = "/@abc1234/css/site.css", .sha = "abc1234", .rel = "css/site.css" },
        .{ .in = "/@abc1234/a/b?x=1", .sha = "abc1234", .rel = "a/b.html" },
        .{
            .in = "/@0123456789abcdef0123456789abcdef01234567/p",
            .sha = "0123456789abcdef0123456789abcdef01234567",
            .rel = "p.html",
        },
    };
    for (cases) |c| {
        const route = try mapPath(t.allocator, c.in);
        try t.expect(route == .snapshot);
        defer t.allocator.free(route.snapshot.sha);
        defer t.allocator.free(route.snapshot.rel);
        try t.expectEqualStrings(c.sha, route.snapshot.sha);
        try t.expectEqualStrings(c.rel, route.snapshot.rel);
    }
}

test "mapPath rejects snapshot targets that are not commit shas" {
    // Negative space: short, non-hex, empty sha, traversal inside a pin.
    try t.expect((try mapPath(t.allocator, "/@abc123/x")) == .bad);
    try t.expect((try mapPath(t.allocator, "/@zzz9999/x")) == .bad);
    try t.expect((try mapPath(t.allocator, "/@/x")) == .bad);
    try t.expect((try mapPath(t.allocator, "/@abc1234/../x")) == .bad);
}

test "mapPath history routes normalize the page path" {
    const cases = [_]struct { in: []const u8, rel: []const u8 }{
        .{ .in = "/__history/foo", .rel = "foo.html" },
        .{ .in = "/__history/advisory/one", .rel = "advisory/one.html" },
        .{ .in = "/__history/logo.png", .rel = "logo.png" },
        .{ .in = "/__history/", .rel = "index.html" },
    };
    for (cases) |c| {
        const route = try mapPath(t.allocator, c.in);
        try t.expect(route == .history);
        defer t.allocator.free(route.history);
        try t.expectEqualStrings(c.rel, route.history);
    }
    try t.expect((try mapPath(t.allocator, "/__history/../x")) == .bad);
}

test "mapPath diff routes carry rel, from, and to in either order" {
    const cases = [_]struct { in: []const u8, rel: []const u8, from: []const u8, to: []const u8 }{
        .{ .in = "/__diff/foo?from=abc1234&to=current", .rel = "foo.html", .from = "abc1234", .to = "current" },
        .{ .in = "/__diff/a/b?to=def5678&from=abc1234", .rel = "a/b.html", .from = "abc1234", .to = "def5678" },
        .{ .in = "/__diff/foo?from=current&to=abc1234", .rel = "foo.html", .from = "current", .to = "abc1234" },
    };
    for (cases) |c| {
        const route = try mapPath(t.allocator, c.in);
        try t.expect(route == .diff);
        defer t.allocator.free(route.diff.rel);
        defer t.allocator.free(route.diff.from);
        defer t.allocator.free(route.diff.to);
        try t.expectEqualStrings(c.rel, route.diff.rel);
        try t.expectEqualStrings(c.from, route.diff.from);
        try t.expectEqualStrings(c.to, route.diff.to);
    }
}

test "mapPath rejects diff routes without a valid version pair" {
    // Negative space: no query, one side missing, non-sha refs, traversal.
    try t.expect((try mapPath(t.allocator, "/__diff/foo")) == .bad);
    try t.expect((try mapPath(t.allocator, "/__diff/foo?from=abc1234")) == .bad);
    try t.expect((try mapPath(t.allocator, "/__diff/foo?to=current")) == .bad);
    try t.expect((try mapPath(t.allocator, "/__diff/foo?from=nope&to=current")) == .bad);
    try t.expect((try mapPath(t.allocator, "/__diff/foo?from=abc1234&to=Current")) == .bad);
    try t.expect((try mapPath(t.allocator, "/__diff/../x?from=abc1234&to=current")) == .bad);
}

test "mapPath routes the vendored bundle and nothing else under __assets" {
    try t.expect((try mapPath(t.allocator, "/__assets/diffs.js")) == .diffs_bundle);
    const other = try mapPath(t.allocator, "/__assets/other.js");
    try t.expect(other == .file);
    t.allocator.free(other.file);
}

test "mapPath theme routes" {
    try t.expect((try mapPath(t.allocator, "/__theme")) == .theme_editor);
    try t.expect((try mapPath(t.allocator, "/__theme/data")) == .theme_data);
    try t.expect((try mapPath(t.allocator, "/__theme/save")) == .theme_save);
    try t.expect((try mapPath(t.allocator, "/__theme/apply")) == .theme_apply);
}

test "parseContentLength reads the header case-insensitively" {
    const headers = "POST /__theme/save HTTP/1.1\r\nHost: x\r\ncontent-length: 42\r\n\r\n";
    try t.expectEqual(@as(?usize, 42), parseContentLength(headers));
    try t.expectEqual(@as(?usize, null), parseContentLength("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try t.expectEqual(@as(?usize, null), parseContentLength("POST / HTTP/1.1\r\nContent-Length: nope\r\n\r\n"));
}

test "theme chip links the served index to the editor and hides in print" {
    try t.expect(std.mem.indexOf(u8, theme_chip_snippet, "href=\"/__theme\"") != null);
    try t.expect(std.mem.indexOf(u8, theme_chip_snippet, "id=\"atelier-theme\"") != null);
    try t.expect(std.mem.indexOf(u8, theme_chip_snippet, "@media print") != null);
}

test "theme editor asset wires data, save, and the CSS variable contract" {
    try t.expect(std.mem.indexOf(u8, theme_editor_html, "/__theme/data") != null);
    try t.expect(std.mem.indexOf(u8, theme_editor_html, "/__theme/save") != null);
    for ([_][]const u8{ "--paper", "--ink", "--ink-3", "--accent", "--rule", "--display", "--mono" }) |v| {
        try t.expect(std.mem.indexOf(u8, theme_editor_html, v) != null);
    }
    // The preview is the library's own index, same origin.
    try t.expect(std.mem.indexOf(u8, theme_editor_html, "<iframe") != null);
    // A way back out of the editor.
    try t.expect(std.mem.indexOf(u8, theme_editor_html, "href=\"/\"") != null);
    // The preview strips the injected theme chip, or clicking it would
    // open the editor inside its own preview.
    try t.expect(std.mem.indexOf(u8, theme_editor_html, "atelier-theme") != null);
    // Adopting a theme is one click, not a manifest edit.
    try t.expect(std.mem.indexOf(u8, theme_editor_html, "/__theme/apply") != null);
    // A theme file from anywhere can be imported into the editor.
    try t.expect(std.mem.indexOf(u8, theme_editor_html, "type=\"file\"") != null);
    try t.expect(std.mem.indexOf(u8, theme_editor_html, "id=\"import\"") != null);
    // Self-contained: no external requests from the editor itself.
    try t.expect(std.mem.indexOf(u8, theme_editor_html, "http") == null or
        std.mem.indexOf(u8, theme_editor_html, "src=\"http") == null);
}

test "queryParam finds values by name and misses cleanly" {
    try t.expectEqualStrings("abc", queryParam("from=abc&to=xyz", "from").?);
    try t.expectEqualStrings("xyz", queryParam("from=abc&to=xyz", "to").?);
    try t.expect(queryParam("from=abc", "to") == null);
    try t.expect(queryParam("", "from") == null);
    try t.expect(queryParam("fromage=abc", "from") == null);
}

test "contentType" {
    try t.expectEqualStrings("text/html; charset=utf-8", contentType("x.html"));
    try t.expectEqualStrings("image/svg+xml", contentType("a/b.svg"));
    try t.expectEqualStrings("application/pdf", contentType("p.pdf"));
    try t.expectEqualStrings("application/octet-stream", contentType("noext"));
}

test "injectAtBodyEnd inserts any payload before the last body close" {
    const out = try injectAtBodyEnd(t.allocator, "<body><p>x</p></body>", "<i>y</i>");
    defer t.allocator.free(out);
    try t.expectEqualStrings("<body><p>x</p><i>y</i></body>", out);
}

test "home snippet links to the index and hides in print" {
    try t.expect(std.mem.indexOf(u8, home_snippet, "href=\"/\"") != null);
    try t.expect(std.mem.indexOf(u8, home_snippet, "id=\"atelier-home\"") != null);
    try t.expect(std.mem.indexOf(u8, home_snippet, "@media print") != null);
}

test "history snippet wires the fetch, snapshot links, and print hiding" {
    try t.expect(std.mem.indexOf(u8, history_snippet, "id=\"atelier-history\"") != null);
    try t.expect(std.mem.indexOf(u8, history_snippet, "id=\"atelier-history-panel\"") != null);
    try t.expect(std.mem.indexOf(u8, history_snippet, "'/__history'") != null);
    try t.expect(std.mem.indexOf(u8, history_snippet, "'/@'+") != null);
    try t.expect(std.mem.indexOf(u8, history_snippet, "@media print") != null);
    try t.expect(std.mem.indexOf(u8, history_snippet, "location.pathname") != null);
}

test "history snippet carries the diff picker" {
    try t.expect(std.mem.indexOf(u8, history_snippet, "atelier-dfrom") != null);
    try t.expect(std.mem.indexOf(u8, history_snippet, "atelier-dto") != null);
    try t.expect(std.mem.indexOf(u8, history_snippet, "atelier-diff-go") != null);
    try t.expect(std.mem.indexOf(u8, history_snippet, "'/__diff'") != null);
    try t.expect(std.mem.indexOf(u8, history_snippet, "'current'") != null);
}

test "renderDiffPage embeds both versions and wires the bundle" {
    const page = try renderDiffPage(t.allocator, "foo.html", "abc1234", "current", "<p>old</p>", "<p>new</p>");
    defer t.allocator.free(page);
    try t.expect(std.mem.indexOf(u8, page, "'/__assets/diffs.js'") != null);
    try t.expect(std.mem.indexOf(u8, page, "id=\"diff-data\"") != null);
    // Contents are embedded JSON-escaped, angle brackets defused.
    try t.expect(std.mem.indexOf(u8, page, "\\u003cp\\u003eold\\u003c/p\\u003e") != null);
    try t.expect(std.mem.indexOf(u8, page, "\\u003cp\\u003enew\\u003c/p\\u003e") != null);
    try t.expect(std.mem.indexOf(u8, page, "abc1234") != null);
    try t.expect(std.mem.indexOf(u8, page, "current") != null);
    // The back link is the page's clean URL.
    try t.expect(std.mem.indexOf(u8, page, "href=\"/foo\"") != null);
    // Raw page content must never appear unescaped.
    try t.expect(std.mem.indexOf(u8, page, "<p>old</p>") == null);
}

test "renderDiffPage back link for the index page is the root" {
    const page = try renderDiffPage(t.allocator, "index.html", "abc1234", "current", "a", "b");
    defer t.allocator.free(page);
    try t.expect(std.mem.indexOf(u8, page, "href=\"/\"") != null);
}

test "injectSnippet before closing body" {
    const out = try injectSnippet(t.allocator, "<body><p>x</p></body>");
    defer t.allocator.free(out);
    try t.expectEqualStrings("<body><p>x</p><script>new EventSource('/__reload').onmessage=()=>location.reload();</script></body>", out);
}

test "injectSnippet appends when no body tag" {
    const out = try injectSnippet(t.allocator, "<p>x</p>");
    defer t.allocator.free(out);
    try t.expect(std.mem.endsWith(u8, out, "</script>"));
}

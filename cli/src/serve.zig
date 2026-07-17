const std = @import("std");
const library = @import("library.zig");
const index = @import("index.zig");
const history = @import("history.zig");

pub const Route = union(enum) {
    file: []const u8,
    snapshot: Snapshot,
    history: []const u8,
    reload,
    bad,

    /// A whole-tree time-travel view: `rel` resolved against the library
    /// as of commit `sha` instead of the working tree.
    pub const Snapshot = struct { sha: []const u8, rel: []const u8 };
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
    if (std.mem.indexOfScalar(u8, target, '?')) |q| target = target[0..q];
    if (std.mem.eql(u8, target, "/__reload")) return .reload;
    if (std.mem.indexOfScalar(u8, target, '\\') != null) return .bad;
    if (!std.mem.startsWith(u8, target, "/")) return .bad;
    var it = std.mem.splitScalar(u8, target[1..], '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return .bad;
    if (std.mem.startsWith(u8, target, "/__history/")) {
        return .{ .history = try relFromPath(alloc, target["/__history".len..]) };
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
        const th = std.Thread.spawn(.{}, handleConn, .{ io, lib.root, stream, reload }) catch {
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
fn handleConn(io: std.Io, root: []const u8, stream: net.Stream, reload: bool) void {
    // Every path closes `stream` except a successfully-registered SSE
    // client (Task 7): that connection has to stay open so the scanner can
    // push events down it later, well after this function has returned.
    var keep_open = false;
    defer if (!keep_open) stream.close(io);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var buf: [4096]u8 = undefined;
    var iov: [1][]u8 = .{&buf};
    const n = stream.read(io, &iov) catch return;
    if (n == 0) return;
    const req = buf[0..n];
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
    var parts = std.mem.splitScalar(u8, req[0..line_end], ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    if (!std.mem.eql(u8, method, "GET")) return writeBody(stream, io, "405 Method Not Allowed", "text/plain", "GET only\n");

    const route = mapPath(a, target) catch return;
    switch (route) {
        .bad => return writeBody(stream, io, "400 Bad Request", "text/plain", "bad path\n"),
        .history => |rel| {
            const commits = history.pageLog(a, io, root, rel);
            const json = history.renderJson(a, commits) catch return;
            return writeBody(stream, io, "200 OK", "application/json", json);
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
                // regenerated file history is noise, not authorship).
                if (!std.mem.eql(u8, rel, "index.html")) {
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
    var send_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &send_buf);
    w.interface.print(
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        .{ status, ctype, body.len },
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
pub const history_snippet = "<style>@media print{#atelier-history,#atelier-history-panel{display:none}}" ++
    "#atelier-history{position:fixed;top:14px;right:14px;z-index:9999;display:none;" ++
    "font:600 10px/1 ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase;" ++
    "color:#fff;background:rgba(20,18,15,.78);padding:7px 11px;border-radius:2px;cursor:pointer}" ++
    "#atelier-history-panel{position:fixed;top:40px;right:14px;z-index:9999;display:none;" ++
    "max-height:60vh;overflow:auto;min-width:260px;background:rgba(20,18,15,.92);" ++
    "font:11px/1.5 ui-monospace,monospace;padding:6px 0;border-radius:2px}" ++
    "#atelier-history-panel a{display:block;padding:5px 12px;color:#fff;text-decoration:none;white-space:nowrap}" ++
    "#atelier-history-panel a:hover{background:rgba(255,255,255,.12)}" ++
    "#atelier-history-panel a.now{opacity:.55}</style>" ++
    "<div id=\"atelier-history\"></div><div id=\"atelier-history-panel\"></div>" ++
    "<script>(()=>{" ++
    "const m=location.pathname.match(/^\\/@([0-9a-fA-F]{7,40})(\\/.*)?$/);" ++
    "const pin=m?m[1]:null;const path=m?(m[2]||'/'):location.pathname;" ++
    "const chip=document.getElementById('atelier-history');" ++
    "const panel=document.getElementById('atelier-history-panel');" ++
    "fetch('/__history'+path).then(r=>r.json()).then(list=>{" ++
    "if(!list.length&&!pin)return;" ++
    "chip.textContent=pin?'\\u23f1 '+pin:'history';chip.style.display='block';" ++
    "const add=(href,label,now)=>{const a=document.createElement('a');" ++
    "a.href=href;a.textContent=label;if(now)a.className='now';panel.appendChild(a);};" ++
    "add(path,'current',!pin);" ++
    "list.forEach(c=>add('/@'+c.sha+path,c.date+'  '+c.subject+'  '+c.sha,pin===c.sha));" ++
    "chip.onclick=()=>{panel.style.display=panel.style.display==='block'?'none':'block';};" ++
    "}).catch(()=>{});" ++
    "})();</script>";

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
    const page = index.generate(a, io, lib) catch return;
    const dest = std.fs.path.join(a, &.{ lib.root, "index.html" }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = page }) catch {};
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

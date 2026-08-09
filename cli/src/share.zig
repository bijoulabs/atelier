const std = @import("std");
const index = @import("index.zig");
const library = @import("library.zig");
const pdf = @import("pdf.zig");
const serve = @import("serve.zig");

/// The visible provenance stamp injected into a share copy: fixed
/// bottom-right mono microtype, brand-neutral, prints on the PDF.
pub fn stampSnippet(alloc: std.mem.Allocator, firm: []const u8, recipient: ?[]const u8, date: []const u8) ![]u8 {
    const style = "position:fixed;bottom:10px;right:12px;font:500 7px/1.4 ui-monospace,monospace;" ++
        "letter-spacing:.12em;text-transform:uppercase;color:#8a857b";
    if (recipient) |who| {
        return std.fmt.allocPrint(
            alloc,
            "<div style=\"{s}\">Prepared for {s} by {s} &middot; {s}</div>",
            .{ style, who, firm, date },
        );
    }
    return std.fmt.allocPrint(alloc, "<div style=\"{s}\">{s} &middot; {s}</div>", .{ style, firm, date });
}

/// One `shares.log` line: tab-separated date, library git revision, page,
/// recipient ("-" when none), output basename, and, when the share came
/// through the server, who submitted it. Local CLI shares pass null and
/// keep the original five columns; nothing parses this file, it is a
/// human ledger, so old and new lines coexist. Trailing newline included.
pub fn logLine(
    alloc: std.mem.Allocator,
    date: []const u8,
    rev: []const u8,
    rel: []const u8,
    recipient: ?[]const u8,
    out_name: []const u8,
    identity: ?[]const u8,
) ![]u8 {
    if (identity) |who| {
        // The identity label is sanitized at its source (identity.label);
        // a tab here would silently grow a seventh column.
        std.debug.assert(std.mem.indexOfAny(u8, who, "\t\n") == null);
        return std.fmt.allocPrint(alloc, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            date, rev, rel, recipient orelse "-", out_name, who,
        });
    }
    return std.fmt.allocPrint(alloc, "{s}\t{s}\t{s}\t{s}\t{s}\n", .{ date, rev, rel, recipient orelse "-", out_name });
}

/// Appends one line to `<root>/shares.log`, creating it when absent.
/// Read-whole-then-rewrite, byte-identical to what `atelier share` has
/// always produced; concurrent server writers are serialized by
/// `library.write_mu`, which the server-side caller holds. An O_APPEND
/// open would also work and is a candidate follow-up, but matching the
/// CLI exactly keeps this extraction behavior-preserving.
pub fn appendLog(alloc: std.mem.Allocator, io: std.Io, root: []const u8, line: []const u8) !void {
    std.debug.assert(line.len > 0);
    std.debug.assert(line[line.len - 1] == '\n');
    const log_abs = try std.fs.path.join(alloc, &.{ root, "shares.log" });
    const existing = std.Io.Dir.cwd().readFileAlloc(io, log_abs, alloc, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => try alloc.dupe(u8, ""),
        else => return e,
    };
    const combined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ existing, line });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log_abs, .data = combined });
}

pub const ShareResult = struct {
    /// The ledger line that was appended, for the caller to echo.
    log_line: []u8,
};

/// The whole share pass for one page: read, stamp with provenance,
/// render the stamped temp to `out_abs`, delete the temp, and record the
/// share in `<root>/shares.log`. Extracted from `atelier share` so the
/// CLI and the MCP share_document tool cannot drift; the caller decides
/// `out_abs` (cwd for the CLI, `<root>/shares/` for the server) and
/// passes `identity` only when the share came over the wire. On
/// `error.ChromiumFailed`, `failure.*` names the binary and exit code.
pub fn sharePage(
    alloc: std.mem.Allocator,
    io: std.Io,
    lib: library.Library,
    page_rel: []const u8,
    recipient: ?[]const u8,
    out_abs: []const u8,
    identity: ?[]const u8,
    failure: *?pdf.Failure,
) !ShareResult {
    std.debug.assert(!std.fs.path.isAbsolute(page_rel));
    std.debug.assert(std.mem.endsWith(u8, page_rel, ".html"));
    std.debug.assert(std.fs.path.isAbsolute(out_abs));

    const page_abs = try std.fs.path.join(alloc, &.{ lib.root, page_rel });
    const html = std.Io.Dir.cwd().readFileAlloc(io, page_abs, alloc, .limited(4 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return error.PageNotFound,
        else => return e,
    };

    const now_sec = std.Io.Clock.now(.real, io).toSeconds();
    const date = try isoDate(alloc, now_sec);
    const stamp = try stampSnippet(alloc, lib.name, recipient, date);
    const stamped = try serve.injectAtBodyEnd(alloc, html, stamp);

    const page_dir = std.fs.path.dirname(page_abs) orelse lib.root;
    const stem = blk: {
        const base = std.fs.path.basename(page_rel);
        break :blk base[0 .. base.len - ".html".len];
    };
    const temp_abs = try std.fmt.allocPrint(alloc, "{s}/.{s}-share.html", .{ page_dir, stem });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp_abs, .data = stamped });
    defer std.Io.Dir.cwd().deleteFile(io, temp_abs) catch {}; // best effort; dot-files never index

    try pdf.render(alloc, io, temp_abs, out_abs, failure);

    // Library revision for reproducibility; "-" when git is unavailable.
    const rev = blk: {
        const run = std.process.run(alloc, io, .{
            .argv = &.{ "git", "-C", lib.root, "rev-parse", "--short", "HEAD" },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch break :blk try alloc.dupe(u8, "-");
        const trimmed = std.mem.trim(u8, run.stdout, " \t\r\n");
        break :blk if (trimmed.len > 0) trimmed else try alloc.dupe(u8, "-");
    };

    const line = try logLine(alloc, date, rev, page_rel, recipient, std.fs.path.basename(out_abs), identity);
    try appendLog(alloc, io, lib.root, line);
    return .{ .log_line = line };
}

/// Formats epoch seconds as an ISO date (UTC).
pub fn isoDate(alloc: std.mem.Allocator, epoch_sec: i64) ![]u8 {
    const d = index.dateParts(epoch_sec);
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(d.year)), d.month, d.day });
}

const t = std.testing;

test "stampSnippet carries recipient, firm, and date" {
    const s = try stampSnippet(t.allocator, "Acme, Inc", "Globex", "2026-07-12");
    defer t.allocator.free(s);
    try t.expect(std.mem.indexOf(u8, s, "Prepared for Globex by Acme, Inc &middot; 2026-07-12") != null);
    try t.expect(std.mem.indexOf(u8, s, "position:fixed") != null);

    const bare = try stampSnippet(t.allocator, "Acme, Inc", null, "2026-07-12");
    defer t.allocator.free(bare);
    try t.expect(std.mem.indexOf(u8, bare, "Prepared for") == null);
    try t.expect(std.mem.indexOf(u8, bare, "Acme, Inc &middot; 2026-07-12") != null);
}

test "logLine is tab-separated with dash placeholders" {
    const l = try logLine(t.allocator, "2026-07-12", "abc1234", "advisory/memo.html", null, "memo.pdf", null);
    defer t.allocator.free(l);
    try t.expectEqualStrings("2026-07-12\tabc1234\tadvisory/memo.html\t-\tmemo.pdf\n", l);
}

test "logLine with an identity appends a sixth column" {
    const l = try logLine(t.allocator, "2026-07-12", "abc1234", "memo.html", "Globex", "memo-Globex.pdf", "alice@example.com from laptop");
    defer t.allocator.free(l);
    try t.expectEqualStrings(
        "2026-07-12\tabc1234\tmemo.html\tGlobex\tmemo-Globex.pdf\talice@example.com from laptop\n",
        l,
    );
}

test "appendLog creates the ledger and preserves earlier lines" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);

    // Arena like appendLog's real callers; it does not free its scratch.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    try appendLog(arena_state.allocator(), t.io, root, "first line\n");
    try appendLog(arena_state.allocator(), t.io, root, "second line\n");

    const log = try tmp.dir.readFileAlloc(t.io, "shares.log", t.allocator, .limited(4096));
    defer t.allocator.free(log);
    try t.expectEqualStrings("first line\nsecond line\n", log);
}

test "sharePage stamps, renders, and records the share" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{
        .sub_path = "memo.html",
        .data = "<html><body><h1>Memo</h1></body></html>",
    });

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lib: @import("library.zig").Library = .{ .root = root, .name = "Test Firm", .tag = "", .port = 8789 };
    const out_abs = try std.fs.path.join(a, &.{ root, "out.pdf" });

    var failure: ?@import("pdf.zig").Failure = null;
    const result = sharePage(a, t.io, lib, "memo.html", "Globex", out_abs, "alice@example.com from laptop", &failure) catch |e| switch (e) {
        // Machines without a Chromium still exercise everything up to the
        // render boundary via the tests above; skip only the full pass.
        error.NoChromium => return error.SkipZigTest,
        else => return e,
    };
    try t.expect(std.mem.indexOf(u8, result.log_line, "\tmemo.html\tGlobex\tout.pdf\talice@example.com from laptop\n") != null);

    const rendered = try tmp.dir.readFileAlloc(t.io, "out.pdf", t.allocator, .limited(16 * 1024 * 1024));
    defer t.allocator.free(rendered);
    try t.expect(std.mem.startsWith(u8, rendered, "%PDF"));

    const log = try tmp.dir.readFileAlloc(t.io, "shares.log", t.allocator, .limited(4096));
    defer t.allocator.free(log);
    try t.expectEqualStrings(result.log_line, log);
    // The stamped temp copy must be gone.
    try t.expectError(error.FileNotFound, tmp.dir.readFileAlloc(t.io, ".memo-share.html", t.allocator, .limited(64)));
}

test "isoDate formats UTC" {
    const s = try isoDate(t.allocator, 1783778520); // 2026-07-11 14:02 UTC
    defer t.allocator.free(s);
    try t.expectEqualStrings("2026-07-11", s);
}

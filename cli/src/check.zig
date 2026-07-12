const std = @import("std");
const library = @import("library.zig");
const index = @import("index.zig");

/// Severity of a finding: errors fail the check run, warnings inform.
pub const Severity = enum { err, warn };

/// One finding against a page. `message` is owned by the caller.
pub const Finding = struct {
    severity: Severity,
    message: []const u8,
};

/// Frees a finding slice returned by `scanPage`/`checkPage`.
pub fn freeFindings(alloc: std.mem.Allocator, findings: []const Finding) void {
    for (findings) |f| alloc.free(f.message);
    alloc.free(findings);
}

/// Schemes and forms an internal-reference check must ignore.
const external_prefixes = [_][]const u8{ "http://", "https://", "mailto:", "#", "data:", "tel:" };

/// Resolves an `href`/`src` value to a library-relative candidate path
/// per serve's semantics, or null when the reference is external or
/// empty. `page_dir` is the page's library-relative directory ("" for
/// root pages). Query strings and fragments are stripped; a final
/// segment without an extension gets `.html` appended (clean URLs).
/// Caller owns the returned path.
pub fn resolveRef(alloc: std.mem.Allocator, page_dir: []const u8, ref: []const u8) !?[]u8 {
    if (ref.len == 0) return null;
    for (external_prefixes) |p| {
        if (std.mem.startsWith(u8, ref, p)) return null;
    }
    var val = ref;
    if (std.mem.indexOfAny(u8, val, "?#")) |cut| val = val[0..cut];
    if (val.len == 0) return null;

    const rel = if (val[0] == '/')
        try alloc.dupe(u8, val[1..])
    else if (page_dir.len > 0)
        try std.fs.path.join(alloc, &.{ page_dir, val })
    else
        try alloc.dupe(u8, val);
    errdefer alloc.free(rel);

    const last = std.fs.path.basename(rel);
    if (std.mem.indexOfScalar(u8, last, '.') != null) return rel;
    defer alloc.free(rel);
    return try std.fmt.allocPrint(alloc, "{s}.html", .{rel});
}

fn addFinding(alloc: std.mem.Allocator, out: *std.ArrayList(Finding), severity: Severity, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    errdefer alloc.free(msg);
    try out.append(alloc, .{ .severity = severity, .message = msg });
}

/// True when `list` already holds `s` (case-sensitive).
fn contains(list: *const std.ArrayList([]const u8), s: []const u8) bool {
    for (list.items) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// True when `color` (lowercased hex literal including '#') is allowed by
/// the theme: one of the five theme colors or pure black/white.
fn colorAllowed(theme: library.Theme, color: []const u8) bool {
    const allowed = [_][]const u8{
        theme.paper, theme.ink, theme.muted, theme.accent, theme.rule,
        "#fff",      "#ffffff", "#000",      "#000000",
    };
    for (allowed) |a| {
        if (std.ascii.eqlIgnoreCase(a, color)) return true;
    }
    for (theme.palette) |a| {
        if (std.ascii.eqlIgnoreCase(a, color)) return true;
    }
    return false;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Content checks that need no filesystem: title, agent stamp, em dash,
/// palette and font-family warnings. Reference existence lives in
/// `checkPage`, which has the io capability.
pub fn scanPage(alloc: std.mem.Allocator, html: []const u8, theme: library.Theme, cfg: library.CheckConfig) ![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    errdefer {
        for (out.items) |f| alloc.free(f.message);
        out.deinit(alloc);
    }

    if (index.extractTitle(html) == null)
        try addFinding(alloc, &out, .err, "missing or blank <title>", .{});
    if (std.mem.indexOf(u8, html, "name=\"atelier:agent\"") == null)
        try addFinding(alloc, &out, .err, "missing atelier:agent meta tag", .{});
    if (cfg.forbid_em_dash and std.mem.indexOf(u8, html, "\u{2014}") != null)
        try addFinding(alloc, &out, .err, "contains an em dash", .{});

    // A page declaring atelier:brand "custom" is a deliberate sub-brand
    // (e.g. a client's own identity); style warnings do not apply, the
    // structural errors above always do.
    if (std.mem.indexOf(u8, html, "name=\"atelier:brand\" content=\"custom\"") != null)
        return out.toOwnedSlice(alloc);

    var flagged_colors: std.ArrayList([]const u8) = .empty;
    defer flagged_colors.deinit(alloc);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '#')) |at| {
        i = at + 1;
        var j = i;
        while (j < html.len and isHexDigit(html[j])) j += 1;
        const digits = j - i;
        if (digits != 3 and digits != 6) continue;
        if (j < html.len and (std.ascii.isAlphanumeric(html[j]))) continue;
        const color = html[at..j];
        if (colorAllowed(theme, color)) continue;
        if (contains(&flagged_colors, color)) continue;
        try flagged_colors.append(alloc, color);
        try addFinding(alloc, &out, .warn, "color {s} is outside the theme palette", .{color});
    }

    var flagged_fonts: std.ArrayList([]const u8) = .empty;
    defer flagged_fonts.deinit(alloc);
    i = 0;
    while (std.mem.indexOfPos(u8, html, i, "font-family:")) |at| {
        i = at + "font-family:".len;
        const end = std.mem.indexOfAnyPos(u8, html, i, ";}") orelse html.len;
        var first = html[i..end];
        if (std.mem.indexOfScalar(u8, first, ',')) |c| first = first[0..c];
        first = std.mem.trim(u8, first, " \t\r\n'\"");
        if (first.len == 0) continue;
        if (std.mem.startsWith(u8, first, "var(")) continue; // custom-property reference, not a family
        const in_display = std.ascii.findIgnoreCase(theme.display_font, first) != null;
        const in_mono = std.ascii.findIgnoreCase(theme.mono_font, first) != null;
        if (in_display or in_mono) continue;
        if (contains(&flagged_fonts, first)) continue;
        try flagged_fonts.append(alloc, first);
        try addFinding(alloc, &out, .warn, "font-family '{s}' is outside the theme stacks", .{first});
    }

    return out.toOwnedSlice(alloc);
}

/// Full check of one page: `scanPage` plus internal-reference existence.
/// `rel_path` is library-relative (e.g. "advisory/one.html").
pub fn checkPage(alloc: std.mem.Allocator, io: std.Io, lib: library.Library, rel_path: []const u8, html: []const u8) ![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    errdefer {
        for (out.items) |f| alloc.free(f.message);
        out.deinit(alloc);
    }

    const scanned = try scanPage(alloc, html, lib.theme, lib.check);
    defer alloc.free(scanned); // messages move into out
    try out.appendSlice(alloc, scanned);

    const page_dir = std.fs.path.dirname(rel_path) orelse "";

    var checked: std.ArrayList([]const u8) = .empty;
    defer {
        for (checked.items) |c| alloc.free(c);
        checked.deinit(alloc);
    }

    const attrs = [_][]const u8{ "href=\"", "src=\"" };
    for (attrs) |marker| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, html, i, marker)) |at| {
            const start = at + marker.len;
            const end = std.mem.indexOfScalarPos(u8, html, start, '"') orelse break;
            i = end + 1;
            const ref = html[start..end];
            const rel = (try resolveRef(alloc, page_dir, ref)) orelse continue;
            if (contains(&checked, rel)) {
                alloc.free(rel);
                continue;
            }
            try checked.append(alloc, rel);
            const abs = try std.fs.path.join(alloc, &.{ lib.root, rel });
            defer alloc.free(abs);
            if (std.Io.Dir.cwd().access(io, abs, .{})) |_| {} else |_| {
                try addFinding(alloc, &out, .err, "broken internal reference: {s} (resolved to {s})", .{ ref, rel });
            }
        }
    }

    return out.toOwnedSlice(alloc);
}

const t = std.testing;

test "resolveRef handles root, relative, clean urls, and externals" {
    const cases = [_]struct { dir: []const u8, ref: []const u8, want: ?[]const u8 }{
        .{ .dir = "", .ref = "/advisory/one", .want = "advisory/one.html" },
        .{ .dir = "advisory", .ref = "img/logo.png", .want = "advisory/img/logo.png" },
        .{ .dir = "", .ref = "one?x=1", .want = "one.html" },
        .{ .dir = "", .ref = "https://example.com/x", .want = null },
        .{ .dir = "", .ref = "#section", .want = null },
        .{ .dir = "", .ref = "mailto:x@y.z", .want = null },
        .{ .dir = "", .ref = "data:image/png;base64,xxxx", .want = null },
    };
    for (cases) |c| {
        const got = try resolveRef(t.allocator, c.dir, c.ref);
        defer if (got) |g| t.allocator.free(g);
        if (c.want) |w| {
            try t.expectEqualStrings(w, got.?);
        } else {
            try t.expect(got == null);
        }
    }
}

test "scanPage flags title, stamp, em dash, palette, and fonts" {
    const theme = library.Theme{ .accent = "#9a3b32" };
    const html =
        "<body style=\"color:#123456;font-family:'Comic Sans',cursive\">dash \u{2014} here</body>";
    const findings = try scanPage(t.allocator, html, theme, .{});
    defer freeFindings(t.allocator, findings);
    var errs: usize = 0;
    var warns: usize = 0;
    for (findings) |f| {
        if (f.severity == .err) errs += 1 else warns += 1;
    }
    try t.expectEqual(@as(usize, 3), errs); // title, stamp, em dash
    try t.expectEqual(@as(usize, 2), warns); // color, font
}

test "scanPage skips var() font references" {
    const theme = library.Theme{};
    const html =
        \\<title>V</title><meta name="atelier:agent" content="donna">
        \\<style>h1{font-family:var(--display),serif}</style>
    ;
    const findings = try scanPage(t.allocator, html, theme, .{});
    defer freeFindings(t.allocator, findings);
    try t.expectEqual(@as(usize, 0), findings.len);
}

test "scanPage allows extended palette colors from the theme" {
    const theme = library.Theme{ .palette = &.{ "#4f7d4a", "#B45309" } };
    const html =
        \\<title>P</title><meta name="atelier:agent" content="donna">
        \\<style>.ok{color:#4f7d4a}.warm{color:#b45309}</style>
    ;
    const findings = try scanPage(t.allocator, html, theme, .{});
    defer freeFindings(t.allocator, findings);
    try t.expectEqual(@as(usize, 0), findings.len);
}

test "scanPage exempts custom-brand pages from style warnings only" {
    const theme = library.Theme{};
    const html = "<title>Sub-brand</title><meta name=\"atelier:agent\" content=\"claude\">" ++
        "<meta name=\"atelier:brand\" content=\"custom\">" ++
        "<style>body{color:#123456;font-family:Papyrus,fantasy}</style>" ++
        "em \u{2014} dash still fails";
    const findings = try scanPage(t.allocator, html, theme, .{});
    defer freeFindings(t.allocator, findings);
    try t.expectEqual(@as(usize, 1), findings.len);
    try t.expect(findings[0].severity == .err); // the em dash; no style warnings
}

test "scanPage honors the em dash opt-out" {
    const theme = library.Theme{};
    const html = "<title>D</title><meta name=\"atelier:agent\" content=\"donna\"> a \u{2014} b";
    const strict = try scanPage(t.allocator, html, theme, .{});
    defer freeFindings(t.allocator, strict);
    try t.expectEqual(@as(usize, 1), strict.len);
    const relaxed = try scanPage(t.allocator, html, theme, .{ .forbid_em_dash = false });
    defer freeFindings(t.allocator, relaxed);
    try t.expectEqual(@as(usize, 0), relaxed.len);
}

test "scanPage passes a clean on-brand page" {
    const theme = library.Theme{};
    const html =
        \\<title>Fine</title><meta name="atelier:agent" content="donna">
        \\<style>body{color:#1c1c1c;background:#ffffff;font-family:system-ui,sans-serif}</style>
    ;
    const findings = try scanPage(t.allocator, html, theme, .{});
    defer freeFindings(t.allocator, findings);
    try t.expectEqual(@as(usize, 0), findings.len);
}

test "checkPage reports broken internal references and accepts good ones" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.createDirPath(t.io, "advisory");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "advisory/other.html", .data = "<title>O</title>" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = library.Library{ .root = root, .name = "Acme", .tag = "", .port = 8789 };

    const html =
        \\<title>P</title><meta name="atelier:agent" content="donna">
        \\<a href="/advisory/other">good</a>
        \\<a href="/missing/page">bad</a>
    ;
    const findings = try checkPage(t.allocator, t.io, lib, "advisory/page.html", html);
    defer freeFindings(t.allocator, findings);
    try t.expectEqual(@as(usize, 1), findings.len);
    try t.expect(findings[0].severity == .err);
    try t.expect(std.mem.indexOf(u8, findings[0].message, "/missing/page") != null);
}

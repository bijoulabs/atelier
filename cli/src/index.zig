const std = @import("std");
const library = @import("library.zig");
const template = @import("template.zig");

/// Upper bound on how large a single candidate page is allowed to be when
/// read for title extraction.
const page_bytes_max = 4 * 1024 * 1024;

/// Returns the trimmed contents of the first `<title>...</title>` in
/// `html`, or `null` if there is no title tag or its contents are blank.
pub fn extractTitle(html: []const u8) ?[]const u8 {
    const open = std.mem.indexOf(u8, html, "<title>") orelse return null;
    const rest = html[open + 7 ..];
    const close = std.mem.indexOf(u8, rest, "</title>") orelse return null;
    const raw = std.mem.trim(u8, rest[0..close], " \t\r\n");
    return if (raw.len == 0) null else raw;
}

pub const DateParts = struct { year: i32, month: u8, day: u8, weekday: u8, hour: u8, minute: u8 };

const weekday_names = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [12][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// Converts epoch seconds to UTC civil date and time parts. Hand-rolled
/// (Howard Hinnant's civil_from_days) rather than reaching for
/// std.time.epoch, whose API drifts across dev versions; this is twenty
/// lines of arithmetic with fixed behavior. Weekday is 0=Sunday.
pub fn dateParts(epoch_sec: i64) DateParts {
    const days = @divFloor(epoch_sec, 86400);
    const secs = @mod(epoch_sec, 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = @intCast(if (m <= 2) y + 1 else y),
        .month = @intCast(m),
        .day = @intCast(d),
        .weekday = @intCast(@mod(days + 4, 7)),
        .hour = @intCast(@divFloor(secs, 3600)),
        .minute = @intCast(@mod(@divFloor(secs, 60), 60)),
    };
}

/// Upper bound on extracted searchable text per page. A documented cap,
/// not silent truncation: the search-v2 spec records it, and collateral
/// pages sit far below it; raise this one constant if that changes.
const text_bytes_max = 16 * 1024;

/// Entities decoded by `extractText`; anything else passes through as-is.
const text_entities = [_]struct { name: []const u8, rep: []const u8 }{
    .{ .name = "&amp;", .rep = "&" },
    .{ .name = "&lt;", .rep = "<" },
    .{ .name = "&gt;", .rep = ">" },
    .{ .name = "&quot;", .rep = "\"" },
    .{ .name = "&#39;", .rep = "'" },
    .{ .name = "&nbsp;", .rep = " " },
    .{ .name = "&middot;", .rep = "\u{00B7}" },
};

/// Reduces a page to searchable plain text: `<script>`/`<style>` blocks
/// dropped whole, other tags stripped and treated as word boundaries
/// (adjacent block content must not fuse into one word, or the search
/// vocabulary corrupts), common entities decoded, whitespace runs
/// collapsed to single spaces, ASCII lowercased, output capped at
/// `text_bytes_max`.
fn extractText(alloc: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    var pending_space = false;
    scan: while (i < html.len and out.items.len < text_bytes_max) {
        const c = html[i];
        if (c == '<') {
            const dropped = [_]struct { open: []const u8, close: []const u8 }{
                .{ .open = "<script", .close = "</script>" },
                .{ .open = "<style", .close = "</style>" },
            };
            for (dropped) |d| {
                if (std.ascii.startsWithIgnoreCase(html[i..], d.open)) {
                    // NOTE: this std renamed indexOfIgnoreCase to findIgnoreCase.
                    const rel = std.ascii.findIgnoreCase(html[i..], d.close) orelse break :scan;
                    i += rel + d.close.len;
                    pending_space = true;
                    continue :scan;
                }
            }
            const close = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
            i = close + 1;
            pending_space = true;
            continue;
        }
        if (c == '&') {
            for (text_entities) |e| {
                if (std.mem.startsWith(u8, html[i..], e.name)) {
                    if (pending_space and out.items.len > 0) try out.append(alloc, ' ');
                    pending_space = false;
                    try out.appendSlice(alloc, e.rep);
                    i += e.name.len;
                    continue :scan;
                }
            }
        }
        if (std.ascii.isWhitespace(c)) {
            pending_space = true;
            i += 1;
            continue;
        }
        if (pending_space and out.items.len > 0) try out.append(alloc, ' ');
        pending_space = false;
        try out.append(alloc, std.ascii.toLower(c));
        i += 1;
    }
    if (out.items.len > text_bytes_max) out.shrinkRetainingCapacity(text_bytes_max);
    std.debug.assert(out.items.len <= text_bytes_max);
    return out.toOwnedSlice(alloc);
}

/// One `atelier:*` metadata pair extracted from a page.
pub const Meta = struct { key: []const u8, value: []const u8 };

/// True when `key` matches the spec's `[a-z0-9_-]+` charset.
fn metaKeyValid(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Extracts the page's `atelier:*` metadata per the index-browser spec:
/// every tag shaped exactly `<meta name="atelier:KEY" content="VALUE">`
/// (double quotes, `name` before `content`); anything else is skipped
/// silently, in the same pragmatic string-scanning spirit as
/// `extractTitle`. Keys and values are duped into `alloc`; repeats are
/// kept in document order.
fn extractMeta(alloc: std.mem.Allocator, html: []const u8) ![]Meta {
    var out: std.ArrayList(Meta) = .empty;
    errdefer {
        for (out.items) |m| {
            alloc.free(m.key);
            alloc.free(m.value);
        }
        out.deinit(alloc);
    }

    const name_marker = "<meta name=\"atelier:";
    const content_marker = "\" content=\"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, name_marker)) |at| {
        i = at + name_marker.len;
        const key_end = std.mem.indexOfPos(u8, html, i, content_marker) orelse continue;
        const key = html[i..key_end];
        if (!metaKeyValid(key)) continue;
        const val_start = key_end + content_marker.len;
        const val_end = std.mem.indexOfScalarPos(u8, html, val_start, '"') orelse break;
        const key_d = try alloc.dupe(u8, key);
        errdefer alloc.free(key_d);
        const val_d = try alloc.dupe(u8, html[val_start..val_end]);
        errdefer alloc.free(val_d);
        try out.append(alloc, .{ .key = key_d, .value = val_d });
        i = val_end + 1;
    }
    return out.toOwnedSlice(alloc);
}

/// One discovered page: `label` is its `<title>` (or, failing that, its
/// path relative to the library root), `href` is that relative path minus
/// `.html`, `path` is the relative path as-is (used for the subtitle).
pub const Item = struct {
    label: []const u8,
    href: []const u8,
    path: []const u8,
    /// First segment of the library-relative path; "" for root-level pages.
    section: []const u8 = "",
    /// File mtime, seconds since the epoch; drives the modified sort.
    mtime_sec: i64 = 0,
    /// The page's `atelier:*` tags, document order; often empty.
    meta: []const Meta = &.{},
    /// Extracted searchable plain text (see `extractText`); embedded in
    /// the index's corpus.
    text: []const u8 = "",
    /// Commit count for this page in the library's git history; 0 when
    /// the library is not a repository.
    revs: u32 = 0,
    /// "page" for HTML documents, "pdf" for standalone PDFs. Static
    /// strings, never freed.
    kind: []const u8 = "page",
};

/// Parses `git log --name-only --pretty=format:` output into a map of
/// library-relative path to commit count. Keys are duped; free with
/// `freeRevCounts`.
pub fn parseRevCounts(alloc: std.mem.Allocator, output: []const u8) !std.StringHashMap(u32) {
    var counts = std.StringHashMap(u32).init(alloc);
    errdefer freeRevCounts(alloc, &counts);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r");
        if (path.len == 0) continue;
        if (counts.getPtr(path)) |p| {
            p.* += 1;
        } else {
            try counts.put(try alloc.dupe(u8, path), 1);
        }
    }
    return counts;
}

/// Frees a map returned by `parseRevCounts`.
pub fn freeRevCounts(alloc: std.mem.Allocator, counts: *std.StringHashMap(u32)) void {
    var it = counts.keyIterator();
    while (it.next()) |k| alloc.free(k.*);
    counts.deinit();
}

/// Per-page commit counts for the library, or an empty map when the
/// library is not a git repository (or git is unavailable); the ledger
/// degrades silently either way.
fn revCounts(alloc: std.mem.Allocator, io: std.Io, root: []const u8) std.StringHashMap(u32) {
    const empty = std.StringHashMap(u32).init(alloc);
    const run = std.process.run(alloc, io, .{
        .argv = &.{ "git", "-C", root, "log", "--name-only", "--pretty=format:" },
    }) catch return empty;
    defer alloc.free(run.stdout);
    defer alloc.free(run.stderr);
    switch (run.term) {
        .exited => |code| if (code != 0) return empty,
        else => return empty,
    }
    return parseRevCounts(alloc, run.stdout) catch empty;
}

/// Frees one `collectItems`-owned `Item`'s allocations.
fn freeItem(alloc: std.mem.Allocator, it: Item) void {
    alloc.free(it.label);
    alloc.free(it.href);
    alloc.free(it.path);
    alloc.free(it.section);
    for (it.meta) |m| {
        alloc.free(m.key);
        alloc.free(m.value);
    }
    alloc.free(it.meta);
    alloc.free(it.text);
}

/// Frees an `Item` slice returned by `collectItems`.
pub fn freeItems(alloc: std.mem.Allocator, items: []const Item) void {
    for (items) |it| freeItem(alloc, it);
    alloc.free(items);
}

fn lessThanLabel(_: void, a: Item, b: Item) bool {
    return std.ascii.lessThanIgnoreCase(a.label, b.label);
}

/// Recursively discovers every `*.html` page under `lib.root`, mirroring
/// the earlier internal Node implementation: excludes `index.html` at the
/// root and anything under a root-level `templates/` directory. Also
/// prunes dot-directories (e.g. `.git`) so their subtrees are never
/// descended into. Returned items are sorted by label, case-insensitively.
pub fn collectItems(alloc: std.mem.Allocator, io: std.Io, lib: library.Library) ![]Item {
    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |it| freeItem(alloc, it);
        items.deinit(alloc);
    }

    var revs = revCounts(alloc, io, lib.root);
    defer freeRevCounts(alloc, &revs);

    var root_dir = try std.Io.Dir.openDirAbsolute(io, lib.root, .{ .iterate = true });
    defer root_dir.close(io);

    var walker = try root_dir.walkSelectively(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            // Pruning dot-directories keeps .git and tool state out of the walk, a deliberate deviation from the ported mjs.
            const is_dot = entry.basename.len > 0 and entry.basename[0] == '.';
            const is_root_templates = entry.depth() == 1 and std.mem.eql(u8, entry.basename, "templates");
            if (!is_dot and !is_root_templates) try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        // Dot-files are tool state (e.g. share temp copies), never pages.
        if (entry.basename.len > 0 and entry.basename[0] == '.') continue;

        if (std.mem.endsWith(u8, entry.path, ".pdf")) {
            // A PDF beside a same-stem page is a render of that page, not
            // a document of its own; standalone PDFs join the ledger.
            const sib = try std.fmt.allocPrint(alloc, "{s}.html", .{entry.basename[0 .. entry.basename.len - ".pdf".len]});
            defer alloc.free(sib);
            const sibling_exists = if (entry.dir.access(io, sib, .{})) |_| true else |_| false;
            if (sibling_exists) continue;

            const rel: []const u8 = entry.path;
            const section_src = if (std.mem.indexOfScalar(u8, rel, '/')) |s| rel[0..s] else "";
            const st = entry.dir.statFile(io, entry.basename, .{}) catch null; // racing delete: sort metadata degrades to 0
            try items.append(alloc, .{
                .label = try alloc.dupe(u8, entry.basename),
                .href = try std.fmt.allocPrint(alloc, "/{s}", .{rel}),
                .path = try std.fmt.allocPrint(alloc, "/{s}", .{rel}),
                .section = try alloc.dupe(u8, section_src),
                .mtime_sec = if (st) |s| @intCast(@divTrunc(s.mtime.nanoseconds, std.time.ns_per_s)) else 0,
                .meta = try alloc.alloc(Meta, 0),
                .text = try alloc.dupe(u8, ""),
                .revs = revs.get(rel) orelse 0,
                .kind = "pdf",
            });
            continue;
        }

        if (!std.mem.endsWith(u8, entry.path, ".html")) continue;
        if (std.mem.eql(u8, entry.path, "index.html")) continue;

        const html = entry.dir.readFileAlloc(io, entry.basename, alloc, .limited(page_bytes_max)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer alloc.free(html);

        const rel: []const u8 = entry.path;
        const title = extractTitle(html);
        const label = if (title) |ti| try alloc.dupe(u8, ti) else try alloc.dupe(u8, rel);
        std.debug.assert(std.mem.endsWith(u8, rel, ".html"));
        const href = try std.fmt.allocPrint(alloc, "/{s}", .{rel[0 .. rel.len - ".html".len]});
        const path_ = try std.fmt.allocPrint(alloc, "/{s}", .{rel});

        const section_src = if (std.mem.indexOfScalar(u8, rel, '/')) |s| rel[0..s] else "";
        const section = try alloc.dupe(u8, section_src);
        const st = entry.dir.statFile(io, entry.basename, .{}) catch null; // racing delete: sort metadata degrades to 0
        const mtime_sec: i64 = if (st) |s| @intCast(@divTrunc(s.mtime.nanoseconds, std.time.ns_per_s)) else 0;
        const meta = try extractMeta(alloc, html);
        const text = try extractText(alloc, html);

        try items.append(alloc, .{
            .label = label,
            .href = href,
            .path = path_,
            .section = section,
            .mtime_sec = mtime_sec,
            .meta = meta,
            .text = text,
            .revs = revs.get(rel) orelse 0,
        });
    }

    const out = try items.toOwnedSlice(alloc);
    std.sort.pdq(Item, out, {}, lessThanLabel);
    return out;
}

/// Escapes `&`, `<`, `>` (mirrors the mjs `esc` helper). Used only for the
/// path subtitle; everything else (the `<title>`, the wordmark, and labels
/// sourced from a page's own `<title>`) is trusted verbatim, as in the mjs.
fn escAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Like `escAlloc` but for double-quoted attribute values: also escapes
/// `"` as `&quot;` so page-supplied titles and metadata cannot break out
/// of a `data-*` attribute.
fn escAttrAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            '"' => try out.appendSlice(alloc, "&quot;"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Reserved keys always emitted by the renderer itself; page metadata with
/// these keys stays searchable via the haystack but never becomes an
/// attribute (spec: reserved keys).
const reserved_meta_keys = [_][]const u8{ "label", "path", "section", "mtime" };

fn metaKeyReserved(key: []const u8) bool {
    for (reserved_meta_keys) |r| if (std.mem.eql(u8, key, r)) return true;
    return false;
}

/// First value for `key` in `meta`, or null. Repeats keep their first
/// occurrence, matching the data-attribute emission rule.
fn metaValue(meta: []const Meta, key: []const u8) ?[]const u8 {
    for (meta) |m| if (std.mem.eql(u8, m.key, key)) return m.value;
    return null;
}

/// Renders one ledger entry anchor: `data-*` attributes (escaped), the
/// title, and the stamp row (agent chip, client chip, `section · HH:MM`
/// in mono, the section segment omitted for root pages). Stamps render
/// only when the page declared the corresponding metadata.
fn renderItem(alloc: std.mem.Allocator, out: *std.ArrayList(u8), it: Item) !void {
    // Pair assertions with collectItems, which produces both fields with a
    // leading slash on the other side of the module boundary.
    std.debug.assert(std.mem.startsWith(u8, it.href, "/"));
    std.debug.assert(std.mem.startsWith(u8, it.path, "/"));
    const label_attr = try escAttrAlloc(alloc, it.label);
    defer alloc.free(label_attr);
    const path_attr = try escAttrAlloc(alloc, it.path);
    defer alloc.free(path_attr);
    const section_attr = try escAttrAlloc(alloc, it.section);
    defer alloc.free(section_attr);
    const mtime_str = try std.fmt.allocPrint(alloc, "{d}", .{it.mtime_sec});
    defer alloc.free(mtime_str);

    try out.appendSlice(alloc, "    <a class=\"item\" href=\"");
    try out.appendSlice(alloc, it.href);
    try out.appendSlice(alloc, "\" data-label=\"");
    try out.appendSlice(alloc, label_attr);
    try out.appendSlice(alloc, "\" data-path=\"");
    try out.appendSlice(alloc, path_attr);
    try out.appendSlice(alloc, "\" data-section=\"");
    try out.appendSlice(alloc, section_attr);
    try out.appendSlice(alloc, "\" data-mtime=\"");
    try out.appendSlice(alloc, mtime_str);
    try out.appendSlice(alloc, "\"");
    if (it.revs > 1) {
        const revs_attr = try std.fmt.allocPrint(alloc, " data-revs=\"{d}\"", .{it.revs});
        defer alloc.free(revs_attr);
        try out.appendSlice(alloc, revs_attr);
    }
    if (!std.mem.eql(u8, it.kind, "page")) {
        try out.appendSlice(alloc, " data-kind=\"");
        try out.appendSlice(alloc, it.kind);
        try out.appendSlice(alloc, "\"");
    }

    for (it.meta, 0..) |m, mi| {
        if (metaKeyReserved(m.key)) continue;
        var first = true; // only the first occurrence of a key becomes an attribute
        for (it.meta[0..mi]) |prev| {
            if (std.mem.eql(u8, prev.key, m.key)) first = false;
        }
        if (!first) continue;
        const val_attr = try escAttrAlloc(alloc, m.value);
        defer alloc.free(val_attr);
        try out.appendSlice(alloc, " data-");
        try out.appendSlice(alloc, m.key);
        try out.appendSlice(alloc, "=\"");
        try out.appendSlice(alloc, val_attr);
        try out.appendSlice(alloc, "\"");
    }

    try out.appendSlice(alloc, ">\n      <div class=\"t\">");
    try out.appendSlice(alloc, it.label);
    try out.appendSlice(alloc, "</div>\n      <div class=\"meta\">");
    if (metaValue(it.meta, "agent")) |agent| {
        try out.appendSlice(alloc, "<span class=\"stamp agent\">");
        try out.appendSlice(alloc, agent);
        try out.appendSlice(alloc, "</span>");
    }
    if (metaValue(it.meta, "client")) |client| {
        try out.appendSlice(alloc, "<span class=\"stamp client\">");
        try out.appendSlice(alloc, client);
        try out.appendSlice(alloc, "</span>");
    }
    const when = dateParts(it.mtime_sec);
    try out.appendSlice(alloc, "<span class=\"when\">");
    if (it.section.len > 0) {
        try out.appendSlice(alloc, it.section);
        try out.appendSlice(alloc, " &middot; ");
    }
    const hhmm = try std.fmt.allocPrint(alloc, "{d:0>2}:{d:0>2}", .{ when.hour, when.minute });
    defer alloc.free(hhmm);
    try out.appendSlice(alloc, hhmm);
    try out.appendSlice(alloc, "</span>");
    if (it.revs > 1) {
        const marker = try std.fmt.allocPrint(alloc, "<span class=\"rev\">rev {d}</span>", .{it.revs});
        defer alloc.free(marker);
        try out.appendSlice(alloc, marker);
    }
    if (!std.mem.eql(u8, it.kind, "page")) {
        try out.appendSlice(alloc, "<span class=\"kind\">");
        try out.appendSlice(alloc, it.kind);
        try out.appendSlice(alloc, "</span>");
    }
    try out.appendSlice(alloc, "</div>\n    </a>\n");
}

/// Appends `s` as a JSON string (quotes included): `"` and `\` escaped,
/// and control characters and `<` as unicode escapes, so embedded page
/// text can never close the corpus script tag.
fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '<' => try out.appendSlice(alloc, "\\u003c"),
            else => {
                if (c < 0x20) {
                    const esc = try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c});
                    defer alloc.free(esc);
                    try out.appendSlice(alloc, esc);
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    try out.append(alloc, '"');
}

/// Renders the embedded search corpus: a JSON object mapping each item's
/// href to its extracted text (see `extractText`).
fn renderCorpus(alloc: std.mem.Allocator, items: []const Item) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '{');
    for (items, 0..) |it, i| {
        if (i != 0) try out.append(alloc, ',');
        try appendJsonString(alloc, &out, it.href);
        try out.append(alloc, ':');
        try appendJsonString(alloc, &out, it.text);
    }
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

/// Appends one filter chip button.
fn appendChip(alloc: std.mem.Allocator, out: *std.ArrayList(u8), group: []const u8, value: []const u8) !void {
    const value_attr = try escAttrAlloc(alloc, value);
    defer alloc.free(value_attr);
    try out.appendSlice(alloc, "<button class=\"chip\" data-group=\"");
    try out.appendSlice(alloc, group);
    try out.appendSlice(alloc, "\" data-value=\"");
    try out.appendSlice(alloc, value_attr);
    try out.appendSlice(alloc, "\">");
    try out.appendSlice(alloc, value);
    try out.appendSlice(alloc, "</button>");
}

/// Appends one chip per distinct value of `group` across `items`, in order
/// of first appearance, preceded by a dot separator when the group is
/// non-empty and `sep` is set. Values come from `it.section` for the
/// "section" group and from page metadata otherwise. Returns whether
/// anything was emitted.
fn appendChipGroup(alloc: std.mem.Allocator, out: *std.ArrayList(u8), items: []const Item, group: []const u8, sep: bool) !bool {
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(alloc);
    for (items) |it| {
        const value = if (std.mem.eql(u8, group, "section"))
            (if (it.section.len > 0) it.section else null)
        else
            metaValue(it.meta, group);
        const v = value orelse continue;
        var dup = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, v)) dup = true;
        }
        if (dup) continue;
        if (seen.items.len == 0 and sep) try out.appendSlice(alloc, "<span class=\"dot\">&middot;</span>");
        try seen.append(alloc, v);
        try appendChip(alloc, out, group, v);
    }
    return seen.items.len > 0;
}

/// Renders the filter chip row: `all` (active by default), then the
/// distinct sections, agents, and clients found in `items`, dot-separated
/// per group; a group with no values is omitted entirely.
fn renderChips(alloc: std.mem.Allocator, items: []const Item) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "<button class=\"chip on\" data-group=\"*\">all</button>");
    var any = try appendChipGroup(alloc, &out, items, "section", false);
    any = (try appendChipGroup(alloc, &out, items, "agent", any)) or any;
    _ = try appendChipGroup(alloc, &out, items, "client", any);
    return out.toOwnedSlice(alloc);
}

fn newerThan(_: void, a: Item, b: Item) bool {
    if (a.mtime_sec != b.mtime_sec) return a.mtime_sec > b.mtime_sec;
    return std.ascii.lessThanIgnoreCase(a.label, b.label); // deterministic ties
}

/// Renders the ledger: entries sorted newest-first and grouped into
/// `<section class="day">` blocks whenever the UTC (year, month, day)
/// triple changes, each opened by a folio (zero-padded day numeral over
/// `Weekday · Month` in mono).
fn renderLedger(alloc: std.mem.Allocator, items: []const Item) ![]u8 {
    const sorted = try alloc.dupe(Item, items);
    defer alloc.free(sorted);
    std.sort.pdq(Item, sorted, {}, newerThan);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var open = false;
    var prev: DateParts = undefined;
    for (sorted) |it| {
        const d = dateParts(it.mtime_sec);
        const new_day = !open or d.year != prev.year or d.month != prev.month or d.day != prev.day;
        if (new_day) {
            if (open) try out.appendSlice(alloc, "      </div>\n    </section>\n");
            const folio = try std.fmt.allocPrint(
                alloc,
                "    <section class=\"day\">\n      <div class=\"folio\"><div class=\"num\">{d:0>2}</div><div class=\"dow\">{s} &middot; {s}</div></div>\n      <div class=\"entries\">\n",
                .{ d.day, weekday_names[d.weekday], month_names[d.month - 1] },
            );
            defer alloc.free(folio);
            try out.appendSlice(alloc, folio);
            open = true;
            prev = d;
        }
        try renderItem(alloc, &out, it);
    }
    if (open) try out.appendSlice(alloc, "      </div>\n    </section>\n");
    if (out.items.len > 0) _ = out.pop(); // no trailing newline
    return out.toOwnedSlice(alloc);
}

/// The built-in page shell, structure ported from the earlier internal
/// Node implementation with the branding lifted out into
/// `{{...}}` placeholders that `render` fills from the library's manifest
/// (name, tag, theme). Single braces (all the CSS) pass through
/// `template.fill` untouched; only well-formed `{{IDENT}}` sequences are
/// placeholders.
const builtin_shell =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>{{NAME}} &middot; Atelier</title>
    \\<!-- GENERATED by the atelier CLI (atelier index). Do not edit by hand; re-run the command. -->
    \\{{FONT_LINK_BLOCK}}<style>
    \\  :root{--paper:{{PAPER}};--ink:{{INK}};--ink-3:{{MUTED}};--accent:{{ACCENT}};--rule:{{RULE}};
    \\    --display:{{DISPLAY_FONT}};--mono:{{MONO_FONT}};}
    \\  *{box-sizing:border-box;margin:0;padding:0}
    \\  body{background:var(--paper);color:var(--ink);font-family:var(--display)}
    \\  .page{max-width:1020px;margin:0 auto;padding:48px clamp(24px,5vw,72px) 72px}
    \\  .masthead{display:flex;justify-content:space-between;align-items:flex-end;gap:16px;
    \\    border-bottom:4px double var(--ink);padding-bottom:16px}
    \\  .flag{font-weight:900;font-size:clamp(34px,6vw,52px);letter-spacing:-.03em;line-height:1}.flag .r{color:var(--accent)}
    \\  .tag{font-family:var(--mono);font-size:10px;font-weight:600;letter-spacing:.26em;
    \\    text-transform:uppercase;color:var(--ink-3);margin-top:10px}
    \\  .libcount{font-family:var(--mono);font-size:10px;font-weight:500;letter-spacing:.14em;
    \\    text-transform:uppercase;color:var(--ink-3);white-space:nowrap;padding-bottom:4px}
    \\  .searchrule{display:none;align-items:center;gap:18px;border-bottom:1px solid var(--rule)}
    \\  .searchrule:focus-within{border-bottom-color:var(--accent)}
    \\  .searchrule input{flex:1;min-width:0;border:0;background:transparent;
    \\    color:var(--ink);font-family:var(--mono);font-size:12px;letter-spacing:.08em;padding:14px 2px;outline:none}
    \\  .sorts{display:flex;gap:12px}
    \\  .sortopt{font-family:var(--mono);font-size:9px;font-weight:600;letter-spacing:.14em;text-transform:uppercase;
    \\    background:none;border:0;border-bottom:2px solid transparent;color:var(--ink-3);padding:4px 0;cursor:pointer}
    \\  .sortopt:hover{color:var(--accent)}
    \\  .sortopt.on{color:var(--accent);border-bottom-color:var(--accent)}
    \\  .results{margin-top:32px}
    \\  .results a.item + a.item{border-top:1px solid var(--rule)}
    \\  .snip{font-family:var(--mono);font-size:10px;color:var(--ink-3);margin-top:6px;letter-spacing:.02em;
    \\    white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    \\  .cover{font-family:var(--mono);font-size:8px;font-weight:600;letter-spacing:.1em;
    \\    border:1px dashed var(--rule);color:var(--ink-3);padding:2px 6px}
    \\  .chips{display:none;flex-wrap:wrap;gap:6px;align-items:center;padding:14px 0 0}
    \\  .chip{font-family:var(--mono);font-size:9px;font-weight:600;letter-spacing:.14em;text-transform:uppercase;
    \\    border:1px solid var(--rule);color:var(--ink-3);background:none;padding:4px 10px;cursor:pointer}
    \\  .chip:hover{border-color:var(--accent);color:var(--accent)}
    \\  .chip:focus-visible,a.item:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
    \\  .chip.on{background:var(--accent);border-color:var(--accent);color:var(--paper)}
    \\  .dot{color:var(--rule);font-family:var(--mono);font-size:10px;padding:0 3px}
    \\  .ledger{position:relative;margin-top:32px}
    \\  .ledger::before{content:"";position:absolute;left:104px;top:6px;bottom:0;width:2px;background:var(--accent)}
    \\  .day{display:flex;gap:36px;margin-bottom:8px}
    \\  .folio{width:86px;flex-shrink:0;text-align:right}
    \\  .num{font-size:56px;font-weight:900;line-height:.9}
    \\  .day:first-of-type .num{color:var(--accent)}
    \\  .dow{font-family:var(--mono);font-size:9px;font-weight:600;letter-spacing:.14em;
    \\    text-transform:uppercase;color:var(--ink-3);margin-top:5px}
    \\  .entries{flex:1;padding-left:10px;min-width:0}
    \\  a.item{display:block;text-decoration:none;color:var(--ink);padding:16px 0}
    \\  .entries a.item + a.item{border-top:1px solid var(--rule)}
    \\  .t{font-size:clamp(19px,2.6vw,24px);font-weight:600;line-height:1.15}
    \\  a.item:hover .t{color:var(--accent)}
    \\  .meta{display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin-top:8px}
    \\  .stamp{font-family:var(--mono);font-size:8px;font-weight:600;letter-spacing:.14em;text-transform:uppercase;padding:2px 8px}
    \\  .stamp.agent{border:1px solid var(--accent);color:var(--accent)}
    \\  .stamp.client{border:1px solid var(--rule);color:var(--ink-3)}
    \\  .when{font-family:var(--mono);font-size:9px;font-weight:500;letter-spacing:.14em;text-transform:uppercase;color:var(--ink-3)}
    \\  .rev{font-family:var(--mono);font-size:8px;font-weight:600;letter-spacing:.1em;text-transform:uppercase;
    \\    border-bottom:1px dotted var(--rule);color:var(--ink-3)}
    \\  .kind{font-family:var(--mono);font-size:8px;font-weight:600;letter-spacing:.1em;text-transform:uppercase;
    \\    background:var(--rule);color:var(--ink);padding:2px 6px}
    \\  [hidden]{display:none !important}
    \\  @media (max-width:640px){
    \\    .page{padding:32px 22px 48px}
    \\    .ledger::before{display:none}
    \\    .day{display:block}
    \\    .folio{display:flex;align-items:baseline;gap:10px;width:auto;text-align:left;margin:18px 0 2px}
    \\    .num{font-size:30px}
    \\    .entries{padding-left:0}
    \\  }
    \\</style>
    \\</head>
    \\<body>
    \\  <div class="page">
    \\    <header class="masthead">
    \\      <div>
    \\        <div class="flag">{{WORDMARK}}</div>
    \\{{TAG_BLOCK}}      </div>
    \\      <div class="libcount">Atelier &middot; <span class="n">{{COUNT}}</span> documents</div>
    \\    </header>
    \\    <div class="searchrule">
    \\      <input type="search" placeholder="Search the library  /" aria-label="Search documents">
    \\      <span class="sorts"><button class="sortopt on" data-sort="date">date</button><button class="sortopt" data-sort="match">match</button><button class="sortopt" data-sort="az">a-z</button></span>
    \\    </div>
    \\    <div class="chips">{{CHIPS}}</div>
    \\    <div class="ledger">
    \\{{LEDGER}}
    \\    </div>
    \\    <div class="results" hidden></div>
    \\  </div>
    \\<script type="application/json" id="atelier-corpus">{{CORPUS}}</script>
    \\<script>
    \\(function () {
    \\  var searchrule = document.querySelector('.searchrule');
    \\  var chipsRow = document.querySelector('.chips');
    \\  if (!searchrule || !chipsRow) return;
    \\  searchrule.style.display = 'flex';
    \\  chipsRow.style.display = 'flex';
    \\  var q = searchrule.querySelector('input');
    \\  var sortopts = [].slice.call(searchrule.querySelectorAll('.sortopt'));
    \\  var countEl = document.querySelector('.masthead .n');
    \\  var ledger = document.querySelector('.ledger');
    \\  var resultsEl = document.querySelector('.results');
    \\  var days = [].slice.call(document.querySelectorAll('.day'));
    \\  var chips = [].slice.call(chipsRow.querySelectorAll('.chip'));
    \\  var allChip = chipsRow.querySelector('.chip[data-group="*"]');
    \\  var corpus = {};
    \\  try { corpus = JSON.parse(document.getElementById('atelier-corpus').textContent); } catch (e) { corpus = {}; }
    \\  var entries = [].slice.call(ledger.querySelectorAll('a.item')).map(function (el) {
    \\    var metaVals = [];
    \\    for (var i = 0; i < el.attributes.length; i++) {
    \\      var a = el.attributes[i];
    \\      if (a.name.indexOf('data-') === 0 && a.name !== 'data-mtime' && a.name !== 'data-label') metaVals.push(a.value);
    \\    }
    \\    return {
    \\      el: el,
    \\      label: (el.getAttribute('data-label') || '').toLowerCase(),
    \\      aux: metaVals.join(' ').toLowerCase(),
    \\      mtime: +el.getAttribute('data-mtime') || 0,
    \\      text: corpus[el.getAttribute('href')] || ''
    \\    };
    \\  });
    \\  var sort = 'date';
    \\  var active = { section: {}, agent: {}, client: {} };
    \\  var lex = null;
    \\  function words(s) {
    \\    return s ? s.split(/[^a-z0-9]+/).filter(function (w) { return w.length > 0; }) : [];
    \\  }
    \\  function buildLex() {
    \\    if (lex) return lex;
    \\    var df = {};
    \\    entries.forEach(function (e) {
    \\      var m = {};
    \\      function add(s, w) {
    \\        words(s).forEach(function (word) {
    \\          if (!(m[word] >= w)) m[word] = w;
    \\        });
    \\      }
    \\      add(e.label, 3); add(e.aux, 2); add(e.text, 1);
    \\      e.wordWeights = m;
    \\      for (var w in m) df[w] = (df[w] || 0) + 1;
    \\    });
    \\    lex = { words: Object.keys(df), df: df };
    \\    return lex;
    \\  }
    \\  function idf(w) {
    \\    var d = buildLex().df[w] || 0;
    \\    return Math.log(1 + (entries.length - d + 0.5) / (d + 0.5));
    \\  }
    \\  function editBudget(len) { return len <= 2 ? 0 : len <= 5 ? 1 : 2; }
    \\  function editDistance(a, b, max) {
    \\    var la = a.length, lb = b.length;
    \\    if (Math.abs(la - lb) > max) return max + 1;
    \\    var prev2 = null, prev = [], cur, i, j;
    \\    for (j = 0; j <= lb; j++) prev.push(j);
    \\    for (i = 1; i <= la; i++) {
    \\      cur = [i];
    \\      var rowMin = i;
    \\      for (j = 1; j <= lb; j++) {
    \\        var cost = a.charAt(i - 1) === b.charAt(j - 1) ? 0 : 1;
    \\        var v = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
    \\        if (i > 1 && j > 1 && a.charAt(i - 1) === b.charAt(j - 2) && a.charAt(i - 2) === b.charAt(j - 1)) {
    \\          v = Math.min(v, prev2[j - 2] + 1);
    \\        }
    \\        cur.push(v);
    \\        if (v < rowMin) rowMin = v;
    \\      }
    \\      if (rowMin > max) return max + 1;
    \\      prev2 = prev; prev = cur;
    \\    }
    \\    return prev[lb];
    \\  }
    \\  function vocabMatches(tok, isLast) {
    \\    var vocab = buildLex().words;
    \\    var budget = editBudget(tok.length);
    \\    var out = {};
    \\    for (var i = 0; i < vocab.length; i++) {
    \\      var w = vocab[i];
    \\      var base = 0;
    \\      if (w === tok) base = 100;
    \\      else if (isLast && tok.length >= 2 && w.indexOf(tok) === 0) base = 70;
    \\      else if (budget > 0 && Math.abs(w.length - tok.length) <= budget) {
    \\        var d = editDistance(tok, w, budget);
    \\        if (d === 1) base = 60; else if (d <= budget) base = 35;
    \\      }
    \\      if (base > 0 && !(out[w] >= base)) out[w] = base;
    \\    }
    \\    return out;
    \\  }
    \\  function wordStart(hay, i) {
    \\    if (i === 0) return true;
    \\    var p = hay[i - 1];
    \\    return p === ' ' || p === '-' || p === '/';
    \\  }
    \\  function fuzzy(needle, hay) {
    \\    var score = 0, hi = 0, prev = -2;
    \\    for (var ni = 0; ni < needle.length; ni++) {
    \\      var found = hay.indexOf(needle[ni], hi);
    \\      if (found < 0) return null;
    \\      score += 10;
    \\      if (found === prev + 1) score += 8;
    \\      if (wordStart(hay, found)) score += 12;
    \\      score -= Math.max(0, found - hi);
    \\      prev = found;
    \\      hi = found + 1;
    \\    }
    \\    return score;
    \\  }
    \\  function tokenScore(e, tok, wm) {
    \\    var best = 0, snipWord = null, contentWord = null;
    \\    for (var w in wm) {
    \\      var fw = e.wordWeights ? e.wordWeights[w] : null;
    \\      if (!fw) continue;
    \\      if (fw === 1 && contentWord === null) contentWord = w;
    \\      var c = idf(w) * (wm[w] / 100) * fw;
    \\      if (c > best) { best = c; snipWord = fw === 1 ? w : null; }
    \\    }
    \\    var lbl = fuzzy(tok, e.label);
    \\    if (lbl !== null) {
    \\      var cl = Math.min(1.8, lbl / 50);
    \\      if (cl > best) { best = cl; snipWord = null; }
    \\    }
    \\    var aux = e.aux ? fuzzy(tok, e.aux) : null;
    \\    if (aux !== null) {
    \\      var ca = Math.min(1.2, aux / 60);
    \\      if (ca > best) { best = ca; snipWord = null; }
    \\    }
    \\    var at = -1;
    \\    if (e.text) {
    \\      at = e.text.indexOf(tok);
    \\      if (at >= 0) {
    \\        var occ = 1, p = e.text.indexOf(tok, at + tok.length);
    \\        while (p >= 0 && occ < 6) { occ++; p = e.text.indexOf(tok, p + tok.length); }
    \\        var cc = 0.5 + Math.min(occ - 1, 5) * 0.05;
    \\        if (cc > best) { best = cc; snipWord = tok; }
    \\      }
    \\    }
    \\    if (best <= 0) return null;
    \\    var contentAt = at >= 0 ? at : (contentWord && e.text ? e.text.indexOf(contentWord) : -1);
    \\    var snipAt = snipWord && e.text ? e.text.indexOf(snipWord) : -1;
    \\    return { c: best, snipAt: snipAt, contentAt: contentAt };
    \\  }
    \\  function scoreEntry(e, toks, wms) {
    \\    var total = 0, cover = 0, snipAt = -1;
    \\    var positions = [];
    \\    for (var i = 0; i < toks.length; i++) {
    \\      var r = tokenScore(e, toks[i], wms[i]);
    \\      if (r === null) { positions.push(-1); continue; }
    \\      cover++;
    \\      total += r.c;
    \\      positions.push(r.contentAt);
    \\      if (snipAt < 0 && r.snipAt >= 0) snipAt = r.snipAt;
    \\    }
    \\    if (cover === 0) return null;
    \\    var prox = 0;
    \\    for (var j = 1; j < positions.length; j++) {
    \\      if (positions[j - 1] >= 0 && positions[j] >= 0 && Math.abs(positions[j] - positions[j - 1]) <= 60) prox += 0.4;
    \\    }
    \\    total += Math.min(prox, 1.2);
    \\    return { score: total, cover: cover, snipAt: snipAt };
    \\  }
    \\  function groupMatch(el, group) {
    \\    var keys = Object.keys(active[group]);
    \\    if (keys.length === 0) return true;
    \\    var v = el.getAttribute('data-' + group);
    \\    return v !== null && active[group][v] === true;
    \\  }
    \\  function passesChips(el) {
    \\    return groupMatch(el, 'section') && groupMatch(el, 'agent') && groupMatch(el, 'client');
    \\  }
    \\  function snippet(text, at) {
    \\    var start = Math.max(0, at - 30);
    \\    var end = Math.min(text.length, at + 60);
    \\    return (start > 0 ? '…' : '') + text.slice(start, end) + (end < text.length ? '…' : '');
    \\  }
    \\  function applyLedger() {
    \\    ledger.hidden = false;
    \\    resultsEl.hidden = true;
    \\    var n = 0;
    \\    days.forEach(function (day) {
    \\      var vis = 0;
    \\      [].slice.call(day.querySelectorAll('a.item')).forEach(function (it) {
    \\        var show = passesChips(it);
    \\        it.hidden = !show;
    \\        if (show) { vis++; n++; }
    \\      });
    \\      day.hidden = vis === 0;
    \\    });
    \\    if (countEl) countEl.textContent = n;
    \\  }
    \\  function applyFlat() {
    \\    ledger.hidden = true;
    \\    resultsEl.hidden = false;
    \\    var f = q.value.trim().toLowerCase();
    \\    var toks = words(f); // punctuation splits, matching the vocabulary's tokenization
    \\    var wms = toks.map(function (tok, i) { return vocabMatches(tok, i === toks.length - 1); });
    \\    var rows = [];
    \\    entries.forEach(function (e) {
    \\      if (!passesChips(e.el)) return;
    \\      if (toks.length) {
    \\        var r = scoreEntry(e, toks, wms);
    \\        if (r === null) return;
    \\        rows.push({ e: e, score: r.score, cover: r.cover, snipAt: r.snipAt });
    \\      } else {
    \\        rows.push({ e: e, score: 0, cover: 0, snipAt: -1 });
    \\      }
    \\    });
    \\    rows.sort(function (a, b) {
    \\      if (sort === 'az') return a.e.label < b.e.label ? -1 : a.e.label > b.e.label ? 1 : 0;
    \\      if (sort === 'match' && a.cover !== b.cover) return b.cover - a.cover;
    \\      if (sort === 'match' && a.score !== b.score) return b.score - a.score;
    \\      return b.e.mtime - a.e.mtime;
    \\    });
    \\    resultsEl.innerHTML = '';
    \\    rows.forEach(function (row) {
    \\      var clone = row.e.el.cloneNode(true);
    \\      clone.hidden = false;
    \\      if (toks.length && row.cover < toks.length) {
    \\        var cv = document.createElement('span');
    \\        cv.className = 'cover';
    \\        cv.textContent = row.cover + '/' + toks.length;
    \\        var metaEl = clone.querySelector('.meta');
    \\        if (metaEl) metaEl.appendChild(cv);
    \\      }
    \\      if (row.snipAt >= 0) {
    \\        var d = document.createElement('div');
    \\        d.className = 'snip';
    \\        d.textContent = snippet(row.e.text, row.snipAt);
    \\        clone.appendChild(d);
    \\      }
    \\      resultsEl.appendChild(clone);
    \\    });
    \\    if (countEl) countEl.textContent = rows.length;
    \\  }
    \\  function apply() {
    \\    if (q.value.trim().length === 0 && sort === 'date') applyLedger();
    \\    else applyFlat();
    \\  }
    \\  function setSort(s) {
    \\    sort = s;
    \\    sortopts.forEach(function (o) { o.classList.toggle('on', o.getAttribute('data-sort') === s); });
    \\    apply();
    \\  }
    \\  sortopts.forEach(function (o) {
    \\    o.addEventListener('click', function () { setSort(o.getAttribute('data-sort')); });
    \\  });
    \\  function anyActive() {
    \\    return Object.keys(active.section).length + Object.keys(active.agent).length + Object.keys(active.client).length > 0;
    \\  }
    \\  chips.forEach(function (chip) {
    \\    chip.addEventListener('click', function () {
    \\      var group = chip.getAttribute('data-group');
    \\      if (group === '*') {
    \\        active = { section: {}, agent: {}, client: {} };
    \\        chips.forEach(function (c) { c.classList.remove('on'); });
    \\        chip.classList.add('on');
    \\      } else {
    \\        var v = chip.getAttribute('data-value');
    \\        if (active[group][v]) { delete active[group][v]; chip.classList.remove('on'); }
    \\        else { active[group][v] = true; chip.classList.add('on'); }
    \\        allChip.classList.toggle('on', !anyActive());
    \\      }
    \\      apply();
    \\    });
    \\  });
    \\  q.addEventListener('input', function () {
    \\    var hasQuery = q.value.trim().length > 0;
    \\    if (hasQuery && sort === 'date') setSort('match');
    \\    else if (!hasQuery && sort === 'match') setSort('date');
    \\    else apply();
    \\  });
    \\  document.addEventListener('keydown', function (e) {
    \\    if (e.key === '/' && document.activeElement !== q) { e.preventDefault(); q.focus(); }
    \\  });
    \\  apply();
    \\})();
    \\</script>
    \\</body>
    \\</html>
    \\
;

/// Renders the full index page around `items` by filling `builtin_shell`
/// from the library's manifest, so a library brands itself entirely
/// through its `atelier.json` theme and the binary carries no brand.
///
/// The wordmark renders `lib.name` with its first comma wrapped as
/// `<span class="r">,</span>` (accent-colored; invisible under the neutral
/// theme, whose accent equals the ink color). The tagline div renders
/// `lib.tag` and is omitted entirely when empty; the font `<link>` is
/// omitted when the theme has no `font_link`, keeping the page free of
/// external requests. `<title>` is `{name} &middot; Atelier` with the name
/// rendered raw (only the path subtitle is escaped, mirroring the ported
/// mjs).
pub fn render(alloc: std.mem.Allocator, lib: library.Library, items: []const Item) ![]u8 {
    const ledger_html = try renderLedger(alloc, items);
    defer alloc.free(ledger_html);
    const chips_html = try renderChips(alloc, items);
    defer alloc.free(chips_html);
    const count_str = try std.fmt.allocPrint(alloc, "{d}", .{items.len});
    defer alloc.free(count_str);
    const corpus_json = try renderCorpus(alloc, items);
    defer alloc.free(corpus_json);

    const wordmark = if (std.mem.indexOfScalar(u8, lib.name, ',')) |idx|
        try std.fmt.allocPrint(alloc, "{s}<span class=\"r\">,</span>{s}", .{ lib.name[0..idx], lib.name[idx + 1 ..] })
    else
        try alloc.dupe(u8, lib.name);
    defer alloc.free(wordmark);

    const tag_block = if (lib.tag.len > 0)
        try std.fmt.allocPrint(alloc, "    <div class=\"tag\">{s}</div>\n", .{lib.tag})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(tag_block);

    const font_link_block = if (lib.theme.font_link.len > 0)
        try std.fmt.allocPrint(alloc, "<link href=\"{s}\" rel=\"stylesheet\">\n", .{lib.theme.font_link})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(font_link_block);

    var kv = std.StringHashMap([]const u8).init(alloc);
    defer kv.deinit();
    try kv.put("NAME", lib.name);
    try kv.put("WORDMARK", wordmark);
    try kv.put("TAG_BLOCK", tag_block);
    try kv.put("FONT_LINK_BLOCK", font_link_block);
    try kv.put("LEDGER", ledger_html);
    try kv.put("CHIPS", chips_html);
    try kv.put("COUNT", count_str);
    try kv.put("CORPUS", corpus_json);
    try kv.put("PAPER", lib.theme.paper);
    try kv.put("INK", lib.theme.ink);
    try kv.put("MUTED", lib.theme.muted);
    try kv.put("ACCENT", lib.theme.accent);
    try kv.put("RULE", lib.theme.rule);
    try kv.put("DISPLAY_FONT", lib.theme.display_font);
    try kv.put("MONO_FONT", lib.theme.mono_font);

    const r = try template.fill(alloc, builtin_shell, &kv);
    // Every placeholder in builtin_shell must have a kv entry above; an
    // unfilled one is a programmer error, not data.
    std.debug.assert(r.unfilled.len == 0);
    alloc.free(r.unfilled);
    return r.out;
}

/// Discovers pages under `lib.root` (see `collectItems`) and renders the
/// full `index.html` (see `render`).
pub fn generate(alloc: std.mem.Allocator, io: std.Io, lib: library.Library) ![]u8 {
    const items = try collectItems(alloc, io, lib);
    defer freeItems(alloc, items);
    return render(alloc, lib, items);
}

const t = std.testing;

fn freeMetaForTest(meta: []const Meta) void {
    for (meta) |m| {
        t.allocator.free(m.key);
        t.allocator.free(m.value);
    }
    t.allocator.free(meta);
}

test "extractMeta finds atelier tags and keeps document order" {
    const html =
        \\<head><meta name="atelier:client" content="Globex">
        \\<meta name="atelier:type" content="proposal"></head>
    ;
    const meta = try extractMeta(t.allocator, html);
    defer freeMetaForTest(meta);
    try t.expectEqual(@as(usize, 2), meta.len);
    try t.expectEqualStrings("client", meta[0].key);
    try t.expectEqualStrings("Globex", meta[0].value);
    try t.expectEqualStrings("type", meta[1].key);
}

test "extractMeta skips malformed and foreign tags, keeps repeats" {
    const html =
        \\<meta name="description" content="not ours">
        \\<meta name='atelier:single' content='quotes'>
        \\<meta name="atelier:noval">
        \\<meta name="atelier:Bad Key" content="x">
        \\<meta name="atelier:tag" content="a">
        \\<meta name="atelier:tag" content="b">
    ;
    const meta = try extractMeta(t.allocator, html);
    defer freeMetaForTest(meta);
    try t.expectEqual(@as(usize, 2), meta.len);
    try t.expectEqualStrings("a", meta[0].value);
    try t.expectEqualStrings("b", meta[1].value);
}

test "extractMeta returns empty for pages without metadata" {
    const meta = try extractMeta(t.allocator, "<title>Plain</title>");
    defer freeMetaForTest(meta);
    try t.expectEqual(@as(usize, 0), meta.len);
}

test "parseRevCounts counts path occurrences in git log output" {
    const output = "advisory/one.html\nroot.html\n\nadvisory/one.html\n\nadvisory/one.html\nother.png\n";
    var counts = try parseRevCounts(t.allocator, output);
    defer freeRevCounts(t.allocator, &counts);
    try t.expectEqual(@as(u32, 3), counts.get("advisory/one.html").?);
    try t.expectEqual(@as(u32, 1), counts.get("root.html").?);
    try t.expect(counts.get("missing.html") == null);
}

test "renderLedger shows a rev marker for multi-revision entries" {
    const items = [_]Item{
        .{ .label = "Multi", .href = "/m", .path = "/m.html", .mtime_sec = 3600, .revs = 4 },
        .{ .label = "Single", .href = "/s", .path = "/s.html", .mtime_sec = 3600, .revs = 1 },
    };
    const out = try renderLedger(t.allocator, &items);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "<span class=\"rev\">rev 4</span>") != null);
    try t.expect(std.mem.indexOf(u8, out, "rev 1") == null); // single revision is noise
    try t.expect(std.mem.indexOf(u8, out, "data-revs=\"4\"") != null);
}

test "collectItems indexes standalone pdfs and skips page renders" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "page.html", .data = "<title>P</title>" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "page.pdf", .data = "%PDF-render-of-page" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "deck.pdf", .data = "%PDF-standalone" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = library.Library{ .root = root, .name = "Acme", .tag = "", .port = 8789 };
    const items = try collectItems(t.allocator, t.io, lib);
    defer freeItems(t.allocator, items);
    try t.expectEqual(@as(usize, 2), items.len);
    var found_deck = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "deck.pdf")) {
            found_deck = true;
            try t.expectEqualStrings("pdf", it.kind);
            try t.expectEqualStrings("/deck.pdf", it.href);
        } else {
            try t.expectEqualStrings("page", it.kind);
        }
    }
    try t.expect(found_deck);
}

test "renderLedger marks pdf entries" {
    const items = [_]Item{.{ .label = "deck.pdf", .href = "/deck.pdf", .path = "/deck.pdf", .mtime_sec = 3600, .kind = "pdf" }};
    const out = try renderLedger(t.allocator, &items);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "data-kind=\"pdf\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "<span class=\"kind\">pdf</span>") != null);
}

test "collectItems skips dot-files" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "page.html", .data = "<title>P</title>" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".share-tmp.html", .data = "<title>Hidden</title>" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = library.Library{ .root = root, .name = "Acme", .tag = "", .port = 8789 };
    const items = try collectItems(t.allocator, t.io, lib);
    defer freeItems(t.allocator, items);
    try t.expectEqual(@as(usize, 1), items.len);
    try t.expectEqualStrings("P", items[0].label);
}

test "collectItems derives section, mtime, and meta" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.createDirPath(t.io, "advisory");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "advisory/one.html", .data =
        \\<title>One</title><meta name="atelier:client" content="Globex">
    });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "root.html", .data = "<title>Root</title>" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = library.Library{ .root = root, .name = "Acme", .tag = "", .port = 8789 };
    const items = try collectItems(t.allocator, t.io, lib);
    defer freeItems(t.allocator, items);
    try t.expectEqual(@as(usize, 2), items.len);
    // Sorted by label: "One" then "Root".
    try t.expectEqualStrings("advisory", items[0].section);
    try t.expectEqual(@as(usize, 1), items[0].meta.len);
    try t.expectEqualStrings("Globex", items[0].meta[0].value);
    try t.expect(items[0].mtime_sec > 0);
    try t.expectEqualStrings("", items[1].section);
    try t.expectEqual(@as(usize, 0), items[1].meta.len);
}

test "escAttrAlloc escapes quotes for attribute context" {
    const out = try escAttrAlloc(t.allocator, "a \"b\" <c> & d");
    defer t.allocator.free(out);
    try t.expectEqualStrings("a &quot;b&quot; &lt;c&gt; &amp; d", out);
}

test "renderLedger groups by UTC day, newest first, with folios and stamps" {
    const items = [_]Item{
        .{ .label = "Old", .href = "/old", .path = "/old.html", .mtime_sec = 86400 }, // 1970-01-02
        .{ .label = "New", .href = "/advisory/new", .path = "/advisory/new.html", .section = "advisory", .mtime_sec = 2 * 86400 + 3600 * 14 + 120, .meta = &.{ .{ .key = "agent", .value = "donna" }, .{ .key = "client", .value = "globex" } } },
    };
    const out = try renderLedger(t.allocator, &items);
    defer t.allocator.free(out);
    const day3 = std.mem.indexOf(u8, out, "<div class=\"num\">03</div>").?;
    const day2 = std.mem.indexOf(u8, out, "<div class=\"num\">02</div>").?;
    try t.expect(day3 < day2); // newest day first
    try t.expect(std.mem.indexOf(u8, out, "Sat &middot; January") != null);
    try t.expect(std.mem.indexOf(u8, out, "<span class=\"stamp agent\">donna</span>") != null);
    try t.expect(std.mem.indexOf(u8, out, "<span class=\"stamp client\">globex</span>") != null);
    try t.expect(std.mem.indexOf(u8, out, "advisory &middot; 14:02") != null);
    try t.expect(std.mem.indexOf(u8, out, "data-agent=\"donna\"") != null);
}

test "renderLedger omits section segment and stamps when absent" {
    const items = [_]Item{.{ .label = "Root", .href = "/root", .path = "/root.html", .mtime_sec = 3600 }};
    const out = try renderLedger(t.allocator, &items);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "class=\"stamp") == null);
    try t.expect(std.mem.indexOf(u8, out, "<span class=\"when\">01:00</span>") != null);
}

test "renderLedger skips reserved and repeated metadata keys as attributes" {
    const items = [_]Item{.{
        .label = "X",
        .href = "/x",
        .path = "/x.html",
        .meta = &.{
            .{ .key = "label", .value = "evil" },
            .{ .key = "tag", .value = "first" },
            .{ .key = "tag", .value = "second" },
        },
    }};
    const out = try renderLedger(t.allocator, &items);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "data-label=\"X\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "evil") == null);
    try t.expect(std.mem.indexOf(u8, out, "data-tag=\"first\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "second") == null);
}

test "render pins the CSS variable contract the theme editor writes to" {
    // The /__theme editor previews by setting exactly these custom
    // properties on :root; renaming any of them breaks it silently.
    const lib = library.Library{
        .root = "/x",
        .name = "Acme",
        .tag = "",
        .port = 8789,
        .theme = .{ .paper = "#fbf7f0", .accent = "#8c3a2e" },
    };
    const page = try render(t.allocator, lib, &.{});
    defer t.allocator.free(page);
    try t.expect(std.mem.indexOf(u8, page, "--paper:#fbf7f0") != null);
    try t.expect(std.mem.indexOf(u8, page, "--accent:#8c3a2e") != null);
    for ([_][]const u8{ "--paper:", "--ink:", "--ink-3:", "--accent:", "--rule:", "--display:", "--mono:" }) |v| {
        try t.expect(std.mem.indexOf(u8, page, v) != null);
    }
}

test "render emits ledger chrome: masthead count, chips, search, script" {
    const lib = library.Library{ .root = "/x", .name = "Acme", .tag = "Tag Line", .port = 8789 };
    const items = [_]Item{.{ .label = "Doc", .href = "/doc", .path = "/doc.html", .section = "advisory", .mtime_sec = 86400 }};
    const page = try render(t.allocator, lib, &items);
    defer t.allocator.free(page);
    try t.expect(std.mem.indexOf(u8, page, "class=\"masthead\"") != null);
    try t.expect(std.mem.indexOf(u8, page, "<span class=\"n\">1</span>") != null);
    try t.expect(std.mem.indexOf(u8, page, "data-group=\"*\"") != null);
    try t.expect(std.mem.indexOf(u8, page, "data-group=\"section\" data-value=\"advisory\"") != null);
    try t.expect(std.mem.indexOf(u8, page, "class=\"searchrule\"") != null);
    try t.expect(std.mem.indexOf(u8, page, "class=\"ledger\"") != null);
    try t.expect(std.mem.indexOf(u8, page, "id=\"atelier-corpus\"") != null);
    try t.expect(std.mem.indexOf(u8, page, "class=\"sorts\"") != null);
    try t.expect(std.mem.indexOf(u8, page, "data-sort=\"match\"") != null);
    try t.expect(std.mem.indexOf(u8, page, "class=\"results\"") != null);
    try t.expect(std.mem.indexOf(u8, page, "addEventListener") != null);
    try t.expect(std.mem.indexOf(u8, page, "{{") == null);
    try t.expect(std.mem.indexOf(u8, page, "src=") == null); // self-contained: no external requests
}

test "dateParts converts epoch seconds to UTC civil parts" {
    const epoch = dateParts(0); // 1970-01-01 was a Thursday
    try t.expectEqual(@as(i32, 1970), epoch.year);
    try t.expectEqual(@as(u8, 1), epoch.month);
    try t.expectEqual(@as(u8, 1), epoch.day);
    try t.expectEqual(@as(u8, 4), epoch.weekday);
    try t.expectEqual(@as(u8, 0), epoch.hour);

    const late = dateParts(86399); // same day, 23:59:59
    try t.expectEqual(@as(u8, 1), late.day);
    try t.expectEqual(@as(u8, 23), late.hour);
    try t.expectEqual(@as(u8, 59), late.minute);

    const next = dateParts(86400); // 1970-01-02, Friday
    try t.expectEqual(@as(u8, 2), next.day);
    try t.expectEqual(@as(u8, 5), next.weekday);

    const modern = dateParts(1783778520); // 2026-07-11 14:02 UTC, a Saturday
    try t.expectEqual(@as(i32, 2026), modern.year);
    try t.expectEqual(@as(u8, 7), modern.month);
    try t.expectEqual(@as(u8, 11), modern.day);
    try t.expectEqual(@as(u8, 6), modern.weekday);
    try t.expectEqual(@as(u8, 14), modern.hour);
    try t.expectEqual(@as(u8, 2), modern.minute);
}

test "renderChips emits all plus distinct section, agent, client chips" {
    const items = [_]Item{
        .{ .label = "A", .href = "/a", .path = "/a.html", .section = "advisory", .meta = &.{ .{ .key = "agent", .value = "donna" }, .{ .key = "client", .value = "globex" } } },
        .{ .label = "B", .href = "/b", .path = "/b.html", .section = "advisory", .meta = &.{.{ .key = "agent", .value = "claude" }} },
        .{ .label = "C", .href = "/c", .path = "/c.html" },
    };
    const out = try renderChips(t.allocator, &items);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "data-group=\"*\"") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, out, "data-value=\"advisory\""));
    try t.expect(std.mem.indexOf(u8, out, "data-group=\"agent\" data-value=\"donna\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "data-group=\"agent\" data-value=\"claude\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "data-group=\"client\" data-value=\"globex\"") != null);
}

test "renderChips omits empty groups and their separators" {
    const items = [_]Item{.{ .label = "C", .href = "/c", .path = "/c.html" }};
    const out = try renderChips(t.allocator, &items);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "data-group=\"*\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "data-group=\"section\"") == null);
    try t.expect(std.mem.indexOf(u8, out, "class=\"dot\"") == null);
}

test "extractText strips tags, drops script and style, decodes, lowercases" {
    const html =
        \\<head><style>.x{color:red}</style><script>var a = 1 < 2;</script></head>
        \\<body><h1>Big &amp; Bold</h1>  <p>Two   words&#39;s &lt;tag&gt;</p></body>
    ;
    const out = try extractText(t.allocator, html);
    defer t.allocator.free(out);
    try t.expectEqualStrings("big & bold two words's <tag>", out);
}

test "extractText separates words that only tags separated" {
    // Regression: "Letter</title><body>Enforcement" must not fuse into one
    // vocabulary word; a tag boundary is a word boundary.
    const out = try extractText(t.allocator, "<title>Letter</title><body><p>Enforcement</p></body>");
    defer t.allocator.free(out);
    try t.expectEqualStrings("letter enforcement", out);
}

test "extractText caps output at text_bytes_max" {
    const big = try t.allocator.alloc(u8, text_bytes_max * 2);
    defer t.allocator.free(big);
    @memset(big, 'a');
    const out = try extractText(t.allocator, big);
    defer t.allocator.free(out);
    try t.expectEqual(@as(usize, text_bytes_max), out.len);
}

test "renderCorpus maps hrefs to text with json and angle escaping" {
    const items = [_]Item{.{ .label = "A", .href = "/a", .path = "/a.html", .text = "he said \"hi\" 1 < 2" }};
    const out = try renderCorpus(t.allocator, &items);
    defer t.allocator.free(out);
    try t.expectEqualStrings("{\"/a\":\"he said \\\"hi\\\" 1 \\u003c 2\"}", out);
}

test "extractTitle basic and missing" {
    try t.expectEqualStrings("Hi", extractTitle("<head><title> Hi </title></head>").?);
    try t.expect(extractTitle("<p>no title</p>") == null);
}

test "generate lists pages, skips index.html and templates/" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{\"name\":\"Acme, Inc\",\"tag\":\"Advise\"}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "index.html", .data = "old" });
    try tmp.dir.createDirPath(t.io, "templates");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "templates/master.html", .data = "<title>Master</title>" });
    try tmp.dir.createDirPath(t.io, "advisory");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "advisory/one.html", .data = "<title>One Pager</title>" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "plain.html", .data = "no title here" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = library.Library{ .root = root, .name = "Acme, Inc", .tag = "Advise", .port = 8789 };
    const page = try generate(t.allocator, t.io, lib);
    defer t.allocator.free(page);
    try t.expect(std.mem.indexOf(u8, page, "href=\"/advisory/one\"") != null);
    try t.expect(std.mem.indexOf(u8, page, "One Pager") != null);
    try t.expect(std.mem.indexOf(u8, page, "plain.html") != null); // label falls back to relpath
    try t.expect(std.mem.indexOf(u8, page, "Master") == null); // templates/ excluded
    try t.expect(std.mem.indexOf(u8, page, "Acme<span class=\"r\">,</span> Inc") != null);
    try t.expect(std.mem.indexOf(u8, page, "<title>Acme, Inc &middot; Atelier</title>") != null);
}

test "render with the neutral theme is brand-free and self-contained" {
    const items = [_]Item{.{ .label = "One Pager", .href = "/advisory/one", .path = "/advisory/one.html" }};
    const lib = library.Library{ .root = "/x", .name = "Acme, Inc", .tag = "Advise", .port = 8789 };
    const page = try render(t.allocator, lib, &items);
    defer t.allocator.free(page);
    try t.expect(std.mem.indexOf(u8, page, "<title>Acme, Inc &middot; Atelier</title>") != null);
    try t.expect(std.mem.indexOf(u8, page, "<div class=\"tag\">Advise</div>") != null);
    try t.expect(std.mem.indexOf(u8, page, "href=\"/advisory/one\"") != null);
    // Neutral defaults, no baked-in brand, no external requests.
    try t.expect(std.mem.indexOf(u8, page, "--accent:#1c1c1c") != null);
    try t.expect(std.mem.indexOf(u8, page, "system-ui,sans-serif") != null);
    try t.expect(std.mem.indexOf(u8, page, "<link") == null);
    try t.expect(std.mem.indexOf(u8, page, "Fraunces") == null);
    try t.expect(std.mem.indexOf(u8, page, "9a3b32") == null);
    // No leftover placeholders from the built-in shell.
    try t.expect(std.mem.indexOf(u8, page, "{{") == null);
}

test "render applies the manifest theme" {
    const themed = library.Library{
        .root = "/x",
        .name = "Acme, Inc",
        .tag = "Advise",
        .port = 8789,
        .theme = .{
            .accent = "#9a3b32",
            .display_font = "'Fraunces',Georgia,serif",
            .font_link = "https://fonts.example/css",
        },
    };
    const page = try render(t.allocator, themed, &.{});
    defer t.allocator.free(page);
    try t.expect(std.mem.indexOf(u8, page, "--accent:#9a3b32") != null);
    try t.expect(std.mem.indexOf(u8, page, "'Fraunces',Georgia,serif") != null);
    try t.expect(std.mem.indexOf(u8, page, "<link href=\"https://fonts.example/css\" rel=\"stylesheet\">") != null);
}

test "render omits the tag div when tag is empty" {
    const lib = library.Library{ .root = "/x", .name = "Atelier", .tag = "", .port = 8789 };
    const page = try render(t.allocator, lib, &.{});
    defer t.allocator.free(page);
    try t.expect(std.mem.indexOf(u8, page, "class=\"tag\"") == null);
}

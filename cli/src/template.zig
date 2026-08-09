const std = @import("std");
const library = @import("library.zig");

pub const FillResult = struct { out: []u8, unfilled: [][]const u8 };

fn isIdentChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Replaces `{{IDENT}}` placeholders (IDENT matching `[A-Z0-9_]+`) in
/// `input` with values from `kv`. Braces that don't form a well-formed
/// placeholder (lowercase idents, single braces, empty idents) pass
/// through untouched. Placeholders with no entry in `kv` are left as-is
/// in the output and their identifiers are collected in `unfilled`, each
/// listed once, in first-seen order.
pub fn fill(alloc: std.mem.Allocator, input: []const u8, kv: *const std.StringHashMap([]const u8)) !FillResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var unfilled: std.ArrayList([]const u8) = .empty;
    errdefer unfilled.deinit(alloc);

    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '{' and input[i + 1] == '{') {
            var j = i + 2;
            while (j < input.len and isIdentChar(input[j])) j += 1;
            if (j > i + 2 and j + 1 < input.len and input[j] == '}' and input[j + 1] == '}') {
                const ident = input[i + 2 .. j];
                std.debug.assert(ident.len > 0);
                if (kv.get(ident)) |val| {
                    try out.appendSlice(alloc, val);
                } else {
                    try out.appendSlice(alloc, input[i .. j + 2]);
                    var seen = false;
                    for (unfilled.items) |u| {
                        if (std.mem.eql(u8, u, ident)) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) try unfilled.append(alloc, ident);
                }
                i = j + 2;
                continue;
            }
        }
        try out.append(alloc, input[i]);
        i += 1;
    }
    // Both increments preserve i <= input.len, so the scan must land
    // exactly on the end; anything else means bytes were skipped or read
    // past the input.
    std.debug.assert(i == input.len);
    return .{ .out = try out.toOwnedSlice(alloc), .unfilled = try unfilled.toOwnedSlice(alloc) };
}

/// Upper bound on a template read; matches the page-read cap used across
/// the CLI commands.
pub const template_bytes_max = 4 * 1024 * 1024;

/// Paths `scaffold` computed before it failed, so callers can print the
/// same actionable messages `atelier new` always has ("no template at
/// <abs>", "refusing to overwrite <abs>") without recomputing the name
/// rules. Zig errors carry no payload; this is the conventional out-param
/// diagnostic instead.
pub const ScaffoldDiag = struct {
    template_abs: []const u8 = "",
    dest_abs: []const u8 = "",
};

pub const ScaffoldResult = struct {
    dest_abs: []u8,
    /// Library-relative destination with the `.html` appended, the form
    /// served URLs and tool results speak.
    dest_rel: []u8,
    unfilled: [][]const u8,
};

/// Scaffolds `<root>/<dest>` from `<root>/templates/<template_name>`,
/// appending `.html` to either name when missing. `{{BRAND_*}}` tokens
/// are seeded from the library's resolved theme before `user_vars` is
/// merged, so user pairs win; masters keep one palette source. Reads the
/// template before checking the destination so a missing template is
/// reported even when the destination also exists, the order `atelier
/// new` has always had. Refuses to overwrite. Allocations live on
/// `alloc` (callers run on an arena or free via the result fields).
pub fn scaffold(
    alloc: std.mem.Allocator,
    io: std.Io,
    lib: library.Library,
    template_name: []const u8,
    dest: []const u8,
    user_vars: *const std.StringHashMap([]const u8),
    diag: *ScaffoldDiag,
) !ScaffoldResult {
    std.debug.assert(template_name.len > 0);
    std.debug.assert(dest.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(lib.root));

    var kv = std.StringHashMap([]const u8).init(alloc);
    defer kv.deinit();
    try kv.put("BRAND_PAPER", lib.theme.paper);
    try kv.put("BRAND_INK", lib.theme.ink);
    try kv.put("BRAND_MUTED", lib.theme.muted);
    try kv.put("BRAND_ACCENT", lib.theme.accent);
    try kv.put("BRAND_RULE", lib.theme.rule);
    try kv.put("BRAND_DISPLAY_FONT", lib.theme.display_font);
    try kv.put("BRAND_MONO_FONT", lib.theme.mono_font);
    try kv.put("BRAND_FONT_LINK", lib.theme.font_link);
    var user_entries = user_vars.iterator();
    while (user_entries.next()) |entry| {
        try kv.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    const template_file = if (std.mem.endsWith(u8, template_name, ".html"))
        template_name
    else
        try std.fmt.allocPrint(alloc, "{s}.html", .{template_name});
    const template_abs = try std.fs.path.join(alloc, &.{ lib.root, "templates", template_file });
    diag.template_abs = template_abs;
    const source = std.Io.Dir.cwd().readFileAlloc(io, template_abs, alloc, .limited(template_bytes_max)) catch |e| switch (e) {
        error.FileNotFound => return error.TemplateNotFound,
        else => return e,
    };

    const dest_rel = if (std.mem.endsWith(u8, dest, ".html"))
        try alloc.dupe(u8, dest)
    else
        try std.fmt.allocPrint(alloc, "{s}.html", .{dest});
    const dest_abs = try std.fs.path.join(alloc, &.{ lib.root, dest_rel });
    diag.dest_abs = dest_abs;
    if (std.Io.Dir.cwd().access(io, dest_abs, .{})) |_| {
        return error.DestinationExists;
    } else |_| {} // any access failure means no existing file to protect; the write below surfaces real errors

    const filled = try fill(alloc, source, &kv);
    if (std.fs.path.dirname(dest_abs)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_abs, .data = filled.out });
    return .{ .dest_abs = dest_abs, .dest_rel = dest_rel, .unfilled = filled.unfilled };
}

const t = std.testing;

fn mkKv(alloc: std.mem.Allocator) std.StringHashMap([]const u8) {
    return std.StringHashMap([]const u8).init(alloc);
}

test "fills known placeholders" {
    var kv = mkKv(t.allocator);
    defer kv.deinit();
    try kv.put("CLIENT_NAME", "OM VC");
    const r = try fill(t.allocator, "Dear {{CLIENT_NAME}},", &kv);
    defer t.allocator.free(r.out);
    defer t.allocator.free(r.unfilled);
    try t.expectEqualStrings("Dear OM VC,", r.out);
    try t.expectEqual(@as(usize, 0), r.unfilled.len);
}

test "reports each unfilled placeholder once, preserves it in output" {
    var kv = mkKv(t.allocator);
    defer kv.deinit();
    const r = try fill(t.allocator, "{{A}} {{B}} {{A}}", &kv);
    defer t.allocator.free(r.out);
    defer t.allocator.free(r.unfilled);
    try t.expectEqualStrings("{{A}} {{B}} {{A}}", r.out);
    try t.expectEqual(@as(usize, 2), r.unfilled.len);
    try t.expectEqualStrings("A", r.unfilled[0]);
    try t.expectEqualStrings("B", r.unfilled[1]);
}

test "lowercase braces are not placeholders" {
    var kv = mkKv(t.allocator);
    defer kv.deinit();
    const r = try fill(t.allocator, "{{not_a_slot}} and {single}", &kv);
    defer t.allocator.free(r.out);
    defer t.allocator.free(r.unfilled);
    try t.expectEqualStrings("{{not_a_slot}} and {single}", r.out);
    try t.expectEqual(@as(usize, 0), r.unfilled.len);
}

/// A hand-built library rooted at `root`; references literals plus the
/// caller's root, so it must not be deinited (see `library.Library`).
fn testLibrary(root: []const u8) library.Library {
    return .{ .root = root, .name = "Test", .tag = "", .port = 8789 };
}

test "scaffold seeds brand tokens, lets user vars win, reports unfilled" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "templates");
    try tmp.dir.writeFile(t.io, .{
        .sub_path = "templates/memo.html",
        .data = "<b>{{BRAND_ACCENT}}</b> {{CLIENT}} {{MISSING}}",
    });

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var user_vars = mkKv(a);
    try user_vars.put("BRAND_ACCENT", "#custom");
    try user_vars.put("CLIENT", "OM VC");

    var diag: ScaffoldDiag = .{};
    const r = try scaffold(a, t.io, testLibrary(root), "memo", "notes/first", &user_vars, &diag);
    try t.expectEqualStrings("notes/first.html", r.dest_rel);
    try t.expectEqual(@as(usize, 1), r.unfilled.len);
    try t.expectEqualStrings("MISSING", r.unfilled[0]);

    const written = try tmp.dir.readFileAlloc(t.io, "notes/first.html", t.allocator, .limited(4096));
    defer t.allocator.free(written);
    try t.expectEqualStrings("<b>#custom</b> OM VC {{MISSING}}", written);
}

test "scaffold fills brand tokens from the library theme by default" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "templates");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "templates/memo.html", .data = "{{BRAND_PAPER}}" });

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var user_vars = mkKv(a);
    var diag: ScaffoldDiag = .{};
    _ = try scaffold(a, t.io, testLibrary(root), "memo", "out", &user_vars, &diag);

    const written = try tmp.dir.readFileAlloc(t.io, "out.html", t.allocator, .limited(4096));
    defer t.allocator.free(written);
    try t.expectEqualStrings(library.Theme.neutral.paper, written);
}

test "scaffold refuses to overwrite and names the destination" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "templates");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "templates/memo.html", .data = "x" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "taken.html", .data = "keep me" });

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var user_vars = mkKv(a);
    var diag: ScaffoldDiag = .{};
    try t.expectError(
        error.DestinationExists,
        scaffold(a, t.io, testLibrary(root), "memo", "taken", &user_vars, &diag),
    );
    try t.expect(std.mem.endsWith(u8, diag.dest_abs, "/taken.html"));

    const kept = try tmp.dir.readFileAlloc(t.io, "taken.html", t.allocator, .limited(64));
    defer t.allocator.free(kept);
    try t.expectEqualStrings("keep me", kept);
}

test "scaffold on a missing template fails before touching the destination" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var user_vars = mkKv(a);
    var diag: ScaffoldDiag = .{};
    try t.expectError(
        error.TemplateNotFound,
        scaffold(a, t.io, testLibrary(root), "ghost", "anything", &user_vars, &diag),
    );
    try t.expect(std.mem.endsWith(u8, diag.template_abs, "/templates/ghost.html"));
    try t.expectError(error.FileNotFound, tmp.dir.readFileAlloc(t.io, "anything.html", t.allocator, .limited(64)));
}

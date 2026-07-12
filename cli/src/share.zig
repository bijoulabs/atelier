const std = @import("std");
const index = @import("index.zig");

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
/// recipient ("-" when none), output basename. Trailing newline included.
pub fn logLine(alloc: std.mem.Allocator, date: []const u8, rev: []const u8, rel: []const u8, recipient: ?[]const u8, out_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\t{s}\t{s}\t{s}\t{s}\n", .{ date, rev, rel, recipient orelse "-", out_name });
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
    const l = try logLine(t.allocator, "2026-07-12", "abc1234", "advisory/memo.html", null, "memo.pdf");
    defer t.allocator.free(l);
    try t.expectEqualStrings("2026-07-12\tabc1234\tadvisory/memo.html\t-\tmemo.pdf\n", l);
}

test "isoDate formats UTC" {
    const s = try isoDate(t.allocator, 1783778520); // 2026-07-11 14:02 UTC
    defer t.allocator.free(s);
    try t.expectEqualStrings("2026-07-11", s);
}

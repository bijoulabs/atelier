//! The one JSON string writer in the binary. Hand-rolled on purpose: a
//! handful of escapes is the whole grammar we emit, and `std.json`'s API
//! churns across dev versions. Moved out of `history.zig` when themes
//! and the diff page needed the same escaping.

const std = @import("std");

/// Appends `s` to `out` as a complete quoted JSON string. The escaping
/// (see `appendEscaped`) also covers `<` and `>`, so the result is safe
/// to embed inside an HTML `<script>` element: a literal `</script>` in
/// `s` cannot terminate the element early.
pub fn appendString(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    try appendEscaped(out, alloc, s);
    try out.append(alloc, '"');
}

/// Appends `s` to `out` as JSON string content: `"` and `\` get a
/// backslash escape, control characters and angle brackets become
/// `\u00XX` (angle brackets so the output can sit inside `<script>`,
/// see `appendString`), everything else passes through byte for byte
/// (UTF-8 is valid JSON as-is).
fn appendEscaped(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        0x00...0x1f, '<', '>' => {
            var buf: [6]u8 = undefined;
            const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
            std.debug.assert(esc.len == 6);
            try out.appendSlice(alloc, esc);
        },
        else => try out.append(alloc, c),
    };
}

const t = std.testing;

test "appendString quotes, escapes, and defuses script closers" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try appendString(&out, t.allocator, "a\"b</script><i>");
    try t.expectEqualStrings("\"a\\\"b\\u003c/script\\u003e\\u003ci\\u003e\"", out.items);
}

test "appendString passes plain text and escapes controls" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try appendString(&out, t.allocator, "plain\ttab");
    try t.expectEqualStrings("\"plain\\u0009tab\"", out.items);
}

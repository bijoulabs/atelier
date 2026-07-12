const std = @import("std");

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

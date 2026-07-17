//! Per-page git history for `atelier serve`'s time travel: parse `git log`
//! output into commits, render them as JSON for the injected widget, and
//! read a file's content as of a given commit. The spawn wrappers degrade
//! to "no history" on any failure (git absent, not a repository), the same
//! contract as `index.zig`'s revision counts.

const std = @import("std");

/// One commit touching a page: abbreviated sha, short date, subject line.
/// All fields are slices into the `git log` output they were parsed from;
/// they live exactly as long as that buffer (callers run on an arena).
pub const Commit = struct {
    sha: []const u8,
    date: []const u8,
    subject: []const u8,
};

/// The `git log` format producing one `sha<TAB>date<TAB>subject` line per
/// commit; `parseLog` is its exact inverse.
pub const log_format = "--format=%h%x09%ad%x09%s";

/// Parses `git log` output in `log_format` shape into commits, newest
/// first (git's own order, preserved). Blank and malformed lines (fewer
/// than two tabs) are skipped rather than erroring: this input crosses a
/// process boundary and is not ours to trust. Returned commits alias
/// `output`; the caller owns the returned slice.
pub fn parseLog(alloc: std.mem.Allocator, output: []const u8) ![]Commit {
    var commits: std.ArrayList(Commit) = .empty;
    errdefer commits.deinit(alloc);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const tab1 = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const tab2 = std.mem.indexOfScalarPos(u8, line, tab1 + 1, '\t') orelse continue;
        const commit: Commit = .{
            .sha = line[0..tab1],
            .date = line[tab1 + 1 .. tab2],
            .subject = line[tab2 + 1 ..],
        };
        if (!isCommitSha(commit.sha)) continue;
        try commits.append(alloc, commit);
    }
    return try commits.toOwnedSlice(alloc);
}

/// Renders commits as a JSON array of `{"sha","date","subject"}` objects.
/// Caller owns the returned buffer.
pub fn renderJson(alloc: std.mem.Allocator, commits: []const Commit) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '[');
    for (commits, 0..) |c, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"sha\":\"");
        try appendJsonEscaped(&out, alloc, c.sha);
        try out.appendSlice(alloc, "\",\"date\":\"");
        try appendJsonEscaped(&out, alloc, c.date);
        try out.appendSlice(alloc, "\",\"subject\":\"");
        try appendJsonEscaped(&out, alloc, c.subject);
        try out.appendSlice(alloc, "\"}");
    }
    try out.append(alloc, ']');
    const json = try out.toOwnedSlice(alloc);
    std.debug.assert(json.len >= 2);
    std.debug.assert(json[0] == '[');
    std.debug.assert(json[json.len - 1] == ']');
    return json;
}

/// Appends `s` to `out` as JSON string content: `"` and `\` get a
/// backslash escape, control characters become `\u00XX`, everything else
/// passes through byte for byte (UTF-8 is valid JSON as-is). Hand-rolled
/// on purpose: the three escapes above are the whole JSON string grammar
/// we need, and `std.json`'s API churns across dev versions.
fn appendJsonEscaped(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        0x00...0x1f => {
            var buf: [6]u8 = undefined;
            const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
            std.debug.assert(esc.len == 6);
            try out.appendSlice(alloc, esc);
        },
        else => try out.append(alloc, c),
    };
}

/// Whether `s` is a plausible git commit sha: 7 to 40 hex digits. This is
/// the gate between URL input and the `git show` argv, so it is
/// deliberately strict.
pub fn isCommitSha(s: []const u8) bool {
    if (s.len < 7 or s.len > 40) return false;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => {},
        else => return false,
    };
    return true;
}

/// Upper bound on `git log` output we are willing to parse for one page.
/// A thousand commits of tab-separated one-liners fit with room to spare;
/// beyond that the tail is truncated and the oldest commits drop off.
pub const log_bytes_max = 1024 * 1024;

/// Commits touching `rel` in the repository at `root`, newest first, or
/// an empty slice when git is unavailable, `root` is not a repository, or
/// the page has no history; the widget hides itself either way. No
/// `--follow`: history stops at the page's last rename, a shorter list
/// rather than a broken one (an old sha would hold the file under its old
/// path, which the snapshot URL would not know). The returned commits
/// alias the captured stdout, which is left for `alloc` to reclaim:
/// callers run on an arena.
pub fn pageLog(alloc: std.mem.Allocator, io: std.Io, root: []const u8, rel: []const u8) []Commit {
    std.debug.assert(rel.len > 0);
    std.debug.assert(!std.fs.path.isAbsolute(rel));
    const run = std.process.run(alloc, io, .{
        .argv = &.{ "git", "-C", root, "log", log_format, "--date=short", "--", rel },
        .stdout_limit = .limited(log_bytes_max),
        .stderr_limit = .limited(4096),
    }) catch return &.{};
    switch (run.term) {
        .exited => |code| if (code != 0) return &.{},
        else => return &.{},
    }
    return parseLog(alloc, run.stdout) catch &.{};
}

/// The content of `rel` as of commit `sha` in the repository at `root`,
/// or null when git is unavailable or `sha:rel` names nothing (bad sha,
/// file absent at that commit). `bytes_max` bounds the read, the same
/// contract as serving a working-tree file. Caller keeps the buffer's
/// allocator alive (callers run on an arena).
pub fn showFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    sha: []const u8,
    rel: []const u8,
    bytes_max: usize,
) ?[]u8 {
    // Paired with `mapPath`'s validation: the sha lands in an argv, so it
    // must already be pure hex, and the rel must be root-relative.
    std.debug.assert(isCommitSha(sha));
    std.debug.assert(rel.len > 0);
    std.debug.assert(!std.fs.path.isAbsolute(rel));
    const spec = std.fmt.allocPrint(alloc, "{s}:{s}", .{ sha, rel }) catch return null;
    const run = std.process.run(alloc, io, .{
        .argv = &.{ "git", "-C", root, "show", spec },
        .stdout_limit = .limited(bytes_max),
        .stderr_limit = .limited(4096),
    }) catch return null;
    switch (run.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return run.stdout;
}

const t = std.testing;

test "parseLog splits tab-separated commits, newest first" {
    const out = "abc1234\t2026-07-01\tfirst subject\ndef5678\t2026-06-20\tsecond subject\n";
    const commits = try parseLog(t.allocator, out);
    defer t.allocator.free(commits);
    try t.expectEqual(@as(usize, 2), commits.len);
    try t.expectEqualStrings("abc1234", commits[0].sha);
    try t.expectEqualStrings("2026-07-01", commits[0].date);
    try t.expectEqualStrings("first subject", commits[0].subject);
    try t.expectEqualStrings("def5678", commits[1].sha);
}

test "parseLog keeps tabs inside the subject" {
    const commits = try parseLog(t.allocator, "abc1234\t2026-07-01\ta\tb\tc\n");
    defer t.allocator.free(commits);
    try t.expectEqual(@as(usize, 1), commits.len);
    try t.expectEqualStrings("a\tb\tc", commits[0].subject);
}

test "parseLog skips blank and malformed lines" {
    const out = "\nabc1234\t2026-07-01\tok\nnot a commit line\nonlyone\ttab\n\n";
    const commits = try parseLog(t.allocator, out);
    defer t.allocator.free(commits);
    try t.expectEqual(@as(usize, 1), commits.len);
    try t.expectEqualStrings("ok", commits[0].subject);
}

test "parseLog of empty output is empty" {
    const commits = try parseLog(t.allocator, "");
    defer t.allocator.free(commits);
    try t.expectEqual(@as(usize, 0), commits.len);
}

test "renderJson renders the three fields per commit" {
    const commits = [_]Commit{
        .{ .sha = "abc1234", .date = "2026-07-01", .subject = "hello" },
        .{ .sha = "def5678", .date = "2026-06-20", .subject = "world" },
    };
    const json = try renderJson(t.allocator, &commits);
    defer t.allocator.free(json);
    try t.expectEqualStrings(
        "[{\"sha\":\"abc1234\",\"date\":\"2026-07-01\",\"subject\":\"hello\"}," ++
            "{\"sha\":\"def5678\",\"date\":\"2026-06-20\",\"subject\":\"world\"}]",
        json,
    );
}

test "renderJson escapes quotes, backslashes, and control characters" {
    const commits = [_]Commit{
        .{ .sha = "abc1234", .date = "2026-07-01", .subject = "say \"hi\" \\ back\ttab\nnl" },
    };
    const json = try renderJson(t.allocator, &commits);
    defer t.allocator.free(json);
    try t.expectEqualStrings(
        "[{\"sha\":\"abc1234\",\"date\":\"2026-07-01\"," ++
            "\"subject\":\"say \\\"hi\\\" \\\\ back\\u0009tab\\u000anl\"}]",
        json,
    );
}

test "renderJson of no commits is an empty array" {
    const json = try renderJson(t.allocator, &.{});
    defer t.allocator.free(json);
    try t.expectEqualStrings("[]", json);
}

test "isCommitSha accepts 7 to 40 hex digits and nothing else" {
    try t.expect(isCommitSha("abc1234"));
    try t.expect(isCommitSha("ABC1234"));
    try t.expect(isCommitSha("0123456789abcdef0123456789abcdef01234567"));
    // Negative space: too short, too long, non-hex, empty, path characters.
    try t.expect(!isCommitSha("abc123"));
    try t.expect(!isCommitSha("0123456789abcdef0123456789abcdef012345678"));
    try t.expect(!isCommitSha("abc123g"));
    try t.expect(!isCommitSha(""));
    try t.expect(!isCommitSha("abc1234/.."));
}

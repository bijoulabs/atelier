//! Per-page git history for `atelier serve`'s time travel: parse `git log`
//! output into commits, render them as JSON for the injected widget, and
//! read a file's content as of a given commit. The spawn wrappers degrade
//! to "no history" on any failure (git absent, not a repository), the same
//! contract as `index.zig`'s revision counts.

const std = @import("std");
const json = @import("json.zig");

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
        try out.appendSlice(alloc, "{\"sha\":");
        try json.appendString(&out, alloc, c.sha);
        try out.appendSlice(alloc, ",\"date\":");
        try json.appendString(&out, alloc, c.date);
        try out.appendSlice(alloc, ",\"subject\":");
        try json.appendString(&out, alloc, c.subject);
        try out.appendSlice(alloc, "}");
    }
    try out.append(alloc, ']');
    const rendered = try out.toOwnedSlice(alloc);
    std.debug.assert(rendered.len >= 2);
    std.debug.assert(rendered[0] == '[');
    std.debug.assert(rendered[rendered.len - 1] == ']');
    return rendered;
}

/// Appends `s` to `out` as a complete quoted JSON string; see
/// `json.appendString`, which this forwards to (kept here so history's
/// callers read naturally).
pub fn appendJsonString(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try json.appendString(out, alloc, s);
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

/// Upper bound on stdout/stderr captured from the git write plumbing.
/// Commit output is a handful of lines; a limit this generous only exists
/// because every external read must have one.
const commit_output_bytes_max = 64 * 1024;

/// Outcome of `commitPaths`: whether a commit was created, its short sha,
/// and, when nothing was committed or the sha lookup failed, one lowercase
/// actionable line for the caller to surface. Deliberately not an error
/// union: the server treats git as optional the same way `pageLog` does,
/// so a missing repository degrades the report, never the write that
/// preceded it.
pub const CommitOutcome = struct {
    committed: bool,
    sha: []const u8 = "-",
    note: []const u8 = "",
};

/// Argv staging exactly `rel_paths` and nothing else: the `--` pathspec
/// separator keeps anything the owner staged by hand out of the server's
/// commit. Pure so tests pin the exact shape without spawning git; the
/// caller owns the returned slice (callers run on an arena).
pub fn addArgv(
    alloc: std.mem.Allocator,
    root: []const u8,
    rel_paths: []const []const u8,
) ![]const []const u8 {
    std.debug.assert(rel_paths.len > 0);
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "git", "-C", root, "add", "--" });
    try argv.appendSlice(alloc, rel_paths);
    return try argv.toOwnedSlice(alloc);
}

/// Argv for the commit itself, pathspec-limited like `addArgv`. `author`
/// carries remote attribution ("user via machine <email>"); null commits
/// as the repository's own configured identity, which stays the committer
/// either way. Pure for the same testability reason as `addArgv`.
pub fn commitArgv(
    alloc: std.mem.Allocator,
    root: []const u8,
    message: []const u8,
    author: ?[]const u8,
    rel_paths: []const []const u8,
) ![]const []const u8 {
    std.debug.assert(message.len > 0);
    std.debug.assert(rel_paths.len > 0);
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "git", "-C", root, "commit" });
    if (author) |a| try argv.appendSlice(alloc, &.{ "--author", a });
    try argv.appendSlice(alloc, &.{ "-m", message, "--" });
    try argv.appendSlice(alloc, rel_paths);
    return try argv.toOwnedSlice(alloc);
}

/// The first non-blank line of subprocess output, trimmed; empty when the
/// output is all whitespace. Git failure messages are one useful line
/// followed by hints, and only the useful line belongs in a tool result.
fn firstNonEmptyLine(output: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0) return line;
    }
    return "";
}

/// Runs one git plumbing step; returns null on success, or the one-line
/// reason on any failure (spawn failure, nonzero exit). Helpers compute,
/// `commitPaths` decides.
fn runGitStep(
    alloc: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    spawn_failure_note: []const u8,
) ?[]const u8 {
    const run = std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(commit_output_bytes_max),
        .stderr_limit = .limited(commit_output_bytes_max),
    }) catch return spawn_failure_note;
    switch (run.term) {
        .exited => |code| if (code == 0) return null,
        else => {},
    }
    // Git writes errors to stderr, but some refusals ("nothing to
    // commit") land on stdout; report whichever spoke.
    const stderr_line = firstNonEmptyLine(run.stderr);
    if (stderr_line.len > 0) return stderr_line;
    const stdout_line = firstNonEmptyLine(run.stdout);
    if (stdout_line.len > 0) return stdout_line;
    return "git exited nonzero with no output";
}

/// Stages exactly `rel_paths` and commits them with `message`, optionally
/// attributed to `author` (see `commitArgv`). Never returns an error: a
/// missing git binary, a root outside any repository, or a failing commit
/// all come back as `committed = false` with an actionable note, because
/// the file writes that preceded this call stand regardless and the
/// caller must be able to say so. Allocations live on `alloc` (callers
/// run on an arena).
pub fn commitPaths(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    rel_paths: []const []const u8,
    message: []const u8,
    author: ?[]const u8,
) CommitOutcome {
    std.debug.assert(rel_paths.len > 0);
    std.debug.assert(message.len > 0);
    for (rel_paths) |rel| {
        std.debug.assert(rel.len > 0);
        std.debug.assert(!std.fs.path.isAbsolute(rel));
    }

    const add_argv = addArgv(alloc, root, rel_paths) catch
        return .{ .committed = false, .note = "out of memory staging the commit" };
    if (runGitStep(alloc, io, add_argv, "git is not available, commit skipped")) |note| {
        return .{ .committed = false, .note = note };
    }

    const commit_argv = commitArgv(alloc, root, message, author, rel_paths) catch
        return .{ .committed = false, .note = "out of memory staging the commit" };
    if (runGitStep(alloc, io, commit_argv, "git is not available, commit skipped")) |note| {
        return .{ .committed = false, .note = note };
    }

    const rev_run = std.process.run(alloc, io, .{
        .argv = &.{ "git", "-C", root, "rev-parse", "--short", "HEAD" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return .{ .committed = true, .note = "committed, but the sha lookup failed" };
    const sha = firstNonEmptyLine(rev_run.stdout);
    if (!isCommitSha(sha)) {
        return .{ .committed = true, .note = "committed, but the sha lookup failed" };
    }
    return .{ .committed = true, .sha = sha };
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
    const rendered = try renderJson(t.allocator, &commits);
    defer t.allocator.free(rendered);
    try t.expectEqualStrings(
        "[{\"sha\":\"abc1234\",\"date\":\"2026-07-01\",\"subject\":\"hello\"}," ++
            "{\"sha\":\"def5678\",\"date\":\"2026-06-20\",\"subject\":\"world\"}]",
        rendered,
    );
}

test "renderJson escapes quotes, backslashes, and control characters" {
    const commits = [_]Commit{
        .{ .sha = "abc1234", .date = "2026-07-01", .subject = "say \"hi\" \\ back\ttab\nnl" },
    };
    const rendered = try renderJson(t.allocator, &commits);
    defer t.allocator.free(rendered);
    try t.expectEqualStrings(
        "[{\"sha\":\"abc1234\",\"date\":\"2026-07-01\"," ++
            "\"subject\":\"say \\\"hi\\\" \\\\ back\\u0009tab\\u000anl\"}]",
        rendered,
    );
}

test "renderJson of no commits is an empty array" {
    const rendered = try renderJson(t.allocator, &.{});
    defer t.allocator.free(rendered);
    try t.expectEqualStrings("[]", rendered);
}

test "addArgv stages exactly the given paths behind a pathspec separator" {
    const argv = try addArgv(t.allocator, "/lib", &.{ "advisory/one.html", "shares.log" });
    defer t.allocator.free(argv);
    const want = [_][]const u8{
        "git", "-C", "/lib", "add", "--", "advisory/one.html", "shares.log",
    };
    try t.expectEqual(want.len, argv.len);
    for (want, argv) |w, got| try t.expectEqualStrings(w, got);
}

test "commitArgv carries the author override when attribution is known" {
    const argv = try commitArgv(
        t.allocator,
        "/lib",
        "add the advisory",
        "alice via laptop <alice@example.com>",
        &.{"advisory/one.html"},
    );
    defer t.allocator.free(argv);
    const want = [_][]const u8{
        "git",      "-C",                                   "/lib", "commit",
        "--author", "alice via laptop <alice@example.com>", "-m",   "add the advisory",
        "--",       "advisory/one.html",
    };
    try t.expectEqual(want.len, argv.len);
    for (want, argv) |w, got| try t.expectEqualStrings(w, got);
}

test "commitArgv without an author commits as the repository identity" {
    const argv = try commitArgv(t.allocator, "/lib", "why", null, &.{"a.html"});
    defer t.allocator.free(argv);
    const want = [_][]const u8{ "git", "-C", "/lib", "commit", "-m", "why", "--", "a.html" };
    try t.expectEqual(want.len, argv.len);
    for (want, argv) |w, got| try t.expectEqualStrings(w, got);
}

test "firstNonEmptyLine finds the message in noisy subprocess output" {
    try t.expectEqualStrings("fatal: not a git repository", firstNonEmptyLine("\n\nfatal: not a git repository\nhint: more\n"));
    try t.expectEqualStrings("", firstNonEmptyLine("\n \r\n"));
    try t.expectEqualStrings("one line", firstNonEmptyLine("one line"));
}

test "commitPaths in a real repository commits with the author override" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);

    // Skip on machines without git; the degrade-gracefully contract is
    // exercised by the not-a-repository test below either way.
    const init_run = std.process.run(t.allocator, t.io, .{
        .argv = &.{ "git", "-C", root, "init", "-q" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.SkipZigTest;
    defer t.allocator.free(init_run.stdout);
    defer t.allocator.free(init_run.stderr);
    switch (init_run.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
    inline for (.{ .{ "user.name", "Library Owner" }, .{ "user.email", "owner@example.com" } }) |kv| {
        const config_run = try std.process.run(t.allocator, t.io, .{
            .argv = &.{ "git", "-C", root, "config", kv[0], kv[1] },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        t.allocator.free(config_run.stdout);
        t.allocator.free(config_run.stderr);
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.html", .data = "<html></html>" });

    // commitPaths allocates with the arena contract of its real callers
    // (per-connection or per-command arenas); a bare t.allocator would
    // report its unfreed argv and subprocess buffers as leaks.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const outcome = commitPaths(
        arena_state.allocator(),
        t.io,
        root,
        &.{"one.html"},
        "add the page",
        "alice via laptop <alice@example.com>",
    );
    try t.expect(outcome.committed);
    try t.expect(isCommitSha(outcome.sha));
    try t.expectEqualStrings("", outcome.note);

    const log_run = try std.process.run(t.allocator, t.io, .{
        .argv = &.{ "git", "-C", root, "log", "-1", "--format=%an|%ae|%cn" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer t.allocator.free(log_run.stdout);
    defer t.allocator.free(log_run.stderr);
    try t.expectEqualStrings(
        "alice via laptop|alice@example.com|Library Owner",
        std.mem.trimEnd(u8, log_run.stdout, "\n"),
    );
}

test "commitPaths outside a repository reports and does not error" {
    // NOTE: not a tmpDir on purpose. `t.tmpDir` lives under `.zig-cache`,
    // which sits inside this project's own git repository, so `git -C`
    // there would happily stage into the wrong repo. The filesystem root
    // is the one directory guaranteed to be outside any repository.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const outcome = commitPaths(arena_state.allocator(), t.io, "/", &.{"one.html"}, "why", null);
    try t.expect(!outcome.committed);
    try t.expectEqualStrings("-", outcome.sha);
    try t.expect(outcome.note.len > 0);
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

const std = @import("std");

/// Headless-Chromium-compatible binary names to try, in order. `render`
/// tries each in turn, falling through to the next on `error.FileNotFound`
/// (binary not on `PATH`); the first one that spawns wins.
pub const candidates = [_][]const u8{ "chromium", "google-chrome-stable", "chromium-browser" };

/// Which candidate spawned but exited unsuccessfully, and how. Populated by
/// `render` immediately before it returns `error.ChromiumFailed`, so the
/// caller can report specifics; the brief's reference `render` returns a
/// bare `error.ChromiumFailed` with no way to recover this, but the task's
/// command-behavior spec requires printing "the failing binary name and
/// exit code", so this out-parameter was added on top of the brief's
/// sample code.
pub const Failure = struct {
    bin: []const u8,
    /// The process's exit code when `term == .exited`. For a signal/stop/
    /// unknown termination (no natural "exit code") this is a fixed `1`
    /// placeholder.
    code: u8,
};

/// Builds the argv for a single headless print-to-pdf invocation of `bin`.
/// Freeing the inner `allocPrint` strings is skipped; callers run on an
/// arena.
pub fn buildArgv(alloc: std.mem.Allocator, bin: []const u8, page_abs: []const u8, out_abs: []const u8) ![]const []const u8 {
    std.debug.assert(std.fs.path.isAbsolute(page_abs));
    std.debug.assert(std.fs.path.isAbsolute(out_abs));
    const pdf_arg = try std.fmt.allocPrint(alloc, "--print-to-pdf={s}", .{out_abs});
    const url = try std.fmt.allocPrint(alloc, "file://{s}", .{page_abs});
    const argv = try alloc.dupe([]const u8, &.{ bin, "--headless", "--disable-gpu", pdf_arg, url });
    std.debug.assert(argv.len == 5);
    return argv;
}

/// Renders `page_abs` to `out_abs` by shelling out to the first available
/// binary in `candidates`. Both paths are expected to already be absolute
/// (the caller's job: `file://` needs an absolute URL, and
/// `--print-to-pdf` resolves relative paths against Chromium's own cwd).
///
/// `error.FileNotFound` from spawning one candidate falls through to the
/// next; any other spawn error propagates immediately. Returns
/// `error.NoChromium` when no candidate binary is present at all, or
/// `error.ChromiumFailed` (with `failure.*` populated) when a candidate
/// spawned but exited nonzero or otherwise didn't terminate normally.
///
/// NOTE: reconciled against the installed 0.17.0-dev std, which replaced
/// `std.process.Child.init(...).spawnAndWait()` with the capability-based
/// `std.process.spawn(io, .{ .argv = ... }) -> Child` / `child.wait(io) ->
/// Term`; `Term`'s variants are lowercase (`.exited`, `.signal`, `.stopped`,
/// `.unknown`) rather than the brief's `.Exited`.
pub fn render(alloc: std.mem.Allocator, io: std.Io, page_abs: []const u8, out_abs: []const u8, failure: *?Failure) !void {
    for (candidates) |bin| {
        const argv = try buildArgv(alloc, bin, page_abs, out_abs);
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| {
                if (code == 0) return;
                failure.* = .{ .bin = bin, .code = code };
                return error.ChromiumFailed;
            },
            else => {
                failure.* = .{ .bin = bin, .code = 1 };
                return error.ChromiumFailed;
            },
        }
    }
    return error.NoChromium;
}

/// Upper bound on a `git show` read for one page revision; matches the
/// page-read cap used across the CLI commands.
pub const rev_bytes_max = 4 * 1024 * 1024;

/// Materializes `rev:page_rel` from the repository at `root` into a
/// temporary dot-file beside the page (`.<stem>-<rev>.html`), so relative
/// assets resolve against the working tree, a documented approximation.
/// Returns the temp's absolute path; the caller deletes it after
/// rendering. `rev` is any revspec git accepts: for the CLI that is the
/// operator's own argv, while network callers must gate it first
/// (`history.isCommitSha`), because the spec lands in an argv here.
pub fn materializeRev(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    page_rel: []const u8,
    rev: []const u8,
) ![]u8 {
    std.debug.assert(std.fs.path.isAbsolute(root));
    std.debug.assert(!std.fs.path.isAbsolute(page_rel));
    std.debug.assert(std.mem.endsWith(u8, page_rel, ".html"));
    std.debug.assert(rev.len > 0);

    const spec = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ rev, page_rel });
    const run = std.process.run(alloc, io, .{
        .argv = &.{ "git", "-C", root, "show", spec },
        .stdout_limit = .limited(rev_bytes_max),
        .stderr_limit = .limited(4096),
    }) catch return error.GitUnavailable;
    switch (run.term) {
        .exited => |code| if (code != 0) return error.GitShowFailed,
        else => return error.GitShowFailed,
    }

    const page_abs = try std.fs.path.join(alloc, &.{ root, page_rel });
    const page_dir = std.fs.path.dirname(page_abs) orelse root;
    const base = std.fs.path.basename(page_rel);
    const temp_abs = try std.fmt.allocPrint(alloc, "{s}/.{s}-{s}.html", .{
        page_dir,
        base[0 .. base.len - ".html".len],
        rev,
    });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp_abs, .data = run.stdout });
    return temp_abs;
}

test "materializeRev writes the committed content to a dot-file beside the page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    inline for (.{
        .{ "git", "-C", root, "init", "-q" },
        .{ "git", "-C", root, "config", "user.name", "Owner" },
        .{ "git", "-C", root, "config", "user.email", "owner@example.com" },
    }) |argv| {
        const run = std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &argv,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch return error.SkipZigTest;
        defer std.testing.allocator.free(run.stdout);
        defer std.testing.allocator.free(run.stderr);
        switch (run.term) {
            .exited => |code| if (code != 0) return error.SkipZigTest,
            else => return error.SkipZigTest,
        }
    }
    try tmp.dir.createDirPath(std.testing.io, "advisory");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "advisory/one.html", .data = "committed content" });
    inline for (.{
        .{ "git", "-C", root, "add", "advisory/one.html" },
        .{ "git", "-C", root, "commit", "-q", "-m", "add" },
    }) |argv| {
        const run = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &argv,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        std.testing.allocator.free(run.stdout);
        std.testing.allocator.free(run.stderr);
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "advisory/one.html", .data = "working tree content" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const temp_abs = try materializeRev(arena.allocator(), std.testing.io, root, "advisory/one.html", "HEAD");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, temp_abs) catch {};
    try std.testing.expect(std.mem.endsWith(u8, temp_abs, "/advisory/.one-HEAD.html"));
    const materialized = try tmp.dir.readFileAlloc(std.testing.io, "advisory/.one-HEAD.html", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(materialized);
    try std.testing.expectEqualStrings("committed content", materialized);
}

test "materializeRev on a bad revision is GitShowFailed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const init_run = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "git", "-C", root, "init", "-q" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.SkipZigTest;
    std.testing.allocator.free(init_run.stdout);
    std.testing.allocator.free(init_run.stderr);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.GitShowFailed,
        materializeRev(arena.allocator(), std.testing.io, root, "ghost.html", "HEAD"),
    );
}

test "argv shape" {
    // The brief's sample test frees only the outer slice, which leaks the
    // two inner allocPrint'd strings (pdf_arg, url) under the leak-checking
    // testing allocator, since buildArgv uses the same allocator for both.
    // Per the brief's own note, wrap the call in an arena instead so the
    // whole thing is freed in one shot; assertion shape unchanged.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), "chromium", "/lib/p.html", "/lib/p.pdf");
    try std.testing.expectEqualStrings("--print-to-pdf=/lib/p.pdf", argv[3]);
    try std.testing.expectEqualStrings("file:///lib/p.html", argv[4]);
}

test "candidate order preserved" {
    try std.testing.expectEqualStrings("chromium", candidates[0]);
    try std.testing.expectEqualStrings("google-chrome-stable", candidates[1]);
    try std.testing.expectEqualStrings("chromium-browser", candidates[2]);
}

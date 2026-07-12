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

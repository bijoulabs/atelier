const std = @import("std");
const library = @import("library.zig");
const template = @import("template.zig");
const index = @import("index.zig");
const pdf = @import("pdf.zig");
const serve = @import("serve.zig");
const check = @import("check.zig");
const share = @import("share.zig");

pub const version = "0.1.0";

// NOTE: this Zig dev build (0.17.0-dev) replaced the classic
// `std.fs.File.stdout()` / `std.process.argsAlloc` entry points with an
// explicit `std.Io` capability and a `std.process.Init` first parameter to
// `main`. `usage()` takes `io: std.Io` so it can write to stdout/stderr, and
// the version banner is built at comptime (via `++`) instead of
// `std.fmt.allocPrint`, since no allocator is needed either way.
const usage_text = "atelier " ++ version ++ "\n" ++
    "\n" ++
    "  atelier new <template> <dest> [--set KEY=VALUE ...] [--library <path>]\n" ++
    "  atelier index [--library <path>]\n" ++
    "  atelier pdf <page> [-o out.pdf] [--rev <sha>] [--library <path>]\n" ++
    "  atelier check [page] [--library <path>]\n" ++
    "  atelier share <page> [--for <recipient>] [-o out.pdf] [--library <path>]\n" ++
    "  atelier serve [path] [--port N] [--no-reload] [--library <path>]\n";

fn usage(io: std.Io, code: u8) noreturn {
    const w = if (code == 0) std.Io.File.stdout() else std.Io.File.stderr();
    w.writeStreamingAll(io, usage_text) catch {}; // a failed usage write must not block the exit
    std.process.exit(code);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) usage(io, 1);
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "new")) {
        try cmdNew(arena, io, init.environ_map, args);
    } else if (std.mem.eql(u8, cmd, "index")) {
        try cmdIndex(arena, io, init.environ_map, args);
    } else if (std.mem.eql(u8, cmd, "pdf")) {
        try cmdPdf(arena, io, init.environ_map, args);
    } else if (std.mem.eql(u8, cmd, "check")) {
        try cmdCheck(arena, io, init.environ_map, args);
    } else if (std.mem.eql(u8, cmd, "share")) {
        try cmdShare(arena, io, init.environ_map, args);
    } else if (std.mem.eql(u8, cmd, "serve")) {
        try cmdServe(arena, io, init.environ_map, args);
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        usage(io, 0);
    } else {
        usage(io, 1);
    }
}

/// Implements `atelier new <template> <dest> [--set KEY=VALUE ...] [--library <path>]`.
///
/// `<template>` is resolved relative to `<library>/templates/` (`.html` is
/// appended if missing); `<dest>` is resolved relative to the library root
/// (same `.html` handling). Refuses to overwrite an existing `<dest>`.
/// Prints `wrote <dest>`, then, if any placeholders were left unfilled,
/// `unfilled: A B ...`; exits 0 either way.
fn cmdNew(
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) !void {
    if (args.len < 4) usage(io, 1);
    const lib = try resolveFromArgs(alloc, io, environ, args, null);

    var kv = std.StringHashMap([]const u8).init(alloc);
    // Brand tokens from the resolved theme, seeded before --set so user
    // pairs win; masters referencing {{BRAND_*}} scaffold with the current
    // brand and the palette keeps one source.
    try kv.put("BRAND_PAPER", lib.theme.paper);
    try kv.put("BRAND_INK", lib.theme.ink);
    try kv.put("BRAND_MUTED", lib.theme.muted);
    try kv.put("BRAND_ACCENT", lib.theme.accent);
    try kv.put("BRAND_RULE", lib.theme.rule);
    try kv.put("BRAND_DISPLAY_FONT", lib.theme.display_font);
    try kv.put("BRAND_MONO_FONT", lib.theme.mono_font);
    try kv.put("BRAND_FONT_LINK", lib.theme.font_link);
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--set") and i + 1 < args.len) {
            const pair = args[i + 1];
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
                std.debug.print("bad --set (want KEY=VALUE): {s}\n", .{pair});
                std.process.exit(1);
            };
            try kv.put(pair[0..eq], pair[eq + 1 ..]);
            i += 1;
        }
    }

    const tname = if (std.mem.endsWith(u8, args[2], ".html")) args[2] else try std.fmt.allocPrint(alloc, "{s}.html", .{args[2]});
    const tpath = try std.fs.path.join(alloc, &.{ lib.root, "templates", tname });
    const src = std.Io.Dir.cwd().readFileAlloc(io, tpath, alloc, .limited(4 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("no template at {s}\n", .{tpath});
            std.process.exit(1);
        },
        else => return e,
    };

    const dname = if (std.mem.endsWith(u8, args[3], ".html")) args[3] else try std.fmt.allocPrint(alloc, "{s}.html", .{args[3]});
    const dpath = try std.fs.path.join(alloc, &.{ lib.root, dname });
    if (std.Io.Dir.cwd().access(io, dpath, .{})) |_| {
        std.debug.print("refusing to overwrite {s}\n", .{dpath});
        std.process.exit(1);
    } else |_| {} // any access failure means no existing file to protect; the write below surfaces real errors

    const r = try template.fill(alloc, src, &kv);
    if (std.fs.path.dirname(dpath)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dpath, .data = r.out });
    std.debug.print("wrote {s}\n", .{dpath});
    if (r.unfilled.len > 0) {
        std.debug.print("unfilled:", .{});
        for (r.unfilled) |u| std.debug.print(" {s}", .{u});
        std.debug.print("\n", .{});
    }
}

/// Implements `atelier index [--library <path>]`.
///
/// Discovers every `*.html` page under the resolved library root (see
/// `index.zig`), writes `<root>/index.html`, and prints the mjs-shaped
/// summary: `index.html rebuilt with N document(s):` followed by one
/// `  <href>  (<label>)` line per page.
fn cmdIndex(
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) !void {
    const lib = try resolveFromArgs(alloc, io, environ, args, null);
    const items = try index.collectItems(alloc, io, lib);
    const page = try index.render(alloc, lib, items);

    const dest = try std.fs.path.join(alloc, &.{ lib.root, "index.html" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = page });

    std.debug.print("index.html rebuilt with {d} document(s):\n", .{items.len});
    for (items) |it| std.debug.print("  {s}  ({s})\n", .{ it.href, it.label });
}

/// Implements `atelier pdf <page> [-o out.pdf] [--library <path>]`.
///
/// `<page>` resolves relative to the library root (`.html` appended when
/// missing); an absolute `<page>` is used as-is, unmodified. The default
/// output path is `<page>` with a trailing `.html` replaced by `.pdf` (or
/// `.pdf` appended outright if `<page>` has no `.html` suffix); `-o`
/// overrides it and, if given as a relative path, is resolved against the
/// current working directory. Both the page and output paths are made
/// absolute before being handed to Chromium: `file://` needs an absolute
/// URL, and `--print-to-pdf` resolves a relative path against Chromium's
/// own cwd, not ours.
fn cmdPdf(
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) !void {
    if (args.len < 3) usage(io, 1);
    const lib = try resolveFromArgs(alloc, io, environ, args, null);

    var out_flag: ?[]const u8 = null;
    var rev_flag: ?[]const u8 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            out_flag = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--rev") and i + 1 < args.len) {
            rev_flag = args[i + 1];
            i += 1;
        }
    }

    var page_abs = if (std.fs.path.isAbsolute(args[2]))
        args[2]
    else blk: {
        const page_name = if (std.mem.endsWith(u8, args[2], ".html")) args[2] else try std.fmt.allocPrint(alloc, "{s}.html", .{args[2]});
        break :blk try std.fs.path.join(alloc, &.{ lib.root, page_name });
    };
    // The default output name derives from the page as named, never from
    // a --rev temp copy.
    const named_page_abs = page_abs;

    // --rev renders the page as it existed at a library revision: git
    // show into a temporary dot-file beside the page (relative assets
    // resolve against the working tree, a documented approximation).
    var rev_tmp: ?[]const u8 = null;
    defer if (rev_tmp) |tmp| std.Io.Dir.cwd().deleteFile(io, tmp) catch {}; // best effort; dot-files never index
    if (rev_flag) |rev| {
        if (std.fs.path.isAbsolute(args[2])) {
            std.debug.print("--rev needs a library-relative page\n", .{});
            std.process.exit(1);
        }
        const page_rel = if (std.mem.endsWith(u8, args[2], ".html")) args[2] else try std.fmt.allocPrint(alloc, "{s}.html", .{args[2]});
        const spec = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ rev, page_rel });
        const run = std.process.run(alloc, io, .{
            .argv = &.{ "git", "-C", lib.root, "show", spec },
        }) catch {
            std.debug.print("git is unavailable; --rev needs it\n", .{});
            std.process.exit(1);
        };
        const ok = switch (run.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) {
            std.debug.print("git show {s} failed; check the revision and page\n", .{spec});
            std.process.exit(1);
        }
        const page_dir = std.fs.path.dirname(page_abs) orelse lib.root;
        const base = std.fs.path.basename(page_rel);
        const tmp = try std.fmt.allocPrint(alloc, "{s}/.{s}-{s}.html", .{ page_dir, base[0 .. base.len - ".html".len], rev });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = run.stdout });
        rev_tmp = tmp;
        page_abs = tmp;
    }

    const out_default = if (std.mem.endsWith(u8, named_page_abs, ".html"))
        try std.fmt.allocPrint(alloc, "{s}.pdf", .{named_page_abs[0 .. named_page_abs.len - ".html".len]})
    else
        try std.fmt.allocPrint(alloc, "{s}.pdf", .{named_page_abs});

    const out_abs = if (out_flag) |o| blk: {
        if (std.fs.path.isAbsolute(o)) break :blk o;
        const cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(cwd);
        break :blk try std.fs.path.join(alloc, &.{ cwd, o });
    } else out_default;

    // Pair assertions with buildArgv: absoluteness is produced here and
    // asserted again where the argv is assembled.
    std.debug.assert(std.fs.path.isAbsolute(page_abs));
    std.debug.assert(std.fs.path.isAbsolute(out_abs));

    var failure: ?pdf.Failure = null;
    pdf.render(alloc, io, page_abs, out_abs, &failure) catch |e| switch (e) {
        error.NoChromium => {
            std.debug.print("install chromium (or google-chrome-stable) for PDF rendering\n", .{});
            std.process.exit(1);
        },
        error.ChromiumFailed => {
            const f = failure.?;
            std.debug.print("{s} failed with exit code {d}\n", .{ f.bin, f.code });
            std.process.exit(1);
        },
        else => return e,
    };
    std.debug.print("wrote {s}\n", .{out_abs});
}

/// Implements `atelier check [page] [--library <path>]`.
///
/// With a page, checks just that page (`.html` appended when the last
/// segment has no extension); without, checks every page the indexer
/// would see. Errors print as `<rel>: error: ...` and fail the run with
/// exit 1; warnings print and do not. Ends with a one-line summary.
fn cmdCheck(
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) !void {
    var positional: ?[]const u8 = null;
    var i: usize = 2;
    if (i < args.len and !std.mem.startsWith(u8, args[i], "--")) {
        positional = args[i];
        i += 1;
    }
    const lib = try resolveFromArgs(alloc, io, environ, args, null);

    var rels: std.ArrayList([]const u8) = .empty;
    if (positional) |p| {
        const last = std.fs.path.basename(p);
        const rel = if (std.mem.indexOfScalar(u8, last, '.') != null)
            try alloc.dupe(u8, p)
        else
            try std.fmt.allocPrint(alloc, "{s}.html", .{p});
        try rels.append(alloc, if (std.mem.startsWith(u8, rel, "/")) rel[1..] else rel);
    } else {
        const items = try index.collectItems(alloc, io, lib);
        for (items) |it| {
            if (!std.mem.eql(u8, it.kind, "page")) continue; // only pages are lintable
            try rels.append(alloc, try alloc.dupe(u8, it.path[1..]));
        }
    }

    var pages: usize = 0;
    var errs: usize = 0;
    var warns: usize = 0;
    for (rels.items) |rel| {
        const abs = try std.fs.path.join(alloc, &.{ lib.root, rel });
        const html = std.Io.Dir.cwd().readFileAlloc(io, abs, alloc, .limited(4 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => {
                std.debug.print("no page at {s}\n", .{abs});
                std.process.exit(1);
            },
            else => return e,
        };
        pages += 1;
        const findings = try check.checkPage(alloc, io, lib, rel, html);
        for (findings) |f| {
            switch (f.severity) {
                .err => {
                    errs += 1;
                    std.debug.print("{s}: error: {s}\n", .{ rel, f.message });
                },
                .warn => {
                    warns += 1;
                    std.debug.print("{s}: warning: {s}\n", .{ rel, f.message });
                },
            }
        }
    }
    std.debug.print("{d} page(s) checked, {d} error(s), {d} warning(s)\n", .{ pages, errs, warns });
    if (errs > 0) std.process.exit(1);
}

/// Implements `atelier share <page> [--for <recipient>] [-o out.pdf] [--library <path>]`.
///
/// Renders the page to PDF like `atelier pdf`, but the rendered copy is a
/// temporary dot-file beside the page (relative assets keep resolving)
/// carrying a visible provenance stamp; the temp is deleted afterwards
/// and the share is recorded in `<library>/shares.log`. The default
/// output is `<stem>[-<recipient>].pdf` in the current directory: the
/// artifact is leaving, the library is not its home.
fn cmdShare(
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) !void {
    if (args.len < 3) usage(io, 1);
    const lib = try resolveFromArgs(alloc, io, environ, args, null);

    var recipient: ?[]const u8 = null;
    var out_flag: ?[]const u8 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--for") and i + 1 < args.len) {
            recipient = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            out_flag = args[i + 1];
            i += 1;
        }
    }

    const page_rel = if (std.mem.endsWith(u8, args[2], ".html"))
        try alloc.dupe(u8, args[2])
    else
        try std.fmt.allocPrint(alloc, "{s}.html", .{args[2]});
    const page_abs = try std.fs.path.join(alloc, &.{ lib.root, page_rel });
    const html = std.Io.Dir.cwd().readFileAlloc(io, page_abs, alloc, .limited(4 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("no page at {s}\n", .{page_abs});
            std.process.exit(1);
        },
        else => return e,
    };

    const now_sec = std.Io.Clock.now(.real, io).toSeconds();
    const date = try share.isoDate(alloc, now_sec);
    const stamp = try share.stampSnippet(alloc, lib.name, recipient, date);
    const stamped = try serve.injectAtBodyEnd(alloc, html, stamp);

    const page_dir = std.fs.path.dirname(page_abs) orelse lib.root;
    const stem = blk: {
        const base = std.fs.path.basename(page_rel);
        break :blk base[0 .. base.len - ".html".len];
    };
    const tmp_abs = try std.fmt.allocPrint(alloc, "{s}/.{s}-share.html", .{ page_dir, stem });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_abs, .data = stamped });
    defer std.Io.Dir.cwd().deleteFile(io, tmp_abs) catch {}; // best effort; dot-files never index

    const out_abs = if (out_flag) |o| blk: {
        if (std.fs.path.isAbsolute(o)) break :blk try alloc.dupe(u8, o);
        const cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(cwd);
        break :blk try std.fs.path.join(alloc, &.{ cwd, o });
    } else blk: {
        const cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(cwd);
        const name = if (recipient) |r|
            try std.fmt.allocPrint(alloc, "{s}-{s}.pdf", .{ stem, r })
        else
            try std.fmt.allocPrint(alloc, "{s}.pdf", .{stem});
        break :blk try std.fs.path.join(alloc, &.{ cwd, name });
    };

    std.debug.assert(std.fs.path.isAbsolute(tmp_abs));
    std.debug.assert(std.fs.path.isAbsolute(out_abs));
    var failure: ?pdf.Failure = null;
    pdf.render(alloc, io, tmp_abs, out_abs, &failure) catch |e| switch (e) {
        error.NoChromium => {
            std.debug.print("install chromium (or google-chrome-stable) for PDF rendering\n", .{});
            std.process.exit(1);
        },
        error.ChromiumFailed => {
            const f = failure.?;
            std.debug.print("{s} failed with exit code {d}\n", .{ f.bin, f.code });
            std.process.exit(1);
        },
        else => return e,
    };

    // Library revision for reproducibility; "-" when git is unavailable.
    const rev = blk: {
        const run = std.process.run(alloc, io, .{
            .argv = &.{ "git", "-C", lib.root, "rev-parse", "--short", "HEAD" },
        }) catch break :blk try alloc.dupe(u8, "-");
        const trimmed = std.mem.trim(u8, run.stdout, " \t\r\n");
        break :blk if (trimmed.len > 0) trimmed else try alloc.dupe(u8, "-");
    };

    const line = try share.logLine(alloc, date, rev, page_rel, recipient, std.fs.path.basename(out_abs));
    const log_abs = try std.fs.path.join(alloc, &.{ lib.root, "shares.log" });
    const existing = std.Io.Dir.cwd().readFileAlloc(io, log_abs, alloc, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => try alloc.dupe(u8, ""),
        else => return e,
    };
    const combined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ existing, line });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log_abs, .data = combined });

    std.debug.print("wrote {s}\n", .{out_abs});
    std.debug.print("logged: {s}", .{line});
}

/// Implements `atelier serve [path] [--port N] [--no-reload] [--library <path>]`.
///
/// `[path]` is an optional positional (the first arg after `serve` that
/// doesn't start with `--`); like `resolveFromArgs`'s other callers, an
/// explicit `--library <path>` flag still wins over it. `--port N`
/// overrides the port `serve.run` binds to; absent that flag, the port
/// comes from the resolved library's `atelier.json` `port` field (default
/// 8789, see `library.Manifest`). `--no-reload` is parsed here and passed
/// through as `reload=false`; `serve.run` uses it to gate the scanner
/// thread, `/__reload`'s SSE route, and per-response snippet injection.
fn cmdServe(
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) !void {
    var positional: ?[]const u8 = null;
    var i: usize = 2;
    if (i < args.len and !std.mem.startsWith(u8, args[i], "--")) {
        positional = args[i];
        i += 1;
    }

    var port_flag: ?u16 = null;
    var reload = true;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port_flag = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                std.debug.print("bad --port (want 0-65535): {s}\n", .{args[i + 1]});
                std.process.exit(1);
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--no-reload")) {
            reload = false;
        }
    }

    const lib = try resolveFromArgs(alloc, io, environ, args, positional);
    const port = port_flag orelse lib.port;
    try serve.run(io, lib, port, reload);
}

/// Scans `args` for `--library <path>`; falls back to `positional` when
/// no flag is present. Resolves the library via `library.resolve` against
/// the current working directory and the default config path, printing a
/// loud, actionable message and exiting the process on `NoLibrary` /
/// `NotALibrary` rather than propagating those as generic errors.
fn resolveFromArgs(
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args: []const [:0]const u8,
    positional: ?[]const u8,
) !library.Library {
    var explicit: ?[]const u8 = positional;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--library") and i + 1 < args.len) explicit = args[i + 1];
    }
    const cwd = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd);
    const cfg = try defaultConfigPath(alloc, environ);
    defer alloc.free(cfg);
    return library.resolve(alloc, io, .{ .explicit = explicit, .start_dir = cwd, .config_path = cfg }) catch |e| switch (e) {
        error.NoLibrary => {
            std.debug.print(
                "no library found: pass a path or --library, run inside a library (atelier.json), or set library= in ~/.config/atelier/config\n",
                .{},
            );
            std.process.exit(1);
        },
        error.NotALibrary => {
            std.debug.print("path is not a library: no atelier.json at the given root\n", .{});
            std.process.exit(1);
        },
        else => return e,
    };
}

/// Returns `~/.config/atelier/config`, the fallback library pointer file.
///
/// NOTE: 0.17-dev has no `std.posix.getenv`; `HOME` is read from the
/// process's `Environ.Map` (built for us in `std.process.Init`) instead.
fn defaultConfigPath(alloc: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const home = environ.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, ".config", "atelier", "config" });
}

test {
    _ = @import("library.zig");
    _ = @import("template.zig");
    _ = @import("index.zig");
    _ = @import("pdf.zig");
    _ = @import("serve.zig");
    _ = @import("check.zig");
    _ = @import("share.zig");
}

test "defaultConfigPath joins HOME with .config/atelier/config" {
    const t = std.testing;
    var environ = std.process.Environ.Map.init(t.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/home/tester");

    const cfg = try defaultConfigPath(t.allocator, &environ);
    defer t.allocator.free(cfg);
    try t.expectEqualStrings("/home/tester/.config/atelier/config", cfg);
}

test "defaultConfigPath surfaces NoHome when HOME is unset" {
    const t = std.testing;
    var environ = std.process.Environ.Map.init(t.allocator);
    defer environ.deinit();

    try t.expectError(error.NoHome, defaultConfigPath(t.allocator, &environ));
}

// Runs resolveFromArgs end to end via the --library flag. This is the
// happy path only: the NoLibrary/NotALibrary branches call
// std.process.exit and can't be exercised from within a test process, but
// referencing resolveFromArgs here still forces Zig to semantically
// analyze its full body (Zig skips analysis of functions nothing calls).
test "resolveFromArgs picks up an explicit --library flag" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);

    var environ = std.process.Environ.Map.init(t.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/nonexistent-home");

    const args = [_][:0]const u8{ "atelier", "index", "--library", root };
    const lib = try resolveFromArgs(t.allocator, t.io, &environ, &args, null);
    defer lib.deinit(t.allocator);
    try t.expectEqualStrings(root, lib.root);
}

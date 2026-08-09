const std = @import("std");
const theme_mod = @import("theme.zig");

/// The name of the manifest file that marks a directory as a library root.
const manifest_file_name = "atelier.json";

/// Upper bound on how large an `atelier.json` manifest is allowed to be.
const manifest_bytes_max = 64 * 1024;

/// Upper bound on how large the `~/.config/atelier/config` file is allowed to be.
const config_bytes_max = 4 * 1024;

/// Index-page branding; the struct itself now lives in `theme.zig`
/// (named themes, presets, overlays), re-exported here so the rest of
/// the code keeps reading `library.Theme`.
pub const Theme = theme_mod.Theme;

/// Knobs for `atelier check`, set via the optional `check` object in
/// `atelier.json`. Defaults are opinionated; adopters opt out per rule.
pub const CheckConfig = struct {
    /// Treat an em dash in a page as an error.
    forbid_em_dash: bool = true,
};

/// A resolved atelier library: its root directory plus manifest fields.
pub const Library = struct {
    root: []const u8,
    name: []const u8,
    tag: []const u8,
    port: u16,
    theme: Theme = Theme.neutral,
    check: CheckConfig = .{},

    /// Frees the allocations owned by this `Library`. Only valid on values
    /// produced by `resolve`/`loadAt`, which own every field; hand-built
    /// values (as in tests) reference literals and must not be deinited.
    pub fn deinit(self: Library, alloc: std.mem.Allocator) void {
        alloc.free(self.root);
        alloc.free(self.name);
        alloc.free(self.tag);
        self.theme.deinit(alloc);
    }
};

/// Errors `resolve` can return, in addition to whatever the underlying
/// filesystem and JSON parsing calls surface.
pub const ResolveError = error{
    /// No explicit path, ancestor manifest, or config fallback was found.
    NoLibrary,
    /// A path was given (explicitly or via config) but has no manifest.
    NotALibrary,
} || anyerror;

/// On-disk shape of `atelier.json`. Missing fields fall back to library
/// defaults. `theme` stays a raw JSON value here because it accepts
/// three forms (object, name string, base-plus-overrides object);
/// `theme.resolveSpec` interprets it during `loadAt`.
const Manifest = struct {
    name: []const u8 = "Atelier",
    tag: []const u8 = "",
    port: u16 = 8789,
    theme: std.json.Value = .null,
    check: CheckConfig = .{},
};

/// Loads and parses `atelier.json` from `dir_abs` if present.
///
/// Returns `null` (not an error) when the manifest file does not exist,
/// so callers can distinguish "not a library" from a real I/O failure.
fn loadAt(alloc: std.mem.Allocator, io: std.Io, dir_abs: []const u8) !?Library {
    std.debug.assert(std.fs.path.isAbsolute(dir_abs));
    const manifest_path = try std.fs.path.join(alloc, &.{ dir_abs, manifest_file_name });
    defer alloc.free(manifest_path);

    const raw = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, alloc, .limited(manifest_bytes_max)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(Manifest, alloc, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Duped one at a time with errdefers: a failing theme resolution
    // (e.g. an unknown name) must not strand the earlier fields.
    const root = try alloc.dupe(u8, dir_abs);
    errdefer alloc.free(root);
    const name = try alloc.dupe(u8, parsed.value.name);
    errdefer alloc.free(name);
    const tag = try alloc.dupe(u8, parsed.value.tag);
    errdefer alloc.free(tag);
    return Library{
        .root = root,
        .name = name,
        .tag = tag,
        .port = parsed.value.port,
        .theme = try theme_mod.resolveSpec(alloc, io, dir_abs, parsed.value.theme),
        .check = parsed.value.check,
    };
}

/// Serializes every library mutation the serving process performs:
/// document writes, index regeneration, shares.log appends, theme saves
/// and applies, and git commits. One coarse process-wide mutex on
/// purpose: mutations are rare and human-paced, and correctness beats
/// letting parallel writers loose on one working tree and git repo. It
/// lives here rather than in serve.zig so serve and the MCP handlers can
/// both take it without an import cycle. In-process only: a CLI run on
/// the serve machine is not serialized against the server, same as today.
///
/// NOTE: this std has no std.Thread.Mutex; std.Io.Mutex (whose lock and
/// unlock take io) is the blocking mutex, the same reconciliation as
/// serve.zig's SSE client list.
pub var write_mu: std.Io.Mutex = .init;

/// Writes `data` to the absolute path `dest_abs` atomically: bytes land
/// in a same-directory dot-file first, then one rename replaces the
/// destination, so a concurrent reader sees the old content or the new,
/// never a torn write. Same-directory keeps the rename on one
/// filesystem; the dot prefix keeps a crash leftover out of the ledger
/// walk and the scanner's tree signature, both of which skip dot names.
pub fn writeFileAtomic(io: std.Io, alloc: std.mem.Allocator, dest_abs: []const u8, data: []const u8) !void {
    std.debug.assert(std.fs.path.isAbsolute(dest_abs));
    const dir = std.fs.path.dirname(dest_abs) orelse return error.BadPathName;
    const base = std.fs.path.basename(dest_abs);
    std.debug.assert(base.len > 0);
    std.debug.assert(base[0] != '.');
    const temp_abs = try std.fmt.allocPrint(alloc, "{s}/.{s}.tmp", .{ dir, base });
    defer alloc.free(temp_abs);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp_abs, .data = data });
    try std.Io.Dir.renameAbsolute(temp_abs, dest_abs, io);
}

/// Selects which library `resolve` should load; a struct because
/// `start_dir` and `config_path` are both paths and a positional call
/// could swap them silently.
pub const ResolveOptions = struct {
    /// Explicit library path (from `--library` or a positional); wins when set.
    explicit: ?[]const u8 = null,
    /// Absolute directory the ancestor walk starts from (usually the cwd).
    start_dir: []const u8,
    /// Absolute path of the config file holding the `library=` fallback.
    config_path: []const u8,
};

/// Resolves the library in effect, in order:
///
///   1. `options.explicit`, if given: the path must resolve and contain a
///      manifest, otherwise `error.NotALibrary`.
///   2. An ancestor walk from `options.start_dir` up to the filesystem
///      root, looking for the nearest `atelier.json`.
///   3. The `library=` line in the file at `options.config_path`, if present.
///
/// If none of those resolve, returns `error.NoLibrary`.
pub fn resolve(alloc: std.mem.Allocator, io: std.Io, options: ResolveOptions) ResolveError!Library {
    std.debug.assert(std.fs.path.isAbsolute(options.start_dir));
    std.debug.assert(std.fs.path.isAbsolute(options.config_path));

    if (options.explicit) |p| {
        const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, p, alloc);
        defer alloc.free(abs);
        return (try loadAt(alloc, io, abs)) orelse error.NotALibrary;
    }

    var cur: []const u8 = options.start_dir;
    while (true) {
        if (try loadAt(alloc, io, cur)) |lib| return lib;
        const parent = std.fs.path.dirname(cur) orelse break;
        if (std.mem.eql(u8, parent, cur)) break;
        cur = parent;
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(io, options.config_path, alloc, .limited(config_bytes_max)) catch |err| switch (err) {
        error.FileNotFound => return error.NoLibrary,
        else => return err,
    };
    defer alloc.free(raw);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "library=")) {
            const configured = trimmed["library=".len..];
            if (configured.len > 0) return (try loadAt(alloc, io, configured)) orelse error.NotALibrary;
        }
    }

    return error.NoLibrary;
}

const t = std.testing;

test "explicit path with manifest resolves" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data =
        \\{"name":"Acme, Inc","tag":"Advise","port":9000}
    });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = try resolve(t.allocator, t.io, .{ .explicit = root, .start_dir = "/", .config_path = "/nonexistent" });
    defer lib.deinit(t.allocator);
    try t.expectEqualStrings("Acme, Inc", lib.name);
    try t.expectEqual(@as(u16, 9000), lib.port);
}

test "manifest theme block overrides the neutral defaults" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data =
        \\{"name":"Acme","theme":{"accent":"#9a3b32","display_font":"'Fraunces',serif",
        \\ "font_link":"https://fonts.example/css"}}
    });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = try resolve(t.allocator, t.io, .{ .explicit = root, .start_dir = "/", .config_path = "/nonexistent" });
    defer lib.deinit(t.allocator);
    try t.expectEqualStrings("#9a3b32", lib.theme.accent);
    try t.expectEqualStrings("'Fraunces',serif", lib.theme.display_font);
    try t.expectEqualStrings("https://fonts.example/css", lib.theme.font_link);
    // Unspecified fields keep their neutral defaults.
    try t.expectEqualStrings(Theme.neutral.ink, lib.theme.ink);
    try t.expectEqualStrings(Theme.neutral.paper, lib.theme.paper);
}

test "manifest can name a theme and gets the preset" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data =
        \\{"name":"Acme","theme":"noir"}
    });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = try resolve(t.allocator, t.io, .{ .explicit = root, .start_dir = "/", .config_path = "/nonexistent" });
    defer lib.deinit(t.allocator);
    try t.expectEqualStrings("#d4a24e", lib.theme.accent);
    try t.expectEqualStrings("#16130f", lib.theme.paper);
}

test "manifest base theme with field overrides" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data =
        \\{"name":"Acme","theme":{"base":"ledger","accent":"#123456"}}
    });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = try resolve(t.allocator, t.io, .{ .explicit = root, .start_dir = "/", .config_path = "/nonexistent" });
    defer lib.deinit(t.allocator);
    try t.expectEqualStrings("#123456", lib.theme.accent);
    try t.expectEqualStrings("#f7f3e8", lib.theme.paper);
}

test "manifest naming an unknown theme fails loudly" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data =
        \\{"name":"Acme","theme":"no-such"}
    });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try t.expectError(error.UnknownTheme, resolve(t.allocator, t.io, .{ .explicit = root, .start_dir = "/", .config_path = "/nonexistent" }));
}

test "manifest check block overrides the opinionated defaults" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data =
        \\{"name":"Acme","check":{"forbid_em_dash":false}}
    });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = try resolve(t.allocator, t.io, .{ .explicit = root, .start_dir = "/", .config_path = "/nonexistent" });
    defer lib.deinit(t.allocator);
    try t.expect(!lib.check.forbid_em_dash);
}

test "manifest without a check block keeps forbid_em_dash on" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = try resolve(t.allocator, t.io, .{ .explicit = root, .start_dir = "/", .config_path = "/nonexistent" });
    defer lib.deinit(t.allocator);
    try t.expect(lib.check.forbid_em_dash);
}

test "manifest without a theme block gets the neutral theme" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const lib = try resolve(t.allocator, t.io, .{ .explicit = root, .start_dir = "/", .config_path = "/nonexistent" });
    defer lib.deinit(t.allocator);
    try t.expectEqualStrings(Theme.neutral.accent, lib.theme.accent);
    try t.expectEqualStrings("", lib.theme.font_link);
}

test "explicit path without manifest is NotALibrary" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try t.expectError(error.NotALibrary, resolve(t.allocator, t.io, .{ .explicit = root, .start_dir = "/", .config_path = "/nonexistent" }));
}

test "ancestor walk finds manifest from a subdirectory" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "atelier.json", .data = "{}" });
    try tmp.dir.createDirPath(t.io, "a/b");
    const sub = try tmp.dir.realPathFileAlloc(t.io, "a/b", t.allocator);
    defer t.allocator.free(sub);
    const lib = try resolve(t.allocator, t.io, .{ .start_dir = sub, .config_path = "/nonexistent" });
    defer lib.deinit(t.allocator);
    try t.expectEqual(@as(u16, 8789), lib.port);
    try t.expectEqualStrings("Atelier", lib.name);
}

test "config fallback" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "thelib");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "thelib/atelier.json", .data = "{}" });
    const libpath = try tmp.dir.realPathFileAlloc(t.io, "thelib", t.allocator);
    defer t.allocator.free(libpath);
    const cfg = try std.fmt.allocPrint(t.allocator, "library={s}\n", .{libpath});
    defer t.allocator.free(cfg);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config", .data = cfg });
    const cfgpath = try tmp.dir.realPathFileAlloc(t.io, "config", t.allocator);
    defer t.allocator.free(cfgpath);
    const lib = try resolve(t.allocator, t.io, .{ .start_dir = "/", .config_path = cfgpath });
    defer lib.deinit(t.allocator);
    try t.expectEqualStrings(libpath, lib.root);
}

test "nothing resolvable is NoLibrary" {
    try t.expectError(error.NoLibrary, resolve(t.allocator, t.io, .{ .start_dir = "/", .config_path = "/nonexistent" }));
}

test "write_mu round-trips a lock so every server writer can rely on it" {
    try write_mu.lock(t.io);
    write_mu.unlock(t.io);
}

test "writeFileAtomic lands content and leaves no temp file behind" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const dest = try std.fs.path.join(t.allocator, &.{ root, "index.html" });
    defer t.allocator.free(dest);

    try writeFileAtomic(t.io, t.allocator, dest, "first");
    try writeFileAtomic(t.io, t.allocator, dest, "second");

    const read_back = try tmp.dir.readFileAlloc(t.io, "index.html", t.allocator, .limited(64));
    defer t.allocator.free(read_back);
    try t.expectEqualStrings("second", read_back);
    try t.expectError(error.FileNotFound, tmp.dir.readFileAlloc(t.io, ".index.html.tmp", t.allocator, .limited(64)));
}

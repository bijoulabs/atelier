const std = @import("std");

/// The name of the manifest file that marks a directory as a library root.
const manifest_file_name = "atelier.json";

/// Upper bound on how large an `atelier.json` manifest is allowed to be.
const manifest_bytes_max = 64 * 1024;

/// Upper bound on how large the `~/.config/atelier/config` file is allowed to be.
const config_bytes_max = 4 * 1024;

/// Index-page branding, set via the optional `theme` object in
/// `atelier.json`. Every field defaults to the neutral look (`neutral`), so
/// a library themes itself entirely through config and the binary stays
/// free of any particular brand. Color fields are CSS color values, font
/// fields are CSS font-family stacks, and `font_link` is a stylesheet URL
/// emitted as a `<link>` when non-empty (empty means the page makes no
/// external requests).
pub const Theme = struct {
    paper: []const u8 = "#ffffff",
    ink: []const u8 = "#1c1c1c",
    muted: []const u8 = "#606060",
    accent: []const u8 = "#1c1c1c",
    rule: []const u8 = "#dddddd",
    display_font: []const u8 = "system-ui,sans-serif",
    mono_font: []const u8 = "ui-monospace,monospace",
    font_link: []const u8 = "",
    /// Extra hex colors `atelier check` accepts beyond the five theme
    /// colors: the brand's extended palette (shades, semantic colors).
    palette: []const []const u8 = &.{},

    /// The all-defaults theme; also what tests compare against.
    pub const neutral = Theme{};

    fn dupe(self: Theme, alloc: std.mem.Allocator) !Theme {
        const palette = try alloc.alloc([]const u8, self.palette.len);
        for (self.palette, 0..) |c, i| palette[i] = try alloc.dupe(u8, c);
        return .{
            .paper = try alloc.dupe(u8, self.paper),
            .ink = try alloc.dupe(u8, self.ink),
            .muted = try alloc.dupe(u8, self.muted),
            .accent = try alloc.dupe(u8, self.accent),
            .rule = try alloc.dupe(u8, self.rule),
            .display_font = try alloc.dupe(u8, self.display_font),
            .mono_font = try alloc.dupe(u8, self.mono_font),
            .font_link = try alloc.dupe(u8, self.font_link),
            .palette = palette,
        };
    }

    fn deinit(self: Theme, alloc: std.mem.Allocator) void {
        alloc.free(self.paper);
        alloc.free(self.ink);
        alloc.free(self.muted);
        alloc.free(self.accent);
        alloc.free(self.rule);
        alloc.free(self.display_font);
        alloc.free(self.mono_font);
        alloc.free(self.font_link);
        for (self.palette) |c| alloc.free(c);
        alloc.free(self.palette);
    }
};

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
/// defaults; a missing or partial `theme` falls back to `Theme.neutral`
/// field by field (see `Theme`'s own defaults).
const Manifest = struct {
    name: []const u8 = "Atelier",
    tag: []const u8 = "",
    port: u16 = 8789,
    theme: Theme = Theme.neutral,
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

    return Library{
        .root = try alloc.dupe(u8, dir_abs),
        .name = try alloc.dupe(u8, parsed.value.name),
        .tag = try alloc.dupe(u8, parsed.value.tag),
        .port = parsed.value.port,
        .theme = try parsed.value.theme.dupe(alloc),
        .check = parsed.value.check,
    };
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

//! Named themes. A theme is a JSON object of index-page branding fields;
//! it can live inline in `atelier.json` (today's form), as a file in the
//! library's `themes/` directory, or as one of the presets embedded in
//! the binary. Resolution: the library shadows the presets, so forking a
//! shipped theme is dropping a same-named file into `themes/`. The
//! manifest may also name a `base` theme and override individual fields.

const std = @import("std");
const json = @import("json.zig");

/// Index-page branding, set via the `theme` value in `atelier.json`.
/// Every field defaults to the neutral look (`neutral`), so a library
/// themes itself entirely through config and the binary stays free of
/// any particular brand. Color fields are CSS color values, font fields
/// are CSS font-family stacks, and `font_link` is a stylesheet URL
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

    pub fn dupe(self: Theme, alloc: std.mem.Allocator) !Theme {
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

    pub fn deinit(self: Theme, alloc: std.mem.Allocator) void {
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

/// Errors specific to theme resolution; everything else (I/O, JSON
/// syntax) propagates as-is.
pub const Error = error{
    /// A named theme resolved to neither `<library>/themes/<name>.json`
    /// nor a built-in preset (or the name itself is invalid).
    UnknownTheme,
    /// A theme file declared `base`; composition lives in the manifest
    /// only, so files stay self-contained and shareable.
    NestedBase,
    /// The manifest's `theme` value is neither a string, an object, nor
    /// absent.
    BadThemeSpec,
};

/// Upper bound on how large a theme file is allowed to be.
pub const theme_bytes_max = 64 * 1024;

/// Names of the presets embedded in the binary, alphabetical. Each has a
/// same-named JSON file under `assets/themes/`; the two arrays below are
/// index-parallel.
pub const preset_names = [_][]const u8{ "gallery", "ledger", "noir", "porcelain", "terminal" };

/// The preset names as one comma-separated string, for error messages
/// and usage text.
pub const preset_names_joined = blk: {
    var s: []const u8 = "";
    for (preset_names, 0..) |n, i| {
        s = s ++ (if (i > 0) ", " else "") ++ n;
    }
    break :blk s;
};

const preset_sources = [_][]const u8{
    @embedFile("assets/themes/gallery.json"),
    @embedFile("assets/themes/ledger.json"),
    @embedFile("assets/themes/noir.json"),
    @embedFile("assets/themes/porcelain.json"),
    @embedFile("assets/themes/terminal.json"),
};

/// The embedded JSON source of the preset named `name`, or null.
pub fn presetSource(name: []const u8) ?[]const u8 {
    for (preset_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return preset_sources[i];
    }
    return null;
}

/// Whether `s` is a valid theme name: 1 to 64 of `[a-z0-9-]`. This gates
/// both resolution and the editor's save path, so it is deliberately
/// strict; no dots or slashes means a name cannot escape `themes/`.
pub fn isThemeName(s: []const u8) bool {
    if (s.len < 1 or s.len > 64) return false;
    for (s) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// Whether every theme field is within the editor-save size caps: each
/// string field at most 512 bytes, at most 64 palette entries of at most
/// 64 bytes. Values inside the caps are still arbitrary CSS; the caps
/// only keep a hostile save request from writing megabytes.
pub fn fieldLimitsOk(theme: Theme) bool {
    const strings = [_][]const u8{
        theme.paper, theme.ink,          theme.muted,     theme.accent,
        theme.rule,  theme.display_font, theme.mono_font, theme.font_link,
    };
    for (strings) |s| if (s.len > 512) return false;
    if (theme.palette.len > 64) return false;
    for (theme.palette) |c| if (c.len > 64) return false;
    return true;
}

/// The all-optional mirror of `Theme` plus `base`: how a theme arrives
/// from JSON before overlay. A null field means "not specified, inherit";
/// `Theme`'s own defaults cannot express that distinction.
const Overlay = struct {
    base: ?[]const u8 = null,
    paper: ?[]const u8 = null,
    ink: ?[]const u8 = null,
    muted: ?[]const u8 = null,
    accent: ?[]const u8 = null,
    rule: ?[]const u8 = null,
    display_font: ?[]const u8 = null,
    mono_font: ?[]const u8 = null,
    font_link: ?[]const u8 = null,
    palette: ?[]const []const u8 = null,
};

/// Lays `o`'s specified fields over `base`. The result borrows from both
/// inputs; callers dupe it into owned memory before either dies.
fn applyOverlay(base: Theme, o: Overlay) Theme {
    return .{
        .paper = o.paper orelse base.paper,
        .ink = o.ink orelse base.ink,
        .muted = o.muted orelse base.muted,
        .accent = o.accent orelse base.accent,
        .rule = o.rule orelse base.rule,
        .display_font = o.display_font orelse base.display_font,
        .mono_font = o.mono_font orelse base.mono_font,
        .font_link = o.font_link orelse base.font_link,
        .palette = o.palette orelse base.palette,
    };
}

/// Parses a standalone theme file (library `themes/*.json` or an
/// embedded preset) into an owned `Theme`; unspecified fields fall back
/// to `neutral`. A `base` field in a file is `error.NestedBase`.
pub fn parseThemeFile(alloc: std.mem.Allocator, raw: []const u8) !Theme {
    const parsed = try std.json.parseFromSlice(Overlay, alloc, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.base != null) return error.NestedBase;
    return try applyOverlay(Theme.neutral, parsed.value).dupe(alloc);
}

/// Parses an already-parsed JSON object value into an owned `Theme`,
/// with the same contract as `parseThemeFile` (neutral fallback,
/// `error.NestedBase` on a `base` field). The editor's save endpoint
/// reads its request body through this.
pub fn parseThemeValue(alloc: std.mem.Allocator, value: std.json.Value) !Theme {
    const parsed = try std.json.parseFromValue(Overlay, alloc, value, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.base != null) return error.NestedBase;
    return try applyOverlay(Theme.neutral, parsed.value).dupe(alloc);
}

/// Resolves a theme name to an owned `Theme`: the library's
/// `themes/<name>.json` first, then the embedded presets;
/// `error.UnknownTheme` when neither exists.
pub fn resolveNamed(alloc: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8) !Theme {
    // The name check is also the path confinement: no dots or slashes
    // can reach the join below.
    if (!isThemeName(name)) return error.UnknownTheme;
    const path = try std.fmt.allocPrint(alloc, "{s}/themes/{s}.json", .{ root, name });
    defer alloc.free(path);
    const from_library: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(theme_bytes_max)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (from_library) |raw| {
        defer alloc.free(raw);
        return try parseThemeFile(alloc, raw);
    }
    const preset = presetSource(name) orelse return error.UnknownTheme;
    return try parseThemeFile(alloc, preset);
}

/// Resolves the manifest's raw `theme` value to an owned `Theme`:
/// absent is neutral, a string is a named theme, an object is an
/// overlay over its optional `base` (or neutral), anything else is
/// `error.BadThemeSpec`.
pub fn resolveSpec(alloc: std.mem.Allocator, io: std.Io, root: []const u8, value: std.json.Value) !Theme {
    switch (value) {
        .null => return try Theme.neutral.dupe(alloc),
        .string => |name| return try resolveNamed(alloc, io, root, name),
        .object => {
            const parsed = try std.json.parseFromValue(Overlay, alloc, value, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (parsed.value.base) |base_name| {
                const base = try resolveNamed(alloc, io, root, base_name);
                defer base.deinit(alloc);
                return try applyOverlay(base, parsed.value).dupe(alloc);
            }
            return try applyOverlay(Theme.neutral, parsed.value).dupe(alloc);
        },
        else => return error.BadThemeSpec,
    }
}

/// Renders an owned `Theme` as pretty-printed standalone theme-file
/// JSON, the exact shape `parseThemeFile` reads back. Caller owns the
/// buffer.
pub fn renderThemeJson(alloc: std.mem.Allocator, theme: Theme) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const fields = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "paper", .value = theme.paper },
        .{ .name = "ink", .value = theme.ink },
        .{ .name = "muted", .value = theme.muted },
        .{ .name = "accent", .value = theme.accent },
        .{ .name = "rule", .value = theme.rule },
        .{ .name = "display_font", .value = theme.display_font },
        .{ .name = "mono_font", .value = theme.mono_font },
        .{ .name = "font_link", .value = theme.font_link },
    };
    try out.appendSlice(alloc, "{\n");
    for (fields, 0..) |f, i| {
        try out.appendSlice(alloc, "  ");
        try json.appendString(&out, alloc, f.name);
        try out.appendSlice(alloc, ": ");
        try json.appendString(&out, alloc, f.value);
        const last = i == fields.len - 1 and theme.palette.len == 0;
        try out.appendSlice(alloc, if (last) "\n" else ",\n");
    }
    if (theme.palette.len > 0) {
        try out.appendSlice(alloc, "  \"palette\": [");
        for (theme.palette, 0..) |c, i| {
            if (i > 0) try out.appendSlice(alloc, ", ");
            try json.appendString(&out, alloc, c);
        }
        try out.appendSlice(alloc, "]\n");
    }
    try out.appendSlice(alloc, "}\n");
    return try out.toOwnedSlice(alloc);
}

const t = std.testing;

test "isThemeName accepts kebab names and nothing else" {
    try t.expect(isThemeName("porcelain"));
    try t.expect(isThemeName("my-theme-2"));
    // Negative space: empty, uppercase, dots, slashes, length 65.
    try t.expect(!isThemeName(""));
    try t.expect(!isThemeName("Porcelain"));
    try t.expect(!isThemeName("a.b"));
    try t.expect(!isThemeName("a/b"));
    try t.expect(!isThemeName(".."));
    // 65 characters, one past the cap. NOTE: written out because this
    // std's tokenizer rejects the `"a" ** 65` repeat spelling here.
    try t.expect(!isThemeName("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "parseThemeFile fills unspecified fields from neutral" {
    const theme = try parseThemeFile(t.allocator, "{\"accent\":\"#123456\"}");
    defer theme.deinit(t.allocator);
    try t.expectEqualStrings("#123456", theme.accent);
    try t.expectEqualStrings(Theme.neutral.paper, theme.paper);
    try t.expectEqualStrings(Theme.neutral.mono_font, theme.mono_font);
}

test "parseThemeFile rejects a base field" {
    try t.expectError(error.NestedBase, parseThemeFile(t.allocator, "{\"base\":\"noir\"}"));
}

test "every embedded preset parses and recolors the neutral look" {
    for (preset_names) |name| {
        const src = presetSource(name).?;
        const theme = try parseThemeFile(t.allocator, src);
        defer theme.deinit(t.allocator);
        try t.expect(!std.mem.eql(u8, theme.paper, Theme.neutral.paper) or
            !std.mem.eql(u8, theme.ink, Theme.neutral.ink));
        try t.expect(!std.mem.eql(u8, theme.accent, Theme.neutral.accent));
        // Presets must never make external requests.
        try t.expectEqualStrings("", theme.font_link);
    }
}

test "resolveNamed prefers the library file over the preset" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "themes");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "themes/porcelain.json", .data = "{\"accent\":\"#123456\"}" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const shadowed = try resolveNamed(t.allocator, t.io, root, "porcelain");
    defer shadowed.deinit(t.allocator);
    try t.expectEqualStrings("#123456", shadowed.accent);
    // With no library file, the embedded preset answers.
    const preset = try resolveNamed(t.allocator, t.io, root, "noir");
    defer preset.deinit(t.allocator);
    try t.expectEqualStrings("#d4a24e", preset.accent);
}

test "resolveNamed on an unknown or invalid name errors" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try t.expectError(error.UnknownTheme, resolveNamed(t.allocator, t.io, root, "no-such-theme"));
    try t.expectError(error.UnknownTheme, resolveNamed(t.allocator, t.io, root, "../escape"));
}

fn specValue(alloc: std.mem.Allocator, raw: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
}

test "resolveSpec null is neutral, string is named, bad type errors" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);

    const from_null = try resolveSpec(t.allocator, t.io, root, .null);
    defer from_null.deinit(t.allocator);
    try t.expectEqualStrings(Theme.neutral.accent, from_null.accent);

    const named = try specValue(t.allocator, "\"terminal\"");
    defer named.deinit();
    const from_name = try resolveSpec(t.allocator, t.io, root, named.value);
    defer from_name.deinit(t.allocator);
    try t.expectEqualStrings("#3fb950", from_name.accent);

    const bad = try specValue(t.allocator, "7");
    defer bad.deinit();
    try t.expectError(error.BadThemeSpec, resolveSpec(t.allocator, t.io, root, bad.value));
}

test "resolveSpec object with base overlays the named theme" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const spec = try specValue(t.allocator, "{\"base\":\"noir\",\"accent\":\"#123456\"}");
    defer spec.deinit();
    const theme = try resolveSpec(t.allocator, t.io, root, spec.value);
    defer theme.deinit(t.allocator);
    try t.expectEqualStrings("#123456", theme.accent);
    try t.expectEqualStrings("#16130f", theme.paper);
}

test "resolveSpec plain object keeps inline-theme behavior" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const spec = try specValue(t.allocator, "{\"accent\":\"#9a3b32\",\"palette\":[\"#111111\"]}");
    defer spec.deinit();
    const theme = try resolveSpec(t.allocator, t.io, root, spec.value);
    defer theme.deinit(t.allocator);
    try t.expectEqualStrings("#9a3b32", theme.accent);
    try t.expectEqualStrings(Theme.neutral.paper, theme.paper);
    try t.expectEqual(@as(usize, 1), theme.palette.len);
    try t.expectEqualStrings("#111111", theme.palette[0]);
}

test "fieldLimitsOk caps field and palette sizes" {
    try t.expect(fieldLimitsOk(Theme.neutral));
    var big: [513]u8 = undefined;
    @memset(&big, 'x');
    try t.expect(!fieldLimitsOk(.{ .accent = &big }));
    const entries: [65][]const u8 = @splat("#111111");
    try t.expect(!fieldLimitsOk(.{ .palette = &entries }));
}

test "parseThemeValue mirrors parseThemeFile including base rejection" {
    const ok = try specValue(t.allocator, "{\"accent\":\"#123456\"}");
    defer ok.deinit();
    const theme = try parseThemeValue(t.allocator, ok.value);
    defer theme.deinit(t.allocator);
    try t.expectEqualStrings("#123456", theme.accent);
    try t.expectEqualStrings(Theme.neutral.paper, theme.paper);
    const based = try specValue(t.allocator, "{\"base\":\"noir\"}");
    defer based.deinit();
    try t.expectError(error.NestedBase, parseThemeValue(t.allocator, based.value));
}

test "renderThemeJson round-trips through parseThemeFile" {
    const original = try resolveNamed(t.allocator, t.io, "/nonexistent", "ledger");
    defer original.deinit(t.allocator);
    const rendered = try renderThemeJson(t.allocator, original);
    defer t.allocator.free(rendered);
    const reparsed = try parseThemeFile(t.allocator, rendered);
    defer reparsed.deinit(t.allocator);
    try t.expectEqualStrings(original.paper, reparsed.paper);
    try t.expectEqualStrings(original.accent, reparsed.accent);
    try t.expectEqualStrings(original.display_font, reparsed.display_font);
}

//! Runtime theme palette for the interactive TUI.
//!
//! [FLOW_TUI_THEME] Ports the subset of upstream
//! `packages/coding-agent/src/modes/interactive/theme/theme.ts` that the
//! Zig TUI actually consumes at runtime: a small `Palette` of ANSI escape
//! strings derived from the active theme JSON's `colors` map. The TUI's
//! status bar, banner, palette/selector overlays, and dividers ask the
//! palette for each token instead of using the hardcoded `tui.sgr.*`
//! constants — that's how a `--theme dark` vs `--theme light` switch
//! actually changes what the user sees.
//!
//! The full upstream theme system covers ~49 tokens (foregrounds + 6
//! backgrounds) plus markdown/syntax variants. The Zig live TUI currently
//! paints only six of those tokens, so this module derives just those six
//! and leaves the rest to upstream parity work (a later wave can expand
//! the `Palette` struct as more tokens enter the render path).
//!
//! Loading precedence (mirrors `themes.zig` priority):
//!   1. `Options.theme_name` argument passed by the caller (cli_runtime)
//!   2. `PI_THEME=<name>` env var (set by the user or harness)
//!   3. `"dark"` (the built-in default; matches `themes.zig` builtin order)
//!
//! Custom (file-based) themes resolved through `themes.zig` are NOT yet
//! plumbed here; the palette currently consumes built-in JSON bytes only
//! (`themes.builtinThemeBytes`). If a theme name cannot be resolved or its
//! JSON fails to parse, every token falls back to the legacy `sgr.*`
//! escape string so the TUI keeps painting the previous colors unchanged.
//!
//! Hex → ANSI 256 conversion mirrors upstream `rgbTo256()` (weighted
//! Euclidean distance against the 6×6×6 cube + the 24-step grayscale ramp;
//! grayscale only wins when the source RGB has spread < 10 AND is closer).
//! Pure-stdlib so the palette is unit-testable without a TTY.
//!
//! Storage note: each token is stored inline (a fixed-size buffer plus a
//! `_len` cursor) and exposed via accessor methods that compute the slice
//! from `*const Palette`. We deliberately avoid `[]const u8` fields here
//! because slice pointers into a struct's own storage dangle when the
//! struct is copied / moved (Zig structs don't track self-references); the
//! accessor approach lets the App keep a `palette: tui_theme.Palette`
//! field with no allocator + safe copy semantics.

const std = @import("std");
const themes = @import("themes.zig");

// ============================================================================
// Static fallback escapes (legacy `tui.sgr` constants)
// ============================================================================

/// Legacy hardcoded escapes that the TUI used before theming. Returned by
/// `Palette` accessor methods whenever the theme can't be resolved /
/// parsed, so painting never crashes — the user just sees the pre-theme
/// colors.
pub const fallback = struct {
    pub const accent = "\x1b[38;5;208m"; // orange — provider/model
    pub const branch = "\x1b[38;5;111m"; // teal/blue — git branch
    pub const muted = "\x1b[38;5;240m"; // grey — timers / dividers
    pub const good = "\x1b[38;5;82m"; // green — good state
    pub const warn = "\x1b[38;5;214m"; // amber — update banner
    pub const code_bg = "\x1b[48;5;236m"; // dim background — inline `code`
};

/// Per-token escape buffer. Longest legal sequence is `\x1b[48;5;NNNm`
/// = 11 bytes; 12 bytes gives a one-byte safety margin.
const escape_buf_size: usize = 12;

/// Resolved palette. Stored inline in the App so an init() copy is safe;
/// accessor methods take `*const Self` and compute slices from the local
/// storage, so the returned `[]const u8` always points into the struct's
/// own buffers (not a stale stack frame).
pub const Palette = struct {
    is_fallback: bool = true,

    name_buf: [32]u8 = undefined,
    name_len: u8 = 0,

    accent_buf: [escape_buf_size]u8 = undefined,
    accent_len: u8 = 0,
    muted_buf: [escape_buf_size]u8 = undefined,
    muted_len: u8 = 0,
    branch_buf: [escape_buf_size]u8 = undefined,
    branch_len: u8 = 0,
    good_buf: [escape_buf_size]u8 = undefined,
    good_len: u8 = 0,
    warn_buf: [escape_buf_size]u8 = undefined,
    warn_len: u8 = 0,
    code_bg_buf: [escape_buf_size]u8 = undefined,
    code_bg_len: u8 = 0,

    /// The theme name resolved at init time. `"dark"` for the default
    /// fallback path; the real built-in name otherwise. Surfaced for
    /// diagnostics and for the App's `/theme` status messages.
    pub fn name(self: *const Palette) []const u8 {
        if (self.name_len == 0) return "dark";
        return self.name_buf[0..self.name_len];
    }

    pub fn accent(self: *const Palette) []const u8 {
        if (self.accent_len == 0) return fallback.accent;
        return self.accent_buf[0..self.accent_len];
    }

    pub fn muted(self: *const Palette) []const u8 {
        if (self.muted_len == 0) return fallback.muted;
        return self.muted_buf[0..self.muted_len];
    }

    pub fn branch(self: *const Palette) []const u8 {
        if (self.branch_len == 0) return fallback.branch;
        return self.branch_buf[0..self.branch_len];
    }

    pub fn good(self: *const Palette) []const u8 {
        if (self.good_len == 0) return fallback.good;
        return self.good_buf[0..self.good_len];
    }

    pub fn warn(self: *const Palette) []const u8 {
        if (self.warn_len == 0) return fallback.warn;
        return self.warn_buf[0..self.warn_len];
    }

    pub fn codeBg(self: *const Palette) []const u8 {
        if (self.code_bg_len == 0) return fallback.code_bg;
        return self.code_bg_buf[0..self.code_bg_len];
    }
};

// ============================================================================
// Public init: resolve a theme name + build escapes
// ============================================================================

pub const InitOptions = struct {
    /// Optional explicit theme name (e.g. from `--theme dark`). When null,
    /// `PI_THEME=<name>` env var wins; absent that, falls back to "dark".
    theme_name: ?[]const u8 = null,
    /// Environment lookup for `PI_THEME`. Pass null in tests to disable.
    env: ?*const std.process.Environ.Map = null,
};

/// Build a `Palette` for the configured theme. Never errors: a failure to
/// resolve / parse the theme silently leaves every token at its `fallback`
/// escape so the TUI keeps painting (the App can log the fallback via the
/// `is_fallback` flag).
pub fn init(allocator: std.mem.Allocator, options: InitOptions) Palette {
    var palette = Palette{};

    // Resolve which theme name to load.
    const requested = resolveThemeName(options);
    const name_len = @min(requested.len, palette.name_buf.len);
    @memcpy(palette.name_buf[0..name_len], requested[0..name_len]);
    palette.name_len = @intCast(name_len);

    const bytes = themes.builtinThemeBytes(requested) orelse return palette;

    // Parse the theme JSON; on parse failure, keep the fallback escapes.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return palette;
    defer parsed.deinit();
    if (parsed.value != .object) return palette;
    const colors = parsed.value.object.get("colors") orelse return palette;
    if (colors != .object) return palette;
    const vars: ?std.json.ObjectMap = blk: {
        if (parsed.value.object.get("vars")) |v| {
            if (v == .object) break :blk v.object;
        }
        break :blk null;
    };

    // Derive each token. A token that fails to resolve keeps its fallback
    // (the `_len == 0` accessor branch returns the fallback string).
    if (deriveFg(&palette.accent_buf, colors.object, vars, "accent")) |slice| {
        palette.accent_len = @intCast(slice.len);
    }
    if (deriveFg(&palette.muted_buf, colors.object, vars, "muted")) |slice| {
        palette.muted_len = @intCast(slice.len);
    }
    // `branch` is not a theme token; reuse `border` which carries the
    // teal/blue accent used for the upstream status-bar branch label.
    if (deriveFg(&palette.branch_buf, colors.object, vars, "border")) |slice| {
        palette.branch_len = @intCast(slice.len);
    }
    if (deriveFg(&palette.good_buf, colors.object, vars, "success")) |slice| {
        palette.good_len = @intCast(slice.len);
    }
    if (deriveFg(&palette.warn_buf, colors.object, vars, "warning")) |slice| {
        palette.warn_len = @intCast(slice.len);
    }
    // `code_bg` is a background; upstream has no dedicated token for
    // inline-code background, so sample `selectedBg` (the closest
    // dim-card-like background used by upstream's selected rows).
    if (deriveBg(&palette.code_bg_buf, colors.object, vars, "selectedBg")) |slice| {
        palette.code_bg_len = @intCast(slice.len);
    }

    palette.is_fallback = false;
    return palette;
}

/// Resolve the active theme name from the explicit option, env, then default.
fn resolveThemeName(options: InitOptions) []const u8 {
    if (options.theme_name) |n| if (n.len > 0) return n;
    if (options.env) |env| {
        if (env.get("PI_THEME")) |n| if (n.len > 0) return n;
    }
    return "dark";
}

// ============================================================================
// Color resolution (hex / var refs / numeric 256-color index)
// ============================================================================

/// Derive the foreground escape `\x1b[38;5;Nm` for `key` from `colors[key]`
/// (resolving var refs through `vars`). Writes into `buf` and returns the
/// written slice; returns null when the color value is empty or unresolvable.
fn deriveFg(buf: []u8, colors: std.json.ObjectMap, vars: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = colors.get(key) orelse return null;
    const index = resolveTo256(value, vars) orelse return null;
    return std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{index}) catch null;
}

/// Same as `deriveFg` but for backgrounds (`\x1b[48;5;Nm`).
fn deriveBg(buf: []u8, colors: std.json.ObjectMap, vars: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = colors.get(key) orelse return null;
    const index = resolveTo256(value, vars) orelse return null;
    return std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{index}) catch null;
}

/// Resolve a `ColorValue` (hex / var ref / 256-index integer) to a final
/// ANSI 256-color index. Mirrors upstream `resolveVarRefs` + `hexTo256`.
fn resolveTo256(value: std.json.Value, vars: ?std.json.ObjectMap) ?u8 {
    var seen_buf: [16][]const u8 = undefined;
    var seen_len: usize = 0;
    return resolveTo256Inner(value, vars, &seen_buf, &seen_len);
}

fn resolveTo256Inner(
    value: std.json.Value,
    vars: ?std.json.ObjectMap,
    seen: *[16][]const u8,
    seen_len: *usize,
) ?u8 {
    switch (value) {
        .integer => |int| {
            if (int < 0 or int > 255) return null;
            return @intCast(int);
        },
        .string => |text| {
            if (text.len == 0) return null;
            if (std.mem.startsWith(u8, text, "#")) return hexTo256(text);
            // Variable reference: look up `text` in vars and recurse.
            const vars_object = vars orelse return null;
            // Cycle detection (cheap O(n) since n is tiny — themes have <20 vars).
            var i: usize = 0;
            while (i < seen_len.*) : (i += 1) {
                if (std.mem.eql(u8, seen.*[i], text)) return null;
            }
            if (seen_len.* >= seen.len) return null;
            seen.*[seen_len.*] = text;
            seen_len.* += 1;
            const next = vars_object.get(text) orelse return null;
            return resolveTo256Inner(next, vars, seen, seen_len);
        },
        else => return null,
    }
}

// ============================================================================
// Hex → ANSI 256 (mirrors upstream rgbTo256)
// ============================================================================

const Rgb = struct { r: u8, g: u8, b: u8 };

// 6×6×6 cube channel values (indices 0-5).
const cube_values = [_]u16{ 0, 95, 135, 175, 215, 255 };

fn hexToRgb(hex: []const u8) ?Rgb {
    const cleaned = if (std.mem.startsWith(u8, hex, "#")) hex[1..] else hex;
    if (cleaned.len != 6) return null;
    const r = std.fmt.parseInt(u8, cleaned[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, cleaned[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, cleaned[4..6], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

fn findClosestCubeIndex(value: u8) usize {
    var best: usize = 0;
    var best_dist: i32 = std.math.maxInt(i32);
    for (cube_values, 0..) |v, i| {
        const d = @as(i32, @intCast(@abs(@as(i32, value) - @as(i32, @intCast(v)))));
        if (d < best_dist) {
            best_dist = d;
            best = i;
        }
    }
    return best;
}

fn findClosestGrayIndex(gray: u8) usize {
    // GRAY_VALUES[i] = 8 + i*10 for i in 0..24.
    var best: usize = 0;
    var best_dist: i32 = std.math.maxInt(i32);
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const v: i32 = 8 + @as(i32, @intCast(i)) * 10;
        const d = @as(i32, @intCast(@abs(@as(i32, gray) - v)));
        if (d < best_dist) {
            best_dist = d;
            best = i;
        }
    }
    return best;
}

/// Weighted Euclidean distance (human eye is more sensitive to green).
/// Returns a fixed-point integer (scaled by 1000) so we stay int-only.
fn colorDistance(r1: u8, g1: u8, b1: u8, r2: u8, g2: u8, b2: u8) i64 {
    const dr: i64 = @as(i64, r1) - @as(i64, r2);
    const dg: i64 = @as(i64, g1) - @as(i64, g2);
    const db: i64 = @as(i64, b1) - @as(i64, b2);
    return dr * dr * 299 + dg * dg * 587 + db * db * 114;
}

fn hexTo256(hex: []const u8) ?u8 {
    const rgb = hexToRgb(hex) orelse return null;
    return rgbTo256(rgb.r, rgb.g, rgb.b);
}

/// Mirrors upstream `rgbTo256`: pick the closer of the 6×6×6 cube vs the
/// 24-gray ramp, preferring the cube unless the source is near-neutral
/// (spread < 10) AND grayscale is genuinely closer.
fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    const r_idx = findClosestCubeIndex(r);
    const g_idx = findClosestCubeIndex(g);
    const b_idx = findClosestCubeIndex(b);
    const cube_r: u8 = @intCast(cube_values[r_idx]);
    const cube_g: u8 = @intCast(cube_values[g_idx]);
    const cube_b: u8 = @intCast(cube_values[b_idx]);
    const cube_index: u8 = @intCast(16 + 36 * r_idx + 6 * g_idx + b_idx);
    const cube_dist = colorDistance(r, g, b, cube_r, cube_g, cube_b);

    // Grayscale candidate.
    const gray_f: f64 = 0.299 * @as(f64, @floatFromInt(r)) + 0.587 * @as(f64, @floatFromInt(g)) + 0.114 * @as(f64, @floatFromInt(b));
    const gray: u8 = @intFromFloat(@round(gray_f));
    const gray_idx = findClosestGrayIndex(gray);
    const gray_value: u8 = @intCast(8 + gray_idx * 10);
    const gray_index: u8 = @intCast(232 + gray_idx);
    const gray_dist = colorDistance(r, g, b, gray_value, gray_value, gray_value);

    const max_c = @max(@max(r, g), b);
    const min_c = @min(@min(r, g), b);
    const spread: u8 = max_c - min_c;

    if (spread < 10 and gray_dist < cube_dist) return gray_index;
    return cube_index;
}

// ============================================================================
// Tests
// ============================================================================

test "fallback palette has all six tokens populated" {
    const palette = init(std.testing.allocator, .{ .theme_name = "definitely-not-a-real-theme" });
    try std.testing.expect(palette.is_fallback);
    try std.testing.expectEqualStrings(fallback.accent, palette.accent());
    try std.testing.expectEqualStrings(fallback.muted, palette.muted());
    try std.testing.expectEqualStrings(fallback.branch, palette.branch());
    try std.testing.expectEqualStrings(fallback.good, palette.good());
    try std.testing.expectEqualStrings(fallback.warn, palette.warn());
    try std.testing.expectEqualStrings(fallback.code_bg, palette.codeBg());
}

test "dark theme derives accent from #8abeb7 -> ANSI 256 index 109" {
    const palette = init(std.testing.allocator, .{ .theme_name = "dark" });
    try std.testing.expect(!palette.is_fallback);
    try std.testing.expectEqualStrings("dark", palette.name());
    // dark.accent = "accent" -> vars.accent = "#8abeb7" -> cube index 16 + 36*2 + 6*3 + 3 = 109.
    try std.testing.expectEqualStrings("\x1b[38;5;109m", palette.accent());
    // dark.muted = "gray" -> vars.gray = "#808080" -> gray ramp index 244.
    try std.testing.expectEqualStrings("\x1b[38;5;244m", palette.muted());
}

test "light theme picks a different accent than dark" {
    const dark = init(std.testing.allocator, .{ .theme_name = "dark" });
    const light = init(std.testing.allocator, .{ .theme_name = "light" });
    try std.testing.expect(!dark.is_fallback);
    try std.testing.expect(!light.is_fallback);
    try std.testing.expect(!std.mem.eql(u8, dark.accent(), light.accent()));
    try std.testing.expect(!std.mem.eql(u8, dark.muted(), light.muted()));
}

test "hexTo256 maps known upstream samples" {
    // #8abeb7 -> 109 (dark.accent / vars.accent)
    try std.testing.expectEqual(@as(?u8, 109), hexTo256("#8abeb7"));
    // #808080 -> 244 (dark muted, gray ramp because spread = 0).
    try std.testing.expectEqual(@as(?u8, 244), hexTo256("#808080"));
    // #5a8080 -> cube (spread = 38 > 10).
    const light_accent = hexTo256("#5a8080") orelse return error.TestUnexpectedResult;
    try std.testing.expect(light_accent >= 16 and light_accent < 232);
}

test "PI_THEME env var resolves over the default" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PI_THEME", "light");
    const palette = init(std.testing.allocator, .{ .env = &env });
    try std.testing.expect(!palette.is_fallback);
    try std.testing.expectEqualStrings("light", palette.name());
}

test "explicit theme_name beats PI_THEME env" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PI_THEME", "light");
    const palette = init(std.testing.allocator, .{ .theme_name = "dark", .env = &env });
    try std.testing.expectEqualStrings("dark", palette.name());
}

test "empty theme name still resolves through the default" {
    const palette = init(std.testing.allocator, .{ .theme_name = "" });
    try std.testing.expect(!palette.is_fallback);
    try std.testing.expectEqualStrings("dark", palette.name());
}

test "vars cycle does not crash and falls back" {
    // A theme JSON that references a var that points back at itself.
    const cyclic =
        \\{
        \\  "name": "cyclic",
        \\  "vars": { "a": "a" },
        \\  "colors": { "accent": "a", "muted": "a", "border": "a", "success": "a", "warning": "a", "selectedBg": "a" }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, cyclic, .{});
    defer parsed.deinit();
    const colors = parsed.value.object.get("colors").?.object;
    const vars = parsed.value.object.get("vars").?.object;
    var buf: [16]u8 = undefined;
    // Should return null without infinite recursion.
    try std.testing.expectEqual(@as(?[]const u8, null), deriveFg(&buf, colors, vars, "accent"));
}

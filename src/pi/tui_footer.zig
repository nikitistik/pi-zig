//! Multi-row interactive footer renderer for pi-zig.
//!
//! Ports the upstream pi-mono interactive footer (the bottom strip carrying the
//! pwd/git-branch/provider/model/thinking/timer/percent line). Upstream sources:
//!
//!   - `upstream/pi/packages/coding-agent/src/modes/interactive/components/footer.ts`
//!     — the FooterComponent that renders the pwd/branch line + cumulative
//!     token-and-context stats line plus per-extension status; the underlying
//!     visual layout (provider | model · thinking on the right) is mirrored
//!     here.
//!   - `upstream/pi/packages/coding-agent/src/modes/interactive/interactive-mode.ts`
//!     — `showNewVersionNotification` (the orange "Update Available" banner the
//!     interactive mode pushes when a newer release is detected).
//!   - `upstream/pi/packages/coding-agent/src/modes/interactive/components/keybinding-hints.ts`
//!     — `keyHint`/`rawKeyHint` (the dim-key + muted-description format of the
//!     bottom hint line under the footer).
//!
//! The upstream FooterComponent uses live data from `AgentSession` (token usage,
//! context window percent) which is not yet wired into pi-zig's TUI; the
//! VISUAL layout we ship now is the requested 6-row block:
//!
//!     <divider>
//!     <update-banner>   (optional; gated by App.update_banner_text)
//!     <divider>
//!     <composer-spacer>
//!     <divider>
//!     <status-row>      (left=branch, right=provider | model · thinking + timers)
//!     <hint-row>        (dim key + muted description, like upstream keyHint())
//!
//! Progress bars use U+2588 FULL BLOCK and U+258C LEFT HALF BLOCK so the
//! half-block falls on the boundary cell exactly like upstream. Both the
//! per-session (5h default) and per-week (7d default) windows are configurable
//! via env (`PI_ZIG_SESSION_WINDOW_HOURS`, `PI_ZIG_WEEK_WINDOW_DAYS`); the App
//! reads these at init and stores them as i128 nanoseconds for the renderer.
//!
//! All ANSI styling is opened and closed on the same line so the differential
//! renderer's line-level diff stays correct; spilling SGR state across rows
//! would corrupt subsequent rewrites.

const std = @import("std");
const tui = @import("tui.zig");

/// UTF-8 box-drawing horizontal rule glyph (U+2500).
const divider_segment = "\xe2\x94\x80";
/// UTF-8 full block (U+2588). Renders as a solid colored cell.
pub const block_full = "\xe2\x96\x88";
/// UTF-8 left half block (U+258C). Renders the left half of a cell colored,
/// the right half background — used as the partial-cell glyph in upstream-style
/// progress bars so the half-step is a real visual mid-point.
pub const block_half = "\xe2\x96\x8c";
/// UTF-8 box-drawings light up-and-right (U+2514, "└") + horizontal segment.
/// Used as the branch slot prefix in the status row, mirroring the visual
/// "drop-in from the composer" cue described in the wave brief.
const branch_prefix = "\xe2\x94\x94\xe2\x94\x80";

/// Default per-session window length. claude-code's interactive mode caps
/// usage at a 5-hour rolling window; we mirror that as the visual default
/// for the session progress bar. Overridable via PI_ZIG_SESSION_WINDOW_HOURS.
pub const default_session_window_hours: u64 = 5;
/// Default per-week window length. The "Week" progress block measures usage
/// against a 7-day rolling window. Overridable via PI_ZIG_WEEK_WINDOW_DAYS.
pub const default_week_window_days: u64 = 7;

/// Render width (cells) of each progress bar slot.
pub const progress_bar_width: usize = 6;

// =====================================================================
// Pure helpers (unit-tested below)
// =====================================================================

/// Build a divider line: dim foreground + 80 horizontal box-drawing glyphs +
/// reset. Caller owns the returned slice.
pub fn buildDivider(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, tui.sgr.muted);
    var i: usize = 0;
    while (i < 80) : (i += 1) try out.appendSlice(allocator, divider_segment);
    try out.appendSlice(allocator, tui.sgr.reset);
    return out.toOwnedSlice(allocator);
}

/// Render a single progress bar of `cells` width filled to `percent` (0..100).
/// Filled cells use U+2588; the boundary half-cell uses U+258C; remaining
/// cells use a single space. The bar is wrapped in `sgr.accent` so the filled
/// portion glows orange (matching upstream's accent color) and the trailing
/// reset closes the color. Caller owns the returned slice.
pub fn buildProgressBar(allocator: std.mem.Allocator, percent: u8, cells: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, tui.sgr.accent);

    const clamped: u32 = if (percent > 100) 100 else percent;
    // Half-step granularity: each cell carries two half-steps, so we map
    // percent -> halves in [0, cells*2].
    const total_halves: u32 = @as(u32, @intCast(cells)) * 2;
    const halves: u32 = (@as(u32, clamped) * total_halves) / 100;
    var i: u32 = 0;
    while (i < @as(u32, @intCast(cells))) : (i += 1) {
        const filled_halves = halves -| (i * 2);
        if (filled_halves >= 2) {
            try out.appendSlice(allocator, block_full);
        } else if (filled_halves == 1) {
            try out.appendSlice(allocator, block_half);
        } else {
            try out.append(allocator, ' ');
        }
    }
    try out.appendSlice(allocator, tui.sgr.reset);
    return out.toOwnedSlice(allocator);
}

/// Format an hours-minutes elapsed timer in the upstream `<Xh Y:m>` shape
/// when the window is multi-hour, falling back to `<Xm>` for sub-hour windows.
/// Used for the per-session window (default 5h). Caller owns the slice.
pub fn formatTimerHM(allocator: std.mem.Allocator, elapsed_seconds: u64) ![]u8 {
    const hours = elapsed_seconds / 3600;
    const minutes = (elapsed_seconds % 3600) / 60;
    if (hours > 0) {
        return std.fmt.allocPrint(allocator, "{d}h {d:0>2}m", .{ hours, minutes });
    }
    return std.fmt.allocPrint(allocator, "{d}m", .{minutes});
}

/// Format a days-hours elapsed timer in the upstream `<Xd Yh>` shape for the
/// per-week window (default 7d). For sub-day spans, falls back to `<Xh Y:m>`.
/// Caller owns the slice.
pub fn formatTimerDH(allocator: std.mem.Allocator, elapsed_seconds: u64) ![]u8 {
    const days = elapsed_seconds / 86400;
    const hours = (elapsed_seconds % 86400) / 3600;
    if (days > 0) {
        return std.fmt.allocPrint(allocator, "{d}d {d}h", .{ days, hours });
    }
    return formatTimerHM(allocator, elapsed_seconds);
}

/// Compute integer percent (0..100) of `elapsed / window`.
pub fn computePercent(elapsed_seconds: u64, window_seconds: u64) u8 {
    if (window_seconds == 0) return 0;
    if (elapsed_seconds >= window_seconds) return 100;
    const pct: u64 = (elapsed_seconds * 100) / window_seconds;
    return @intCast(pct);
}

/// Format a percent value as `NN%` (zero-padded to two digits when < 100).
/// Caller owns the slice.
pub fn formatPercent(allocator: std.mem.Allocator, percent: u8) ![]u8 {
    if (percent >= 100) return std.fmt.allocPrint(allocator, "100%", .{});
    return std.fmt.allocPrint(allocator, "{d:0>2}%", .{percent});
}

/// Build the "Update Available" banner line in the upstream orange/warn color.
/// Output is a single line because the differential renderer compares lines
/// literally and a multi-line banner would not survive a partial repaint.
/// Caller owns the slice. The `text` is the release version / instruction
/// string; we render it as: `▎ Update Available — <text>` (with the leading
/// glyph dropped if the text is empty).
pub fn buildBanner(allocator: std.mem.Allocator, banner_text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, tui.sgr.warn);
    try out.appendSlice(allocator, tui.sgr.bold);
    try out.appendSlice(allocator, "Update Available");
    try out.appendSlice(allocator, tui.sgr.reset);
    if (banner_text.len > 0) {
        try out.appendSlice(allocator, tui.sgr.warn);
        try out.appendSlice(allocator, " — ");
        try out.appendSlice(allocator, banner_text);
        try out.appendSlice(allocator, tui.sgr.reset);
    }
    return out.toOwnedSlice(allocator);
}

/// Build the bottom keybinding-hint line: dim key chord + muted description,
/// in the same shape upstream's `keyHint(keybinding, description)` produces.
/// We mirror just two common chords (Ctrl+C abort, /help) here so the row
/// stays compact; the dynamic full hint set is a follow-up.
pub fn buildHintLine(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Ctrl+C clear / Esc abort
    try out.appendSlice(allocator, tui.sgr.dim);
    try out.appendSlice(allocator, "Ctrl+C");
    try out.appendSlice(allocator, tui.sgr.reset);
    try out.appendSlice(allocator, tui.sgr.muted);
    try out.appendSlice(allocator, " clear/abort   ");
    try out.appendSlice(allocator, tui.sgr.reset);

    try out.appendSlice(allocator, tui.sgr.dim);
    try out.appendSlice(allocator, "/help");
    try out.appendSlice(allocator, tui.sgr.reset);
    try out.appendSlice(allocator, tui.sgr.muted);
    try out.appendSlice(allocator, " keyboard shortcuts");
    try out.appendSlice(allocator, tui.sgr.reset);

    return out.toOwnedSlice(allocator);
}

// =====================================================================
// Main renderer
// =====================================================================

/// Render the multi-row footer onto `lines` (App owns the slice). Mirrors the
/// upstream pi-mono visual layout described in the module doc. Skips the
/// per-render wall-clock read when `app.session_start_ns == 0` (the test path
/// passes `io = undefined` which would crash `Clock.real.now`).
///
/// Optional App fields (`update_banner_text`, `thinking_level`, `week_start_ns`,
/// `session_window_seconds`, `week_window_seconds`) are read via `@hasField`
/// at comptime so the renderer compiles even when the App schema hasn't been
/// extended yet (e.g. a parallel agent reset the integration hunk in tui.zig).
pub fn render(app: *tui.App, lines: *std.ArrayList([]u8)) !void {
    const allocator = app.allocator;

    // 1. Divider above the optional update banner.
    try lines.append(allocator, try buildDivider(allocator));

    // 2. Optional Update Available banner: only emitted when the host
    //    populated `app.update_banner_text` (e.g. from the PI_ZIG_NEW_VERSION
    //    env var). Real version-check HTTP probe is a follow-up.
    if (comptime @hasField(tui.App, "update_banner_text")) {
        if (app.update_banner_text) |text| {
            try lines.append(allocator, try buildBanner(allocator, text));
            try lines.append(allocator, try buildDivider(allocator));
        }
    }

    // 3. Composer spacer: a single empty line so the composer "breathes" above
    //    the status row. Owned (empty string).
    try lines.append(allocator, try allocator.dupe(u8, ""));

    // 4. Divider below the composer spacer.
    try lines.append(allocator, try buildDivider(allocator));

    // 5. Two-column status row.
    try lines.append(allocator, try renderStatusRow(app));

    // 6. Bottom keybinding-hint row.
    try lines.append(allocator, try buildHintLine(allocator));
}

/// Build the status row: left=branch (teal, with "└─" prefix when present);
/// right=`<provider> | <model> · <thinking>  <session timer> <bar> <pct>  | Week <wtimer> <bar> <pct>`.
/// Caller owns the returned slice.
fn renderStatusRow(app: *tui.App) ![]u8 {
    const allocator = app.allocator;
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(allocator);

    // Resolve the branch label once (App stores the cached buf+len).
    if (!app.git_branch_resolved) app.resolveGitBranch();

    // Left column: branch slot.
    if (app.git_branch_len > 0) {
        try row.appendSlice(allocator, tui.sgr.branch);
        try row.appendSlice(allocator, branch_prefix);
        try row.append(allocator, ' ');
        try row.appendSlice(allocator, app.git_branch_buf[0..app.git_branch_len]);
        try row.appendSlice(allocator, tui.sgr.reset);
    }
    // Gap between left and right columns (visual two-column layout).
    try row.appendSlice(allocator, "   ");

    // Right column: provider | model · thinking.
    const provider = app.options.provider orelse "(no provider)";
    const model_name = if (app.selected_model) |m| m.id else (app.options.model orelse "(no model)");
    try row.appendSlice(allocator, tui.sgr.accent);
    try row.appendSlice(allocator, provider);
    try row.appendSlice(allocator, tui.sgr.reset);
    try row.appendSlice(allocator, tui.sgr.muted);
    try row.appendSlice(allocator, " | ");
    try row.appendSlice(allocator, tui.sgr.reset);
    try row.appendSlice(allocator, tui.sgr.accent);
    try row.appendSlice(allocator, model_name);
    try row.appendSlice(allocator, tui.sgr.reset);
    try row.appendSlice(allocator, tui.sgr.muted);
    try row.appendSlice(allocator, " · thinking ");
    const thinking_lvl = if (comptime @hasField(tui.App, "thinking_level")) app.thinking_level else null;
    try row.appendSlice(allocator, thinkingLabel(thinking_lvl));
    try row.appendSlice(allocator, tui.sgr.reset);

    // Session timer + bar + percent.
    if (app.session_start_ns != 0) {
        const now_ns = std.Io.Clock.real.now(app.io).nanoseconds;
        const session_elapsed_s = elapsedSeconds(now_ns, app.session_start_ns);
        const session_window_s = if (comptime @hasField(tui.App, "session_window_seconds"))
            app.session_window_seconds
        else
            default_session_window_hours * 3600;
        try row.append(allocator, ' ');
        try row.append(allocator, ' ');
        try row.appendSlice(allocator, tui.sgr.muted);
        const session_timer = try formatTimerHM(allocator, session_elapsed_s);
        defer allocator.free(session_timer);
        try row.appendSlice(allocator, session_timer);
        try row.appendSlice(allocator, tui.sgr.reset);
        try row.append(allocator, ' ');
        const session_pct = computePercent(session_elapsed_s, session_window_s);
        const session_bar = try buildProgressBar(allocator, session_pct, progress_bar_width);
        defer allocator.free(session_bar);
        try row.appendSlice(allocator, session_bar);
        try row.append(allocator, ' ');
        try row.appendSlice(allocator, tui.sgr.muted);
        const session_pct_text = try formatPercent(allocator, session_pct);
        defer allocator.free(session_pct_text);
        try row.appendSlice(allocator, session_pct_text);
        try row.appendSlice(allocator, tui.sgr.reset);

        // Week separator.
        try row.appendSlice(allocator, tui.sgr.muted);
        try row.appendSlice(allocator, "  | Week ");
        try row.appendSlice(allocator, tui.sgr.reset);

        const week_start_ns = if (comptime @hasField(tui.App, "week_start_ns"))
            app.week_start_ns
        else
            app.session_start_ns;
        const week_elapsed_s = elapsedSeconds(now_ns, week_start_ns);
        const week_window_s = if (comptime @hasField(tui.App, "week_window_seconds"))
            app.week_window_seconds
        else
            default_week_window_days * 86400;
        try row.appendSlice(allocator, tui.sgr.muted);
        const week_timer = try formatTimerDH(allocator, week_elapsed_s);
        defer allocator.free(week_timer);
        try row.appendSlice(allocator, week_timer);
        try row.appendSlice(allocator, tui.sgr.reset);
        try row.append(allocator, ' ');
        const week_pct = computePercent(week_elapsed_s, week_window_s);
        const week_bar = try buildProgressBar(allocator, week_pct, progress_bar_width);
        defer allocator.free(week_bar);
        try row.appendSlice(allocator, week_bar);
        try row.append(allocator, ' ');
        try row.appendSlice(allocator, tui.sgr.muted);
        const week_pct_text = try formatPercent(allocator, week_pct);
        defer allocator.free(week_pct_text);
        try row.appendSlice(allocator, week_pct_text);
        try row.appendSlice(allocator, tui.sgr.reset);
    }

    return row.toOwnedSlice(allocator);
}

/// Coerce a wall-clock delta (i128 ns) to non-negative seconds. Used by the
/// renderer so both session and week timers stay monotonic when the host clock
/// jumps backward.
fn elapsedSeconds(now_ns: i128, start_ns: i128) u64 {
    if (start_ns == 0) return 0;
    const delta = now_ns - start_ns;
    if (delta <= 0) return 0;
    return @intCast(@divTrunc(delta, std.time.ns_per_s));
}

/// Map an optional `ThinkingLevel` to its upstream display label.
/// Returns "off" when unset, matching upstream's footer fallback.
fn thinkingLabel(level: ?@import("types.zig").ThinkingLevel) []const u8 {
    if (level) |l| {
        return switch (l) {
            .off => "off",
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
        };
    }
    return "off";
}

// =====================================================================
// Tests (pure helpers)
// =====================================================================

const testing = std.testing;

test "buildDivider emits dim + 80 horizontal glyphs + reset" {
    const out = try buildDivider(testing.allocator);
    defer testing.allocator.free(out);
    // Must open and close ANSI state on the same line.
    try testing.expect(std.mem.startsWith(u8, out, tui.sgr.muted));
    try testing.expect(std.mem.endsWith(u8, out, tui.sgr.reset));
    // 80 horizontal-rule glyphs (3 bytes each).
    var count: usize = 0;
    var i: usize = 0;
    while (i + 3 <= out.len) : (i += 1) {
        if (std.mem.eql(u8, out[i .. i + 3], divider_segment)) count += 1;
    }
    try testing.expect(count == 80);
}

test "buildProgressBar 0% renders all spaces wrapped in accent/reset" {
    const out = try buildProgressBar(testing.allocator, 0, 6);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, tui.sgr.accent));
    try testing.expect(std.mem.endsWith(u8, out, tui.sgr.reset));
    // Strip the wrapping SGR; the middle should be exactly 6 spaces.
    const inner = out[tui.sgr.accent.len .. out.len - tui.sgr.reset.len];
    try testing.expectEqualStrings("      ", inner);
}

test "buildProgressBar 100% renders 6 full blocks" {
    const out = try buildProgressBar(testing.allocator, 100, 6);
    defer testing.allocator.free(out);
    // 6 full-block glyphs (3 bytes each) between the SGR wrappers.
    const inner = out[tui.sgr.accent.len .. out.len - tui.sgr.reset.len];
    try testing.expect(inner.len == 6 * 3);
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try testing.expectEqualStrings(block_full, inner[i * 3 .. i * 3 + 3]);
    }
}

test "buildProgressBar 50% renders 3 full blocks then spaces" {
    const out = try buildProgressBar(testing.allocator, 50, 6);
    defer testing.allocator.free(out);
    const inner = out[tui.sgr.accent.len .. out.len - tui.sgr.reset.len];
    // 3 full blocks (3 bytes each) then 3 spaces.
    try testing.expectEqualStrings(block_full, inner[0..3]);
    try testing.expectEqualStrings(block_full, inner[3..6]);
    try testing.expectEqualStrings(block_full, inner[6..9]);
    try testing.expectEqualStrings("   ", inner[9..]);
}

test "buildProgressBar half-step boundary uses U+258C left-half block" {
    // 8% of 6 cells = 0.48 cells -> 0 halves filled (since 8*12/100 = 0).
    // 9% of 6 cells = 0.54 cells -> 1 half filled.
    const out = try buildProgressBar(testing.allocator, 9, 6);
    defer testing.allocator.free(out);
    const inner = out[tui.sgr.accent.len .. out.len - tui.sgr.reset.len];
    try testing.expectEqualStrings(block_half, inner[0..3]);
}

test "formatTimerHM falls back to minutes when sub-hour" {
    const out_a = try formatTimerHM(testing.allocator, 30); // 30s -> 0m
    defer testing.allocator.free(out_a);
    try testing.expectEqualStrings("0m", out_a);

    const out_b = try formatTimerHM(testing.allocator, 5 * 60); // 5 minutes
    defer testing.allocator.free(out_b);
    try testing.expectEqualStrings("5m", out_b);
}

test "formatTimerHM renders hours and zero-padded minutes when multi-hour" {
    // 1h 03m
    const out = try formatTimerHM(testing.allocator, 60 * 60 + 3 * 60);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("1h 03m", out);
}

test "formatTimerDH renders days + hours when multi-day" {
    // 2d 5h
    const out = try formatTimerDH(testing.allocator, 2 * 86400 + 5 * 3600);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("2d 5h", out);
}

test "formatTimerDH falls back to HM shape for sub-day spans" {
    const out = try formatTimerDH(testing.allocator, 7200); // 2h 00m
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("2h 00m", out);
}

test "computePercent clamps to 100 when window exceeded" {
    try testing.expect(computePercent(0, 100) == 0);
    try testing.expect(computePercent(50, 100) == 50);
    try testing.expect(computePercent(100, 100) == 100);
    try testing.expect(computePercent(200, 100) == 100);
    try testing.expect(computePercent(0, 0) == 0); // zero window guard
}

test "formatPercent pads sub-100 with leading zero, full when 100" {
    {
        const out = try formatPercent(testing.allocator, 7);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("07%", out);
    }
    {
        const out = try formatPercent(testing.allocator, 42);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("42%", out);
    }
    {
        const out = try formatPercent(testing.allocator, 100);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("100%", out);
    }
}

test "buildBanner wraps text in warn+bold and adds em-dash separator" {
    const out = try buildBanner(testing.allocator, "v1.2.3 release");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, tui.sgr.warn));
    try testing.expect(std.mem.indexOf(u8, out, "Update Available") != null);
    try testing.expect(std.mem.indexOf(u8, out, "v1.2.3 release") != null);
    // " — " (UTF-8 em-dash) is the separator between the label and version.
    try testing.expect(std.mem.indexOf(u8, out, " \xe2\x80\x94 ") != null);
}

test "buildBanner with empty text emits only the label" {
    const out = try buildBanner(testing.allocator, "");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Update Available") != null);
    try testing.expect(std.mem.indexOf(u8, out, " \xe2\x80\x94 ") == null);
}

test "buildHintLine carries the dim Ctrl+C and /help hints" {
    const out = try buildHintLine(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Ctrl+C") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/help") != null);
    try testing.expect(std.mem.indexOf(u8, out, tui.sgr.dim) != null);
    try testing.expect(std.mem.indexOf(u8, out, tui.sgr.muted) != null);
}

test "thinkingLabel maps each enum variant and defaults to off when null" {
    try testing.expectEqualStrings("off", thinkingLabel(null));
    try testing.expectEqualStrings("off", thinkingLabel(.off));
    try testing.expectEqualStrings("xhigh", thinkingLabel(.xhigh));
    try testing.expectEqualStrings("medium", thinkingLabel(.medium));
}

test "elapsedSeconds clamps negative and zero deltas to 0" {
    try testing.expect(elapsedSeconds(0, 0) == 0);
    try testing.expect(elapsedSeconds(100, 0) == 0); // start_ns == 0 sentinel
    try testing.expect(elapsedSeconds(1_000_000_000, 2_000_000_000) == 0);
    try testing.expect(elapsedSeconds(2_000_000_000, 1_000_000_000) == 1);
}

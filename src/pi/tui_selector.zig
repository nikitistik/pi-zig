//! Generic scrollable select-list overlay for the TUI.
//!
//! [FLOW_TUI_SELECTOR] Mirrors the upstream
//! `packages/tui/src/components/select-list.ts` `SelectList` component:
//! a scrollable list of `{value, label, description?}` items with a
//! highlighted cursor row, scroll-position indicator, wrap-around
//! Up/Down navigation, and Enter/Esc actions. The component is pure
//! state + rendering; the App owns the actual terminal I/O and key
//! decoding (the App calls `handleKey()` with already-decoded bytes).
//!
//! Used by the representative `/theme` selector overlay (see
//! `tui.zig`'s `theme_selector_active` path). Future selectors
//! (settings/thinking/session/etc.) can share the same primitive.
//!
//! Upstream uses three rendering features the Zig live TUI doesn't
//! need yet (truecolor truncation, two-column description layout, and
//! filter typing), so this port keeps a minimal single-column list
//! with optional descriptions appended after the label. The wrap and
//! scroll math match upstream exactly.

const std = @import("std");
const tui_keys = @import("tui_keys.zig");
const tui_theme = @import("tui_theme.zig");

/// One row in the select list. `value` is the canonical id returned
/// when the user confirms; `label` is what's drawn (defaults to
/// `value` when empty); `description` is a dim suffix.
pub const Item = struct {
    value: []const u8,
    label: []const u8 = "",
    description: []const u8 = "",

    pub fn display(self: Item) []const u8 {
        return if (self.label.len > 0) self.label else self.value;
    }
};

/// Selector state. The owning App initializes one per active overlay
/// (e.g. `/theme`); the App's `buildScreen` calls `render` to emit
/// the visible rows, and `handleKey` to dispatch keys.
pub const SelectList = struct {
    items: []const Item,
    selected: usize = 0,
    max_visible: usize = 8,
    palette: tui_theme.Palette = .{},

    /// True when the user confirmed (Enter); set by `handleKey`.
    confirmed: bool = false,
    /// True when the user cancelled (Esc / Ctrl+C); set by `handleKey`.
    cancelled: bool = false,

    pub fn init(items: []const Item, max_visible: usize, palette: tui_theme.Palette) SelectList {
        return .{
            .items = items,
            .selected = 0,
            .max_visible = @max(1, max_visible),
            .palette = palette,
        };
    }

    /// Snap the cursor to a specific row. Out-of-range values clamp.
    pub fn setSelectedIndex(self: *SelectList, index: usize) void {
        if (self.items.len == 0) {
            self.selected = 0;
            return;
        }
        self.selected = @min(index, self.items.len - 1);
    }

    /// Move the cursor by `delta` rows with wrap-around. No-op when
    /// the list is empty. Mirrors upstream `handleInput` `tui.select.up`
    /// / `tui.select.down` (top wraps to bottom, bottom wraps to top).
    pub fn move(self: *SelectList, delta: i64) void {
        if (self.items.len == 0) return;
        const len_i: i64 = @intCast(self.items.len);
        var next: i64 = @as(i64, @intCast(self.selected)) + delta;
        next = @mod(next, len_i);
        if (next < 0) next += len_i;
        self.selected = @intCast(next);
    }

    /// Dispatch a decoded key sequence. Returns true when the key was
    /// consumed by the selector (caller swallows it instead of forwarding
    /// to the editor). Sets `confirmed` / `cancelled` flags the App polls
    /// to apply the selection / close the overlay.
    pub fn handleKey(self: *SelectList, data: []const u8) bool {
        if (tui_keys.matches(data, "tui.select.up")) {
            self.move(-1);
            return true;
        }
        if (tui_keys.matches(data, "tui.select.down")) {
            self.move(1);
            return true;
        }
        if (tui_keys.matches(data, "tui.select.confirm")) {
            self.confirmed = true;
            return true;
        }
        if (tui_keys.matches(data, "tui.select.cancel")) {
            self.cancelled = true;
            return true;
        }
        return false;
    }

    /// Compute the visible window into `items` given `max_visible`.
    /// Mirrors upstream `render()`'s scrolling math (keep the cursor
    /// centered when possible; clamp at the ends).
    pub fn visibleWindow(self: *const SelectList) struct { start: usize, end: usize } {
        if (self.items.len == 0) return .{ .start = 0, .end = 0 };
        const half = self.max_visible / 2;
        var start: usize = 0;
        if (self.selected > half) start = self.selected - half;
        if (start + self.max_visible > self.items.len) {
            start = if (self.items.len > self.max_visible) self.items.len - self.max_visible else 0;
        }
        const end = @min(start + self.max_visible, self.items.len);
        return .{ .start = start, .end = end };
    }

    /// Render the selector into `out` as owned lines (caller frees each).
    /// Each line is self-contained (open/close ANSI on the same line) so
    /// the differential renderer's line-level diff stays correct.
    pub fn render(self: *const SelectList, allocator: std.mem.Allocator, out: *std.ArrayList([]u8)) !void {
        if (self.items.len == 0) {
            const line = try std.fmt.allocPrint(allocator, "{s}  (no items){s}", .{ self.palette.muted(), "\x1b[0m" });
            try out.append(allocator, line);
            return;
        }
        const window = self.visibleWindow();
        var i: usize = window.start;
        while (i < window.end) : (i += 1) {
            const item = self.items[i];
            const is_selected = (i == self.selected);
            const prefix = if (is_selected) "> " else "  ";
            const display = item.display();
            const line: []u8 = if (item.description.len == 0)
                if (is_selected)
                    try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ self.palette.accent(), prefix, display, "\x1b[0m" })
                else
                    try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, display })
            else if (is_selected)
                try std.fmt.allocPrint(allocator, "{s}{s}{s}  {s}{s}", .{ self.palette.accent(), prefix, display, item.description, "\x1b[0m" })
            else
                try std.fmt.allocPrint(allocator, "{s}{s}  {s}{s}{s}", .{ prefix, display, self.palette.muted(), item.description, "\x1b[0m" });
            try out.append(allocator, line);
        }
        if (window.start > 0 or window.end < self.items.len) {
            const scroll_line = try std.fmt.allocPrint(allocator, "{s}  ({d}/{d}){s}", .{ self.palette.muted(), self.selected + 1, self.items.len, "\x1b[0m" });
            try out.append(allocator, scroll_line);
        }
    }

    /// Return the currently highlighted item, or null when empty.
    pub fn selectedItem(self: *const SelectList) ?Item {
        if (self.items.len == 0) return null;
        return self.items[self.selected];
    }
};

// ============================================================================
// Tests
// ============================================================================

test "empty list renders the (no items) placeholder" {
    var list = SelectList.init(&.{}, 5, .{});
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| std.testing.allocator.free(l);
        lines.deinit(std.testing.allocator);
    }
    try list.render(std.testing.allocator, &lines);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "(no items)") != null);
}

test "move wraps from top to bottom and back" {
    const items = [_]Item{
        .{ .value = "a" },
        .{ .value = "b" },
        .{ .value = "c" },
    };
    var list = SelectList.init(&items, 5, .{});
    try std.testing.expectEqual(@as(usize, 0), list.selected);
    list.move(-1);
    try std.testing.expectEqual(@as(usize, 2), list.selected);
    list.move(1);
    try std.testing.expectEqual(@as(usize, 0), list.selected);
    list.move(2);
    try std.testing.expectEqual(@as(usize, 2), list.selected);
    list.move(1);
    try std.testing.expectEqual(@as(usize, 0), list.selected);
}

test "handleKey routes up/down/enter/escape" {
    const items = [_]Item{
        .{ .value = "a" },
        .{ .value = "b" },
    };
    var list = SelectList.init(&items, 5, .{});
    // Down moves the cursor.
    try std.testing.expect(list.handleKey("\x1b[B")); // down arrow
    try std.testing.expectEqual(@as(usize, 1), list.selected);
    // Up wraps.
    try std.testing.expect(list.handleKey("\x1b[A")); // up arrow
    try std.testing.expectEqual(@as(usize, 0), list.selected);
    // Enter confirms.
    try std.testing.expect(list.handleKey("\r"));
    try std.testing.expect(list.confirmed);
    // Escape cancels (on a fresh selector).
    var list2 = SelectList.init(&items, 5, .{});
    try std.testing.expect(list2.handleKey("\x1b"));
    try std.testing.expect(list2.cancelled);
    // Unknown key is not consumed.
    try std.testing.expect(!list.handleKey("x"));
}

test "render marks the selected row with the accent escape and a caret" {
    const items = [_]Item{
        .{ .value = "dark", .description = "(current)" },
        .{ .value = "light" },
    };
    var list = SelectList.init(&items, 5, .{});
    list.setSelectedIndex(1);
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| std.testing.allocator.free(l);
        lines.deinit(std.testing.allocator);
    }
    try list.render(std.testing.allocator, &lines);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    // Row 0 is not selected: no leading caret and no fallback accent at the start.
    try std.testing.expect(std.mem.startsWith(u8, lines.items[0], "  "));
    // Row 1 is selected: starts with the fallback accent escape + caret.
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "\x1b[38;5;208m") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "> light") != null);
}

test "visibleWindow keeps the cursor centered with a scroll indicator" {
    // 10 items, max_visible 4, cursor at index 5 -> window centers around 5.
    var items_buf: [10]Item = undefined;
    for (&items_buf, 0..) |*it, i| {
        // Static-string values are fine in a test (no escaping/format needed).
        it.* = .{ .value = if (i == 0) "0" else if (i == 1) "1" else if (i == 2) "2" else if (i == 3) "3" else if (i == 4) "4" else if (i == 5) "5" else if (i == 6) "6" else if (i == 7) "7" else if (i == 8) "8" else "9" };
    }
    var list = SelectList.init(&items_buf, 4, .{});
    list.setSelectedIndex(5);
    const window = list.visibleWindow();
    try std.testing.expect(window.start <= 5);
    try std.testing.expect(window.end > 5);
    try std.testing.expectEqual(@as(usize, 4), window.end - window.start);

    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| std.testing.allocator.free(l);
        lines.deinit(std.testing.allocator);
    }
    try list.render(std.testing.allocator, &lines);
    // 4 visible rows + 1 scroll indicator.
    try std.testing.expectEqual(@as(usize, 5), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[4], "/10") != null);
}

test "selectedItem returns the highlighted row" {
    const items = [_]Item{
        .{ .value = "alpha" },
        .{ .value = "beta" },
    };
    var list = SelectList.init(&items, 5, .{});
    list.setSelectedIndex(1);
    try std.testing.expectEqualStrings("beta", list.selectedItem().?.value);
}

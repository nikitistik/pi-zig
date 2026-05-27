//! Differential line renderer for the TUI.
//!
//! Ports the line-diff core of upstream `packages/tui/src/tui.ts` `doRender()`:
//! given the previously rendered lines and the new lines (already wrapped to the
//! terminal width by the caller), compute the ANSI byte sequence that updates
//! the terminal.
//!
//! Invariant: after every `render`, the hardware cursor is left at column 0 of
//! the LAST rendered line. The next `render` computes upward motion from there.
//! Because positioning is relative to the bottom of the block, it stays correct
//! even when the terminal scrolls as content is appended.
//!
//! Two strategies mirror upstream:
//!   - In-place line diff when the line count is unchanged (the common case
//!     while editing the prompt or streaming text into the last lines): only
//!     changed lines are moved-to, cleared, and rewritten.
//!   - Full redraw (clear scrollback + home + rewrite) when the line count
//!     changes (append/shrink) — upstream falls back to `fullRender` for
//!     height/shrink changes; we use it for any count change so the visible
//!     block is always consistent without fragile absolute-row math.
//!
//! Kitty image handling, overlay compositing, and synchronized-output guards
//! are not ported (noted as remaining). The diff itself is deterministic, which
//! is what the snapshot tests exercise.

const std = @import("std");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    /// Previously rendered lines (owned copies). Empty before the first render.
    previous: std.ArrayList([]u8) = .empty,
    /// Row of the hardware cursor relative to the top of the rendered block.
    /// Held at the last line index by the post-render invariant.
    cursor_row: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Renderer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Renderer) void {
        for (self.previous.items) |line| self.allocator.free(line);
        self.previous.deinit(self.allocator);
    }

    fn replacePrevious(self: *Renderer, new_lines: []const []const u8) !void {
        for (self.previous.items) |line| self.allocator.free(line);
        self.previous.clearRetainingCapacity();
        for (new_lines) |line| {
            try self.previous.append(self.allocator, try self.allocator.dupe(u8, line));
        }
        // Invariant: cursor ends at the last rendered line.
        self.cursor_row = if (new_lines.len == 0) 0 else new_lines.len - 1;
    }

    /// Emit every line; cursor ends on the last line.
    fn writeAllLines(self: *Renderer, buf: *std.ArrayList(u8), new_lines: []const []const u8) !void {
        for (new_lines, 0..) |line, i| {
            if (i > 0) try buf.appendSlice(self.allocator, "\r\n");
            try buf.appendSlice(self.allocator, line);
        }
    }

    /// Compute the ANSI update for transitioning the screen to `new_lines`.
    /// Caller owns the returned buffer. Updates internal previous-state.
    ///
    /// Escape vocabulary:
    ///   - `\r`              carriage return (column 0)
    ///   - `ESC[<n>A`        move cursor up n rows
    ///   - `ESC[2K`          clear entire line
    ///   - `ESC[2J ESC[H ESC[3J`  clear screen, home, clear scrollback
    pub fn render(self: *Renderer, new_lines: []const []const u8) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        // First render: emit everything (assume a clean line).
        if (self.previous.items.len == 0) {
            try self.writeAllLines(&buf, new_lines);
            try self.replacePrevious(new_lines);
            return buf.toOwnedSlice(self.allocator);
        }

        // Line-count change -> full redraw for a consistent visible block.
        if (new_lines.len != self.previous.items.len) {
            // Move cursor to the top of the current block, then clear downward.
            if (self.cursor_row > 0) {
                try buf.print(self.allocator, "\x1b[{d}A", .{self.cursor_row});
            }
            try buf.appendSlice(self.allocator, "\r\x1b[0J"); // CR + clear to end of screen
            try self.writeAllLines(&buf, new_lines);
            try self.replacePrevious(new_lines);
            return buf.toOwnedSlice(self.allocator);
        }

        // Same line count: in-place diff of changed lines.
        var first_changed: ?usize = null;
        var last_changed: usize = 0;
        var i: usize = 0;
        while (i < new_lines.len) : (i += 1) {
            if (!std.mem.eql(u8, self.previous.items[i], new_lines[i])) {
                if (first_changed == null) first_changed = i;
                last_changed = i;
            }
        }

        // No changes: leave cursor where it is.
        if (first_changed == null) return buf.toOwnedSlice(self.allocator);
        const start = first_changed.?;

        // Move up from the last line (cursor_row) to the first changed line.
        if (self.cursor_row > start) {
            try buf.print(self.allocator, "\x1b[{d}A", .{self.cursor_row - start});
        }
        // Rewrite changed lines top-down.
        var row = start;
        while (row <= last_changed) : (row += 1) {
            if (row > start) try buf.appendSlice(self.allocator, "\r\n");
            try buf.appendSlice(self.allocator, "\r\x1b[2K");
            try buf.appendSlice(self.allocator, new_lines[row]);
        }
        // Return the cursor to the last line so the invariant holds.
        const last_index = new_lines.len - 1;
        if (last_changed < last_index) {
            try buf.print(self.allocator, "\x1b[{d}B", .{last_index - last_changed});
        }
        try buf.appendSlice(self.allocator, "\r");

        try self.replacePrevious(new_lines);
        return buf.toOwnedSlice(self.allocator);
    }

    /// Force a full redraw on the next `render` (e.g. after a terminal resize).
    pub fn invalidate(self: *Renderer) void {
        for (self.previous.items) |line| self.allocator.free(line);
        self.previous.clearRetainingCapacity();
        self.cursor_row = 0;
    }
};

/// Hard-wrap a single logical line to `width` columns (byte-based; assumes
/// no embedded ANSI for the wrap-width accounting). Returns a list of owned
/// line slices. Caller frees each line and the list.
pub fn wrapLine(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), text: []const u8, width: usize) !void {
    if (width == 0 or text.len <= width) {
        try out.append(allocator, try allocator.dupe(u8, text));
        return;
    }
    var i: usize = 0;
    while (i < text.len) {
        const end = @min(i + width, text.len);
        try out.append(allocator, try allocator.dupe(u8, text[i..end]));
        i = end;
    }
}

// ===== Tests =====

fn freeLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| allocator.free(l);
    allocator.free(lines);
}

test "first render emits all lines joined by CRLF" {
    var r = Renderer.init(std.testing.allocator);
    defer r.deinit();
    const out = try r.render(&.{ "line one", "line two" });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("line one\r\nline two", out);
    try std.testing.expect(r.cursor_row == 1);
}

test "unchanged render produces empty update" {
    var r = Renderer.init(std.testing.allocator);
    defer r.deinit();
    const first = try r.render(&.{ "a", "b" });
    std.testing.allocator.free(first);
    const second = try r.render(&.{ "a", "b" });
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("", second);
}

test "single changed line moves cursor up, rewrites it, returns to last line" {
    var r = Renderer.init(std.testing.allocator);
    defer r.deinit();
    const first = try r.render(&.{ "a", "b", "c" });
    std.testing.allocator.free(first); // cursor at row 2 (last line)
    const upd = try r.render(&.{ "a", "B", "c" });
    defer std.testing.allocator.free(upd);
    // Up 1 (row 2 -> 1), clear+write "B", down 1 back to last line, CR.
    try std.testing.expectEqualStrings("\x1b[1A\r\x1b[2KB\x1b[1B\r", upd);
}

test "changing the last line needs no return motion" {
    var r = Renderer.init(std.testing.allocator);
    defer r.deinit();
    const first = try r.render(&.{ "a", "b" });
    std.testing.allocator.free(first); // cursor at row 1
    const upd = try r.render(&.{ "a", "B" });
    defer std.testing.allocator.free(upd);
    // Already on the last line; just clear and rewrite, then CR.
    try std.testing.expectEqualStrings("\r\x1b[2KB\r", upd);
}

test "appending lines triggers a full redraw that clears to end of screen" {
    var r = Renderer.init(std.testing.allocator);
    defer r.deinit();
    const first = try r.render(&.{"a"});
    std.testing.allocator.free(first); // cursor at row 0
    const upd = try r.render(&.{ "a", "b" });
    defer std.testing.allocator.free(upd);
    // Count changed (1 -> 2): full redraw. Cursor at row 0 already, so CR +
    // clear-to-end, then write both lines.
    try std.testing.expectEqualStrings("\r\x1b[0Ja\r\nb", upd);
}

test "shrinking content clears removed lines via full redraw" {
    var r = Renderer.init(std.testing.allocator);
    defer r.deinit();
    const first = try r.render(&.{ "a", "b", "c" });
    std.testing.allocator.free(first); // cursor at row 2
    const upd = try r.render(&.{"a"});
    defer std.testing.allocator.free(upd);
    // Count changed (3 -> 1): move up 2 to the top, CR, clear to end, write "a".
    try std.testing.expectEqualStrings("\x1b[2A\r\x1b[0Ja", upd);
    // Internal state should reflect the single remaining line.
    try std.testing.expect(r.previous.items.len == 1);
}

test "wrapLine splits on width boundaries" {
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| std.testing.allocator.free(l);
        lines.deinit(std.testing.allocator);
    }
    try wrapLine(std.testing.allocator, &lines, "abcdef", 2);
    try std.testing.expect(lines.items.len == 3);
    try std.testing.expectEqualStrings("ab", lines.items[0]);
    try std.testing.expectEqualStrings("ef", lines.items[2]);
}

test "invalidate forces a full redraw" {
    var r = Renderer.init(std.testing.allocator);
    defer r.deinit();
    const first = try r.render(&.{ "a", "b" });
    std.testing.allocator.free(first);
    r.invalidate();
    const upd = try r.render(&.{ "a", "b" });
    defer std.testing.allocator.free(upd);
    try std.testing.expectEqualStrings("a\r\nb", upd);
}

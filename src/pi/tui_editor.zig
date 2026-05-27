//! Prompt composer / line editor for the TUI.
//!
//! Ports the editing logic of upstream `packages/tui/src/components/editor.ts`:
//! a multi-line buffer with cursor movement (char/word/line), Emacs-style kill
//! ring (`kill-ring.ts`), deletion operations, prompt history browsing, and a
//! single-level snapshot undo. Word boundaries follow upstream
//! `isWhitespaceChar` / `isPunctuationChar` (`packages/tui/src/utils.ts`).
//!
//! Cursor positions are byte offsets within a line. Upstream operates on
//! grapheme clusters; for the ASCII / common-UTF-8 prompts this surface targets,
//! byte offsets reproduce the same observable cursor/word/kill behavior. Full
//! grapheme-cluster segmentation is noted as a remaining refinement.

const std = @import("std");

/// Punctuation set, mirroring upstream PUNCTUATION_REGEX
/// `/[(){}[\]<>.,;:'"!?+\-=*/\\|&%^$#@~`]/`.
fn isPunctuation(c: u8) bool {
    return switch (c) {
        '(', ')', '{', '}', '[', ']', '<', '>', '.', ',', ';', ':', '\'', '"', '!', '?', '+', '-', '=', '*', '/', '\\', '|', '&', '%', '^', '$', '#', '@', '~', '`' => true,
        else => false,
    };
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0b or c == 0x0c;
}

const KillRing = struct {
    entries: std.ArrayList([]u8) = .empty,

    fn deinit(self: *KillRing, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e);
        self.entries.deinit(allocator);
    }

    fn len(self: *const KillRing) usize {
        return self.entries.items.len;
    }

    /// Add killed text. When accumulating, merge with the most recent entry
    /// (prepend for backward deletion, append for forward).
    fn push(self: *KillRing, allocator: std.mem.Allocator, text: []const u8, prepend: bool, accumulate: bool) !void {
        if (text.len == 0) return;
        if (accumulate and self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            const merged = if (prepend)
                try std.mem.concat(allocator, u8, &.{ text, last })
            else
                try std.mem.concat(allocator, u8, &.{ last, text });
            allocator.free(last);
            self.entries.items[self.entries.items.len - 1] = merged;
        } else {
            try self.entries.append(allocator, try allocator.dupe(u8, text));
        }
    }

    fn peek(self: *const KillRing) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.entries.items.len - 1];
    }

    /// Move last entry to front (for yank-pop cycling).
    fn rotate(self: *KillRing, allocator: std.mem.Allocator) !void {
        if (self.entries.items.len > 1) {
            const last = self.entries.pop().?;
            try self.entries.insert(allocator, 0, last);
        }
    }
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    /// Logical lines (no trailing newline). Always at least one line.
    lines: std.ArrayList(std.ArrayList(u8)),
    cursor_line: usize = 0,
    cursor_col: usize = 0,

    kill_ring: KillRing = .{},
    last_action: enum { none, kill, yank } = .none,

    /// Prompt history (oldest first). -1 (== history.len) means "not browsing".
    history: std.ArrayList([]u8) = .empty,
    history_index: usize = std.math.maxInt(usize),
    /// Saved draft when entering history browsing.
    saved_draft: ?[]u8 = null,

    /// Single-level undo snapshot of the full text + cursor.
    undo_text: ?[]u8 = null,
    undo_line: usize = 0,
    undo_col: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Editor {
        var lines: std.ArrayList(std.ArrayList(u8)) = .empty;
        try lines.append(allocator, .empty);
        return .{ .allocator = allocator, .lines = lines };
    }

    pub fn deinit(self: *Editor) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.kill_ring.deinit(self.allocator);
        for (self.history.items) |h| self.allocator.free(h);
        self.history.deinit(self.allocator);
        if (self.saved_draft) |d| self.allocator.free(d);
        if (self.undo_text) |t| self.allocator.free(t);
    }

    fn currentLine(self: *Editor) *std.ArrayList(u8) {
        return &self.lines.items[self.cursor_line];
    }

    fn clampCursorCol(self: *Editor) void {
        const line_len = self.currentLine().items.len;
        if (self.cursor_col > line_len) self.cursor_col = line_len;
    }

    /// Serialize the full text (lines joined with '\n'). Caller owns memory.
    pub fn getText(self: *Editor) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        for (self.lines.items, 0..) |line, i| {
            if (i > 0) try out.append(self.allocator, '\n');
            try out.appendSlice(self.allocator, line.items);
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Replace the buffer with `text`, splitting on '\n', cursor at the end.
    pub fn setText(self: *Editor, text: []const u8) !void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |part| {
            var line: std.ArrayList(u8) = .empty;
            try line.appendSlice(self.allocator, part);
            try self.lines.append(self.allocator, line);
        }
        if (self.lines.items.len == 0) try self.lines.append(self.allocator, .empty);
        self.cursor_line = self.lines.items.len - 1;
        self.cursor_col = self.lines.items[self.cursor_line].items.len;
        self.last_action = .none;
    }

    pub fn isEmpty(self: *Editor) bool {
        return self.lines.items.len == 1 and self.lines.items[0].items.len == 0;
    }

    fn pushUndoSnapshot(self: *Editor) void {
        const text = self.getText() catch return;
        if (self.undo_text) |t| self.allocator.free(t);
        self.undo_text = text;
        self.undo_line = self.cursor_line;
        self.undo_col = self.cursor_col;
    }

    pub fn undo(self: *Editor) !void {
        const text = self.undo_text orelse return;
        const owned = try self.allocator.dupe(u8, text);
        defer self.allocator.free(owned);
        try self.setText(owned);
        self.cursor_line = @min(self.undo_line, self.lines.items.len - 1);
        self.cursor_col = self.undo_col;
        self.clampCursorCol();
        self.allocator.free(self.undo_text.?);
        self.undo_text = null;
    }

    fn exitHistory(self: *Editor) void {
        self.history_index = std.math.maxInt(usize);
    }

    // -- Insertion --------------------------------------------------------

    /// Insert printable text at the cursor (no embedded newlines).
    pub fn insertText(self: *Editor, text: []const u8) !void {
        if (text.len == 0) return;
        self.exitHistory();
        self.last_action = .none;
        var line = self.currentLine();
        try line.insertSlice(self.allocator, self.cursor_col, text);
        self.cursor_col += text.len;
    }

    /// Insert a line break at the cursor, splitting the current line.
    pub fn newLine(self: *Editor) !void {
        self.exitHistory();
        self.last_action = .none;
        var line = self.currentLine();
        const tail = try self.allocator.dupe(u8, line.items[self.cursor_col..]);
        defer self.allocator.free(tail);
        line.shrinkRetainingCapacity(self.cursor_col);
        var new_line: std.ArrayList(u8) = .empty;
        try new_line.appendSlice(self.allocator, tail);
        try self.lines.insert(self.allocator, self.cursor_line + 1, new_line);
        self.cursor_line += 1;
        self.cursor_col = 0;
    }

    // -- Cursor movement --------------------------------------------------

    pub fn moveLeft(self: *Editor) void {
        self.last_action = .none;
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
        } else if (self.cursor_line > 0) {
            self.cursor_line -= 1;
            self.cursor_col = self.currentLine().items.len;
        }
    }

    pub fn moveRight(self: *Editor) void {
        self.last_action = .none;
        const line_len = self.currentLine().items.len;
        if (self.cursor_col < line_len) {
            self.cursor_col += 1;
        } else if (self.cursor_line < self.lines.items.len - 1) {
            self.cursor_line += 1;
            self.cursor_col = 0;
        }
    }

    pub fn moveUp(self: *Editor) void {
        self.last_action = .none;
        if (self.cursor_line > 0) {
            self.cursor_line -= 1;
            self.clampCursorCol();
        }
    }

    pub fn moveDown(self: *Editor) void {
        self.last_action = .none;
        if (self.cursor_line < self.lines.items.len - 1) {
            self.cursor_line += 1;
            self.clampCursorCol();
        }
    }

    pub fn moveLineStart(self: *Editor) void {
        self.last_action = .none;
        self.cursor_col = 0;
    }

    pub fn moveLineEnd(self: *Editor) void {
        self.last_action = .none;
        self.cursor_col = self.currentLine().items.len;
    }

    /// Move cursor backward by one word. Mirrors upstream `moveWordBackwards`:
    /// skip trailing whitespace, then a punctuation run OR a word run.
    pub fn moveWordLeft(self: *Editor) void {
        self.last_action = .none;
        if (self.cursor_col == 0) {
            if (self.cursor_line > 0) {
                self.cursor_line -= 1;
                self.cursor_col = self.currentLine().items.len;
            }
            return;
        }
        const text = self.currentLine().items;
        var col = self.cursor_col;
        while (col > 0 and isWhitespace(text[col - 1])) col -= 1;
        if (col > 0) {
            if (isPunctuation(text[col - 1])) {
                while (col > 0 and isPunctuation(text[col - 1])) col -= 1;
            } else {
                while (col > 0 and !isWhitespace(text[col - 1]) and !isPunctuation(text[col - 1])) col -= 1;
            }
        }
        self.cursor_col = col;
    }

    /// Move cursor forward by one word. Mirrors upstream `moveWordForwards`:
    /// skip a punctuation run OR a word run, then trailing whitespace.
    pub fn moveWordRight(self: *Editor) void {
        self.last_action = .none;
        const text = self.currentLine().items;
        if (self.cursor_col >= text.len) {
            if (self.cursor_line < self.lines.items.len - 1) {
                self.cursor_line += 1;
                self.cursor_col = 0;
            }
            return;
        }
        var col = self.cursor_col;
        if (isPunctuation(text[col])) {
            while (col < text.len and isPunctuation(text[col])) col += 1;
        } else if (!isWhitespace(text[col])) {
            while (col < text.len and !isWhitespace(text[col]) and !isPunctuation(text[col])) col += 1;
        }
        while (col < text.len and isWhitespace(text[col])) col += 1;
        self.cursor_col = col;
    }

    // -- Deletion ---------------------------------------------------------

    pub fn deleteCharBackward(self: *Editor) !void {
        self.exitHistory();
        self.last_action = .none;
        if (self.cursor_col > 0) {
            self.pushUndoSnapshot();
            _ = self.currentLine().orderedRemove(self.cursor_col - 1);
            self.cursor_col -= 1;
        } else if (self.cursor_line > 0) {
            self.pushUndoSnapshot();
            var prev = &self.lines.items[self.cursor_line - 1];
            const prev_len = prev.items.len;
            const cur = self.lines.orderedRemove(self.cursor_line);
            var cur_mut = cur;
            try prev.appendSlice(self.allocator, cur_mut.items);
            cur_mut.deinit(self.allocator);
            self.cursor_line -= 1;
            self.cursor_col = prev_len;
        }
    }

    pub fn deleteCharForward(self: *Editor) !void {
        self.exitHistory();
        self.last_action = .none;
        var line = self.currentLine();
        if (self.cursor_col < line.items.len) {
            self.pushUndoSnapshot();
            _ = line.orderedRemove(self.cursor_col);
        } else if (self.cursor_line < self.lines.items.len - 1) {
            self.pushUndoSnapshot();
            const next = self.lines.orderedRemove(self.cursor_line + 1);
            var next_mut = next;
            try self.currentLine().appendSlice(self.allocator, next_mut.items);
            next_mut.deinit(self.allocator);
        }
    }

    pub fn deleteWordBackward(self: *Editor) !void {
        self.exitHistory();
        const was_kill = self.last_action == .kill;
        if (self.cursor_col == 0) {
            if (self.cursor_line > 0) {
                self.pushUndoSnapshot();
                try self.kill_ring.push(self.allocator, "\n", true, was_kill);
                self.last_action = .kill;
                var prev = &self.lines.items[self.cursor_line - 1];
                const prev_len = prev.items.len;
                const cur = self.lines.orderedRemove(self.cursor_line);
                var cur_mut = cur;
                try prev.appendSlice(self.allocator, cur_mut.items);
                cur_mut.deinit(self.allocator);
                self.cursor_line -= 1;
                self.cursor_col = prev_len;
            }
            return;
        }
        self.pushUndoSnapshot();
        const old_col = self.cursor_col;
        self.moveWordLeft();
        const delete_from = self.cursor_col;
        var line = self.currentLine();
        const deleted = line.items[delete_from..old_col];
        try self.kill_ring.push(self.allocator, deleted, true, was_kill);
        self.last_action = .kill;
        line.replaceRange(self.allocator, delete_from, old_col - delete_from, &.{}) catch {};
        self.cursor_col = delete_from;
    }

    pub fn deleteWordForward(self: *Editor) !void {
        self.exitHistory();
        const was_kill = self.last_action == .kill;
        var line = self.currentLine();
        if (self.cursor_col >= line.items.len) {
            if (self.cursor_line < self.lines.items.len - 1) {
                self.pushUndoSnapshot();
                try self.kill_ring.push(self.allocator, "\n", false, was_kill);
                self.last_action = .kill;
                const next = self.lines.orderedRemove(self.cursor_line + 1);
                var next_mut = next;
                try self.currentLine().appendSlice(self.allocator, next_mut.items);
                next_mut.deinit(self.allocator);
            }
            return;
        }
        self.pushUndoSnapshot();
        const old_col = self.cursor_col;
        self.moveWordRight();
        const delete_to = self.cursor_col;
        self.cursor_col = old_col;
        line = self.currentLine();
        const deleted = line.items[old_col..delete_to];
        try self.kill_ring.push(self.allocator, deleted, false, was_kill);
        self.last_action = .kill;
        line.replaceRange(self.allocator, old_col, delete_to - old_col, &.{}) catch {};
    }

    pub fn deleteToLineStart(self: *Editor) !void {
        self.exitHistory();
        if (self.cursor_col == 0) return;
        self.pushUndoSnapshot();
        const was_kill = self.last_action == .kill;
        var line = self.currentLine();
        const deleted = line.items[0..self.cursor_col];
        try self.kill_ring.push(self.allocator, deleted, true, was_kill);
        self.last_action = .kill;
        line.replaceRange(self.allocator, 0, self.cursor_col, &.{}) catch {};
        self.cursor_col = 0;
    }

    pub fn deleteToLineEnd(self: *Editor) !void {
        self.exitHistory();
        var line = self.currentLine();
        if (self.cursor_col >= line.items.len) return;
        self.pushUndoSnapshot();
        const was_kill = self.last_action == .kill;
        const deleted = line.items[self.cursor_col..];
        try self.kill_ring.push(self.allocator, deleted, false, was_kill);
        self.last_action = .kill;
        line.shrinkRetainingCapacity(self.cursor_col);
    }

    // -- Kill ring yank ---------------------------------------------------

    pub fn yank(self: *Editor) !void {
        const text = self.kill_ring.peek() orelse return;
        self.pushUndoSnapshot();
        // Insert possibly-multiline yanked text.
        try self.insertYanked(text);
        self.last_action = .yank;
    }

    fn insertYanked(self: *Editor, text: []const u8) !void {
        var it = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (it.next()) |part| {
            if (!first) try self.newLine();
            first = false;
            if (part.len > 0) {
                var line = self.currentLine();
                try line.insertSlice(self.allocator, self.cursor_col, part);
                self.cursor_col += part.len;
            }
        }
    }

    pub fn yankPop(self: *Editor) !void {
        if (self.last_action != .yank or self.kill_ring.len() <= 1) return;
        // Remove previously yanked text by undoing to the snapshot, then rotate.
        if (self.undo_text) |t| {
            const owned = try self.allocator.dupe(u8, t);
            defer self.allocator.free(owned);
            try self.setText(owned);
            self.cursor_line = @min(self.undo_line, self.lines.items.len - 1);
            self.cursor_col = self.undo_col;
            self.clampCursorCol();
        }
        try self.kill_ring.rotate(self.allocator);
        self.pushUndoSnapshot();
        const text = self.kill_ring.peek() orelse return;
        try self.insertYanked(text);
        self.last_action = .yank;
    }

    // -- History ----------------------------------------------------------

    /// Record a submitted prompt into history (deduping consecutive repeats).
    pub fn addHistory(self: *Editor, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, text)) {
                self.history_index = std.math.maxInt(usize);
                return;
            }
        }
        try self.history.append(self.allocator, try self.allocator.dupe(u8, text));
        self.history_index = std.math.maxInt(usize);
    }

    /// Browse to the previous (older) history entry. Returns true if it moved.
    pub fn historyPrev(self: *Editor) !bool {
        if (self.history.items.len == 0) return false;
        if (self.history_index == std.math.maxInt(usize)) {
            // Entering history: save current draft.
            if (self.saved_draft) |d| self.allocator.free(d);
            self.saved_draft = try self.getText();
            self.history_index = self.history.items.len;
        }
        if (self.history_index == 0) return false;
        self.history_index -= 1;
        const owned = try self.allocator.dupe(u8, self.history.items[self.history_index]);
        defer self.allocator.free(owned);
        try self.setText(owned);
        return true;
    }

    /// Browse to the next (newer) history entry, restoring the draft past the end.
    pub fn historyNext(self: *Editor) !bool {
        if (self.history_index == std.math.maxInt(usize)) return false;
        self.history_index += 1;
        if (self.history_index >= self.history.items.len) {
            self.history_index = std.math.maxInt(usize);
            const draft = self.saved_draft orelse "";
            const owned = try self.allocator.dupe(u8, draft);
            defer self.allocator.free(owned);
            try self.setText(owned);
            return true;
        }
        const owned = try self.allocator.dupe(u8, self.history.items[self.history_index]);
        defer self.allocator.free(owned);
        try self.setText(owned);
        return true;
    }

    pub fn clear(self: *Editor) !void {
        try self.setText("");
        self.cursor_line = 0;
        self.cursor_col = 0;
    }
};

// ===== Tests =====

fn editorWithText(allocator: std.mem.Allocator, text: []const u8) !Editor {
    var ed = try Editor.init(allocator);
    try ed.setText(text);
    return ed;
}

test "insert and getText round-trips" {
    var ed = try Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.insertText("hello");
    try ed.insertText(" world");
    const text = try ed.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);
    try std.testing.expect(ed.cursor_col == 11);
}

test "word-left/right honor punctuation and whitespace runs" {
    var ed = try editorWithText(std.testing.allocator, "foo.bar baz");
    defer ed.deinit();
    // cursor at end (col 11)
    ed.moveWordLeft(); // -> start of "baz" (col 8)
    try std.testing.expect(ed.cursor_col == 8);
    ed.moveWordLeft(); // skip whitespace then punctuation? "bar" is a word -> col 4
    try std.testing.expect(ed.cursor_col == 4);
    ed.moveWordLeft(); // "." punctuation run -> col 3
    try std.testing.expect(ed.cursor_col == 3);
    ed.moveWordLeft(); // "foo" word -> col 0
    try std.testing.expect(ed.cursor_col == 0);

    ed.moveWordRight(); // "foo" word, no trailing ws -> col 3
    try std.testing.expect(ed.cursor_col == 3);
    ed.moveWordRight(); // "." punctuation -> col 4
    try std.testing.expect(ed.cursor_col == 4);
}

test "deleteWordBackward kills a word and supports yank" {
    var ed = try editorWithText(std.testing.allocator, "hello world");
    defer ed.deinit();
    try ed.deleteWordBackward(); // removes "world"
    const t1 = try ed.getText();
    defer std.testing.allocator.free(t1);
    try std.testing.expectEqualStrings("hello ", t1);

    try ed.yank(); // pastes "world" back
    const t2 = try ed.getText();
    defer std.testing.allocator.free(t2);
    try std.testing.expectEqualStrings("hello world", t2);
}

test "consecutive kills accumulate in the kill ring" {
    var ed = try editorWithText(std.testing.allocator, "alpha beta gamma");
    defer ed.deinit();
    try ed.deleteWordBackward(); // kill "gamma"
    try ed.deleteWordBackward(); // kill "beta " (accumulates, prepended)
    try std.testing.expect(ed.kill_ring.len() == 1);
    try std.testing.expectEqualStrings("beta gamma", ed.kill_ring.peek().?);
}

test "deleteToLineStart and deleteToLineEnd" {
    var ed = try editorWithText(std.testing.allocator, "keep|cut");
    defer ed.deinit();
    ed.cursor_col = 4; // after "keep"
    try ed.deleteToLineEnd();
    const t1 = try ed.getText();
    defer std.testing.allocator.free(t1);
    try std.testing.expectEqualStrings("keep", t1);

    try ed.deleteToLineStart();
    const t2 = try ed.getText();
    defer std.testing.allocator.free(t2);
    try std.testing.expectEqualStrings("", t2);
}

test "undo restores previous snapshot" {
    var ed = try editorWithText(std.testing.allocator, "hello world");
    defer ed.deinit();
    try ed.deleteWordBackward();
    try ed.undo();
    const t = try ed.getText();
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("hello world", t);
}

test "newLine splits the line and multi-line text serializes" {
    var ed = try editorWithText(std.testing.allocator, "abcd");
    defer ed.deinit();
    ed.cursor_col = 2;
    try ed.newLine();
    const t = try ed.getText();
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("ab\ncd", t);
    try std.testing.expect(ed.lines.items.len == 2);
}

test "history prev/next browses entries and restores draft" {
    var ed = try Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.addHistory("first");
    try ed.addHistory("second");
    try ed.insertText("draft");

    try std.testing.expect(try ed.historyPrev()); // -> "second"
    const t1 = try ed.getText();
    defer std.testing.allocator.free(t1);
    try std.testing.expectEqualStrings("second", t1);

    try std.testing.expect(try ed.historyPrev()); // -> "first"
    const t2 = try ed.getText();
    defer std.testing.allocator.free(t2);
    try std.testing.expectEqualStrings("first", t2);

    try std.testing.expect(try ed.historyNext()); // -> "second"
    try std.testing.expect(try ed.historyNext()); // -> draft restored
    const t3 = try ed.getText();
    defer std.testing.allocator.free(t3);
    try std.testing.expectEqualStrings("draft", t3);
}

test "isEmpty reflects buffer state" {
    var ed = try Editor.init(std.testing.allocator);
    defer ed.deinit();
    try std.testing.expect(ed.isEmpty());
    try ed.insertText("x");
    try std.testing.expect(!ed.isEmpty());
    try ed.clear();
    try std.testing.expect(ed.isEmpty());
}

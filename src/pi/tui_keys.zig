//! Terminal key decoding and keybinding matching for the TUI.
//!
//! Ports the legacy (non-Kitty) branch of upstream `packages/tui/src/keys.ts`
//! `parseKey()` into a Zig `decode()` that maps raw terminal bytes to a
//! canonical key id (e.g. `"ctrl+a"`, `"alt+left"`, `"up"`, `"a"`), plus the
//! default keybinding table from `packages/tui/src/keybindings.ts`
//! (`TUI_KEYBINDINGS`) and the application keybindings documented in
//! `docs/keybindings.md`.
//!
//! The Kitty keyboard protocol and `modifyOtherKeys` CSI-u decoding are not
//! ported; the legacy sequences cover every key needed by the interactive
//! core commands.

const std = @import("std");

/// A decoded key. Use `id()` for the canonical key id (null for an unrecognized
/// escape sequence) and `printable` for plain text input (no modifiers).
///
/// Synthesized ids (ctrl/alt/ctrl+alt + letter) are stored in `id_buf`; `id()`
/// re-bases the slice onto the returned value's own buffer so the pointer stays
/// valid after the struct is copied out of `decode`.
pub const Decoded = struct {
    /// For static ids this points at a constant; for synthesized ids it is null
    /// and `id_len > 0` selects `id_buf`.
    static_id: ?[]const u8 = null,
    id_buf: [16]u8 = undefined,
    id_len: usize = 0,
    printable: []const u8 = "",

    /// Canonical key id, or null when the bytes were not recognized.
    pub fn id(self: *const Decoded) ?[]const u8 {
        if (self.static_id) |s| return s;
        if (self.id_len > 0) return self.id_buf[0..self.id_len];
        return null;
    }
};

fn setSynth(result: *Decoded, comptime fmt: []const u8, letter: u8) void {
    const slice = std.fmt.bufPrint(&result.id_buf, fmt, .{letter}) catch return;
    result.id_len = slice.len;
}

/// Decode raw terminal input bytes (one key's worth) into a canonical key id.
/// Mirrors the legacy, non-Kitty branch of upstream `parseKey()`.
pub fn decode(data: []const u8) Decoded {
    var result: Decoded = .{};

    if (data.len == 0) return result;

    // Multi-byte control sequences (exact matches).
    const exact = std.StaticStringMap([]const u8).initComptime(.{
        .{ "\x1b", "escape" },
        .{ "\x1c", "ctrl+\\" },
        .{ "\x1d", "ctrl+]" },
        .{ "\x1f", "ctrl+-" },
        .{ "\x1b\x1b", "ctrl+alt+[" },
        .{ "\x1b\x1c", "ctrl+alt+\\" },
        .{ "\x1b\x1d", "ctrl+alt+]" },
        .{ "\x1b\x1f", "ctrl+alt+-" },
        .{ "\t", "tab" },
        .{ "\r", "enter" },
        .{ "\n", "enter" },
        .{ "\x1bOM", "enter" },
        .{ "\x00", "ctrl+space" },
        .{ " ", "space" },
        .{ "\x7f", "backspace" },
        .{ "\x08", "backspace" },
        .{ "\x1b[Z", "shift+tab" },
        .{ "\x1b\r", "alt+enter" },
        .{ "\x1b ", "alt+space" },
        .{ "\x1b\x7f", "alt+backspace" },
        .{ "\x1b\x08", "alt+backspace" },
        .{ "\x1bB", "alt+left" },
        .{ "\x1bF", "alt+right" },
        .{ "\x1b[A", "up" },
        .{ "\x1b[B", "down" },
        .{ "\x1b[C", "right" },
        .{ "\x1b[D", "left" },
        .{ "\x1b[H", "home" },
        .{ "\x1bOH", "home" },
        .{ "\x1b[F", "end" },
        .{ "\x1bOF", "end" },
        .{ "\x1b[1~", "home" },
        .{ "\x1b[4~", "end" },
        .{ "\x1b[2~", "insert" },
        .{ "\x1b[3~", "delete" },
        .{ "\x1b[5~", "pageUp" },
        .{ "\x1b[6~", "pageDown" },
        // Common modified arrows (xterm CSI 1;<mod> <dir>).
        .{ "\x1b[1;5D", "ctrl+left" },
        .{ "\x1b[1;5C", "ctrl+right" },
        .{ "\x1b[1;5A", "ctrl+up" },
        .{ "\x1b[1;5B", "ctrl+down" },
        .{ "\x1b[1;3D", "alt+left" },
        .{ "\x1b[1;3C", "alt+right" },
        .{ "\x1b[1;3A", "alt+up" },
        .{ "\x1b[1;3B", "alt+down" },
        .{ "\x1b[1;2A", "shift+up" },
        .{ "\x1b[1;2B", "shift+down" },
    });
    if (exact.get(data)) |found| {
        result.static_id = found;
        return result;
    }

    // ESC + single byte: ctrl+alt+letter or alt+letter/digit.
    if (data.len == 2 and data[0] == 0x1b) {
        const code = data[1];
        if (code >= 1 and code <= 26) {
            setSynth(&result, "ctrl+alt+{c}", code + 96);
            return result;
        }
        if ((code >= 'a' and code <= 'z') or (code >= '0' and code <= '9')) {
            setSynth(&result, "alt+{c}", code);
            return result;
        }
    }

    // Single byte: ctrl+letter, or a plain printable character.
    if (data.len == 1) {
        const code = data[0];
        if (code >= 1 and code <= 26) {
            setSynth(&result, "ctrl+{c}", code + 96);
            return result;
        }
        if (code >= 32 and code <= 126) {
            result.static_id = data; // a printable id equals its own character
            result.printable = data;
            return result;
        }
    }

    // Multi-byte UTF-8 printable (no recognized escape). Treat as text input.
    if (data[0] >= 0x20 and data[0] != 0x7f and !std.mem.startsWith(u8, data, "\x1b")) {
        result.printable = data;
        return result;
    }

    return result;
}

/// Returns true when `data` decodes to the given canonical `key_id`.
pub fn matchesKey(data: []const u8, key_id: []const u8) bool {
    const decoded = decode(data);
    const id = decoded.id() orelse return false;
    return std.mem.eql(u8, id, key_id);
}

/// Split a raw input buffer into individual key sequences. Ports the splitting
/// rule of upstream `packages/tui/src/stdin-buffer.ts` `extractCompleteSequences`:
/// an ESC begins a multi-byte escape sequence (consumed up to its final byte);
/// any other byte is a single key. This lets a buffer like `"/quit\r"` (one
/// read while typing fast / pasting) be processed key-by-key so control bytes
/// like Enter are handled separately from printable runs.
///
/// Returns slices into `data` (no allocation). UTF-8 multi-byte printables are
/// emitted as one sequence each.
pub const SequenceIterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(self: *SequenceIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const rest = self.data[self.pos..];

        if (rest[0] == 0x1b) {
            const len = escapeSequenceLen(rest);
            const seq = rest[0..len];
            self.pos += len;
            return seq;
        }

        // UTF-8 lead byte: emit the whole multi-byte code point as one key.
        const cp_len = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
        const take = @min(cp_len, rest.len);
        const seq = rest[0..take];
        self.pos += take;
        return seq;
    }
};

/// Length of the escape sequence beginning at `data[0] == ESC`. Recognizes
/// CSI (`ESC[ ... final`), SS3 (`ESC O x`), and meta (`ESC x`) forms; falls
/// back to the whole remaining buffer if incomplete.
fn escapeSequenceLen(data: []const u8) usize {
    if (data.len <= 1) return data.len;
    switch (data[1]) {
        '[' => {
            // CSI: consume until a final byte in 0x40..0x7e.
            var i: usize = 2;
            while (i < data.len) : (i += 1) {
                const c = data[i];
                if (c >= 0x40 and c <= 0x7e) return i + 1;
            }
            return data.len;
        },
        'O' => return @min(3, data.len), // SS3 + one char
        0x1b => return 2, // ESC ESC (meta)
        else => return 2, // ESC + single char (alt+key)
    }
}

/// Convenience: build a `SequenceIterator` over `data`.
pub fn sequences(data: []const u8) SequenceIterator {
    return .{ .data = data };
}

pub const Binding = struct {
    id: []const u8,
    keys: []const []const u8,
    description: []const u8,
};

/// Default keybindings. Combines `TUI_KEYBINDINGS` (editor/input/select) with
/// the application bindings from `docs/keybindings.md` that the interactive
/// loop dispatches on.
pub const default_bindings = [_]Binding{
    // TUI editor cursor movement
    .{ .id = "tui.editor.cursorUp", .keys = &.{"up"}, .description = "Move cursor up" },
    .{ .id = "tui.editor.cursorDown", .keys = &.{"down"}, .description = "Move cursor down" },
    .{ .id = "tui.editor.cursorLeft", .keys = &.{ "left", "ctrl+b" }, .description = "Move cursor left" },
    .{ .id = "tui.editor.cursorRight", .keys = &.{ "right", "ctrl+f" }, .description = "Move cursor right" },
    .{ .id = "tui.editor.cursorWordLeft", .keys = &.{ "alt+left", "ctrl+left", "alt+b" }, .description = "Move cursor word left" },
    .{ .id = "tui.editor.cursorWordRight", .keys = &.{ "alt+right", "ctrl+right", "alt+f" }, .description = "Move cursor word right" },
    .{ .id = "tui.editor.cursorLineStart", .keys = &.{ "home", "ctrl+a" }, .description = "Move to line start" },
    .{ .id = "tui.editor.cursorLineEnd", .keys = &.{ "end", "ctrl+e" }, .description = "Move to line end" },
    .{ .id = "tui.editor.pageUp", .keys = &.{"pageUp"}, .description = "Page up" },
    .{ .id = "tui.editor.pageDown", .keys = &.{"pageDown"}, .description = "Page down" },
    // TUI editor deletion
    .{ .id = "tui.editor.deleteCharBackward", .keys = &.{"backspace"}, .description = "Delete character backward" },
    .{ .id = "tui.editor.deleteCharForward", .keys = &.{ "delete", "ctrl+d" }, .description = "Delete character forward" },
    .{ .id = "tui.editor.deleteWordBackward", .keys = &.{ "ctrl+w", "alt+backspace" }, .description = "Delete word backward" },
    .{ .id = "tui.editor.deleteWordForward", .keys = &.{ "alt+d", "alt+delete" }, .description = "Delete word forward" },
    .{ .id = "tui.editor.deleteToLineStart", .keys = &.{"ctrl+u"}, .description = "Delete to line start" },
    .{ .id = "tui.editor.deleteToLineEnd", .keys = &.{"ctrl+k"}, .description = "Delete to line end" },
    // TUI kill ring
    .{ .id = "tui.editor.yank", .keys = &.{"ctrl+y"}, .description = "Yank" },
    .{ .id = "tui.editor.yankPop", .keys = &.{"alt+y"}, .description = "Yank pop" },
    .{ .id = "tui.editor.undo", .keys = &.{"ctrl+-"}, .description = "Undo last edit" },
    // TUI input
    .{ .id = "tui.input.newLine", .keys = &.{"shift+enter"}, .description = "Insert new line" },
    .{ .id = "tui.input.submit", .keys = &.{"enter"}, .description = "Submit input" },
    .{ .id = "tui.input.tab", .keys = &.{"tab"}, .description = "Tab / autocomplete" },
    .{ .id = "tui.input.copy", .keys = &.{"ctrl+c"}, .description = "Copy selection" },
    // TUI select
    .{ .id = "tui.select.up", .keys = &.{"up"}, .description = "Move selection up" },
    .{ .id = "tui.select.down", .keys = &.{"down"}, .description = "Move selection down" },
    .{ .id = "tui.select.confirm", .keys = &.{"enter"}, .description = "Confirm selection" },
    .{ .id = "tui.select.cancel", .keys = &.{ "escape", "ctrl+c" }, .description = "Cancel selection" },
    // Application
    .{ .id = "app.interrupt", .keys = &.{"escape"}, .description = "Cancel / abort" },
    .{ .id = "app.clear", .keys = &.{"ctrl+c"}, .description = "Clear editor" },
    .{ .id = "app.exit", .keys = &.{"ctrl+d"}, .description = "Exit (when editor empty)" },
    .{ .id = "app.editor.external", .keys = &.{"ctrl+g"}, .description = "Open in external editor" },
    .{ .id = "app.model.select", .keys = &.{"ctrl+l"}, .description = "Open model selector" },
    .{ .id = "app.model.cycleForward", .keys = &.{"ctrl+p"}, .description = "Cycle to next model" },
    .{ .id = "app.model.cycleBackward", .keys = &.{"shift+ctrl+p"}, .description = "Cycle to previous model" },
    .{ .id = "app.thinking.cycle", .keys = &.{"shift+tab"}, .description = "Cycle thinking level" },
    .{ .id = "app.thinking.toggle", .keys = &.{"ctrl+t"}, .description = "Collapse/expand thinking" },
    .{ .id = "app.tools.expand", .keys = &.{"ctrl+o"}, .description = "Collapse/expand tool output" },
    .{ .id = "app.message.followUp", .keys = &.{"alt+enter"}, .description = "Queue follow-up message" },
    .{ .id = "app.message.dequeue", .keys = &.{"alt+up"}, .description = "Restore queued messages to editor" },
};

/// Find the binding id whose default keys include the canonical id decoded from `data`.
/// Returns the matched keybinding id, or null.
pub fn lookupBinding(data: []const u8) ?[]const u8 {
    const decoded = decode(data);
    const id = decoded.id() orelse return null;
    for (default_bindings) |binding| {
        for (binding.keys) |k| {
            if (std.mem.eql(u8, k, id)) return binding.id;
        }
    }
    return null;
}

/// Returns whether the bytes decode to a key bound to the given keybinding id.
pub fn matches(data: []const u8, keybinding_id: []const u8) bool {
    const decoded = decode(data);
    const id = decoded.id() orelse return false;
    for (default_bindings) |binding| {
        if (!std.mem.eql(u8, binding.id, keybinding_id)) continue;
        for (binding.keys) |k| {
            if (std.mem.eql(u8, k, id)) return true;
        }
    }
    return false;
}

fn expectId(expected: []const u8, data: []const u8) !void {
    const d = decode(data);
    try std.testing.expectEqualStrings(expected, d.id().?);
}

test "decode maps control bytes to ctrl key ids" {
    try expectId("ctrl+a", "\x01");
    try expectId("ctrl+c", "\x03");
    try expectId("ctrl+d", "\x04");
    try expectId("ctrl+w", "\x17");
    try expectId("backspace", "\x7f");
    try expectId("escape", "\x1b");
    try expectId("enter", "\r");
    try expectId("tab", "\t");
}

test "decode maps escape sequences for arrows and navigation" {
    try expectId("up", "\x1b[A");
    try expectId("down", "\x1b[B");
    try expectId("right", "\x1b[C");
    try expectId("left", "\x1b[D");
    try expectId("delete", "\x1b[3~");
    try expectId("pageUp", "\x1b[5~");
    try expectId("shift+tab", "\x1b[Z");
    try expectId("ctrl+left", "\x1b[1;5D");
    try expectId("alt+enter", "\x1b\r");
}

test "decode maps alt+letter and ctrl+alt+letter" {
    try expectId("alt+b", "\x1bb");
    try expectId("alt+f", "\x1bf");
    try expectId("ctrl+alt+a", "\x1b\x01");
}

test "decode returns printable for plain characters" {
    const d = decode("x");
    try std.testing.expectEqualStrings("x", d.id().?);
    try std.testing.expectEqualStrings("x", d.printable);
    const ctrl = decode("\x01");
    try std.testing.expectEqualStrings("", ctrl.printable);
}

test "matches resolves keybinding ids against default table" {
    try std.testing.expect(matches("\x01", "tui.editor.cursorLineStart")); // ctrl+a
    try std.testing.expect(matches("\x7f", "tui.editor.deleteCharBackward")); // backspace
    try std.testing.expect(matches("\x17", "tui.editor.deleteWordBackward")); // ctrl+w
    try std.testing.expect(matches("\x1b", "app.interrupt")); // escape
    try std.testing.expect(matches("\x03", "app.clear")); // ctrl+c
    try std.testing.expect(matches("\x04", "app.exit")); // ctrl+d
    try std.testing.expect(matches("\r", "tui.input.submit")); // enter
    try std.testing.expect(!matches("x", "app.interrupt"));
}

test "lookupBinding returns the first matching application binding" {
    try std.testing.expectEqualStrings("app.model.select", lookupBinding("\x0c").?); // ctrl+l
    try std.testing.expectEqualStrings("app.tools.expand", lookupBinding("\x0f").?); // ctrl+o
    try std.testing.expect(lookupBinding("z") == null or std.mem.eql(u8, lookupBinding("z").?, "z") == false);
}

test "sequences splits a printable run with a trailing control byte" {
    var it = sequences("/quit\r");
    try std.testing.expectEqualStrings("/", it.next().?);
    try std.testing.expectEqualStrings("q", it.next().?);
    try std.testing.expectEqualStrings("u", it.next().?);
    try std.testing.expectEqualStrings("i", it.next().?);
    try std.testing.expectEqualStrings("t", it.next().?);
    try std.testing.expectEqualStrings("\r", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "sequences keeps escape sequences intact" {
    var it = sequences("\x1b[Dx\x1b[3~");
    try std.testing.expectEqualStrings("\x1b[D", it.next().?); // left arrow
    try std.testing.expectEqualStrings("x", it.next().?);
    try std.testing.expectEqualStrings("\x1b[3~", it.next().?); // delete
    try std.testing.expect(it.next() == null);
}

test "sequences treats alt+key as a two-byte sequence" {
    var it = sequences("\x1bbhi");
    try std.testing.expectEqualStrings("\x1bb", it.next().?); // alt+b
    try std.testing.expectEqualStrings("h", it.next().?);
    try std.testing.expectEqualStrings("i", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "sequences emits a multi-byte UTF-8 code point as one key" {
    // "é" is 0xC3 0xA9 (2 bytes).
    var it = sequences("a\xc3\xa9b");
    try std.testing.expectEqualStrings("a", it.next().?);
    try std.testing.expectEqualStrings("\xc3\xa9", it.next().?);
    try std.testing.expectEqualStrings("b", it.next().?);
    try std.testing.expect(it.next() == null);
}

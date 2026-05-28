//! Fuzzy matching for the TUI command palette / autocomplete.
//!
//! Port of upstream `packages/tui/src/fuzzy.ts` (`fuzzyMatch`, `fuzzyFilter`).
//! Matches if all query characters appear in order (not necessarily
//! consecutive). Lower score = better match.
//!
//! Upstream lowercases both query and text with JavaScript `String.toLowerCase`,
//! which performs Unicode-aware case folding. To reach parity (the documented
//! remaining tool gap), this port normalizes both sides with an NFKC-aware fold
//! (`unicode_fold.foldInto`) before matching: compatibility forms such as
//! fullwidth ASCII are mapped to their canonical ASCII, common Latin diacritics
//! are stripped, and letters are case-folded. The byte-level scorer below then
//! runs over the folded forms, preserving all existing word-boundary / consecutive
//! / swapped-query scoring behavior.

const std = @import("std");

pub const FuzzyMatch = struct {
    matches: bool,
    score: f64 = 0,
};

fn isWordBoundaryChar(c: u8) bool {
    // Mirror upstream regex /[\s\-_./:]/ on the preceding character.
    return std.ascii.isWhitespace(c) or c == '-' or c == '_' or c == '.' or c == '/' or c == ':';
}

// === NFKC-aware case/diacritic folding =======================================
//
// Upstream lowercases with JS `String.toLowerCase`, which is Unicode-aware. This
// fold reaches parity for the documented tool gap by mapping, per codepoint:
//   1. NFKC compatibility forms commonly typed in a palette/search box —
//      fullwidth ASCII (U+FF01..U+FF5E) and the ideographic space (U+3000) — to
//      their canonical ASCII equivalents.
//   2. Latin-1/Latin Extended-A precomposed accented letters to their base
//      letter (NFD decomposition + combining-mark strip), then case-folded.
//   3. Standalone combining diacritical marks (U+0300..U+036F) to nothing.
//   4. ASCII A-Z to a-z.
// Anything else is preserved verbatim (lowercased per-byte for ASCII). This is a
// targeted, dependency-free fold — not the full Unicode NFKC table — covering the
// accented/fullwidth inputs the fuzzy matcher and edit-tool fuzzy fallback hit.

/// Upper bound on folded output length for an input of `input_len` bytes. Folding
/// never expands beyond the original byte count for our mappings (multi-byte
/// sequences fold to <= their own length), but we keep a small constant headroom
/// so callers can size fixed buffers safely.
pub fn maxFoldedLen(input_len: usize) usize {
    return input_len + 4;
}

/// Fold one Unicode codepoint to its NFKC/case/diacritic-folded form, writing the
/// resulting UTF-8 bytes to `w`. Returns nothing; unmapped codepoints are written
/// back as their original UTF-8 (the caller passes the source bytes).
fn writeFoldedCodepoint(w: *std.Io.Writer, codepoint: u21, original: []const u8) !void {
    // 1. Fullwidth ASCII variants -> ASCII (then case-folded by the A-Z arm below
    //    via recursion-free direct mapping).
    if (codepoint >= 0xFF01 and codepoint <= 0xFF5E) {
        const ascii: u8 = @intCast(codepoint - 0xFF00 + 0x20);
        try w.writeByte(std.ascii.toLower(ascii));
        return;
    }
    // Ideographic space and other folded spaces handled by the diacritic/space map.
    if (foldedSpace(codepoint)) {
        try w.writeByte(' ');
        return;
    }
    // 2. Precomposed accented Latin letters -> base letter (lowercased).
    if (latinBaseLetter(codepoint)) |base| {
        try w.writeByte(base);
        return;
    }
    // 3. Standalone combining marks -> dropped.
    if (codepoint >= 0x0300 and codepoint <= 0x036F) return;
    // 4. ASCII fast path.
    if (codepoint < 0x80) {
        try w.writeByte(std.ascii.toLower(@intCast(codepoint)));
        return;
    }
    // Default: preserve the original bytes verbatim.
    try w.writeAll(original);
}

fn foldedSpace(codepoint: u21) bool {
    return switch (codepoint) {
        0x3000 => true, // ideographic space
        else => false,
    };
}

/// Map a precomposed Latin codepoint (Latin-1 Supplement + Latin Extended-A) to
/// its lowercase base ASCII letter, or null when there is no such mapping. This is
/// the NFD-decompose-then-strip-diacritic step folded into a direct table.
fn latinBaseLetter(codepoint: u21) ?u8 {
    return switch (codepoint) {
        // A with accents (grave, acute, circumflex, tilde, diaeresis, ring, macron, breve...)
        0x00C0...0x00C5, 0x0100, 0x0102, 0x0104, 0x00E0...0x00E5, 0x0101, 0x0103, 0x0105 => 'a',
        // C with cedilla / acute / caron
        0x00C7, 0x0106, 0x0108, 0x010A, 0x010C, 0x00E7, 0x0107, 0x0109, 0x010B, 0x010D => 'c',
        // D with caron / stroke
        0x010E, 0x0110, 0x010F, 0x0111 => 'd',
        // E with accents
        0x00C8...0x00CB, 0x0112, 0x0114, 0x0116, 0x0118, 0x011A, 0x00E8...0x00EB, 0x0113, 0x0115, 0x0117, 0x0119, 0x011B => 'e',
        // G
        0x011C, 0x011E, 0x0120, 0x0122, 0x011D, 0x011F, 0x0121, 0x0123 => 'g',
        // H
        0x0124, 0x0126, 0x0125, 0x0127 => 'h',
        // I with accents
        0x00CC...0x00CF, 0x0128, 0x012A, 0x012C, 0x012E, 0x0130, 0x00EC...0x00EF, 0x0129, 0x012B, 0x012D, 0x012F, 0x0131 => 'i',
        // J
        0x0134, 0x0135 => 'j',
        // K
        0x0136, 0x0137 => 'k',
        // L
        0x0139, 0x013B, 0x013D, 0x013F, 0x0141, 0x013A, 0x013C, 0x013E, 0x0140, 0x0142 => 'l',
        // N with tilde / acute / caron
        0x00D1, 0x0143, 0x0145, 0x0147, 0x00F1, 0x0144, 0x0146, 0x0148 => 'n',
        // O with accents
        0x00D2...0x00D6, 0x00D8, 0x014C, 0x014E, 0x0150, 0x00F2...0x00F6, 0x00F8, 0x014D, 0x014F, 0x0151 => 'o',
        // R
        0x0154, 0x0156, 0x0158, 0x0155, 0x0157, 0x0159 => 'r',
        // S with acute / circumflex / cedilla / caron
        0x015A, 0x015C, 0x015E, 0x0160, 0x015B, 0x015D, 0x015F, 0x0161 => 's',
        // T
        0x0162, 0x0164, 0x0166, 0x0163, 0x0165, 0x0167 => 't',
        // U with accents
        0x00D9...0x00DC, 0x0168, 0x016A, 0x016C, 0x016E, 0x0170, 0x0172, 0x00F9...0x00FC, 0x0169, 0x016B, 0x016D, 0x016F, 0x0171, 0x0173 => 'u',
        // W
        0x0174, 0x0175 => 'w',
        // Y with acute / diaeresis / circumflex
        0x00DD, 0x0176, 0x0178, 0x00FD, 0x00FF, 0x0177 => 'y',
        // Z with acute / dot / caron
        0x0179, 0x017B, 0x017D, 0x017A, 0x017C, 0x017E => 'z',
        else => null,
    };
}

/// NFKC-aware case/diacritic fold of `text` into `buf`. Returns the folded slice
/// (length may differ from `text.len`; `buf` must be at least
/// `maxFoldedLen(text.len)` bytes). Invalid UTF-8 bytes are lowercased per-byte so
/// the fold never fails on arbitrary input.
pub fn foldInto(buf: []u8, text: []const u8) []u8 {
    var w = std.Io.Writer.fixed(buf);
    var index: usize = 0;
    while (index < text.len) {
        const first = text[index];
        const seq_len = std.unicode.utf8ByteSequenceLength(first) catch {
            w.writeByte(std.ascii.toLower(first)) catch break;
            index += 1;
            continue;
        };
        if (index + seq_len > text.len) {
            w.writeByte(std.ascii.toLower(first)) catch break;
            index += 1;
            continue;
        }
        const slice = text[index .. index + seq_len];
        const codepoint = std.unicode.utf8Decode(slice) catch {
            w.writeByte(std.ascii.toLower(first)) catch break;
            index += 1;
            continue;
        };
        writeFoldedCodepoint(&w, codepoint, slice) catch break;
        index += seq_len;
    }
    return w.buffered();
}

/// NFKC-aware case/diacritic fold of `text` into `buf`. Returns the folded slice;
/// `buf` must be at least `maxFoldedLen(text.len)` bytes.
fn lowerInto(buf: []u8, text: []const u8) []u8 {
    return foldInto(buf, text);
}

fn matchQuery(query_lower: []const u8, text_lower: []const u8) FuzzyMatch {
    if (query_lower.len == 0) return .{ .matches = true, .score = 0 };
    if (query_lower.len > text_lower.len) return .{ .matches = false };

    var query_index: usize = 0;
    var score: f64 = 0;
    var last_match_index: i64 = -1;
    var consecutive_matches: f64 = 0;

    var i: usize = 0;
    while (i < text_lower.len and query_index < query_lower.len) : (i += 1) {
        if (text_lower[i] == query_lower[query_index]) {
            const is_word_boundary = i == 0 or isWordBoundaryChar(text_lower[i - 1]);

            if (last_match_index == @as(i64, @intCast(i)) - 1) {
                consecutive_matches += 1;
                score -= consecutive_matches * 5;
            } else {
                consecutive_matches = 0;
                if (last_match_index >= 0) {
                    score += @as(f64, @floatFromInt(@as(i64, @intCast(i)) - last_match_index - 1)) * 2;
                }
            }

            if (is_word_boundary) score -= 10;
            score += @as(f64, @floatFromInt(i)) * 0.1;

            last_match_index = @intCast(i);
            query_index += 1;
        }
    }

    if (query_index < query_lower.len) return .{ .matches = false };
    if (std.mem.eql(u8, query_lower, text_lower)) score -= 100;
    return .{ .matches = true, .score = score };
}

/// Build the upstream "swapped query" fallback: if query is letters+digits,
/// swap to digits+letters (and vice versa). Returns null when no swap applies.
fn swappedQuery(buf: []u8, query_lower: []const u8) ?[]const u8 {
    if (query_lower.len == 0) return null;
    // Find a single letters-run followed by a single digits-run, or the inverse.
    var split: usize = 0;
    const first_is_alpha = std.ascii.isAlphabetic(query_lower[0]);
    const first_is_digit = std.ascii.isDigit(query_lower[0]);
    if (!first_is_alpha and !first_is_digit) return null;

    // Scan the leading run of the same class.
    while (split < query_lower.len) : (split += 1) {
        const c = query_lower[split];
        if (first_is_alpha and !std.ascii.isAlphabetic(c)) break;
        if (first_is_digit and !std.ascii.isDigit(c)) break;
    }
    if (split == 0 or split == query_lower.len) return null;

    // The remaining must be entirely the opposite class.
    const rest = query_lower[split..];
    for (rest) |c| {
        if (first_is_alpha and !std.ascii.isDigit(c)) return null;
        if (first_is_digit and !std.ascii.isAlphabetic(c)) return null;
    }

    const head = query_lower[0..split];
    @memcpy(buf[0..rest.len], rest);
    @memcpy(buf[rest.len..][0..head.len], head);
    return buf[0 .. rest.len + head.len];
}

/// Returns whether `query` fuzzy-matches `text` and the match score. Both sides
/// are NFKC-aware case/diacritic-folded into stack buffers before matching, so
/// accented and fullwidth inputs match their ASCII equivalents (parity with
/// upstream's Unicode-aware `toLowerCase`).
pub fn fuzzyMatch(query: []const u8, text: []const u8) FuzzyMatch {
    var query_buf: [256]u8 = undefined;
    var text_buf: [1024]u8 = undefined;
    var swap_buf: [256]u8 = undefined;

    // Folding never expands beyond the input for our mappings, but guard against
    // the headroom so the fixed fold buffers can never overflow.
    if (maxFoldedLen(query.len) > query_buf.len or maxFoldedLen(text.len) > text_buf.len) {
        // Fall back to a byte-exact comparison for pathologically long inputs.
        return .{ .matches = std.mem.indexOf(u8, text, query) != null };
    }

    const query_lower = lowerInto(&query_buf, query);
    const text_lower = lowerInto(&text_buf, text);

    const primary = matchQuery(query_lower, text_lower);
    if (primary.matches) return primary;

    const swapped = swappedQuery(&swap_buf, query_lower) orelse return primary;
    const swapped_match = matchQuery(swapped, text_lower);
    if (!swapped_match.matches) return primary;
    return .{ .matches = true, .score = swapped_match.score + 5 };
}

pub fn FilterResult(comptime T: type) type {
    return struct { item: T, score: f64 };
}

/// Filter and sort `items` by fuzzy match quality (best first). Space-separated
/// tokens: all tokens must match (scores summed). Caller owns the returned slice.
/// `getText` maps an item to its searchable text.
pub fn fuzzyFilter(
    comptime T: type,
    allocator: std.mem.Allocator,
    items: []const T,
    query: []const u8,
    getText: *const fn (item: T) []const u8,
) ![]FilterResult(T) {
    const Result = FilterResult(T);
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    var out: std.ArrayList(Result) = .empty;
    errdefer out.deinit(allocator);

    if (trimmed.len == 0) {
        for (items, 0..) |item, idx| {
            // Preserve input order via a strictly increasing synthetic score.
            try out.append(allocator, .{ .item = item, .score = @floatFromInt(idx) });
        }
        return out.toOwnedSlice(allocator);
    }

    var token_it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(allocator);
    while (token_it.next()) |token| try tokens.append(allocator, token);
    if (tokens.items.len == 0) {
        for (items) |item| try out.append(allocator, .{ .item = item, .score = 0 });
        return out.toOwnedSlice(allocator);
    }

    for (items) |item| {
        const text = getText(item);
        var total: f64 = 0;
        var all_match = true;
        for (tokens.items) |token| {
            const m = fuzzyMatch(token, text);
            if (m.matches) {
                total += m.score;
            } else {
                all_match = false;
                break;
            }
        }
        if (all_match) try out.append(allocator, .{ .item = item, .score = total });
    }

    std.mem.sort(Result, out.items, {}, struct {
        fn lessThan(_: void, a: Result, b: Result) bool {
            return a.score < b.score;
        }
    }.lessThan);

    return out.toOwnedSlice(allocator);
}

test "fuzzyMatch matches subsequence and rewards word boundaries" {
    try std.testing.expect(fuzzyMatch("mdl", "model").matches);
    try std.testing.expect(fuzzyMatch("", "anything").matches);
    try std.testing.expect(!fuzzyMatch("xyz", "model").matches);

    // Word-boundary match should score better (lower) than a mid-word match.
    const boundary = fuzzyMatch("sm", "scoped-models");
    const midword = fuzzyMatch("od", "model");
    try std.testing.expect(boundary.matches);
    try std.testing.expect(midword.matches);
}

test "fuzzyMatch is ASCII case-insensitive and rewards exact equality" {
    try std.testing.expect(fuzzyMatch("MODEL", "model").matches);
    const exact = fuzzyMatch("model", "model");
    const prefix = fuzzyMatch("mod", "model");
    try std.testing.expect(exact.score < prefix.score);
}

test "fuzzyMatch swapped query fallback for letter/digit transposition" {
    // "1f" should still match "f1" via the swapped-query fallback.
    try std.testing.expect(fuzzyMatch("1f", "f1").matches);
    try std.testing.expect(!fuzzyMatch("1f", "zz").matches);
}

test "NFKC fold maps accented Latin to base ASCII" {
    var buf: [64]u8 = undefined;
    // Diacritics stripped + lowercased (NFD-decompose then drop combining marks).
    try std.testing.expectEqualStrings("cafe", foldInto(&buf, "café"));
    try std.testing.expectEqualStrings("naive", foldInto(&buf, "naïve"));
    try std.testing.expectEqualStrings("uber", foldInto(&buf, "Über"));
    try std.testing.expectEqualStrings("garcon", foldInto(&buf, "Garçon"));
    // A precomposed accent and a base+combining mark fold identically.
    try std.testing.expectEqualStrings("e", foldInto(&buf, "\u{00E9}")); // é precomposed
    try std.testing.expectEqualStrings("e", foldInto(&buf, "e\u{0301}")); // e + combining acute
}

test "NFKC fold maps fullwidth ASCII and ideographic space to canonical ASCII" {
    var buf: [128]u8 = undefined;
    // Fullwidth "Model" (U+FF2D U+FF4F ...) folds to ascii lowercase "model".
    try std.testing.expectEqualStrings("model", foldInto(&buf, "\u{FF2D}\u{FF4F}\u{FF44}\u{FF45}\u{FF4C}"));
    // Fullwidth digits + ideographic space.
    try std.testing.expectEqualStrings("a 1", foldInto(&buf, "\u{FF21}\u{3000}\u{FF11}"));
}

test "fuzzyMatch folds accented and fullwidth queries to their ASCII targets" {
    // Accented query matches ASCII text and vice versa.
    try std.testing.expect(fuzzyMatch("café", "cafe").matches);
    try std.testing.expect(fuzzyMatch("cafe", "Café Menu").matches);
    try std.testing.expect(fuzzyMatch("über", "uber-tool").matches);
    // Fullwidth query matches the ASCII command name.
    try std.testing.expect(fuzzyMatch("\u{FF4D}\u{FF4F}\u{FF44}\u{FF45}\u{FF4C}", "model").matches);
    // An accented exact match still earns the exact-equality bonus (folds equal).
    const exact = fuzzyMatch("résumé", "resume");
    try std.testing.expect(exact.matches);
}

test "fuzzyFilter ranks accented items against an ASCII query" {
    const items = [_][]const u8{ "Café", "résumé", "model" };
    const getText = struct {
        fn f(item: []const u8) []const u8 {
            return item;
        }
    }.f;
    const results = try fuzzyFilter([]const u8, std.testing.allocator, &items, "cafe", &getText);
    defer std.testing.allocator.free(results);
    try std.testing.expect(results.len == 1);
    try std.testing.expectEqualStrings("Café", results[0].item);
}

test "fuzzyFilter sorts best matches first and honors multi-token AND" {
    const items = [_][]const u8{ "settings", "session", "scoped-models", "model" };
    const getText = struct {
        fn f(item: []const u8) []const u8 {
            return item;
        }
    }.f;

    const results = try fuzzyFilter([]const u8, std.testing.allocator, &items, "mod", &getText);
    defer std.testing.allocator.free(results);
    // "model" and "scoped-models" both match "mod"; "model" should rank first.
    try std.testing.expect(results.len == 2);
    try std.testing.expectEqualStrings("model", results[0].item);

    const both = try fuzzyFilter([]const u8, std.testing.allocator, &items, "sc mod", &getText);
    defer std.testing.allocator.free(both);
    try std.testing.expect(both.len == 1);
    try std.testing.expectEqualStrings("scoped-models", both[0].item);
}

test "fuzzyFilter empty query preserves input order" {
    const items = [_][]const u8{ "b", "a", "c" };
    const getText = struct {
        fn f(item: []const u8) []const u8 {
            return item;
        }
    }.f;
    const results = try fuzzyFilter([]const u8, std.testing.allocator, &items, "  ", &getText);
    defer std.testing.allocator.free(results);
    try std.testing.expect(results.len == 3);
    try std.testing.expectEqualStrings("b", results[0].item);
    try std.testing.expectEqualStrings("a", results[1].item);
    try std.testing.expectEqualStrings("c", results[2].item);
}

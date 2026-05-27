//! Fuzzy matching for the TUI command palette / autocomplete.
//!
//! Port of upstream `packages/tui/src/fuzzy.ts` (`fuzzyMatch`, `fuzzyFilter`).
//! Matches if all query characters appear in order (not necessarily
//! consecutive). Lower score = better match. Supports ASCII case folding and
//! the upstream letter/digit "swapped query" fallback.

const std = @import("std");

pub const FuzzyMatch = struct {
    matches: bool,
    score: f64 = 0,
};

fn asciiLower(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn isWordBoundaryChar(c: u8) bool {
    // Mirror upstream regex /[\s\-_./:]/ on the preceding character.
    return std.ascii.isWhitespace(c) or c == '-' or c == '_' or c == '.' or c == '/' or c == ':';
}

/// Lowercase a string into `buf` (must be at least `text.len`). ASCII only.
fn lowerInto(buf: []u8, text: []const u8) []u8 {
    for (text, 0..) |c, i| buf[i] = asciiLower(c);
    return buf[0..text.len];
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

/// Returns whether `query` fuzzy-matches `text` and the match score.
/// `scratch` must be at least `@max(query.len, text.len)` bytes for case folding;
/// pass an empty slice to use a small stack buffer (sufficient for typical inputs).
pub fn fuzzyMatch(query: []const u8, text: []const u8) FuzzyMatch {
    var query_buf: [256]u8 = undefined;
    var text_buf: [1024]u8 = undefined;
    var swap_buf: [256]u8 = undefined;

    if (query.len > query_buf.len or text.len > text_buf.len) {
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

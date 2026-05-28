//! Terminal markdown renderer for pi-zig's TUI scrollback.
//!
//! Faithful Zig port of the upstream pi-mono renderer at
//! `upstream/pi/packages/tui/src/components/markdown.ts` (797 lines, Marked-based).
//! The upstream class is built on top of the `marked` npm parser; we replicate
//! the visible output (ANSI-styled lines that read like upstream's claude-code-
//! styled TUI) without pulling a parser dependency by implementing a minimal
//! line-level block grammar + an inline tokenizer that covers the subset
//! upstream actually uses for assistant transcripts:
//!
//!   - Block: ATX headers (#..######), unordered (-, *, +) and ordered (1.)
//!     lists, blockquotes (>), fenced code blocks (``` … ```), horizontal rules
//!     (---), and prose paragraphs.
//!   - Inline: **bold**, *italic* / _italic_, `code`, [text](href), backslash
//!     escapes for the markdown control chars.
//!
//! Output invariants (these mirror the upstream renderer and the pi-zig TUI's
//! differential repaint expectations):
//!
//!   * Each emitted line is SELF-CONTAINED w.r.t. ANSI state — every SGR open
//!     is closed on the same line, so the differential renderer's line diff
//!     stays correct when only one row changes.
//!   * Fenced code blocks render with a dim background tint and a 2-space
//!     indent, mirroring upstream's `codeBlockIndent` default. A lightweight
//!     token-class colorer matches the HTML export (keywords / strings /
//!     comments) so the visual treatment is consistent across HTML + TUI.
//!   * Wrap-aware: lines wider than `width` are hard-wrapped on byte
//!     boundaries (no grapheme/east-asian-width awareness — pi-zig's existing
//!     PTY harness uses 80 cols and ASCII-only fixtures, matching upstream's
//!     default font assumptions).
//!
//! Honest gaps vs the TS source (documented for the report and the next wave):
//!   - No tables. Upstream supports GFM tables; pi-zig assistant text rarely
//!     ships them and the port keeps to ATX/list/quote/code/HR — the four
//!     features the user verification doc explicitly listed.
//!   - No OSC-8 hyperlinks. Upstream falls back to plain "text (href)" when
//!     capabilities lack OSC-8; we always emit that fallback form.
//!   - No syntax highlighter dependency. We use the keyword/string/comment
//!     tokenizer in `html_export.zig` (kept locally to avoid a circular import)
//!     so HTML + TUI exports stay visually consistent.
//!   - No grapheme/east-asian width. Byte width is used for wrap accounting,
//!     mirroring the rest of pi-zig's TUI layer.
//!
//! All entry points return ANSI-styled lines OWNED by the caller; free each
//! line and the slice with `freeLines()` (or with the same allocator used at
//! construction). Inline-only helpers (`renderInline`) leave the caller's line
//! intact when the input is a bare prose run (the common case for transcript
//! lines that were already flattened by `App.appendTranscript`).

const std = @import("std");

// =====================================================================
// ANSI styling primitives
// =====================================================================
//
// Each constant is a complete open/close pair so callers (or the helpers
// below) can wrap an inline run cheaply. The codes mirror the existing
// `tui.zig::sgr` palette so assistant text rendered through `tui_markdown`
// blends with the status bar/banner already on screen.

pub const sgr = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";
    pub const strike = "\x1b[9m";
    pub const dim = "\x1b[2m";

    /// Inline `code`: bright accent on a dim background. Mirrors upstream's
    /// `code` theme (accent fg, default bg) but adds a dim bg so the span is
    /// visually distinct inside a transcript line.
    pub const code_open = "\x1b[38;5;208m\x1b[48;5;236m"; // accent fg + dim bg
    pub const code_close = "\x1b[0m";

    /// Fenced code block body: muted-green foreground, like upstream's
    /// `mdCodeBlock` dark-theme color (#green family). Background stays dim so
    /// the indented block looks like a card.
    pub const code_block_open = "\x1b[38;5;108m\x1b[48;5;235m"; // muted green fg, darker bg
    pub const code_block_close = "\x1b[0m";

    /// Code-block fence (the ``` lines): grey, dim. Matches upstream's
    /// `mdCodeBlockBorder` color.
    pub const code_block_border_open = "\x1b[38;5;240m"; // gray
    pub const code_block_border_close = "\x1b[0m";

    /// Headings: bright accent. h1 also opens underline; both are bold.
    pub const heading_open = "\x1b[1m\x1b[38;5;214m"; // bold + amber/orange
    pub const heading_close = "\x1b[0m";
    pub const heading_underline_open = "\x1b[1m\x1b[4m\x1b[38;5;214m"; // h1: + underline
    pub const heading_underline_close = "\x1b[0m";

    /// Links: blue underlined; the (url) tail in dim grey.
    pub const link_open = "\x1b[4m\x1b[38;5;111m"; // underlined blue
    pub const link_close = "\x1b[0m";
    pub const link_url_open = "\x1b[2m\x1b[38;5;240m"; // dim grey
    pub const link_url_close = "\x1b[0m";

    /// Blockquote: italic grey; the leading `│ ` border in solid grey.
    pub const quote_open = "\x1b[3m\x1b[38;5;240m"; // italic + grey
    pub const quote_close = "\x1b[0m";
    pub const quote_border_open = "\x1b[38;5;240m"; // grey
    pub const quote_border_close = "\x1b[0m";

    /// Horizontal rule: grey horizontal glyphs.
    pub const hr_open = "\x1b[38;5;240m";
    pub const hr_close = "\x1b[0m";

    /// List bullet (or "1.") prefix: accent.
    pub const bullet_open = "\x1b[38;5;208m"; // accent
    pub const bullet_close = "\x1b[0m";

    // Lightweight syntax tokens for fenced code blocks. Kept aligned with
    // html_export.zig's tok-kw/tok-str/tok-cmt classes so HTML + TUI stay
    // visually coherent.
    pub const tok_kw_open = "\x1b[38;5;176m\x1b[48;5;235m"; // purple-ish on dim bg
    pub const tok_str_open = "\x1b[38;5;180m\x1b[48;5;235m"; // tan on dim bg
    pub const tok_cmt_open = "\x1b[2m\x1b[38;5;108m\x1b[48;5;235m"; // dim green on dim bg
    pub const tok_close = "\x1b[0m";
};

// =====================================================================
// Public API
// =====================================================================

pub const RenderOptions = struct {
    /// Output width in columns. Lines wider than this are hard-wrapped. The
    /// upstream renderer defaults to the connected terminal width; the
    /// pi-zig PTY harness uses 80, which is also a reasonable fallback when
    /// the host hasn't measured a width.
    width: usize = 80,
    /// Horizontal padding (in spaces) applied to every output line, matching
    /// upstream's `paddingX`. The TUI scrollback already pads via the diff
    /// renderer, so the integration leaves this at 0 by default.
    padding_x: usize = 0,
};

/// Render a markdown document to a slice of ANSI-styled lines.
///
/// The returned slice and each line are owned by the caller; use `freeLines`
/// for a one-shot free. Returns an empty slice (still owned, length 0) when
/// the input is empty or whitespace-only.
pub fn render(allocator: std.mem.Allocator, text: []const u8, options: RenderOptions) ![][]u8 {
    if (text.len == 0 or std.mem.indexOfAny(u8, text, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#`*-_>") == null) {
        // Pure whitespace or punctuation: emit a single trimmed-empty line so
        // callers get a deterministic shape.
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) {
            const out = try allocator.alloc([]u8, 0);
            return out;
        }
    }

    var lines: std.ArrayList([]u8) = .empty;
    errdefer freeLineList(allocator, &lines);

    // Normalize tabs to 3 spaces (matches upstream).
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\t') {
            try normalized.appendSlice(allocator, "   ");
        } else if (text[i] == '\r') {
            // Strip CR; keep LF so block boundaries stay intact.
            continue;
        } else {
            try normalized.append(allocator, text[i]);
        }
    }

    try renderBlocks(allocator, &lines, normalized.items, options);

    // Hard-wrap each line to width (byte-based; ANSI sequences are skipped
    // so the visible-column estimate stays correct).
    if (options.width > 0) {
        var wrapped: std.ArrayList([]u8) = .empty;
        errdefer freeLineList(allocator, &wrapped);
        for (lines.items) |line| {
            try wrapAnsiLineInto(allocator, line, options.width, &wrapped);
        }
        // Free the unwrapped intermediates and replace with the wrapped slice.
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
        return try wrapped.toOwnedSlice(allocator);
    }

    return try lines.toOwnedSlice(allocator);
}

/// Render a single transcript line as INLINE-only markdown (no headers, no
/// fenced code, no lists, no quotes). Used by `tui.zig::buildScreen` to style
/// transcript rows that were already flattened by `appendTranscript`. The
/// returned line is owned by the caller.
///
/// Caller-friendly invariant: when the input has no markdown markers the
/// returned line is byte-identical to the input (allowing the renderer to
/// route every transcript line through this helper without allocating
/// surprising changes).
pub fn renderInlineLine(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    if (!hasInlineMarkers(line)) {
        return try allocator.dupe(u8, line);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try renderInline(allocator, &out, line);
    return try out.toOwnedSlice(allocator);
}

/// Free the slice produced by `render`.
pub fn freeLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| allocator.free(l);
    allocator.free(lines);
}

fn freeLineList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |l| allocator.free(l);
    list.deinit(allocator);
}

// =====================================================================
// Block-level grammar
// =====================================================================

const Block = union(enum) {
    blank,
    heading: HeadingBlock,
    paragraph: []const u8, // joined paragraph text (may include inline markers)
    code: CodeBlock,
    hr,
    quote: []const u8, // raw quote body (with markers stripped)
    unordered_list: ListBlock,
    ordered_list: ListBlock,
};

const HeadingBlock = struct {
    level: u8,
    text: []const u8,
};

const CodeBlock = struct {
    lang: []const u8,
    body: []const u8, // not owned; slice into the normalized buffer
};

const ListBlock = struct {
    items: []ListItem,
    start: usize = 1,
};

const ListItem = struct {
    text: []u8,
};

fn renderBlocks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]u8),
    text: []const u8,
    options: RenderOptions,
) !void {
    var line_it = std.mem.splitScalar(u8, text, '\n');
    // Buffer paragraph lines (re-joined by ' ' to mirror upstream Marked).
    var paragraph: std.ArrayList(u8) = .empty;
    defer paragraph.deinit(allocator);

    // Pending unordered/ordered list state.
    var list_buf: std.ArrayList(ListItem) = .empty;
    defer {
        for (list_buf.items) |item| allocator.free(item.text);
        list_buf.deinit(allocator);
    }
    var list_ordered: bool = false;
    var list_start: usize = 1;

    var prev_was_blank: bool = false;

    while (line_it.next()) |raw_line| {
        // Drop trailing whitespace; preserve leading whitespace (used to
        // detect indented continuations).
        var line = raw_line;
        while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) {
            line = line[0 .. line.len - 1];
        }

        // ---- fenced code block ----
        const trimmed_left = stripLeading(line);
        if (std.mem.startsWith(u8, trimmed_left, "```")) {
            try flushParagraph(allocator, out, &paragraph);
            try flushList(allocator, out, &list_buf, list_ordered, list_start, options);
            const lang = std.mem.trim(u8, trimmed_left[3..], " \t");
            // Consume until the closing fence or EOF.
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(allocator);
            while (line_it.next()) |body_line| {
                const body_trimmed = stripLeading(body_line);
                if (std.mem.startsWith(u8, body_trimmed, "```")) break;
                try body.appendSlice(allocator, body_line);
                try body.append(allocator, '\n');
            }
            // Drop trailing newline so we don't emit an empty body line.
            const body_slice = if (body.items.len > 0 and body.items[body.items.len - 1] == '\n')
                body.items[0 .. body.items.len - 1]
            else
                body.items;
            try emitCodeBlock(allocator, out, lang, body_slice, options);
            prev_was_blank = false;
            continue;
        }

        // ---- blank line ----
        if (std.mem.trim(u8, line, " \t").len == 0) {
            try flushParagraph(allocator, out, &paragraph);
            try flushList(allocator, out, &list_buf, list_ordered, list_start, options);
            if (!prev_was_blank and out.items.len > 0) {
                try out.append(allocator, try allocator.dupe(u8, ""));
            }
            prev_was_blank = true;
            continue;
        }
        prev_was_blank = false;

        // ---- ATX heading ----
        if (parseHeading(trimmed_left)) |h| {
            try flushParagraph(allocator, out, &paragraph);
            try flushList(allocator, out, &list_buf, list_ordered, list_start, options);
            try emitHeading(allocator, out, h);
            continue;
        }

        // ---- horizontal rule ----
        if (isHorizontalRule(trimmed_left)) {
            try flushParagraph(allocator, out, &paragraph);
            try flushList(allocator, out, &list_buf, list_ordered, list_start, options);
            try emitHr(allocator, out, options.width);
            continue;
        }

        // ---- blockquote ----
        if (trimmed_left.len > 0 and trimmed_left[0] == '>') {
            try flushParagraph(allocator, out, &paragraph);
            try flushList(allocator, out, &list_buf, list_ordered, list_start, options);
            const quote_body = std.mem.trimStart(u8, trimmed_left[1..], " ");
            try emitQuote(allocator, out, quote_body, options);
            continue;
        }

        // ---- unordered list ----
        if (parseUnorderedListMarker(trimmed_left)) |body| {
            try flushParagraph(allocator, out, &paragraph);
            if (list_buf.items.len > 0 and list_ordered) {
                try flushList(allocator, out, &list_buf, list_ordered, list_start, options);
            }
            list_ordered = false;
            list_start = 1;
            try list_buf.append(allocator, .{ .text = try allocator.dupe(u8, body) });
            continue;
        }

        // ---- ordered list ----
        if (parseOrderedListMarker(trimmed_left)) |info| {
            try flushParagraph(allocator, out, &paragraph);
            if (list_buf.items.len > 0 and !list_ordered) {
                try flushList(allocator, out, &list_buf, list_ordered, list_start, options);
            }
            if (list_buf.items.len == 0) list_start = info.number;
            list_ordered = true;
            try list_buf.append(allocator, .{ .text = try allocator.dupe(u8, info.body) });
            continue;
        }

        // ---- paragraph continuation ----
        try flushList(allocator, out, &list_buf, list_ordered, list_start, options);
        if (paragraph.items.len > 0) try paragraph.append(allocator, ' ');
        try paragraph.appendSlice(allocator, std.mem.trim(u8, line, " \t"));
    }

    try flushParagraph(allocator, out, &paragraph);
    try flushList(allocator, out, &list_buf, list_ordered, list_start, options);

    // Drop trailing blank lines so the rendered shape matches upstream's
    // "no spurious tail rows" invariant (and matches how a transcript
    // emitter would expect to append further content right after).
    while (out.items.len > 0 and out.items[out.items.len - 1].len == 0) {
        const last = out.pop().?;
        allocator.free(last);
    }
}

fn flushParagraph(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]u8),
    paragraph: *std.ArrayList(u8),
) !void {
    if (paragraph.items.len == 0) return;
    var rendered: std.ArrayList(u8) = .empty;
    errdefer rendered.deinit(allocator);
    try renderInline(allocator, &rendered, paragraph.items);
    try out.append(allocator, try rendered.toOwnedSlice(allocator));
    paragraph.clearRetainingCapacity();
}

fn flushList(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]u8),
    items: *std.ArrayList(ListItem),
    ordered: bool,
    start: usize,
    options: RenderOptions,
) !void {
    if (items.items.len == 0) return;
    for (items.items, 0..) |item, idx| {
        // Bullet prefix (ANSI-wrapped to bullet_open/close).
        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(allocator);
        try prefix.appendSlice(allocator, sgr.bullet_open);
        if (ordered) {
            try prefix.print(allocator, "{d}. ", .{start + idx});
        } else {
            try prefix.appendSlice(allocator, "- ");
        }
        try prefix.appendSlice(allocator, sgr.bullet_close);

        // Inline-render the item body.
        var inline_text: std.ArrayList(u8) = .empty;
        defer inline_text.deinit(allocator);
        try renderInline(allocator, &inline_text, item.text);

        // Combine, then wrap-aware emit. We don't add a continuation prefix
        // because the wrap helper splits on visible width and keeps each
        // emitted row self-contained for the differential renderer.
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        try line.appendSlice(allocator, prefix.items);
        try line.appendSlice(allocator, inline_text.items);
        try out.append(allocator, try line.toOwnedSlice(allocator));
        allocator.free(item.text);
    }
    items.clearRetainingCapacity();
    _ = options; // wrap pass happens at top-level
}

fn emitHeading(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]u8),
    h: HeadingBlock,
) !void {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    const open = if (h.level == 1) sgr.heading_underline_open else sgr.heading_open;
    const close = if (h.level == 1) sgr.heading_underline_close else sgr.heading_close;
    try line.appendSlice(allocator, open);
    // Prefix with the hash markers for h3+ (matches upstream).
    if (h.level >= 3) {
        var hi: u8 = 0;
        while (hi < h.level) : (hi += 1) try line.append(allocator, '#');
        try line.append(allocator, ' ');
    }
    // Inline-render the heading text so **bold**/`code` inside a heading still
    // styles, but re-open the heading SGR after each inline reset.
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);
    try renderInline(allocator, &rendered, h.text);
    try reopenAfterResets(allocator, &line, rendered.items, open);
    try line.appendSlice(allocator, close);
    try out.append(allocator, try line.toOwnedSlice(allocator));
}

fn emitHr(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), width: usize) !void {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    try line.appendSlice(allocator, sgr.hr_open);
    const cols = @min(@max(width, 1), 80);
    var i: usize = 0;
    while (i < cols) : (i += 1) try line.appendSlice(allocator, "\xe2\x94\x80"); // U+2500
    try line.appendSlice(allocator, sgr.hr_close);
    try out.append(allocator, try line.toOwnedSlice(allocator));
}

fn emitQuote(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]u8),
    body: []const u8,
    options: RenderOptions,
) !void {
    _ = options;
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    try line.appendSlice(allocator, sgr.quote_border_open);
    try line.appendSlice(allocator, "\xe2\x94\x82 "); // U+2502 + space
    try line.appendSlice(allocator, sgr.quote_border_close);
    try line.appendSlice(allocator, sgr.quote_open);
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);
    try renderInline(allocator, &rendered, body);
    try reopenAfterResets(allocator, &line, rendered.items, sgr.quote_open);
    try line.appendSlice(allocator, sgr.quote_close);
    try out.append(allocator, try line.toOwnedSlice(allocator));
}

fn emitCodeBlock(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]u8),
    lang: []const u8,
    body: []const u8,
    options: RenderOptions,
) !void {
    _ = options;
    const indent = "  ";

    // Opening fence row: ```<lang> in the border color.
    {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        try line.appendSlice(allocator, sgr.code_block_border_open);
        try line.appendSlice(allocator, "```");
        try line.appendSlice(allocator, lang);
        try line.appendSlice(allocator, sgr.code_block_border_close);
        try out.append(allocator, try line.toOwnedSlice(allocator));
    }

    // Body: one line per source line, each indented and tokenized.
    var body_it = std.mem.splitScalar(u8, body, '\n');
    while (body_it.next()) |body_line| {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        try line.appendSlice(allocator, indent);
        try line.appendSlice(allocator, sgr.code_block_open);
        try renderCodeTokens(allocator, &line, body_line, lang);
        try line.appendSlice(allocator, sgr.code_block_close);
        try out.append(allocator, try line.toOwnedSlice(allocator));
    }

    // Closing fence row.
    {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        try line.appendSlice(allocator, sgr.code_block_border_open);
        try line.appendSlice(allocator, "```");
        try line.appendSlice(allocator, sgr.code_block_border_close);
        try out.append(allocator, try line.toOwnedSlice(allocator));
    }
}

// =====================================================================
// Block helpers
// =====================================================================

fn parseHeading(line: []const u8) ?HeadingBlock {
    if (line.len == 0 or line[0] != '#') return null;
    var level: u8 = 0;
    while (level < line.len and line[level] == '#') : (level += 1) {}
    if (level == 0 or level > 6) return null;
    if (level >= line.len) return .{ .level = level, .text = "" };
    if (line[level] != ' ') return null;
    return .{ .level = level, .text = std.mem.trim(u8, line[level + 1 ..], " \t") };
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const c = line[0];
    if (c != '-' and c != '_' and c != '*') return false;
    var count: usize = 0;
    for (line) |byte| {
        if (byte == c) count += 1
        else if (byte == ' ' or byte == '\t') {}
        else return false;
    }
    return count >= 3;
}

fn parseUnorderedListMarker(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;
    const c = line[0];
    if (c != '-' and c != '*' and c != '+') return null;
    if (line[1] != ' ') return null;
    return std.mem.trim(u8, line[2..], " \t");
}

const OrderedListInfo = struct {
    number: usize,
    body: []const u8,
};

fn parseOrderedListMarker(line: []const u8) ?OrderedListInfo {
    var idx: usize = 0;
    var number: usize = 0;
    while (idx < line.len and std.ascii.isDigit(line[idx])) : (idx += 1) {
        number = number * 10 + @as(usize, @intCast(line[idx] - '0'));
    }
    if (idx == 0 or idx >= line.len) return null;
    if (line[idx] != '.' and line[idx] != ')') return null;
    idx += 1;
    if (idx >= line.len or line[idx] != ' ') return null;
    return .{ .number = number, .body = std.mem.trim(u8, line[idx + 1 ..], " \t") };
}

fn stripLeading(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line[i..];
}

// =====================================================================
// Inline tokenizer
// =====================================================================
//
// Mirrors the subset of upstream `renderInlineTokens` exercised by assistant
// transcripts: **bold**, *italic* (and _italic_), `code`, [text](href), plus
// backslash escapes (\* \_ \` \[ etc.). The tokenizer is a single-pass scanner
// over bytes; no AST is built, no allocator is held outside the output buffer.

fn hasInlineMarkers(line: []const u8) bool {
    for (line) |c| {
        switch (c) {
            '*', '_', '`', '[', '\\' => return true,
            else => {},
        }
    }
    return false;
}

fn renderInline(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        // Escape: \X passes X through literally (matches markdown spec).
        if (c == '\\' and i + 1 < text.len) {
            try out.append(allocator, text[i + 1]);
            i += 2;
            continue;
        }
        // Bold: **...**
        if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (findCloser(text, i + 2, "**")) |close| {
                try out.appendSlice(allocator, sgr.bold);
                try renderInline(allocator, out, text[i + 2 .. close]);
                try out.appendSlice(allocator, sgr.reset);
                i = close + 2;
                continue;
            }
        }
        // Italic: *...* or _..._
        if ((c == '*' or c == '_') and i + 1 < text.len and text[i + 1] != c) {
            const closer = [_]u8{c};
            if (findCloser(text, i + 1, &closer)) |close| {
                // Reject an empty span and the bold form (already handled).
                if (close > i + 1) {
                    try out.appendSlice(allocator, sgr.italic);
                    try renderInline(allocator, out, text[i + 1 .. close]);
                    try out.appendSlice(allocator, sgr.reset);
                    i = close + 1;
                    continue;
                }
            }
        }
        // Inline code: `...`
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close| {
                try out.appendSlice(allocator, sgr.code_open);
                try out.appendSlice(allocator, text[i + 1 .. close]);
                try out.appendSlice(allocator, sgr.code_close);
                i = close + 1;
                continue;
            }
        }
        // Link: [text](href)
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |close_text| {
                if (close_text + 1 < text.len and text[close_text + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close_text + 2, ')')) |close_href| {
                        const link_text = text[i + 1 .. close_text];
                        const href = text[close_text + 2 .. close_href];
                        try out.appendSlice(allocator, sgr.link_open);
                        try renderInline(allocator, out, link_text);
                        try out.appendSlice(allocator, sgr.link_close);
                        // Render the (href) tail in dim grey when it differs
                        // from the visible text (matches upstream fallback).
                        if (!std.mem.eql(u8, link_text, href)) {
                            try out.appendSlice(allocator, sgr.link_url_open);
                            try out.append(allocator, ' ');
                            try out.append(allocator, '(');
                            try out.appendSlice(allocator, href);
                            try out.append(allocator, ')');
                            try out.appendSlice(allocator, sgr.link_url_close);
                        }
                        i = close_href + 1;
                        continue;
                    }
                }
            }
        }
        // Default: pass byte through.
        try out.append(allocator, c);
        i += 1;
    }
}

fn findCloser(text: []const u8, start: usize, marker: []const u8) ?usize {
    var i: usize = start;
    while (i + marker.len <= text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], marker)) return i;
    }
    return null;
}

/// Re-open `style` after every embedded `\x1b[0m` reset inside `rendered`,
/// then write the result into `out`. This mirrors the upstream blockquote /
/// heading style-prefix trick: when an inner inline span closes with a full
/// reset, the surrounding outer style would otherwise drop until the line
/// ends. Appending the outer style after each reset keeps the visible state
/// consistent without spilling SGR across line boundaries.
fn reopenAfterResets(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rendered: []const u8,
    style: []const u8,
) !void {
    const reset = sgr.reset;
    var i: usize = 0;
    while (i < rendered.len) {
        if (i + reset.len <= rendered.len and std.mem.startsWith(u8, rendered[i..], reset)) {
            try out.appendSlice(allocator, reset);
            try out.appendSlice(allocator, style);
            i += reset.len;
            continue;
        }
        try out.append(allocator, rendered[i]);
        i += 1;
    }
}

// =====================================================================
// Code-block syntax tokenizer (mirrors html_export.zig classes)
// =====================================================================

fn renderCodeTokens(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    lang: []const u8,
) !void {
    const hash_comments = langUsesHashComments(lang);
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        // Block comment open: /* ... */ on the same line.
        if (c == '/' and i + 1 < line.len and line[i + 1] == '*') {
            const end_idx = std.mem.indexOfPos(u8, line, i + 2, "*/");
            const stop = if (end_idx) |e| e + 2 else line.len;
            try out.appendSlice(allocator, sgr.tok_cmt_open);
            try out.appendSlice(allocator, line[i..stop]);
            try out.appendSlice(allocator, sgr.tok_close);
            try out.appendSlice(allocator, sgr.code_block_open);
            i = stop;
            continue;
        }
        // Line comment: //
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            try out.appendSlice(allocator, sgr.tok_cmt_open);
            try out.appendSlice(allocator, line[i..]);
            try out.appendSlice(allocator, sgr.tok_close);
            try out.appendSlice(allocator, sgr.code_block_open);
            return;
        }
        // Hash comment for shell/python/etc.
        if (c == '#' and hash_comments) {
            try out.appendSlice(allocator, sgr.tok_cmt_open);
            try out.appendSlice(allocator, line[i..]);
            try out.appendSlice(allocator, sgr.tok_close);
            try out.appendSlice(allocator, sgr.code_block_open);
            return;
        }
        // String literal.
        if (c == '"' or c == '\'' or c == '`') {
            const end = scanStringEnd(line, i, c);
            try out.appendSlice(allocator, sgr.tok_str_open);
            try out.appendSlice(allocator, line[i..end]);
            try out.appendSlice(allocator, sgr.tok_close);
            try out.appendSlice(allocator, sgr.code_block_open);
            i = end;
            continue;
        }
        // Identifier / keyword.
        if (isIdentStart(c)) {
            var j: usize = i + 1;
            while (j < line.len and isIdentPart(line[j])) : (j += 1) {}
            const word = line[i..j];
            if (isCodeKeyword(word)) {
                try out.appendSlice(allocator, sgr.tok_kw_open);
                try out.appendSlice(allocator, word);
                try out.appendSlice(allocator, sgr.tok_close);
                try out.appendSlice(allocator, sgr.code_block_open);
            } else {
                try out.appendSlice(allocator, word);
            }
            i = j;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
}

fn scanStringEnd(line: []const u8, start: usize, quote: u8) usize {
    var i: usize = start + 1;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (c == quote) return i + 1;
    }
    return line.len;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn langUsesHashComments(lang: []const u8) bool {
    const hash_langs = [_][]const u8{
        "sh", "bash", "zsh", "shell", "python", "py", "ruby", "rb", "yaml",
        "yml", "toml", "perl", "r", "makefile", "dockerfile",
    };
    for (hash_langs) |candidate| {
        if (asciiEqlIgnoreCase(lang, candidate)) return true;
    }
    return false;
}

fn isCodeKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        // JS/TS
        "const",   "let",        "var",     "function", "return",  "if",      "else",   "for",
        "while",   "do",         "switch",  "case",     "break",   "continue", "new",   "class",
        "extends", "import",     "export",  "from",     "default", "async",   "await",  "yield",
        "typeof",  "instanceof", "in",      "of",       "this",    "super",   "null",   "undefined",
        "true",    "false",      "void",    "delete",   "try",     "catch",   "finally","throw",
        // Common across languages
        "def",     "elif",       "lambda",  "pass",     "with",    "as",      "and",    "or",
        "not",     "fn",         "mut",     "pub",      "use",     "struct",  "enum",
        "impl",    "trait",      "match",   "type",     "interface","public", "private","static",
        "int",     "float",      "bool",    "string",   "package", "func",    "go",     "defer",
        "select",  "chan",       "map",     "range",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

// =====================================================================
// Wrapping (byte-based, ANSI-aware)
// =====================================================================

fn wrapAnsiLineInto(
    allocator: std.mem.Allocator,
    line: []const u8,
    width: usize,
    out: *std.ArrayList([]u8),
) !void {
    if (line.len == 0) {
        try out.append(allocator, try allocator.dupe(u8, ""));
        return;
    }

    // Estimate visible width by stripping ANSI escape sequences. We split
    // exactly when the next visible byte would overflow `width`. The wrap
    // closes the current SGR with a reset and re-opens the active style on
    // the next row so each emitted row stays self-contained.
    var visible: usize = 0;
    var i: usize = 0;
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(allocator);
    var active_style: std.ArrayList(u8) = .empty;
    defer active_style.deinit(allocator);

    while (i < line.len) {
        // ANSI escape: ESC [ ... letter
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            var j: usize = i + 2;
            while (j < line.len) : (j += 1) {
                const ch = line[j];
                if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z')) break;
            }
            const end = if (j < line.len) j + 1 else line.len;
            const esc = line[i..end];
            try row.appendSlice(allocator, esc);
            // Track the active style so wrap rows can re-open it. A reset
            // (`\x1b[0m`) clears the active style.
            if (std.mem.eql(u8, esc, sgr.reset)) {
                active_style.clearRetainingCapacity();
            } else {
                try active_style.appendSlice(allocator, esc);
            }
            i = end;
            continue;
        }

        // Visible byte: account for width and split when full. ASCII columns
        // count 1 byte = 1 col; multi-byte UTF-8 leading bytes also count 1
        // col so width is a reasonable upper bound for the common cases the
        // pi-zig PTY harness ships.
        const advance = utf8CharLen(line[i]);
        if (visible == width) {
            // Close current SGR, push the row, reopen on the next row.
            if (active_style.items.len > 0) try row.appendSlice(allocator, sgr.reset);
            try out.append(allocator, try row.toOwnedSlice(allocator));
            row = .empty;
            visible = 0;
            if (active_style.items.len > 0) try row.appendSlice(allocator, active_style.items);
        }
        const take = @min(advance, line.len - i);
        try row.appendSlice(allocator, line[i .. i + take]);
        visible += 1;
        i += take;
    }
    if (active_style.items.len > 0) try row.appendSlice(allocator, sgr.reset);
    try out.append(allocator, try row.toOwnedSlice(allocator));
}

fn utf8CharLen(b: u8) usize {
    if (b < 0x80) return 1;
    if (b < 0xC0) return 1; // continuation byte; safe lower bound
    if (b < 0xE0) return 2;
    if (b < 0xF0) return 3;
    return 4;
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

fn lineContains(lines: [][]u8, needle: []const u8) bool {
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) return true;
    }
    return false;
}

test "render returns empty slice for whitespace-only input" {
    const lines = try render(testing.allocator, "   \n  \t  \n", .{});
    defer freeLines(testing.allocator, lines);
    try testing.expect(lines.len == 0);
}

test "render emits ATX heading with bold open and reset" {
    const lines = try render(testing.allocator, "# Hello world\n", .{ .width = 80 });
    defer freeLines(testing.allocator, lines);
    try testing.expect(lines.len >= 1);
    // h1 opens with the underline+bold sequence; the visible text follows.
    try testing.expect(std.mem.indexOf(u8, lines[0], "Hello world") != null);
    try testing.expect(std.mem.indexOf(u8, lines[0], "\x1b[1m") != null);
    try testing.expect(std.mem.endsWith(u8, lines[0], sgr.reset));
}

test "render emits h3 with hash prefix preserved" {
    const lines = try render(testing.allocator, "### Section\n", .{ .width = 80 });
    defer freeLines(testing.allocator, lines);
    try testing.expect(std.mem.indexOf(u8, lines[0], "### Section") != null);
}

test "render emits unordered list with accent bullet" {
    const md = "- alpha\n- beta\n- gamma\n";
    const lines = try render(testing.allocator, md, .{ .width = 80 });
    defer freeLines(testing.allocator, lines);
    try testing.expect(lines.len >= 3);
    // Each row carries the accent bullet prefix + the item body. ANSI sits
    // between the marker and the body so we check the two pieces separately.
    try testing.expect(std.mem.indexOf(u8, lines[0], sgr.bullet_open) != null);
    try testing.expect(std.mem.indexOf(u8, lines[0], "- ") != null);
    try testing.expect(std.mem.indexOf(u8, lines[0], "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, lines[1], "beta") != null);
    try testing.expect(std.mem.indexOf(u8, lines[2], "gamma") != null);
}

test "render emits ordered list with sequential numbers from the marker" {
    const md = "3. first item\n4. second item\n";
    const lines = try render(testing.allocator, md, .{ .width = 80 });
    defer freeLines(testing.allocator, lines);
    try testing.expect(lines.len >= 2);
    // ANSI separates the numbered marker from the body; check both halves.
    try testing.expect(std.mem.indexOf(u8, lines[0], "3. ") != null);
    try testing.expect(std.mem.indexOf(u8, lines[0], "first item") != null);
    try testing.expect(std.mem.indexOf(u8, lines[1], "4. ") != null);
    try testing.expect(std.mem.indexOf(u8, lines[1], "second item") != null);
}

test "render emits fenced code block with border + indented body" {
    const md = "```js\nconst x = 1;\nreturn x;\n```\n";
    const lines = try render(testing.allocator, md, .{ .width = 80 });
    defer freeLines(testing.allocator, lines);
    try testing.expect(lines.len >= 4);
    // First line is the opening fence in border color.
    try testing.expect(std.mem.indexOf(u8, lines[0], "```") != null);
    try testing.expect(std.mem.indexOf(u8, lines[0], sgr.code_block_border_open) != null);
    // Body line has the 2-space indent and the code-block fg/bg.
    try testing.expect(std.mem.startsWith(u8, lines[1], "  "));
    try testing.expect(std.mem.indexOf(u8, lines[1], sgr.code_block_open) != null);
    // Keyword "const" gets the tok-kw class.
    try testing.expect(std.mem.indexOf(u8, lines[1], sgr.tok_kw_open) != null);
}

test "render emits horizontal rule" {
    const lines = try render(testing.allocator, "before\n\n---\n\nafter\n", .{ .width = 20 });
    defer freeLines(testing.allocator, lines);
    var found_hr = false;
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, sgr.hr_open) != null) found_hr = true;
    }
    try testing.expect(found_hr);
}

test "render emits blockquote with U+2502 border" {
    const lines = try render(testing.allocator, "> quoted text\n", .{ .width = 80 });
    defer freeLines(testing.allocator, lines);
    try testing.expect(lines.len >= 1);
    try testing.expect(std.mem.indexOf(u8, lines[0], "\xe2\x94\x82") != null);
    try testing.expect(std.mem.indexOf(u8, lines[0], "quoted text") != null);
}

test "renderInline styles bold then italic then code" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderInline(testing.allocator, &buf, "a **bold** and *italic* and `code`.");
    // Bold span open/close.
    try testing.expect(std.mem.indexOf(u8, buf.items, sgr.bold) != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "bold") != null);
    // Italic span open/close.
    try testing.expect(std.mem.indexOf(u8, buf.items, sgr.italic) != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "italic") != null);
    // Inline code: accent on dim bg, with the marker removed.
    try testing.expect(std.mem.indexOf(u8, buf.items, sgr.code_open) != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "code") != null);
    // No raw markdown markers remain.
    try testing.expect(std.mem.indexOf(u8, buf.items, "**") == null);
}

test "renderInline emits link with (url) fallback when text != href" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderInline(testing.allocator, &buf, "see [pi-zig](https://example.org) docs");
    try testing.expect(std.mem.indexOf(u8, buf.items, sgr.link_open) != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "pi-zig") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, sgr.link_url_open) != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "(https://example.org)") != null);
}

test "renderInline drops (url) when the link text equals the href" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderInline(testing.allocator, &buf, "[https://x.io](https://x.io)");
    try testing.expect(std.mem.indexOf(u8, buf.items, "https://x.io") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "(https://x.io)") == null);
}

test "renderInline passes through escaped markers" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderInline(testing.allocator, &buf, "literal \\*not bold\\* end");
    try testing.expect(std.mem.indexOf(u8, buf.items, "*not bold*") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, sgr.bold) == null);
}

test "renderInlineLine returns input verbatim when there are no markers" {
    const out = try renderInlineLine(testing.allocator, "plain text without markers");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("plain text without markers", out);
}

test "renderInlineLine styles when markers are present" {
    const out = try renderInlineLine(testing.allocator, "this is **strong** stuff");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, sgr.bold) != null);
    try testing.expect(std.mem.indexOf(u8, out, "strong") != null);
    try testing.expect(std.mem.indexOf(u8, out, "**") == null);
}

test "wrapAnsiLineInto splits a long ANSI-styled line preserving style on the next row" {
    const input = sgr.bold ++ "abcdefghij" ++ sgr.reset;
    var out: std.ArrayList([]u8) = .empty;
    defer freeLineList(testing.allocator, &out);
    try wrapAnsiLineInto(testing.allocator, input, 4, &out);
    try testing.expect(out.items.len == 3);
    // Each row carries the bold open and a reset.
    try testing.expect(std.mem.startsWith(u8, out.items[0], sgr.bold));
    try testing.expect(std.mem.endsWith(u8, out.items[0], sgr.reset));
    try testing.expect(std.mem.startsWith(u8, out.items[1], sgr.bold));
    try testing.expect(std.mem.endsWith(u8, out.items[1], sgr.reset));
}

test "render keeps paragraphs separated by a single blank line" {
    const md = "first paragraph\n\nsecond paragraph\n";
    const lines = try render(testing.allocator, md, .{ .width = 80 });
    defer freeLines(testing.allocator, lines);
    try testing.expect(lines.len == 3);
    try testing.expectEqualStrings("first paragraph", lines[0]);
    try testing.expectEqualStrings("", lines[1]);
    try testing.expectEqualStrings("second paragraph", lines[2]);
}

test "render composes a representative document with header + code + list + link + bold/italic" {
    const md =
        "# Sample\n\n" ++
        "This is **bold** and *italic* and `code`.\n\n" ++
        "- item one\n- item two\n\n" ++
        "```js\nconst answer = 42;\n```\n\n" ++
        "See [example](https://example.com).\n";
    const lines = try render(testing.allocator, md, .{ .width = 80 });
    defer freeLines(testing.allocator, lines);
    // Heading is bold + styled.
    try testing.expect(lineContains(lines, "Sample"));
    try testing.expect(lineContains(lines, sgr.heading_underline_open));
    // Inline styling for bold/italic/code.
    try testing.expect(lineContains(lines, sgr.bold));
    try testing.expect(lineContains(lines, sgr.italic));
    try testing.expect(lineContains(lines, sgr.code_open));
    // List bullets in accent (the marker and the item body are checked
    // separately because an ANSI reset sits between them).
    try testing.expect(lineContains(lines, sgr.bullet_open));
    try testing.expect(lineContains(lines, "- "));
    try testing.expect(lineContains(lines, "item one"));
    // Fenced code block.
    try testing.expect(lineContains(lines, sgr.code_block_border_open));
    try testing.expect(lineContains(lines, sgr.code_block_open));
    try testing.expect(lineContains(lines, "const"));
    // Link styling + (url) tail.
    try testing.expect(lineContains(lines, sgr.link_open));
    try testing.expect(lineContains(lines, "(https://example.com)"));
}

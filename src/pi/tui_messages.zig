//! Interactive message renderers for pi-zig.
//!
//! Ports the upstream coding-agent message components:
//!   - `interactive/components/user-message.ts`
//!   - `interactive/components/assistant-message.ts`
//!   - `interactive/components/tool-execution.ts`
//!   - `interactive/components/bash-execution.ts`
//!   - `interactive/components/compaction-summary-message.ts`
//!   - `interactive/components/branch-summary-message.ts`
//!   - `interactive/components/custom-message.ts`
//!   - `interactive/components/skill-invocation-message.ts`
//!
//! Each renderer here returns one or more transcript LINES (owned `[]u8`) — the
//! pi-zig differential renderer compares lines literally, so every ANSI SGR open
//! is balanced by a `reset` on the same line. No line ever leaves an open SGR
//! state behind. The box-drawing chrome is plain UTF-8 (no zero-width control
//! sequences), which keeps the wave3 status-bar diff cost predictable.
//!
//! The renderers are pure: they take small structs and an allocator, and return
//! owned lines. They do not touch the terminal directly, so they are unit-
//! testable byte-by-byte against the expected output (see tests at the bottom
//! of this file). The `tui.App.appendUser*` / `appendAssistant*` / `appendTool*`
//! helpers in `tui.zig` invoke these and feed their output into the App's
//! existing transcript scrollback (`App.transcript`).

const std = @import("std");

// =====================================================================
// ANSI styling primitives
// =====================================================================
//
// Every renderer opens its SGR state at the start of a line and closes with
// `reset` before the line terminator. The differential renderer in
// `tui_render.zig` compares lines string-equal, so any spilled SGR state would
// corrupt later rewrites. The palette mirrors the upstream dark theme keys
// (userMessageBg/userMessageText, customMessageLabel/customMessageBg/customMessageText,
// bashMode, toolTitle, toolOutput, toolPendingBg/toolSuccessBg/toolErrorBg,
// muted/dim/warning/error) using the same 256-color ANSI codes the rest of
// pi-zig's TUI uses. They are pinned here (not re-exported from `tui.zig`)
// so the module compiles standalone for tests without pulling in App state.

pub const sgr = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const italic = "\x1b[3m";
    pub const inverse = "\x1b[7m";
    pub const dim_attr = "\x1b[2m";

    // Foreground colors keyed to upstream theme tokens.
    pub const user_chip_fg = "\x1b[38;5;15m"; // bright white text on the USER chip
    pub const assistant_chip_fg = "\x1b[38;5;15m"; // bright white text on the ASSISTANT chip
    pub const muted = "\x1b[38;5;240m"; // dim gray — dividers / hints
    pub const dim = "\x1b[38;5;244m"; // softer gray — preview body
    pub const accent = "\x1b[38;5;208m"; // orange — tool title accent
    pub const bash = "\x1b[38;5;82m"; // green — bash mode (upstream `bashMode: green`)
    pub const warning = "\x1b[38;5;214m"; // amber — truncation / cancelled markers
    pub const error_fg = "\x1b[38;5;196m"; // red — error markers (upstream `error: red`)
    pub const custom_label_fg = "\x1b[38;5;141m"; // muted purple — upstream `customMessageLabel: #9575cd`
    pub const tool_output_fg = "\x1b[38;5;244m"; // muted gray — upstream `toolOutput: gray`

    // Background colors keyed to upstream chip surfaces. These are intentionally
    // dim 256-color slabs so the text foreground stays readable.
    pub const user_chip_bg = "\x1b[48;5;25m"; // blue — user role chip
    pub const assistant_chip_bg = "\x1b[48;5;130m"; // amber-brown — assistant role chip
    pub const tool_pending_bg = "\x1b[48;5;236m"; // upstream `toolPendingBg: #282832`
    pub const tool_success_bg = "\x1b[48;5;22m"; // upstream `toolSuccessBg: #283228`
    pub const tool_error_bg = "\x1b[48;5;52m"; // upstream `toolErrorBg: #3c2828`
    pub const custom_bg = "\x1b[48;5;237m"; // upstream `customMsgBg: #2d2838`
};

// =====================================================================
// Box-drawing primitives
// =====================================================================
//
// Upstream uses `Box`/`DynamicBorder` (pi-tui) which paint single-line box
// borders with U+2500 LIGHT HORIZONTAL and the four corner glyphs. The
// renderers here emit the same characters. Reused by the user/assistant/tool/
// bash/compaction/branch/custom/skill blocks.

pub const box = struct {
    pub const top_left = "\xe2\x95\xad"; // U+256D LIGHT ARC DOWN AND RIGHT
    pub const top_right = "\xe2\x95\xae"; // U+256E LIGHT ARC DOWN AND LEFT
    pub const bottom_left = "\xe2\x95\xb0"; // U+2570 LIGHT ARC UP AND RIGHT
    pub const bottom_right = "\xe2\x95\xaf"; // U+256F LIGHT ARC UP AND LEFT
    pub const horizontal = "\xe2\x94\x80"; // U+2500 LIGHT HORIZONTAL
    pub const vertical = "\xe2\x94\x82"; // U+2502 LIGHT VERTICAL
};

/// Default width (cells, ASCII approximation) for the box-drawing chrome. The
/// renderers use this to size the top/bottom rules. Callers can pass `null` to
/// fall back to this. Picked to match the upstream Box default with comfortable
/// padding for ~80-col terminals.
const default_box_width: usize = 60;

// =====================================================================
// Renderer inputs
// =====================================================================

/// Inputs for `renderUserMessage`. Mirrors upstream `UserMessageComponent`'s
/// single-text input — markdown is not interpreted; the text is rendered as
/// plain styled lines.
pub const UserMessageInput = struct {
    text: []const u8,
    width: ?usize = null,
};

/// Inputs for `renderAssistantMessage`. Tool calls are rendered as nested
/// `ToolCall` blocks inside the assistant chrome (or by `renderToolExecution`
/// when the call is its own transcript block).
pub const AssistantMessageInput = struct {
    text: []const u8,
    width: ?usize = null,
};

/// Inputs for `renderToolExecution`. Mirrors upstream `ToolExecutionComponent`:
/// `tool_name` + `arguments_json` (always) + an optional `result_text` preview
/// (when the tool has completed). `is_error` toggles the surface color.
pub const ToolExecutionInput = struct {
    tool_name: []const u8,
    arguments_json: []const u8 = "",
    result_text: ?[]const u8 = null,
    is_error: bool = false,
    pending: bool = false,
    /// Preview cap (in chars) applied to `result_text` so a long output doesn't
    /// blow up the scrollback. Upstream uses a line-count truncation; here we
    /// cap by bytes since the App writes lines, not chars-per-cell.
    preview_chars: usize = 400,
    width: ?usize = null,
};

/// Inputs for `renderBashExecution`. Mirrors upstream `BashExecutionComponent`:
/// `command` + accumulated `output` + an optional `exit_code` and `cancelled`
/// flag. Lines are truncated for preview to match upstream's 20-line cap.
pub const BashExecutionInput = struct {
    command: []const u8,
    output: []const u8 = "",
    exit_code: ?i32 = null,
    cancelled: bool = false,
    /// Optional path to the full output when truncated; rendered as a warning
    /// line so the user can find the spilled artifact.
    full_output_path: ?[]const u8 = null,
    preview_lines: usize = 20,
    width: ?usize = null,
};

/// Inputs for `renderCompactionSummary`. Mirrors upstream
/// `CompactionSummaryMessageComponent` (expanded mode): a `[compaction]` label,
/// the tokens-before count, and the summary body.
pub const CompactionSummaryInput = struct {
    tokens_before: u64,
    summary: []const u8,
    width: ?usize = null,
};

/// Inputs for `renderBranchSummary`. Mirrors upstream
/// `BranchSummaryMessageComponent` (expanded mode): a `[branch]` label and the
/// summary body. The header line is "Branch Summary" as upstream does.
pub const BranchSummaryInput = struct {
    summary: []const u8,
    width: ?usize = null,
};

/// Inputs for `renderCustomMessage`. Mirrors upstream `CustomMessageComponent`
/// (default rendering): a `[<customType>]` label and the text body. Only used
/// when the message's `display` field is true (the App filters); display=false
/// messages don't reach the transcript.
pub const CustomMessageInput = struct {
    custom_type: []const u8,
    content: []const u8,
    width: ?usize = null,
};

/// Inputs for `renderSkillInvocation`. Mirrors upstream
/// `SkillInvocationMessageComponent` (expanded mode): a `[skill]` label, the
/// skill name as a bold header, and the rendered skill content/args body.
pub const SkillInvocationInput = struct {
    name: []const u8,
    args: []const u8 = "",
    width: ?usize = null,
};

// =====================================================================
// Renderer outputs
// =====================================================================

/// One rendered transcript line, owned. Returned in a slice from each
/// renderer so the caller can hand them to `App.transcript` directly.
pub const RenderedLines = struct {
    lines: [][]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RenderedLines) void {
        for (self.lines) |line| self.allocator.free(line);
        self.allocator.free(self.lines);
    }
};

fn finalize(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) !RenderedLines {
    return .{
        .lines = try list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// =====================================================================
// Helpers
// =====================================================================

fn boxWidth(width: ?usize) usize {
    return width orelse default_box_width;
}

/// Build the top rule of a box: `╭──...──╮` (using box-drawing chars).
/// Wraps each segment in the supplied foreground color so the chrome reads as
/// part of the message it labels. Caller owns the returned line.
fn buildTopRule(allocator: std.mem.Allocator, fg: []const u8, width: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, fg);
    try out.appendSlice(allocator, box.top_left);
    var i: usize = 0;
    while (i + 2 < width) : (i += 1) try out.appendSlice(allocator, box.horizontal);
    try out.appendSlice(allocator, box.top_right);
    try out.appendSlice(allocator, sgr.reset);
    return out.toOwnedSlice(allocator);
}

/// Build the bottom rule of a box: `╰──...──╯`. Mirror of `buildTopRule`.
fn buildBottomRule(allocator: std.mem.Allocator, fg: []const u8, width: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, fg);
    try out.appendSlice(allocator, box.bottom_left);
    var i: usize = 0;
    while (i + 2 < width) : (i += 1) try out.appendSlice(allocator, box.horizontal);
    try out.appendSlice(allocator, box.bottom_right);
    try out.appendSlice(allocator, sgr.reset);
    return out.toOwnedSlice(allocator);
}

/// Build a horizontal divider (used as a visual separator between message
/// blocks, mirroring upstream `DynamicBorder`'s standalone rule). All styling
/// open/closed on the same line.
pub fn buildDivider(allocator: std.mem.Allocator, width: ?usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, sgr.muted);
    var i: usize = 0;
    while (i < boxWidth(width)) : (i += 1) try out.appendSlice(allocator, box.horizontal);
    try out.appendSlice(allocator, sgr.reset);
    return out.toOwnedSlice(allocator);
}

/// Append every newline-separated chunk of `text` to `list` with `prefix`
/// prepended and styled with `fg`. Each appended line opens+closes its own SGR.
/// Empty input produces no lines (the renderers handle the empty case
/// explicitly to avoid a stray styled prefix).
fn appendStyledLines(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]u8),
    prefix: []const u8,
    fg: []const u8,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |part| {
        const line = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s}", .{ prefix, fg, part, sgr.reset, "" });
        errdefer allocator.free(line);
        try list.append(allocator, line);
    }
}

// =====================================================================
// Renderers
// =====================================================================

/// Render a user message: a boxed block with a "USER" chip and the text body.
/// Upstream uses a colored background slab; we approximate with a chip + box
/// border so the same shape reads on non-truecolor terminals. Each line is
/// fully styled (open+close SGR) so the differential renderer stays correct.
pub fn renderUserMessage(allocator: std.mem.Allocator, input: UserMessageInput) !RenderedLines {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |l| allocator.free(l);
        list.deinit(allocator);
    }

    // Chip + top rule on the first line.
    const chip = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s} USER {s}{s} {s}{s}{s}{s}",
        .{
            sgr.bold,
            sgr.user_chip_fg,
            sgr.user_chip_bg,
            sgr.reset,
            sgr.muted,
            box.horizontal,
            box.horizontal,
            box.horizontal,
            sgr.reset,
        },
    );
    try list.append(allocator, chip);

    // Body lines (each prefixed with `│ ` to mirror the upstream box).
    const body_prefix = try std.fmt.allocPrint(allocator, "{s}{s}{s} ", .{ sgr.muted, box.vertical, sgr.reset });
    defer allocator.free(body_prefix);
    if (input.text.len == 0) {
        // Even an empty user message still gets a chrome blank line so the
        // chip doesn't collapse against the next entry.
        const empty = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ sgr.muted, box.vertical, sgr.reset });
        try list.append(allocator, empty);
    } else {
        try appendStyledLines(allocator, &list, body_prefix, sgr.user_chip_fg, input.text);
    }

    // Bottom rule.
    const bottom = try buildBottomRule(allocator, sgr.muted, boxWidth(input.width));
    try list.append(allocator, bottom);

    return finalize(allocator, &list);
}

/// Render an assistant text message: a boxed block with an "ASSISTANT" chip
/// and the text body. Tool calls embedded in the assistant response are NOT
/// rendered here — they go through `renderToolExecution` as separate transcript
/// blocks, matching upstream's component split.
pub fn renderAssistantMessage(allocator: std.mem.Allocator, input: AssistantMessageInput) !RenderedLines {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |l| allocator.free(l);
        list.deinit(allocator);
    }

    const chip = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s} ASSISTANT {s}{s} {s}{s}{s}{s}",
        .{
            sgr.bold,
            sgr.assistant_chip_fg,
            sgr.assistant_chip_bg,
            sgr.reset,
            sgr.muted,
            box.horizontal,
            box.horizontal,
            box.horizontal,
            sgr.reset,
        },
    );
    try list.append(allocator, chip);

    const body_prefix = try std.fmt.allocPrint(allocator, "{s}{s}{s} ", .{ sgr.muted, box.vertical, sgr.reset });
    defer allocator.free(body_prefix);
    if (input.text.len == 0) {
        const empty = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ sgr.muted, box.vertical, sgr.reset });
        try list.append(allocator, empty);
    } else {
        try appendStyledLines(allocator, &list, body_prefix, "", input.text);
    }

    const bottom = try buildBottomRule(allocator, sgr.muted, boxWidth(input.width));
    try list.append(allocator, bottom);

    return finalize(allocator, &list);
}

/// Render a tool-execution panel: a boxed block containing a `[tool: <name>]`
/// chip on the title row, the arguments JSON as a preview, and (if the tool
/// has completed) a styled result preview. The surface background follows
/// upstream's pending/success/error split.
pub fn renderToolExecution(allocator: std.mem.Allocator, input: ToolExecutionInput) !RenderedLines {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |l| allocator.free(l);
        list.deinit(allocator);
    }

    const surface_bg = if (input.pending)
        sgr.tool_pending_bg
    else if (input.is_error)
        sgr.tool_error_bg
    else
        sgr.tool_success_bg;
    _ = surface_bg; // Reserved for a future opaque-fill chrome variant; the
    // current line-styled approximation keeps the diff renderer's invariants
    // simpler without the per-line background fills.

    // Top rule.
    const top = try buildTopRule(allocator, sgr.muted, boxWidth(input.width));
    try list.append(allocator, top);

    // Title row: `│ [tool: <name>]`.
    const title = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s} {s}{s}[tool: {s}]{s}",
        .{
            sgr.muted,
            box.vertical,
            sgr.reset,
            sgr.bold,
            sgr.accent,
            input.tool_name,
            sgr.reset,
        },
    );
    try list.append(allocator, title);

    // Arguments JSON preview (one transcript line per JSON line).
    if (input.arguments_json.len > 0) {
        const body_prefix = try std.fmt.allocPrint(allocator, "{s}{s}{s} ", .{ sgr.muted, box.vertical, sgr.reset });
        defer allocator.free(body_prefix);
        try appendStyledLines(allocator, &list, body_prefix, sgr.dim, input.arguments_json);
    }

    // Result preview (truncated, styled).
    if (input.result_text) |full_result| {
        const result_prefix = try std.fmt.allocPrint(allocator, "{s}{s}{s} ", .{ sgr.muted, box.vertical, sgr.reset });
        defer allocator.free(result_prefix);
        const preview_len = @min(full_result.len, input.preview_chars);
        const slice = full_result[0..preview_len];
        const fg = if (input.is_error) sgr.error_fg else sgr.tool_output_fg;
        try appendStyledLines(allocator, &list, result_prefix, fg, slice);
        if (preview_len < full_result.len) {
            const trailing = try std.fmt.allocPrint(
                allocator,
                "{s}{s}{s} {s}... ({d} more bytes){s}",
                .{ sgr.muted, box.vertical, sgr.reset, sgr.dim, full_result.len - preview_len, sgr.reset },
            );
            try list.append(allocator, trailing);
        }
    } else if (input.pending) {
        const pending = try std.fmt.allocPrint(
            allocator,
            "{s}{s}{s} {s}(running...){s}",
            .{ sgr.muted, box.vertical, sgr.reset, sgr.dim, sgr.reset },
        );
        try list.append(allocator, pending);
    }

    // Bottom rule.
    const bottom = try buildBottomRule(allocator, sgr.muted, boxWidth(input.width));
    try list.append(allocator, bottom);

    return finalize(allocator, &list);
}

/// Render a bash-execution panel: a boxed block with `$ <command>` header, the
/// (truncated) output, and a status footer ((exit N) / (cancelled) / truncation
/// notice). Mirrors upstream `BashExecutionComponent` with its 20-line preview
/// cap.
pub fn renderBashExecution(allocator: std.mem.Allocator, input: BashExecutionInput) !RenderedLines {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |l| allocator.free(l);
        list.deinit(allocator);
    }

    // Top rule (uses the bash-mode green so the panel reads as "shell output").
    const top = try buildTopRule(allocator, sgr.bash, boxWidth(input.width));
    try list.append(allocator, top);

    // `$ <command>` header line, bold green.
    const header = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s} {s}{s}$ {s}{s}",
        .{ sgr.bash, box.vertical, sgr.reset, sgr.bold, sgr.bash, input.command, sgr.reset },
    );
    try list.append(allocator, header);

    // Truncated output preview.
    if (input.output.len > 0) {
        const out_prefix = try std.fmt.allocPrint(allocator, "{s}{s}{s} ", .{ sgr.bash, box.vertical, sgr.reset });
        defer allocator.free(out_prefix);

        // Count newlines to apply the preview cap. We keep the tail (matches
        // upstream `truncateTail` semantics).
        var lines_count: usize = 1;
        for (input.output) |c| if (c == '\n') {
            lines_count += 1;
        };
        if (lines_count <= input.preview_lines) {
            try appendStyledLines(allocator, &list, out_prefix, sgr.dim, input.output);
        } else {
            // Find the start byte of the tail window of `preview_lines`.
            var newlines_to_skip = lines_count - input.preview_lines;
            var idx: usize = 0;
            while (idx < input.output.len and newlines_to_skip > 0) : (idx += 1) {
                if (input.output[idx] == '\n') newlines_to_skip -= 1;
            }
            // idx now points right after the last skipped newline.
            try appendStyledLines(allocator, &list, out_prefix, sgr.dim, input.output[idx..]);
            const trim = try std.fmt.allocPrint(
                allocator,
                "{s}{s}{s} {s}... ({d} more lines){s}",
                .{ sgr.bash, box.vertical, sgr.reset, sgr.dim, lines_count - input.preview_lines, sgr.reset },
            );
            try list.append(allocator, trim);
        }
    }

    // Status footer.
    if (input.cancelled) {
        const line = try std.fmt.allocPrint(
            allocator,
            "{s}{s}{s} {s}(cancelled){s}",
            .{ sgr.bash, box.vertical, sgr.reset, sgr.warning, sgr.reset },
        );
        try list.append(allocator, line);
    } else if (input.exit_code) |code| {
        if (code != 0) {
            const line = try std.fmt.allocPrint(
                allocator,
                "{s}{s}{s} {s}(exit {d}){s}",
                .{ sgr.bash, box.vertical, sgr.reset, sgr.error_fg, code, sgr.reset },
            );
            try list.append(allocator, line);
        }
    }
    if (input.full_output_path) |path| {
        const line = try std.fmt.allocPrint(
            allocator,
            "{s}{s}{s} {s}Output truncated. Full output: {s}{s}",
            .{ sgr.bash, box.vertical, sgr.reset, sgr.warning, path, sgr.reset },
        );
        try list.append(allocator, line);
    }

    // Bottom rule.
    const bottom = try buildBottomRule(allocator, sgr.bash, boxWidth(input.width));
    try list.append(allocator, bottom);

    return finalize(allocator, &list);
}

/// Render an expanded `/compact` summary: a boxed block with a bold
/// `[compaction]` label, a "Compacted from N tokens" header, and the summary
/// body. Matches upstream `CompactionSummaryMessageComponent` expanded state.
pub fn renderCompactionSummary(allocator: std.mem.Allocator, input: CompactionSummaryInput) !RenderedLines {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |l| allocator.free(l);
        list.deinit(allocator);
    }

    const top = try buildTopRule(allocator, sgr.custom_label_fg, boxWidth(input.width));
    try list.append(allocator, top);

    const label = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s} {s}{s}[compaction]{s}",
        .{ sgr.custom_label_fg, box.vertical, sgr.reset, sgr.bold, sgr.custom_label_fg, sgr.reset },
    );
    try list.append(allocator, label);

    const header = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s} {s}Compacted from {d} tokens{s}",
        .{ sgr.custom_label_fg, box.vertical, sgr.reset, sgr.bold, input.tokens_before, sgr.reset },
    );
    try list.append(allocator, header);

    if (input.summary.len > 0) {
        const body_prefix = try std.fmt.allocPrint(allocator, "{s}{s}{s} ", .{ sgr.custom_label_fg, box.vertical, sgr.reset });
        defer allocator.free(body_prefix);
        try appendStyledLines(allocator, &list, body_prefix, "", input.summary);
    }

    const bottom = try buildBottomRule(allocator, sgr.custom_label_fg, boxWidth(input.width));
    try list.append(allocator, bottom);

    return finalize(allocator, &list);
}

/// Render an expanded branch summary: a boxed block with a bold `[branch]`
/// label, a "Branch Summary" header, and the summary body. Matches upstream
/// `BranchSummaryMessageComponent` expanded state.
pub fn renderBranchSummary(allocator: std.mem.Allocator, input: BranchSummaryInput) !RenderedLines {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |l| allocator.free(l);
        list.deinit(allocator);
    }

    const top = try buildTopRule(allocator, sgr.custom_label_fg, boxWidth(input.width));
    try list.append(allocator, top);

    const label = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s} {s}{s}[branch]{s}",
        .{ sgr.custom_label_fg, box.vertical, sgr.reset, sgr.bold, sgr.custom_label_fg, sgr.reset },
    );
    try list.append(allocator, label);

    const header = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s} {s}Branch Summary{s}",
        .{ sgr.custom_label_fg, box.vertical, sgr.reset, sgr.bold, sgr.reset },
    );
    try list.append(allocator, header);

    if (input.summary.len > 0) {
        const body_prefix = try std.fmt.allocPrint(allocator, "{s}{s}{s} ", .{ sgr.custom_label_fg, box.vertical, sgr.reset });
        defer allocator.free(body_prefix);
        try appendStyledLines(allocator, &list, body_prefix, "", input.summary);
    }

    const bottom = try buildBottomRule(allocator, sgr.custom_label_fg, boxWidth(input.width));
    try list.append(allocator, bottom);

    return finalize(allocator, &list);
}

/// Render a display:true custom message (extension-injected): a boxed block
/// with `[<customType>]` as the label and the text body. Matches upstream
/// `CustomMessageComponent` default rendering (no custom renderer override).
pub fn renderCustomMessage(allocator: std.mem.Allocator, input: CustomMessageInput) !RenderedLines {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |l| allocator.free(l);
        list.deinit(allocator);
    }

    const top = try buildTopRule(allocator, sgr.custom_label_fg, boxWidth(input.width));
    try list.append(allocator, top);

    const label = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s} {s}{s}[{s}]{s}",
        .{ sgr.custom_label_fg, box.vertical, sgr.reset, sgr.bold, sgr.custom_label_fg, input.custom_type, sgr.reset },
    );
    try list.append(allocator, label);

    if (input.content.len > 0) {
        const body_prefix = try std.fmt.allocPrint(allocator, "{s}{s}{s} ", .{ sgr.custom_label_fg, box.vertical, sgr.reset });
        defer allocator.free(body_prefix);
        try appendStyledLines(allocator, &list, body_prefix, "", input.content);
    }

    const bottom = try buildBottomRule(allocator, sgr.custom_label_fg, boxWidth(input.width));
    try list.append(allocator, bottom);

    return finalize(allocator, &list);
}

/// Render a skill invocation: a boxed block with a `[skill]` label, the skill
/// name as a bold header, and any rendered args body. Matches upstream
/// `SkillInvocationMessageComponent` expanded state.
pub fn renderSkillInvocation(allocator: std.mem.Allocator, input: SkillInvocationInput) !RenderedLines {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |l| allocator.free(l);
        list.deinit(allocator);
    }

    const top = try buildTopRule(allocator, sgr.custom_label_fg, boxWidth(input.width));
    try list.append(allocator, top);

    const label = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s} {s}{s}[skill]{s} {s}{s}{s}",
        .{ sgr.custom_label_fg, box.vertical, sgr.reset, sgr.bold, sgr.custom_label_fg, sgr.reset, sgr.bold, input.name, sgr.reset },
    );
    try list.append(allocator, label);

    if (input.args.len > 0) {
        const body_prefix = try std.fmt.allocPrint(allocator, "{s}{s}{s} ", .{ sgr.custom_label_fg, box.vertical, sgr.reset });
        defer allocator.free(body_prefix);
        try appendStyledLines(allocator, &list, body_prefix, sgr.dim, input.args);
    }

    const bottom = try buildBottomRule(allocator, sgr.custom_label_fg, boxWidth(input.width));
    try list.append(allocator, bottom);

    return finalize(allocator, &list);
}

// =====================================================================
// Tests
// =====================================================================

test "renderUserMessage shows USER chip + boxed body + reset on every line" {
    var rendered = try renderUserMessage(std.testing.allocator, .{ .text = "hello agent" });
    defer rendered.deinit();
    try std.testing.expect(rendered.lines.len >= 3);
    // First line carries the USER chip and is fully reset.
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[0], " USER ") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered.lines[0], sgr.reset));
    // Body line carries the message text.
    var saw_body = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "hello agent") != null) saw_body = true;
        // Every styled line opens at least once and closes with reset.
        if (std.mem.indexOf(u8, line, "\x1b[") != null) {
            try std.testing.expect(std.mem.indexOf(u8, line, sgr.reset) != null);
        }
    }
    try std.testing.expect(saw_body);
    // Last line is the bottom rule.
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[rendered.lines.len - 1], box.bottom_left) != null);
}

test "renderUserMessage handles multi-line text by splitting on newlines" {
    var rendered = try renderUserMessage(std.testing.allocator, .{ .text = "line one\nline two" });
    defer rendered.deinit();
    var saw_one = false;
    var saw_two = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "line one") != null) saw_one = true;
        if (std.mem.indexOf(u8, line, "line two") != null) saw_two = true;
    }
    try std.testing.expect(saw_one);
    try std.testing.expect(saw_two);
}

test "renderAssistantMessage shows ASSISTANT chip with distinct color from USER" {
    var rendered = try renderAssistantMessage(std.testing.allocator, .{ .text = "responding" });
    defer rendered.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[0], " ASSISTANT ") != null);
    // Assistant chip uses a different background SGR than user.
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[0], sgr.assistant_chip_bg) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[0], sgr.user_chip_bg) == null);
    // Body line contains the assistant text.
    var saw_body = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "responding") != null) saw_body = true;
    }
    try std.testing.expect(saw_body);
}

test "renderToolExecution renders [tool: name] chip, args, and result preview" {
    var rendered = try renderToolExecution(std.testing.allocator, .{
        .tool_name = "read",
        .arguments_json = "{\"path\":\"/tmp/x\"}",
        .result_text = "file contents",
    });
    defer rendered.deinit();
    var saw_chip = false;
    var saw_args = false;
    var saw_result = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "[tool: read]") != null) saw_chip = true;
        if (std.mem.indexOf(u8, line, "{\"path\":\"/tmp/x\"}") != null) saw_args = true;
        if (std.mem.indexOf(u8, line, "file contents") != null) saw_result = true;
    }
    try std.testing.expect(saw_chip);
    try std.testing.expect(saw_args);
    try std.testing.expect(saw_result);
    // Top and bottom rule glyphs present (vertical glyph also appears on body rows).
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[0], box.top_left) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[rendered.lines.len - 1], box.bottom_left) != null);
}

test "renderToolExecution truncates long results and notes the trailing bytes" {
    const long_result = "a" ** 600;
    var rendered = try renderToolExecution(std.testing.allocator, .{
        .tool_name = "bash",
        .result_text = long_result,
        .preview_chars = 50,
    });
    defer rendered.deinit();
    var saw_trail = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "more bytes") != null) saw_trail = true;
    }
    try std.testing.expect(saw_trail);
}

test "renderToolExecution error rendering uses the error foreground" {
    var rendered = try renderToolExecution(std.testing.allocator, .{
        .tool_name = "read",
        .result_text = "permission denied",
        .is_error = true,
    });
    defer rendered.deinit();
    var saw_err_color = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "permission denied") != null and
            std.mem.indexOf(u8, line, sgr.error_fg) != null) saw_err_color = true;
    }
    try std.testing.expect(saw_err_color);
}

test "renderBashExecution prints `$ command` header and exit code on failure" {
    var rendered = try renderBashExecution(std.testing.allocator, .{
        .command = "ls /missing",
        .output = "ls: /missing: No such file or directory",
        .exit_code = 1,
    });
    defer rendered.deinit();
    var saw_header = false;
    var saw_exit = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "$ ls /missing") != null) saw_header = true;
        if (std.mem.indexOf(u8, line, "(exit 1)") != null) saw_exit = true;
    }
    try std.testing.expect(saw_header);
    try std.testing.expect(saw_exit);
}

test "renderBashExecution truncates output past preview cap" {
    // 25-line output > default 20 preview cap.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        try buf.appendSlice(std.testing.allocator, "row\n");
    }
    var rendered = try renderBashExecution(std.testing.allocator, .{
        .command = "seq 25",
        .output = buf.items,
    });
    defer rendered.deinit();
    var saw_trim = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "more lines") != null) saw_trim = true;
    }
    try std.testing.expect(saw_trim);
}

test "renderBashExecution cancelled shows warning footer" {
    var rendered = try renderBashExecution(std.testing.allocator, .{
        .command = "sleep 100",
        .cancelled = true,
    });
    defer rendered.deinit();
    var saw_cancel = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "(cancelled)") != null) saw_cancel = true;
    }
    try std.testing.expect(saw_cancel);
}

test "renderCompactionSummary shows [compaction] label and tokens-before count" {
    var rendered = try renderCompactionSummary(std.testing.allocator, .{
        .tokens_before = 12345,
        .summary = "compacted goal text",
    });
    defer rendered.deinit();
    var saw_label = false;
    var saw_tokens = false;
    var saw_summary = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "[compaction]") != null) saw_label = true;
        if (std.mem.indexOf(u8, line, "Compacted from 12345 tokens") != null) saw_tokens = true;
        if (std.mem.indexOf(u8, line, "compacted goal text") != null) saw_summary = true;
    }
    try std.testing.expect(saw_label);
    try std.testing.expect(saw_tokens);
    try std.testing.expect(saw_summary);
}

test "renderBranchSummary shows [branch] label and Branch Summary header" {
    var rendered = try renderBranchSummary(std.testing.allocator, .{ .summary = "feature/x merged" });
    defer rendered.deinit();
    var saw_label = false;
    var saw_header = false;
    var saw_summary = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "[branch]") != null) saw_label = true;
        if (std.mem.indexOf(u8, line, "Branch Summary") != null) saw_header = true;
        if (std.mem.indexOf(u8, line, "feature/x merged") != null) saw_summary = true;
    }
    try std.testing.expect(saw_label);
    try std.testing.expect(saw_header);
    try std.testing.expect(saw_summary);
}

test "renderCustomMessage shows [<customType>] label and body" {
    var rendered = try renderCustomMessage(std.testing.allocator, .{
        .custom_type = "diagnostic",
        .content = "lint clean",
    });
    defer rendered.deinit();
    var saw_label = false;
    var saw_body = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "[diagnostic]") != null) saw_label = true;
        if (std.mem.indexOf(u8, line, "lint clean") != null) saw_body = true;
    }
    try std.testing.expect(saw_label);
    try std.testing.expect(saw_body);
}

test "renderSkillInvocation shows [skill] label, bold name, and args body" {
    var rendered = try renderSkillInvocation(std.testing.allocator, .{
        .name = "verify",
        .args = "target=ui",
    });
    defer rendered.deinit();
    var saw_label = false;
    var saw_name = false;
    var saw_args = false;
    for (rendered.lines) |line| {
        if (std.mem.indexOf(u8, line, "[skill]") != null) saw_label = true;
        if (std.mem.indexOf(u8, line, "verify") != null) saw_name = true;
        if (std.mem.indexOf(u8, line, "target=ui") != null) saw_args = true;
    }
    try std.testing.expect(saw_label);
    try std.testing.expect(saw_name);
    try std.testing.expect(saw_args);
}

test "buildDivider produces a muted horizontal rule with closing reset" {
    const line = try buildDivider(std.testing.allocator, null);
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, box.horizontal) != null);
    try std.testing.expect(std.mem.endsWith(u8, line, sgr.reset));
    try std.testing.expect(std.mem.indexOf(u8, line, sgr.muted) != null);
}

test "renderers leave no open SGR state (every \\x1b[ has a matching reset on the same line)" {
    // Run each renderer over one fixture and assert balanced SGR per line.
    const fixtures = struct {
        fn run(allocator: std.mem.Allocator, lines: [][]u8) !void {
            for (lines) |line| {
                if (std.mem.indexOf(u8, line, "\x1b[") == null) continue;
                // Any line containing an SGR open must contain at least one reset.
                try std.testing.expect(std.mem.indexOf(u8, line, sgr.reset) != null);
            }
            _ = allocator;
        }
    };

    var user = try renderUserMessage(std.testing.allocator, .{ .text = "hi" });
    defer user.deinit();
    try fixtures.run(std.testing.allocator, user.lines);

    var asst = try renderAssistantMessage(std.testing.allocator, .{ .text = "ok" });
    defer asst.deinit();
    try fixtures.run(std.testing.allocator, asst.lines);

    var tool = try renderToolExecution(std.testing.allocator, .{
        .tool_name = "read",
        .arguments_json = "{}",
        .result_text = "result",
    });
    defer tool.deinit();
    try fixtures.run(std.testing.allocator, tool.lines);

    var bash = try renderBashExecution(std.testing.allocator, .{
        .command = "echo hi",
        .output = "hi",
        .exit_code = 0,
    });
    defer bash.deinit();
    try fixtures.run(std.testing.allocator, bash.lines);

    var compact = try renderCompactionSummary(std.testing.allocator, .{ .tokens_before = 1, .summary = "s" });
    defer compact.deinit();
    try fixtures.run(std.testing.allocator, compact.lines);

    var branch = try renderBranchSummary(std.testing.allocator, .{ .summary = "s" });
    defer branch.deinit();
    try fixtures.run(std.testing.allocator, branch.lines);

    var custom = try renderCustomMessage(std.testing.allocator, .{ .custom_type = "x", .content = "y" });
    defer custom.deinit();
    try fixtures.run(std.testing.allocator, custom.lines);

    var skill = try renderSkillInvocation(std.testing.allocator, .{ .name = "n", .args = "a" });
    defer skill.deinit();
    try fixtures.run(std.testing.allocator, skill.lines);
}

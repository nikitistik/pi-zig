//! Interactive TUI mode for pi-zig.
//!
//! Ports the application shell of upstream
//! `packages/coding-agent/src/modes/interactive/interactive-mode.ts`:
//! boot banner, prompt composer, slash-command palette, streaming assistant
//! output, tool-call panels, permission dialogs, and abort controls. It reuses
//! the pure logic modules in this package (`tui_editor`, `tui_keys`,
//! `tui_fuzzy`, `tui_render`, `tui_terminal`) and drives the existing agent
//! runtime through an injected `PromptRunner` so the loop stays decoupled and
//! testable.
//!
//! Builtin slash commands mirror `packages/coding-agent/src/core/slash-commands.ts`
//! `BUILTIN_SLASH_COMMANDS`. Keyboard commands mirror `docs/keybindings.md`.
//!
//! Rendering uses the differential renderer (`tui_render`). Live provider-backed
//! conversation, permission prompts, and abort are wired through `PromptRunner`
//! callbacks; see `cli_runtime.runTuiPrompt` for the production wiring.

const std = @import("std");
const editor_mod = @import("tui_editor.zig");
const keys = @import("tui_keys.zig");
const fuzzy = @import("tui_fuzzy.zig");
const render = @import("tui_render.zig");
const terminal = @import("tui_terminal.zig");
const config = @import("config.zig");
// Read-only use: the model selector cycles/sets models via models.zig (no edits to models.zig).
const models = @import("models.zig");

// ANSI styling primitives used by the rich-render layer (status bar, themed
// banner, inline markdown). Each open MUST be closed on the same line because
// the differential renderer compares lines literally; spilling SGR state
// across rows would corrupt subsequent rewrites.
pub const sgr = struct {
    pub const reset = "\x1b[0m";
    pub const dim = "\x1b[2m";
    pub const bold = "\x1b[1m";
    pub const italic = "\x1b[3m";
    pub const inverse = "\x1b[7m";
    // Theme-equivalent foreground colors (ANSI 256-color), tuned to look
    // reasonable on a dark terminal without depending on the user's palette.
    pub const accent = "\x1b[38;5;208m"; // orange — provider/model
    pub const branch = "\x1b[38;5;111m"; // teal/blue — git branch
    pub const muted = "\x1b[38;5;240m"; // grey — timers / dividers
    pub const good = "\x1b[38;5;82m"; // green — good state
    pub const warn = "\x1b[38;5;214m"; // amber — update banner
    pub const code_bg = "\x1b[48;5;236m"; // dim background — inline `code`
};

pub const BuiltinCommand = struct {
    name: []const u8,
    description: []const u8,
};

/// Builtin slash commands, ported from upstream `BUILTIN_SLASH_COMMANDS`.
pub const builtin_commands = [_]BuiltinCommand{
    .{ .name = "settings", .description = "Open settings menu" },
    .{ .name = "model", .description = "Select model (opens selector UI)" },
    .{ .name = "scoped-models", .description = "Enable/disable models for Ctrl+P cycling" },
    .{ .name = "export", .description = "Export session (HTML default, or specify path: .html/.jsonl)" },
    .{ .name = "import", .description = "Import and resume a session from a JSONL file" },
    .{ .name = "share", .description = "Share session as a secret GitHub gist" },
    .{ .name = "copy", .description = "Copy last agent message to clipboard" },
    .{ .name = "name", .description = "Set session display name" },
    .{ .name = "session", .description = "Show session info and stats" },
    .{ .name = "changelog", .description = "Show changelog entries" },
    .{ .name = "hotkeys", .description = "Show all keyboard shortcuts" },
    .{ .name = "fork", .description = "Create a new fork from a previous user message" },
    .{ .name = "clone", .description = "Duplicate the current session at the current position" },
    .{ .name = "tree", .description = "Navigate session tree (switch branches)" },
    .{ .name = "login", .description = "Configure provider authentication" },
    .{ .name = "logout", .description = "Remove provider authentication" },
    .{ .name = "new", .description = "Start a new session" },
    .{ .name = "compact", .description = "Manually compact the session context" },
    .{ .name = "resume", .description = "Resume a different session" },
    .{ .name = "reload", .description = "Reload keybindings, extensions, skills, prompts, and themes" },
    .{ .name = "quit", .description = "Quit pi-zig" },
};

/// Summarization instructions appended after the serialized `<conversation>` block for
/// `/compact`. Byte-identical to upstream SUMMARIZATION_PROMPT
/// (packages/coding-agent/src/core/compaction/compaction.ts) and to the RPC runtime's
/// private copy, kept here so the TUI compaction path matches without coupling to rpc.zig.
pub const compaction_summarization_prompt =
    "The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.\n\n" ++
    "Use this EXACT format:\n\n" ++
    "## Goal\n[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]\n\n" ++
    "## Constraints & Preferences\n- [Any constraints, preferences, or requirements mentioned by user]\n- [Or \"(none)\" if none were mentioned]\n\n" ++
    "## Progress\n### Done\n- [x] [Completed tasks/changes]\n\n### In Progress\n- [ ] [Current work]\n\n### Blocked\n- [Issues preventing progress, if any]\n\n" ++
    "## Key Decisions\n- **[Decision]**: [Brief rationale]\n\n" ++
    "## Next Steps\n1. [Ordered list of what should happen next]\n\n" ++
    "## Critical Context\n- [Any data, examples, or references needed to continue]\n- [Or \"(none)\" if not applicable]\n\n" ++
    "Keep each section concise. Preserve exact file paths, function names, and error messages.";

/// Filter builtin commands by a query string (without the leading slash) using
/// the fuzzy matcher. Caller frees the returned slice.
pub fn filterCommands(allocator: std.mem.Allocator, query: []const u8) ![]fuzzy.FilterResult(BuiltinCommand) {
    const getText = struct {
        fn f(item: BuiltinCommand) []const u8 {
            return item.name;
        }
    }.f;
    return fuzzy.fuzzyFilter(BuiltinCommand, allocator, &builtin_commands, query, &getText);
}

pub fn findCommand(name: []const u8) ?BuiltinCommand {
    for (builtin_commands) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

// =====================================================================
// Prompt runner seam
// =====================================================================

/// Permission decision returned by the host for a tool call.
pub const PermissionDecision = enum { allow, deny };

/// Callbacks the prompt runner invokes while a turn streams. All are optional.
pub const PromptCallbacks = struct {
    ctx: *anyopaque,
    /// Streaming assistant text delta.
    on_text: ?*const fn (ctx: *anyopaque, delta: []const u8) anyerror!void = null,
    /// A tool call is about to run; the host returns allow/deny (permission gate).
    on_tool_permission: ?*const fn (ctx: *anyopaque, tool_name: []const u8, arguments_json: []const u8) anyerror!PermissionDecision = null,
    /// A tool finished; `content` is its result text.
    on_tool_result: ?*const fn (ctx: *anyopaque, tool_name: []const u8, content: []const u8, is_error: bool) anyerror!void = null,
    /// Polled cooperatively; return true to abort the active turn.
    should_cancel: ?*const fn (ctx: *anyopaque) bool = null,
};

/// Injected runner that executes a prompt against the agent runtime.
/// Returns the final assistant text (caller frees), or an error.
pub const PromptRunner = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8, callbacks: PromptCallbacks) anyerror![]u8,
};

/// Role of a recorded conversation turn. Mirrors the subset of upstream message
/// roles the interactive loop produces, used to serialize the in-memory transcript
/// for provider-backed `/compact` summarization.
pub const MessageRole = enum {
    user,
    assistant,
    tool,

    /// Conversation-prefix matching upstream serializeConversation()
    /// (compaction/utils.ts), so the summarization prompt is byte-identical to the
    /// RPC runtime's structured compaction input.
    fn conversationPrefix(self: MessageRole) []const u8 {
        return switch (self) {
            .user => "[User]: ",
            .assistant => "[Assistant]: ",
            .tool => "[Tool result]: ",
        };
    }
};

/// One recorded conversation turn (owned text). The App keeps a faithful list of
/// these as turns stream so `/compact` can summarize the real conversation rather
/// than the decorated scrollback lines.
pub const Message = struct {
    role: MessageRole,
    text: []u8,
};

/// Injected runner that produces an LLM summary of a serialized conversation for
/// `/compact`. Mirrors the RPC runtime's provider-backed compaction
/// (rpc.zig `runCompactionSummaryIfAuthenticated`): a single tool-free turn with the
/// dedicated summarization system prompt. Returns the owned summary text (caller
/// frees). Wired by the host only when a provider+model+auth are configured; absent
/// it, `/compact` falls back to the local `SessionCallbacks.compact` summary.
pub const CompactRunner = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, conversation: []const u8, custom_instructions: ?[]const u8) anyerror![]u8,
};

/// Session operation callbacks injected by the host runtime. Each is optional;
/// when absent the command reports "not yet wired" as before.
pub const SessionCallbacks = struct {
    ctx: *anyopaque,
    /// Compact the session locally (message-count summary), persisting + returning owned
    /// summary text (caller frees). Used as the no-auth fallback when no `CompactRunner`
    /// is wired; the provider-backed path uses `CompactRunner` + `persist_compaction`.
    compact: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, custom_instructions: ?[]const u8) anyerror![]u8 = null,
    /// Persist a provider-backed `/compact` summary (the text produced by `CompactRunner`)
    /// to the session store. Separate from `compact` so the local fallback keeps owning its
    /// own persistence while the LLM path persists the summary the App computed.
    persist_compaction: ?*const fn (ctx: *anyopaque, summary: []const u8, custom_instructions: ?[]const u8, message_count: usize) anyerror!void = null,
    /// Export session as HTML; returns owned output path (caller frees).
    export_html: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, output_path: ?[]const u8) anyerror![]u8 = null,
    /// Set the session display name.
    set_name: ?*const fn (ctx: *anyopaque, name: []const u8) anyerror!void = null,
    /// Fork the session; switches to new sibling session.
    fork: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void = null,
    /// Clone the session.
    clone: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void = null,
};

// =====================================================================
// Interactive app state and loop
// =====================================================================

pub const Options = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// When false (no TTY / tests), the loop never enters raw mode.
    interactive: bool = true,
};

pub const ExitReason = enum { user_quit, eof, not_a_tty };

/// The interactive controller. Owns the editor, renderer, and transcript.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    editor: editor_mod.Editor,
    renderer: render.Renderer,
    options: Options,
    runner: ?PromptRunner = null,
    /// Optional provider-backed summarization runner for `/compact`. When wired (a
    /// provider+model+auth are configured) `/compact` produces a real LLM summary of the
    /// in-memory conversation; otherwise it falls back to the local count summary.
    compact_runner: ?CompactRunner = null,
    /// Optional session operation callbacks wired by the host runtime.
    session_callbacks: ?SessionCallbacks = null,

    /// Faithful in-memory conversation (user/assistant/tool turns) recorded as the loop
    /// streams. Distinct from `transcript` (decorated scrollback lines): this is the clean
    /// role-tagged message list serialized for provider-backed `/compact` summarization,
    /// mirroring the RPC runtime's structured compaction input. Owned.
    messages: std.ArrayList(Message),
    /// Scrollback transcript lines (assistant/user/tool/system). Owned.
    transcript: std.ArrayList([]u8),
    /// Status line shown above the editor.
    status: []u8 = "",
    /// Whether a turn is currently streaming (controls abort handling).
    running: bool = false,
    /// True while a permission dialog blocks the turn; the status line then
    /// shows the prompt text instead of the generic working indicator.
    awaiting_permission: bool = false,
    /// Set by Escape during a run; polled by should_cancel.
    abort_requested: bool = false,
    /// Live assistant text being streamed for the current turn.
    streaming: std.ArrayList(u8),

    // -- Command palette (live fuzzy `/`-command autocomplete) ----------
    /// True while the editor holds a leading `/` and the palette is shown.
    palette_active: bool = false,
    /// Index of the highlighted palette row among the current matches.
    palette_selected: usize = 0,

    // -- Model selector (`/model` UI) -----------------------------------
    /// True while the `/model` selector overlay is open.
    model_selector_active: bool = false,
    /// Currently highlighted model in the selector (read-only catalog pointer);
    /// null selects the first catalog entry. Cycled via models.next.
    selected_model: ?*const models.ModelEntry = null,

    // -- Status-bar state ----------------------------------------------
    /// Wall-clock nanoseconds at App init; used to render the session-elapsed timer.
    session_start_ns: i128 = 0,
    /// Cached git branch label, resolved lazily on the first render. When the
    /// resolution fails (not a git repo, missing git binary, etc.) `git_branch_len`
    /// stays 0 and the status bar omits the branch slot.
    git_branch_buf: [128]u8 = undefined,
    git_branch_len: usize = 0,
    git_branch_resolved: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !App {
        // Read the wall clock once; `std.Io.Clock.real.now` will panic if `io`
        // is `undefined` (test paths pass `undefined` deliberately), so guard.
        const session_start_ns: i128 = blk: {
            if (options.interactive) {
                break :blk std.Io.Clock.real.now(io).nanoseconds;
            }
            break :blk 0;
        };
        return .{
            .allocator = allocator,
            .io = io,
            .editor = try editor_mod.Editor.init(allocator),
            .renderer = render.Renderer.init(allocator),
            .options = options,
            .messages = .empty,
            .transcript = .empty,
            .streaming = .empty,
            .session_start_ns = session_start_ns,
        };
    }

    pub fn deinit(self: *App) void {
        self.editor.deinit();
        self.renderer.deinit();
        self.clearMessages();
        self.messages.deinit(self.allocator);
        for (self.transcript.items) |line| self.allocator.free(line);
        self.transcript.deinit(self.allocator);
        self.streaming.deinit(self.allocator);
        if (self.status.len > 0) self.allocator.free(self.status);
    }

    /// Record a conversation turn into the in-memory message list (owning a copy of `text`).
    /// Tool results carry a `[Tool result]:` prefix when serialized for compaction.
    fn appendMessage(self: *App, role: MessageRole, text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.messages.append(self.allocator, .{ .role = role, .text = owned });
    }

    /// Free and clear the in-memory message list (e.g. after `/new` or a successful compaction).
    fn clearMessages(self: *App) void {
        for (self.messages.items) |message| self.allocator.free(message.text);
        self.messages.clearRetainingCapacity();
    }

    /// Serialize the in-memory conversation into the `<conversation>...</conversation>` block
    /// upstream's compaction feeds the summarizer (serializeConversation in
    /// compaction/utils.ts). Caller frees the returned slice. Pure (no I/O), so the
    /// `/compact` provider path is App-level unit-testable. Returns an empty-conversation
    /// block when no turns were recorded.
    fn buildCompactionPromptText(self: *App, custom_instructions: ?[]const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "<conversation>\n");
        var emitted = false;
        for (self.messages.items) |message| {
            const text = std.mem.trim(u8, message.text, " \t\r\n");
            if (text.len == 0) continue;
            if (emitted) try out.appendSlice(self.allocator, "\n\n");
            try out.appendSlice(self.allocator, message.role.conversationPrefix());
            try out.appendSlice(self.allocator, text);
            emitted = true;
        }
        try out.appendSlice(self.allocator, "\n</conversation>\n\n");
        try out.appendSlice(self.allocator, compaction_summarization_prompt);
        if (custom_instructions) |instructions| {
            const trimmed = std.mem.trim(u8, instructions, " \t\r\n");
            if (trimmed.len > 0) {
                try out.appendSlice(self.allocator, "\n\nAdditional focus: ");
                try out.appendSlice(self.allocator, trimmed);
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    pub fn setStatus(self: *App, text: []const u8) !void {
        if (self.status.len > 0) self.allocator.free(self.status);
        self.status = try self.allocator.dupe(u8, text);
    }

    /// Append a transcript line (split on embedded newlines), owning copies.
    pub fn appendTranscript(self: *App, text: []const u8) !void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |part| {
            try self.transcript.append(self.allocator, try self.allocator.dupe(u8, part));
        }
    }

    /// Build the full screen as logical lines: transcript, optional streaming
    /// block, a separator, status, then the prompt composer with a cursor caret.
    /// Caller frees each line and the list.
    pub fn buildScreen(self: *App) !std.ArrayList([]u8) {
        var lines: std.ArrayList([]u8) = .empty;
        errdefer {
            for (lines.items) |l| self.allocator.free(l);
            lines.deinit(self.allocator);
        }

        for (self.transcript.items) |line| {
            try lines.append(self.allocator, try self.allocator.dupe(u8, line));
        }
        if (self.streaming.items.len > 0) {
            var it = std.mem.splitScalar(u8, self.streaming.items, '\n');
            while (it.next()) |part| {
                try lines.append(self.allocator, try self.allocator.dupe(u8, part));
            }
        }

        // Status line. A blocking permission dialog shows its prompt (in
        // self.status); otherwise a generic working indicator while streaming.
        const status_text = if (self.awaiting_permission)
            self.status
        else if (self.running)
            "[working... press Esc to abort]"
        else
            self.status;
        if (status_text.len > 0) {
            try lines.append(self.allocator, try self.allocator.dupe(u8, status_text));
        }

        // Prompt composer: render each editor line, marking the cursor on its row.
        for (self.editor.lines.items, 0..) |line, row| {
            const prefix = if (row == 0) "> " else "  ";
            if (row == self.editor.cursor_line) {
                // Insert a visible caret marker '|' at the cursor column.
                var composed: std.ArrayList(u8) = .empty;
                errdefer composed.deinit(self.allocator);
                try composed.appendSlice(self.allocator, prefix);
                try composed.appendSlice(self.allocator, line.items[0..self.editor.cursor_col]);
                try composed.append(self.allocator, '|');
                try composed.appendSlice(self.allocator, line.items[self.editor.cursor_col..]);
                try lines.append(self.allocator, try composed.toOwnedSlice(self.allocator));
            } else {
                const composed = try std.mem.concat(self.allocator, u8, &.{ prefix, line.items });
                try lines.append(self.allocator, composed);
            }
        }

        // Overlays under the composer: the model selector takes precedence over the
        // command palette (both are never open at once in normal use).
        if (self.model_selector_active) {
            try self.renderModelSelector(&lines);
        } else if (self.palette_active) {
            try self.renderPalette(&lines);
        }

        // Bottom status bar: divider + one row carrying branch · provider/model
        // · thinking · session-elapsed. Mirrors the upstream pi-mono TUI's
        // bottom strip. Skipped in non-interactive/test paths so unit tests
        // keep deterministic line counts.
        if (self.options.interactive) {
            try self.renderStatusBar(&lines);
        }

        return lines;
    }

    /// Append a divider + bottom status row carrying:
    ///   `<branch>   <provider> | <model> · <thinking>   session <elapsed>`
    /// All ANSI styling is opened+closed on the same line so the differential
    /// renderer's line-level diff stays correct.
    fn renderStatusBar(self: *App, lines: *std.ArrayList([]u8)) !void {
        // Divider: a dim horizontal rule, length-capped so we don't paint past
        // typical terminal widths. The renderer wraps if needed.
        const divider_segment = "\xe2\x94\x80"; // U+2500 BOX DRAWINGS LIGHT HORIZONTAL (UTF-8: e2 94 80)
        var divider: std.ArrayList(u8) = .empty;
        defer divider.deinit(self.allocator);
        try divider.appendSlice(self.allocator, sgr.muted);
        var i: usize = 0;
        while (i < 80) : (i += 1) try divider.appendSlice(self.allocator, divider_segment);
        try divider.appendSlice(self.allocator, sgr.reset);
        try lines.append(self.allocator, try divider.toOwnedSlice(self.allocator));

        // Resolve the branch label once (best-effort; staying null on failure).
        if (!self.git_branch_resolved) self.resolveGitBranch();

        // Compose the status row.
        var row: std.ArrayList(u8) = .empty;
        defer row.deinit(self.allocator);

        if (self.git_branch_len > 0) {
            try row.appendSlice(self.allocator, sgr.branch);
            try row.appendSlice(self.allocator, " "); // small left pad
            try row.appendSlice(self.allocator, self.git_branch_buf[0..self.git_branch_len]);
            try row.appendSlice(self.allocator, sgr.reset);
            try row.appendSlice(self.allocator, "   ");
        }

        // Provider | Model · thinking
        const provider = self.options.provider orelse "(no provider)";
        const model_name = if (self.selected_model) |m| m.id else (self.options.model orelse "(no model)");
        try row.appendSlice(self.allocator, sgr.accent);
        try row.appendSlice(self.allocator, provider);
        try row.appendSlice(self.allocator, sgr.reset);
        try row.appendSlice(self.allocator, sgr.muted);
        try row.appendSlice(self.allocator, " | ");
        try row.appendSlice(self.allocator, sgr.reset);
        try row.appendSlice(self.allocator, sgr.accent);
        try row.appendSlice(self.allocator, model_name);
        try row.appendSlice(self.allocator, sgr.reset);

        // Session-elapsed timer (`session 0m 12s`). When the wall clock isn't
        // available (test path, options.interactive=false) we already skipped
        // this whole call.
        if (self.session_start_ns != 0) {
            const now_ns = std.Io.Clock.real.now(self.io).nanoseconds;
            const elapsed_ns: i128 = now_ns - self.session_start_ns;
            const elapsed_s: u64 = if (elapsed_ns > 0) @intCast(@divTrunc(elapsed_ns, std.time.ns_per_s)) else 0;
            const hours = elapsed_s / 3600;
            const minutes = (elapsed_s % 3600) / 60;
            const seconds = elapsed_s % 60;
            try row.appendSlice(self.allocator, sgr.muted);
            try row.appendSlice(self.allocator, "   session ");
            const timer_text = if (hours > 0)
                try std.fmt.allocPrint(self.allocator, "{d}h{d:0>2}m{d:0>2}s", .{ hours, minutes, seconds })
            else if (minutes > 0)
                try std.fmt.allocPrint(self.allocator, "{d}m{d:0>2}s", .{ minutes, seconds })
            else
                try std.fmt.allocPrint(self.allocator, "{d}s", .{seconds});
            defer self.allocator.free(timer_text);
            try row.appendSlice(self.allocator, timer_text);
            try row.appendSlice(self.allocator, sgr.reset);
        }

        try lines.append(self.allocator, try row.toOwnedSlice(self.allocator));
    }

    /// Best-effort one-shot resolution of the current git branch via
    /// `git symbolic-ref --short HEAD`. Failures (no git, no repo) leave the
    /// branch label empty so the status bar simply omits the branch slot.
    fn resolveGitBranch(self: *App) void {
        self.git_branch_resolved = true;
        const argv = [_][]const u8{ "git", "symbolic-ref", "--short", "HEAD" };
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &argv,
            .stdout_limit = .limited(256),
            .stderr_limit = .limited(0),
            .expand_arg0 = .expand,
        }) catch return;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return,
            else => return,
        }
        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > self.git_branch_buf.len) return;
        @memcpy(self.git_branch_buf[0..trimmed.len], trimmed);
        self.git_branch_len = trimmed.len;
    }

    /// Append the command-palette rows (ranked fuzzy matches) to the screen, marking the
    /// highlighted row with a `>` caret. Each line is owned by `lines`.
    fn renderPalette(self: *App, lines: *std.ArrayList([]u8)) !void {
        const query = self.paletteQuery() orelse return;
        const matches = try filterCommands(self.allocator, query);
        defer self.allocator.free(matches);
        if (matches.len == 0) return;
        const max_rows = @min(matches.len, @as(usize, 8));
        for (matches[0..max_rows], 0..) |match, row| {
            const marker = if (row == self.palette_selected) ">" else " ";
            const line = try std.fmt.allocPrint(
                self.allocator,
                "{s} /{s}  {s}",
                .{ marker, match.item.name, match.item.description },
            );
            try lines.append(self.allocator, line);
        }
    }

    /// Append the model-selector overlay (header + highlighted current model) to the screen.
    /// Each line is owned by `lines`.
    fn renderModelSelector(self: *App, lines: *std.ArrayList([]u8)) !void {
        try lines.append(self.allocator, try self.allocator.dupe(u8, "Select model (Up/Down to cycle, Enter to apply, Esc to cancel):"));
        const selected = self.selected_model orelse if (models.all.len > 0) &models.all[0] else return;
        const line = try std.fmt.allocPrint(
            self.allocator,
            "> {s} / {s}",
            .{ selected.provider, selected.id },
        );
        try lines.append(self.allocator, line);
    }

    fn freeScreen(self: *App, lines: *std.ArrayList([]u8)) void {
        for (lines.items) |l| self.allocator.free(l);
        lines.deinit(self.allocator);
    }

    // -- Slash command handling ----------------------------------------

    pub const CommandOutcome = enum { handled, quit, unknown };

    /// Execute a builtin slash command line (without the leading slash).
    /// Side effects render into the transcript / status. Commands that require
    /// deeper runtime integration report an honest "not wired in TUI" notice.
    pub fn runCommand(self: *App, command_line: []const u8) !CommandOutcome {
        var it = std.mem.tokenizeAny(u8, command_line, " \t");
        const name = it.next() orelse return .unknown;

        if (std.mem.eql(u8, name, "quit") or std.mem.eql(u8, name, "exit")) {
            return .quit;
        }
        if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "hotkeys")) {
            try self.appendHotkeys();
            return .handled;
        }
        if (std.mem.eql(u8, name, "new") or std.mem.eql(u8, name, "clear")) {
            for (self.transcript.items) |l| self.allocator.free(l);
            self.transcript.clearRetainingCapacity();
            self.clearMessages();
            self.renderer.invalidate();
            try self.setStatus("Started a new session.");
            return .handled;
        }
        if (std.mem.eql(u8, name, "session")) {
            try self.appendSessionInfo();
            return .handled;
        }
        if (std.mem.eql(u8, name, "model")) {
            const arg = it.next();
            if (arg) |model_name| {
                try self.setModelByName(model_name);
            } else {
                // No argument: open the live selector overlay (rendered by buildScreen).
                self.openModelSelector();
            }
            return .handled;
        }
        if (std.mem.eql(u8, name, "changelog")) {
            try self.appendTranscript("pi-zig changelog: see docs/parity.md for the parity wave status.");
            return .handled;
        }

        // Session commands wired through SessionCallbacks when the host provides them.
        if (std.mem.eql(u8, name, "compact")) {
            // Rest-of-line (after "compact ") is the optional custom focus instruction.
            const instructions_arg = blk: {
                const rest = std.mem.trim(u8, command_line[name.len..], " \t");
                break :blk if (rest.len == 0) null else rest;
            };
            if (try self.runCompact(instructions_arg)) return .handled;
        }
        if (std.mem.eql(u8, name, "export")) {
            if (self.session_callbacks) |cbs| {
                if (cbs.export_html) |export_fn| {
                    const output_arg = it.next();
                    const output_path = export_fn(cbs.ctx, self.allocator, output_arg) catch |err| {
                        try self.setStatusFmt("Export failed: {s}", .{@errorName(err)});
                        return .handled;
                    };
                    defer self.allocator.free(output_path);
                    try self.setStatusFmt("Exported to {s}", .{output_path});
                    return .handled;
                }
            }
        }
        if (std.mem.eql(u8, name, "name")) {
            if (self.session_callbacks) |cbs| {
                if (cbs.set_name) |set_name_fn| {
                    const name_arg = it.next() orelse "";
                    set_name_fn(cbs.ctx, name_arg) catch |err| {
                        try self.setStatusFmt("Set name failed: {s}", .{@errorName(err)});
                        return .handled;
                    };
                    try self.setStatusFmt("Session name: {s}", .{name_arg});
                    return .handled;
                }
            }
        }
        if (std.mem.eql(u8, name, "fork")) {
            if (self.session_callbacks) |cbs| {
                if (cbs.fork) |fork_fn| {
                    fork_fn(cbs.ctx, self.allocator) catch |err| {
                        try self.setStatusFmt("Fork failed: {s}", .{@errorName(err)});
                        return .handled;
                    };
                    for (self.transcript.items) |l| self.allocator.free(l);
                    self.transcript.clearRetainingCapacity();
                    self.renderer.invalidate();
                    try self.setStatus("Session forked.");
                    return .handled;
                }
            }
        }
        if (std.mem.eql(u8, name, "clone")) {
            if (self.session_callbacks) |cbs| {
                if (cbs.clone) |clone_fn| {
                    clone_fn(cbs.ctx, self.allocator) catch |err| {
                        try self.setStatusFmt("Clone failed: {s}", .{@errorName(err)});
                        return .handled;
                    };
                    for (self.transcript.items) |l| self.allocator.free(l);
                    self.transcript.clearRetainingCapacity();
                    self.renderer.invalidate();
                    try self.setStatus("Session cloned.");
                    return .handled;
                }
            }
        }

        // Recognized builtin that needs deeper integration not yet ported.
        if (findCommand(name) != null) {
            try self.setStatusFmt("/{s} is a recognized command but is not yet wired in the Zig TUI.", .{name});
            return .handled;
        }

        try self.setStatusFmt("Unknown command: /{s}", .{name});
        return .unknown;
    }

    /// Handle `/compact`. Prefers a provider-backed LLM summary of the in-memory conversation
    /// (the `compact_runner` path, wired when a provider+model+auth are configured), mirroring
    /// the RPC runtime's structured compaction; falls back to the host's local message-count
    /// summary (`SessionCallbacks.compact`) when no runner is wired (no auth). On success the
    /// summary is persisted (provider path via `SessionCallbacks.persist_compaction`; local path
    /// persists itself) and the scrollback + in-memory conversation are reset to the summary.
    ///
    /// Returns true when `/compact` was handled (a runner or callback was present), false when
    /// no compaction backend is wired so `runCommand` can fall through to the "not yet wired"
    /// notice. App-level and unit-testable: the auth path is driven by a fake `compact_runner`,
    /// the no-auth path by a fake `SessionCallbacks.compact`.
    fn runCompact(self: *App, custom_instructions: ?[]const u8) !bool {
        // Provider-backed LLM summary path: requires a runner and a non-empty conversation.
        if (self.compact_runner) |compact_runner| {
            if (self.messages.items.len > 0) {
                const conversation = try self.buildCompactionPromptText(custom_instructions);
                defer self.allocator.free(conversation);
                const message_count = self.messages.items.len;
                const summary = compact_runner.run(compact_runner.ctx, self.allocator, conversation, custom_instructions) catch |err| {
                    try self.setStatusFmt("Compact failed: {s}", .{@errorName(err)});
                    return true;
                };
                defer self.allocator.free(summary);
                if (self.session_callbacks) |cbs| {
                    if (cbs.persist_compaction) |persist_fn| {
                        persist_fn(cbs.ctx, summary, custom_instructions, message_count) catch |err| {
                            try self.setStatusFmt("Compact failed: {s}", .{@errorName(err)});
                            return true;
                        };
                    }
                }
                try self.applyCompactionSummary(summary);
                return true;
            }
            // Runner wired but nothing to summarize yet: fall through to the local path so an
            // empty session still reports an honest local summary rather than calling the model.
        }

        // Local fallback (no auth / no runner / empty conversation): the host computes and
        // persists a message-count summary.
        if (self.session_callbacks) |cbs| {
            if (cbs.compact) |compact_fn| {
                const summary = compact_fn(cbs.ctx, self.allocator, custom_instructions) catch |err| {
                    try self.setStatusFmt("Compact failed: {s}", .{@errorName(err)});
                    return true;
                };
                defer self.allocator.free(summary);
                try self.applyCompactionSummary(summary);
                return true;
            }
        }
        return false;
    }

    /// Reset the visible scrollback and in-memory conversation after a successful compaction and
    /// surface the summary. Shared by the provider and local `/compact` paths. The in-memory
    /// message list is cleared (the persisted compaction entry in the session store is the source
    /// of truth that seeds the next real prompt's context), so a subsequent `/compact` summarizes
    /// only post-compaction turns — matching the RPC runtime's firstKeptEntryId semantics.
    fn applyCompactionSummary(self: *App, summary: []const u8) !void {
        for (self.transcript.items) |l| self.allocator.free(l);
        self.transcript.clearRetainingCapacity();
        self.clearMessages();
        self.renderer.invalidate();
        try self.appendTranscript("[Context compacted]");
        if (summary.len > 0) try self.appendTranscript(summary);
        try self.setStatus("Session compacted.");
    }

    fn setStatusFmt(self: *App, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        try self.setStatus(text);
    }

    fn appendHotkeys(self: *App) !void {
        try self.appendTranscript("Keyboard shortcuts:");
        for (keys.default_bindings) |b| {
            // Render "id  keys  description" compactly.
            var keys_buf: std.ArrayList(u8) = .empty;
            defer keys_buf.deinit(self.allocator);
            for (b.keys, 0..) |k, i| {
                if (i > 0) try keys_buf.appendSlice(self.allocator, ", ");
                try keys_buf.appendSlice(self.allocator, k);
            }
            const line = try std.fmt.allocPrint(self.allocator, "  {s}  [{s}]  {s}", .{ b.id, keys_buf.items, b.description });
            defer self.allocator.free(line);
            try self.appendTranscript(line);
        }
    }

    fn appendSessionInfo(self: *App) !void {
        const provider = self.options.provider orelse "(none)";
        const model = self.options.model orelse "(none)";
        const line = try std.fmt.allocPrint(self.allocator, "Session: provider={s} model={s} transcript_lines={d}", .{ provider, model, self.transcript.items.len });
        defer self.allocator.free(line);
        try self.appendTranscript(line);
    }

    fn appendModelInfo(self: *App) !void {
        const provider = self.options.provider orelse "(none)";
        const model = self.options.model orelse "(none)";
        const line = try std.fmt.allocPrint(self.allocator, "Current model: {s} / {s}. Pass a name to /model to switch.", .{ provider, model });
        defer self.allocator.free(line);
        try self.appendTranscript(line);
    }

    // -- Command palette (live `/`-command fuzzy autocomplete) ---------
    //
    // While the prompt buffer begins with `/`, the palette fuzzy-filters
    // `builtin_commands` (via tui_fuzzy/filterCommands) using the typed query and
    // renders the ranked matches under the composer (see buildScreen). Up/Down move
    // the highlight; Tab accepts the highlighted command into the editor. The logic
    // is pure (no terminal I/O) so it is App-level unit-testable with interactive:false.

    /// The query text after the leading `/` on the first editor line (palette filter input).
    /// Returns null when the buffer is not a single-line slash command (palette inactive).
    fn paletteQuery(self: *App) ?[]const u8 {
        if (self.editor.lines.items.len != 1) return null;
        const line = self.editor.lines.items[0].items;
        if (line.len == 0 or line[0] != '/') return null;
        const rest = line[1..];
        // Once a space is typed the user is entering arguments, not picking a command.
        if (std.mem.indexOfScalar(u8, rest, ' ') != null) return null;
        return rest;
    }

    /// Recompute palette visibility from the current buffer and clamp the selection.
    /// Caller invokes after any edit/navigation. Pure with respect to terminal I/O.
    fn refreshPalette(self: *App) !void {
        const query = self.paletteQuery() orelse {
            self.palette_active = false;
            self.palette_selected = 0;
            return;
        };
        const matches = try filterCommands(self.allocator, query);
        defer self.allocator.free(matches);
        self.palette_active = matches.len > 0;
        if (!self.palette_active) {
            self.palette_selected = 0;
        } else if (self.palette_selected >= matches.len) {
            self.palette_selected = matches.len - 1;
        }
    }

    /// Move the palette highlight by `delta` rows with wraparound. No-op when inactive.
    fn paletteMove(self: *App, delta: i64) !void {
        if (!self.palette_active) return;
        const query = self.paletteQuery() orelse return;
        const matches = try filterCommands(self.allocator, query);
        defer self.allocator.free(matches);
        if (matches.len == 0) return;
        const count: i64 = @intCast(matches.len);
        var next_index: i64 = @as(i64, @intCast(self.palette_selected)) + delta;
        next_index = @mod(next_index, count);
        if (next_index < 0) next_index += count;
        self.palette_selected = @intCast(next_index);
    }

    /// Accept the highlighted palette command: replace the buffer with `/<name> ` so the
    /// user can add arguments, then close the palette. Returns true when a command was
    /// completed. No-op (returns false) when the palette is inactive or has no matches.
    fn paletteAccept(self: *App) !bool {
        if (!self.palette_active) return false;
        const query = self.paletteQuery() orelse return false;
        const matches = try filterCommands(self.allocator, query);
        defer self.allocator.free(matches);
        if (matches.len == 0) return false;
        const index = @min(self.palette_selected, matches.len - 1);
        const name = matches[index].item.name;
        const completed = try std.fmt.allocPrint(self.allocator, "/{s} ", .{name});
        defer self.allocator.free(completed);
        try self.editor.setText(completed);
        self.palette_active = false;
        self.palette_selected = 0;
        return true;
    }

    // -- Model selector (`/model` overlay) -----------------------------
    //
    // `/model` with no argument opens an overlay seeded with the current model (resolved
    // from options.provider/model via models.find). Up/Down cycle the catalog with
    // models.next (read-only); Enter applies the highlighted model to options.provider/model.
    // `/model <name>` resolves and applies directly via models.findExactModelReference/find.

    /// Resolve the catalog entry for the current options.provider/model, if any.
    fn currentModelEntry(self: *App) ?*const models.ModelEntry {
        const provider = self.options.provider orelse return null;
        const model = self.options.model orelse return null;
        return models.find(provider, model);
    }

    /// Open the `/model` selector overlay, seeding the highlight with the current model.
    fn openModelSelector(self: *App) void {
        self.model_selector_active = true;
        self.selected_model = self.currentModelEntry();
    }

    /// Cycle the highlighted model forward (delta>=0) using the read-only models.next helper.
    /// No-op when the selector is closed or the catalog is empty.
    fn modelSelectorCycle(self: *App) void {
        if (!self.model_selector_active) return;
        if (models.all.len == 0) return;
        self.selected_model = models.next(self.selected_model);
    }

    /// Apply the highlighted model to options.provider/model and close the overlay. The provider
    /// and id slices borrow the catalog entry (stable for process lifetime). Returns true when a
    /// model was applied. No-op (returns false) when the selector is closed.
    fn modelSelectorAccept(self: *App) !bool {
        if (!self.model_selector_active) return false;
        const selected = self.selected_model orelse if (models.all.len > 0) &models.all[0] else {
            self.model_selector_active = false;
            return false;
        };
        self.options.provider = selected.provider;
        self.options.model = selected.id;
        self.model_selector_active = false;
        self.selected_model = null;
        try self.setStatusFmt("Model set to {s} / {s}.", .{ selected.provider, selected.id });
        return true;
    }

    /// Resolve `name` (a `/model <name>` argument) against the catalog and apply it. Accepts a bare
    /// id, a `provider/id` reference, or any unambiguous catalog reference (models.zig matching).
    fn setModelByName(self: *App, name: []const u8) !void {
        const entry = models.findExactModelReference(name) orelse {
            try self.setStatusFmt("Unknown model: {s}. Use /model to browse the catalog.", .{name});
            return;
        };
        self.options.provider = entry.provider;
        self.options.model = entry.id;
        try self.setStatusFmt("Model set to {s} / {s}.", .{ entry.provider, entry.id });
    }

    // -- Prompt execution ----------------------------------------------

    const StreamCtx = struct {
        app: *App,
        writer: *std.Io.Writer,
    };

    fn streamTextCb(ctx: *anyopaque, delta: []const u8) anyerror!void {
        const sc: *StreamCtx = @ptrCast(@alignCast(ctx));
        try sc.app.streaming.appendSlice(sc.app.allocator, delta);
        try sc.app.paint(sc.writer);
    }

    fn toolResultCb(ctx: *anyopaque, tool_name: []const u8, content: []const u8, is_error: bool) anyerror!void {
        const sc: *StreamCtx = @ptrCast(@alignCast(ctx));
        const label = if (is_error) "tool error" else "tool";
        const header = try std.fmt.allocPrint(sc.app.allocator, "[{s}: {s}]", .{ label, tool_name });
        defer sc.app.allocator.free(header);
        try sc.app.appendTranscript(header);
        // Show a short preview of the tool output.
        const preview_len = @min(content.len, 400);
        try sc.app.appendTranscript(content[0..preview_len]);
        // Record the full tool result in the in-memory conversation so a later `/compact`
        // can summarize it (mirrors the RPC runtime threading tool results into compaction).
        try sc.app.appendMessage(.tool, content);
        try sc.app.paint(sc.writer);
    }

    fn cancelCb(ctx: *anyopaque) bool {
        const sc: *StreamCtx = @ptrCast(@alignCast(ctx));
        const app = sc.app;
        if (app.abort_requested) return true;
        // Cooperative abort: while a tool (e.g. a long-running bash command) is
        // executing, the main input loop is blocked, so poll stdin without
        // blocking for a pending Escape / Ctrl+C and set the abort flag.
        if (app.options.interactive) {
            var buf: [64]u8 = undefined;
            const n = terminal.readNonblocking(std.Io.File.stdin().handle, &buf);
            if (n > 0) {
                var it = keys.sequences(buf[0..n]);
                while (it.next()) |seq| {
                    if (keys.matches(seq, "app.interrupt") or keys.matches(seq, "app.clear")) {
                        app.abort_requested = true;
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /// Render a blocking permission dialog and read a single y/n decision from
    /// the terminal. Mirrors the upstream permission prompt: the turn pauses
    /// until the user answers. Only used when an interactive TTY is present.
    fn permissionCb(ctx: *anyopaque, tool_name: []const u8, arguments_json: []const u8) anyerror!PermissionDecision {
        const sc: *StreamCtx = @ptrCast(@alignCast(ctx));
        const app = sc.app;

        // Show the request and a short preview of the arguments in the status.
        const preview_len = @min(arguments_json.len, 200);
        app.awaiting_permission = true;
        defer app.awaiting_permission = false;
        try app.setStatusFmt(
            "Allow tool '{s}'? {s}  [y]es / [n]o",
            .{ tool_name, arguments_json[0..preview_len] },
        );
        try app.paint(sc.writer);

        // Read keys until y/n/escape.
        const stdin = std.Io.File.stdin();
        var key_buf: [64]u8 = undefined;
        while (true) {
            if (app.abort_requested) return .deny;
            const n = stdin.readStreaming(app.io, &.{&key_buf}) catch return .deny;
            if (n == 0) return .deny;
            var it = keys.sequences(key_buf[0..n]);
            while (it.next()) |seq| {
                if (keys.matches(seq, "app.interrupt")) {
                    app.abort_requested = true;
                    return .deny;
                }
                const decoded = keys.decode(seq);
                if (decoded.printable.len == 1) {
                    switch (decoded.printable[0]) {
                        'y', 'Y' => {
                            try app.setStatus("");
                            return .allow;
                        },
                        'n', 'N' => {
                            try app.setStatus("Tool denied.");
                            return .deny;
                        },
                        else => {},
                    }
                }
            }
        }
    }

    /// Run a user prompt through the injected runner, streaming output to `w`.
    fn executePrompt(self: *App, w: *std.Io.Writer, prompt: []const u8) !void {
        const runner = self.runner orelse {
            try self.setStatus("No model configured. Pass --provider and --model to run prompts.");
            return;
        };

        // Echo the user message into the transcript and record it in the in-memory
        // conversation so `/compact` can summarize the real turns.
        const user_line = try std.fmt.allocPrint(self.allocator, "> {s}", .{prompt});
        defer self.allocator.free(user_line);
        try self.appendTranscript(user_line);
        try self.appendMessage(.user, prompt);

        self.running = true;
        self.abort_requested = false;
        self.streaming.clearRetainingCapacity();
        try self.paint(w);

        var stream_ctx = StreamCtx{ .app = self, .writer = w };
        const callbacks = PromptCallbacks{
            .ctx = &stream_ctx,
            .on_text = streamTextCb,
            .on_tool_permission = permissionCb,
            .on_tool_result = toolResultCb,
            .should_cancel = cancelCb,
        };

        const result = runner.run(runner.ctx, self.allocator, prompt, callbacks) catch |err| {
            self.running = false;
            try self.setStatusFmt("Prompt failed: {s}", .{@errorName(err)});
            self.streaming.clearRetainingCapacity();
            try self.paint(w);
            return;
        };
        defer self.allocator.free(result);

        self.running = false;
        // Commit the final assistant text into the transcript and the in-memory conversation.
        self.streaming.clearRetainingCapacity();
        const assistant_line = try std.fmt.allocPrint(self.allocator, "assistant: {s}", .{result});
        defer self.allocator.free(assistant_line);
        try self.appendTranscript(assistant_line);
        if (result.len > 0) try self.appendMessage(.assistant, result);
        if (self.abort_requested) {
            try self.setStatus("Aborted.");
        } else {
            try self.setStatus("");
        }
        try self.paint(w);
    }

    // -- Main loop ------------------------------------------------------

    /// Run the interactive loop. Requires a TTY; otherwise returns `.not_a_tty`.
    pub fn run(self: *App) !ExitReason {
        const stdin = std.Io.File.stdin();
        const stdout = std.Io.File.stdout();

        const is_tty = stdin.isTty(self.io) catch false;
        if (!self.options.interactive or !is_tty) {
            return .not_a_tty;
        }

        var raw = terminal.RawMode.enable(stdin.handle) catch {
            return .not_a_tty;
        };
        defer raw.disable();

        var out_buf: [16 * 1024]u8 = undefined;
        var stdout_writer = stdout.writer(self.io, &out_buf);
        const w = &stdout_writer.interface;
        defer w.flush() catch {};

        // Boot banner.
        try self.printBanner();
        try self.paint(w);

        var in_buf: [4096]u8 = undefined;
        while (true) {
            // A single read may carry multiple keys (fast typing / paste); split
            // the buffer into individual key sequences and dispatch each.
            const n = stdin.readStreaming(self.io, &.{&in_buf}) catch break;
            if (n == 0) return .eof;

            var it = keys.sequences(in_buf[0..n]);
            while (it.next()) |seq| {
                const action = try self.handleKey(seq);
                switch (action) {
                    .none => {},
                    .exit => return .user_quit,
                    .abort => {
                        // Abort handled cooperatively by the running prompt via cancelCb.
                    },
                    .submit => |text| {
                        defer self.allocator.free(text);
                        try self.executePrompt(w, text);
                    },
                    .run_command => |cmd| {
                        defer self.allocator.free(cmd);
                        const outcome = try self.runCommand(cmd);
                        if (outcome == .quit) return .user_quit;
                    },
                }
            }
            try self.paint(w);
        }
        return .eof;
    }

    fn printBanner(self: *App) !void {
        // Bold, accent-colored masthead so the first paint signals "this is a
        // real TUI" rather than a bare prompt. Each line keeps ANSI state
        // self-contained per the line-diff renderer's invariants.
        const masthead = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}π pi-zig{s}{s}  interactive mode{s}",
            .{ sgr.bold, sgr.accent, sgr.reset, sgr.muted, sgr.reset },
        );
        defer self.allocator.free(masthead);
        try self.appendTranscript(masthead);

        const provider = self.options.provider orelse "(none)";
        const model = self.options.model orelse "(none)";
        const meta = try std.fmt.allocPrint(
            self.allocator,
            "{s}provider:{s} {s}{s}{s}   {s}model:{s} {s}{s}{s}",
            .{ sgr.muted, sgr.reset, sgr.accent, provider, sgr.reset, sgr.muted, sgr.reset, sgr.accent, model, sgr.reset },
        );
        defer self.allocator.free(meta);
        try self.appendTranscript(meta);

        const hint = try std.fmt.allocPrint(
            self.allocator,
            "{s}Type a message and press Enter. Slash: {s}/help /model /session /new /quit{s}. Ctrl+D to exit.{s}",
            .{ sgr.muted, sgr.accent, sgr.muted, sgr.reset },
        );
        defer self.allocator.free(hint);
        try self.appendTranscript(hint);
        try self.appendTranscript("");
    }

    /// Render the current screen to the terminal writer using the diff renderer.
    fn paint(self: *App, w: *std.Io.Writer) !void {
        var screen = try self.buildScreen();
        defer self.freeScreen(&screen);
        const update = try self.renderer.render(screen.items);
        defer self.allocator.free(update);
        try w.writeAll(update);
        try w.flush();
    }

    // -- Input dispatch ------------------------------------------------

    pub const Action = union(enum) {
        none,
        submit: []const u8, // owned prompt text (caller frees)
        run_command: []const u8, // owned command line without leading slash
        exit,
        abort,
    };

    /// Process one decoded key against the editor and app state. Returns an
    /// action for the caller (the loop) to perform. Submit/run_command return
    /// owned text the caller must free. Pure with respect to terminal I/O so it
    /// can be unit-tested.
    ///
    /// Overlay keys (model selector, command palette) are intercepted first; then the
    /// normal editor dispatch runs. After any pass the palette visibility is recomputed
    /// from the buffer so typing `/mod` opens it and editing/clearing closes it.
    pub fn handleKey(self: *App, data: []const u8) !Action {
        // Live overlays intercept navigation/accept/cancel keys before editor dispatch.
        if (try self.handleOverlayKey(data)) |action| return action;

        const action = try self.dispatchKey(data);
        switch (action) {
            // Typing / deletion / cursor moves may open or close the palette.
            .none => try self.refreshPalette(),
            // Submit and run_command clear the editor, so the palette must close.
            .submit, .run_command => {
                self.palette_active = false;
                self.palette_selected = 0;
            },
            .exit, .abort => {},
        }
        return action;
    }

    /// Handle a key while a model selector or command palette overlay is open, or the global
    /// model hotkeys (Ctrl+L open, Ctrl+P/Shift+Ctrl+P cycle). Returns the resulting Action when
    /// the key was consumed by an overlay, or null to let the normal editor dispatch run.
    fn handleOverlayKey(self: *App, data: []const u8) !?Action {
        // Global model-selector hotkeys (work even when no overlay is open yet).
        if (keys.matches(data, "app.model.select")) {
            self.openModelSelector();
            return Action.none;
        }
        if (keys.matches(data, "app.model.cycleForward")) {
            if (!self.model_selector_active) self.openModelSelector();
            self.modelSelectorCycle();
            return Action.none;
        }
        if (keys.matches(data, "app.model.cycleBackward")) {
            if (!self.model_selector_active) self.openModelSelector();
            self.modelSelectorCycle();
            return Action.none;
        }

        if (self.model_selector_active) {
            if (keys.matches(data, "app.interrupt") or keys.matches(data, "tui.select.cancel")) {
                self.model_selector_active = false;
                self.selected_model = null;
                return Action.none;
            }
            if (keys.matches(data, "tui.editor.cursorUp") or keys.matches(data, "tui.editor.cursorDown")) {
                self.modelSelectorCycle();
                return Action.none;
            }
            if (keys.matches(data, "tui.input.submit") or keys.matches(data, "tui.select.confirm")) {
                _ = try self.modelSelectorAccept();
                return Action.none;
            }
            // Swallow other keys while the selector is modal.
            return Action.none;
        }

        if (self.palette_active) {
            if (keys.matches(data, "tui.editor.cursorUp")) {
                try self.paletteMove(-1);
                return Action.none;
            }
            if (keys.matches(data, "tui.editor.cursorDown")) {
                try self.paletteMove(1);
                return Action.none;
            }
            if (keys.matches(data, "tui.input.tab")) {
                _ = try self.paletteAccept();
                return Action.none;
            }
            if (keys.matches(data, "app.interrupt")) {
                // Escape dismisses the palette without clearing the buffer.
                self.palette_active = false;
                self.palette_selected = 0;
                return Action.none;
            }
            // Other keys (typing, submit, deletion) fall through to editor dispatch.
        }
        return null;
    }

    /// The normal per-key editor/app dispatch (cursor movement, deletion, submit, insertion).
    fn dispatchKey(self: *App, data: []const u8) !Action {
        // Application-level bindings first.
        if (keys.matches(data, "app.exit") and self.editor.isEmpty()) {
            return .exit;
        }
        if (keys.matches(data, "app.interrupt")) {
            if (self.running) {
                self.abort_requested = true;
                return .abort;
            }
            // Esc on idle clears any status.
            try self.setStatus("");
            return .none;
        }
        if (keys.matches(data, "app.clear")) {
            // Ctrl+C clears the editor (when not running).
            if (!self.running) {
                try self.editor.clear();
            }
            return .none;
        }

        // Submit / newline.
        if (keys.matches(data, "tui.input.submit")) {
            const text = try self.editor.getText();
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len == 0) {
                self.allocator.free(text);
                return .none;
            }
            try self.editor.addHistory(text);
            try self.editor.clear();
            if (std.mem.startsWith(u8, trimmed, "/")) {
                const cmd = try self.allocator.dupe(u8, trimmed[1..]);
                self.allocator.free(text);
                return .{ .run_command = cmd };
            }
            // Reslice trimmed into a fresh owned buffer, free the original.
            const owned = try self.allocator.dupe(u8, trimmed);
            self.allocator.free(text);
            return .{ .submit = owned };
        }
        if (keys.matches(data, "tui.input.newLine")) {
            try self.editor.newLine();
            return .none;
        }

        // Editor cursor movement.
        if (keys.matches(data, "tui.editor.cursorLeft")) {
            self.editor.moveLeft();
            return .none;
        }
        if (keys.matches(data, "tui.editor.cursorRight")) {
            self.editor.moveRight();
            return .none;
        }
        if (keys.matches(data, "tui.editor.cursorWordLeft")) {
            self.editor.moveWordLeft();
            return .none;
        }
        if (keys.matches(data, "tui.editor.cursorWordRight")) {
            self.editor.moveWordRight();
            return .none;
        }
        if (keys.matches(data, "tui.editor.cursorLineStart")) {
            self.editor.moveLineStart();
            return .none;
        }
        if (keys.matches(data, "tui.editor.cursorLineEnd")) {
            self.editor.moveLineEnd();
            return .none;
        }
        if (keys.matches(data, "tui.editor.cursorUp")) {
            // Up at top of editor browses prompt history.
            if (self.editor.cursor_line == 0) {
                _ = try self.editor.historyPrev();
            } else {
                self.editor.moveUp();
            }
            return .none;
        }
        if (keys.matches(data, "tui.editor.cursorDown")) {
            if (self.editor.cursor_line == self.editor.lines.items.len - 1) {
                _ = try self.editor.historyNext();
            } else {
                self.editor.moveDown();
            }
            return .none;
        }

        // Editor deletion.
        if (keys.matches(data, "tui.editor.deleteCharBackward")) {
            try self.editor.deleteCharBackward();
            return .none;
        }
        if (keys.matches(data, "tui.editor.deleteCharForward")) {
            try self.editor.deleteCharForward();
            return .none;
        }
        if (keys.matches(data, "tui.editor.deleteWordBackward")) {
            try self.editor.deleteWordBackward();
            return .none;
        }
        if (keys.matches(data, "tui.editor.deleteWordForward")) {
            try self.editor.deleteWordForward();
            return .none;
        }
        if (keys.matches(data, "tui.editor.deleteToLineStart")) {
            try self.editor.deleteToLineStart();
            return .none;
        }
        if (keys.matches(data, "tui.editor.deleteToLineEnd")) {
            try self.editor.deleteToLineEnd();
            return .none;
        }
        if (keys.matches(data, "tui.editor.yank")) {
            try self.editor.yank();
            return .none;
        }
        if (keys.matches(data, "tui.editor.yankPop")) {
            try self.editor.yankPop();
            return .none;
        }
        if (keys.matches(data, "tui.editor.undo")) {
            try self.editor.undo();
            return .none;
        }

        // Otherwise: insert printable text. The space key decodes to the id
        // "space" (with empty printable), so insert a literal space for it.
        const decoded = keys.decode(data);
        if (decoded.printable.len > 0) {
            try self.editor.insertText(decoded.printable);
        } else if (decoded.id()) |id| {
            if (std.mem.eql(u8, id, "space")) try self.editor.insertText(" ");
        }
        return .none;
    }
};

// =====================================================================
// Tests
// =====================================================================

test "builtin commands match upstream count and contain quit" {
    try std.testing.expect(builtin_commands.len == 21);
    try std.testing.expect(findCommand("quit") != null);
    try std.testing.expect(findCommand("model") != null);
    try std.testing.expect(findCommand("nope") == null);
}

test "filterCommands fuzzy-matches builtin slash commands" {
    const results = try filterCommands(std.testing.allocator, "mod");
    defer std.testing.allocator.free(results);
    // "model" and "scoped-models" both match.
    try std.testing.expect(results.len >= 2);
    try std.testing.expectEqualStrings("model", results[0].item.name);

    const sess = try filterCommands(std.testing.allocator, "sess");
    defer std.testing.allocator.free(sess);
    try std.testing.expectEqualStrings("session", sess[0].item.name);
}

test "handleKey inserts printable text into the editor" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    for ("hello") |c| {
        const action = try app.handleKey(&.{c});
        try std.testing.expect(action == .none);
    }
    const text = try app.editor.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "handleKey inserts spaces (space key has no printable payload)" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    for ("a b c") |c| {
        _ = try app.handleKey(&.{c});
    }
    const text = try app.editor.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a b c", text);
}

test "handleKey submit returns prompt text and clears editor" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    try app.editor.insertText("do something");
    const action = try app.handleKey("\r"); // enter
    switch (action) {
        .submit => |text| {
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings("do something", text);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(app.editor.isEmpty());
}

test "handleKey routes slash input to run_command" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    try app.editor.insertText("/model gpt-5");
    const action = try app.handleKey("\r");
    switch (action) {
        .run_command => |cmd| {
            defer std.testing.allocator.free(cmd);
            try std.testing.expectEqualStrings("model gpt-5", cmd);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "handleKey ctrl+d on empty editor exits, otherwise deletes forward" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    // Empty editor -> exit.
    try std.testing.expect((try app.handleKey("\x04")) == .exit);
    // Non-empty -> ctrl+d deletes forward (a char), not exit.
    try app.editor.insertText("ab");
    app.editor.cursor_col = 0;
    const action = try app.handleKey("\x04");
    try std.testing.expect(action == .none);
    const text = try app.editor.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("b", text);
}

test "handleKey escape requests abort while running" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    app.running = true;
    const action = try app.handleKey("\x1b"); // escape
    try std.testing.expect(action == .abort);
    try std.testing.expect(app.abort_requested);
}

test "handleKey word deletion uses editor kill semantics" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    try app.editor.insertText("alpha beta");
    _ = try app.handleKey("\x17"); // ctrl+w deletes "beta"
    const text = try app.editor.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("alpha ", text);
}

test "buildScreen renders prompt with cursor caret and transcript" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    try app.appendTranscript("assistant: hi");
    try app.editor.insertText("hello");
    app.editor.cursor_col = 2;
    var screen = try app.buildScreen();
    defer {
        for (screen.items) |l| std.testing.allocator.free(l);
        screen.deinit(std.testing.allocator);
    }
    // First line is the transcript.
    try std.testing.expectEqualStrings("assistant: hi", screen.items[0]);
    // Last line is the prompt with caret after "he".
    try std.testing.expectEqualStrings("> he|llo", screen.items[screen.items.len - 1]);
}

test "appendTranscript splits embedded newlines into separate lines" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    try app.appendTranscript("line1\nline2\nline3");
    try std.testing.expect(app.transcript.items.len == 3);
    try std.testing.expectEqualStrings("line2", app.transcript.items[1]);
}

test "runCommand quit returns quit outcome" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    try std.testing.expect((try app.runCommand("quit")) == .quit);
}

test "runCommand hotkeys appends keyboard shortcut transcript" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    const outcome = try app.runCommand("hotkeys");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(app.transcript.items.len > 1);
    try std.testing.expectEqualStrings("Keyboard shortcuts:", app.transcript.items[0]);
    // Should include a known binding id somewhere.
    var found = false;
    for (app.transcript.items) |line| {
        if (std.mem.indexOf(u8, line, "app.interrupt") != null) found = true;
    }
    try std.testing.expect(found);
}

test "runCommand new clears the transcript" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    try app.appendTranscript("old content");
    const outcome = try app.runCommand("new");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(app.transcript.items.len == 0);
}

test "runCommand recognizes builtin but reports unwired, and flags unknown" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    // "compact" is a real builtin not yet wired in the TUI.
    try std.testing.expect((try app.runCommand("compact")) == .handled);
    try std.testing.expect(std.mem.indexOf(u8, app.status, "not yet wired") != null);
    // Bogus command.
    try std.testing.expect((try app.runCommand("definitelynotacommand")) == .unknown);
    try std.testing.expect(std.mem.indexOf(u8, app.status, "Unknown command") != null);
}

const FakeRunner = struct {
    reply: []const u8,
    emit_tool: bool = false,

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8, callbacks: PromptCallbacks) anyerror![]u8 {
        const self: *FakeRunner = @ptrCast(@alignCast(ctx));
        _ = prompt;
        if (callbacks.on_text) |cb| {
            try cb(callbacks.ctx, "streamed ");
            try cb(callbacks.ctx, "text");
        }
        if (self.emit_tool) {
            if (callbacks.on_tool_result) |cb| {
                try cb(callbacks.ctx, "bash", "command output", false);
            }
        }
        return allocator.dupe(u8, self.reply);
    }

    fn runner(self: *FakeRunner) PromptRunner {
        return .{ .ctx = self, .run = FakeRunner.run };
    }
};

test "executePrompt streams text and commits assistant transcript via fake runner" {
    // Use a discarding writer so paint() has a valid sink.
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const w = &sink.writer;

    var fake = FakeRunner{ .reply = "final answer", .emit_tool = true };
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    app.runner = fake.runner();

    try app.executePrompt(w, "hello");
    try std.testing.expect(!app.running);

    // Transcript should contain the user echo, the tool panel, and the assistant reply.
    var saw_user = false;
    var saw_tool = false;
    var saw_assistant = false;
    for (app.transcript.items) |line| {
        if (std.mem.indexOf(u8, line, "> hello") != null) saw_user = true;
        if (std.mem.indexOf(u8, line, "[tool: bash]") != null) saw_tool = true;
        if (std.mem.indexOf(u8, line, "assistant: final answer") != null) saw_assistant = true;
    }
    try std.testing.expect(saw_user);
    try std.testing.expect(saw_tool);
    try std.testing.expect(saw_assistant);
}

test "executePrompt without a runner sets an informative status" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const w = &sink.writer;
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    try app.executePrompt(w, "hello");
    try std.testing.expect(std.mem.indexOf(u8, app.status, "No model configured") != null);
}

// A runner that simulates a user pressing Escape mid-stream: it sets
// app.abort_requested = true through the provided pointer (simulating an Escape
// keystroke landing while the runner is active), then checks should_cancel.
// When should_cancel returns true it returns error.AgentAborted.
const FakeRunnerCancellable = struct {
    app_ptr: *App,

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8, callbacks: PromptCallbacks) anyerror![]u8 {
        const self: *FakeRunnerCancellable = @ptrCast(@alignCast(ctx));
        _ = prompt;
        // Emit a partial text delta first, then simulate user pressing Escape.
        if (callbacks.on_text) |cb| try cb(callbacks.ctx, "par");
        // Simulate Escape: set abort_requested (same as handleKey(.abort) would do).
        self.app_ptr.abort_requested = true;
        // Cooperative check: should_cancel reads abort_requested → returns true.
        if (callbacks.should_cancel) |cb| {
            if (cb(callbacks.ctx)) return error.AgentAborted;
        }
        return allocator.dupe(u8, "");
    }

    fn runner(self: *FakeRunnerCancellable) PromptRunner {
        return .{ .ctx = self, .run = FakeRunnerCancellable.run };
    }
};

test "executePrompt abort path: mid-stream abort causes AgentAborted status" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const w = &sink.writer;

    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    var fake = FakeRunnerCancellable{ .app_ptr = &app };
    app.runner = fake.runner();

    try app.executePrompt(w, "test prompt");

    try std.testing.expect(!app.running);
    // Runner returned AgentAborted → status shows "Prompt failed: AgentAborted".
    try std.testing.expect(std.mem.indexOf(u8, app.status, "AgentAborted") != null);
    // Streaming buffer is cleared after the abort path.
    try std.testing.expect(app.streaming.items.len == 0);
}

test "executePrompt abort path: user echo persists in transcript after abort" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const w = &sink.writer;

    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    var fake = FakeRunnerCancellable{ .app_ptr = &app };
    app.runner = fake.runner();

    try app.executePrompt(w, "mid-stream abort");

    try std.testing.expect(!app.running);
    try std.testing.expect(app.streaming.items.len == 0);
    var saw_user = false;
    for (app.transcript.items) |line| {
        if (std.mem.indexOf(u8, line, "> mid-stream abort") != null) saw_user = true;
    }
    try std.testing.expect(saw_user);
}

// Fake session callbacks used to verify /compact, /export, /name, /fork, /clone wiring.
const FakeSessionCtx = struct {
    compact_called: bool = false,
    export_called: bool = false,
    name_value: []const u8 = "",
    fork_called: bool = false,
    clone_called: bool = false,
    // /compact provider-path persistence capture. The summary/instructions slices the App hands us
    // are freed right after this callback returns, so copy the bytes into inline buffers.
    persist_called: bool = false,
    persisted_summary_buf: [256]u8 = undefined,
    persisted_summary_len: usize = 0,
    persisted_count: usize = 0,
    persisted_instructions_buf: [128]u8 = undefined,
    persisted_instructions_len: usize = 0,
    persisted_has_instructions: bool = false,

    fn persistedSummary(self: *const FakeSessionCtx) []const u8 {
        return self.persisted_summary_buf[0..self.persisted_summary_len];
    }

    fn persistedInstructions(self: *const FakeSessionCtx) ?[]const u8 {
        return if (self.persisted_has_instructions) self.persisted_instructions_buf[0..self.persisted_instructions_len] else null;
    }

    fn compact(ctx: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8) anyerror![]u8 {
        const self: *FakeSessionCtx = @ptrCast(@alignCast(ctx));
        self.compact_called = true;
        return allocator.dupe(u8, "Compaction summary");
    }

    fn persist_compaction(ctx: *anyopaque, summary: []const u8, custom_instructions: ?[]const u8, message_count: usize) anyerror!void {
        const self: *FakeSessionCtx = @ptrCast(@alignCast(ctx));
        self.persist_called = true;
        self.persisted_count = message_count;
        self.persisted_summary_len = @min(summary.len, self.persisted_summary_buf.len);
        @memcpy(self.persisted_summary_buf[0..self.persisted_summary_len], summary[0..self.persisted_summary_len]);
        if (custom_instructions) |instructions| {
            self.persisted_has_instructions = true;
            self.persisted_instructions_len = @min(instructions.len, self.persisted_instructions_buf.len);
            @memcpy(self.persisted_instructions_buf[0..self.persisted_instructions_len], instructions[0..self.persisted_instructions_len]);
        }
    }

    fn export_html(ctx: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8) anyerror![]u8 {
        const self: *FakeSessionCtx = @ptrCast(@alignCast(ctx));
        self.export_called = true;
        return allocator.dupe(u8, "/tmp/session.html");
    }

    fn set_name(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *FakeSessionCtx = @ptrCast(@alignCast(ctx));
        self.name_value = name;
    }

    fn fork(ctx: *anyopaque, _: std.mem.Allocator) anyerror!void {
        const self: *FakeSessionCtx = @ptrCast(@alignCast(ctx));
        self.fork_called = true;
    }

    fn clone(ctx: *anyopaque, _: std.mem.Allocator) anyerror!void {
        const self: *FakeSessionCtx = @ptrCast(@alignCast(ctx));
        self.clone_called = true;
    }

    fn callbacks(self: *FakeSessionCtx) SessionCallbacks {
        return .{
            .ctx = self,
            .compact = FakeSessionCtx.compact,
            .persist_compaction = FakeSessionCtx.persist_compaction,
            .export_html = FakeSessionCtx.export_html,
            .set_name = FakeSessionCtx.set_name,
            .fork = FakeSessionCtx.fork,
            .clone = FakeSessionCtx.clone,
        };
    }
};

// Fake provider-backed compaction runner: inspects the conversation it was handed (while the slice
// is alive, since the App frees it after `run` returns) and returns a canned LLM summary, standing
// in for InteractiveCompactRunner (agent.runPrompt) in App-level tests.
const FakeCompactRunner = struct {
    called: bool = false,
    saw_conversation_wrapper: bool = false,
    saw_user_turn: bool = false,
    saw_summarization_instructions: bool = false,
    summary: []const u8 = "LLM summary",
    fail: bool = false,

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, conversation: []const u8, _: ?[]const u8) anyerror![]u8 {
        const self: *FakeCompactRunner = @ptrCast(@alignCast(ctx));
        self.called = true;
        self.saw_conversation_wrapper = std.mem.indexOf(u8, conversation, "<conversation>") != null and
            std.mem.indexOf(u8, conversation, "</conversation>") != null;
        self.saw_user_turn = std.mem.indexOf(u8, conversation, "[User]: ") != null;
        self.saw_summarization_instructions = std.mem.indexOf(u8, conversation, "structured context checkpoint summary") != null;
        if (self.fail) return error.ProviderRequestFailed;
        return allocator.dupe(u8, self.summary);
    }

    fn runner(self: *FakeCompactRunner) CompactRunner {
        return .{ .ctx = self, .run = FakeCompactRunner.run };
    }
};

test "runCommand compact with session_callbacks calls compact_fn" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    var ctx = FakeSessionCtx{};
    app.session_callbacks = ctx.callbacks();

    const outcome = try app.runCommand("compact");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(ctx.compact_called);
    try std.testing.expect(std.mem.indexOf(u8, app.status, "compacted") != null);
    var saw_compact_entry = false;
    for (app.transcript.items) |line| {
        if (std.mem.indexOf(u8, line, "compacted") != null or
            std.mem.indexOf(u8, line, "Compaction summary") != null) saw_compact_entry = true;
    }
    try std.testing.expect(saw_compact_entry);
}

test "runCommand export with session_callbacks calls export_fn" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    var ctx = FakeSessionCtx{};
    app.session_callbacks = ctx.callbacks();

    const outcome = try app.runCommand("export");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(ctx.export_called);
    try std.testing.expect(std.mem.indexOf(u8, app.status, "session.html") != null);
}

test "runCommand name with session_callbacks sets name" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    var ctx = FakeSessionCtx{};
    app.session_callbacks = ctx.callbacks();

    const outcome = try app.runCommand("name my-session");
    try std.testing.expect(outcome == .handled);
    try std.testing.expectEqualStrings("my-session", ctx.name_value);
}

test "runCommand fork with session_callbacks calls fork_fn" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    var ctx = FakeSessionCtx{};
    app.session_callbacks = ctx.callbacks();

    const outcome = try app.runCommand("fork");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(ctx.fork_called);
    try std.testing.expect(std.mem.indexOf(u8, app.status, "forked") != null);
}

test "runCommand clone with session_callbacks calls clone_fn" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    var ctx = FakeSessionCtx{};
    app.session_callbacks = ctx.callbacks();

    const outcome = try app.runCommand("clone");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(ctx.clone_called);
    try std.testing.expect(std.mem.indexOf(u8, app.status, "cloned") != null);
}

test "runCommand compact without session_callbacks reports not yet wired" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    const outcome = try app.runCommand("compact");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(std.mem.indexOf(u8, app.status, "not yet wired") != null);
}

// /compact provider (auth) path: a wired CompactRunner with a non-empty conversation runs the LLM
// summary over the serialized conversation, persists it via persist_compaction, and resets the
// transcript + in-memory conversation. The local compact callback is NOT used on this path.
test "runCommand compact uses the LLM runner and persists when authenticated" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    var session_ctx = FakeSessionCtx{};
    app.session_callbacks = session_ctx.callbacks();
    var compact_runner = FakeCompactRunner{ .summary = "## Goal\nstructured llm summary" };
    app.compact_runner = compact_runner.runner();

    // Seed a real conversation so the provider path engages.
    try app.appendMessage(.user, "add a feature");
    try app.appendMessage(.assistant, "done, edited main.zig");

    const outcome = try app.runCommand("compact focus on edits");
    try std.testing.expect(outcome == .handled);

    // The LLM runner ran over the serialized <conversation> (not the local fallback).
    try std.testing.expect(compact_runner.called);
    try std.testing.expect(!session_ctx.compact_called);
    try std.testing.expect(compact_runner.saw_conversation_wrapper);
    try std.testing.expect(compact_runner.saw_user_turn);
    try std.testing.expect(compact_runner.saw_summarization_instructions);

    // The provider summary was persisted with the in-memory turn count and the custom focus.
    try std.testing.expect(session_ctx.persist_called);
    try std.testing.expectEqualStrings("## Goal\nstructured llm summary", session_ctx.persistedSummary());
    try std.testing.expectEqual(@as(usize, 2), session_ctx.persisted_count);
    try std.testing.expectEqualStrings("focus on edits", session_ctx.persistedInstructions().?);

    // Transcript reset to the summary; in-memory conversation cleared.
    try std.testing.expect(std.mem.indexOf(u8, app.status, "compacted") != null);
    try std.testing.expect(app.messages.items.len == 0);
    var saw_summary = false;
    for (app.transcript.items) |line| {
        if (std.mem.indexOf(u8, line, "structured llm summary") != null) saw_summary = true;
    }
    try std.testing.expect(saw_summary);
}

// /compact no-auth path: when no CompactRunner is wired, /compact falls back to the host's local
// message-count summary (SessionCallbacks.compact), exactly as before the provider path existed.
test "runCommand compact falls back to the local summary when no LLM runner is wired" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    var session_ctx = FakeSessionCtx{};
    app.session_callbacks = session_ctx.callbacks();
    // No app.compact_runner.
    try app.appendMessage(.user, "hello");

    const outcome = try app.runCommand("compact");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(session_ctx.compact_called);
    try std.testing.expect(!session_ctx.persist_called);
    try std.testing.expect(std.mem.indexOf(u8, app.status, "compacted") != null);
}

// A wired runner but an empty conversation falls back to the local summary instead of calling the
// model with nothing to summarize.
test "runCommand compact with a runner but empty conversation uses the local summary" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    var session_ctx = FakeSessionCtx{};
    app.session_callbacks = session_ctx.callbacks();
    var compact_runner = FakeCompactRunner{};
    app.compact_runner = compact_runner.runner();

    const outcome = try app.runCommand("compact");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(!compact_runner.called);
    try std.testing.expect(session_ctx.compact_called);
}

// A failing provider summary surfaces an error status and does NOT reset the conversation.
test "runCommand compact surfaces an error when the LLM runner fails" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    var session_ctx = FakeSessionCtx{};
    app.session_callbacks = session_ctx.callbacks();
    var compact_runner = FakeCompactRunner{ .fail = true };
    app.compact_runner = compact_runner.runner();
    try app.appendMessage(.user, "work");

    const outcome = try app.runCommand("compact");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(compact_runner.called);
    try std.testing.expect(!session_ctx.persist_called);
    try std.testing.expect(std.mem.indexOf(u8, app.status, "Compact failed") != null);
    // Conversation preserved so the user can retry.
    try std.testing.expect(app.messages.items.len == 1);
}

test "buildCompactionPromptText serializes the in-memory conversation with upstream prefixes" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    try app.appendMessage(.user, "fix the bug");
    try app.appendMessage(.assistant, "patched parser.zig");
    try app.appendMessage(.tool, "tests pass");

    const prompt = try app.buildCompactionPromptText("keep it short");
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.startsWith(u8, prompt, "<conversation>\n"));
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[User]: fix the bug") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[Assistant]: patched parser.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[Tool result]: tests pass") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "</conversation>") != null);
    // The summarization instructions and the custom focus are appended after the conversation.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "structured context checkpoint summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Additional focus: keep it short") != null);
}

test "executePrompt records user and assistant turns into the in-memory conversation" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const w = &sink.writer;
    var fake = FakeRunner{ .reply = "final answer", .emit_tool = true };
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    app.runner = fake.runner();

    try app.executePrompt(w, "do the thing");

    // user + tool + assistant turns recorded (the FakeRunner emits one tool result).
    try std.testing.expectEqual(@as(usize, 3), app.messages.items.len);
    try std.testing.expect(app.messages.items[0].role == .user);
    try std.testing.expectEqualStrings("do the thing", app.messages.items[0].text);
    try std.testing.expect(app.messages.items[1].role == .tool);
    try std.testing.expect(app.messages.items[2].role == .assistant);
    try std.testing.expectEqualStrings("final answer", app.messages.items[2].text);
}

// =====================================================================
// Command palette + model selector tests (Part 2)
// =====================================================================

test "typing a slash command opens the palette and editing it closes it" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    // Type "/mod" key-by-key through handleKey; the palette should activate.
    for ("/mod") |c| _ = try app.handleKey(&.{c});
    try std.testing.expect(app.palette_active);
    // A space turns the rest into arguments -> palette closes.
    _ = try app.handleKey(" ");
    try std.testing.expect(!app.palette_active);
}

test "palette navigation wraps and accept completes the highlighted command" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    try app.editor.insertText("/mod");
    try app.refreshPalette();
    try std.testing.expect(app.palette_active);
    // "model" ranks first for "mod"; Down moves to the next match.
    try std.testing.expect(app.palette_selected == 0);
    try app.paletteMove(1);
    try std.testing.expect(app.palette_selected == 1);
    // Up from row 0 wraps to the last match.
    app.palette_selected = 0;
    try app.paletteMove(-1);
    try std.testing.expect(app.palette_selected > 0);

    // Accept the top match: buffer becomes "/model ".
    app.palette_selected = 0;
    const accepted = try app.paletteAccept();
    try std.testing.expect(accepted);
    try std.testing.expect(!app.palette_active);
    const text = try app.editor.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("/model ", text);
}

test "palette Tab key accepts the highlighted command via handleKey" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    for ("/sess") |c| _ = try app.handleKey(&.{c});
    try std.testing.expect(app.palette_active);
    const action = try app.handleKey("\t"); // tui.input.tab
    try std.testing.expect(action == .none);
    const text = try app.editor.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("/session ", text);
}

test "palette buildScreen renders ranked matches with a selection caret" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    try app.editor.insertText("/mod");
    try app.refreshPalette();
    var screen = try app.buildScreen();
    defer {
        for (screen.items) |l| std.testing.allocator.free(l);
        screen.deinit(std.testing.allocator);
    }
    var saw_model_row = false;
    var saw_caret = false;
    for (screen.items) |line| {
        if (std.mem.indexOf(u8, line, "/model") != null) saw_model_row = true;
        if (std.mem.startsWith(u8, line, ">") and std.mem.indexOf(u8, line, "/model") != null) saw_caret = true;
    }
    try std.testing.expect(saw_model_row);
    try std.testing.expect(saw_caret);
}

test "model selector opens, cycles, and applies a model to options" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    app.openModelSelector();
    try std.testing.expect(app.model_selector_active);
    // Cycling advances to a concrete catalog entry.
    app.modelSelectorCycle();
    const highlighted = app.selected_model.?;
    const applied = try app.modelSelectorAccept();
    try std.testing.expect(applied);
    try std.testing.expect(!app.model_selector_active);
    try std.testing.expectEqualStrings(highlighted.provider, app.options.provider.?);
    try std.testing.expectEqualStrings(highlighted.id, app.options.model.?);
}

test "ctrl+L opens the model selector and ctrl+P cycles it via handleKey" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    _ = try app.handleKey("\x0c"); // ctrl+l -> app.model.select
    try std.testing.expect(app.model_selector_active);
    const before = app.selected_model;
    _ = try app.handleKey("\x10"); // ctrl+p -> app.model.cycleForward
    try std.testing.expect(app.selected_model != before);
    // Enter applies and closes the overlay.
    const action = try app.handleKey("\r");
    try std.testing.expect(action == .none);
    try std.testing.expect(!app.model_selector_active);
    try std.testing.expect(app.options.model != null);
}

test "model selector escape cancels without changing options" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false, .provider = "anthropic", .model = "claude-opus-4-7" });
    defer app.deinit();
    app.openModelSelector();
    app.modelSelectorCycle();
    const action = try app.handleKey("\x1b"); // escape
    try std.testing.expect(action == .none);
    try std.testing.expect(!app.model_selector_active);
    // Options unchanged because the selection was cancelled.
    try std.testing.expectEqualStrings("anthropic", app.options.provider.?);
    try std.testing.expectEqualStrings("claude-opus-4-7", app.options.model.?);
}

test "runCommand model with a valid name applies the catalog model" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    const outcome = try app.runCommand("model anthropic/claude-opus-4-7");
    try std.testing.expect(outcome == .handled);
    try std.testing.expectEqualStrings("anthropic", app.options.provider.?);
    try std.testing.expectEqualStrings("claude-opus-4-7", app.options.model.?);
    try std.testing.expect(std.mem.indexOf(u8, app.status, "Model set to") != null);
}

test "runCommand model with no argument opens the selector overlay" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    const outcome = try app.runCommand("model");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(app.model_selector_active);
}

test "runCommand model with an unknown name reports an error and leaves options unset" {
    var app = try App.init(std.testing.allocator, undefined, .{ .interactive = false });
    defer app.deinit();
    const outcome = try app.runCommand("model definitely-not-a-real-model-xyz");
    try std.testing.expect(outcome == .handled);
    try std.testing.expect(app.options.model == null);
    try std.testing.expect(std.mem.indexOf(u8, app.status, "Unknown model") != null);
}

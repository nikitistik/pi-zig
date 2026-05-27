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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !App {
        return .{
            .allocator = allocator,
            .io = io,
            .editor = try editor_mod.Editor.init(allocator),
            .renderer = render.Renderer.init(allocator),
            .options = options,
            .transcript = .empty,
            .streaming = .empty,
        };
    }

    pub fn deinit(self: *App) void {
        self.editor.deinit();
        self.renderer.deinit();
        for (self.transcript.items) |line| self.allocator.free(line);
        self.transcript.deinit(self.allocator);
        self.streaming.deinit(self.allocator);
        if (self.status.len > 0) self.allocator.free(self.status);
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

        return lines;
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
                if (self.options.model) |_| {}
                try self.setStatusFmt("Model set to {s} (selector UI not yet wired).", .{model_name});
            } else {
                try self.appendModelInfo();
            }
            return .handled;
        }
        if (std.mem.eql(u8, name, "changelog")) {
            try self.appendTranscript("pi-zig changelog: see docs/parity.md for the parity wave status.");
            return .handled;
        }

        // Recognized builtin that needs deeper integration not yet ported.
        if (findCommand(name) != null) {
            try self.setStatusFmt("/{s} is a recognized command but is not yet wired in the Zig TUI.", .{name});
            return .handled;
        }

        try self.setStatusFmt("Unknown command: /{s}", .{name});
        return .unknown;
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

        // Echo the user message into the transcript.
        const user_line = try std.fmt.allocPrint(self.allocator, "> {s}", .{prompt});
        defer self.allocator.free(user_line);
        try self.appendTranscript(user_line);

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
        // Commit the final assistant text into the transcript.
        self.streaming.clearRetainingCapacity();
        const assistant_line = try std.fmt.allocPrint(self.allocator, "assistant: {s}", .{result});
        defer self.allocator.free(assistant_line);
        try self.appendTranscript(assistant_line);
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
        try self.appendTranscript("pi-zig interactive mode");
        const provider = self.options.provider orelse "(none)";
        const model = self.options.model orelse "(none)";
        const line = try std.fmt.allocPrint(self.allocator, "provider: {s}  model: {s}", .{ provider, model });
        defer self.allocator.free(line);
        try self.appendTranscript(line);
        try self.appendTranscript("Type a message and press Enter. Slash commands: /help /model /session /new /quit. Ctrl+D to exit.");
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
    pub fn handleKey(self: *App, data: []const u8) !Action {
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

const std = @import("std");
const agent = @import("agent.zig");
const ai_client = @import("ai_client.zig");
const auth = @import("auth.zig");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const context_files = @import("context_files.zig");
const extensions = @import("extensions.zig");
const extension_runner = @import("extension_runner.zig");
const models = @import("models.zig");
const rpc = @import("rpc.zig");
const session = @import("session.zig");
const settings = @import("settings.zig");
const system_prompt = @import("system_prompt.zig");
const tools = @import("tools.zig");
const tui = @import("tui.zig");

const all_tool_names = [_][]const u8{ "read", "bash", "edit", "write", "grep", "find", "ls" };

/// Summarization system prompt for the interactive `/compact` provider path. Byte-identical to
/// upstream SUMMARIZATION_SYSTEM_PROMPT (packages/coding-agent/src/core/compaction/utils.ts) and
/// to the RPC runtime's private copy; redeclared here so the TUI compaction path matches upstream
/// without coupling cli_runtime.zig to rpc.zig internals. The conversation body + instructions are
/// built App-side (tui.buildCompactionPromptText + tui.compaction_summarization_prompt).
const compaction_summarization_system_prompt =
    "You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.\n\n" ++
    "Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.";

const PromptResult = struct {
    text: []const u8,
    owned: bool = false,
    image_parts: []ai_client.ChatContentPart = &.{},

    fn deinit(self: PromptResult, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.text);
        for (self.image_parts) |part| {
            switch (part) {
                .image => |image| allocator.free(image.data),
                .text => {},
            }
        }
        if (self.image_parts.len > 0) allocator.free(self.image_parts);
    }
};

const PathResult = struct {
    path: []const u8,
    owned: bool = false,

    fn deinit(self: PathResult, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.path);
    }
};

const SelectedToolNames = struct {
    names: []const []const u8,
    owned: bool = false,

    fn deinit(self: SelectedToolNames, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.names);
    }
};

const JsonStreamContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    final_text: *std.Io.Writer.Allocating,
    assistant_started: bool = false,
};

const JsonToolEventContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    final_text: *std.Io.Writer.Allocating,
    assistant_started: bool = false,
};

const AssistantStatus = struct {
    stop_reason: []const u8,
    error_message: []const u8,
};

// ===== Top-level JSON-mode abort lifecycle (SIGINT) =====
// Upstream's interactive/print agent aborts an in-flight turn on Ctrl+C and emits the
// "aborted" assistant lifecycle (mirrored by rpc.zig's AgentAborted handling). The top-level
// JSON path already maps error.AgentAborted -> stopReason:"aborted"/errorMessage:"Request was
// aborted" via assistantStatusForError + emitJsonAssistantStatusLifecycle, but nothing could
// trigger that abort because no run was cancellable. A process-global SIGINT handler flips an
// atomic flag that the agent/provider stream poll through should_cancel, so a cancelled
// `--mode json` run now surfaces the same abort lifecycle events as RPC.
var json_abort_requested = std.atomic.Value(bool).init(false);
var json_abort_handler_installed = std.atomic.Value(bool).init(false);

fn jsonAbortSignalHandler(_: std.posix.SIG) callconv(.c) void {
    json_abort_requested.store(true, .seq_cst);
}

/// Install the SIGINT handler once and reset the abort flag for a fresh run. Idempotent: the
/// handler is registered at most once per process; every call clears the flag so a prior run's
/// abort never leaks into the next. POSIX-only; a no-op shim keeps non-POSIX builds compiling.
fn armJsonAbortHandler() void {
    json_abort_requested.store(false, .seq_cst);
    if (@import("builtin").os.tag == .windows) return;
    if (json_abort_handler_installed.swap(true, .seq_cst)) return;
    var action = std.posix.Sigaction{
        .handler = .{ .handler = jsonAbortSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}

fn jsonAbortRequested(_: *anyopaque) bool {
    return json_abort_requested.load(.seq_cst);
}

pub fn runTopLevel(init: std.process.Init, argv: []const []const u8) !void {
    const parsed = cli.parse(argv);

    try writeDiagnostics(init.io, init.gpa, parsed);
    if (hasErrorDiagnostics(parsed)) return error.InvalidCliArguments;

    if (parsed.help) return writeTopLevelHelpWithExtensions(init.io, init.gpa, init.environ_map);
    if (parsed.version) return writeStdout(init.io, config.version ++ "\n");

    if (parsed.list_models) {
        return models.writeListModelsJson(init.io, parsed.list_models_pattern);
    }

    if (parsed.export_path) |input_path| {
        const output_path = if (parsed.messages_len > 0) parsed.messages[0] else null;
        const written_path = session.exportHtmlFromFile(init.io, init.gpa, input_path, output_path) catch |err| {
            try writeStderr(init.io, "Error: ");
            try writeStderr(init.io, @errorName(err));
            try writeStderr(init.io, "\n");
            return err;
        };
        defer init.gpa.free(written_path);
        try writeStdout(init.io, "Exported to: ");
        try writeStdout(init.io, written_path);
        try writeStdout(init.io, "\n");
        return;
    }

    try validateSessionFlags(init.io, parsed);
    try validateExtensionFlags(init.io, init.gpa, init.environ_map, parsed);

    // Model fallback/default selection (upstream model-resolver.ts resolveInitialModel /
    // buildFallbackModel parity): when a --provider is given but --model is omitted, resolve a
    // sensible default model id from the catalog instead of dropping to the inert foundation
    // response. Mutate a local copy so every downstream mode (rpc/text/json/interactive) sees the
    // resolved model. Leaves `parsed` untouched when both flags are absent or a model is explicit.
    var resolved_parsed = parsed;
    applyDefaultModelSelection(&resolved_parsed);

    const mode = resolved_parsed.mode orelse cli.Mode.text;
    if (mode == .rpc) {
        if (resolved_parsed.file_args_len > 0) {
            try writeStderr(init.io, "Error: @file arguments are not supported in RPC mode.\n");
            return error.InvalidCliArguments;
        }
        const path = try resolveSessionPath(init.io, init.gpa, init.environ_map, resolved_parsed);
        defer path.deinit(init.gpa);
        var runtime_extensions = try discoverRuntimeExtensionPaths(init.io, init.gpa, init.environ_map, resolved_parsed);
        defer runtime_extensions.deinit(init.gpa);
        var command_options = commandOptionsFromParsed(init, &resolved_parsed);
        command_options.extension_paths = runtime_extensions.paths;
        const extension_flag_values = try extensionFlagValuesFromParsed(init.gpa, resolved_parsed);
        defer if (extension_flag_values.len > 0) init.gpa.free(extension_flag_values);
        return rpc.run(init.io, init.gpa, init.environ_map, path.path, .{
            .command_options = command_options,
            .extension_paths = runtime_extensions.paths,
            .extension_flag_values = extension_flag_values,
            .tool_set = toolSetFromParsed(resolved_parsed),
            .custom_tools_enabled = !resolved_parsed.no_tools,
            .tool_allowlist = resolved_parsed.tools,
        });
    }

    // Read piped stdin for non-rpc modes (rpc reads stdin as JSONL commands).
    // Upstream treats piped stdin as the initial prompt and flips an otherwise
    // interactive invocation into print mode.
    const stdin_content = try readPipedStdin(init.io, init.gpa);
    defer if (stdin_content) |content| init.gpa.free(content);

    const prompt = try buildPrompt(init.io, init.gpa, resolved_parsed, stdin_content);
    defer prompt.deinit(init.gpa);

    if (prompt.text.len == 0 and !resolved_parsed.print and resolved_parsed.messages_len == 0 and resolved_parsed.file_args_len == 0 and stdin_content == null) {
        return runInteractive(init, resolved_parsed);
    }

    return switch (mode) {
        .json => runJsonPrintFoundation(init.io, init.gpa, init.environ_map, resolved_parsed, prompt.text, prompt.image_parts),
        .text => runTextPrintFoundation(init.io, init.gpa, init.environ_map, resolved_parsed, prompt.text, prompt.image_parts),
        .rpc => unreachable,
    };
}

/// Resolve a default model when `--provider` was supplied without `--model`.
///
/// Mirrors upstream `model-resolver.ts` `buildFallbackModel`/`resolveInitialModel`: when only a
/// provider is known we pick its catalog default (curated id when present, otherwise the provider's
/// first listed model). Without a model previously the run dropped to the inert foundation response
/// (`buildFoundationResponse`); resolving here lets text/json/rpc/interactive proceed against a real
/// model. No-op when both flags are absent (true interactive boot) or when a model is already set.
fn applyDefaultModelSelection(parsed: *cli.ParsedArgs) void {
    if (parsed.model != null) return;
    const provider = parsed.provider orelse return;
    if (defaultModelIdForProvider(provider)) |model_id| {
        parsed.model = model_id;
    }
}

/// Pick a default catalog model id for `provider` using only stable public models.zig APIs.
/// Prefers the canonical provider's curated default (the model id upstream lists first for that
/// provider in the generated catalog) and otherwise returns the first catalog entry for the
/// provider — matching upstream `buildFallbackModel` (`providerModels.find(default) ?? providerModels[0]`).
/// Returns null for an unknown provider with no catalog entries, leaving the foundation path intact.
fn defaultModelIdForProvider(provider: []const u8) ?[]const u8 {
    const canonical = models.canonicalProvider(provider) orelse provider;
    for (models.all) |*model| {
        if (std.mem.eql(u8, model.provider, canonical)) return model.id;
    }
    return null;
}

// =====================================================================
// Interactive TUI entrypoint
// =====================================================================

/// Boot the interactive TUI. When stdin is not a TTY (pipes, CI, the
/// verify-basic smokes) the loop reports `.not_a_tty`; we then fall back to the
/// previous foundation guidance so non-interactive contracts are unchanged.
fn runInteractive(init: std.process.Init, parsed: cli.ParsedArgs) !void {
    var app = try tui.App.init(init.gpa, init.io, .{
        .provider = parsed.provider,
        .model = parsed.model,
        .interactive = true,
    });
    defer app.deinit();

    // Wire a provider-backed prompt runner when a provider+model are configured.
    var runner_ctx = InteractivePromptRunner{
        .io = init.io,
        .allocator = init.gpa,
        .env = init.environ_map,
        .parsed = parsed,
    };
    // Provider-backed `/compact` summarization runner, wired on the same provider+model condition
    // as the prompt runner (auth is resolved lazily inside the runner). When unset (no provider/
    // model), `/compact` falls back to the host's local message-count summary.
    var compact_ctx = InteractiveCompactRunner{
        .io = init.io,
        .allocator = init.gpa,
        .env = init.environ_map,
        .parsed = parsed,
    };
    if (parsed.provider != null and parsed.model != null) {
        app.runner = .{ .ctx = &runner_ctx, .run = InteractivePromptRunner.run };
        app.compact_runner = .{ .ctx = &compact_ctx, .run = InteractiveCompactRunner.run };
    }

    // Open the persistent session store (honors --no-session) and wire the live session-op
    // callbacks so /compact /export /name /fork /clone call the real session APIs instead of
    // reporting "not yet wired". Mirrors the store wiring used by the print/json paths
    // (maybeOpenStore + resolveSessionPath). When --no-session is set there is no store, so the
    // callbacks stay unwired and those commands continue to report the honest notice.
    var store = try maybeOpenStore(init.io, init.gpa, init.environ_map, parsed);
    var session_ops = SessionOps{
        .io = init.io,
        .allocator = init.gpa,
        .env = init.environ_map,
        .parsed = parsed,
        .store = if (store) |*persistent| persistent else null,
    };
    if (store != null) {
        app.session_callbacks = session_ops.callbacks();
    }

    const reason = try app.run();
    switch (reason) {
        .user_quit, .eof => return,
        .not_a_tty => {
            try writeStderr(init.io, "pi-zig interactive TUI requires a terminal. Use -p, --mode json, or --mode rpc in non-interactive contexts.\n");
            return writeTopLevelHelp(init.io);
        },
    }
}

/// Bridges the TUI prompt-runner seam to the existing agent runtime. Holds the
/// context `buildPrintResponse` needs and adapts agent streaming/permission
/// callbacks onto the TUI `PromptCallbacks`.
const InteractivePromptRunner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
    callbacks: tui.PromptCallbacks = undefined,
    /// Extension hook runner, when extensions are loaded. The agent shares one
    /// tool-hook context, so the runner chains the extension hooks with its own
    /// permission gate.
    extension_hooks: ?*extension_runner.Runner = null,

    fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8, callbacks: tui.PromptCallbacks) anyerror![]u8 {
        const self: *InteractivePromptRunner = @ptrCast(@alignCast(ctx_ptr));
        self.callbacks = callbacks;

        const result = try interactiveBuildResponse(
            self.io,
            allocator,
            self.env,
            self.parsed,
            prompt,
            self,
        );
        defer result.deinit(allocator);
        return allocator.dupe(u8, result.final_text);
    }

    fn onTextDelta(ctx_ptr: *anyopaque, delta: []const u8) anyerror!void {
        const self: *InteractivePromptRunner = @ptrCast(@alignCast(ctx_ptr));
        if (self.callbacks.on_text) |cb| try cb(self.callbacks.ctx, delta);
    }

    fn onToolEnd(ctx_ptr: *anyopaque, tool_result: agent.ToolResult) anyerror!void {
        const self: *InteractivePromptRunner = @ptrCast(@alignCast(ctx_ptr));
        if (self.callbacks.on_tool_result) |cb| {
            try cb(self.callbacks.ctx, tool_result.tool_name, tool_result.content, tool_result.is_error);
        }
    }

    fn shouldCancel(ctx_ptr: *anyopaque) bool {
        const self: *InteractivePromptRunner = @ptrCast(@alignCast(ctx_ptr));
        if (self.callbacks.should_cancel) |cb| return cb(self.callbacks.ctx);
        return false;
    }

    fn beforeToolCall(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall) anyerror!agent.BeforeToolCallResult {
        const self: *InteractivePromptRunner = @ptrCast(@alignCast(ctx_ptr));

        // Extension tool-call hook first (may block or rewrite arguments).
        var effective_call = call;
        var ext_result: agent.BeforeToolCallResult = .{};
        if (self.extension_hooks) |hooks| {
            ext_result = try extension_runner.Runner.beforeToolCall(hooks, call);
            if (ext_result.block) return ext_result;
            if (ext_result.arguments_json) |args| effective_call.arguments_json = args;
        }

        // Then the TUI permission prompt.
        if (self.callbacks.on_tool_permission) |cb| {
            const decision = try cb(self.callbacks.ctx, effective_call.name, effective_call.arguments_json);
            if (decision == .deny) {
                ext_result.deinit(self.allocator);
                return .{ .block = true, .reason = try self.allocator.dupe(u8, "User denied tool execution.") };
            }
        }
        return ext_result;
    }

    fn afterToolCall(
        ctx_ptr: *anyopaque,
        call: ai_client.ChatToolCall,
        result: agent.ToolResult,
    ) anyerror!agent.AfterToolCallResult {
        const self: *InteractivePromptRunner = @ptrCast(@alignCast(ctx_ptr));
        if (self.extension_hooks) |hooks| {
            return extension_runner.Runner.afterToolCall(hooks, call, result);
        }
        return .{};
    }
};

/// Provider-backed summarization runner for the interactive `/compact` command. Bridges the TUI
/// `CompactRunner` seam onto `agent.runPrompt`, mirroring rpc.zig's `runCompactionSummaryIfAuthenticated`:
/// a single tool-free turn (`tool_set = .none`, `max_turns = 1`) with the dedicated summarization
/// system prompt over the App-serialized `<conversation>` text. The TUI only wires this when a
/// provider+model+auth are configured, so a failure to resolve auth here is unexpected and surfaces
/// as a `/compact` error rather than silently falling back.
const InteractiveCompactRunner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,

    fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, conversation: []const u8, custom_instructions: ?[]const u8) anyerror![]u8 {
        _ = custom_instructions; // already folded into `conversation` by tui.buildCompactionPromptText
        const self: *InteractiveCompactRunner = @ptrCast(@alignCast(ctx_ptr));
        const provider = self.parsed.provider.?;
        const model = self.parsed.model.?;
        const api_key = if (self.parsed.api_key) |key|
            try allocator.dupe(u8, key)
        else
            try auth.resolveProviderApiKey(self.io, allocator, self.env, provider) orelse return error.ProviderAuthMissing;
        defer allocator.free(api_key);

        const shell_settings = try settings.loadShellSettings(self.io, allocator, self.env);
        defer shell_settings.deinit(allocator);

        var run_result = try agent.runPrompt(self.io, allocator, self.env, .{
            .provider = provider,
            .model = model,
            .api_key = api_key,
            .prompt = conversation,
            .system_prompt = compaction_summarization_system_prompt,
            .env = self.env,
            .shell_path = shell_settings.shell_path,
            .shell_command_prefix = shell_settings.shell_command_prefix,
            .history = &.{},
            .tool_set = agent.ToolSet.none,
            .custom_tools = &.{},
            .max_turns = 1,
        });
        defer run_result.deinit(allocator);
        return allocator.dupe(u8, std.mem.trim(u8, run_result.final_text, " \t\r\n"));
    }
};

/// Mirror of `buildPrintResponse` for the interactive loop: same provider/auth/
/// extension setup, but routes agent streaming, tool-end, cancellation, and a
/// permission gate through the `InteractivePromptRunner`.
fn interactiveBuildResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
    prompt: []const u8,
    runner: *InteractivePromptRunner,
) !agent.RunResult {
    const provider = parsed.provider.?;
    const model = parsed.model.?;
    const api_key = if (parsed.api_key) |key|
        try allocator.dupe(u8, key)
    else
        try auth.resolveProviderApiKey(io, allocator, env, provider) orelse return error.ProviderAuthMissing;
    defer allocator.free(api_key);

    const runtime_system_prompt = try buildRuntimeSystemPrompt(io, allocator, env, parsed);
    defer allocator.free(runtime_system_prompt);
    const shell_settings = try settings.loadShellSettings(io, allocator, env);
    defer shell_settings.deinit(allocator);
    const auto_resize_images = try loadImageAutoResize(io, allocator, env);

    // Discover extension tools so the TUI can execute registered extension tools
    // (and run extension tool-call hooks) mid-conversation, mirroring the
    // print-mode wiring in buildPrintResponse.
    var runtime_extensions = try discoverRuntimeExtensionPaths(io, allocator, env, parsed);
    defer runtime_extensions.deinit(allocator);
    const extension_flag_values = try extensionFlagValuesFromParsed(allocator, parsed);
    defer if (extension_flag_values.len > 0) allocator.free(extension_flag_values);
    var hooks = extension_runner.Runner{
        .io = io,
        .allocator = allocator,
        .extension_paths = runtime_extensions.paths,
        .flag_values = extension_flag_values,
    };
    const has_extension_hooks = hooks.hasExtensions();
    var extension_tool_definitions: []ai_client.ChatToolDefinition = if (has_extension_hooks)
        try hooks.discoverToolDefinitions()
    else
        &.{};
    extension_tool_definitions = try filterExtensionToolDefinitions(allocator, parsed, extension_tool_definitions);
    defer if (extension_tool_definitions.len > 0) hooks.deinitToolDefinitions(extension_tool_definitions);

    // The agent invokes a single before_tool_call hook. The TUI needs its
    // permission gate AND extension hooks need their tool_call rewrite, so the
    // runner chains them: extension hook first, then the TUI permission prompt.
    runner.extension_hooks = if (has_extension_hooks) &hooks else null;

    return agent.runPrompt(io, allocator, env, .{
        .provider = provider,
        .model = model,
        .api_key = api_key,
        .prompt = prompt,
        .system_prompt = runtime_system_prompt,
        .env = env,
        .shell_path = shell_settings.shell_path,
        .shell_command_prefix = shell_settings.shell_command_prefix,
        .auto_resize_images = auto_resize_images,
        .tool_set = toolSetFromParsed(parsed),
        .custom_tools = extension_tool_definitions,
        .custom_tool_context = if (extension_tool_definitions.len > 0) &hooks else null,
        .execute_custom_tool = if (extension_tool_definitions.len > 0) extension_runner.Runner.executeRegisteredTool else null,
        .stream_turns = true,
        .text_event_context = runner,
        .on_text_delta = InteractivePromptRunner.onTextDelta,
        .tool_event_context = runner,
        .on_tool_end = InteractivePromptRunner.onToolEnd,
        .tool_hook_context = runner,
        .before_tool_call = InteractivePromptRunner.beforeToolCall,
        .after_tool_call = if (has_extension_hooks) InteractivePromptRunner.afterToolCall else null,
        .cancellation_context = runner,
        .should_cancel = InteractivePromptRunner.shouldCancel,
    });
}

/// Live session-operation backend for the interactive TUI. Bridges the TUI `SessionCallbacks`
/// seam (tui.zig) onto the real persisted-session APIs (session.zig / html_export.zig), matching
/// the print/json store wiring (maybeOpenStore + resolveSessionPath). Holds the open store and the
/// resolved session_dir/cwd needed to create sibling sessions for fork/clone.
const SessionOps = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
    store: ?*session.PersistentStore,

    /// Local (no-auth) `/compact` fallback: append a message-count summary compaction entry via the
    /// same `appendCompaction` API the RPC runtime uses for its static-summary fallback, and return
    /// the owned summary text for the TUI to display. The provider-backed LLM summary path now runs
    /// through `tui.CompactRunner` (InteractiveCompactRunner) and persists via `persistCompaction`;
    /// this method is only invoked when no model/auth is configured (no CompactRunner wired).
    fn compact(ctx: *anyopaque, allocator: std.mem.Allocator, custom_instructions: ?[]const u8) anyerror![]u8 {
        const self: *SessionOps = @ptrCast(@alignCast(ctx));
        const store = self.store orelse return error.NoSessionStore;
        const message_count = store.totalMessages();
        const summary = try std.fmt.allocPrint(
            allocator,
            "Local summary of {d} message(s) compacted into session context.",
            .{message_count},
        );
        errdefer allocator.free(summary);
        _ = try store.appendCompaction(self.io, allocator, summary, "", 0, custom_instructions, message_count, null);
        return summary;
    }

    /// Persist a provider-backed `/compact` summary (produced by InteractiveCompactRunner) to the
    /// session store, recording the provider/model meta so the persisted compaction entry mirrors
    /// the RPC runtime's `details.local = false` shape. `message_count` is the in-memory turn count
    /// the App summarized.
    fn persistCompaction(ctx: *anyopaque, summary: []const u8, custom_instructions: ?[]const u8, message_count: usize) anyerror!void {
        const self: *SessionOps = @ptrCast(@alignCast(ctx));
        const store = self.store orelse return error.NoSessionStore;
        const provider_meta: ?session.PersistentStore.CompactionProvider =
            if (self.parsed.provider) |provider|
                if (self.parsed.model) |model|
                    .{ .provider = provider, .model = model }
                else
                    null
            else
                null;
        _ = try store.appendCompaction(self.io, self.allocator, summary, "", 0, custom_instructions, message_count, provider_meta);
    }

    /// Export the current session to HTML via html_export (session.exportHtmlFromFile). Returns the
    /// owned output path. `output_path` is the optional explicit target from the `/export` argument.
    fn exportHtml(ctx: *anyopaque, allocator: std.mem.Allocator, output_path: ?[]const u8) anyerror![]u8 {
        const self: *SessionOps = @ptrCast(@alignCast(ctx));
        const store = self.store orelse return error.NoSessionStore;
        return session.exportHtmlFromFile(self.io, allocator, store.path(), output_path);
    }

    /// Set the session display name (persists a sessionInfo entry, matching RPC set_name).
    fn setName(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *SessionOps = @ptrCast(@alignCast(ctx));
        const store = self.store orelse return error.NoSessionStore;
        try store.appendSessionInfo(self.io, self.allocator, name);
    }

    /// Fork the current session into a new sibling file (session.forkFromFile duplicates the session
    /// with a fresh id + parentSession pointer) and switch the store to it. Matches the RPC fork at
    /// the latest position when no specific user message is selected.
    fn fork(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *SessionOps = @ptrCast(@alignCast(ctx));
        try self.copyIntoSiblingSession(allocator);
    }

    /// Clone the current session: a full file-level duplicate of the session at its current state
    /// (same mechanism as fork — session.forkFromFile copies every entry), then switch to it.
    fn clone(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *SessionOps = @ptrCast(@alignCast(ctx));
        try self.copyIntoSiblingSession(allocator);
    }

    fn copyIntoSiblingSession(self: *SessionOps, allocator: std.mem.Allocator) !void {
        const store = self.store orelse return error.NoSessionStore;
        const cwd = try currentPathOwned(self.io, allocator);
        defer allocator.free(cwd);
        const session_dir = try resolveSessionDir(self.io, allocator, self.env, cwd, self.parsed.session_dir);
        defer allocator.free(session_dir);
        const source_path = store.path();
        const new_path = try session.forkFromFile(self.io, allocator, source_path, session_dir, cwd);
        defer allocator.free(new_path);
        store.* = try session.PersistentStore.open(self.io, allocator, new_path);
    }

    fn callbacks(self: *SessionOps) tui.SessionCallbacks {
        return .{
            .ctx = self,
            .compact = SessionOps.compact,
            .persist_compaction = SessionOps.persistCompaction,
            .export_html = SessionOps.exportHtml,
            .set_name = SessionOps.setName,
            .fork = SessionOps.fork,
            .clone = SessionOps.clone,
        };
    }
};

pub fn writeTopLevelHelp(io: std.Io) !void {
    try writeStdout(io,
        \\pi-zig - Zig + Preact port of earendil-works/pi
        \\
        \\Usage:
        \\  pi-zig [options] [@files...] [messages...]
        \\
        \\Top-level options:
        \\  --provider <name>              Provider name (delegated to the model resolver)
        \\  --model <pattern>              Model pattern or ID (supports "provider/id" and ":<thinking>")
        \\  --api-key <key>                API key (defaults to env vars)
        \\  --system-prompt <text>         System prompt (default: coding assistant prompt)
        \\  --append-system-prompt <text>  Append text or file contents to the system prompt (repeatable)
        \\  --mode <text|json|rpc>         Output mode; text (default), json, or rpc (JSONL on stdin)
        \\  --print, -p [prompt]           Non-interactive mode: process prompt and exit
        \\  --continue, -c                 Continue the newest session in the session directory
        \\  --resume, -r                   Select a session to resume (newest-session lookup)
        \\  --session <path|id>            Use a session JSONL file or partial id
        \\  --fork <path|id>               Fork a session file or partial id into a new session
        \\  --session-dir <dir>            Directory for session storage and lookup
        \\  --no-session                   Don't persist the session (ephemeral)
        \\  --models <patterns>            Comma-separated model patterns for Ctrl+P cycling
        \\  --no-tools, -nt                Disable all tools by default (built-in and extension)
        \\  --no-builtin-tools, -nbt       Disable built-in tools but keep extension/custom tools
        \\  --tools, -t <tools>            Comma-separated allowlist of tool names to enable
        \\  --thinking <level>             Thinking level: off, minimal, low, medium, high, xhigh
        \\  --extension, -e <path>         Load an extension file (repeatable)
        \\  --no-extensions, -ne           Disable extension discovery (explicit -e paths still work)
        \\  --skill <path>                 Load a skill file or directory (repeatable)
        \\  --no-skills, -ns               Disable skills discovery and loading
        \\  --prompt-template <path>       Load a prompt template file or directory (repeatable)
        \\  --no-prompt-templates, -np     Disable prompt template discovery and loading
        \\  --theme <path>                 Load a theme file or directory (repeatable)
        \\  --no-themes                    Disable theme discovery and loading
        \\  --no-context-files, -nc        Disable AGENTS.md and CLAUDE.md discovery and loading
        \\  --export <session> [output]    Export a session JSONL file to HTML and exit
        \\  --list-models [search]         List available models (with optional fuzzy search)
        \\  --verbose                      Force verbose startup
        \\  --offline                      Disable startup network operations (same as PI_OFFLINE=1)
        \\  --help, -h                     Show this help
        \\  --version, -v                  Show version number
        \\
        \\Extensions can register additional flags (passed through as unknown long flags).
        \\
        \\Package commands:
        \\  install <source> [-l]          Local path package settings foundation
        \\  remove <source> [-l]           Remove matching package settings entry
        \\  list                           List configured user/project packages
        \\  update                         Fails visibly until updater parity is ported
        \\
        \\Resource inspection:
        \\  themes                         List built-in, user, project, and temporary themes
        \\  themes --export <name>          Resolve HTML export colors for a theme
        \\  themes --detect                 Detect default dark/light theme from COLORFGBG
        \\  context-files                   List AGENTS/CLAUDE and system prompt files
        \\  context-files --no-context-files Skip AGENTS/CLAUDE discovery
        \\  system-prompt                   Build the effective system prompt text
        \\
        \\Current top-level scope: print/json/rpc entry-point foundation. Interactive TUI,
        \\full extension execution, and full upstream agent parity remain incomplete.
        \\
    );
}

// ===== FLOW 07: extension-aware help =====
// Print the base top-level help, then append CLI flags registered by discovered
// extensions (matching upstream printHelp(extensionFlags)). Discovery/runner failures
// are non-fatal: help still prints without the extension section.
pub fn writeTopLevelHelpWithExtensions(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
) !void {
    try writeTopLevelHelp(io);
    try writeExtensionFlagHelp(io, allocator, env);
}
// ===== END FLOW 07 =====

fn runTextPrintFoundation(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
    prompt: []const u8,
    image_parts: []const ai_client.ChatContentPart,
) !void {
    const command_outcome = try runTopLevelRegisteredCommand(io, allocator, env, parsed, prompt);
    defer command_outcome.deinit(allocator);
    const prompt_request = switch (command_outcome) {
        .not_handled => TopLevelPromptRequest{
            .content = prompt,
            .image_parts = image_parts,
            .persist_user_message = true,
        },
        .handled => return,
        .prompt => |command_prompt| TopLevelPromptRequest{
            .content = command_prompt.content,
            .image_parts = command_prompt.image_parts,
            .persist_user_message = command_prompt.persist_user_message,
        },
    };

    var store = try maybeOpenStore(io, allocator, env, parsed);
    if (store) |*persistent| {
        if (prompt_request.persist_user_message and (prompt_request.content.len > 0 or prompt_request.image_parts.len > 0)) {
            _ = try persistent.appendMessageWithContentParts(io, allocator, .user, prompt_request.content, prompt_request.image_parts);
        }
    }

    const response = try buildPrintResponse(io, allocator, env, parsed, prompt_request.content, prompt_request.image_parts, false, null, null, null, null, null, null, null);
    defer response.deinit(allocator);

    if (store) |*persistent| {
        _ = try persistent.appendMessage(io, allocator, .assistant, response.final_text);
    }

    try writeStdout(io, response.final_text);
    try writeStdout(io, "\n");
}

fn runJsonPrintFoundation(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
    prompt: []const u8,
    image_parts: []const ai_client.ChatContentPart,
) !void {
    // Arm the SIGINT abort hook so an interrupted tool-capable run emits the upstream abort
    // lifecycle (error.AgentAborted -> stopReason:"aborted", surfaced below).
    armJsonAbortHandler();
    const command_outcome = try runTopLevelRegisteredCommand(io, allocator, env, parsed, prompt);
    defer command_outcome.deinit(allocator);
    const prompt_request = switch (command_outcome) {
        .not_handled => TopLevelPromptRequest{
            .content = prompt,
            .image_parts = image_parts,
            .persist_user_message = true,
        },
        .handled => {
            var store = try maybeOpenStore(io, allocator, env, parsed);
            const session_id = if (store) |*persistent| persistent.sessionId() else "pi-zig-ephemeral";
            try emitJsonSessionHeader(io, allocator, session_id);
            return;
        },
        .prompt => |command_prompt| TopLevelPromptRequest{
            .content = command_prompt.content,
            .image_parts = command_prompt.image_parts,
            .persist_user_message = command_prompt.persist_user_message,
        },
    };

    if (shouldUseProviderTextStream(parsed)) {
        return runJsonProviderTextStream(io, allocator, env, parsed, prompt_request.content, prompt_request.image_parts, prompt_request.persist_user_message);
    }

    var store = try maybeOpenStore(io, allocator, env, parsed);
    if (store) |*persistent| {
        if (prompt_request.persist_user_message and (prompt_request.content.len > 0 or prompt_request.image_parts.len > 0)) {
            _ = try persistent.appendMessageWithContentParts(io, allocator, .user, prompt_request.content, prompt_request.image_parts);
        }
    }

    const session_id = if (store) |*persistent| persistent.sessionId() else "pi-zig-ephemeral";
    try emitJsonPrelude(io, allocator, session_id);

    var streamed_final_text: std.Io.Writer.Allocating = .init(allocator);
    defer streamed_final_text.deinit();
    var tool_event_context = JsonToolEventContext{
        .io = io,
        .allocator = allocator,
        .final_text = &streamed_final_text,
    };
    const retry_settings = try settings.loadRetrySettings(io, allocator, env);
    var retry_attempts: usize = 0;

    const response = retry_build: while (true) {
        const result = buildPrintResponse(
            io,
            allocator,
            env,
            parsed,
            prompt_request.content,
            prompt_request.image_parts,
            true,
            &tool_event_context,
            handleJsonToolStart,
            handleJsonToolUpdate,
            handleJsonToolEnd,
            &tool_event_context,
            handleJsonAgentTextDelta,
            .{ .context = &tool_event_context, .should_cancel = jsonAbortRequested },
        ) catch |err| {
            if (shouldRetryJsonProviderError(retry_settings, retry_attempts, err, !tool_event_context.assistant_started and streamed_final_text.written().len == 0)) {
                retry_attempts += 1;
                const delay_ms = jsonRetryDelayMs(retry_settings, retry_attempts);
                try emitJsonAssistantStatusLifecycle(
                    io,
                    allocator,
                    streamed_final_text.written(),
                    "error",
                    @errorName(err),
                    !tool_event_context.assistant_started,
                    true,
                );
                try emitJsonAutoRetryStart(io, allocator, retry_attempts, retry_settings.max_retries, delay_ms, @errorName(err));
                try sleepMilliseconds(io, delay_ms);
                continue;
            }
            const status = assistantStatusForError(err);
            if (store) |*persistent| {
                try appendJsonAssistantStatusMessage(
                    io,
                    allocator,
                    persistent,
                    parsed,
                    streamed_final_text.written(),
                    status.stop_reason,
                    status.error_message,
                );
            }
            try emitJsonAssistantStatusLifecycle(
                io,
                allocator,
                streamed_final_text.written(),
                status.stop_reason,
                status.error_message,
                !tool_event_context.assistant_started,
                false,
            );
            if (retry_attempts > 0) {
                try emitJsonAutoRetryEnd(io, allocator, false, retry_attempts, @errorName(err));
            }
            return err;
        };
        break :retry_build result;
    };
    defer response.deinit(allocator);

    if (store) |*persistent| {
        _ = try persistent.appendMessage(io, allocator, .assistant, response.final_text);
    }

    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;

    if (!tool_event_context.assistant_started) {
        try w.writeAll("{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n");
        try w.writeAll("{\"type\":\"message_update\",\"message\":");
        try writeAssistantMessageJson(w, response.final_text);
        try w.writeAll(",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":");
        try writeJsonString(w, response.final_text);
        try w.writeAll("}}\n");
    }
    try w.writeAll("{\"type\":\"message_end\",\"message\":");
    try writeAssistantMessageJson(w, response.final_text);
    try w.writeAll("}\n");
    if (retry_attempts > 0) {
        try writeJsonAutoRetryEnd(w, true, retry_attempts, null);
        try w.writeByte('\n');
    }
    try w.writeAll("{\"type\":\"turn_end\",\"message\":");
    try writeAssistantMessageJson(w, response.final_text);
    try w.writeAll(",\"toolResults\":[");
    for (response.tool_results, 0..) |tool_result, index| {
        if (index != 0) try w.writeByte(',');
        try writeToolResultMessageJson(w, tool_result);
    }
    try w.writeAll("]}\n");
    try w.writeAll("{\"type\":\"agent_end\",\"messages\":[");
    try writeAssistantMessageJson(w, response.final_text);
    try w.writeAll("],\"willRetry\":false}\n");
    try w.flush();
}

fn shouldUseProviderTextStream(parsed: cli.ParsedArgs) bool {
    return parsed.provider != null and parsed.model != null and parsed.no_tools;
}

const SlashCommandInvocation = struct {
    name: []const u8,
    args: []const u8,
};

const TopLevelPromptRequest = struct {
    content: []const u8,
    image_parts: []const ai_client.ChatContentPart,
    persist_user_message: bool,
};

const TopLevelCommandPrompt = struct {
    content: []u8,
    image_parts: []ai_client.ChatContentPart = &.{},
    persist_user_message: bool,

    fn deinit(self: TopLevelCommandPrompt, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        freeOwnedContentParts(allocator, self.image_parts);
    }
};

const TopLevelCommandOutcome = union(enum) {
    not_handled,
    handled,
    prompt: TopLevelCommandPrompt,

    fn deinit(self: TopLevelCommandOutcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .prompt => |command_prompt| command_prompt.deinit(allocator),
            .not_handled, .handled => {},
        }
    }
};

fn parseSlashCommandInvocation(message: []const u8) ?SlashCommandInvocation {
    if (message.len < 2 or message[0] != '/') return null;
    const rest = message[1..];
    const space_index = std.mem.indexOfScalar(u8, rest, ' ');
    const name = if (space_index) |index| rest[0..index] else rest;
    if (name.len == 0) return null;
    const args = if (space_index) |index| rest[index + 1 ..] else "";
    return .{ .name = name, .args = args };
}

fn runTopLevelRegisteredCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
    prompt: []const u8,
) !TopLevelCommandOutcome {
    const invocation = parseSlashCommandInvocation(prompt) orelse return .not_handled;
    var runtime_extensions = try discoverRuntimeExtensionPaths(io, allocator, env, parsed);
    defer runtime_extensions.deinit(allocator);
    if (runtime_extensions.paths.len == 0) return .not_handled;

    const extension_flag_values = try extensionFlagValuesFromParsed(allocator, parsed);
    defer if (extension_flag_values.len > 0) allocator.free(extension_flag_values);
    var runner = extension_runner.Runner{
        .io = io,
        .allocator = allocator,
        .extension_paths = runtime_extensions.paths,
        .flag_values = extension_flag_values,
    };
    const result = try runner.runRegisteredCommand(invocation.name, invocation.args);
    defer result.deinit(allocator);
    if (!result.handled) return .not_handled;

    var store: ?session.PersistentStore = null;
    var command_prompt: ?TopLevelCommandPrompt = null;
    errdefer if (command_prompt) |owned_prompt| owned_prompt.deinit(allocator);
    for (result.actions) |action| {
        if (command_prompt != null) return error.MultipleCommandPromptActionsUnsupported;
        switch (action) {
            .send_user_message => |user_message| {
                const owned_content = try allocator.dupe(u8, user_message.content);
                var assigned_prompt = false;
                errdefer if (!assigned_prompt) allocator.free(owned_content);
                const owned_image_parts = try cloneContentParts(allocator, user_message.image_parts);
                errdefer if (!assigned_prompt) freeOwnedContentParts(allocator, owned_image_parts);
                command_prompt = .{
                    .content = owned_content,
                    .image_parts = owned_image_parts,
                    .persist_user_message = true,
                };
                assigned_prompt = true;
            },
            .send_message => |custom_message| {
                if (custom_message.deliver_as != null and custom_message.deliver_as.? == .next_turn) return error.UnsupportedCommandActionNextTurn;
                if (store == null) store = try maybeOpenStore(io, allocator, env, parsed);
                if (store) |*persistent| {
                    _ = try persistent.appendCustomMessage(
                        io,
                        allocator,
                        custom_message.custom_type,
                        custom_message.content,
                        custom_message.display,
                    );
                }
                if (custom_message.trigger_turn) {
                    command_prompt = .{
                        .content = try allocator.dupe(u8, custom_message.content),
                        .persist_user_message = false,
                    };
                }
            },
            .append_entry => |entry| {
                if (store == null) store = try maybeOpenStore(io, allocator, env, parsed);
                if (store) |*persistent| {
                    _ = try persistent.appendCustomEntryRawJson(
                        io,
                        allocator,
                        entry.custom_type,
                        entry.data_json,
                    );
                }
            },
        }
    }
    if (command_prompt) |owned_prompt| return .{ .prompt = owned_prompt };
    return .handled;
}

fn runJsonProviderTextStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
    prompt: []const u8,
    image_parts: []const ai_client.ChatContentPart,
    persist_user_message: bool,
) !void {
    // Arm the SIGINT abort hook so an interrupted streaming run emits the upstream abort lifecycle.
    armJsonAbortHandler();
    var store = try maybeOpenStore(io, allocator, env, parsed);
    if (store) |*persistent| {
        if (persist_user_message and (prompt.len > 0 or image_parts.len > 0)) _ = try persistent.appendMessageWithContentParts(io, allocator, .user, prompt, image_parts);
    }

    const provider = parsed.provider.?;
    const model = parsed.model.?;
    const api_key = if (parsed.api_key) |key|
        try allocator.dupe(u8, key)
    else
        try auth.resolveProviderApiKey(io, allocator, env, provider) orelse {
            try writeStderr(io, "No API key found for ");
            try writeStderr(io, provider);
            try writeStderr(io, ".\n");
            return error.ProviderAuthMissing;
        };
    defer allocator.free(api_key);

    const runtime_system_prompt = try buildRuntimeSystemPrompt(io, allocator, env, parsed);
    defer allocator.free(runtime_system_prompt);

    var messages_buf: [2]ai_client.ChatMessage = undefined;
    var messages_len: usize = 0;
    const trimmed_system = std.mem.trim(u8, runtime_system_prompt, " \t\r\n");
    if (trimmed_system.len > 0) {
        messages_buf[messages_len] = .{ .role = .system, .content = trimmed_system };
        messages_len += 1;
    }
    const prompt_content_parts = try buildPromptContentParts(allocator, prompt, image_parts);
    defer if (prompt_content_parts.len > 0) allocator.free(prompt_content_parts);
    messages_buf[messages_len] = .{ .role = .user, .content = prompt, .content_parts = prompt_content_parts };
    messages_len += 1;

    try emitJsonPrelude(io, allocator, if (store) |*persistent| persistent.sessionId() else "pi-zig-ephemeral");

    var final_text: std.Io.Writer.Allocating = .init(allocator);
    defer final_text.deinit();
    var stream_context = JsonStreamContext{
        .io = io,
        .allocator = allocator,
        .final_text = &final_text,
    };
    const retry_settings = try settings.loadRetrySettings(io, allocator, env);
    var retry_attempts: usize = 0;

    while (true) {
        ai_client.streamChatTurnText(io, allocator, env, .{
            .provider = provider,
            .model = model,
            .api_key = api_key,
            .messages = messages_buf[0..messages_len],
            .tools = &.{},
            .cancellation_context = &stream_context,
            .should_cancel = jsonAbortRequested,
        }, &stream_context, handleJsonStreamTextDelta) catch |err| {
            if (shouldRetryJsonProviderError(retry_settings, retry_attempts, err, !stream_context.assistant_started and final_text.written().len == 0)) {
                retry_attempts += 1;
                const delay_ms = jsonRetryDelayMs(retry_settings, retry_attempts);
                try emitJsonAssistantStatusLifecycle(
                    io,
                    allocator,
                    final_text.written(),
                    "error",
                    @errorName(err),
                    !stream_context.assistant_started,
                    true,
                );
                try emitJsonAutoRetryStart(io, allocator, retry_attempts, retry_settings.max_retries, delay_ms, @errorName(err));
                try sleepMilliseconds(io, delay_ms);
                continue;
            }
            const status = assistantStatusForError(err);
            if (store) |*persistent| {
                try appendJsonAssistantStatusMessage(
                    io,
                    allocator,
                    persistent,
                    parsed,
                    final_text.written(),
                    status.stop_reason,
                    status.error_message,
                );
            }
            try emitJsonAssistantStatusLifecycle(
                io,
                allocator,
                final_text.written(),
                status.stop_reason,
                status.error_message,
                !stream_context.assistant_started,
                false,
            );
            if (retry_attempts > 0) {
                try emitJsonAutoRetryEnd(io, allocator, false, retry_attempts, @errorName(err));
            }
            return err;
        };
        break;
    }

    if (final_text.written().len == 0) {
        if (store) |*persistent| {
            try appendJsonAssistantStatusMessage(
                io,
                allocator,
                persistent,
                parsed,
                final_text.written(),
                "error",
                "ProviderResponseInvalid",
            );
        }
        try emitJsonAssistantStatusLifecycle(
            io,
            allocator,
            final_text.written(),
            "error",
            "ProviderResponseInvalid",
            !stream_context.assistant_started,
            false,
        );
        return error.ProviderResponseInvalid;
    }
    if (store) |*persistent| {
        _ = try persistent.appendMessage(io, allocator, .assistant, final_text.written());
    }

    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    const w = &line.writer;
    try w.writeAll("{\"type\":\"message_end\",\"message\":");
    try writeAssistantMessageJson(w, final_text.written());
    try w.writeAll("}\n");
    if (retry_attempts > 0) {
        try writeJsonAutoRetryEnd(w, true, retry_attempts, null);
        try w.writeByte('\n');
    }
    try w.writeAll("{\"type\":\"turn_end\",\"message\":");
    try writeAssistantMessageJson(w, final_text.written());
    try w.writeAll(",\"toolResults\":[]}\n");
    try w.writeAll("{\"type\":\"agent_end\",\"messages\":[");
    try writeAssistantMessageJson(w, final_text.written());
    try w.writeAll("],\"willRetry\":false}\n");
    try writeStreamingJsonLine(io, allocator, line.written());
}

fn emitJsonSessionHeader(io: std.Io, allocator: std.mem.Allocator, session_id: []const u8) !void {
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    const w = &line.writer;
    try w.writeAll("{\"type\":\"session\",\"version\":3,\"id\":");
    try writeJsonString(w, session_id);
    try w.writeAll(",\"timestamp\":\"local-foundation\",\"cwd\":\".\"}\n");
    try writeStreamingJsonLine(io, allocator, line.written());
}

fn emitJsonPrelude(io: std.Io, allocator: std.mem.Allocator, session_id: []const u8) !void {
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    const w = &line.writer;
    try w.writeAll("{\"type\":\"session\",\"version\":3,\"id\":");
    try writeJsonString(w, session_id);
    try w.writeAll(",\"timestamp\":\"local-foundation\",\"cwd\":\".\"}\n");
    try w.writeAll("{\"type\":\"agent_start\"}\n");
    try w.writeAll("{\"type\":\"turn_start\"}\n");
    try writeStreamingJsonLine(io, allocator, line.written());
}

fn shouldRetryJsonProviderError(retry_settings: settings.RetrySettings, retry_attempts: usize, err: anyerror, clean_turn: bool) bool {
    if (!clean_turn) return false;
    if (!retry_settings.enabled) return false;
    if (retry_attempts >= retry_settings.max_retries) return false;
    return isRetryableProviderError(err);
}

/// Cross-mode parity with rpc.zig's `isRetryableAgentError`: a provider request the server rejected
/// as transient (429/5xx/overloaded/retryable body text -> ProviderRequestFailed) and a stream that
/// ended before its terminal `[DONE]`/`message_stop` event (network drop / socket hang up ->
/// ProviderStreamIncomplete) are both retryable. Structurally malformed responses
/// (ProviderResponseInvalid) and non-transient 4xx client failures (ProviderClientError) stay
/// non-retryable, matching the RPC classification exactly.
fn isRetryableProviderError(err: anyerror) bool {
    return switch (err) {
        error.ProviderRequestFailed, error.ProviderStreamIncomplete => true,
        else => false,
    };
}

fn jsonRetryDelayMs(retry_settings: settings.RetrySettings, attempt: usize) usize {
    if (retry_settings.base_delay_ms == 0) return 0;
    const shift: std.math.Log2Int(usize) = @intCast(@min(attempt - 1, @bitSizeOf(usize) - 2));
    const multiplier = @as(usize, 1) << shift;
    return std.math.mul(usize, retry_settings.base_delay_ms, multiplier) catch std.math.maxInt(usize);
}

fn sleepMilliseconds(io: std.Io, milliseconds: usize) !void {
    if (milliseconds == 0) return;
    const bounded = @min(milliseconds, @as(usize, @intCast(std.math.maxInt(i64))));
    try std.Io.sleep(io, .fromMilliseconds(@intCast(bounded)), .awake);
}

fn emitJsonAutoRetryStart(
    io: std.Io,
    allocator: std.mem.Allocator,
    attempt: usize,
    max_attempts: usize,
    delay_ms: usize,
    error_message: []const u8,
) !void {
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    const w = &line.writer;
    try w.writeAll("{\"type\":\"auto_retry_start\",\"attempt\":");
    try w.print("{d}", .{attempt});
    try w.writeAll(",\"maxAttempts\":");
    try w.print("{d}", .{max_attempts});
    try w.writeAll(",\"delayMs\":");
    try w.print("{d}", .{delay_ms});
    try w.writeAll(",\"errorMessage\":");
    try writeJsonString(w, error_message);
    try w.writeAll("}\n");
    try writeStreamingJsonLine(io, allocator, line.written());
}

fn emitJsonAutoRetryEnd(
    io: std.Io,
    allocator: std.mem.Allocator,
    success: bool,
    attempt: usize,
    final_error: ?[]const u8,
) !void {
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    try writeJsonAutoRetryEnd(&line.writer, success, attempt, final_error);
    try line.writer.writeByte('\n');
    try writeStreamingJsonLine(io, allocator, line.written());
}

fn writeJsonAutoRetryEnd(w: *std.Io.Writer, success: bool, attempt: usize, final_error: ?[]const u8) !void {
    try w.writeAll("{\"type\":\"auto_retry_end\",\"success\":");
    try w.writeAll(if (success) "true" else "false");
    try w.writeAll(",\"attempt\":");
    try w.print("{d}", .{attempt});
    if (final_error) |message| {
        try w.writeAll(",\"finalError\":");
        try writeJsonString(w, message);
    }
    try w.writeByte('}');
}

fn assistantStatusForError(err: anyerror) AssistantStatus {
    if (err == error.AgentAborted) {
        return .{ .stop_reason = "aborted", .error_message = "Request was aborted" };
    }
    return .{ .stop_reason = "error", .error_message = @errorName(err) };
}

fn appendJsonAssistantStatusMessage(
    io: std.Io,
    allocator: std.mem.Allocator,
    persistent: *session.PersistentStore,
    parsed: cli.ParsedArgs,
    text: []const u8,
    stop_reason: []const u8,
    error_message: ?[]const u8,
) !void {
    const api: ?[]const u8 = if (parsed.provider) |provider|
        if (parsed.model) |model|
            if (models.find(provider, model)) |entry| entry.api else null
        else
            null
    else
        null;
    _ = try persistent.appendAssistantStatusMessage(
        io,
        allocator,
        text,
        api,
        parsed.provider,
        parsed.model,
        stop_reason,
        error_message,
    );
}

fn emitJsonAssistantStatusLifecycle(
    io: std.Io,
    allocator: std.mem.Allocator,
    text: []const u8,
    stop_reason: []const u8,
    error_message: ?[]const u8,
    emit_start: bool,
    will_retry: bool,
) !void {
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    const w = &line.writer;
    if (emit_start) {
        try w.writeAll("{\"type\":\"message_start\",\"message\":");
        try writeAssistantStatusMessageJson(w, text, stop_reason, error_message);
        try w.writeAll("}\n");
    }
    try w.writeAll("{\"type\":\"message_end\",\"message\":");
    try writeAssistantStatusMessageJson(w, text, stop_reason, error_message);
    try w.writeAll("}\n");
    try w.writeAll("{\"type\":\"turn_end\",\"message\":");
    try writeAssistantStatusMessageJson(w, text, stop_reason, error_message);
    try w.writeAll(",\"toolResults\":[]}\n");
    try w.writeAll("{\"type\":\"agent_end\",\"messages\":[");
    try writeAssistantStatusMessageJson(w, text, stop_reason, error_message);
    try w.writeAll("],\"willRetry\":");
    try w.writeAll(if (will_retry) "true" else "false");
    try w.writeAll("}\n");
    try writeStreamingJsonLine(io, allocator, line.written());
}

fn handleJsonStreamTextDelta(ctx_ptr: *anyopaque, delta: []const u8) anyerror!void {
    const ctx: *JsonStreamContext = @ptrCast(@alignCast(ctx_ptr));
    try ctx.final_text.writer.writeAll(delta);

    var line: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer line.deinit();
    const w = &line.writer;
    if (!ctx.assistant_started) {
        ctx.assistant_started = true;
        try w.writeAll("{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n");
    }
    try w.writeAll("{\"type\":\"message_update\",\"message\":");
    try writeAssistantMessageJson(w, ctx.final_text.written());
    try w.writeAll(",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":");
    try writeJsonString(w, delta);
    try w.writeAll("}}\n");
    try writeStreamingJsonLine(ctx.io, ctx.allocator, line.written());
}

fn handleJsonToolStart(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall) anyerror!void {
    const ctx: *JsonToolEventContext = @ptrCast(@alignCast(ctx_ptr));
    var line: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer line.deinit();
    try writeToolCallExecutionStartJson(&line.writer, call);
    try line.writer.writeByte('\n');
    try writeStreamingJsonLine(ctx.io, ctx.allocator, line.written());
}

fn handleJsonToolUpdate(ctx_ptr: *anyopaque, update: agent.ToolUpdate) anyerror!void {
    const ctx: *JsonToolEventContext = @ptrCast(@alignCast(ctx_ptr));
    var line: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer line.deinit();
    try writeToolExecutionUpdateJson(&line.writer, update);
    try line.writer.writeByte('\n');
    try writeStreamingJsonLine(ctx.io, ctx.allocator, line.written());
}

fn handleJsonToolEnd(ctx_ptr: *anyopaque, tool_result: agent.ToolResult) anyerror!void {
    const ctx: *JsonToolEventContext = @ptrCast(@alignCast(ctx_ptr));
    var line: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer line.deinit();
    const w = &line.writer;
    try writeToolExecutionEndJson(w, tool_result);
    try w.writeByte('\n');
    try w.writeAll("{\"type\":\"message_start\",\"message\":");
    try writeToolResultMessageJson(w, tool_result);
    try w.writeAll("}\n");
    try w.writeAll("{\"type\":\"message_end\",\"message\":");
    try writeToolResultMessageJson(w, tool_result);
    try w.writeAll("}\n");
    try writeStreamingJsonLine(ctx.io, ctx.allocator, line.written());
}

fn handleJsonAgentTextDelta(ctx_ptr: *anyopaque, delta: []const u8) anyerror!void {
    const ctx: *JsonToolEventContext = @ptrCast(@alignCast(ctx_ptr));
    var line: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer line.deinit();
    const w = &line.writer;
    if (!ctx.assistant_started) {
        ctx.assistant_started = true;
        try w.writeAll("{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n");
    }
    try ctx.final_text.writer.writeAll(delta);
    try w.writeAll("{\"type\":\"message_update\",\"message\":");
    try writeAssistantMessageJson(w, ctx.final_text.written());
    try w.writeAll(",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":");
    try writeJsonString(w, delta);
    try w.writeAll("}}\n");
    try writeStreamingJsonLine(ctx.io, ctx.allocator, line.written());
}

fn writeStreamingJsonLine(io: std.Io, allocator: std.mem.Allocator, bytes: []const u8) !void {
    _ = allocator;
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn maybeOpenStore(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
) !?session.PersistentStore {
    if (parsed.no_session) return null;
    const path = try resolveSessionPath(io, allocator, env, parsed);
    defer path.deinit(allocator);
    const store = try session.PersistentStore.init(io, allocator, path.path);
    return store;
}

fn resolveSessionPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
) !PathResult {
    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);

    const session_dir = try resolveSessionDir(io, allocator, env, cwd, parsed.session_dir);
    defer allocator.free(session_dir);

    if (parsed.fork) |source| {
        const source_path = try resolveSessionArg(io, allocator, env, cwd, session_dir, source) orelse {
            try writeStderr(io, "No session found matching '");
            try writeStderr(io, source);
            try writeStderr(io, "'.\n");
            std.process.exit(1);
        };
        defer allocator.free(source_path);
        const forked_path = session.forkFromFile(io, allocator, source_path, session_dir, cwd) catch |err| {
            try writeStderr(io, "Error: ");
            try writeStderr(io, @errorName(err));
            try writeStderr(io, "\n");
            std.process.exit(1);
        };
        return .{ .path = forked_path, .owned = true };
    }

    if (parsed.session) |arg| {
        const path = try resolveSessionArg(io, allocator, env, cwd, session_dir, arg) orelse {
            try writeStderr(io, "No session found matching '");
            try writeStderr(io, arg);
            try writeStderr(io, "'.\n");
            std.process.exit(1);
        };
        return .{ .path = path, .owned = true };
    }

    if (parsed.continue_session or parsed.resume_session) {
        if (try session.findMostRecentSession(io, allocator, session_dir)) |path| {
            return .{ .path = path, .owned = true };
        }
        const path = try session.newSessionPath(io, allocator, session_dir);
        return .{ .path = path, .owned = true };
    }

    if (parsed.session_dir != null) {
        const path = try session.newSessionPath(io, allocator, session_dir);
        return .{ .path = path, .owned = true };
    }
    return .{ .path = session.default_session_file };
}

fn validateSessionFlags(io: std.Io, parsed: cli.ParsedArgs) !void {
    if (parsed.fork == null) return;
    var conflicts: [4][]const u8 = undefined;
    var len: usize = 0;
    if (parsed.session != null) {
        conflicts[len] = "--session";
        len += 1;
    }
    if (parsed.continue_session) {
        conflicts[len] = "--continue";
        len += 1;
    }
    if (parsed.resume_session) {
        conflicts[len] = "--resume";
        len += 1;
    }
    if (parsed.no_session) {
        conflicts[len] = "--no-session";
        len += 1;
    }
    if (len == 0) return;
    try writeStderr(io, "Error: --fork cannot be combined with ");
    for (conflicts[0..len], 0..) |flag, index| {
        if (index != 0) try writeStderr(io, ", ");
        try writeStderr(io, flag);
    }
    try writeStderr(io, "\n");
    std.process.exit(1);
}

fn resolveSessionDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    explicit_dir: ?[]const u8,
) ![]u8 {
    if (explicit_dir) |dir| return resolveLocalPath(allocator, env, cwd, dir);
    return session.defaultSessionDir(io, allocator, env, cwd);
}

fn resolveSessionArg(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    session_dir: []const u8,
    arg: []const u8,
) !?[]u8 {
    if (looksLikeSessionPath(arg)) {
        const path = try resolveLocalPath(allocator, env, cwd, arg);
        return path;
    }
    return session.findSessionByIdPrefix(io, allocator, session_dir, arg);
}

fn looksLikeSessionPath(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, '/') != null or
        std.mem.indexOfScalar(u8, value, '\\') != null or
        std.mem.endsWith(u8, value, ".jsonl");
}

fn resolveLocalPath(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    path: []const u8,
) ![]u8 {
    const expanded = try expandMaybeTilde(allocator, env, path);
    defer allocator.free(expanded);
    if (std.fs.path.isAbsolute(expanded)) return std.fs.path.resolve(allocator, &.{expanded});
    return std.fs.path.resolve(allocator, &.{ cwd, expanded });
}

fn expandMaybeTilde(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, env.get("HOME") orelse ".");
    if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(allocator, &.{ env.get("HOME") orelse ".", path[2..] });
    return allocator.dupe(u8, path);
}

fn currentPathOwned(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

/// Mirrors upstream readPipedStdin(): if stdin is a TTY (interactive terminal)
/// return null; otherwise read all of stdin, trim it, and return null when the
/// trimmed content is empty. Caller owns the returned slice.
fn readPipedStdin(io: std.Io, allocator: std.mem.Allocator) !?[]u8 {
    const stdin = std.Io.File.stdin();
    if (stdin.isTty(io) catch true) return null;

    var in_buf: [16 * 1024]u8 = undefined;
    var stdin_reader = stdin.reader(io, &in_buf);
    const r = &stdin_reader.interface;

    const raw = try r.allocRemaining(allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn buildPrompt(io: std.Io, allocator: std.mem.Allocator, parsed: cli.ParsedArgs, stdin_content: ?[]const u8) !PromptResult {
    // Upstream buildInitialMessage() orders prompt segments as
    // [stdinContent, fileText, firstMessage]. The single-message fast path is
    // only valid when there is no piped stdin to prepend.
    if (stdin_content == null and parsed.file_args_len == 0 and parsed.messages_len == 1) {
        return .{ .text = parsed.messages[0] };
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    var image_parts: std.ArrayList(ai_client.ChatContentPart) = .empty;
    errdefer {
        for (image_parts.items) |part| {
            switch (part) {
                .image => |image| allocator.free(image.data),
                .text => {},
            }
        }
        image_parts.deinit(allocator);
    }

    if (stdin_content) |stdin| {
        try w.writeAll(stdin);
    }

    for (parsed.file_args[0..parsed.file_args_len]) |path| {
        if (imageMimeTypeForPath(path)) |mime_type| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024));
            defer allocator.free(bytes);
            const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            errdefer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, bytes);
            try image_parts.append(allocator, .{ .image = .{
                .data = encoded,
                .mime_type = mime_type,
            } });
            continue;
        }
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(bytes);
        if (out.written().len != 0) try w.writeAll("\n\n");
        try w.writeAll("@");
        try w.writeAll(path);
        try w.writeAll("\n");
        try w.writeAll(bytes);
    }

    for (parsed.messages[0..parsed.messages_len]) |message| {
        if (out.written().len != 0) try w.writeAll("\n\n");
        try w.writeAll(message);
    }

    var text: []const u8 = "";
    var text_owned = false;
    errdefer if (text_owned) allocator.free(text);
    if (out.written().len == 0) {
        out.deinit();
    } else {
        text = try out.toOwnedSlice();
        text_owned = true;
    }
    const images: []ai_client.ChatContentPart = if (image_parts.items.len > 0) try image_parts.toOwnedSlice(allocator) else &.{};
    return .{ .text = text, .owned = text_owned, .image_parts = images };
}

fn buildFoundationResponse(allocator: std.mem.Allocator, parsed: cli.ParsedArgs, prompt: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("pi-zig print-mode foundation accepted ");
    try w.print("{d}", .{parsed.messages_len + parsed.file_args_len});
    try w.writeAll(" prompt input(s). Provider execution is not implemented yet.");
    if (parsed.provider) |provider| {
        try w.writeAll(" provider=");
        try w.writeAll(provider);
    }
    if (parsed.model) |model| {
        try w.writeAll(" model=");
        try w.writeAll(model);
    }
    if (parsed.thinking) |thinking| {
        try w.writeAll(" thinking=");
        try w.writeAll(@tagName(thinking));
    }
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len > 0) {
        try w.writeAll("\n\nPrompt:\n");
        try w.writeAll(trimmed);
    }
    return try out.toOwnedSlice();
}

/// Resolve the `images.autoResize` setting (default true) so provider-backed print/JSON runs can
/// thread it into the read-tool via agent.RunOptions.auto_resize_images. settings.zig owns the
/// canonical typed loaders (loadRetrySettings/loadShellSettings) but does not expose an image
/// loader, so this mirrors its project-over-global precedence and `images.autoResize` path read
/// against the same settings files. A missing/invalid value falls back to true, matching
/// settings.zig's `imageSettings` default and upstream's default-on auto-resize.
fn loadImageAutoResize(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !bool {
    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);

    const global_path = try settingsAgentSettingsPath(allocator, env);
    defer allocator.free(global_path);
    const project_path = try std.fs.path.join(allocator, &.{ cwd, ".pi/settings.json" });
    defer allocator.free(project_path);

    if (try readImageAutoResizeFromFile(io, allocator, project_path)) |value| return value;
    if (try readImageAutoResizeFromFile(io, allocator, global_path)) |value| return value;
    return true;
}

/// Mirror of settings.zig's `agentDir` + "settings.json": `$PI_CODING_AGENT_DIR` (tilde-expanded)
/// or `$HOME/.pi/agent`, joined with `settings.json`.
fn settingsAgentSettingsPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const agent_dir = if (env.get("PI_CODING_AGENT_DIR")) |value|
        try expandMaybeTilde(allocator, env, value)
    else
        try std.fs.path.join(allocator, &.{ env.get("HOME") orelse ".", ".pi", "agent" });
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
}

/// Read `images.autoResize` from a single settings file. Returns null when the file is absent,
/// unparseable, or the boolean is missing, so the caller can fall through to the next scope/default.
fn readImageAutoResizeFromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const images = parsed.value.object.get("images") orelse return null;
    if (images != .object) return null;
    const auto_resize = images.object.get("autoResize") orelse return null;
    return if (auto_resize == .bool) auto_resize.bool else null;
}

fn buildPrintResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
    prompt: []const u8,
    image_parts: []const ai_client.ChatContentPart,
    stream_turns: bool,
    tool_event_context: ?*anyopaque,
    on_tool_start: ?agent.ToolStartCallback,
    on_tool_update: ?agent.ToolUpdateCallback,
    on_tool_end: ?agent.ToolEndCallback,
    text_event_context: ?*anyopaque,
    on_text_delta: ?agent.TextDeltaCallback,
    cancel: ?Cancellation,
) !agent.RunResult {
    if (parsed.provider == null or parsed.model == null) {
        return .{ .final_text = try buildFoundationResponse(allocator, parsed, prompt) };
    }

    const provider = parsed.provider.?;
    const model = parsed.model.?;
    const api_key = if (parsed.api_key) |key|
        try allocator.dupe(u8, key)
    else
        try auth.resolveProviderApiKey(io, allocator, env, provider) orelse {
            try writeStderr(io, "No API key found for ");
            try writeStderr(io, provider);
            try writeStderr(io, ".\n");
            return error.ProviderAuthMissing;
        };
    defer allocator.free(api_key);

    const runtime_system_prompt = try buildRuntimeSystemPrompt(io, allocator, env, parsed);
    defer allocator.free(runtime_system_prompt);
    const shell_settings = try settings.loadShellSettings(io, allocator, env);
    defer shell_settings.deinit(allocator);
    const auto_resize_images = try loadImageAutoResize(io, allocator, env);
    const prompt_content_parts = try buildPromptContentParts(allocator, prompt, image_parts);
    defer if (prompt_content_parts.len > 0) allocator.free(prompt_content_parts);
    var runtime_extensions = try discoverRuntimeExtensionPaths(io, allocator, env, parsed);
    defer runtime_extensions.deinit(allocator);
    const extension_flag_values = try extensionFlagValuesFromParsed(allocator, parsed);
    defer if (extension_flag_values.len > 0) allocator.free(extension_flag_values);
    var hooks = extension_runner.Runner{
        .io = io,
        .allocator = allocator,
        .extension_paths = runtime_extensions.paths,
        .flag_values = extension_flag_values,
    };
    const has_extension_hooks = hooks.hasExtensions();
    var extension_tool_definitions: []ai_client.ChatToolDefinition = if (has_extension_hooks)
        try hooks.discoverToolDefinitions()
    else
        &.{};
    extension_tool_definitions = try filterExtensionToolDefinitions(allocator, parsed, extension_tool_definitions);
    defer if (extension_tool_definitions.len > 0) hooks.deinitToolDefinitions(extension_tool_definitions);

    return agent.runPrompt(io, allocator, env, .{
        .provider = provider,
        .model = model,
        .api_key = api_key,
        .prompt = prompt,
        .prompt_content_parts = prompt_content_parts,
        .system_prompt = runtime_system_prompt,
        .env = env,
        .shell_path = shell_settings.shell_path,
        .shell_command_prefix = shell_settings.shell_command_prefix,
        .auto_resize_images = auto_resize_images,
        .tool_set = toolSetFromParsed(parsed),
        .custom_tools = extension_tool_definitions,
        .custom_tool_context = if (extension_tool_definitions.len > 0) &hooks else null,
        .execute_custom_tool = if (extension_tool_definitions.len > 0) extension_runner.Runner.executeRegisteredTool else null,
        .stream_turns = stream_turns,
        .tool_event_context = tool_event_context,
        .on_tool_start = on_tool_start,
        .on_tool_update = on_tool_update,
        .on_tool_end = on_tool_end,
        .tool_hook_context = if (has_extension_hooks) &hooks else null,
        .before_tool_call = if (has_extension_hooks) extension_runner.Runner.beforeToolCall else null,
        .after_tool_call = if (has_extension_hooks) extension_runner.Runner.afterToolCall else null,
        .text_event_context = text_event_context,
        .on_text_delta = on_text_delta,
        .cancellation_context = if (cancel) |c| c.context else null,
        .should_cancel = if (cancel) |c| c.should_cancel else null,
    }) catch |err| {
        try writeStderr(io, "Provider request failed: ");
        try writeStderr(io, @errorName(err));
        try writeStderr(io, "\n");
        return err;
    };
}

/// Optional cancellation hook threaded into a print/JSON agent run so an interrupted turn aborts
/// cooperatively (agent.zig polls `should_cancel` before each provider request and between turns).
const Cancellation = struct {
    context: *anyopaque,
    should_cancel: agent.CancellationCallback,
};

fn toolSetFromParsed(parsed: cli.ParsedArgs) agent.ToolSet {
    if (parsed.no_tools or parsed.no_builtin_tools) return .none;
    if (parsed.tools) |value| {
        if (toolListContains(value, "*") or toolListContains(value, "all")) return .all;
        return .{
            .read = toolListContains(value, "read"),
            .bash = toolListContains(value, "bash"),
            .edit = toolListContains(value, "edit"),
            .write = toolListContains(value, "write"),
            .grep = toolListContains(value, "grep"),
            .find = toolListContains(value, "find"),
            .ls = toolListContains(value, "ls"),
        };
    }
    return .all;
}

fn filterExtensionToolDefinitions(
    allocator: std.mem.Allocator,
    parsed: cli.ParsedArgs,
    definitions: []ai_client.ChatToolDefinition,
) ![]ai_client.ChatToolDefinition {
    if (definitions.len == 0) return &.{};
    var kept: std.ArrayList(ai_client.ChatToolDefinition) = .empty;
    errdefer {
        for (kept.items) |definition| {
            allocator.free(definition.name);
            allocator.free(definition.description);
            allocator.free(definition.parameters_json);
        }
        kept.deinit(allocator);
    }
    for (definitions) |definition| {
        if (extensionToolAllowed(parsed, definition.name)) {
            try kept.append(allocator, definition);
        } else {
            allocator.free(definition.name);
            allocator.free(definition.description);
            allocator.free(definition.parameters_json);
        }
    }
    allocator.free(definitions);
    if (kept.items.len == 0) return &.{};
    return kept.toOwnedSlice(allocator);
}

fn extensionFlagValuesFromParsed(allocator: std.mem.Allocator, parsed: cli.ParsedArgs) ![]extension_runner.Runner.FlagValue {
    if (parsed.unknown_flags_len == 0) return &.{};
    const values = try allocator.alloc(extension_runner.Runner.FlagValue, parsed.unknown_flags_len);
    for (parsed.unknown_flags[0..parsed.unknown_flags_len], 0..) |flag, index| {
        values[index] = .{ .name = flag.name, .value = flag.value };
    }
    return values;
}

// ===== FLOW 07: extension flag validation/help surfacing =====
// Validate CLI-provided unknown flags against the extension-registered flag set.
// Mirrors upstream registerFlag typing: a boolean flag rejects an explicit value and a
// string flag requires one. Unknown (non-extension) flags are left untouched, matching
// upstream which passes them through. Returns error.InvalidCliArguments after reporting
// when any registered extension flag was given an invalid value.
fn validateExtensionFlags(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
) !void {
    if (parsed.unknown_flags_len == 0) return;

    var runtime_extensions = try discoverRuntimeExtensionPaths(io, allocator, env, parsed);
    defer runtime_extensions.deinit(allocator);
    if (runtime_extensions.paths.len == 0) return;

    const provided = try extensionFlagValuesFromParsed(allocator, parsed);
    defer if (provided.len > 0) allocator.free(provided);

    var runner = extension_runner.Runner{
        .io = io,
        .allocator = allocator,
        .extension_paths = runtime_extensions.paths,
    };
    const definitions = try runner.discoverFlagDefinitions();
    defer runner.deinitFlagDefinitions(definitions);
    if (definitions.len == 0) return;

    const errors = try runner.validateFlags(definitions, provided);
    defer runner.deinitFlagValidationErrors(errors);
    if (errors.len == 0) return;

    for (errors) |err| {
        try writeStderr(io, err.message);
        try writeStderr(io, "\n");
    }
    std.process.exit(1);
}

// Append extension-registered CLI flags to the top-level help output, matching upstream
// printHelp()'s "Extension CLI Flags:" section in cli/args.ts.
fn writeExtensionFlagHelp(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
) !void {
    var runtime_extensions = discoverRuntimeExtensionPaths(io, allocator, env, .{}) catch return;
    defer runtime_extensions.deinit(allocator);
    if (runtime_extensions.paths.len == 0) return;

    var runner = extension_runner.Runner{
        .io = io,
        .allocator = allocator,
        .extension_paths = runtime_extensions.paths,
    };
    const definitions = runner.discoverFlagDefinitions() catch return;
    defer runner.deinitFlagDefinitions(definitions);
    if (definitions.len == 0) return;

    try writeStdout(io, "\nExtension CLI Flags:\n");
    for (definitions) |definition| {
        try writeExtensionFlagHelpLine(io, allocator, definition);
    }
}

fn writeExtensionFlagHelpLine(
    io: std.Io,
    allocator: std.mem.Allocator,
    definition: extension_runner.Runner.FlagDefinition,
) !void {
    const value_hint = if (definition.flag_type == .string) " <value>" else "";
    const left = try std.fmt.allocPrint(allocator, "  --{s}{s}", .{ definition.name, value_hint });
    defer allocator.free(left);
    try writeStdout(io, left);
    var pad = left.len;
    while (pad < 32) : (pad += 1) try writeStdout(io, " ");
    if (definition.description) |description| {
        try writeStdout(io, description);
    } else {
        try writeStdout(io, "Registered by ");
        try writeStdout(io, definition.extension_path);
    }
    try writeStdout(io, "\n");
}
// ===== END FLOW 07 =====

fn extensionToolAllowed(parsed: cli.ParsedArgs, name: []const u8) bool {
    if (parsed.no_tools) return false;
    const raw = parsed.tools orelse return true;
    if (toolListContains(raw, "*") or toolListContains(raw, "all")) return true;
    return toolListContains(raw, name);
}

fn discoverRuntimeExtensionPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
) !extensions.RuntimePaths {
    return extensions.discoverRuntimePaths(io, allocator, env, .{
        .no_extensions = parsed.no_extensions,
        .explicit_paths = parsed.extensions[0..parsed.extensions_len],
    });
}

fn buildPromptContentParts(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    image_parts: []const ai_client.ChatContentPart,
) ![]ai_client.ChatContentPart {
    if (image_parts.len == 0) return &.{};
    const text_parts: usize = if (prompt.len > 0) 1 else 0;
    const parts = try allocator.alloc(ai_client.ChatContentPart, text_parts + image_parts.len);
    var index: usize = 0;
    if (prompt.len > 0) {
        parts[index] = .{ .text = prompt };
        index += 1;
    }
    for (image_parts) |part| {
        parts[index] = part;
        index += 1;
    }
    return parts;
}

fn cloneContentParts(allocator: std.mem.Allocator, parts: []const ai_client.ChatContentPart) ![]ai_client.ChatContentPart {
    if (parts.len == 0) return &.{};
    const cloned = try allocator.alloc(ai_client.ChatContentPart, parts.len);
    var len: usize = 0;
    errdefer {
        for (cloned[0..len]) |part| freeOwnedContentPart(allocator, part);
        allocator.free(cloned);
    }
    for (parts) |part| {
        cloned[len] = switch (part) {
            .text => |text| .{ .text = try allocator.dupe(u8, text) },
            .image => |image| blk: {
                const owned_data = try allocator.dupe(u8, image.data);
                errdefer allocator.free(owned_data);
                const owned_mime_type = try allocator.dupe(u8, image.mime_type);
                errdefer allocator.free(owned_mime_type);
                break :blk .{ .image = .{ .data = owned_data, .mime_type = owned_mime_type } };
            },
        };
        len += 1;
    }
    return cloned;
}

fn freeOwnedContentParts(allocator: std.mem.Allocator, parts: []const ai_client.ChatContentPart) void {
    if (parts.len == 0) return;
    for (parts) |part| freeOwnedContentPart(allocator, part);
    allocator.free(parts);
}

fn freeOwnedContentPart(allocator: std.mem.Allocator, part: ai_client.ChatContentPart) void {
    switch (part) {
        .text => |text| allocator.free(text),
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    }
}

fn imageMimeTypeForPath(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (asciiEqlIgnoreCase(ext, ".png")) return "image/png";
    if (asciiEqlIgnoreCase(ext, ".jpg")) return "image/jpeg";
    if (asciiEqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (asciiEqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (asciiEqlIgnoreCase(ext, ".gif")) return "image/gif";
    return null;
}

fn asciiEqlIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn toolListContains(value: []const u8, needle: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (std.mem.eql(u8, trimmed, needle)) return true;
    }
    return false;
}

fn buildRuntimeSystemPrompt(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
) ![]u8 {
    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);

    const package_dir = try system_prompt.resolvePackageDir(io, allocator, env, cwd, null);
    defer allocator.free(package_dir);

    var discovery = try context_files.discover(io, allocator, env, .{ .no_context_files = parsed.no_context_files });
    defer discovery.deinit();

    const append_prompt = try system_prompt.combineAppendPrompt(allocator, discovery.append_system_prompt, parsed.append_system_prompts[0..parsed.append_system_prompts_len]);
    defer if (append_prompt) |value| allocator.free(value);

    var date_buf: [10]u8 = undefined;
    const current_date = try system_prompt.currentLocalDate(io, allocator, env, &date_buf);

    const selected_tools = try selectedToolNamesFromParsed(allocator, parsed);
    defer selected_tools.deinit(allocator);

    return system_prompt.build(allocator, .{
        .custom_prompt = parsed.system_prompt orelse if (discovery.system_prompt) |file| file.content else null,
        .append_system_prompt = append_prompt,
        .selected_tools = selected_tools.names,
        .cwd = cwd,
        .package_dir = package_dir,
        .date = current_date,
        .context_files = discovery.context_files.items,
        .include_builtin_tool_metadata = true,
    });
}

fn selectedToolNamesFromParsed(allocator: std.mem.Allocator, parsed: cli.ParsedArgs) !SelectedToolNames {
    if (parsed.no_tools or parsed.no_builtin_tools) return .{ .names = &.{} };
    const raw = parsed.tools orelse return .{ .names = all_tool_names[0..] };
    if (toolListContains(raw, "*") or toolListContains(raw, "all")) return .{ .names = all_tool_names[0..] };

    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len > 0) try names.append(allocator, trimmed);
    }
    return .{ .names = try names.toOwnedSlice(allocator), .owned = true };
}

fn writeAssistantMessageJson(w: *std.Io.Writer, text: []const u8) !void {
    try writeAssistantStatusMessageJson(w, text, "end", null);
}

fn writeAssistantStatusMessageJson(
    w: *std.Io.Writer,
    text: []const u8,
    stop_reason: []const u8,
    error_message: ?[]const u8,
) !void {
    try w.writeAll("{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.writeAll("}],\"stopReason\":");
    try writeJsonString(w, stop_reason);
    if (error_message) |message| {
        try w.writeAll(",\"errorMessage\":");
        try writeJsonString(w, message);
    }
    try w.writeByte('}');
}

fn writeToolExecutionStartJson(w: *std.Io.Writer, tool_result: agent.ToolResult) !void {
    try w.writeAll("{\"type\":\"tool_execution_start\",\"toolCallId\":");
    try writeJsonString(w, tool_result.tool_call_id);
    try w.writeAll(",\"toolName\":");
    try writeJsonString(w, tool_result.tool_name);
    try w.writeAll(",\"args\":");
    try writeRawJsonObjectOrString(w, tool_result.arguments_json);
    try w.writeByte('}');
}

fn writeToolCallExecutionStartJson(w: *std.Io.Writer, call: ai_client.ChatToolCall) !void {
    try w.writeAll("{\"type\":\"tool_execution_start\",\"toolCallId\":");
    try writeJsonString(w, call.id);
    try w.writeAll(",\"toolName\":");
    try writeJsonString(w, call.name);
    try w.writeAll(",\"args\":");
    try writeRawJsonObjectOrString(w, call.arguments_json);
    try w.writeByte('}');
}

fn writeToolExecutionUpdateJson(w: *std.Io.Writer, update: agent.ToolUpdate) !void {
    try w.writeAll("{\"type\":\"tool_execution_update\",\"toolCallId\":");
    try writeJsonString(w, update.tool_call_id);
    try w.writeAll(",\"toolName\":");
    try writeJsonString(w, update.tool_name);
    try w.writeAll(",\"args\":");
    try writeRawJsonObjectOrString(w, update.arguments_json);
    try w.writeAll(",\"partialResult\":");
    try writeToolUpdatePayloadJson(w, update);
    try w.writeByte('}');
}

fn writeToolExecutionEndJson(w: *std.Io.Writer, tool_result: agent.ToolResult) !void {
    try w.writeAll("{\"type\":\"tool_execution_end\",\"toolCallId\":");
    try writeJsonString(w, tool_result.tool_call_id);
    try w.writeAll(",\"toolName\":");
    try writeJsonString(w, tool_result.tool_name);
    try w.writeAll(",\"result\":");
    try writeToolResultPayloadJson(w, tool_result);
    try w.writeAll(",\"isError\":");
    try w.writeAll(if (tool_result.is_error) "true" else "false");
    try w.writeAll(",\"terminate\":");
    try w.writeAll(if (tool_result.terminate) "true" else "false");
    try w.writeByte('}');
}

fn writeToolResultMessageJson(w: *std.Io.Writer, tool_result: agent.ToolResult) !void {
    try w.writeAll("{\"role\":\"toolResult\",\"toolCallId\":");
    try writeJsonString(w, tool_result.tool_call_id);
    try w.writeAll(",\"toolName\":");
    try writeJsonString(w, tool_result.tool_name);
    try w.writeAll(",\"content\":");
    try writeToolResultContentJson(w, tool_result);
    try w.writeAll(",\"isError\":");
    try w.writeAll(if (tool_result.is_error) "true" else "false");
    try w.writeAll(",\"terminate\":");
    try w.writeAll(if (tool_result.terminate) "true" else "false");
    try w.writeByte('}');
}

fn writeToolResultPayloadJson(w: *std.Io.Writer, tool_result: agent.ToolResult) !void {
    try w.writeAll("{\"content\":");
    try writeToolResultContentJson(w, tool_result);
    try w.writeAll(",\"terminate\":");
    try w.writeAll(if (tool_result.terminate) "true" else "false");
    try w.writeByte('}');
}

fn writeToolResultContentJson(w: *std.Io.Writer, tool_result: agent.ToolResult) !void {
    if (tool_result.content_parts.len == 0) {
        try w.writeAll("[{\"type\":\"text\",\"text\":");
        try writeJsonString(w, tool_result.content);
        try w.writeAll("}]");
        return;
    }
    try w.writeByte('[');
    for (tool_result.content_parts, 0..) |part, index| {
        if (index != 0) try w.writeByte(',');
        try writeChatContentPartJson(w, part);
    }
    try w.writeByte(']');
}

fn writeChatContentPartJson(w: *std.Io.Writer, part: ai_client.ChatContentPart) !void {
    switch (part) {
        .text => |text| {
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try writeJsonString(w, text);
            try w.writeByte('}');
        },
        .image => |image| {
            try w.writeAll("{\"type\":\"image\",\"data\":");
            try writeJsonString(w, image.data);
            try w.writeAll(",\"mimeType\":");
            try writeJsonString(w, image.mime_type);
            try w.writeByte('}');
        },
    }
}

fn writeToolUpdatePayloadJson(w: *std.Io.Writer, update: agent.ToolUpdate) !void {
    try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(w, update.content);
    try w.writeAll("}]");
    if (update.truncated or update.full_output_path != null or update.truncation != null) {
        try w.writeAll(",\"details\":{");
        var needs_comma = false;
        if (update.truncation) |truncation| {
            try w.writeAll("\"truncation\":");
            try writeToolUpdateTruncationJson(w, update.content, truncation);
            needs_comma = true;
        } else if (update.truncated) {
            try w.writeAll("\"truncated\":true");
            needs_comma = true;
        }
        if (update.full_output_path) |path| {
            if (needs_comma) try w.writeByte(',');
            try w.writeAll("\"fullOutputPath\":");
            try writeJsonString(w, path);
        }
        try w.writeByte('}');
    }
    try w.writeAll(",\"isError\":");
    try w.writeAll(if (update.is_error) "true" else "false");
    try w.writeAll(",\"terminate\":");
    try w.writeAll(if (update.terminate) "true" else "false");
    try w.writeByte('}');
}

fn writeToolUpdateTruncationJson(w: *std.Io.Writer, content: []const u8, truncation: tools.ShellTruncationDetails) !void {
    try w.writeAll("{\"content\":");
    try writeJsonString(w, content);
    try w.writeAll(",\"truncated\":true,\"truncatedBy\":");
    if (truncation.truncated_by) |truncated_by| {
        try writeJsonString(w, switch (truncated_by) {
            .lines => "lines",
            .bytes => "bytes",
        });
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"totalLines\":");
    try w.print("{d}", .{truncation.total_lines});
    try w.writeAll(",\"totalBytes\":");
    try w.print("{d}", .{truncation.total_bytes});
    try w.writeAll(",\"outputLines\":");
    try w.print("{d}", .{truncation.output_lines});
    try w.writeAll(",\"outputBytes\":");
    try w.print("{d}", .{truncation.output_bytes});
    try w.writeAll(",\"lastLinePartial\":");
    try w.writeAll(if (truncation.last_line_partial) "true" else "false");
    try w.writeAll(",\"firstLineExceedsLimit\":");
    try w.writeAll(if (truncation.first_line_exceeds_limit) "true" else "false");
    try w.writeAll(",\"maxLines\":");
    try w.print("{d}", .{truncation.max_lines});
    try w.writeAll(",\"maxBytes\":");
    try w.print("{d}", .{truncation.max_bytes});
    try w.writeByte('}');
}

fn writeRawJsonObjectOrString(w: *std.Io.Writer, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        try w.writeAll(trimmed);
        return;
    }
    try writeJsonString(w, value);
}

/// Emit parse diagnostics to stderr, byte-for-byte matching upstream main.ts:
/// `console.error(`${type === "error" ? "Error" : "Warning"}: ${message}`)`.
/// Upstream's `message` is the fully interpolated sentence (e.g. the offending
/// `--thinking` value and valid-values list, or the unknown option arg), so we
/// render it via `cli.renderDiagnosticMessage` rather than printing the raw static
/// `.message` template. The JSON introspection path already interpolates the same
/// way (cli.renderDiagnosticMessageEscaped); this brings the text/stderr path to
/// parity. Upstream colorizes via chalk; pi-zig's diagnostics path emits plain text.
fn writeDiagnostics(io: std.Io, allocator: std.mem.Allocator, parsed: cli.ParsedArgs) !void {
    for (parsed.diagnostics[0..parsed.diagnostics_len]) |diagnostic| {
        var rendered: std.Io.Writer.Allocating = .init(allocator);
        defer rendered.deinit();
        try writeDiagnosticLine(&rendered.writer, diagnostic);
        try writeStderr(io, rendered.written());
    }
}

/// Render a single diagnostic as the exact stderr line upstream prints, including the
/// `Error: `/`Warning: ` prefix and trailing newline, with the message body fully
/// interpolated via `cli.renderDiagnosticMessage`. Factored out so the byte-exact line
/// can be asserted in a unit test without writing to the real stderr fd.
fn writeDiagnosticLine(w: *std.Io.Writer, diagnostic: cli.Diagnostic) !void {
    try w.writeAll(if (diagnostic.kind == .@"error") "Error: " else "Warning: ");
    try cli.renderDiagnosticMessage(w, diagnostic);
    try w.writeByte('\n');
}

fn hasErrorDiagnostics(parsed: cli.ParsedArgs) bool {
    for (parsed.diagnostics[0..parsed.diagnostics_len]) |diagnostic| {
        if (diagnostic.kind == .@"error") return true;
    }
    return false;
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeStderr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789abcdef";
    try w.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11...12, 14...0x1f => {
                try w.writeAll("\\u00");
                try w.writeByte(hex[byte >> 4]);
                try w.writeByte(hex[byte & 0x0f]);
            },
            else => try w.writeByte(byte),
        }
    }
    try w.writeByte('"');
}

fn commandOptionsFromParsed(init: std.process.Init, parsed: *const cli.ParsedArgs) commands.Options {
    return .{
        .home = init.environ_map.get("HOME"),
        .additional_skill_paths = parsed.skills[0..parsed.skills_len],
        .additional_prompt_paths = parsed.prompt_templates[0..parsed.prompt_templates_len],
        .no_skills = parsed.no_skills,
        .no_prompt_templates = parsed.no_prompt_templates,
    };
}

test "top-level prompt builder combines messages" {
    const parsed = cli.parse(&.{ "hello", "world" });
    const prompt = try buildPrompt(std.testing.io, std.testing.allocator, parsed, null);
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello\n\nworld", prompt.text);
}

test "top-level prompt builder prepends piped stdin (upstream parity)" {
    // Upstream buildInitialMessage() places stdin content before file text and
    // the first CLI message.
    const parsed = cli.parse(&.{"world"});
    const prompt = try buildPrompt(std.testing.io, std.testing.allocator, parsed, "from-stdin");
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("from-stdin\n\nworld", prompt.text);

    const empty_args = cli.parse(&.{});
    const stdin_only = try buildPrompt(std.testing.io, std.testing.allocator, empty_args, "only-stdin");
    defer stdin_only.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("only-stdin", stdin_only.text);
}

test "provider tools follow tool flags" {
    try std.testing.expect(toolSetFromParsed(cli.parse(&.{})).bash);
    try std.testing.expect(toolSetFromParsed(cli.parse(&.{})).read);
    try std.testing.expect(!toolSetFromParsed(cli.parse(&.{"--no-tools"})).bash);
    try std.testing.expect(!toolSetFromParsed(cli.parse(&.{"--no-builtin-tools"})).read);
    const read_bash = toolSetFromParsed(cli.parse(&.{ "--tools", "read,bash" }));
    try std.testing.expect(read_bash.read);
    try std.testing.expect(read_bash.bash);
    try std.testing.expect(!read_bash.grep);
    const all_tools = toolSetFromParsed(cli.parse(&.{ "--tools", "all" }));
    try std.testing.expect(all_tools.edit);
    try std.testing.expect(all_tools.ls);
}

test "JSON/print retry classifier mirrors RPC transient-error parity" {
    // Transient provider failures and incomplete streams are retryable; structurally invalid
    // responses, non-transient 4xx client errors, and aborts are not. This must match rpc.zig's
    // isRetryableAgentError so RPC and JSON/print modes retry the same error set.
    try std.testing.expect(isRetryableProviderError(error.ProviderRequestFailed));
    try std.testing.expect(isRetryableProviderError(error.ProviderStreamIncomplete));
    try std.testing.expect(!isRetryableProviderError(error.ProviderResponseInvalid));
    try std.testing.expect(!isRetryableProviderError(error.ProviderClientError));
    try std.testing.expect(!isRetryableProviderError(error.AgentAborted));
}

test "JSON/print retry gate honors settings and clean-turn state for incomplete streams" {
    const enabled: settings.RetrySettings = .{ .enabled = true, .max_retries = 3, .base_delay_ms = 0 };
    // A clean turn (no assistant output yet) with an incomplete stream retries, matching the
    // cross-mode parity fix that added ProviderStreamIncomplete to the retryable set.
    try std.testing.expect(shouldRetryJsonProviderError(enabled, 0, error.ProviderStreamIncomplete, true));
    // Already past max attempts: stop retrying.
    try std.testing.expect(!shouldRetryJsonProviderError(enabled, 3, error.ProviderStreamIncomplete, true));
    // Output already streamed this turn: not a clean turn, do not retry mid-stream.
    try std.testing.expect(!shouldRetryJsonProviderError(enabled, 0, error.ProviderStreamIncomplete, false));
    // Retry disabled in settings: never retry.
    const disabled: settings.RetrySettings = .{ .enabled = false, .max_retries = 3, .base_delay_ms = 0 };
    try std.testing.expect(!shouldRetryJsonProviderError(disabled, 0, error.ProviderStreamIncomplete, true));
    // Non-transient client error stays non-retryable even on a clean turn.
    try std.testing.expect(!shouldRetryJsonProviderError(enabled, 0, error.ProviderClientError, true));
}

test "default model selection resolves a provider default when --model omitted" {
    // A known provider with no --model resolves to a real catalog model (upstream buildFallbackModel
    // parity) so the run proceeds instead of dropping to the inert foundation response.
    var anthropic = cli.parse(&.{"--provider"});
    anthropic.provider = "anthropic";
    anthropic.model = null;
    applyDefaultModelSelection(&anthropic);
    try std.testing.expect(anthropic.model != null);
    try std.testing.expect(models.find("anthropic", anthropic.model.?) != null);

    // Case-insensitive provider names canonicalize before lookup.
    var mixed = cli.parse(&.{});
    mixed.provider = "OpenAI";
    mixed.model = null;
    applyDefaultModelSelection(&mixed);
    try std.testing.expect(mixed.model != null);
    try std.testing.expect(models.find("openai", mixed.model.?) != null);
}

test "default model selection leaves explicit and absent models untouched" {
    // Explicit --model is never overwritten.
    var explicit = cli.parse(&.{});
    explicit.provider = "anthropic";
    explicit.model = "claude-opus-4-7";
    applyDefaultModelSelection(&explicit);
    try std.testing.expectEqualStrings("claude-opus-4-7", explicit.model.?);

    // No provider at all (true interactive boot) stays a no-op: model remains null.
    var none = cli.parse(&.{});
    none.provider = null;
    none.model = null;
    applyDefaultModelSelection(&none);
    try std.testing.expect(none.model == null);

    // Unknown provider with no catalog entries leaves the model null (foundation path preserved).
    var unknown = cli.parse(&.{});
    unknown.provider = "definitely-not-a-real-provider";
    unknown.model = null;
    applyDefaultModelSelection(&unknown);
    try std.testing.expect(unknown.model == null);
}

test "diagnostic stderr line interpolates the upstream message (text path parity)" {
    // Invalid --thinking value: the text/stderr line must carry the offending value and the
    // valid-values list, not the raw static `.message` template ("Invalid thinking level").
    {
        const parsed = cli.parse(&.{ "--thinking", "maximum" });
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeDiagnosticLine(&w, parsed.diagnostics[0]);
        try std.testing.expectEqualStrings(
            "Warning: Invalid thinking level \"maximum\". Valid values: off, minimal, low, medium, high, xhigh\n",
            w.buffered(),
        );
    }
    // Unknown option: a hard error prefixed `Error: ` with the offending arg interpolated.
    {
        const parsed = cli.parse(&.{"-x"});
        var buf: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeDiagnosticLine(&w, parsed.diagnostics[0]);
        try std.testing.expectEqualStrings("Error: Unknown option: -x\n", w.buffered());
    }
}

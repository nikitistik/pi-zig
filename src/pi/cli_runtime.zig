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

const all_tool_names = [_][]const u8{ "read", "bash", "edit", "write", "grep", "find", "ls" };

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

pub fn runTopLevel(init: std.process.Init, argv: []const []const u8) !void {
    const parsed = cli.parse(argv);

    try writeDiagnostics(init.io, parsed);
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

    const mode = parsed.mode orelse cli.Mode.text;
    if (mode == .rpc) {
        if (parsed.file_args_len > 0) {
            try writeStderr(init.io, "Error: @file arguments are not supported in RPC mode.\n");
            return error.InvalidCliArguments;
        }
        const path = try resolveSessionPath(init.io, init.gpa, init.environ_map, parsed);
        defer path.deinit(init.gpa);
        var runtime_extensions = try discoverRuntimeExtensionPaths(init.io, init.gpa, init.environ_map, parsed);
        defer runtime_extensions.deinit(init.gpa);
        var command_options = commandOptionsFromParsed(init, &parsed);
        command_options.extension_paths = runtime_extensions.paths;
        const extension_flag_values = try extensionFlagValuesFromParsed(init.gpa, parsed);
        defer if (extension_flag_values.len > 0) init.gpa.free(extension_flag_values);
        return rpc.run(init.io, init.gpa, init.environ_map, path.path, .{
            .command_options = command_options,
            .extension_paths = runtime_extensions.paths,
            .extension_flag_values = extension_flag_values,
            .tool_set = toolSetFromParsed(parsed),
            .custom_tools_enabled = !parsed.no_tools,
            .tool_allowlist = parsed.tools,
        });
    }

    const prompt = try buildPrompt(init.io, init.gpa, parsed);
    defer prompt.deinit(init.gpa);

    if (prompt.text.len == 0 and !parsed.print and parsed.messages_len == 0 and parsed.file_args_len == 0) {
        try writeStderr(init.io, "pi-zig interactive TUI mode is not implemented yet. Use -p, --mode json, or --mode rpc for the current foundation runtime.\n");
        return writeTopLevelHelp(init.io);
    }

    return switch (mode) {
        .json => runJsonPrintFoundation(init.io, init.gpa, init.environ_map, parsed, prompt.text, prompt.image_parts),
        .text => runTextPrintFoundation(init.io, init.gpa, init.environ_map, parsed, prompt.text, prompt.image_parts),
        .rpc => unreachable,
    };
}

pub fn writeTopLevelHelp(io: std.Io) !void {
    try writeStdout(io,
        \\pi-zig - Zig + Preact port of earendil-works/pi
        \\
        \\Usage:
        \\  pi-zig [options] [@files...] [messages...]
        \\
        \\Top-level options:
        \\  --mode <text|json|rpc>        Output mode; rpc reads JSONL commands from stdin
        \\  --print, -p [prompt]          Non-interactive text mode
        \\  --session <path|id>           Use a session JSONL file or id prefix
        \\  --session-dir <dir>           Store and look up sessions under a directory
        \\  --continue, -c                Continue the newest session in the session directory
        \\  --resume, -r                  Foundation alias for newest session lookup
        \\  --fork <path|id>              Fork a session into the current session directory
        \\  --no-session                  Do not persist prompt-mode messages
        \\  --provider <name>             Provider name parsed for upstream CLI parity
        \\  --model <pattern>             Model pattern parsed for upstream CLI parity
        \\  --thinking <level>            Thinking level parsed for upstream CLI parity
        \\  --list-models [search]        List generated upstream model catalog
        \\  --export <session> [output]   Export a session JSONL file to HTML
        \\  --help, -h                    Show this help
        \\  --version, -v                 Show version
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

    const response = try buildPrintResponse(io, allocator, env, parsed, prompt_request.content, prompt_request.image_parts, false, null, null, null, null, null, null);
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
    return err == error.ProviderRequestFailed;
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

fn buildPrompt(io: std.Io, allocator: std.mem.Allocator, parsed: cli.ParsedArgs) !PromptResult {
    if (parsed.file_args_len == 0 and parsed.messages_len == 1) {
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
    }) catch |err| {
        try writeStderr(io, "Provider request failed: ");
        try writeStderr(io, @errorName(err));
        try writeStderr(io, "\n");
        return err;
    };
}

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
    const current_date = try system_prompt.currentUtcDate(io, &date_buf);

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

fn writeDiagnostics(io: std.Io, parsed: cli.ParsedArgs) !void {
    for (parsed.diagnostics[0..parsed.diagnostics_len]) |diagnostic| {
        try writeStderr(io, if (diagnostic.kind == .@"error") "Error: " else "Warning: ");
        try writeStderr(io, diagnostic.message);
        try writeStderr(io, "\n");
    }
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
    const prompt = try buildPrompt(std.testing.io, std.testing.allocator, parsed);
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello\n\nworld", prompt.text);
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

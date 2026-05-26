const std = @import("std");
const agent = @import("agent.zig");
const ai_client = @import("ai_client.zig");
const auth = @import("auth.zig");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const context_files = @import("context_files.zig");
const models = @import("models.zig");
const rpc = @import("rpc.zig");
const session = @import("session.zig");
const system_prompt = @import("system_prompt.zig");

const all_tool_names = [_][]const u8{ "read", "bash", "edit", "write", "grep", "find", "ls" };

const PromptResult = struct {
    text: []const u8,
    owned: bool = false,

    fn deinit(self: PromptResult, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.text);
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
};

pub fn runTopLevel(init: std.process.Init, argv: []const []const u8) !void {
    const parsed = cli.parse(argv);

    try writeDiagnostics(init.io, parsed);
    if (hasErrorDiagnostics(parsed)) return error.InvalidCliArguments;

    if (parsed.help) return writeTopLevelHelp(init.io);
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

    const mode = parsed.mode orelse cli.Mode.text;
    if (mode == .rpc) {
        if (parsed.file_args_len > 0) {
            try writeStderr(init.io, "Error: @file arguments are not supported in RPC mode.\n");
            return error.InvalidCliArguments;
        }
        const path = try resolveSessionPath(init.io, init.gpa, init.environ_map, parsed);
        defer path.deinit(init.gpa);
        return rpc.run(init.io, init.gpa, init.environ_map, path.path, commandOptionsFromParsed(init, &parsed));
    }

    const prompt = try buildPrompt(init.io, init.gpa, parsed);
    defer prompt.deinit(init.gpa);

    if (prompt.text.len == 0 and !parsed.print and parsed.messages_len == 0 and parsed.file_args_len == 0) {
        try writeStderr(init.io, "pi-zig interactive TUI mode is not implemented yet. Use -p, --mode json, or --mode rpc for the current foundation runtime.\n");
        return writeTopLevelHelp(init.io);
    }

    return switch (mode) {
        .json => runJsonPrintFoundation(init.io, init.gpa, init.environ_map, parsed, prompt.text),
        .text => runTextPrintFoundation(init.io, init.gpa, init.environ_map, parsed, prompt.text),
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
        \\extension execution, streamed tool calls, and full upstream agent parity remain incomplete.
        \\
    );
}

fn runTextPrintFoundation(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
    prompt: []const u8,
) !void {
    var store = try maybeOpenStore(io, allocator, env, parsed);
    if (store) |*persistent| {
        if (prompt.len > 0) _ = try persistent.appendMessage(io, allocator, .user, prompt);
    }

    const response = try buildPrintResponse(io, allocator, env, parsed, prompt);
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
) !void {
    if (shouldUseProviderTextStream(parsed)) {
        return runJsonProviderTextStream(io, allocator, env, parsed, prompt);
    }

    var store = try maybeOpenStore(io, allocator, env, parsed);
    if (store) |*persistent| {
        if (prompt.len > 0) _ = try persistent.appendMessage(io, allocator, .user, prompt);
    }

    const response = try buildPrintResponse(io, allocator, env, parsed, prompt);
    defer response.deinit(allocator);

    if (store) |*persistent| {
        _ = try persistent.appendMessage(io, allocator, .assistant, response.final_text);
    }

    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;

    try w.writeAll("{\"type\":\"session\",\"version\":3,\"id\":");
    if (store) |*persistent| {
        try writeJsonString(w, persistent.sessionId());
    } else {
        try writeJsonString(w, "pi-zig-ephemeral");
    }
    try w.writeAll(",\"timestamp\":\"local-foundation\",\"cwd\":\".\"}\n");
    try w.writeAll("{\"type\":\"agent_start\"}\n");
    try w.writeAll("{\"type\":\"turn_start\"}\n");
    for (response.tool_results) |tool_result| {
        try writeToolExecutionStartJson(w, tool_result);
        try w.writeByte('\n');
        try writeToolExecutionEndJson(w, tool_result);
        try w.writeByte('\n');
        try w.writeAll("{\"type\":\"message_start\",\"message\":");
        try writeToolResultMessageJson(w, tool_result);
        try w.writeAll("}\n");
        try w.writeAll("{\"type\":\"message_end\",\"message\":");
        try writeToolResultMessageJson(w, tool_result);
        try w.writeAll("}\n");
    }
    try w.writeAll("{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n");
    try w.writeAll("{\"type\":\"message_update\",\"message\":");
    try writeAssistantMessageJson(w, response.final_text);
    try w.writeAll(",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":");
    try writeJsonString(w, response.final_text);
    try w.writeAll("}}\n");
    try w.writeAll("{\"type\":\"message_end\",\"message\":");
    try writeAssistantMessageJson(w, response.final_text);
    try w.writeAll("}\n");
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
    try w.writeAll("]}\n");
    try w.flush();
}

fn shouldUseProviderTextStream(parsed: cli.ParsedArgs) bool {
    return parsed.provider != null and parsed.model != null and (parsed.no_tools or parsed.no_builtin_tools);
}

fn runJsonProviderTextStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    parsed: cli.ParsedArgs,
    prompt: []const u8,
) !void {
    var store = try maybeOpenStore(io, allocator, env, parsed);
    if (store) |*persistent| {
        if (prompt.len > 0) _ = try persistent.appendMessage(io, allocator, .user, prompt);
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
    messages_buf[messages_len] = .{ .role = .user, .content = prompt };
    messages_len += 1;

    try emitJsonPrelude(io, allocator, if (store) |*persistent| persistent.sessionId() else "pi-zig-ephemeral");
    try writeStreamingJsonLine(io, allocator, "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n");

    var final_text: std.Io.Writer.Allocating = .init(allocator);
    defer final_text.deinit();
    var stream_context = JsonStreamContext{
        .io = io,
        .allocator = allocator,
        .final_text = &final_text,
    };

    try ai_client.streamChatTurnText(io, allocator, env, .{
        .provider = provider,
        .model = model,
        .api_key = api_key,
        .messages = messages_buf[0..messages_len],
        .tools = &.{},
    }, &stream_context, handleJsonStreamTextDelta);

    if (final_text.written().len == 0) return error.ProviderResponseInvalid;
    if (store) |*persistent| {
        _ = try persistent.appendMessage(io, allocator, .assistant, final_text.written());
    }

    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    const w = &line.writer;
    try w.writeAll("{\"type\":\"message_end\",\"message\":");
    try writeAssistantMessageJson(w, final_text.written());
    try w.writeAll("}\n");
    try w.writeAll("{\"type\":\"turn_end\",\"message\":");
    try writeAssistantMessageJson(w, final_text.written());
    try w.writeAll(",\"toolResults\":[]}\n");
    try w.writeAll("{\"type\":\"agent_end\",\"messages\":[");
    try writeAssistantMessageJson(w, final_text.written());
    try w.writeAll("]}\n");
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

fn handleJsonStreamTextDelta(ctx_ptr: *anyopaque, delta: []const u8) anyerror!void {
    const ctx: *JsonStreamContext = @ptrCast(@alignCast(ctx_ptr));
    try ctx.final_text.writer.writeAll(delta);

    var line: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer line.deinit();
    const w = &line.writer;
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

    for (parsed.file_args[0..parsed.file_args_len]) |path| {
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

    return .{ .text = try out.toOwnedSlice(), .owned = true };
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

    return agent.runPrompt(io, allocator, env, .{
        .provider = provider,
        .model = model,
        .api_key = api_key,
        .prompt = prompt,
        .system_prompt = runtime_system_prompt,
        .tool_set = toolSetFromParsed(parsed),
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
    try w.writeAll("{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.writeAll("}],\"stopReason\":\"end\"}");
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

fn writeToolExecutionEndJson(w: *std.Io.Writer, tool_result: agent.ToolResult) !void {
    try w.writeAll("{\"type\":\"tool_execution_end\",\"toolCallId\":");
    try writeJsonString(w, tool_result.tool_call_id);
    try w.writeAll(",\"toolName\":");
    try writeJsonString(w, tool_result.tool_name);
    try w.writeAll(",\"result\":");
    try writeToolResultPayloadJson(w, tool_result);
    try w.writeAll(",\"isError\":");
    try w.writeAll(if (tool_result.is_error) "true" else "false");
    try w.writeByte('}');
}

fn writeToolResultMessageJson(w: *std.Io.Writer, tool_result: agent.ToolResult) !void {
    try w.writeAll("{\"role\":\"toolResult\",\"toolCallId\":");
    try writeJsonString(w, tool_result.tool_call_id);
    try w.writeAll(",\"toolName\":");
    try writeJsonString(w, tool_result.tool_name);
    try w.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(w, tool_result.content);
    try w.writeAll("}],\"isError\":");
    try w.writeAll(if (tool_result.is_error) "true" else "false");
    try w.writeByte('}');
}

fn writeToolResultPayloadJson(w: *std.Io.Writer, tool_result: agent.ToolResult) !void {
    try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(w, tool_result.content);
    try w.writeAll("}]}");
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

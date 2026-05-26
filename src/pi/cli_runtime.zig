const std = @import("std");
const ai_client = @import("ai_client.zig");
const auth = @import("auth.zig");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const models = @import("models.zig");
const rpc = @import("rpc.zig");
const session = @import("session.zig");

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
        return rpc.run(init.io, init.gpa, path.path, commandOptionsFromParsed(init, &parsed));
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
        \\Current top-level scope: print/json/rpc entry-point foundation. Provider execution,
        \\interactive TUI, extension execution, provider execution, and full agent loop remain incomplete.
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
    defer allocator.free(response);

    if (store) |*persistent| {
        _ = try persistent.appendMessage(io, allocator, .assistant, response);
    }

    try writeStdout(io, response);
    try writeStdout(io, "\n");
}

fn runJsonPrintFoundation(
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
    defer allocator.free(response);

    if (store) |*persistent| {
        _ = try persistent.appendMessage(io, allocator, .assistant, response);
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
    try w.writeAll("{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n");
    try w.writeAll("{\"type\":\"message_update\",\"message\":");
    try writeAssistantMessageJson(w, response);
    try w.writeAll(",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":");
    try writeJsonString(w, response);
    try w.writeAll("}}\n");
    try w.writeAll("{\"type\":\"message_end\",\"message\":");
    try writeAssistantMessageJson(w, response);
    try w.writeAll("}\n");
    try w.writeAll("{\"type\":\"turn_end\",\"message\":");
    try writeAssistantMessageJson(w, response);
    try w.writeAll(",\"toolResults\":[]}\n");
    try w.writeAll("{\"type\":\"agent_end\",\"messages\":[");
    try writeAssistantMessageJson(w, response);
    try w.writeAll("]}\n");
    try w.flush();
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

fn buildFoundationResponse(allocator: std.mem.Allocator, parsed: cli.ParsedArgs, prompt: []const u8) ![]const u8 {
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
) ![]const u8 {
    if (parsed.provider == null or parsed.model == null) {
        return buildFoundationResponse(allocator, parsed, prompt);
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

    const system_override = try buildSystemOverride(allocator, parsed);
    defer if (system_override) |value| allocator.free(value);

    return ai_client.runChatCompletion(io, allocator, env, .{
        .provider = provider,
        .model = model,
        .api_key = api_key,
        .prompt = prompt,
        .system_prompt = system_override,
    }) catch |err| {
        try writeStderr(io, "Provider request failed: ");
        try writeStderr(io, @errorName(err));
        try writeStderr(io, "\n");
        return err;
    };
}

fn buildSystemOverride(allocator: std.mem.Allocator, parsed: cli.ParsedArgs) !?[]u8 {
    if (parsed.system_prompt == null and parsed.append_system_prompts_len == 0) return null;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    if (parsed.system_prompt) |system_prompt| {
        try out.writer.writeAll(system_prompt);
    }
    for (parsed.append_system_prompts[0..parsed.append_system_prompts_len]) |append_prompt| {
        if (out.written().len != 0) try out.writer.writeAll("\n\n");
        try out.writer.writeAll(append_prompt);
    }
    return try out.toOwnedSlice();
}

fn writeAssistantMessageJson(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.writeAll("}],\"stopReason\":\"end\"}");
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

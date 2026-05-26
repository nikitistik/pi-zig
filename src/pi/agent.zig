const std = @import("std");
const ai_client = @import("ai_client.zig");
const tools = @import("tools.zig");

pub const RunOptions = struct {
    provider: []const u8,
    model: []const u8,
    api_key: []const u8,
    prompt: []const u8,
    system_prompt: ?[]const u8 = null,
    max_turns: usize = 8,
    tool_set: ToolSet = .all,
};

pub const ToolSet = struct {
    read: bool = true,
    bash: bool = true,
    edit: bool = true,
    write: bool = true,
    grep: bool = true,
    find: bool = true,
    ls: bool = true,

    pub const none: ToolSet = .{
        .read = false,
        .bash = false,
        .edit = false,
        .write = false,
        .grep = false,
        .find = false,
        .ls = false,
    };
    pub const all: ToolSet = .{};

    pub fn contains(self: ToolSet, name: []const u8) bool {
        if (std.mem.eql(u8, name, "read")) return self.read;
        if (std.mem.eql(u8, name, "bash")) return self.bash;
        if (std.mem.eql(u8, name, "edit")) return self.edit;
        if (std.mem.eql(u8, name, "write")) return self.write;
        if (std.mem.eql(u8, name, "grep")) return self.grep;
        if (std.mem.eql(u8, name, "find")) return self.find;
        if (std.mem.eql(u8, name, "ls")) return self.ls;
        return false;
    }
};

pub const RunResult = struct {
    final_text: []u8,
    tool_results_count: usize = 0,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.final_text);
    }
};

pub const AgentError = anyerror;

const bash_parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string","description":"Bash command to execute"},"timeout":{"type":"number","description":"Timeout in seconds (optional, no default timeout)"}},"required":["command"],"additionalProperties":false}
;
const read_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to read (relative or absolute)"},"offset":{"type":"number","description":"Line number to start reading from (1-indexed)"},"limit":{"type":"number","description":"Maximum number of lines to read"}},"required":["path"],"additionalProperties":false}
;
const edit_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to edit (relative or absolute)"},"edits":{"type":"array","description":"One or more targeted replacements matched against the original file.","items":{"type":"object","properties":{"oldText":{"type":"string","description":"Exact unique text to replace"},"newText":{"type":"string","description":"Replacement text"}},"required":["oldText","newText"],"additionalProperties":false}}},"required":["path","edits"],"additionalProperties":false}
;
const write_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to write (relative or absolute)"},"content":{"type":"string","description":"Content to write to the file"}},"required":["path","content"],"additionalProperties":false}
;
const grep_parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Search pattern (regex or literal string)"},"path":{"type":"string","description":"Directory or file to search (default: current directory)"},"glob":{"type":"string","description":"Filter files by glob pattern"},"ignoreCase":{"type":"boolean","description":"Case-insensitive search"},"literal":{"type":"boolean","description":"Treat pattern as literal string"},"context":{"type":"number","description":"Number of lines before and after each match"},"limit":{"type":"number","description":"Maximum number of matches to return"}},"required":["pattern"],"additionalProperties":false}
;
const find_parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern to match files"},"path":{"type":"string","description":"Directory to search in (default: current directory)"},"limit":{"type":"number","description":"Maximum number of results"}},"required":["pattern"],"additionalProperties":false}
;
const ls_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Directory to list (default: current directory)"},"limit":{"type":"number","description":"Maximum number of entries to return"}},"additionalProperties":false}
;

const all_tool_definitions = [_]ai_client.ChatToolDefinition{
    .{
        .name = "read",
        .description = "Read the contents of a file. Supports text files with offset and limit. Output is truncated to pi-zig read-tool limits.",
        .parameters_json = read_parameters_json,
    },
    .{
        .name = "bash",
        .description = "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to the same limits as pi-zig tool-bash.",
        .parameters_json = bash_parameters_json,
    },
    .{
        .name = "edit",
        .description = "Apply one or more exact targeted replacements to a file.",
        .parameters_json = edit_parameters_json,
    },
    .{
        .name = "write",
        .description = "Write content to a file, creating parent directories and overwriting existing content.",
        .parameters_json = write_parameters_json,
    },
    .{
        .name = "grep",
        .description = "Search file contents for a pattern. Respects .gitignore through ripgrep and returns file paths with line numbers.",
        .parameters_json = grep_parameters_json,
    },
    .{
        .name = "find",
        .description = "Search for files by glob pattern. Returns matching paths relative to the search directory.",
        .parameters_json = find_parameters_json,
    },
    .{
        .name = "ls",
        .description = "List directory contents sorted alphabetically, with slash suffixes for directories.",
        .parameters_json = ls_parameters_json,
    },
};

const OwnedMessage = struct {
    role: ai_client.ChatRole,
    content: []u8,
    tool_call_id: ?[]u8 = null,
    tool_calls: []ai_client.ChatToolCall = &.{},

    fn deinit(self: OwnedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.tool_call_id) |id| allocator.free(id);
        for (self.tool_calls) |call| call.deinit(allocator);
        allocator.free(self.tool_calls);
    }

    fn borrowed(self: *const OwnedMessage) ai_client.ChatMessage {
        return .{
            .role = self.role,
            .content = self.content,
            .tool_call_id = self.tool_call_id,
            .tool_calls = self.tool_calls,
        };
    }
};

pub fn runPrompt(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    options: RunOptions,
) AgentError!RunResult {
    var messages: std.ArrayList(OwnedMessage) = .empty;
    defer {
        for (messages.items) |message| message.deinit(allocator);
        messages.deinit(allocator);
    }

    if (options.system_prompt) |system_prompt| {
        const trimmed = std.mem.trim(u8, system_prompt, " \t\r\n");
        if (trimmed.len > 0) {
            try messages.append(allocator, .{
                .role = .system,
                .content = try allocator.dupe(u8, trimmed),
            });
        }
    }
    try messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, options.prompt),
    });

    var tool_results_count: usize = 0;
    var tool_definitions_buf: [all_tool_definitions.len]ai_client.ChatToolDefinition = undefined;
    const tool_definitions = enabledToolDefinitions(options.tool_set, &tool_definitions_buf);
    var turn: usize = 0;
    while (turn < options.max_turns) : (turn += 1) {
        const borrowed = try borrowMessages(allocator, messages.items);
        defer allocator.free(borrowed);

        var response = try ai_client.runChatTurn(io, allocator, env, .{
            .provider = options.provider,
            .model = options.model,
            .api_key = options.api_key,
            .messages = borrowed,
            .tools = tool_definitions,
        });
        defer response.deinit(allocator);

        if (response.tool_calls.len == 0) {
            const text = if (response.text) |value| value else try allocator.dupe(u8, "");
            response.text = null;
            return .{
                .final_text = text,
                .tool_results_count = tool_results_count,
            };
        }

        try appendAssistantToolCallMessage(allocator, &messages, &response);
        const tool_calls = messages.items[messages.items.len - 1].tool_calls;
        response.tool_calls = &.{};

        for (tool_calls) |call| {
            const tool_output = try executeToolCall(io, allocator, call);
            errdefer allocator.free(tool_output);
            const tool_call_id = try allocator.dupe(u8, call.id);
            errdefer allocator.free(tool_call_id);
            try messages.append(allocator, .{
                .role = .tool,
                .content = tool_output,
                .tool_call_id = tool_call_id,
            });
            tool_results_count += 1;
        }
    }

    return error.MaxAgentTurnsExceeded;
}

fn borrowMessages(allocator: std.mem.Allocator, messages: []const OwnedMessage) ![]ai_client.ChatMessage {
    const borrowed = try allocator.alloc(ai_client.ChatMessage, messages.len);
    for (messages, 0..) |*message, index| {
        borrowed[index] = message.borrowed();
    }
    return borrowed;
}

fn enabledToolDefinitions(
    tool_set: ToolSet,
    buf: *[all_tool_definitions.len]ai_client.ChatToolDefinition,
) []const ai_client.ChatToolDefinition {
    var len: usize = 0;
    for (all_tool_definitions) |definition| {
        if (!tool_set.contains(definition.name)) continue;
        buf[len] = definition;
        len += 1;
    }
    return buf[0..len];
}

fn appendAssistantToolCallMessage(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(OwnedMessage),
    response: *ai_client.ChatCompletionResult,
) !void {
    const content = if (response.text) |text| text else try allocator.dupe(u8, "");
    errdefer allocator.free(content);
    response.text = null;
    try messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .tool_calls = response.tool_calls,
    });
}

fn executeToolCall(
    io: std.Io,
    allocator: std.mem.Allocator,
    call: ai_client.ChatToolCall,
) ![]u8 {
    if (std.mem.eql(u8, call.name, "read")) return executeReadTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "bash")) return executeBashTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "edit")) return executeEditTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "write")) return executeWriteTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "grep")) return executeGrepTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "find")) return executeFindTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "ls")) return executeLsTool(io, allocator, call.arguments_json);
    return std.fmt.allocPrint(allocator, "Tool {s} is not implemented in pi-zig yet.", .{call.name});
}

fn executeReadTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    var parsed = parseArguments(allocator, "read", arguments_json) catch |err| return invalidJsonMessage(allocator, "read", err);
    defer parsed.deinit();
    const path = requiredString(parsed.value, "path") orelse return allocator.dupe(u8, "read tool arguments are missing path.");
    const offset = optionalUsize(parsed.value, "offset") catch return allocator.dupe(u8, "read tool offset must be a non-negative number.");
    const limit = optionalUsize(parsed.value, "limit") catch return allocator.dupe(u8, "read tool limit must be a non-negative number.");
    return tools.readFileForToolText(io, allocator, path, offset, limit) catch |err| {
        return std.fmt.allocPrint(allocator, "read tool failed: {s}", .{@errorName(err)});
    };
}

fn executeBashTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    var parsed = parseArguments(allocator, "bash", arguments_json) catch |err| return invalidJsonMessage(allocator, "bash", err);
    defer parsed.deinit();

    if (parsed.value != .object) return allocator.dupe(u8, "bash tool arguments must be a JSON object.");
    const command = requiredString(parsed.value, "command") orelse return allocator.dupe(u8, "bash tool arguments are missing command.");

    const shell_result = tools.runShellCapture(io, allocator, command) catch |err| {
        return std.fmt.allocPrint(allocator, "bash tool failed before execution: {s}", .{@errorName(err)});
    };
    defer allocator.free(shell_result.output);

    return allocator.dupe(u8, shell_result.output);
}

fn executeEditTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    var parsed = parseArguments(allocator, "edit", arguments_json) catch |err| return invalidJsonMessage(allocator, "edit", err);
    defer parsed.deinit();
    const path = requiredString(parsed.value, "path") orelse return allocator.dupe(u8, "edit tool arguments are missing path.");
    const edits_value = fieldValue(parsed.value, "edits") orelse return allocator.dupe(u8, "edit tool arguments are missing edits.");
    if (edits_value != .array) return allocator.dupe(u8, "edit tool edits must be an array.");

    var edit_replacements: std.ArrayList(tools.EditReplacement) = .empty;
    defer edit_replacements.deinit(allocator);
    for (edits_value.array.items) |edit_value| {
        if (edit_value != .object) return allocator.dupe(u8, "edit tool edits entries must be objects.");
        const old_text = requiredString(edit_value, "oldText") orelse return allocator.dupe(u8, "edit tool edit is missing oldText.");
        const new_text = requiredString(edit_value, "newText") orelse return allocator.dupe(u8, "edit tool edit is missing newText.");
        try edit_replacements.append(allocator, .{ .old_text = old_text, .new_text = new_text });
    }
    return tools.editFileManyText(io, allocator, path, edit_replacements.items) catch |err| {
        return std.fmt.allocPrint(allocator, "edit tool failed: {s}", .{@errorName(err)});
    };
}

fn executeWriteTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    var parsed = parseArguments(allocator, "write", arguments_json) catch |err| return invalidJsonMessage(allocator, "write", err);
    defer parsed.deinit();
    const path = requiredString(parsed.value, "path") orelse return allocator.dupe(u8, "write tool arguments are missing path.");
    const content = requiredString(parsed.value, "content") orelse return allocator.dupe(u8, "write tool arguments are missing content.");
    return tools.writeFileForToolText(io, allocator, path, content) catch |err| {
        return std.fmt.allocPrint(allocator, "write tool failed: {s}", .{@errorName(err)});
    };
}

fn executeGrepTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    var parsed = parseArguments(allocator, "grep", arguments_json) catch |err| return invalidJsonMessage(allocator, "grep", err);
    defer parsed.deinit();
    const pattern = requiredString(parsed.value, "pattern") orelse return allocator.dupe(u8, "grep tool arguments are missing pattern.");
    const path = optionalString(parsed.value, "path") orelse ".";
    const options: tools.GrepOptions = .{
        .glob = optionalString(parsed.value, "glob"),
        .ignore_case = optionalBool(parsed.value, "ignoreCase") catch return allocator.dupe(u8, "grep tool ignoreCase must be a boolean."),
        .literal = optionalBool(parsed.value, "literal") catch return allocator.dupe(u8, "grep tool literal must be a boolean."),
        .context = (optionalUsize(parsed.value, "context") catch return allocator.dupe(u8, "grep tool context must be a non-negative number.")) orelse 0,
        .limit = (optionalUsize(parsed.value, "limit") catch return allocator.dupe(u8, "grep tool limit must be a non-negative number.")) orelse 100,
    };
    return tools.grepText(io, allocator, pattern, path, options) catch |err| {
        return std.fmt.allocPrint(allocator, "grep tool failed: {s}", .{@errorName(err)});
    };
}

fn executeFindTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    var parsed = parseArguments(allocator, "find", arguments_json) catch |err| return invalidJsonMessage(allocator, "find", err);
    defer parsed.deinit();
    const pattern = requiredString(parsed.value, "pattern") orelse return allocator.dupe(u8, "find tool arguments are missing pattern.");
    const path = optionalString(parsed.value, "path") orelse ".";
    const limit = (optionalUsize(parsed.value, "limit") catch return allocator.dupe(u8, "find tool limit must be a non-negative number.")) orelse 1000;
    return tools.findFilesText(io, allocator, pattern, path, limit) catch |err| {
        return std.fmt.allocPrint(allocator, "find tool failed: {s}", .{@errorName(err)});
    };
}

fn executeLsTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    var parsed = parseArguments(allocator, "ls", arguments_json) catch |err| return invalidJsonMessage(allocator, "ls", err);
    defer parsed.deinit();
    const path = optionalString(parsed.value, "path") orelse ".";
    const limit = (optionalUsize(parsed.value, "limit") catch return allocator.dupe(u8, "ls tool limit must be a non-negative number.")) orelse 500;
    return tools.listDirText(io, allocator, path, limit) catch |err| {
        return std.fmt.allocPrint(allocator, "ls tool failed: {s}", .{@errorName(err)});
    };
}

fn parseArguments(allocator: std.mem.Allocator, tool_name: []const u8, arguments_json: []const u8) !std.json.Parsed(std.json.Value) {
    _ = tool_name;
    return std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
}

fn invalidJsonMessage(allocator: std.mem.Allocator, tool_name: []const u8, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} tool argument JSON is invalid: {s}", .{ tool_name, @errorName(err) });
}

fn fieldValue(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn requiredString(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = fieldValue(value, name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn optionalString(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = fieldValue(value, name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn optionalBool(value: std.json.Value, name: []const u8) !bool {
    const field = fieldValue(value, name) orelse return false;
    if (field != .bool) return error.InvalidToolArgument;
    return field.bool;
}

fn optionalUsize(value: std.json.Value, name: []const u8) !?usize {
    const field = fieldValue(value, name) orelse return null;
    switch (field) {
        .integer => |integer| {
            if (integer < 0) return error.InvalidToolArgument;
            return @intCast(integer);
        },
        .float => |float| {
            if (float < 0 or @floor(float) != float) return error.InvalidToolArgument;
            return @intFromFloat(float);
        },
        else => return error.InvalidToolArgument,
    }
}

test "unsupported tool call returns a tool result instead of aborting" {
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_unsupported"),
        .name = try std.testing.allocator.dupe(u8, "unknown_tool"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCall(std.testing.io, std.testing.allocator, call);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Tool unknown_tool is not implemented in pi-zig yet.", result);
}

const std = @import("std");
const ai_client = @import("ai_client.zig");
const tools = @import("tools.zig");

pub const ToolStartCallback = *const fn (ctx: *anyopaque, call: ai_client.ChatToolCall) anyerror!void;
pub const ToolEndCallback = *const fn (ctx: *anyopaque, result: ToolResult) anyerror!void;
pub const TextDeltaCallback = ai_client.StreamTextCallback;
pub const BeforeToolCallCallback = *const fn (ctx: *anyopaque, call: ai_client.ChatToolCall) anyerror!BeforeToolCallResult;
pub const AfterToolCallCallback = *const fn (ctx: *anyopaque, call: ai_client.ChatToolCall, result: ToolResult) anyerror!AfterToolCallResult;
pub const PrepareNextTurnCallback = *const fn (ctx: *anyopaque, turn: TurnContext) anyerror!PrepareNextTurnResult;
pub const ShouldStopAfterTurnCallback = *const fn (ctx: *anyopaque, turn: TurnContext) anyerror!bool;

pub const RunOptions = struct {
    provider: []const u8,
    model: []const u8,
    api_key: []const u8,
    prompt: []const u8,
    system_prompt: ?[]const u8 = null,
    history: []const ai_client.ChatMessage = &.{},
    max_turns: usize = 8,
    tool_set: ToolSet = .all,
    stream_turns: bool = false,
    tool_event_context: ?*anyopaque = null,
    on_tool_start: ?ToolStartCallback = null,
    on_tool_end: ?ToolEndCallback = null,
    tool_hook_context: ?*anyopaque = null,
    before_tool_call: ?BeforeToolCallCallback = null,
    after_tool_call: ?AfterToolCallCallback = null,
    turn_lifecycle_context: ?*anyopaque = null,
    prepare_next_turn: ?PrepareNextTurnCallback = null,
    should_stop_after_turn: ?ShouldStopAfterTurnCallback = null,
    text_event_context: ?*anyopaque = null,
    on_text_delta: ?TextDeltaCallback = null,
};

pub const BeforeToolCallResult = struct {
    block: bool = false,
    reason: ?[]u8 = null,
    arguments_json: ?[]u8 = null,

    pub fn deinit(self: BeforeToolCallResult, allocator: std.mem.Allocator) void {
        if (self.reason) |reason| allocator.free(reason);
        if (self.arguments_json) |arguments_json| allocator.free(arguments_json);
    }
};

pub const AfterToolCallResult = struct {
    content: ?[]u8 = null,
    is_error: ?bool = null,
    terminate: ?bool = null,

    pub fn deinit(self: AfterToolCallResult, allocator: std.mem.Allocator) void {
        if (self.content) |content| allocator.free(content);
    }
};

pub const TurnContext = struct {
    turn_index: usize,
    assistant_text: []const u8,
    tool_results: []const ToolResult,
    system_prompt: []const u8,
    provider: []const u8,
    model: []const u8,
};

pub const PrepareNextTurnResult = struct {
    system_prompt: ?[]u8 = null,
    provider: ?[]u8 = null,
    model: ?[]u8 = null,
    api_key: ?[]u8 = null,

    pub fn deinit(self: PrepareNextTurnResult, allocator: std.mem.Allocator) void {
        if (self.system_prompt) |system_prompt| allocator.free(system_prompt);
        if (self.provider) |provider| allocator.free(provider);
        if (self.model) |model| allocator.free(model);
        if (self.api_key) |api_key| allocator.free(api_key);
    }
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
    tool_results: []ToolResult = &.{},
    tool_results_count: usize = 0,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.final_text);
        for (self.tool_results) |result| result.deinit(allocator);
        allocator.free(self.tool_results);
    }
};

pub const ToolResult = struct {
    tool_call_id: []u8,
    tool_name: []u8,
    arguments_json: []u8,
    content: []u8,
    is_error: bool = false,
    terminate: bool = false,

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        if (self.tool_call_id.len > 0) allocator.free(self.tool_call_id);
        if (self.tool_name.len > 0) allocator.free(self.tool_name);
        if (self.arguments_json.len > 0) allocator.free(self.arguments_json);
        if (self.content.len > 0) allocator.free(self.content);
    }
};

const ToolExecutionResult = struct {
    content: []u8,
    is_error: bool = false,
    terminate: bool = false,
    arguments_json: ?[]u8 = null,

    fn deinit(self: ToolExecutionResult, allocator: std.mem.Allocator) void {
        if (self.content.len > 0) allocator.free(self.content);
        if (self.arguments_json) |arguments_json| allocator.free(arguments_json);
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
    for (options.history) |message| {
        try messages.append(allocator, try cloneChatMessage(allocator, message));
    }
    try messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, options.prompt),
    });

    var tool_results_count: usize = 0;
    var tool_results: std.ArrayList(ToolResult) = .empty;
    errdefer {
        for (tool_results.items) |result| result.deinit(allocator);
        tool_results.deinit(allocator);
    }

    var tool_definitions_buf: [all_tool_definitions.len]ai_client.ChatToolDefinition = undefined;
    const tool_definitions = enabledToolDefinitions(options.tool_set, &tool_definitions_buf);
    var active_provider: ?[]u8 = null;
    defer if (active_provider) |provider| allocator.free(provider);
    var active_model: ?[]u8 = null;
    defer if (active_model) |model| allocator.free(model);
    var active_api_key: ?[]u8 = null;
    defer if (active_api_key) |api_key| allocator.free(api_key);
    var turn: usize = 0;
    while (turn < options.max_turns) : (turn += 1) {
        const borrowed = try borrowMessages(allocator, messages.items);
        defer allocator.free(borrowed);

        const request: ai_client.ChatTurnRequest = .{
            .provider = active_provider orelse options.provider,
            .model = active_model orelse options.model,
            .api_key = active_api_key orelse options.api_key,
            .messages = borrowed,
            .tools = tool_definitions,
        };
        var response = if (options.stream_turns)
            try ai_client.streamChatTurnWithTextCallback(io, allocator, env, request, options.text_event_context, options.on_text_delta)
        else
            try ai_client.runChatTurn(io, allocator, env, request);
        defer response.deinit(allocator);

        if (response.tool_calls.len == 0) {
            const text = if (response.text) |value| value else try allocator.dupe(u8, "");
            response.text = null;
            return .{
                .final_text = text,
                .tool_results = try tool_results.toOwnedSlice(allocator),
                .tool_results_count = tool_results_count,
            };
        }

        try appendAssistantToolCallMessage(allocator, &messages, &response);
        const tool_calls = messages.items[messages.items.len - 1].tool_calls;
        response.tool_calls = &.{};

        var terminating_results: usize = 0;
        const batch_results_start = tool_results.items.len;
        for (tool_calls) |call| {
            if (options.on_tool_start) |callback| {
                if (options.tool_event_context) |context| try callback(context, call);
            }
            var tool_execution = try executeToolCallWithHooks(io, allocator, call, options);
            errdefer tool_execution.deinit(allocator);
            const tool_call_id = try allocator.dupe(u8, call.id);
            errdefer allocator.free(tool_call_id);
            const trace_call: ai_client.ChatToolCall = .{
                .id = call.id,
                .name = call.name,
                .arguments_json = tool_execution.arguments_json orelse call.arguments_json,
            };
            const traced_tool_result = try createToolResultTrace(allocator, trace_call, tool_execution.content, tool_execution.is_error, tool_execution.terminate);
            errdefer traced_tool_result.deinit(allocator);
            if (options.on_tool_end) |callback| {
                if (options.tool_event_context) |context| try callback(context, traced_tool_result);
            }
            try tool_results.append(allocator, traced_tool_result);
            try messages.append(allocator, .{
                .role = .tool,
                .content = tool_execution.content,
                .tool_call_id = tool_call_id,
            });
            tool_execution.content = &.{};
            if (tool_execution.arguments_json) |arguments_json| allocator.free(arguments_json);
            tool_execution.arguments_json = null;
            tool_results_count += 1;
            if (traced_tool_result.terminate) terminating_results += 1;
        }

        const should_stop = try finishTurnLifecycle(allocator, &messages, options, .{
            .turn_index = turn,
            .assistant_text = messages.items[messages.items.len - 1].content,
            .tool_results = tool_results.items[batch_results_start..],
            .system_prompt = currentSystemPrompt(messages.items),
            .provider = active_provider orelse options.provider,
            .model = active_model orelse options.model,
        }, &active_provider, &active_model, &active_api_key);
        if (should_stop) {
            return .{
                .final_text = try allocator.dupe(u8, ""),
                .tool_results = try tool_results.toOwnedSlice(allocator),
                .tool_results_count = tool_results_count,
            };
        }

        if (terminating_results == tool_calls.len) {
            return .{
                .final_text = try allocator.dupe(u8, ""),
                .tool_results = try tool_results.toOwnedSlice(allocator),
                .tool_results_count = tool_results_count,
            };
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

fn cloneChatMessage(allocator: std.mem.Allocator, message: ai_client.ChatMessage) !OwnedMessage {
    var owned = OwnedMessage{
        .role = message.role,
        .content = try allocator.dupe(u8, message.content),
        .tool_call_id = null,
        .tool_calls = &.{},
    };
    errdefer owned.deinit(allocator);
    if (message.tool_call_id) |tool_call_id| {
        owned.tool_call_id = try allocator.dupe(u8, tool_call_id);
    }
    if (message.tool_calls.len > 0) {
        owned.tool_calls = try cloneToolCalls(allocator, message.tool_calls);
    }
    return owned;
}

fn cloneToolCalls(allocator: std.mem.Allocator, tool_calls: []const ai_client.ChatToolCall) ![]ai_client.ChatToolCall {
    const cloned = try allocator.alloc(ai_client.ChatToolCall, tool_calls.len);
    var len: usize = 0;
    errdefer {
        for (cloned[0..len]) |call| call.deinit(allocator);
        allocator.free(cloned);
    }
    for (tool_calls) |call| {
        cloned[len] = .{
            .id = try allocator.dupe(u8, call.id),
            .name = try allocator.dupe(u8, call.name),
            .arguments_json = try allocator.dupe(u8, call.arguments_json),
        };
        len += 1;
    }
    return cloned;
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

fn finishTurnLifecycle(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(OwnedMessage),
    options: RunOptions,
    turn_context: TurnContext,
    active_provider: *?[]u8,
    active_model: *?[]u8,
    active_api_key: *?[]u8,
) !bool {
    if (options.prepare_next_turn) |callback| {
        if (options.turn_lifecycle_context) |context| {
            var update = try callback(context, turn_context);
            defer update.deinit(allocator);

            if (update.system_prompt) |system_prompt| {
                try applySystemPromptUpdate(allocator, messages, system_prompt);
                allocator.free(system_prompt);
                update.system_prompt = null;
            }
            if (update.provider) |provider| {
                replaceOwnedString(allocator, active_provider, provider);
                update.provider = null;
            }
            if (update.model) |model| {
                replaceOwnedString(allocator, active_model, model);
                update.model = null;
            }
            if (update.api_key) |api_key| {
                replaceOwnedString(allocator, active_api_key, api_key);
                update.api_key = null;
            }
        }
    }

    if (options.should_stop_after_turn) |callback| {
        if (options.turn_lifecycle_context) |context| {
            const updated_turn_context: TurnContext = .{
                .turn_index = turn_context.turn_index,
                .assistant_text = turn_context.assistant_text,
                .tool_results = turn_context.tool_results,
                .system_prompt = currentSystemPrompt(messages.items),
                .provider = active_provider.* orelse options.provider,
                .model = active_model.* orelse options.model,
            };
            return try callback(context, updated_turn_context);
        }
    }

    return false;
}

fn applySystemPromptUpdate(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(OwnedMessage),
    system_prompt: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, system_prompt, " \t\r\n");
    if (messages.items.len > 0 and messages.items[0].role == .system) {
        allocator.free(messages.items[0].content);
        messages.items[0].content = try allocator.dupe(u8, trimmed);
        return;
    }
    try messages.insert(allocator, 0, .{
        .role = .system,
        .content = try allocator.dupe(u8, trimmed),
    });
}

fn currentSystemPrompt(messages: []const OwnedMessage) []const u8 {
    if (messages.len > 0 and messages[0].role == .system) return messages[0].content;
    return "";
}

fn replaceOwnedString(allocator: std.mem.Allocator, target: *?[]u8, value: []u8) void {
    if (target.*) |previous| allocator.free(previous);
    target.* = value;
}

fn createToolResultTrace(
    allocator: std.mem.Allocator,
    call: ai_client.ChatToolCall,
    content: []const u8,
    is_error: bool,
    terminate: bool,
) !ToolResult {
    var result: ToolResult = .{
        .tool_call_id = try allocator.dupe(u8, call.id),
        .tool_name = &.{},
        .arguments_json = &.{},
        .content = &.{},
        .is_error = is_error,
        .terminate = terminate,
    };
    errdefer result.deinit(allocator);
    result.tool_name = try allocator.dupe(u8, call.name);
    result.arguments_json = try allocator.dupe(u8, call.arguments_json);
    result.content = try allocator.dupe(u8, content);
    return result;
}

fn executeToolCallWithHooks(
    io: std.Io,
    allocator: std.mem.Allocator,
    call: ai_client.ChatToolCall,
    options: RunOptions,
) !ToolExecutionResult {
    if (!isImplementedTool(call.name)) return executeToolCall(io, allocator, call);

    var effective_call = call;
    var overridden_arguments_json: ?[]u8 = null;
    errdefer if (overridden_arguments_json) |arguments_json| allocator.free(arguments_json);

    if (options.before_tool_call) |callback| {
        if (options.tool_hook_context) |context| {
            var before_result = callback(context, call) catch |err| {
                return toolError(try std.fmt.allocPrint(allocator, "beforeToolCall failed: {s}", .{@errorName(err)}));
            };
            defer before_result.deinit(allocator);

            if (before_result.block) {
                const reason = before_result.reason orelse "Tool execution was blocked";
                return toolError(try allocator.dupe(u8, reason));
            }

            if (before_result.arguments_json) |arguments_json| {
                effective_call.arguments_json = arguments_json;
                overridden_arguments_json = arguments_json;
                before_result.arguments_json = null;
            }
        }
    }

    var result = try executeToolCall(io, allocator, effective_call);
    errdefer result.deinit(allocator);

    if (options.after_tool_call) |callback| {
        if (options.tool_hook_context) |context| {
            const provisional_result: ToolResult = .{
                .tool_call_id = effective_call.id,
                .tool_name = effective_call.name,
                .arguments_json = effective_call.arguments_json,
                .content = result.content,
                .is_error = result.is_error,
                .terminate = result.terminate,
            };
            var after_result = callback(context, effective_call, provisional_result) catch |err| {
                allocator.free(result.content);
                result.content = try std.fmt.allocPrint(allocator, "afterToolCall failed: {s}", .{@errorName(err)});
                result.is_error = true;
                result.terminate = false;
                result.arguments_json = overridden_arguments_json;
                overridden_arguments_json = null;
                return result;
            };
            defer after_result.deinit(allocator);

            if (after_result.content) |content| {
                allocator.free(result.content);
                result.content = content;
                after_result.content = null;
            }
            if (after_result.is_error) |is_error| result.is_error = is_error;
            if (after_result.terminate) |terminate| result.terminate = terminate;
        }
    }

    result.arguments_json = overridden_arguments_json;
    overridden_arguments_json = null;
    return result;
}

fn executeToolCall(
    io: std.Io,
    allocator: std.mem.Allocator,
    call: ai_client.ChatToolCall,
) !ToolExecutionResult {
    if (std.mem.eql(u8, call.name, "read")) return executeReadTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "bash")) return executeBashTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "edit")) return executeEditTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "write")) return executeWriteTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "grep")) return executeGrepTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "find")) return executeFindTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "ls")) return executeLsTool(io, allocator, call.arguments_json);
    return toolError(try std.fmt.allocPrint(allocator, "Tool {s} is not implemented in pi-zig yet.", .{call.name}));
}

fn isImplementedTool(name: []const u8) bool {
    if (std.mem.eql(u8, name, "read")) return true;
    if (std.mem.eql(u8, name, "bash")) return true;
    if (std.mem.eql(u8, name, "edit")) return true;
    if (std.mem.eql(u8, name, "write")) return true;
    if (std.mem.eql(u8, name, "grep")) return true;
    if (std.mem.eql(u8, name, "find")) return true;
    if (std.mem.eql(u8, name, "ls")) return true;
    return false;
}

fn executeReadTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "read", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "read", err));
    defer parsed.deinit();
    const path = requiredString(parsed.value, "path") orelse return toolError(try allocator.dupe(u8, "read tool arguments are missing path."));
    const offset = optionalUsize(parsed.value, "offset") catch return toolError(try allocator.dupe(u8, "read tool offset must be a non-negative number."));
    const limit = optionalUsize(parsed.value, "limit") catch return toolError(try allocator.dupe(u8, "read tool limit must be a non-negative number."));
    const content = tools.readFileForToolText(io, allocator, path, offset, limit) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "read tool failed: {s}", .{@errorName(err)}));
    };
    return toolOk(content);
}

fn executeBashTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "bash", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "bash", err));
    defer parsed.deinit();

    if (parsed.value != .object) return toolError(try allocator.dupe(u8, "bash tool arguments must be a JSON object."));
    const command = requiredString(parsed.value, "command") orelse return toolError(try allocator.dupe(u8, "bash tool arguments are missing command."));

    const shell_result = tools.runShellCapture(io, allocator, command) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "bash tool failed before execution: {s}", .{@errorName(err)}));
    };
    defer allocator.free(shell_result.output);

    return .{
        .content = try allocator.dupe(u8, shell_result.output),
        .is_error = shell_result.exit_code == null or shell_result.exit_code.? != 0,
    };
}

fn executeEditTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "edit", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "edit", err));
    defer parsed.deinit();
    const path = requiredString(parsed.value, "path") orelse return toolError(try allocator.dupe(u8, "edit tool arguments are missing path."));
    const edits_value = fieldValue(parsed.value, "edits") orelse return toolError(try allocator.dupe(u8, "edit tool arguments are missing edits."));
    if (edits_value != .array) return toolError(try allocator.dupe(u8, "edit tool edits must be an array."));

    var edit_replacements: std.ArrayList(tools.EditReplacement) = .empty;
    defer edit_replacements.deinit(allocator);
    for (edits_value.array.items) |edit_value| {
        if (edit_value != .object) return toolError(try allocator.dupe(u8, "edit tool edits entries must be objects."));
        const old_text = requiredString(edit_value, "oldText") orelse return toolError(try allocator.dupe(u8, "edit tool edit is missing oldText."));
        const new_text = requiredString(edit_value, "newText") orelse return toolError(try allocator.dupe(u8, "edit tool edit is missing newText."));
        try edit_replacements.append(allocator, .{ .old_text = old_text, .new_text = new_text });
    }
    const content = tools.editFileManyText(io, allocator, path, edit_replacements.items) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "edit tool failed: {s}", .{@errorName(err)}));
    };
    return toolOk(content);
}

fn executeWriteTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "write", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "write", err));
    defer parsed.deinit();
    const path = requiredString(parsed.value, "path") orelse return toolError(try allocator.dupe(u8, "write tool arguments are missing path."));
    const content = requiredString(parsed.value, "content") orelse return toolError(try allocator.dupe(u8, "write tool arguments are missing content."));
    const output = tools.writeFileForToolText(io, allocator, path, content) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "write tool failed: {s}", .{@errorName(err)}));
    };
    return toolOk(output);
}

fn executeGrepTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "grep", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "grep", err));
    defer parsed.deinit();
    const pattern = requiredString(parsed.value, "pattern") orelse return toolError(try allocator.dupe(u8, "grep tool arguments are missing pattern."));
    const path = optionalString(parsed.value, "path") orelse ".";
    const options: tools.GrepOptions = .{
        .glob = optionalString(parsed.value, "glob"),
        .ignore_case = optionalBool(parsed.value, "ignoreCase") catch return toolError(try allocator.dupe(u8, "grep tool ignoreCase must be a boolean.")),
        .literal = optionalBool(parsed.value, "literal") catch return toolError(try allocator.dupe(u8, "grep tool literal must be a boolean.")),
        .context = (optionalUsize(parsed.value, "context") catch return toolError(try allocator.dupe(u8, "grep tool context must be a non-negative number."))) orelse 0,
        .limit = (optionalUsize(parsed.value, "limit") catch return toolError(try allocator.dupe(u8, "grep tool limit must be a non-negative number."))) orelse 100,
    };
    const content = tools.grepText(io, allocator, pattern, path, options) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "grep tool failed: {s}", .{@errorName(err)}));
    };
    return toolOk(content);
}

fn executeFindTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "find", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "find", err));
    defer parsed.deinit();
    const pattern = requiredString(parsed.value, "pattern") orelse return toolError(try allocator.dupe(u8, "find tool arguments are missing pattern."));
    const path = optionalString(parsed.value, "path") orelse ".";
    const limit = (optionalUsize(parsed.value, "limit") catch return toolError(try allocator.dupe(u8, "find tool limit must be a non-negative number."))) orelse 1000;
    const content = tools.findFilesText(io, allocator, pattern, path, limit) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "find tool failed: {s}", .{@errorName(err)}));
    };
    return toolOk(content);
}

fn executeLsTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "ls", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "ls", err));
    defer parsed.deinit();
    const path = optionalString(parsed.value, "path") orelse ".";
    const limit = (optionalUsize(parsed.value, "limit") catch return toolError(try allocator.dupe(u8, "ls tool limit must be a non-negative number."))) orelse 500;
    const content = tools.listDirText(io, allocator, path, limit) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "ls tool failed: {s}", .{@errorName(err)}));
    };
    return toolOk(content);
}

fn parseArguments(allocator: std.mem.Allocator, tool_name: []const u8, arguments_json: []const u8) !std.json.Parsed(std.json.Value) {
    _ = tool_name;
    return std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
}

fn invalidJsonMessage(allocator: std.mem.Allocator, tool_name: []const u8, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} tool argument JSON is invalid: {s}", .{ tool_name, @errorName(err) });
}

fn toolOk(content: []u8) ToolExecutionResult {
    return .{ .content = content };
}

fn toolError(content: []u8) ToolExecutionResult {
    return .{ .content = content, .is_error = true };
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
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("Tool unknown_tool is not implemented in pi-zig yet.", result.content);
}

test "failed tool calls are marked as errors" {
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_missing_read"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"path\":\"zig-out/does-not-exist-for-agent-test.txt\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCall(std.testing.io, std.testing.allocator, call);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "read tool failed:"));
}

test "before tool hook can block execution with an error result" {
    const HookContext = struct {
        allocator: std.mem.Allocator,
        before_calls: usize = 0,
        after_calls: usize = 0,
    };
    const Hooks = struct {
        fn before(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall) anyerror!BeforeToolCallResult {
            const ctx: *HookContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.before_calls += 1;
            try std.testing.expectEqualStrings("bash", call.name);
            return .{
                .block = true,
                .reason = try ctx.allocator.dupe(u8, "blocked by before hook"),
            };
        }

        fn after(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall, result: ToolResult) anyerror!AfterToolCallResult {
            _ = call;
            _ = result;
            const ctx: *HookContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.after_calls += 1;
            return .{};
        }
    };

    var ctx = HookContext{ .allocator = std.testing.allocator };
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_blocked"),
        .name = try std.testing.allocator.dupe(u8, "bash"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"command\":\"printf should-not-run\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithHooks(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .tool_hook_context = &ctx,
        .before_tool_call = Hooks.before,
        .after_tool_call = Hooks.after,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("blocked by before hook", result.content);
    try std.testing.expectEqual(@as(usize, 1), ctx.before_calls);
    try std.testing.expectEqual(@as(usize, 0), ctx.after_calls);
}

test "before tool hook can replace arguments before execution" {
    const HookContext = struct {
        allocator: std.mem.Allocator,
        before_calls: usize = 0,
    };
    const Hooks = struct {
        fn before(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall) anyerror!BeforeToolCallResult {
            const ctx: *HookContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.before_calls += 1;
            try std.testing.expectEqualStrings("read", call.name);
            return .{
                .arguments_json = try ctx.allocator.dupe(u8, "{\"path\":\"build.zig\",\"limit\":1}"),
            };
        }
    };

    var ctx = HookContext{ .allocator = std.testing.allocator };
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_rewrite_args"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"path\":\"zig-out/does-not-exist-for-agent-test.txt\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithHooks(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .tool_hook_context = &ctx,
        .before_tool_call = Hooks.before,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "const std") != null);
    try std.testing.expectEqualStrings("{\"path\":\"build.zig\",\"limit\":1}", result.arguments_json.?);
    try std.testing.expectEqual(@as(usize, 1), ctx.before_calls);
}

test "after tool hook can override content error state and termination" {
    const HookContext = struct {
        allocator: std.mem.Allocator,
        after_calls: usize = 0,
    };
    const Hooks = struct {
        fn after(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall, result: ToolResult) anyerror!AfterToolCallResult {
            const ctx: *HookContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.after_calls += 1;
            try std.testing.expectEqualStrings("read", call.name);
            try std.testing.expect(result.is_error);
            try std.testing.expect(std.mem.startsWith(u8, result.content, "read tool failed:"));
            return .{
                .content = try ctx.allocator.dupe(u8, "patched by after hook"),
                .is_error = false,
                .terminate = true,
            };
        }
    };

    var ctx = HookContext{ .allocator = std.testing.allocator };
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_after_patch"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"path\":\"zig-out/does-not-exist-for-agent-test.txt\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithHooks(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .tool_hook_context = &ctx,
        .after_tool_call = Hooks.after,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.terminate);
    try std.testing.expectEqualStrings("patched by after hook", result.content);
    try std.testing.expectEqual(@as(usize, 1), ctx.after_calls);
}

test "prepare next turn can update request state before should-stop runs" {
    const LifecycleContext = struct {
        allocator: std.mem.Allocator,
        prepare_calls: usize = 0,
        stop_calls: usize = 0,
    };
    const Hooks = struct {
        fn prepare(ctx_ptr: *anyopaque, turn: TurnContext) anyerror!PrepareNextTurnResult {
            const ctx: *LifecycleContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.prepare_calls += 1;
            try std.testing.expectEqual(@as(usize, 3), turn.turn_index);
            try std.testing.expectEqualStrings("first system", turn.system_prompt);
            try std.testing.expectEqualStrings("openai", turn.provider);
            try std.testing.expectEqualStrings("first-model", turn.model);
            return .{
                .system_prompt = try ctx.allocator.dupe(u8, "second system"),
                .provider = try ctx.allocator.dupe(u8, "openrouter"),
                .model = try ctx.allocator.dupe(u8, "second-model"),
                .api_key = try ctx.allocator.dupe(u8, "second-key"),
            };
        }

        fn shouldStop(ctx_ptr: *anyopaque, turn: TurnContext) anyerror!bool {
            const ctx: *LifecycleContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.stop_calls += 1;
            try std.testing.expectEqualStrings("second system", turn.system_prompt);
            try std.testing.expectEqualStrings("openrouter", turn.provider);
            try std.testing.expectEqualStrings("second-model", turn.model);
            try std.testing.expectEqualStrings("assistant asked for a tool", turn.assistant_text);
            try std.testing.expectEqual(@as(usize, 1), turn.tool_results.len);
            try std.testing.expectEqualStrings("call_lifecycle", turn.tool_results[0].tool_call_id);
            return true;
        }
    };

    var messages: std.ArrayList(OwnedMessage) = .empty;
    defer {
        for (messages.items) |message| message.deinit(std.testing.allocator);
        messages.deinit(std.testing.allocator);
    }
    try messages.append(std.testing.allocator, .{
        .role = .system,
        .content = try std.testing.allocator.dupe(u8, "first system"),
    });
    try messages.append(std.testing.allocator, .{
        .role = .assistant,
        .content = try std.testing.allocator.dupe(u8, "assistant asked for a tool"),
    });

    var tool_results = [_]ToolResult{.{
        .tool_call_id = try std.testing.allocator.dupe(u8, "call_lifecycle"),
        .tool_name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{}"),
        .content = try std.testing.allocator.dupe(u8, "ok"),
    }};
    defer tool_results[0].deinit(std.testing.allocator);
    var lifecycle = LifecycleContext{ .allocator = std.testing.allocator };
    var active_provider: ?[]u8 = null;
    defer if (active_provider) |provider| std.testing.allocator.free(provider);
    var active_model: ?[]u8 = null;
    defer if (active_model) |model| std.testing.allocator.free(model);
    var active_api_key: ?[]u8 = null;
    defer if (active_api_key) |api_key| std.testing.allocator.free(api_key);

    const should_stop = try finishTurnLifecycle(std.testing.allocator, &messages, .{
        .provider = "openai",
        .model = "first-model",
        .api_key = "first-key",
        .prompt = "",
        .turn_lifecycle_context = &lifecycle,
        .prepare_next_turn = Hooks.prepare,
        .should_stop_after_turn = Hooks.shouldStop,
    }, .{
        .turn_index = 3,
        .assistant_text = messages.items[1].content,
        .tool_results = &tool_results,
        .system_prompt = currentSystemPrompt(messages.items),
        .provider = "openai",
        .model = "first-model",
    }, &active_provider, &active_model, &active_api_key);

    try std.testing.expect(should_stop);
    try std.testing.expectEqual(@as(usize, 1), lifecycle.prepare_calls);
    try std.testing.expectEqual(@as(usize, 1), lifecycle.stop_calls);
    try std.testing.expectEqualStrings("second system", messages.items[0].content);
    try std.testing.expectEqualStrings("openrouter", active_provider.?);
    try std.testing.expectEqualStrings("second-model", active_model.?);
    try std.testing.expectEqualStrings("second-key", active_api_key.?);
}

test "prepare next turn inserts a system prompt when the transcript has none" {
    var messages: std.ArrayList(OwnedMessage) = .empty;
    defer {
        for (messages.items) |message| message.deinit(std.testing.allocator);
        messages.deinit(std.testing.allocator);
    }
    try messages.append(std.testing.allocator, .{
        .role = .user,
        .content = try std.testing.allocator.dupe(u8, "hello"),
    });

    try applySystemPromptUpdate(std.testing.allocator, &messages, " inserted system ");

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expect(messages.items[0].role == .system);
    try std.testing.expect(messages.items[1].role == .user);
    try std.testing.expectEqualStrings("inserted system", messages.items[0].content);
}

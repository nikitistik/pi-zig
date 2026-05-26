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
    enable_bash_tool: bool = true,
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

const default_tool_definitions = [_]ai_client.ChatToolDefinition{
    .{
        .name = "bash",
        .description = "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to the same limits as pi-zig tool-bash.",
        .parameters_json = bash_parameters_json,
    },
};
const no_tool_definitions = [_]ai_client.ChatToolDefinition{};

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
    const tool_definitions = if (options.enable_bash_tool) &default_tool_definitions else &no_tool_definitions;
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
    if (std.mem.eql(u8, call.name, "bash")) return executeBashTool(io, allocator, call.arguments_json);
    return std.fmt.allocPrint(allocator, "Tool {s} is not implemented in pi-zig yet.", .{call.name});
}

fn executeBashTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "bash tool argument JSON is invalid: {s}", .{@errorName(err)});
    };
    defer parsed.deinit();

    if (parsed.value != .object) return allocator.dupe(u8, "bash tool arguments must be a JSON object.");
    const command_value = parsed.value.object.get("command") orelse return allocator.dupe(u8, "bash tool arguments are missing command.");
    if (command_value != .string) return allocator.dupe(u8, "bash tool command must be a string.");

    const shell_result = tools.runShellCapture(io, allocator, command_value.string) catch |err| {
        return std.fmt.allocPrint(allocator, "bash tool failed before execution: {s}", .{@errorName(err)});
    };
    defer allocator.free(shell_result.output);

    return allocator.dupe(u8, shell_result.output);
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

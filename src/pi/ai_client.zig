const std = @import("std");
const config = @import("config.zig");

pub const ChatCompletionRequest = struct {
    provider: []const u8,
    model: []const u8,
    api_key: []const u8,
    prompt: []const u8,
    system_prompt: ?[]const u8 = null,
};

pub const ChatRole = enum {
    system,
    user,
    assistant,
    tool,

    fn label(self: ChatRole) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

pub const ChatToolCall = struct {
    id: []u8,
    name: []u8,
    arguments_json: []u8,

    pub fn deinit(self: ChatToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments_json);
    }
};

pub const ChatMessage = struct {
    role: ChatRole,
    content: []const u8 = "",
    tool_call_id: ?[]const u8 = null,
    tool_calls: []const ChatToolCall = &.{},
};

pub const ChatToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const ChatTurnRequest = struct {
    provider: []const u8,
    model: []const u8,
    api_key: []const u8,
    messages: []const ChatMessage,
    tools: []const ChatToolDefinition = &.{},
};

pub const ChatCompletionResult = struct {
    text: ?[]u8 = null,
    tool_calls: []ChatToolCall = &.{},

    pub fn deinit(self: ChatCompletionResult, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        for (self.tool_calls) |call| call.deinit(allocator);
        allocator.free(self.tool_calls);
    }
};

pub const ChatCompletionError = error{
    UnsupportedProvider,
    ProviderRequestFailed,
    ProviderResponseInvalid,
    EmptyPrompt,
} || std.mem.Allocator.Error || std.http.Client.FetchError;

pub fn runChatCompletion(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatCompletionRequest,
) ChatCompletionError![]u8 {
    if (std.mem.trim(u8, request.prompt, " \t\r\n").len == 0) return error.EmptyPrompt;

    var messages_buf: [2]ChatMessage = undefined;
    var messages_len: usize = 0;
    if (request.system_prompt) |system_prompt| {
        const trimmed_system = std.mem.trim(u8, system_prompt, " \t\r\n");
        if (trimmed_system.len > 0) {
            messages_buf[messages_len] = .{ .role = .system, .content = trimmed_system };
            messages_len += 1;
        }
    }
    messages_buf[messages_len] = .{ .role = .user, .content = request.prompt };
    messages_len += 1;

    var result = try runChatTurn(io, allocator, env, .{
        .provider = request.provider,
        .model = request.model,
        .api_key = request.api_key,
        .messages = messages_buf[0..messages_len],
    });
    defer result.deinit(allocator);

    const text = result.text orelse return error.ProviderResponseInvalid;
    result.text = null;
    return text;
}

pub fn runChatTurn(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
) ChatCompletionError!ChatCompletionResult {
    const endpoint = try endpointForProvider(allocator, env, request.provider);
    defer allocator.free(endpoint);

    const payload = try buildPayload(allocator, request);
    defer allocator.free(payload);

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{request.api_key});
    defer allocator.free(authorization);
    const user_agent = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.app_name, config.version });
    defer allocator.free(user_agent);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .response_writer = &response_body.writer,
        .headers = .{
            .authorization = .{ .override = authorization },
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = user_agent },
        },
    });

    const body = response_body.written();
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.ProviderRequestFailed;
    }

    return parseOpenAICompatibleResult(allocator, body);
}

fn endpointForProvider(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, provider: []const u8) ![]u8 {
    if (env.get("PI_ZIG_PROVIDER_BASE_URL")) |base_url| {
        return endpointFromBaseUrl(allocator, base_url);
    }
    if (std.mem.eql(u8, provider, "openai")) return allocator.dupe(u8, "https://api.openai.com/v1/chat/completions");
    if (std.mem.eql(u8, provider, "openrouter")) return allocator.dupe(u8, "https://openrouter.ai/api/v1/chat/completions");
    if (std.mem.eql(u8, provider, "groq")) return allocator.dupe(u8, "https://api.groq.com/openai/v1/chat/completions");
    if (std.mem.eql(u8, provider, "deepseek")) return allocator.dupe(u8, "https://api.deepseek.com/chat/completions");
    if (std.mem.eql(u8, provider, "xai")) return allocator.dupe(u8, "https://api.x.ai/v1/chat/completions");
    if (std.mem.eql(u8, provider, "together")) return allocator.dupe(u8, "https://api.together.xyz/v1/chat/completions");
    return error.UnsupportedProvider;
}

fn endpointFromBaseUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') end -= 1;
    const trimmed = base_url[0..end];
    if (std.mem.endsWith(u8, trimmed, "/chat/completions")) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}/chat/completions", .{trimmed});
}

fn buildPayload(allocator: std.mem.Allocator, request: ChatTurnRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"model\":");
    try writeJsonString(w, request.model);
    try w.writeAll(",\"messages\":[");
    for (request.messages, 0..) |message, index| {
        if (index != 0) try w.writeByte(',');
        try writeMessage(w, message);
    }
    try w.writeAll("],\"stream\":false");
    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (request.tools, 0..) |tool, index| {
            if (index != 0) try w.writeByte(',');
            try writeToolDefinition(w, tool);
        }
        try w.writeAll("],\"tool_choice\":\"auto\"");
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

fn writeMessage(w: *std.Io.Writer, message: ChatMessage) !void {
    try w.writeAll("{\"role\":");
    try writeJsonString(w, message.role.label());
    if (message.role == .assistant and message.tool_calls.len > 0) {
        try w.writeAll(",\"content\":");
        if (message.content.len > 0) {
            try writeJsonString(w, message.content);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"tool_calls\":[");
        for (message.tool_calls, 0..) |call, index| {
            if (index != 0) try w.writeByte(',');
            try writeToolCall(w, call);
        }
        try w.writeByte(']');
    } else {
        if (message.role == .tool) {
            if (message.tool_call_id) |tool_call_id| {
                try w.writeAll(",\"tool_call_id\":");
                try writeJsonString(w, tool_call_id);
            }
        }
        try w.writeAll(",\"content\":");
        try writeJsonString(w, message.content);
    }
    try w.writeByte('}');
}

fn writeToolDefinition(w: *std.Io.Writer, tool: ChatToolDefinition) !void {
    try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try writeJsonString(w, tool.name);
    try w.writeAll(",\"description\":");
    try writeJsonString(w, tool.description);
    try w.writeAll(",\"parameters\":");
    try w.writeAll(tool.parameters_json);
    try w.writeAll("}}");
}

fn writeToolCall(w: *std.Io.Writer, call: ChatToolCall) !void {
    try w.writeAll("{\"id\":");
    try writeJsonString(w, call.id);
    try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
    try writeJsonString(w, call.name);
    try w.writeAll(",\"arguments\":");
    try writeJsonString(w, call.arguments_json);
    try w.writeAll("}}");
}

fn parseOpenAICompatibleText(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var result = try parseOpenAICompatibleResult(allocator, body);
    defer result.deinit(allocator);
    const text = result.text orelse return error.ProviderResponseInvalid;
    result.text = null;
    return text;
}

fn parseOpenAICompatibleResult(allocator: std.mem.Allocator, body: []const u8) !ChatCompletionResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderResponseInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ProviderResponseInvalid;

    var result: ChatCompletionResult = .{};
    errdefer result.deinit(allocator);

    if (parsed.value.object.get("choices")) |choices| {
        if (choices != .array or choices.array.items.len == 0) return error.ProviderResponseInvalid;
        const first = choices.array.items[0];
        if (first != .object) return error.ProviderResponseInvalid;
        const message = first.object.get("message") orelse return error.ProviderResponseInvalid;
        if (message != .object) return error.ProviderResponseInvalid;
        if (message.object.get("content")) |content| {
            switch (content) {
                .string => result.text = try allocator.dupe(u8, content.string),
                .array => result.text = try parseContentParts(allocator, content.array.items),
                .null => {},
                else => return error.ProviderResponseInvalid,
            }
        }
        if (message.object.get("tool_calls")) |tool_calls| {
            result.tool_calls = try parseToolCalls(allocator, tool_calls);
        }
        if (result.text == null and result.tool_calls.len == 0) return error.ProviderResponseInvalid;
        return result;
    }

    if (parsed.value.object.get("output_text")) |output_text| {
        if (output_text == .string) {
            result.text = try allocator.dupe(u8, output_text.string);
            return result;
        }
    }

    return error.ProviderResponseInvalid;
}

fn parseToolCalls(allocator: std.mem.Allocator, value: std.json.Value) ![]ChatToolCall {
    if (value != .array) return error.ProviderResponseInvalid;
    var calls: std.ArrayList(ChatToolCall) = .empty;
    errdefer {
        for (calls.items) |call| call.deinit(allocator);
        calls.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .object) return error.ProviderResponseInvalid;
        const id = item.object.get("id") orelse return error.ProviderResponseInvalid;
        if (id != .string) return error.ProviderResponseInvalid;
        const function = item.object.get("function") orelse return error.ProviderResponseInvalid;
        if (function != .object) return error.ProviderResponseInvalid;
        const name = function.object.get("name") orelse return error.ProviderResponseInvalid;
        if (name != .string) return error.ProviderResponseInvalid;
        const arguments = function.object.get("arguments") orelse return error.ProviderResponseInvalid;
        if (arguments != .string) return error.ProviderResponseInvalid;

        try calls.append(allocator, .{
            .id = try allocator.dupe(u8, id.string),
            .name = try allocator.dupe(u8, name.string),
            .arguments_json = try allocator.dupe(u8, arguments.string),
        });
    }

    return calls.toOwnedSlice(allocator);
}

fn parseContentParts(allocator: std.mem.Allocator, parts: []const std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (parts) |part| {
        if (part != .object) continue;
        const text = part.object.get("text") orelse continue;
        if (text != .string) continue;
        if (out.written().len != 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(text.string);
    }
    if (out.written().len == 0) return error.ProviderResponseInvalid;
    return out.toOwnedSlice();
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.encodeJsonString(value, .{}, w);
}

test "parses OpenAI-compatible chat completion text" {
    const body =
        \\{"choices":[{"message":{"content":"hello from provider"}}]}
    ;
    const text = try parseOpenAICompatibleText(std.testing.allocator, body);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello from provider", text);
}

test "parses OpenAI-compatible tool calls" {
    const body =
        \\{"choices":[{"message":{"content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"printf ok\"}"}}]}}]}
    ;
    const result = try parseOpenAICompatibleResult(std.testing.allocator, body);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.text == null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf ok\"}", result.tool_calls[0].arguments_json);
}

test "provider base URL appends chat completions endpoint" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43123/v1/");
    const endpoint = try endpointForProvider(std.testing.allocator, &env, "openai");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/chat/completions", endpoint);
}

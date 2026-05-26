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

pub const ChatImageContent = struct {
    data: []const u8,
    mime_type: []const u8,
};

pub const ChatContentPart = union(enum) {
    text: []const u8,
    image: ChatImageContent,
};

pub const ChatMessage = struct {
    role: ChatRole,
    content: []const u8 = "",
    content_parts: []const ChatContentPart = &.{},
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

pub const StreamTextCallback = *const fn (ctx: *anyopaque, delta: []const u8) anyerror!void;
const StreamDataCallback = *const fn (ctx: *anyopaque, data: []const u8) anyerror!void;

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

pub fn streamChatTurnText(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
    callback_context: *anyopaque,
    callback: StreamTextCallback,
) !void {
    var text_context = StreamTextContext{
        .allocator = allocator,
        .callback_context = callback_context,
        .callback = callback,
    };
    try streamChatTurnData(io, allocator, env, request, &text_context, handleStreamTextData);
}

pub fn streamChatTurn(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
) !ChatCompletionResult {
    return streamChatTurnWithTextCallback(io, allocator, env, request, null, null);
}

pub fn streamChatTurnWithTextCallback(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
    text_callback_context: ?*anyopaque,
    text_callback: ?StreamTextCallback,
) !ChatCompletionResult {
    var accumulator = StreamChatAccumulator.init(allocator);
    errdefer accumulator.deinit();
    var result_context = StreamResultContext{
        .allocator = allocator,
        .accumulator = &accumulator,
        .text_callback_context = text_callback_context,
        .text_callback = text_callback,
    };
    try streamChatTurnData(io, allocator, env, request, &result_context, handleStreamResultData);
    return try accumulator.toResult();
}

fn streamChatTurnData(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
) !void {
    const endpoint = try endpointForProvider(allocator, env, request.provider);
    defer allocator.free(endpoint);

    const payload = try buildPayloadWithStream(allocator, request, true);
    defer allocator.free(payload);

    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{request.api_key});
    defer allocator.free(authorization);
    const user_agent = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.app_name, config.version });
    defer allocator.free(user_agent);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const uri = try std.Uri.parse(endpoint);
    var request_handle = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = .{ .override = authorization },
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer request_handle.deinit();

    request_handle.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = try request_handle.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try request_handle.connection.?.flush();

    var response = try request_handle.receiveHead(&.{});
    if (@intFromEnum(response.head.status) < 200 or @intFromEnum(response.head.status) >= 300) {
        var transfer_buffer: [1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        _ = reader.discardRemaining() catch {};
        return error.ProviderRequestFailed;
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var saw_done = false;
    while (true) {
        const raw_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ProviderResponseInvalid,
            else => return err,
        };
        const line_with_cr = raw_line orelse break;
        const line = stripTrailingCarriageReturn(line_with_cr);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
        if (std.mem.eql(u8, data, "[DONE]")) {
            saw_done = true;
            break;
        }
        try callback(callback_context, data);
    }
    if (!saw_done) return error.ProviderResponseInvalid;
}

const StreamTextContext = struct {
    allocator: std.mem.Allocator,
    callback_context: *anyopaque,
    callback: StreamTextCallback,
};

fn handleStreamTextData(ctx_ptr: *anyopaque, data: []const u8) anyerror!void {
    const ctx: *StreamTextContext = @ptrCast(@alignCast(ctx_ptr));
    try parseOpenAICompatibleStreamData(ctx.allocator, data, ctx.callback_context, ctx.callback);
}

fn handleStreamResultData(ctx_ptr: *anyopaque, data: []const u8) anyerror!void {
    const ctx: *StreamResultContext = @ptrCast(@alignCast(ctx_ptr));
    try parseOpenAICompatibleStreamResultData(ctx.allocator, data, ctx.accumulator, ctx.text_callback_context, ctx.text_callback);
}

const StreamResultContext = struct {
    allocator: std.mem.Allocator,
    accumulator: *StreamChatAccumulator,
    text_callback_context: ?*anyopaque,
    text_callback: ?StreamTextCallback,
};

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
    return buildPayloadWithStream(allocator, request, false);
}

fn buildPayloadWithStream(allocator: std.mem.Allocator, request: ChatTurnRequest, stream: bool) ![]u8 {
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
    try w.writeAll("],\"stream\":");
    try w.writeAll(if (stream) "true" else "false");
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

fn parseOpenAICompatibleStreamData(
    allocator: std.mem.Allocator,
    data: []const u8,
    callback_context: *anyopaque,
    callback: StreamTextCallback,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return error.ProviderResponseInvalid;
    defer parsed.deinit();
    if (isResponseStreamEvent(parsed.value)) {
        if (try responseStreamTextDelta(parsed.value)) |delta| {
            if (delta.len > 0) try callback(callback_context, delta);
        }
        return;
    }
    const delta = try firstStreamDelta(parsed.value) orelse return;
    const content = delta.object.get("content") orelse return;
    if (content == .null) return;
    if (content != .string) return error.ProviderResponseInvalid;
    if (content.string.len > 0) try callback(callback_context, content.string);
}

fn parseOpenAICompatibleStreamResultData(
    allocator: std.mem.Allocator,
    data: []const u8,
    accumulator: *StreamChatAccumulator,
    text_callback_context: ?*anyopaque,
    text_callback: ?StreamTextCallback,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return error.ProviderResponseInvalid;
    defer parsed.deinit();
    if (isResponseStreamEvent(parsed.value)) {
        try accumulator.appendResponseStreamEvent(parsed.value, text_callback_context, text_callback);
        return;
    }
    const delta = try firstStreamDelta(parsed.value) orelse return;
    try accumulator.appendDelta(delta, text_callback_context, text_callback);
}

fn isResponseStreamEvent(value: std.json.Value) bool {
    if (value != .object) return false;
    const event_type = value.object.get("type") orelse return false;
    if (event_type != .string) return false;
    return std.mem.startsWith(u8, event_type.string, "response.");
}

fn responseStreamTextDelta(value: std.json.Value) !?[]const u8 {
    if (value != .object) return error.ProviderResponseInvalid;
    const event_type = value.object.get("type") orelse return null;
    if (event_type != .string) return error.ProviderResponseInvalid;
    if (!std.mem.eql(u8, event_type.string, "response.output_text.delta")) return null;
    const delta = value.object.get("delta") orelse return error.ProviderResponseInvalid;
    if (delta != .string) return error.ProviderResponseInvalid;
    return delta.string;
}

fn firstStreamDelta(value: std.json.Value) !?std.json.Value {
    if (value != .object) return error.ProviderResponseInvalid;
    const choices = value.object.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return error.ProviderResponseInvalid;
    const first = choices.array.items[0];
    if (first != .object) return error.ProviderResponseInvalid;
    const delta = first.object.get("delta") orelse return null;
    if (delta != .object) return error.ProviderResponseInvalid;
    return delta;
}

const StreamToolCallAccumulator = struct {
    id: std.Io.Writer.Allocating,
    name: std.Io.Writer.Allocating,
    arguments_json: std.Io.Writer.Allocating,
    seen: bool = false,

    fn init(allocator: std.mem.Allocator) StreamToolCallAccumulator {
        return .{
            .id = .init(allocator),
            .name = .init(allocator),
            .arguments_json = .init(allocator),
        };
    }

    fn deinit(self: *StreamToolCallAccumulator) void {
        self.id.deinit();
        self.name.deinit();
        self.arguments_json.deinit();
    }

    fn replaceArguments(self: *StreamToolCallAccumulator, allocator: std.mem.Allocator, arguments_json: []const u8) !void {
        self.arguments_json.deinit();
        self.arguments_json = .init(allocator);
        try self.arguments_json.writer.writeAll(arguments_json);
    }
};

const StreamChatAccumulator = struct {
    allocator: std.mem.Allocator,
    text: std.Io.Writer.Allocating,
    tool_calls: std.ArrayList(StreamToolCallAccumulator),
    response_tool_index: ?usize = null,

    fn init(allocator: std.mem.Allocator) StreamChatAccumulator {
        return .{
            .allocator = allocator,
            .text = .init(allocator),
            .tool_calls = .empty,
        };
    }

    fn deinit(self: *StreamChatAccumulator) void {
        self.text.deinit();
        for (self.tool_calls.items) |*call| call.deinit();
        self.tool_calls.deinit(self.allocator);
    }

    fn appendDelta(
        self: *StreamChatAccumulator,
        delta: std.json.Value,
        text_callback_context: ?*anyopaque,
        text_callback: ?StreamTextCallback,
    ) !void {
        const content = delta.object.get("content") orelse .null;
        if (content != .null) {
            if (content != .string) return error.ProviderResponseInvalid;
            try self.appendTextDelta(content.string, text_callback_context, text_callback);
        }

        if (delta.object.get("tool_calls")) |tool_calls| {
            try self.appendToolCallDeltas(tool_calls);
        }
    }

    fn appendResponseStreamEvent(
        self: *StreamChatAccumulator,
        value: std.json.Value,
        text_callback_context: ?*anyopaque,
        text_callback: ?StreamTextCallback,
    ) !void {
        const event_type = try requiredObjectString(value, "type");
        if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
            const delta = value.object.get("delta") orelse return error.ProviderResponseInvalid;
            if (delta != .string) return error.ProviderResponseInvalid;
            try self.appendTextDelta(delta.string, text_callback_context, text_callback);
            return;
        }
        if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const item = value.object.get("item") orelse return error.ProviderResponseInvalid;
            if (try isResponseFunctionCallItem(item)) try self.startResponseFunctionCall(item);
            return;
        }
        if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const index = self.response_tool_index orelse return;
            const delta = value.object.get("delta") orelse return error.ProviderResponseInvalid;
            if (delta != .string) return error.ProviderResponseInvalid;
            try self.tool_calls.items[index].arguments_json.writer.writeAll(delta.string);
            return;
        }
        if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            const index = self.response_tool_index orelse return;
            const arguments = value.object.get("arguments") orelse return error.ProviderResponseInvalid;
            if (arguments != .string) return error.ProviderResponseInvalid;
            try self.tool_calls.items[index].replaceArguments(self.allocator, arguments.string);
            return;
        }
        if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const item = value.object.get("item") orelse return error.ProviderResponseInvalid;
            if (try isResponseFunctionCallItem(item)) try self.finishResponseFunctionCall(item);
            return;
        }
    }

    fn appendTextDelta(
        self: *StreamChatAccumulator,
        delta: []const u8,
        text_callback_context: ?*anyopaque,
        text_callback: ?StreamTextCallback,
    ) !void {
        try self.text.writer.writeAll(delta);
        if (delta.len > 0) {
            if (text_callback) |callback| {
                if (text_callback_context) |context| try callback(context, delta);
            }
        }
    }

    fn appendToolCallDeltas(self: *StreamChatAccumulator, value: std.json.Value) !void {
        if (value != .array) return error.ProviderResponseInvalid;
        for (value.array.items) |item| {
            if (item != .object) return error.ProviderResponseInvalid;
            const index_value = item.object.get("index") orelse return error.ProviderResponseInvalid;
            const index = try streamToolCallIndex(index_value);
            const call = try self.ensureToolCall(index);
            call.seen = true;

            if (item.object.get("id")) |id| {
                if (id != .null) {
                    if (id != .string) return error.ProviderResponseInvalid;
                    try call.id.writer.writeAll(id.string);
                }
            }
            if (item.object.get("function")) |function| {
                if (function != .object) return error.ProviderResponseInvalid;
                if (function.object.get("name")) |name| {
                    if (name != .null) {
                        if (name != .string) return error.ProviderResponseInvalid;
                        try call.name.writer.writeAll(name.string);
                    }
                }
                if (function.object.get("arguments")) |arguments| {
                    if (arguments != .null) {
                        if (arguments != .string) return error.ProviderResponseInvalid;
                        try call.arguments_json.writer.writeAll(arguments.string);
                    }
                }
            }
        }
    }

    fn startResponseFunctionCall(self: *StreamChatAccumulator, item: std.json.Value) !void {
        const index = self.tool_calls.items.len;
        const call = try self.ensureToolCall(index);
        call.seen = true;
        self.response_tool_index = index;

        const call_id = try requiredObjectString(item, "call_id");
        const item_id = try requiredObjectString(item, "id");
        const compound_id = try std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ call_id, item_id });
        defer self.allocator.free(compound_id);
        try call.id.writer.writeAll(compound_id);
        try call.name.writer.writeAll(try requiredObjectString(item, "name"));
        if (try optionalObjectString(item, "arguments")) |arguments| {
            try call.arguments_json.writer.writeAll(arguments);
        }
    }

    fn finishResponseFunctionCall(self: *StreamChatAccumulator, item: std.json.Value) !void {
        const call = if (self.response_tool_index) |index|
            &self.tool_calls.items[index]
        else blk: {
            try self.startResponseFunctionCall(item);
            break :blk &self.tool_calls.items[self.response_tool_index.?];
        };
        if (try optionalObjectString(item, "arguments")) |arguments| {
            try call.replaceArguments(self.allocator, arguments);
        }
        self.response_tool_index = null;
    }

    fn ensureToolCall(self: *StreamChatAccumulator, index: usize) !*StreamToolCallAccumulator {
        while (self.tool_calls.items.len <= index) {
            try self.tool_calls.append(self.allocator, StreamToolCallAccumulator.init(self.allocator));
        }
        return &self.tool_calls.items[index];
    }

    fn toResult(self: *StreamChatAccumulator) !ChatCompletionResult {
        var result: ChatCompletionResult = .{};
        errdefer result.deinit(self.allocator);

        if (self.text.written().len > 0) {
            result.text = try self.text.toOwnedSlice();
            self.text = .init(self.allocator);
        }

        var seen_count: usize = 0;
        for (self.tool_calls.items) |call| {
            if (call.seen) seen_count += 1;
        }
        if (seen_count > 0) {
            const calls = try self.allocator.alloc(ChatToolCall, seen_count);
            var len: usize = 0;
            errdefer {
                for (calls[0..len]) |call| call.deinit(self.allocator);
                self.allocator.free(calls);
            }
            for (self.tool_calls.items) |*call| {
                if (!call.seen) continue;
                if (call.id.written().len == 0 or call.name.written().len == 0) {
                    return error.ProviderResponseInvalid;
                }
                var id: ?[]u8 = try call.id.toOwnedSlice();
                call.id = .init(self.allocator);
                errdefer if (id) |value| self.allocator.free(value);
                var name: ?[]u8 = try call.name.toOwnedSlice();
                call.name = .init(self.allocator);
                errdefer if (name) |value| self.allocator.free(value);
                var arguments_json: ?[]u8 = try call.arguments_json.toOwnedSlice();
                call.arguments_json = .init(self.allocator);
                errdefer if (arguments_json) |value| self.allocator.free(value);
                calls[len] = .{
                    .id = id.?,
                    .name = name.?,
                    .arguments_json = arguments_json.?,
                };
                id = null;
                name = null;
                arguments_json = null;
                len += 1;
            }
            result.tool_calls = calls;
        }

        if (result.text == null and result.tool_calls.len == 0) return error.ProviderResponseInvalid;
        self.tool_calls.deinit(self.allocator);
        self.tool_calls = .empty;
        return result;
    }
};

fn requiredObjectString(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.ProviderResponseInvalid;
    const field = value.object.get(key) orelse return error.ProviderResponseInvalid;
    if (field != .string) return error.ProviderResponseInvalid;
    return field.string;
}

fn optionalObjectString(value: std.json.Value, key: []const u8) !?[]const u8 {
    if (value != .object) return error.ProviderResponseInvalid;
    const field = value.object.get(key) orelse return null;
    if (field == .null) return null;
    if (field != .string) return error.ProviderResponseInvalid;
    return field.string;
}

fn isResponseFunctionCallItem(item: std.json.Value) !bool {
    if (item != .object) return error.ProviderResponseInvalid;
    const item_type = item.object.get("type") orelse return false;
    if (item_type != .string) return error.ProviderResponseInvalid;
    return std.mem.eql(u8, item_type.string, "function_call");
}

fn streamToolCallIndex(value: std.json.Value) !usize {
    return switch (value) {
        .integer => |integer| blk: {
            if (integer < 0) return error.ProviderResponseInvalid;
            break :blk @intCast(integer);
        },
        else => error.ProviderResponseInvalid,
    };
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
        if (message.content_parts.len > 0) {
            try writeContentParts(w, message.content_parts);
        } else {
            try writeJsonString(w, message.content);
        }
    }
    try w.writeByte('}');
}

fn writeContentParts(w: *std.Io.Writer, parts: []const ChatContentPart) !void {
    try w.writeByte('[');
    for (parts, 0..) |part, index| {
        if (index != 0) try w.writeByte(',');
        switch (part) {
            .text => |text| {
                try w.writeAll("{\"type\":\"text\",\"text\":");
                try writeJsonString(w, text);
                try w.writeByte('}');
            },
            .image => |image| {
                try w.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
                try writeJsonStringFragment(w, image.mime_type);
                try w.writeAll(";base64,");
                try writeJsonStringFragment(w, image.data);
                try w.writeAll("\"}}");
            },
        }
    }
    try w.writeByte(']');
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

fn writeJsonStringFragment(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                const hex = "0123456789abcdef";
                try w.writeAll("\\u00");
                try w.writeByte(hex[byte >> 4]);
                try w.writeByte(hex[byte & 0x0f]);
            },
            else => try w.writeByte(byte),
        }
    }
}

fn stripTrailingCarriageReturn(value: []const u8) []const u8 {
    if (value.len > 0 and value[value.len - 1] == '\r') return value[0 .. value.len - 1];
    return value;
}

test "parses OpenAI-compatible chat completion text" {
    const body =
        \\{"choices":[{"message":{"content":"hello from provider"}}]}
    ;
    const text = try parseOpenAICompatibleText(std.testing.allocator, body);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello from provider", text);
}

test "serializes OpenAI-compatible text and image content parts" {
    const parts = [_]ChatContentPart{
        .{ .text = "inspect this" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const messages = [_]ChatMessage{
        .{ .role = .user, .content_parts = parts[0..] },
    };
    const payload = try buildPayload(std.testing.allocator, .{
        .provider = "openai",
        .model = "mock-image-model",
        .api_key = "unused",
        .messages = messages[0..],
    });
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"content\":[{\"type\":\"text\",\"text\":\"inspect this\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,aGVsbG8=\"}}]") != null);
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

test "assembles streamed OpenAI-compatible tool call deltas" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_stream","type":"function","function":{"name":"bash","arguments":"{\"command\":\"printf "}}]}}]}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"stream-ok\"}"}}]}}]}
    , &accumulator, null, null);
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.text == null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_stream", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf stream-ok\"}", result.tool_calls[0].arguments_json);
}

test "assembles OpenAI Responses output text deltas" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"response.output_text.delta","delta":"response "}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"response.output_text.done","text":"response "}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"response.output_text.delta","delta":"delta"}
    , &accumulator, null, null);
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("response delta", result.text.?);
    try std.testing.expectEqual(@as(usize, 0), result.tool_calls.len);
}

test "assembles OpenAI Responses function call stream events" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"response.output_item.added","item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"bash","arguments":"{\"command\":\"printf "}}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"response.function_call_arguments.delta","delta":"response-"}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"response.function_call_arguments.done","arguments":"{\"command\":\"printf response-ok\"}"}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"response.output_item.done","item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"bash","arguments":"{\"command\":\"printf response-ok\"}"}}
    , &accumulator, null, null);
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.text == null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_1|item_1", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf response-ok\"}", result.tool_calls[0].arguments_json);
}

test "provider base URL appends chat completions endpoint" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43123/v1/");
    const endpoint = try endpointForProvider(std.testing.allocator, &env, "openai");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/chat/completions", endpoint);
}

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
    if (isAnthropicMessagesProvider(request.provider)) {
        return runAnthropicMessagesTurn(io, allocator, env, request);
    }
    if (isGoogleGenerativeProvider(request.provider)) {
        return runGoogleGenerateContentTurn(io, allocator, env, request);
    }
    if (isMistralProvider(request.provider)) {
        return runMistralChatTurn(io, allocator, env, request);
    }

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
    if (isAnthropicMessagesProvider(request.provider)) {
        return streamAnthropicMessagesData(io, allocator, env, request, callback_context, callback);
    }
    if (isGoogleGenerativeProvider(request.provider)) {
        return streamGoogleGenerateContentData(io, allocator, env, request, callback_context, callback);
    }
    if (isMistralProvider(request.provider)) {
        return streamMistralChatData(io, allocator, env, request, callback_context, callback);
    }

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
    try readDoneTerminatedSseStream(reader, callback_context, callback);
}

fn readDoneTerminatedSseStream(
    reader: *std.Io.Reader,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
) !void {
    var saw_done = false;
    while (true) {
        const raw_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ProviderResponseInvalid,
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

fn isAnthropicMessagesProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "anthropic");
}

fn isGoogleGenerativeProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "google");
}

fn isMistralProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "mistral");
}

fn runAnthropicMessagesTurn(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
) ChatCompletionError!ChatCompletionResult {
    const endpoint = try anthropicMessagesEndpointForProvider(allocator, env);
    defer allocator.free(endpoint);

    const payload = try buildAnthropicMessagesPayload(allocator, request, false);
    defer allocator.free(payload);

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    var auth_header = try anthropicAuthHeader(allocator, request.api_key);
    defer auth_header.deinit(allocator);
    const user_agent = if (auth_header.oauth) "claude-cli/2.1.75" else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.app_name, config.version });
    defer if (!auth_header.oauth) allocator.free(user_agent);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var extra_headers_buf: [5]std.http.Header = undefined;
    const extra_headers = anthropicExtraHeaders(&extra_headers_buf, request.api_key, auth_header.oauth);
    const result = try client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .response_writer = &response_body.writer,
        .headers = .{
            .authorization = if (auth_header.authorization) |value| .{ .override = value } else .default,
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = user_agent },
        },
        .extra_headers = extra_headers,
    });

    const body = response_body.written();
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.ProviderRequestFailed;
    }

    return parseAnthropicMessagesResult(allocator, body);
}

fn streamAnthropicMessagesData(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
) !void {
    const endpoint = try anthropicMessagesEndpointForProvider(allocator, env);
    defer allocator.free(endpoint);

    const payload = try buildAnthropicMessagesPayload(allocator, request, true);
    defer allocator.free(payload);

    var auth_header = try anthropicAuthHeader(allocator, request.api_key);
    defer auth_header.deinit(allocator);
    const user_agent = if (auth_header.oauth) "claude-cli/2.1.75" else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.app_name, config.version });
    defer if (!auth_header.oauth) allocator.free(user_agent);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const uri = try std.Uri.parse(endpoint);
    var extra_headers_buf: [5]std.http.Header = undefined;
    const extra_headers = anthropicExtraHeaders(&extra_headers_buf, request.api_key, auth_header.oauth);
    var request_handle = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = if (auth_header.authorization) |value| .{ .override = value } else .default,
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra_headers,
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
    try readAnthropicSseStream(allocator, reader, callback_context, callback);
}

fn runGoogleGenerateContentTurn(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
) ChatCompletionError!ChatCompletionResult {
    const endpoint = try googleGenerateContentEndpointForProvider(allocator, env, request.model, false);
    defer allocator.free(endpoint);

    const payload = try buildGoogleGenerateContentPayload(allocator, request);
    defer allocator.free(payload);

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const user_agent = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.app_name, config.version });
    defer allocator.free(user_agent);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const extra_headers = [_]std.http.Header{
        .{ .name = "x-goog-api-key", .value = request.api_key },
    };
    const result = try client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .response_writer = &response_body.writer,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = user_agent },
        },
        .extra_headers = &extra_headers,
    });

    const body = response_body.written();
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.ProviderRequestFailed;
    }

    return parseGoogleGenerateContentResult(allocator, body);
}

fn streamGoogleGenerateContentData(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
) !void {
    const endpoint = try googleGenerateContentEndpointForProvider(allocator, env, request.model, true);
    defer allocator.free(endpoint);

    const payload = try buildGoogleGenerateContentPayload(allocator, request);
    defer allocator.free(payload);

    const user_agent = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.app_name, config.version });
    defer allocator.free(user_agent);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const uri = try std.Uri.parse(endpoint);
    const extra_headers = [_]std.http.Header{
        .{ .name = "x-goog-api-key", .value = request.api_key },
    };
    var request_handle = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &extra_headers,
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
    try readGoogleSseStream(reader, callback_context, callback);
}

fn runMistralChatTurn(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
) ChatCompletionError!ChatCompletionResult {
    const endpoint = try mistralChatEndpointForProvider(allocator, env);
    defer allocator.free(endpoint);

    const payload = try buildMistralChatPayload(allocator, request, false);
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

fn streamMistralChatData(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
) !void {
    const endpoint = try mistralChatEndpointForProvider(allocator, env);
    defer allocator.free(endpoint);

    const payload = try buildMistralChatPayload(allocator, request, true);
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
    try readDoneTerminatedSseStream(reader, callback_context, callback);
}

const AnthropicAuthHeader = struct {
    authorization: ?[]u8 = null,
    oauth: bool = false,

    fn deinit(self: *AnthropicAuthHeader, allocator: std.mem.Allocator) void {
        if (self.authorization) |value| allocator.free(value);
    }
};

fn anthropicAuthHeader(allocator: std.mem.Allocator, api_key: []const u8) !AnthropicAuthHeader {
    if (std.mem.startsWith(u8, api_key, "sk-ant-oat")) {
        return .{
            .authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}),
            .oauth = true,
        };
    }
    return .{};
}

fn anthropicExtraHeaders(buf: *[5]std.http.Header, api_key: []const u8, oauth: bool) []const std.http.Header {
    var len: usize = 0;
    buf[len] = .{ .name = "anthropic-version", .value = "2023-06-01" };
    len += 1;
    if (oauth) {
        buf[len] = .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" };
        len += 1;
        buf[len] = .{ .name = "x-app", .value = "cli" };
        len += 1;
    } else {
        buf[len] = .{ .name = "x-api-key", .value = api_key };
        len += 1;
    }
    return buf[0..len];
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

fn anthropicMessagesEndpointForProvider(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("PI_ZIG_PROVIDER_BASE_URL")) |base_url| {
        return endpointFromBaseUrlWithPath(allocator, base_url, "/v1/messages");
    }
    return allocator.dupe(u8, "https://api.anthropic.com/v1/messages");
}

fn googleGenerateContentEndpointForProvider(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    model: []const u8,
    stream: bool,
) ![]u8 {
    const base_url = env.get("PI_ZIG_PROVIDER_BASE_URL") orelse "https://generativelanguage.googleapis.com/v1beta";
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') end -= 1;
    const trimmed = base_url[0..end];
    const action = if (stream) "streamGenerateContent?alt=sse" else "generateContent";
    return std.fmt.allocPrint(allocator, "{s}/models/{s}:{s}", .{ trimmed, model, action });
}

fn mistralChatEndpointForProvider(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const base_url = env.get("PI_ZIG_PROVIDER_BASE_URL") orelse "https://api.mistral.ai/v1";
    return endpointFromBaseUrlWithPath(allocator, base_url, "/chat/completions");
}

fn endpointFromBaseUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    return endpointFromBaseUrlWithPath(allocator, base_url, "/chat/completions");
}

fn endpointFromBaseUrlWithPath(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8) ![]u8 {
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') end -= 1;
    const trimmed = base_url[0..end];
    if (std.mem.endsWith(u8, trimmed, suffix)) return allocator.dupe(u8, trimmed);
    if (std.mem.startsWith(u8, suffix, "/v1/") and std.mem.endsWith(u8, trimmed, "/v1")) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, suffix["/v1".len..] });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, suffix });
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

fn buildAnthropicMessagesPayload(allocator: std.mem.Allocator, request: ChatTurnRequest, stream: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"model\":");
    try writeJsonString(w, request.model);
    try w.writeAll(",\"max_tokens\":4096");
    try w.writeAll(",\"stream\":");
    try w.writeAll(if (stream) "true" else "false");
    try writeAnthropicSystem(w, request.messages);
    try w.writeAll(",\"messages\":[");
    var emitted: usize = 0;
    var index: usize = 0;
    while (index < request.messages.len) {
        const message = request.messages[index];
        if (message.role == .system) {
            index += 1;
            continue;
        }
        if (emitted != 0) try w.writeByte(',');
        if (message.role == .tool) {
            try writeAnthropicToolResultMessage(w, request.messages, &index);
        } else {
            try writeAnthropicMessage(w, message);
            index += 1;
        }
        emitted += 1;
    }
    try w.writeByte(']');
    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (request.tools, 0..) |tool, tool_index| {
            if (tool_index != 0) try w.writeByte(',');
            try writeAnthropicToolDefinition(w, tool);
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

fn buildGoogleGenerateContentPayload(allocator: std.mem.Allocator, request: ChatTurnRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"contents\":[");
    var emitted: usize = 0;
    var index: usize = 0;
    while (index < request.messages.len) {
        const message = request.messages[index];
        if (message.role == .system) {
            index += 1;
            continue;
        }
        if (emitted != 0) try w.writeByte(',');
        if (message.role == .tool) {
            try writeGoogleToolResultContent(w, request.messages, &index);
        } else {
            try writeGoogleContent(w, message);
            index += 1;
        }
        emitted += 1;
    }
    try w.writeByte(']');
    try writeGoogleSystemInstruction(w, request.messages);
    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[{\"functionDeclarations\":[");
        for (request.tools, 0..) |tool, tool_index| {
            if (tool_index != 0) try w.writeByte(',');
            try writeGoogleToolDefinition(w, tool);
        }
        try w.writeAll("]}],\"toolConfig\":{\"functionCallingConfig\":{\"mode\":\"AUTO\"}}");
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

fn buildMistralChatPayload(allocator: std.mem.Allocator, request: ChatTurnRequest, stream: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"model\":");
    try writeJsonString(w, request.model);
    try w.writeAll(",\"stream\":");
    try w.writeAll(if (stream) "true" else "false");
    try w.writeAll(",\"messages\":[");
    for (request.messages, 0..) |message, index| {
        if (index != 0) try w.writeByte(',');
        try writeMistralMessage(w, request.messages, index, message);
    }
    try w.writeByte(']');
    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (request.tools, 0..) |tool, tool_index| {
            if (tool_index != 0) try w.writeByte(',');
            try writeMistralToolDefinition(w, tool);
        }
        try w.writeAll("],\"tool_choice\":\"auto\"");
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

fn writeAnthropicSystem(w: *std.Io.Writer, messages: []const ChatMessage) !void {
    var emitted: usize = 0;
    for (messages) |message| {
        if (message.role != .system or std.mem.trim(u8, message.content, " \t\r\n").len == 0) continue;
        if (emitted == 0) try w.writeAll(",\"system\":[") else try w.writeByte(',');
        try w.writeAll("{\"type\":\"text\",\"text\":");
        try writeJsonString(w, message.content);
        try w.writeByte('}');
        emitted += 1;
    }
    if (emitted != 0) try w.writeByte(']');
}

fn writeAnthropicMessage(w: *std.Io.Writer, message: ChatMessage) !void {
    try w.writeAll("{\"role\":");
    try writeJsonString(w, switch (message.role) {
        .assistant => "assistant",
        else => "user",
    });
    try w.writeAll(",\"content\":[");
    var emitted: usize = 0;
    if (message.role == .assistant and message.content.len > 0) {
        try writeAnthropicTextBlock(w, message.content, &emitted);
    } else if (message.content_parts.len > 0) {
        for (message.content_parts) |part| {
            if (emitted != 0) try w.writeByte(',');
            try writeAnthropicContentPart(w, part);
            emitted += 1;
        }
    } else if (message.content.len > 0) {
        try writeAnthropicTextBlock(w, message.content, &emitted);
    }
    if (message.role == .assistant and message.tool_calls.len > 0) {
        for (message.tool_calls) |call| {
            if (emitted != 0) try w.writeByte(',');
            try writeAnthropicToolUseBlock(w, call);
            emitted += 1;
        }
    }
    try w.writeAll("]}");
}

fn writeAnthropicToolResultMessage(w: *std.Io.Writer, messages: []const ChatMessage, index: *usize) !void {
    try w.writeAll("{\"role\":\"user\",\"content\":[");
    var emitted: usize = 0;
    while (index.* < messages.len and messages[index.*].role == .tool) : (index.* += 1) {
        if (emitted != 0) try w.writeByte(',');
        const message = messages[index.*];
        try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
        try writeJsonString(w, message.tool_call_id orelse "");
        try w.writeAll(",\"content\":");
        try writeJsonString(w, message.content);
        try w.writeByte('}');
        emitted += 1;
    }
    try w.writeAll("]}");
}

fn writeAnthropicTextBlock(w: *std.Io.Writer, text: []const u8, emitted: *usize) !void {
    if (emitted.* != 0) try w.writeByte(',');
    try w.writeAll("{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.writeByte('}');
    emitted.* += 1;
}

fn writeAnthropicContentPart(w: *std.Io.Writer, part: ChatContentPart) !void {
    switch (part) {
        .text => |text| {
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try writeJsonString(w, text);
            try w.writeByte('}');
        },
        .image => |image| {
            try w.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
            try writeJsonString(w, image.mime_type);
            try w.writeAll(",\"data\":");
            try writeJsonString(w, image.data);
            try w.writeAll("}}");
        },
    }
}

fn writeAnthropicToolUseBlock(w: *std.Io.Writer, call: ChatToolCall) !void {
    try w.writeAll("{\"type\":\"tool_use\",\"id\":");
    try writeJsonString(w, call.id);
    try w.writeAll(",\"name\":");
    try writeJsonString(w, call.name);
    try w.writeAll(",\"input\":");
    if (std.mem.trim(u8, call.arguments_json, " \t\r\n").len == 0) {
        try w.writeAll("{}");
    } else {
        try w.writeAll(call.arguments_json);
    }
    try w.writeByte('}');
}

fn writeAnthropicToolDefinition(w: *std.Io.Writer, tool: ChatToolDefinition) !void {
    try w.writeAll("{\"name\":");
    try writeJsonString(w, tool.name);
    try w.writeAll(",\"description\":");
    try writeJsonString(w, tool.description);
    try w.writeAll(",\"input_schema\":");
    try w.writeAll(tool.parameters_json);
    try w.writeByte('}');
}

fn writeGoogleSystemInstruction(w: *std.Io.Writer, messages: []const ChatMessage) !void {
    var emitted: usize = 0;
    for (messages) |message| {
        if (message.role != .system or std.mem.trim(u8, message.content, " \t\r\n").len == 0) continue;
        if (emitted == 0) try w.writeAll(",\"systemInstruction\":{\"parts\":[") else try w.writeByte(',');
        try w.writeAll("{\"text\":");
        try writeJsonString(w, message.content);
        try w.writeByte('}');
        emitted += 1;
    }
    if (emitted != 0) try w.writeAll("]}");
}

fn writeGoogleContent(w: *std.Io.Writer, message: ChatMessage) !void {
    try w.writeAll("{\"role\":");
    try writeJsonString(w, if (message.role == .assistant) "model" else "user");
    try w.writeAll(",\"parts\":[");
    var emitted: usize = 0;
    if (message.role == .assistant and message.content.len > 0) {
        try writeGoogleTextPart(w, message.content, &emitted);
    } else if (message.content_parts.len > 0) {
        for (message.content_parts) |part| {
            if (emitted != 0) try w.writeByte(',');
            try writeGoogleContentPart(w, part);
            emitted += 1;
        }
    } else if (message.content.len > 0) {
        try writeGoogleTextPart(w, message.content, &emitted);
    }
    if (message.role == .assistant and message.tool_calls.len > 0) {
        for (message.tool_calls) |call| {
            if (emitted != 0) try w.writeByte(',');
            try writeGoogleFunctionCallPart(w, call);
            emitted += 1;
        }
    }
    try w.writeAll("]}");
}

fn writeGoogleToolResultContent(w: *std.Io.Writer, messages: []const ChatMessage, index: *usize) !void {
    try w.writeAll("{\"role\":\"user\",\"parts\":[");
    var emitted: usize = 0;
    while (index.* < messages.len and messages[index.*].role == .tool) : (index.* += 1) {
        const message = messages[index.*];
        const tool_call_id = message.tool_call_id orelse return error.ProviderResponseInvalid;
        const tool_name = findToolNameForToolResult(messages, index.*, tool_call_id) orelse return error.ProviderResponseInvalid;
        if (emitted != 0) try w.writeByte(',');
        try w.writeAll("{\"functionResponse\":{\"name\":");
        try writeJsonString(w, tool_name);
        try w.writeAll(",\"response\":{\"output\":");
        try writeJsonString(w, message.content);
        try w.writeAll("}}}");
        emitted += 1;
    }
    try w.writeAll("]}");
}

fn findToolNameForToolResult(messages: []const ChatMessage, up_to_index: usize, tool_call_id: []const u8) ?[]const u8 {
    var remaining = up_to_index;
    while (remaining > 0) {
        remaining -= 1;
        const message = messages[remaining];
        if (message.role != .assistant) continue;
        for (message.tool_calls) |call| {
            if (std.mem.eql(u8, call.id, tool_call_id)) return call.name;
        }
    }
    return null;
}

fn writeGoogleTextPart(w: *std.Io.Writer, text: []const u8, emitted: *usize) !void {
    if (emitted.* != 0) try w.writeByte(',');
    try w.writeAll("{\"text\":");
    try writeJsonString(w, text);
    try w.writeByte('}');
    emitted.* += 1;
}

fn writeGoogleContentPart(w: *std.Io.Writer, part: ChatContentPart) !void {
    switch (part) {
        .text => |text| {
            try w.writeAll("{\"text\":");
            try writeJsonString(w, text);
            try w.writeByte('}');
        },
        .image => |image| {
            try w.writeAll("{\"inlineData\":{\"mimeType\":");
            try writeJsonString(w, image.mime_type);
            try w.writeAll(",\"data\":");
            try writeJsonString(w, image.data);
            try w.writeAll("}}");
        },
    }
}

fn writeGoogleFunctionCallPart(w: *std.Io.Writer, call: ChatToolCall) !void {
    try w.writeAll("{\"functionCall\":{\"name\":");
    try writeJsonString(w, call.name);
    try w.writeAll(",\"args\":");
    if (std.mem.trim(u8, call.arguments_json, " \t\r\n").len == 0) {
        try w.writeAll("{}");
    } else {
        try w.writeAll(call.arguments_json);
    }
    try w.writeAll("}}");
}

fn writeGoogleToolDefinition(w: *std.Io.Writer, tool: ChatToolDefinition) !void {
    try w.writeAll("{\"name\":");
    try writeJsonString(w, tool.name);
    try w.writeAll(",\"description\":");
    try writeJsonString(w, tool.description);
    try w.writeAll(",\"parametersJsonSchema\":");
    try w.writeAll(tool.parameters_json);
    try w.writeByte('}');
}

fn writeMistralMessage(w: *std.Io.Writer, messages: []const ChatMessage, index: usize, message: ChatMessage) !void {
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
        for (message.tool_calls, 0..) |call, call_index| {
            if (call_index != 0) try w.writeByte(',');
            try writeMistralToolCall(w, call);
        }
        try w.writeByte(']');
    } else if (message.role == .tool) {
        const tool_call_id = message.tool_call_id orelse return error.ProviderResponseInvalid;
        const tool_name = findToolNameForToolResult(messages, index, tool_call_id) orelse "";
        try w.writeAll(",\"tool_call_id\":");
        try writeJsonString(w, tool_call_id);
        if (tool_name.len > 0) {
            try w.writeAll(",\"name\":");
            try writeJsonString(w, tool_name);
        }
        try w.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
        try writeJsonString(w, if (message.content.len > 0) message.content else "(no tool output)");
        try w.writeAll("}]");
    } else {
        try w.writeAll(",\"content\":");
        if (message.content_parts.len > 0) {
            try writeMistralContentParts(w, message.content_parts);
        } else {
            try writeJsonString(w, message.content);
        }
    }
    try w.writeByte('}');
}

fn writeMistralContentParts(w: *std.Io.Writer, parts: []const ChatContentPart) !void {
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
                try w.writeAll("{\"type\":\"image_url\",\"image_url\":\"data:");
                try writeJsonStringFragment(w, image.mime_type);
                try w.writeAll(";base64,");
                try writeJsonStringFragment(w, image.data);
                try w.writeAll("\"}");
            },
        }
    }
    try w.writeByte(']');
}

fn writeMistralToolDefinition(w: *std.Io.Writer, tool: ChatToolDefinition) !void {
    try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try writeJsonString(w, tool.name);
    try w.writeAll(",\"description\":");
    try writeJsonString(w, tool.description);
    try w.writeAll(",\"parameters\":");
    try w.writeAll(tool.parameters_json);
    try w.writeAll(",\"strict\":false}}");
}

fn writeMistralToolCall(w: *std.Io.Writer, call: ChatToolCall) !void {
    try w.writeAll("{\"id\":");
    try writeJsonString(w, call.id);
    try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
    try writeJsonString(w, call.name);
    try w.writeAll(",\"arguments\":");
    try writeJsonString(w, call.arguments_json);
    try w.writeAll("}}");
}

fn readAnthropicSseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
) !void {
    var data_writer: std.Io.Writer.Allocating = .init(allocator);
    defer data_writer.deinit();
    var event_kind: AnthropicSseEventKind = .none;
    var saw_stop = false;

    while (true) {
        const raw_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ProviderResponseInvalid,
            else => return err,
        };
        const line_with_cr = raw_line orelse break;
        const line = stripTrailingCarriageReturn(line_with_cr);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            if (data_writer.written().len > 0) {
                if (event_kind == .err) return error.ProviderRequestFailed;
                const data = data_writer.written();
                try callback(callback_context, data);
                if (try isAnthropicMessageStopData(allocator, data)) saw_stop = true;
                data_writer.deinit();
                data_writer = .init(allocator);
            }
            event_kind = .none;
            continue;
        }
        if (trimmed[0] == ':') continue;
        if (std.mem.startsWith(u8, trimmed, "event:")) {
            event_kind = parseAnthropicSseEventKind(std.mem.trim(u8, trimmed["event:".len..], " \t"));
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "data:")) {
            if (data_writer.written().len > 0) try data_writer.writer.writeByte('\n');
            try data_writer.writer.writeAll(std.mem.trim(u8, trimmed["data:".len..], " \t"));
        }
    }
    if (data_writer.written().len > 0) {
        if (event_kind == .err) return error.ProviderRequestFailed;
        const data = data_writer.written();
        try callback(callback_context, data);
        if (try isAnthropicMessageStopData(allocator, data)) saw_stop = true;
    }
    if (!saw_stop) return error.ProviderResponseInvalid;
}

fn readGoogleSseStream(
    reader: *std.Io.Reader,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
) !void {
    var saw_data = false;
    while (true) {
        const raw_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ProviderResponseInvalid,
            else => return err,
        };
        const line_with_cr = raw_line orelse break;
        const line = stripTrailingCarriageReturn(line_with_cr);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == ':') continue;
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
        if (data.len == 0) continue;
        try callback(callback_context, data);
        saw_data = true;
    }
    if (!saw_data) return error.ProviderResponseInvalid;
}

const AnthropicSseEventKind = enum {
    none,
    known,
    err,
};

fn parseAnthropicSseEventKind(event: []const u8) AnthropicSseEventKind {
    if (std.mem.eql(u8, event, "error")) return .err;
    if (std.mem.eql(u8, event, "message_start") or
        std.mem.eql(u8, event, "message_delta") or
        std.mem.eql(u8, event, "message_stop") or
        std.mem.eql(u8, event, "content_block_start") or
        std.mem.eql(u8, event, "content_block_delta") or
        std.mem.eql(u8, event, "content_block_stop"))
    {
        return .known;
    }
    return .none;
}

fn isAnthropicMessageStopData(allocator: std.mem.Allocator, data: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return error.ProviderResponseInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ProviderResponseInvalid;
    const event_type = parsed.value.object.get("type") orelse return false;
    if (event_type != .string) return error.ProviderResponseInvalid;
    return std.mem.eql(u8, event_type.string, "message_stop");
}

fn parseAnthropicMessagesResult(allocator: std.mem.Allocator, body: []const u8) !ChatCompletionResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderResponseInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ProviderResponseInvalid;

    const content = parsed.value.object.get("content") orelse return error.ProviderResponseInvalid;
    if (content != .array) return error.ProviderResponseInvalid;

    var result: ChatCompletionResult = .{};
    errdefer result.deinit(allocator);
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    var calls: std.ArrayList(ChatToolCall) = .empty;
    errdefer {
        for (calls.items) |call| call.deinit(allocator);
        calls.deinit(allocator);
    }

    for (content.array.items) |block| {
        if (block != .object) return error.ProviderResponseInvalid;
        const block_type = try requiredObjectString(block, "type");
        if (std.mem.eql(u8, block_type, "text")) {
            try text.writer.writeAll(try requiredObjectString(block, "text"));
        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            const input = block.object.get("input") orelse return error.ProviderResponseInvalid;
            const arguments_json = try jsonValueToOwnedString(allocator, input);
            errdefer allocator.free(arguments_json);
            try calls.append(allocator, .{
                .id = try allocator.dupe(u8, try requiredObjectString(block, "id")),
                .name = try allocator.dupe(u8, try requiredObjectString(block, "name")),
                .arguments_json = arguments_json,
            });
        }
    }

    if (text.written().len > 0) {
        result.text = try text.toOwnedSlice();
        text = .init(allocator);
    }
    if (calls.items.len > 0) {
        result.tool_calls = try calls.toOwnedSlice(allocator);
    }
    if (result.text == null and result.tool_calls.len == 0) return error.ProviderResponseInvalid;
    return result;
}

fn parseGoogleGenerateContentResult(allocator: std.mem.Allocator, body: []const u8) !ChatCompletionResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderResponseInvalid;
    defer parsed.deinit();

    var result: ChatCompletionResult = .{};
    errdefer result.deinit(allocator);
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    var calls: std.ArrayList(ChatToolCall) = .empty;
    errdefer {
        for (calls.items) |call| call.deinit(allocator);
        calls.deinit(allocator);
    }

    const parts = try firstGoogleCandidateParts(parsed.value) orelse return error.ProviderResponseInvalid;
    for (parts, 0..) |part, index| {
        if (part != .object) return error.ProviderResponseInvalid;
        if (part.object.get("text")) |text_value| {
            if (text_value != .string) return error.ProviderResponseInvalid;
            try text.writer.writeAll(text_value.string);
        }
        if (part.object.get("functionCall")) |function_call| {
            if (function_call != .object) return error.ProviderResponseInvalid;
            const name = try optionalObjectString(function_call, "name") orelse return error.ProviderResponseInvalid;
            var id: ?[]u8 = if (try optionalObjectString(function_call, "id")) |provided_id|
                try allocator.dupe(u8, provided_id)
            else
                try std.fmt.allocPrint(allocator, "{s}_google_{d}", .{ name, index + 1 });
            errdefer if (id) |value| allocator.free(value);
            var name_copy: ?[]u8 = try allocator.dupe(u8, name);
            errdefer if (name_copy) |value| allocator.free(value);
            var arguments_json: ?[]u8 = if (function_call.object.get("args")) |args|
                if (args == .null) try allocator.dupe(u8, "{}") else try jsonValueToOwnedString(allocator, args)
            else
                try allocator.dupe(u8, "{}");
            errdefer if (arguments_json) |value| allocator.free(value);
            try calls.append(allocator, .{
                .id = id.?,
                .name = name_copy.?,
                .arguments_json = arguments_json.?,
            });
            id = null;
            name_copy = null;
            arguments_json = null;
        }
    }

    if (text.written().len > 0) {
        result.text = try text.toOwnedSlice();
        text = .init(allocator);
    }
    if (calls.items.len > 0) {
        result.tool_calls = try calls.toOwnedSlice(allocator);
    }
    if (result.text == null and result.tool_calls.len == 0) return error.ProviderResponseInvalid;
    return result;
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
    if (isAnthropicStreamEvent(parsed.value)) {
        if (try anthropicStreamTextDelta(parsed.value)) |delta| {
            if (delta.len > 0) try callback(callback_context, delta);
        }
        return;
    }
    if (isGoogleStreamChunk(parsed.value)) {
        try parseGoogleStreamTextDeltas(parsed.value, callback_context, callback);
        return;
    }
    if (isMistralStreamChunk(parsed.value)) {
        try parseMistralStreamTextDeltas(parsed.value, callback_context, callback);
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
    if (isAnthropicStreamEvent(parsed.value)) {
        try accumulator.appendAnthropicStreamEvent(parsed.value, text_callback_context, text_callback);
        return;
    }
    if (isGoogleStreamChunk(parsed.value)) {
        try accumulator.appendGoogleStreamChunk(parsed.value, text_callback_context, text_callback);
        return;
    }
    if (isMistralStreamChunk(parsed.value)) {
        try accumulator.appendMistralStreamChunk(parsed.value, text_callback_context, text_callback);
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

fn isAnthropicStreamEvent(value: std.json.Value) bool {
    if (value != .object) return false;
    const event_type = value.object.get("type") orelse return false;
    if (event_type != .string) return false;
    return std.mem.eql(u8, event_type.string, "message_start") or
        std.mem.eql(u8, event_type.string, "content_block_start") or
        std.mem.eql(u8, event_type.string, "content_block_delta") or
        std.mem.eql(u8, event_type.string, "content_block_stop") or
        std.mem.eql(u8, event_type.string, "message_delta") or
        std.mem.eql(u8, event_type.string, "message_stop");
}

fn anthropicStreamTextDelta(value: std.json.Value) !?[]const u8 {
    if (value != .object) return error.ProviderResponseInvalid;
    const event_type = try requiredObjectString(value, "type");
    if (!std.mem.eql(u8, event_type, "content_block_delta")) return null;
    const delta = value.object.get("delta") orelse return error.ProviderResponseInvalid;
    if (delta != .object) return error.ProviderResponseInvalid;
    const delta_type = try requiredObjectString(delta, "type");
    if (!std.mem.eql(u8, delta_type, "text_delta")) return null;
    return try requiredObjectString(delta, "text");
}

fn isGoogleStreamChunk(value: std.json.Value) bool {
    if (value != .object) return false;
    return value.object.get("candidates") != null;
}

fn parseGoogleStreamTextDeltas(
    value: std.json.Value,
    callback_context: *anyopaque,
    callback: StreamTextCallback,
) !void {
    const parts = try firstGoogleCandidateParts(value) orelse return;
    for (parts) |part| {
        if (part != .object) return error.ProviderResponseInvalid;
        if (part.object.get("text")) |text| {
            if (text != .string) return error.ProviderResponseInvalid;
            if (text.string.len > 0) try callback(callback_context, text.string);
        }
    }
}

fn isMistralStreamChunk(value: std.json.Value) bool {
    const delta = firstStreamDelta(value) catch return false;
    const actual_delta = delta orelse return false;
    if (actual_delta.object.get("toolCalls")) |_| return true;
    if (actual_delta.object.get("content")) |content| {
        return content == .array;
    }
    return false;
}

fn parseMistralStreamTextDeltas(
    value: std.json.Value,
    callback_context: *anyopaque,
    callback: StreamTextCallback,
) !void {
    const delta = try firstStreamDelta(value) orelse return;
    try parseMistralContentDelta(delta, callback_context, callback);
}

fn parseMistralContentDelta(
    delta: std.json.Value,
    callback_context: *anyopaque,
    callback: StreamTextCallback,
) !void {
    const content = delta.object.get("content") orelse return;
    switch (content) {
        .null => return,
        .string => |text| if (text.len > 0) try callback(callback_context, text),
        .array => |items| {
            for (items.items) |item| {
                if (item == .string) {
                    if (item.string.len > 0) try callback(callback_context, item.string);
                    continue;
                }
                if (item != .object) return error.ProviderResponseInvalid;
                const item_type = try optionalObjectString(item, "type") orelse continue;
                if (std.mem.eql(u8, item_type, "text")) {
                    const text = try requiredObjectString(item, "text");
                    if (text.len > 0) try callback(callback_context, text);
                }
            }
        },
        else => return error.ProviderResponseInvalid,
    }
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

    fn appendAnthropicStreamEvent(
        self: *StreamChatAccumulator,
        value: std.json.Value,
        text_callback_context: ?*anyopaque,
        text_callback: ?StreamTextCallback,
    ) !void {
        const event_type = try requiredObjectString(value, "type");
        if (std.mem.eql(u8, event_type, "content_block_start")) {
            const content_block = value.object.get("content_block") orelse return error.ProviderResponseInvalid;
            if (try isAnthropicToolUseBlock(content_block)) {
                const index = try anthropicEventIndex(value);
                try self.startAnthropicToolUse(index, content_block);
            }
            return;
        }
        if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const delta = value.object.get("delta") orelse return error.ProviderResponseInvalid;
            if (delta != .object) return error.ProviderResponseInvalid;
            const delta_type = try requiredObjectString(delta, "type");
            if (std.mem.eql(u8, delta_type, "text_delta")) {
                try self.appendTextDelta(try requiredObjectString(delta, "text"), text_callback_context, text_callback);
                return;
            }
            if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                const index = try anthropicEventIndex(value);
                if (index >= self.tool_calls.items.len or !self.tool_calls.items[index].seen) return;
                try self.tool_calls.items[index].arguments_json.writer.writeAll(try requiredObjectString(delta, "partial_json"));
                return;
            }
            return;
        }
    }

    fn appendGoogleStreamChunk(
        self: *StreamChatAccumulator,
        value: std.json.Value,
        text_callback_context: ?*anyopaque,
        text_callback: ?StreamTextCallback,
    ) !void {
        const parts = try firstGoogleCandidateParts(value) orelse return;
        for (parts) |part| {
            if (part != .object) return error.ProviderResponseInvalid;
            if (part.object.get("text")) |text| {
                if (text != .string) return error.ProviderResponseInvalid;
                try self.appendTextDelta(text.string, text_callback_context, text_callback);
            }
            if (part.object.get("functionCall")) |function_call| {
                try self.appendGoogleFunctionCall(function_call);
            }
        }
    }

    fn appendMistralStreamChunk(
        self: *StreamChatAccumulator,
        value: std.json.Value,
        text_callback_context: ?*anyopaque,
        text_callback: ?StreamTextCallback,
    ) !void {
        const delta = try firstStreamDelta(value) orelse return;
        if (delta.object.get("content")) |_| {
            try self.appendMistralContentDelta(delta, text_callback_context, text_callback);
        }
        if (delta.object.get("toolCalls")) |tool_calls| {
            try self.appendMistralToolCallDeltas(tool_calls);
        } else if (delta.object.get("tool_calls")) |tool_calls| {
            try self.appendToolCallDeltas(tool_calls);
        }
    }

    fn appendMistralContentDelta(
        self: *StreamChatAccumulator,
        delta: std.json.Value,
        text_callback_context: ?*anyopaque,
        text_callback: ?StreamTextCallback,
    ) !void {
        const content = delta.object.get("content") orelse return;
        switch (content) {
            .null => return,
            .string => |text| try self.appendTextDelta(text, text_callback_context, text_callback),
            .array => |items| {
                for (items.items) |item| {
                    if (item == .string) {
                        try self.appendTextDelta(item.string, text_callback_context, text_callback);
                        continue;
                    }
                    if (item != .object) return error.ProviderResponseInvalid;
                    const item_type = try optionalObjectString(item, "type") orelse continue;
                    if (std.mem.eql(u8, item_type, "text")) {
                        try self.appendTextDelta(try requiredObjectString(item, "text"), text_callback_context, text_callback);
                    }
                }
            },
            else => return error.ProviderResponseInvalid,
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

    fn appendMistralToolCallDeltas(self: *StreamChatAccumulator, value: std.json.Value) !void {
        if (value != .array) return error.ProviderResponseInvalid;
        for (value.array.items, 0..) |item, fallback_index| {
            if (item != .object) return error.ProviderResponseInvalid;
            const index = if (item.object.get("index")) |index_value|
                try streamToolCallIndex(index_value)
            else
                fallback_index;
            const call = try self.ensureToolCall(index);
            call.seen = true;

            if (item.object.get("id")) |id| {
                if (id != .null) {
                    if (id != .string) return error.ProviderResponseInvalid;
                    if (call.id.written().len == 0 and !std.mem.eql(u8, id.string, "null")) {
                        try call.id.writer.writeAll(id.string);
                    }
                }
            }
            if (call.id.written().len == 0) {
                try call.id.writer.print("mistral_tool_{d}", .{index + 1});
            }

            const function = item.object.get("function") orelse continue;
            if (function != .object) return error.ProviderResponseInvalid;
            if (function.object.get("name")) |name| {
                if (name != .null) {
                    if (name != .string) return error.ProviderResponseInvalid;
                    if (call.name.written().len == 0) try call.name.writer.writeAll(name.string);
                }
            }
            if (function.object.get("arguments")) |arguments| {
                if (arguments == .null) continue;
                if (arguments == .string) {
                    try call.arguments_json.writer.writeAll(arguments.string);
                } else {
                    const arguments_json = try jsonValueToOwnedString(self.allocator, arguments);
                    defer self.allocator.free(arguments_json);
                    try call.arguments_json.writer.writeAll(arguments_json);
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

    fn startAnthropicToolUse(self: *StreamChatAccumulator, index: usize, content_block: std.json.Value) !void {
        const call = try self.ensureToolCall(index);
        call.seen = true;
        try call.id.writer.writeAll(try requiredObjectString(content_block, "id"));
        try call.name.writer.writeAll(try requiredObjectString(content_block, "name"));
        if (content_block.object.get("input")) |input| {
            if (try shouldSerializeInitialToolInput(input)) {
                const arguments_json = try jsonValueToOwnedString(self.allocator, input);
                defer self.allocator.free(arguments_json);
                try call.arguments_json.writer.writeAll(arguments_json);
            }
        }
    }

    fn appendGoogleFunctionCall(self: *StreamChatAccumulator, function_call: std.json.Value) !void {
        if (function_call != .object) return error.ProviderResponseInvalid;
        const index = self.tool_calls.items.len;
        const call = try self.ensureToolCall(index);
        call.seen = true;

        const name = optionalObjectString(function_call, "name") catch |err| return err;
        const actual_name = name orelse "";
        if (actual_name.len == 0) return error.ProviderResponseInvalid;

        if (try optionalObjectString(function_call, "id")) |provided_id| {
            if (provided_id.len > 0 and !self.hasToolCallId(provided_id)) {
                try call.id.writer.writeAll(provided_id);
            }
        }
        if (call.id.written().len == 0) {
            try call.id.writer.print("{s}_google_{d}", .{ actual_name, index + 1 });
        }
        try call.name.writer.writeAll(actual_name);

        if (function_call.object.get("args")) |args| {
            if (args == .null) {
                try call.arguments_json.writer.writeAll("{}");
            } else {
                const arguments_json = try jsonValueToOwnedString(self.allocator, args);
                defer self.allocator.free(arguments_json);
                try call.arguments_json.writer.writeAll(arguments_json);
            }
        } else {
            try call.arguments_json.writer.writeAll("{}");
        }
    }

    fn hasToolCallId(self: *StreamChatAccumulator, id: []const u8) bool {
        for (self.tool_calls.items) |*call| {
            if (std.mem.eql(u8, call.id.written(), id)) return true;
        }
        return false;
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

fn firstGoogleCandidateParts(value: std.json.Value) !?[]std.json.Value {
    if (value != .object) return error.ProviderResponseInvalid;
    const candidates = value.object.get("candidates") orelse return null;
    if (candidates != .array) return error.ProviderResponseInvalid;
    if (candidates.array.items.len == 0) return null;
    const first = candidates.array.items[0];
    if (first != .object) return error.ProviderResponseInvalid;
    const content = first.object.get("content") orelse return null;
    if (content != .object) return error.ProviderResponseInvalid;
    const parts = content.object.get("parts") orelse return null;
    if (parts != .array) return error.ProviderResponseInvalid;
    return parts.array.items;
}

fn anthropicEventIndex(value: std.json.Value) !usize {
    if (value != .object) return error.ProviderResponseInvalid;
    const index = value.object.get("index") orelse return error.ProviderResponseInvalid;
    return streamToolCallIndex(index);
}

fn isAnthropicToolUseBlock(content_block: std.json.Value) !bool {
    if (content_block != .object) return error.ProviderResponseInvalid;
    const block_type = content_block.object.get("type") orelse return false;
    if (block_type != .string) return error.ProviderResponseInvalid;
    return std.mem.eql(u8, block_type.string, "tool_use");
}

fn shouldSerializeInitialToolInput(value: std.json.Value) !bool {
    if (value == .null) return false;
    if (value == .object and value.object.count() == 0) return false;
    return true;
}

fn jsonValueToOwnedString(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
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
        } else if (message.object.get("toolCalls")) |tool_calls| {
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

test "serializes Anthropic messages payload with images tools and tool results" {
    const parts = [_]ChatContentPart{
        .{ .text = "inspect this" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const tool_calls = [_]ChatToolCall{
        .{ .id = @constCast("call_1"), .name = @constCast("bash"), .arguments_json = @constCast("{\"command\":\"printf ok\"}") },
    };
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "be terse" },
        .{ .role = .user, .content_parts = parts[0..] },
        .{ .role = .assistant, .content = "running", .tool_calls = tool_calls[0..] },
        .{ .role = .tool, .content = "ok", .tool_call_id = "call_1" },
    };
    const tools = [_]ChatToolDefinition{
        .{ .name = "bash", .description = "run shell", .parameters_json = "{\"type\":\"object\"}" },
    };
    const payload = try buildAnthropicMessagesPayload(std.testing.allocator, .{
        .provider = "anthropic",
        .model = "claude-test",
        .api_key = "sk-ant-test",
        .messages = messages[0..],
        .tools = tools[0..],
    }, true);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"system\":[{\"type\":\"text\",\"text\":\"be terse\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"aGVsbG8=\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"bash\",\"input\":{\"command\":\"printf ok\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"type\":\"tool_result\",\"tool_use_id\":\"call_1\",\"content\":\"ok\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tools\":[{\"name\":\"bash\",\"description\":\"run shell\",\"input_schema\":{\"type\":\"object\"}}]") != null);
}

test "serializes Google generate content payload with images tools and tool results" {
    const parts = [_]ChatContentPart{
        .{ .text = "inspect this" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const tool_calls = [_]ChatToolCall{
        .{ .id = @constCast("call_1"), .name = @constCast("bash"), .arguments_json = @constCast("{\"command\":\"printf ok\"}") },
    };
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "be terse" },
        .{ .role = .user, .content_parts = parts[0..] },
        .{ .role = .assistant, .content = "running", .tool_calls = tool_calls[0..] },
        .{ .role = .tool, .content = "ok", .tool_call_id = "call_1" },
    };
    const tools = [_]ChatToolDefinition{
        .{ .name = "bash", .description = "run shell", .parameters_json = "{\"type\":\"object\"}" },
    };
    const payload = try buildGoogleGenerateContentPayload(std.testing.allocator, .{
        .provider = "google",
        .model = "gemini-test",
        .api_key = "google-test",
        .messages = messages[0..],
        .tools = tools[0..],
    });
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"systemInstruction\":{\"parts\":[{\"text\":\"be terse\"}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"aGVsbG8=\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"functionCall\":{\"name\":\"bash\",\"args\":{\"command\":\"printf ok\"}}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"functionResponse\":{\"name\":\"bash\",\"response\":{\"output\":\"ok\"}}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tools\":[{\"functionDeclarations\":[{\"name\":\"bash\",\"description\":\"run shell\",\"parametersJsonSchema\":{\"type\":\"object\"}}]}]") != null);
}

test "serializes Mistral chat payload with images tools and tool results" {
    const parts = [_]ChatContentPart{
        .{ .text = "inspect this" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const tool_calls = [_]ChatToolCall{
        .{ .id = @constCast("call_1"), .name = @constCast("bash"), .arguments_json = @constCast("{\"command\":\"printf ok\"}") },
    };
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "be terse" },
        .{ .role = .user, .content_parts = parts[0..] },
        .{ .role = .assistant, .content = "running", .tool_calls = tool_calls[0..] },
        .{ .role = .tool, .content = "ok", .tool_call_id = "call_1" },
    };
    const tools = [_]ChatToolDefinition{
        .{ .name = "bash", .description = "run shell", .parameters_json = "{\"type\":\"object\"}" },
    };
    const payload = try buildMistralChatPayload(std.testing.allocator, .{
        .provider = "mistral",
        .model = "devstral-test",
        .api_key = "mistral-test",
        .messages = messages[0..],
        .tools = tools[0..],
    }, true);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"role\":\"system\",\"content\":\"be terse\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"type\":\"image_url\",\"image_url\":\"data:image/png;base64,aGVsbG8=\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"printf ok\\\"}\"}}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tool_call_id\":\"call_1\",\"name\":\"bash\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"bash\",\"description\":\"run shell\",\"parameters\":{\"type\":\"object\"},\"strict\":false}}]") != null);
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

test "assembles Anthropic text stream events" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1,"output_tokens":0}}}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"anthropic "}}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"text"}}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"content_block_stop","index":0}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"message_stop"}
    , &accumulator, null, null);
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("anthropic text", result.text.?);
    try std.testing.expectEqual(@as(usize, 0), result.tool_calls.len);
}

test "parses Anthropic messages result text and tool use" {
    const body =
        \\{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"before "},{"type":"tool_use","id":"call_1","name":"bash","input":{"command":"printf ok"}}]}
    ;
    const result = try parseAnthropicMessagesResult(std.testing.allocator, body);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("before ", result.text.?);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf ok\"}", result.tool_calls[0].arguments_json);
}

test "parses Google generate content result text and function call" {
    const body =
        \\{"candidates":[{"content":{"parts":[{"text":"before "},{"functionCall":{"id":"call_1","name":"bash","args":{"command":"printf ok"}}}]},"finishReason":"STOP"}]}
    ;
    const result = try parseGoogleGenerateContentResult(std.testing.allocator, body);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("before ", result.text.?);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf ok\"}", result.tool_calls[0].arguments_json);
}

test "parses native Anthropic SSE frames without done sentinel" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    var context = StreamResultContext{
        .allocator = std.testing.allocator,
        .accumulator = &accumulator,
        .text_callback_context = null,
        .text_callback = null,
    };
    var reader = std.Io.Reader.fixed(
        "event: message_start\n" ++
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\"}}\n\n" ++
            "event: content_block_start\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"native \"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"anthropic\"}}\n\n" ++
            "event: message_stop\n" ++
            "data: {\"type\":\"message_stop\"}\n\n",
    );
    try readAnthropicSseStream(std.testing.allocator, &reader, &context, handleStreamResultData);
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("native anthropic", result.text.?);
}

test "parses native Google SSE frames without done sentinel" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    var context = StreamResultContext{
        .allocator = std.testing.allocator,
        .accumulator = &accumulator,
        .text_callback_context = null,
        .text_callback = null,
    };
    var reader = std.Io.Reader.fixed(
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"native \"}]}}]}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"google\"}]},\"finishReason\":\"STOP\"}]}\n\n",
    );
    try readGoogleSseStream(&reader, &context, handleStreamResultData);
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("native google", result.text.?);
}

test "parses Mistral camelCase stream tool calls and content arrays" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    var context = StreamResultContext{
        .allocator = std.testing.allocator,
        .accumulator = &accumulator,
        .text_callback_context = null,
        .text_callback = null,
    };
    try handleStreamResultData(
        &context,
        "{\"choices\":[{\"delta\":{\"content\":[{\"type\":\"text\",\"text\":\"mistral \"}]}}]}",
    );
    try handleStreamResultData(
        &context,
        "{\"choices\":[{\"delta\":{\"toolCalls\":[{\"index\":0,\"id\":\"call_mistral\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"printf \"}}]}}]}",
    );
    try handleStreamResultData(
        &context,
        "{\"choices\":[{\"delta\":{\"toolCalls\":[{\"index\":0,\"function\":{\"arguments\":\"mistral-ok\\\"}\"}}]}}]}",
    );
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("mistral ", result.text.?);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_mistral", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf mistral-ok\"}", result.tool_calls[0].arguments_json);
}

test "assembles Anthropic tool use stream events" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call_anthropic","name":"bash","input":{}}}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"printf "}}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"anthropic-ok\"}"}}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"type":"content_block_stop","index":0}
    , &accumulator, null, null);
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.text == null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_anthropic", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf anthropic-ok\"}", result.tool_calls[0].arguments_json);
}

test "assembles Google text stream chunks" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"candidates":[{"content":{"parts":[{"text":"google "}]}}]}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"candidates":[{"content":{"parts":[{"text":"text"}]},"finishReason":"STOP"}]}
    , &accumulator, null, null);
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("google text", result.text.?);
    try std.testing.expectEqual(@as(usize, 0), result.tool_calls.len);
}

test "assembles Google function call stream chunks" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"candidates":[{"content":{"parts":[{"functionCall":{"id":"call_google","name":"bash","args":{"command":"printf google-ok"}}}]},"finishReason":"STOP"}]}
    , &accumulator, null, null);
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.text == null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_google", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf google-ok\"}", result.tool_calls[0].arguments_json);
}

test "provider base URL appends chat completions endpoint" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43123/v1/");
    const endpoint = try endpointForProvider(std.testing.allocator, &env, "openai");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/chat/completions", endpoint);
}

test "Anthropic provider base URL appends messages endpoint once" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43123/v1/");
    const endpoint_from_versioned_base = try anthropicMessagesEndpointForProvider(std.testing.allocator, &env);
    defer std.testing.allocator.free(endpoint_from_versioned_base);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/messages", endpoint_from_versioned_base);

    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43123");
    const endpoint_from_root_base = try anthropicMessagesEndpointForProvider(std.testing.allocator, &env);
    defer std.testing.allocator.free(endpoint_from_root_base);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/messages", endpoint_from_root_base);
}

test "Google provider base URL appends stream generate content endpoint" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43123/v1/");
    const stream_endpoint = try googleGenerateContentEndpointForProvider(std.testing.allocator, &env, "gemini-test", true);
    defer std.testing.allocator.free(stream_endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/models/gemini-test:streamGenerateContent?alt=sse", stream_endpoint);

    const non_stream_endpoint = try googleGenerateContentEndpointForProvider(std.testing.allocator, &env, "gemini-test", false);
    defer std.testing.allocator.free(non_stream_endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/models/gemini-test:generateContent", non_stream_endpoint);
}

test "Mistral provider base URL appends chat completions endpoint once" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43123/v1");
    const endpoint_from_root = try mistralChatEndpointForProvider(std.testing.allocator, &env);
    defer std.testing.allocator.free(endpoint_from_root);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/chat/completions", endpoint_from_root);

    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43123/v1/chat/completions");
    const endpoint_from_full = try mistralChatEndpointForProvider(std.testing.allocator, &env);
    defer std.testing.allocator.free(endpoint_from_full);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/chat/completions", endpoint_from_full);
}

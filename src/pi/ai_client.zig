const std = @import("std");
const config = @import("config.zig");
const models = @import("models.zig");

const non_vision_user_image_placeholder = "(image omitted: model does not support images)";
const non_vision_tool_image_placeholder = "(tool image omitted: model does not support images)";

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
    thought_signature: ?[]u8 = null,

    pub fn deinit(self: ChatToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments_json);
        if (self.thought_signature) |signature| allocator.free(signature);
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

pub const CancellationCallback = *const fn (ctx: *anyopaque) bool;

pub const ChatTurnRequest = struct {
    provider: []const u8,
    model: []const u8,
    api_key: []const u8,
    messages: []const ChatMessage,
    tools: []const ChatToolDefinition = &.{},
    cancellation_context: ?*anyopaque = null,
    should_cancel: ?CancellationCallback = null,
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
    ProviderClientError,
    ProviderRequestFailed,
    ProviderResponseInvalid,
    ProviderStreamIncomplete,
    EmptyPrompt,
    AgentAborted,
} || std.mem.Allocator.Error || std.http.Client.FetchError;

// === Image generation ========================================================
//
// Mirrors upstream packages/ai/src/providers/images/openrouter.ts. The OpenRouter
// images API is the OpenAI chat-completions shape extended with a `modalities`
// array and a per-message `images[]` field on the assistant response. We model
// the request input and parsed output as the same text/image content parts used
// everywhere else in this module.

/// A single piece of generated-image output: either model text or an image
/// (decoded from a `data:<mime>;base64,<data>` URL into mime + base64 data).
pub const GeneratedImagePart = union(enum) {
    text: []u8,
    image: ChatImageContent,

    pub fn deinit(self: GeneratedImagePart, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |text| allocator.free(text),
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
        }
    }
};

pub const ImageGenerationResult = struct {
    output: []GeneratedImagePart = &.{},
    response_id: ?[]u8 = null,

    pub fn deinit(self: ImageGenerationResult, allocator: std.mem.Allocator) void {
        for (self.output) |part| part.deinit(allocator);
        allocator.free(self.output);
        if (self.response_id) |id| allocator.free(id);
    }
};

pub const ImageGenerationRequest = struct {
    /// Image-generation provider. Only "openrouter" is wired today; it is the
    /// sole built-in upstream images-api provider ("openrouter-images").
    provider: []const u8,
    model: []const u8,
    api_key: []const u8,
    /// Prompt + reference-image content parts forwarded to the model.
    input: []const ChatContentPart,
    /// When true, request both text and image modalities (matches upstream
    /// `model.output.includes("text")`); otherwise request image-only.
    include_text: bool = false,
};

pub const StreamTextCallback = *const fn (ctx: *anyopaque, delta: []const u8) anyerror!void;
const StreamDataCallback = *const fn (ctx: *anyopaque, data: []const u8) anyerror!void;
const max_provider_error_body_bytes = 16 * 1024;

const CancellationState = struct {
    context: ?*anyopaque = null,
    should_cancel: ?CancellationCallback = null,
};

fn cancellationState(request: ChatTurnRequest) CancellationState {
    return .{
        .context = request.cancellation_context,
        .should_cancel = request.should_cancel,
    };
}

fn checkCancellation(state: CancellationState) ChatCompletionError!void {
    if (state.should_cancel) |callback| {
        if (state.context) |context| {
            if (callback(context)) return error.AgentAborted;
        }
    }
}

fn providerErrorForStatus(status: std.http.Status) ChatCompletionError {
    return providerErrorForStatusAndBody(status, "");
}

fn providerErrorForStatusAndBody(status: std.http.Status, body: []const u8) ChatCompletionError {
    const code = @intFromEnum(status);
    if (isContextOverflowErrorText(body)) return error.ProviderClientError;
    return if (code == 429 or code >= 500 or isRetryableProviderErrorText(body))
        error.ProviderRequestFailed
    else
        error.ProviderClientError;
}

fn providerErrorForStatusAndReader(allocator: std.mem.Allocator, status: std.http.Status, reader: *std.Io.Reader) ChatCompletionError {
    const body = reader.allocRemaining(allocator, .limited(max_provider_error_body_bytes)) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => providerErrorForStatus(status),
        };
    };
    defer allocator.free(body);
    return providerErrorForStatusAndBody(status, body);
}

fn isRetryableProviderErrorText(text: []const u8) bool {
    return containsAsciiIgnoreCase(text, "overloaded") or
        containsWordsInOrderIgnoreCase(text, &.{ "throttling", "error" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "provider", "returned", "error" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "rate", "limit" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "too", "many", "requests" }) or
        containsAsciiIgnoreCase(text, "429") or
        containsAsciiIgnoreCase(text, "500") or
        containsAsciiIgnoreCase(text, "502") or
        containsAsciiIgnoreCase(text, "503") or
        containsAsciiIgnoreCase(text, "504") or
        containsWordsInOrderIgnoreCase(text, &.{ "service", "unavailable" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "server", "error" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "internal", "error" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "network", "error" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "connection", "error" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "connection", "refused" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "connection", "lost" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "websocket", "closed" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "websocket", "error" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "other", "side", "closed" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "fetch", "failed" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "upstream", "connect" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "reset", "before", "headers" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "socket", "hang", "up" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "ended", "without" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "stream", "ended", "before", "message_stop" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "http2", "request", "did", "not", "get", "a", "response" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "timed", "out" }) or
        containsAsciiIgnoreCase(text, "timeout") or
        containsAsciiIgnoreCase(text, "terminated") or
        containsWordsInOrderIgnoreCase(text, &.{ "retry", "delay" });
}

fn isContextOverflowErrorText(text: []const u8) bool {
    if (isKnownNonOverflowProviderErrorText(text)) return false;
    return containsWordsInOrderIgnoreCase(text, &.{ "prompt", "too", "long" }) or
        containsAsciiIgnoreCase(text, "request_too_large") or
        containsWordsInOrderIgnoreCase(text, &.{ "input", "too", "long", "requested", "model" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "exceeds", "context", "window" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "exceeds", "maximum", "context", "length" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "input", "token", "count", "exceeds", "maximum" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "maximum", "prompt", "length", "is" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "reduce", "length", "messages" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "maximum", "context", "length", "is" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "longer", "model", "context", "length" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "exceeds", "limit" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "exceeds", "available", "context", "size" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "greater", "than", "context", "length" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "context", "window", "exceeds", "limit" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "exceeded", "model", "token", "limit" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "too", "large", "model", "maximum", "context", "length" }) or
        containsAsciiIgnoreCase(text, "model_context_window_exceeded") or
        containsWordsInOrderIgnoreCase(text, &.{ "prompt", "too", "long", "context", "length" }) or
        containsAsciiIgnoreCase(text, "context_length_exceeded") or
        containsWordsInOrderIgnoreCase(text, &.{ "context", "length", "exceeded" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "too", "many", "tokens" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "token", "limit", "exceeded" });
}

fn isKnownNonOverflowProviderErrorText(text: []const u8) bool {
    return containsWordsInOrderIgnoreCase(text, &.{ "throttling", "error" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "service", "unavailable" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "rate", "limit" }) or
        containsWordsInOrderIgnoreCase(text, &.{ "too", "many", "requests" });
}

fn containsWordsInOrderIgnoreCase(text: []const u8, words: []const []const u8) bool {
    var start: usize = 0;
    for (words) |word| {
        const found = indexOfAsciiIgnoreCase(text[start..], word) orelse return false;
        start += found + word.len;
    }
    return true;
}

fn containsAsciiIgnoreCase(text: []const u8, needle: []const u8) bool {
    return indexOfAsciiIgnoreCase(text, needle) != null;
}

fn indexOfAsciiIgnoreCase(text: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > text.len) return null;
    var index: usize = 0;
    while (index + needle.len <= text.len) : (index += 1) {
        var matched = true;
        for (needle, 0..) |expected, offset| {
            if (std.ascii.toLower(text[index + offset]) != std.ascii.toLower(expected)) {
                matched = false;
                break;
            }
        }
        if (matched) return index;
    }
    return null;
}

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
    try checkCancellation(cancellationState(request));
    if (isAnthropicMessagesProvider(request.provider)) {
        return runAnthropicMessagesTurn(io, allocator, env, request);
    }
    if (isGoogleGenerativeProvider(request.provider)) {
        return runGoogleGenerateContentTurn(io, allocator, env, request);
    }
    if (isGoogleVertexProvider(request.provider)) {
        return runGoogleVertexGenerateContentTurn(io, allocator, env, request);
    }
    if (isMistralProvider(request.provider)) {
        return runMistralChatTurn(io, allocator, env, request);
    }
    if (isBedrockProvider(request.provider)) {
        return runBedrockConverseTurn(io, allocator, env, request);
    }
    if (isAzureOpenAIResponsesProvider(request.provider)) {
        return runAzureOpenAIResponsesTurn(io, allocator, env, request);
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
    try checkCancellation(cancellationState(request));

    const body = response_body.written();
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return providerErrorForStatusAndBody(result.status, body);
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
    try checkCancellation(cancellationState(request));
    if (isAnthropicMessagesProvider(request.provider)) {
        return streamAnthropicMessagesData(io, allocator, env, request, callback_context, callback);
    }
    if (isGoogleGenerativeProvider(request.provider)) {
        return streamGoogleGenerateContentData(io, allocator, env, request, callback_context, callback);
    }
    if (isGoogleVertexProvider(request.provider)) {
        return streamGoogleVertexGenerateContentData(io, allocator, env, request, callback_context, callback);
    }
    if (isMistralProvider(request.provider)) {
        return streamMistralChatData(io, allocator, env, request, callback_context, callback);
    }
    if (isBedrockProvider(request.provider)) {
        return streamBedrockConverseData(io, allocator, env, request, callback_context, callback);
    }
    if (isAzureOpenAIResponsesProvider(request.provider)) {
        return streamAzureOpenAIResponsesData(io, allocator, env, request, callback_context, callback);
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
    try checkCancellation(cancellationState(request));
    try request_handle.connection.?.flush();
    try checkCancellation(cancellationState(request));

    var response = try request_handle.receiveHead(&.{});
    try checkCancellation(cancellationState(request));
    if (@intFromEnum(response.head.status) < 200 or @intFromEnum(response.head.status) >= 300) {
        var transfer_buffer: [1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        return providerErrorForStatusAndReader(allocator, response.head.status, reader);
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    try readDoneTerminatedSseStream(reader, callback_context, callback, cancellationState(request));
}

fn readDoneTerminatedSseStream(
    reader: *std.Io.Reader,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
    cancellation: CancellationState,
) !void {
    var saw_done = false;
    while (true) {
        try checkCancellation(cancellation);
        const raw_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ProviderStreamIncomplete,
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
        try checkCancellation(cancellation);
    }
    if (!saw_done) return error.ProviderStreamIncomplete;
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

fn isGoogleVertexProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "google-vertex");
}

fn isMistralProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "mistral");
}

fn isBedrockProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "amazon-bedrock");
}

fn isAzureOpenAIResponsesProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "azure-openai-responses");
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
    try checkCancellation(cancellationState(request));

    const body = response_body.written();
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return providerErrorForStatusAndBody(result.status, body);
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
    try checkCancellation(cancellationState(request));
    try request_handle.connection.?.flush();
    try checkCancellation(cancellationState(request));

    var response = try request_handle.receiveHead(&.{});
    try checkCancellation(cancellationState(request));
    if (@intFromEnum(response.head.status) < 200 or @intFromEnum(response.head.status) >= 300) {
        var transfer_buffer: [1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        return providerErrorForStatusAndReader(allocator, response.head.status, reader);
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    try readAnthropicSseStream(allocator, reader, callback_context, callback, cancellationState(request));
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
    try checkCancellation(cancellationState(request));

    const body = response_body.written();
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return providerErrorForStatusAndBody(result.status, body);
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
    try checkCancellation(cancellationState(request));
    try request_handle.connection.?.flush();
    try checkCancellation(cancellationState(request));

    var response = try request_handle.receiveHead(&.{});
    try checkCancellation(cancellationState(request));
    if (@intFromEnum(response.head.status) < 200 or @intFromEnum(response.head.status) >= 300) {
        var transfer_buffer: [1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        return providerErrorForStatusAndReader(allocator, response.head.status, reader);
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    try readGoogleSseStream(reader, callback_context, callback, cancellationState(request));
}

fn runGoogleVertexGenerateContentTurn(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
) ChatCompletionError!ChatCompletionResult {
    const endpoint = try googleVertexGenerateContentEndpointForProvider(allocator, env, request.model, false);
    defer allocator.free(endpoint);

    const payload = try buildGoogleGenerateContentPayload(allocator, request);
    defer allocator.free(payload);

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const user_agent = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.app_name, config.version });
    defer allocator.free(user_agent);

    var auth_header = try googleVertexAuthHeader(allocator, env, request.api_key);
    defer auth_header.deinit(allocator);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var extra_headers_buf: [1]std.http.Header = undefined;
    const extra_headers = auth_header.extraHeaders(&extra_headers_buf);
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
    try checkCancellation(cancellationState(request));

    const body = response_body.written();
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return providerErrorForStatusAndBody(result.status, body);
    }

    return parseGoogleGenerateContentResult(allocator, body);
}

fn streamGoogleVertexGenerateContentData(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
) !void {
    const endpoint = try googleVertexGenerateContentEndpointForProvider(allocator, env, request.model, true);
    defer allocator.free(endpoint);

    const payload = try buildGoogleGenerateContentPayload(allocator, request);
    defer allocator.free(payload);

    const user_agent = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.app_name, config.version });
    defer allocator.free(user_agent);

    var auth_header = try googleVertexAuthHeader(allocator, env, request.api_key);
    defer auth_header.deinit(allocator);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const uri = try std.Uri.parse(endpoint);
    var extra_headers_buf: [1]std.http.Header = undefined;
    const extra_headers = auth_header.extraHeaders(&extra_headers_buf);
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
    try checkCancellation(cancellationState(request));
    try request_handle.connection.?.flush();
    try checkCancellation(cancellationState(request));

    var response = try request_handle.receiveHead(&.{});
    try checkCancellation(cancellationState(request));
    if (@intFromEnum(response.head.status) < 200 or @intFromEnum(response.head.status) >= 300) {
        var transfer_buffer: [1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        return providerErrorForStatusAndReader(allocator, response.head.status, reader);
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    try readGoogleSseStream(reader, callback_context, callback, cancellationState(request));
}

fn runAzureOpenAIResponsesTurn(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
) ChatCompletionError!ChatCompletionResult {
    const endpoint = azureOpenAIResponsesEndpoint(allocator, env, request.model) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedProvider => return error.UnsupportedProvider,
        else => return error.ProviderClientError,
    };
    defer allocator.free(endpoint);

    const payload = try buildAzureResponsesPayload(allocator, env, request, false);
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

    // Azure authenticates the Responses API with an `api-key` header, not a
    // Bearer authorization header (mirrors the AzureOpenAI SDK default).
    const extra_headers = [_]std.http.Header{
        .{ .name = "api-key", .value = request.api_key },
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
    try checkCancellation(cancellationState(request));

    const body = response_body.written();
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return providerErrorForStatusAndBody(result.status, body);
    }

    return parseOpenAIResponsesResult(allocator, body);
}

fn streamAzureOpenAIResponsesData(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
) !void {
    const endpoint = try azureOpenAIResponsesEndpoint(allocator, env, request.model);
    defer allocator.free(endpoint);

    const payload = try buildAzureResponsesPayload(allocator, env, request, true);
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
        .{ .name = "api-key", .value = request.api_key },
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
    try checkCancellation(cancellationState(request));
    try request_handle.connection.?.flush();
    try checkCancellation(cancellationState(request));

    var response = try request_handle.receiveHead(&.{});
    try checkCancellation(cancellationState(request));
    if (@intFromEnum(response.head.status) < 200 or @intFromEnum(response.head.status) >= 300) {
        var transfer_buffer: [1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        return providerErrorForStatusAndReader(allocator, response.head.status, reader);
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    try readDoneTerminatedSseStream(reader, callback_context, callback, cancellationState(request));
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
    try checkCancellation(cancellationState(request));

    const body = response_body.written();
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return providerErrorForStatusAndBody(result.status, body);
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
    try checkCancellation(cancellationState(request));
    try request_handle.connection.?.flush();
    try checkCancellation(cancellationState(request));

    var response = try request_handle.receiveHead(&.{});
    try checkCancellation(cancellationState(request));
    if (@intFromEnum(response.head.status) < 200 or @intFromEnum(response.head.status) >= 300) {
        var transfer_buffer: [1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        return providerErrorForStatusAndReader(allocator, response.head.status, reader);
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    try readDoneTerminatedSseStream(reader, callback_context, callback, cancellationState(request));
}

fn runBedrockConverseTurn(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
) ChatCompletionError!ChatCompletionResult {
    var accumulator = StreamChatAccumulator.init(allocator);
    errdefer accumulator.deinit();
    var result_context = StreamResultContext{
        .allocator = allocator,
        .accumulator = &accumulator,
        .text_callback_context = null,
        .text_callback = null,
    };
    streamBedrockConverseData(io, allocator, env, request, &result_context, handleStreamResultData) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedProvider => return error.UnsupportedProvider,
        error.ProviderClientError => return error.ProviderClientError,
        error.ProviderRequestFailed => return error.ProviderRequestFailed,
        error.ProviderResponseInvalid => return error.ProviderResponseInvalid,
        error.ProviderStreamIncomplete => return error.ProviderStreamIncomplete,
        else => return error.ProviderRequestFailed,
    };
    return accumulator.toResult() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProviderResponseInvalid,
    };
}

// === Amazon Bedrock authentication ============================================
//
// Bedrock supports two local credential paths, mirroring the AWS SDK precedence
// that upstream pi relies on:
//
//   1. Bearer token (AWS_BEARER_TOKEN_BEDROCK). When set, auth.zig resolves it as
//      the request api_key and we send `Authorization: Bearer <token>` unchanged.
//   2. IAM credentials (AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY, optional
//      AWS_SESSION_TOKEN). When no bearer token is present, auth.zig surfaces the
//      `<authenticated>` placeholder api_key and we sign the ConverseStream POST
//      with AWS Signature Version 4 (SigV4) using these environment credentials.
//
// Full ~/.aws/credentials profile resolution (AWS_PROFILE) and container/IMDS
// credential providers are SDK-only behaviors; the documented divergence is that
// pi-zig implements the equivalent SigV4 request signer over environment
// credentials rather than re-implementing the entire AWS credential chain.

const aws_sigv4_algorithm = "AWS4-HMAC-SHA256";
const aws_bedrock_service = "bedrock";
const aws_sigv4_request = "aws4_request";

const BedrockSigV4Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,
    region: []const u8,
};

const BedrockAuth = struct {
    // When set, the value passed to the standard `authorization` override header.
    authorization: []u8,
    // SigV4 requests carry these extra signed/unsigned headers; the bearer path
    // leaves them empty.
    amz_date: ?[]u8 = null,
    content_sha256: ?[]u8 = null,
    security_token: ?[]const u8 = null,

    fn deinit(self: *BedrockAuth, allocator: std.mem.Allocator) void {
        allocator.free(self.authorization);
        if (self.amz_date) |value| allocator.free(value);
        if (self.content_sha256) |value| allocator.free(value);
    }

    fn extraHeaders(self: BedrockAuth, buf: *[3]std.http.Header) []const std.http.Header {
        var len: usize = 0;
        if (self.amz_date) |value| {
            buf[len] = .{ .name = "x-amz-date", .value = value };
            len += 1;
        }
        if (self.content_sha256) |value| {
            buf[len] = .{ .name = "x-amz-content-sha256", .value = value };
            len += 1;
        }
        if (self.security_token) |value| {
            buf[len] = .{ .name = "x-amz-security-token", .value = value };
            len += 1;
        }
        return buf[0..len];
    }
};

/// True when the resolved Bedrock api_key is the ambient `<authenticated>`
/// placeholder (or empty), which signals "no bearer token — use SigV4".
fn isBedrockPlaceholderApiKey(api_key: []const u8) bool {
    const trimmed = std.mem.trim(u8, api_key, " \t\r\n");
    if (trimmed.len == 0) return true;
    return std.mem.eql(u8, trimmed, "<authenticated>");
}

fn bedrockRegion(env: *const std.process.Environ.Map) []const u8 {
    return env.get("AWS_REGION") orelse env.get("AWS_DEFAULT_REGION") orelse "us-east-1";
}

fn bedrockSigV4CredentialsFromEnv(env: *const std.process.Environ.Map) ?BedrockSigV4Credentials {
    const access_key_id = env.get("AWS_ACCESS_KEY_ID") orelse return null;
    const secret_access_key = env.get("AWS_SECRET_ACCESS_KEY") orelse return null;
    if (std.mem.trim(u8, access_key_id, " \t\r\n").len == 0) return null;
    if (std.mem.trim(u8, secret_access_key, " \t\r\n").len == 0) return null;
    var session_token: ?[]const u8 = null;
    if (env.get("AWS_SESSION_TOKEN")) |token| {
        if (std.mem.trim(u8, token, " \t\r\n").len > 0) session_token = token;
    }
    return .{
        .access_key_id = access_key_id,
        .secret_access_key = secret_access_key,
        .session_token = session_token,
        .region = bedrockRegion(env),
    };
}

fn bedrockAuth(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    uri: std.Uri,
    api_key: []const u8,
    payload: []const u8,
) !BedrockAuth {
    if (!isBedrockPlaceholderApiKey(api_key)) {
        // Existing bearer-token path. Keep behavior identical to before.
        return .{ .authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) };
    }
    const credentials = bedrockSigV4CredentialsFromEnv(env) orelse {
        // No bearer token and no IAM credentials: surface a client error rather
        // than sending an empty `Bearer <authenticated>` header that would 4xx.
        return error.ProviderClientError;
    };
    return signBedrockSigV4(allocator, uri, credentials, payload, bedrockSigV4Timestamp(io));
}

const AwsTimestamp = struct {
    // YYYYMMDDTHHMMSSZ
    amz_date: [16]u8,
    // YYYYMMDD
    date_stamp: [8]u8,
};

fn bedrockSigV4Timestamp(io: std.Io) AwsTimestamp {
    const seconds = std.Io.Clock.real.now(io).toSeconds();
    const secs: u64 = if (seconds > 0) @intCast(seconds) else 0;
    return awsTimestampFromUnixSeconds(secs);
}

fn awsTimestampFromUnixSeconds(unix_seconds: u64) AwsTimestamp {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = unix_seconds };
    const day_seconds = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year: u16 = year_day.year;
    const month: u8 = month_day.month.numeric();
    const day: u8 = month_day.day_index + 1;
    const hour: u8 = day_seconds.getHoursIntoDay();
    const minute: u8 = day_seconds.getMinutesIntoHour();
    const second: u8 = day_seconds.getSecondsIntoMinute();

    var ts: AwsTimestamp = undefined;
    _ = std.fmt.bufPrint(&ts.date_stamp, "{d:0>4}{d:0>2}{d:0>2}", .{ year, month, day }) catch unreachable;
    _ = std.fmt.bufPrint(&ts.amz_date, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ year, month, day, hour, minute, second }) catch unreachable;
    return ts;
}

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

fn sha256Hex(input: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn hmacSha256(key: []const u8, msg: []const u8) [HmacSha256.mac_length]u8 {
    var out: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&out, msg, key);
    return out;
}

/// AWS URI-encode per RFC 3986: only A-Z a-z 0-9 - . _ ~ stay literal; when
/// `keep_slash` is true (path segments) the '/' separator is also preserved.
fn writeAwsUriEncoded(w: *std.Io.Writer, value: []const u8, keep_slash: bool) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(byte),
            '/' => {
                if (keep_slash) {
                    try w.writeByte('/');
                } else {
                    try w.writeAll("%2F");
                }
            },
            else => {
                try w.writeByte('%');
                try w.writeByte(hex[byte >> 4]);
                try w.writeByte(hex[byte & 0x0f]);
            },
        }
    }
}

/// Compute the host header value exactly as std.http.Client emits it, i.e. the
/// URI authority (host plus ":port" for non-default ports). The signature must
/// cover the same bytes the client puts on the wire.
fn awsHostHeaderValue(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try uri.writeToStream(&out.writer, .{ .authority = true });
    return out.toOwnedSlice();
}

/// Canonical URI path component, AWS URI-encoded (segment-by-segment). An empty
/// path canonicalizes to "/".
fn awsCanonicalUriPath(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    // Decode the path to raw bytes, then re-encode per AWS rules. The endpoint
    // builder already percent-encodes ':' as %3A; round-tripping through the raw
    // form keeps a single, canonical encoding regardless of input casing.
    var raw_buf: std.Io.Writer.Allocating = .init(allocator);
    defer raw_buf.deinit();
    try uri.path.formatRaw(&raw_buf.writer);
    const raw_path = raw_buf.written();

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    if (raw_path.len == 0) {
        try out.writer.writeByte('/');
    } else {
        try writeAwsUriEncoded(&out.writer, raw_path, true);
    }
    return out.toOwnedSlice();
}

fn awsCanonicalQueryString(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    const query = uri.query orelse return allocator.dupe(u8, "");
    var raw_buf: std.Io.Writer.Allocating = .init(allocator);
    defer raw_buf.deinit();
    try query.formatRaw(&raw_buf.writer);
    const raw_query = raw_buf.written();
    if (raw_query.len == 0) return allocator.dupe(u8, "");

    // Split on '&', then on the first '=', AWS-encode each side, sort by encoded
    // key. ConverseStream uses no query parameters, so this stays simple but is
    // implemented for canonical-request correctness.
    const Pair = struct { key: []u8, value: []u8 };
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    defer {
        for (pairs.items) |pair| {
            allocator.free(pair.key);
            allocator.free(pair.value);
        }
        pairs.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, raw_query, '&');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=');
        const raw_key = if (eq) |i| part[0..i] else part;
        const raw_value = if (eq) |i| part[i + 1 ..] else "";

        var key_buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer key_buf.deinit();
        try writeAwsUriEncoded(&key_buf.writer, raw_key, false);
        var value_buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer value_buf.deinit();
        try writeAwsUriEncoded(&value_buf.writer, raw_value, false);
        try pairs.append(allocator, .{ .key = try key_buf.toOwnedSlice(), .value = try value_buf.toOwnedSlice() });
    }

    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (pairs.items, 0..) |pair, index| {
        if (index != 0) try out.writer.writeByte('&');
        try out.writer.writeAll(pair.key);
        try out.writer.writeByte('=');
        try out.writer.writeAll(pair.value);
    }
    return out.toOwnedSlice();
}

const BedrockSigV4Inputs = struct {
    canonical_request: []u8,
    string_to_sign: []u8,
    signature_hex: [HmacSha256.mac_length * 2]u8,
    authorization: []u8,

    fn deinit(self: *BedrockSigV4Inputs, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_request);
        allocator.free(self.string_to_sign);
        allocator.free(self.authorization);
    }
};

/// Generic SigV4 signer over a fully-built canonical-headers block. This is the
/// algorithm core (canonical request -> string-to-sign -> signing key ->
/// signature) shared by Bedrock and exercised directly by unit tests against the
/// published AWS SigV4 test-suite vectors. No secret material is ever logged.
fn awsSigV4SignCanonical(
    allocator: std.mem.Allocator,
    method: []const u8,
    canonical_uri: []const u8,
    canonical_query: []const u8,
    canonical_headers: []const u8,
    signed_headers: []const u8,
    payload_hash: []const u8,
    access_key_id: []const u8,
    secret_access_key: []const u8,
    region: []const u8,
    service: []const u8,
    amz_date: []const u8,
    date_stamp: []const u8,
) !BedrockSigV4Inputs {
    var canonical_request_buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer canonical_request_buf.deinit();
    try canonical_request_buf.writer.print("{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        method,
        canonical_uri,
        canonical_query,
        canonical_headers,
        signed_headers,
        payload_hash,
    });
    const canonical_request = try canonical_request_buf.toOwnedSlice();
    errdefer allocator.free(canonical_request);

    const canonical_request_hash = sha256Hex(canonical_request);

    // credential scope: <date>/<region>/<service>/aws4_request
    var scope_buf: std.Io.Writer.Allocating = .init(allocator);
    defer scope_buf.deinit();
    try scope_buf.writer.print("{s}/{s}/{s}/{s}", .{ date_stamp, region, service, aws_sigv4_request });
    const credential_scope = scope_buf.written();

    var string_to_sign_buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer string_to_sign_buf.deinit();
    try string_to_sign_buf.writer.print("{s}\n{s}\n{s}\n{s}", .{
        aws_sigv4_algorithm,
        amz_date,
        credential_scope,
        canonical_request_hash[0..],
    });
    const string_to_sign = try string_to_sign_buf.toOwnedSlice();
    errdefer allocator.free(string_to_sign);

    // Derive the signing key: HMAC chain date -> region -> service -> aws4_request.
    var initial_key_buf: [4 + 256]u8 = undefined;
    const initial_key = std.fmt.bufPrint(&initial_key_buf, "AWS4{s}", .{secret_access_key}) catch return error.ProviderClientError;
    const k_date = hmacSha256(initial_key, date_stamp);
    const k_region = hmacSha256(k_date[0..], region);
    const k_service = hmacSha256(k_region[0..], service);
    const k_signing = hmacSha256(k_service[0..], aws_sigv4_request);
    const signature = hmacSha256(k_signing[0..], string_to_sign);
    const signature_hex = std.fmt.bytesToHex(signature, .lower);

    var authorization_buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer authorization_buf.deinit();
    try authorization_buf.writer.print("{s} Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{
        aws_sigv4_algorithm,
        access_key_id,
        credential_scope,
        signed_headers,
        signature_hex[0..],
    });
    const authorization = try authorization_buf.toOwnedSlice();

    return .{
        .canonical_request = canonical_request,
        .string_to_sign = string_to_sign,
        .signature_hex = signature_hex,
        .authorization = authorization,
    };
}

/// Build the SigV4 canonical request, string-to-sign, signing key, and the final
/// Authorization header for a Bedrock POST. Pure/deterministic given its inputs
/// so it can be exercised by unit tests against published AWS vectors without
/// touching the network. No secret material is ever written to logs.
fn computeBedrockSigV4(
    allocator: std.mem.Allocator,
    method: []const u8,
    canonical_uri: []const u8,
    canonical_query: []const u8,
    host_header: []const u8,
    payload: []const u8,
    credentials: BedrockSigV4Credentials,
    timestamp: AwsTimestamp,
    service: []const u8,
) !BedrockSigV4Inputs {
    const payload_hash = sha256Hex(payload);

    // Canonical headers: lowercase name, trimmed value, sorted by name. We sign
    // content-type, host, x-amz-content-sha256, x-amz-date and (when present)
    // x-amz-security-token — the deterministic subset pi-zig controls.
    var signed_headers_buf: std.Io.Writer.Allocating = .init(allocator);
    defer signed_headers_buf.deinit();
    var canonical_headers_buf: std.Io.Writer.Allocating = .init(allocator);
    defer canonical_headers_buf.deinit();

    try canonical_headers_buf.writer.print("content-type:application/json\nhost:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n", .{ host_header, payload_hash[0..], timestamp.amz_date[0..] });
    if (credentials.session_token != null) {
        try canonical_headers_buf.writer.print("x-amz-security-token:{s}\n", .{credentials.session_token.?});
        try signed_headers_buf.writer.writeAll("content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token");
    } else {
        try signed_headers_buf.writer.writeAll("content-type;host;x-amz-content-sha256;x-amz-date");
    }

    return awsSigV4SignCanonical(
        allocator,
        method,
        canonical_uri,
        canonical_query,
        canonical_headers_buf.written(),
        signed_headers_buf.written(),
        payload_hash[0..],
        credentials.access_key_id,
        credentials.secret_access_key,
        credentials.region,
        service,
        timestamp.amz_date[0..],
        timestamp.date_stamp[0..],
    );
}

fn signBedrockSigV4(
    allocator: std.mem.Allocator,
    uri: std.Uri,
    credentials: BedrockSigV4Credentials,
    payload: []const u8,
    timestamp: AwsTimestamp,
) !BedrockAuth {
    const host_header = try awsHostHeaderValue(allocator, uri);
    defer allocator.free(host_header);
    const canonical_uri = try awsCanonicalUriPath(allocator, uri);
    defer allocator.free(canonical_uri);
    const canonical_query = try awsCanonicalQueryString(allocator, uri);
    defer allocator.free(canonical_query);

    const inputs = try computeBedrockSigV4(
        allocator,
        "POST",
        canonical_uri,
        canonical_query,
        host_header,
        payload,
        credentials,
        timestamp,
        aws_bedrock_service,
    );
    // We only keep the Authorization header and the amz headers; the canonical
    // request/string-to-sign are intermediate and freed here.
    defer {
        allocator.free(inputs.canonical_request);
        allocator.free(inputs.string_to_sign);
    }

    const amz_date = try allocator.dupe(u8, timestamp.amz_date[0..]);
    errdefer allocator.free(amz_date);
    const content_sha256 = try sha256HexAlloc(allocator, payload);
    errdefer allocator.free(content_sha256);

    return .{
        .authorization = inputs.authorization,
        .amz_date = amz_date,
        .content_sha256 = content_sha256,
        .security_token = credentials.session_token,
    };
}

fn sha256HexAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const hex = sha256Hex(input);
    return allocator.dupe(u8, hex[0..]);
}

fn streamBedrockConverseData(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
) !void {
    const endpoint = try bedrockConverseStreamEndpointForProvider(allocator, env, request.model);
    defer allocator.free(endpoint);

    const payload = try buildBedrockConversePayload(allocator, request);
    defer allocator.free(payload);

    const user_agent = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.app_name, config.version });
    defer allocator.free(user_agent);

    const uri = try std.Uri.parse(endpoint);

    // Resolve Bedrock auth: prefer a bearer token when one was supplied as the
    // api_key (AWS_BEARER_TOKEN_BEDROCK path), otherwise sign the request with
    // AWS Signature Version 4 using IAM credentials from the environment.
    var auth = try bedrockAuth(io, allocator, env, uri, request.api_key, payload);
    defer auth.deinit(allocator);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var extra_headers_buf: [3]std.http.Header = undefined;
    const extra_headers = auth.extraHeaders(&extra_headers_buf);
    var request_handle = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = .{ .override = auth.authorization },
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
    try checkCancellation(cancellationState(request));
    try request_handle.connection.?.flush();
    try checkCancellation(cancellationState(request));

    var response = try request_handle.receiveHead(&.{});
    try checkCancellation(cancellationState(request));
    if (@intFromEnum(response.head.status) < 200 or @intFromEnum(response.head.status) >= 300) {
        var transfer_buffer: [1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        return providerErrorForStatusAndReader(allocator, response.head.status, reader);
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    try readBedrockEventStream(allocator, reader, callback_context, callback, cancellationState(request));
}

const AnthropicAuthHeader = struct {
    authorization: ?[]u8 = null,
    oauth: bool = false,

    fn deinit(self: *AnthropicAuthHeader, allocator: std.mem.Allocator) void {
        if (self.authorization) |value| allocator.free(value);
    }
};

fn anthropicAuthHeader(allocator: std.mem.Allocator, api_key: []const u8) !AnthropicAuthHeader {
    if (isAnthropicOAuthToken(api_key)) {
        return .{
            .authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}),
            .oauth = true,
        };
    }
    return .{};
}

fn isAnthropicOAuthToken(api_key: []const u8) bool {
    // Mirror upstream `isOAuthToken` (packages/ai/src/providers/anthropic.ts):
    // OAuth access tokens contain "sk-ant-oat" anywhere, not only as a prefix.
    return std.mem.indexOf(u8, api_key, "sk-ant-oat") != null;
}

fn anthropicExtraHeaders(buf: *[5]std.http.Header, api_key: []const u8, oauth: bool) []const std.http.Header {
    var len: usize = 0;
    buf[len] = .{ .name = "anthropic-version", .value = "2023-06-01" };
    len += 1;
    if (oauth) {
        // Upstream OAuth clients send the Claude Code identity beta alongside the
        // OAuth beta: anthropic-beta: claude-code-20250219,oauth-2025-04-20
        buf[len] = .{ .name = "anthropic-beta", .value = "claude-code-20250219,oauth-2025-04-20" };
        len += 1;
        buf[len] = .{ .name = "x-app", .value = "cli" };
        len += 1;
    } else {
        buf[len] = .{ .name = "x-api-key", .value = api_key };
        len += 1;
    }
    return buf[0..len];
}

const GoogleVertexAuthHeader = struct {
    api_key: ?[]const u8 = null,
    authorization: ?[]u8 = null,

    fn deinit(self: *GoogleVertexAuthHeader, allocator: std.mem.Allocator) void {
        if (self.authorization) |value| allocator.free(value);
    }

    fn extraHeaders(self: GoogleVertexAuthHeader, buf: *[1]std.http.Header) []const std.http.Header {
        if (self.api_key) |api_key| {
            buf[0] = .{ .name = "x-goog-api-key", .value = api_key };
            return buf[0..1];
        }
        return buf[0..0];
    }
};

fn googleVertexAuthHeader(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    api_key: []const u8,
) !GoogleVertexAuthHeader {
    if (isGoogleVertexOAuthAccessToken(api_key)) {
        return .{ .authorization = try googleVertexBearerHeader(allocator, api_key) };
    }
    if (!isGoogleVertexPlaceholderApiKey(api_key)) {
        return .{ .api_key = api_key };
    }
    if (env.get("GOOGLE_CLOUD_ACCESS_TOKEN")) |access_token| {
        const trimmed = std.mem.trim(u8, access_token, " \t\r\n");
        if (trimmed.len > 0) {
            return .{ .authorization = try googleVertexBearerHeader(allocator, trimmed) };
        }
    }
    return error.ProviderClientError;
}

fn googleVertexBearerHeader(allocator: std.mem.Allocator, access_token: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, access_token, " \t\r\n");
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{trimmed});
}

fn isGoogleVertexOAuthAccessToken(api_key: []const u8) bool {
    const trimmed = std.mem.trim(u8, api_key, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "ya29.");
}

fn isGoogleVertexPlaceholderApiKey(api_key: []const u8) bool {
    return std.mem.eql(u8, api_key, "<authenticated>") or
        std.mem.eql(u8, api_key, "gcp-vertex-credentials") or
        (api_key.len >= 2 and api_key[0] == '<' and api_key[api_key.len - 1] == '>');
}

// === Image generation request/response =======================================

const ImageGenerationError = error{
    UnsupportedProvider,
    ProviderClientError,
    ProviderRequestFailed,
    ProviderResponseInvalid,
    EmptyPrompt,
} || std.mem.Allocator.Error || std.http.Client.FetchError;

/// Run an OpenRouter image-generation request. Mirrors upstream
/// generateImagesOpenRouter: POST the chat-completions shape with a
/// `modalities` array, then parse `choices[0].message.images[]` data URLs (plus
/// any leading text) into image/text content parts.
pub fn runImageGeneration(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ImageGenerationRequest,
) ImageGenerationError!ImageGenerationResult {
    if (!isOpenRouterImagesProvider(request.provider)) return error.UnsupportedProvider;

    const endpoint = try imageGenerationEndpointForProvider(allocator, env, request.provider);
    defer allocator.free(endpoint);

    const payload = try buildOpenRouterImagesPayload(allocator, request);
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
        const code = @intFromEnum(result.status);
        return if (code == 429 or code >= 500) error.ProviderRequestFailed else error.ProviderClientError;
    }

    return parseOpenRouterImagesResult(allocator, body);
}

fn isOpenRouterImagesProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "openrouter") or std.mem.eql(u8, provider, "openrouter-images");
}

fn imageGenerationEndpointForProvider(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    provider: []const u8,
) ![]u8 {
    if (env.get("PI_ZIG_IMAGES_BASE_URL")) |base_url| {
        return endpointFromBaseUrl(allocator, base_url);
    }
    if (env.get("PI_ZIG_PROVIDER_BASE_URL")) |base_url| {
        return endpointFromBaseUrl(allocator, base_url);
    }
    if (isOpenRouterImagesProvider(provider)) {
        return allocator.dupe(u8, "https://openrouter.ai/api/v1/chat/completions");
    }
    return error.UnsupportedProvider;
}

/// Build the OpenRouter images request body. Equivalent to upstream buildParams:
/// a single user message whose content is the text/image input parts, with
/// `stream:false` and a `modalities` array.
fn buildOpenRouterImagesPayload(allocator: std.mem.Allocator, request: ImageGenerationRequest) ![]u8 {
    var has_prompt = false;
    for (request.input) |part| {
        switch (part) {
            .text => |text| if (std.mem.trim(u8, text, " \t\r\n").len > 0) {
                has_prompt = true;
            },
            .image => has_prompt = true,
        }
    }
    if (!has_prompt) return error.EmptyPrompt;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"model\":");
    try writeJsonString(w, request.model);
    try w.writeAll(",\"messages\":[{\"role\":\"user\",\"content\":");
    // OpenRouter images always sends content as an array of parts (never the
    // bare-string shortcut), matching upstream's ChatCompletionContentPart[].
    try writeContentParts(w, request.input, null);
    try w.writeAll("}],\"stream\":false,\"modalities\":");
    if (request.include_text) {
        try w.writeAll("[\"image\",\"text\"]");
    } else {
        try w.writeAll("[\"image\"]");
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// Parse an OpenRouter images response. Equivalent to the upstream output loop:
/// pull `choices[0].message.content` (text) and each `choices[0].message.images[]`
/// entry whose `image_url` is a `data:<mime>;base64,<data>` URL.
fn parseOpenRouterImagesResult(allocator: std.mem.Allocator, body: []const u8) !ImageGenerationResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderResponseInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ProviderResponseInvalid;

    var output: std.ArrayList(GeneratedImagePart) = .empty;
    errdefer {
        for (output.items) |part| part.deinit(allocator);
        output.deinit(allocator);
    }

    var result: ImageGenerationResult = .{};
    errdefer result.deinit(allocator);

    if (parsed.value.object.get("id")) |id| {
        if (id == .string) result.response_id = try allocator.dupe(u8, id.string);
    }

    const choices = parsed.value.object.get("choices") orelse return error.ProviderResponseInvalid;
    if (choices != .array) return error.ProviderResponseInvalid;
    if (choices.array.items.len == 0) {
        result.output = try output.toOwnedSlice(allocator);
        return result;
    }

    const first = choices.array.items[0];
    if (first != .object) return error.ProviderResponseInvalid;
    const message = first.object.get("message") orelse return error.ProviderResponseInvalid;
    if (message != .object) return error.ProviderResponseInvalid;

    if (message.object.get("content")) |content| {
        if (content == .string and content.string.len > 0) {
            const text = try allocator.dupe(u8, content.string);
            errdefer allocator.free(text);
            try output.append(allocator, .{ .text = text });
        }
    }

    if (message.object.get("images")) |images| {
        if (images == .array) {
            for (images.array.items) |image| {
                if (image != .object) continue;
                const image_url_value = image.object.get("image_url") orelse continue;
                const url = switch (image_url_value) {
                    .string => |s| s,
                    .object => |obj| blk: {
                        const url_field = obj.get("url") orelse continue;
                        if (url_field != .string) continue;
                        break :blk url_field.string;
                    },
                    else => continue,
                };
                const decoded = parseBase64DataUrl(url) orelse continue;
                const mime = try allocator.dupe(u8, decoded.mime_type);
                errdefer allocator.free(mime);
                const data = try allocator.dupe(u8, decoded.data);
                errdefer allocator.free(data);
                try output.append(allocator, .{ .image = .{ .mime_type = mime, .data = data } });
            }
        }
    }

    result.output = try output.toOwnedSlice(allocator);
    return result;
}

/// Split `data:<mime>;base64,<payload>` into its mime type and base64 payload,
/// matching upstream's `/^data:([^;]+);base64,(.+)$/`. Returns null for any URL
/// that is not a base64 data URL.
fn parseBase64DataUrl(url: []const u8) ?ChatImageContent {
    const prefix = "data:";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const after_prefix = url[prefix.len..];
    const semicolon = std.mem.indexOfScalar(u8, after_prefix, ';') orelse return null;
    const mime = after_prefix[0..semicolon];
    if (mime.len == 0) return null;
    const marker = ";base64,";
    if (!std.mem.startsWith(u8, url[prefix.len + semicolon ..], marker)) return null;
    const data = url[prefix.len + semicolon + marker.len ..];
    if (data.len == 0) return null;
    return .{ .mime_type = mime, .data = data };
}

// === Image resize (system-tool shell-out) =====================================
//
// Documented divergence from upstream's resize worker: Zig 0.16 has no built-in
// image codec, so an in-process decode/scale/encode is not feasible. The honest
// equivalent is to shell out to a system image tool when one is present:
//
//   * macOS:        `sips` (always available on macOS).
//   * ImageMagick:  `magick` (v7) or `convert` (v6), when installed.
//
// When NO such tool is available the request is not silently "succeeded": the
// caller receives `error.ResizeToolUnavailable` and can skip the resize step,
// exactly like the smoke harness does on CI runners without an image tool.

pub const ResizeError = error{
    ResizeToolUnavailable,
    ResizeFailed,
    InvalidImageData,
} || std.mem.Allocator.Error;

pub const ResizeTool = enum { sips, magick, convert };

pub const ResizedImage = struct {
    tool: ResizeTool,
    image: ChatImageContent, // mime_type + base64 data, both owned by caller

    pub fn deinit(self: ResizedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.image.data);
        allocator.free(self.image.mime_type);
    }
};

/// Probe for an available system image tool by running its version command.
/// Returns null when neither sips, magick, nor convert can be executed.
pub fn detectResizeTool(io: std.Io, allocator: std.mem.Allocator) ?ResizeTool {
    const candidates = [_]struct { tool: ResizeTool, argv: []const []const u8 }{
        .{ .tool = .sips, .argv = &.{ "sips", "--version" } },
        .{ .tool = .magick, .argv = &.{ "magick", "--version" } },
        .{ .tool = .convert, .argv = &.{ "convert", "--version" } },
    };
    for (candidates) |candidate| {
        const run_result = std.process.run(allocator, io, .{
            .argv = candidate.argv,
            .expand_arg0 = .expand,
        }) catch continue;
        allocator.free(run_result.stdout);
        allocator.free(run_result.stderr);
        switch (run_result.term) {
            .exited => |code| if (code == 0) return candidate.tool,
            else => {},
        }
    }
    return null;
}

/// Re-encode `image` downscaled so its longest side is at most `max_dimension`
/// pixels, using whichever system tool `detectResizeTool` finds. The image is
/// written to a temp file, resized in place by the tool, and re-read + re-encoded
/// to base64. Returns `error.ResizeToolUnavailable` when no tool exists so the
/// caller can cleanly skip rather than fake a result.
pub fn resizeImageWithSystemTool(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    image: ChatImageContent,
    max_dimension: u32,
) ResizeError!ResizedImage {
    const tool = detectResizeTool(io, allocator) orelse return error.ResizeToolUnavailable;
    return resizeImageWithTool(io, allocator, env, tool, image, max_dimension);
}

fn imageExtensionForMime(mime_type: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(mime_type, "image/png")) return "png";
    if (std.ascii.eqlIgnoreCase(mime_type, "image/jpeg") or std.ascii.eqlIgnoreCase(mime_type, "image/jpg")) return "jpg";
    if (std.ascii.eqlIgnoreCase(mime_type, "image/webp")) return "webp";
    if (std.ascii.eqlIgnoreCase(mime_type, "image/gif")) return "gif";
    return "png";
}

fn resizeImageWithTool(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    tool: ResizeTool,
    image: ChatImageContent,
    max_dimension: u32,
) ResizeError!ResizedImage {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(image.data) catch return error.InvalidImageData;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    decoder.decode(decoded, image.data) catch return error.InvalidImageData;

    const ext = imageExtensionForMime(image.mime_type);

    // Unique temp directory under the system temp root. The tool reads and
    // re-writes the same absolute path in place, so no realpath() is needed. The
    // unique suffix is seeded from the real-time clock + a PRNG draw so parallel
    // resizes never collide.
    const tmp_root = systemTempRoot(env);
    const nanos: u96 = @bitCast(std.Io.Clock.real.now(io).toNanoseconds());
    const seed: u64 = @truncate(nanos);
    var prng = std.Random.DefaultPrng.init(seed);
    var random_bytes: [12]u8 = undefined;
    prng.random().bytes(&random_bytes);
    var random_hex: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&random_hex, "{x}", .{&random_bytes}) catch unreachable;

    const dir_path = std.fmt.allocPrint(allocator, "{s}/pi-zig-resize-{s}", .{ tmp_root, random_hex }) catch return error.OutOfMemory;
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch return error.ResizeFailed;
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    const in_path = std.fmt.allocPrint(allocator, "{s}/in.{s}", .{ dir_path, ext }) catch return error.OutOfMemory;
    defer allocator.free(in_path);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = in_path, .data = decoded }) catch return error.ResizeFailed;

    const max_str = std.fmt.allocPrint(allocator, "{d}", .{max_dimension}) catch return error.OutOfMemory;
    defer allocator.free(max_str);

    // For sips the output overwrites the input file in place. For ImageMagick we
    // pass the same path as input and output (`magick in -resize WxH> in`).
    const geometry = std.fmt.allocPrint(allocator, "{d}x{d}>", .{ max_dimension, max_dimension }) catch return error.OutOfMemory;
    defer allocator.free(geometry);

    const argv: []const []const u8 = switch (tool) {
        .sips => &.{ "sips", "-Z", max_str, in_path },
        .magick => &.{ "magick", in_path, "-resize", geometry, in_path },
        .convert => &.{ "convert", in_path, "-resize", geometry, in_path },
    };

    const run_result = std.process.run(allocator, io, .{
        .argv = argv,
        .expand_arg0 = .expand,
    }) catch return error.ResizeFailed;
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);
    switch (run_result.term) {
        .exited => |code| if (code != 0) return error.ResizeFailed,
        else => return error.ResizeFailed,
    }

    const resized_bytes = std.Io.Dir.cwd().readFileAlloc(io, in_path, allocator, .unlimited) catch return error.ResizeFailed;
    defer allocator.free(resized_bytes);
    if (resized_bytes.len == 0) return error.ResizeFailed;

    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(resized_bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);
    _ = encoder.encode(encoded, resized_bytes);

    const mime = try allocator.dupe(u8, image.mime_type);
    return .{ .tool = tool, .image = .{ .mime_type = mime, .data = encoded } };
}

fn systemTempRoot(env: *const std.process.Environ.Map) []const u8 {
    if (env.get("TMPDIR")) |value| {
        var end = value.len;
        while (end > 0 and value[end - 1] == '/') end -= 1;
        if (end > 0) return value[0..end];
    }
    return "/tmp";
}

// === Azure OpenAI Responses deployment routing ================================
//
// Mirrors azure-openai-responses.ts: an Azure-configured request must hit
//   <baseUrl>/deployments/<deployment>/responses?api-version=<version>
// where baseUrl is either AZURE_OPENAI_BASE_URL, derived from
// AZURE_OPENAI_RESOURCE_NAME (https://<resource>.openai.azure.com/openai/v1), or
// PI_ZIG_PROVIDER_BASE_URL (test/override). The deployment name is resolved from
// AZURE_OPENAI_DEPLOYMENT_NAME_MAP ("modelId=deployment,...") falling back to the
// model id, and the api-version defaults to AZURE_OPENAI_API_VERSION or "v1".

const azure_default_api_version = "v1";

/// Resolve the deployment name for `model` from AZURE_OPENAI_DEPLOYMENT_NAME_MAP
/// ("modelA=deployA,modelB=deployB"), falling back to the model id when unmapped.
fn azureResolveDeploymentName(env: *const std.process.Environ.Map, model: []const u8) []const u8 {
    const map = env.get("AZURE_OPENAI_DEPLOYMENT_NAME_MAP") orelse return model;
    var entries = std.mem.splitScalar(u8, map, ',');
    while (entries.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const model_id = std.mem.trim(u8, trimmed[0..eq], " \t\r\n");
        const deployment = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\r\n");
        if (model_id.len == 0 or deployment.len == 0) continue;
        if (std.mem.eql(u8, model_id, model)) return deployment;
    }
    return model;
}

fn azureApiVersion(env: *const std.process.Environ.Map) []const u8 {
    if (env.get("AZURE_OPENAI_API_VERSION")) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return azure_default_api_version;
}

/// Resolve the Azure base URL (without trailing slash). Precedence matches
/// upstream resolveAzureConfig: explicit base URL > resource name > test
/// override. Caller owns the returned slice.
fn azureResolveBaseUrl(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("AZURE_OPENAI_BASE_URL")) |base_url| {
        const trimmed = std.mem.trim(u8, base_url, " \t\r\n");
        if (trimmed.len > 0) return trimAndDupeTrailingSlashes(allocator, trimmed);
    }
    if (env.get("AZURE_OPENAI_RESOURCE_NAME")) |resource_name| {
        const trimmed = std.mem.trim(u8, resource_name, " \t\r\n");
        if (trimmed.len > 0) {
            return std.fmt.allocPrint(allocator, "https://{s}.openai.azure.com/openai/v1", .{trimmed});
        }
    }
    if (env.get("PI_ZIG_PROVIDER_BASE_URL")) |base_url| {
        const trimmed = std.mem.trim(u8, base_url, " \t\r\n");
        if (trimmed.len > 0) return trimAndDupeTrailingSlashes(allocator, trimmed);
    }
    return error.UnsupportedProvider;
}

fn trimAndDupeTrailingSlashes(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') end -= 1;
    return allocator.dupe(u8, value[0..end]);
}

/// Build the Azure OpenAI Responses endpoint:
/// `<baseUrl>/deployments/<deployment>/responses?api-version=<version>`.
fn azureOpenAIResponsesEndpoint(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    model: []const u8,
) ![]u8 {
    const base_url = try azureResolveBaseUrl(allocator, env);
    defer allocator.free(base_url);
    const deployment = azureResolveDeploymentName(env, model);
    const api_version = azureApiVersion(env);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(base_url);
    try out.writer.writeAll("/deployments/");
    try writeUriPathSegment(&out.writer, deployment);
    try out.writer.writeAll("/responses?api-version=");
    try writeUriQueryComponent(&out.writer, api_version);
    return out.toOwnedSlice();
}

fn writeUriQueryComponent(w: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(byte),
            else => {
                try w.writeByte('%');
                try w.writeByte(hex[byte >> 4]);
                try w.writeByte(hex[byte & 0x0f]);
            },
        }
    }
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

fn googleVertexGenerateContentEndpointForProvider(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    model: []const u8,
    stream: bool,
) ![]u8 {
    const base_url = env.get("PI_ZIG_PROVIDER_BASE_URL") orelse env.get("GOOGLE_VERTEX_BASE_URL") orelse "https://aiplatform.googleapis.com";
    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') end -= 1;
    const trimmed = base_url[0..end];
    const action = if (stream) "streamGenerateContent?alt=sse" else "generateContent";

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(trimmed);
    if (!baseUrlPathHasApiVersion(trimmed)) try out.writer.writeAll("/v1");
    try out.writer.writeByte('/');
    try writeGoogleVertexModelResource(&out.writer, env, model);
    try out.writer.print(":{s}", .{action});
    return out.toOwnedSlice();
}

fn baseUrlPathHasApiVersion(base_url: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, base_url, "://");
    const path_start = if (scheme_end) |index|
        (std.mem.indexOfScalarPos(u8, base_url, index + 3, '/') orelse return false)
    else
        (std.mem.indexOfScalar(u8, base_url, '/') orelse return false);
    var segments = std.mem.splitScalar(u8, base_url[path_start + 1 ..], '/');
    while (segments.next()) |segment| {
        if (segment.len >= 2 and segment[0] == 'v' and isAllDigits(segment[1..])) return true;
        if (segment.len >= 6 and std.mem.startsWith(u8, segment, "v") and std.mem.indexOf(u8, segment, "beta") != null) return true;
    }
    return false;
}

fn isAllDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

fn writeGoogleVertexModelResource(
    w: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    model: []const u8,
) !void {
    if (std.mem.startsWith(u8, model, "projects/") or std.mem.startsWith(u8, model, "publishers/")) {
        return writeUriPathPreservingSlashes(w, model);
    }
    const project = env.get("GOOGLE_CLOUD_PROJECT") orelse env.get("GCLOUD_PROJECT");
    const location = env.get("GOOGLE_CLOUD_LOCATION");
    if (project) |project_id| {
        if (location) |location_id| {
            try w.writeAll("projects/");
            try writeUriPathSegment(w, project_id);
            try w.writeAll("/locations/");
            try writeUriPathSegment(w, location_id);
            try w.writeAll("/publishers/google/models/");
            try writeUriPathSegment(w, model);
            return;
        }
    }
    try w.writeAll("publishers/google/models/");
    try writeUriPathSegment(w, model);
}

fn mistralChatEndpointForProvider(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const base_url = env.get("PI_ZIG_PROVIDER_BASE_URL") orelse "https://api.mistral.ai/v1";
    return endpointFromBaseUrlWithPath(allocator, base_url, "/chat/completions");
}

fn bedrockConverseStreamEndpointForProvider(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    model: []const u8,
) ![]u8 {
    const base_url = if (env.get("PI_ZIG_PROVIDER_BASE_URL")) |value|
        value
    else if (env.get("AWS_BEDROCK_RUNTIME_BASE_URL")) |value|
        value
    else blk: {
        const region = env.get("AWS_REGION") orelse env.get("AWS_DEFAULT_REGION") orelse "us-east-1";
        break :blk try std.fmt.allocPrint(allocator, "https://bedrock-runtime.{s}.amazonaws.com", .{region});
    };
    const should_free_base = env.get("PI_ZIG_PROVIDER_BASE_URL") == null and env.get("AWS_BEDROCK_RUNTIME_BASE_URL") == null;
    defer if (should_free_base) allocator.free(base_url);

    var end = base_url.len;
    while (end > 0 and base_url[end - 1] == '/') end -= 1;
    const trimmed = base_url[0..end];
    if (std.mem.endsWith(u8, trimmed, "/converse-stream")) return allocator.dupe(u8, trimmed);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{s}/model/", .{trimmed});
    try writeUriPathSegment(&out.writer, model);
    try out.writer.writeAll("/converse-stream");
    return out.toOwnedSlice();
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

fn requestSupportsImages(request: ChatTurnRequest) bool {
    if (models.find(request.provider, request.model)) |model| return model.input_image;
    if (models.findExactModelReference(request.model)) |model| {
        if (std.ascii.eqlIgnoreCase(model.provider, request.provider)) return model.input_image;
    }
    return true;
}

/// Resolve the catalog entry for a turn the same way requestSupportsImages does:
/// exact (provider,id) first, then a provider-qualified bare-id fallback.
fn requestModelEntry(request: ChatTurnRequest) ?*const models.ModelEntry {
    if (models.find(request.provider, request.model)) |model| return model;
    if (models.findExactModelReference(request.model)) |model| {
        if (std.ascii.eqlIgnoreCase(model.provider, request.provider)) return model;
    }
    return null;
}

/// Reasoning-effort string emitted for the Azure OpenAI Responses default path,
/// mirroring azure-openai-responses.ts buildParams (and the shared
/// openai-responses.ts logic). pi-zig has no explicit reasoning-effort option on
/// ChatTurnRequest, so this reproduces the no-`reasoningEffort`/`reasoningSummary`
/// branch only:
///
///   if (model.reasoning) {
///     if (reasoningEffort || reasoningSummary) { ... }   // not reachable here
///     else if (model.thinkingLevelMap?.off !== null) {
///       params.reasoning = { effort: model.thinkingLevelMap?.off ?? "none" };
///     }
///   }
///
/// The generated catalog encodes `thinkingLevelMap.off === null` as
/// `thinking_off_disabled` (see scripts/generate-model-catalog.mjs `thinkingDisabled`).
/// Across the entire upstream catalog the `off` key is only ever `null`, the
/// string `"none"`, or absent, so when the branch fires the effort is always
/// "none" (`?? "none"` with the sole explicit value being "none"). Non-reasoning
/// models, and reasoning models whose `off` maps to null, emit nothing — matching
/// upstream omitting `params.reasoning` entirely.
fn azureDefaultReasoningEffort(request: ChatTurnRequest) ?[]const u8 {
    const model = requestModelEntry(request) orelse return null;
    if (!model.reasoning) return null;
    if (model.thinking_off_disabled) return null;
    return "none";
}

fn imagePlaceholderForMessage(message: ChatMessage, supports_images: bool) ?[]const u8 {
    if (supports_images) return null;
    return switch (message.role) {
        .user => non_vision_user_image_placeholder,
        .tool => non_vision_tool_image_placeholder,
        else => null,
    };
}

fn buildPayloadWithStream(allocator: std.mem.Allocator, request: ChatTurnRequest, stream: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const supports_images = requestSupportsImages(request);

    try w.writeAll("{\"model\":");
    try writeJsonString(w, request.model);
    try w.writeAll(",\"messages\":[");
    var emitted: usize = 0;
    var index: usize = 0;
    while (index < request.messages.len) {
        const message = request.messages[index];
        if (message.role == .tool) {
            const tool_start = index;
            var has_images = false;
            while (index < request.messages.len and request.messages[index].role == .tool) : (index += 1) {
                if (emitted != 0) try w.writeByte(',');
                try writeOpenAIToolTextMessage(w, request.messages[index], supports_images);
                emitted += 1;
                if (hasImageContentParts(request.messages[index].content_parts)) has_images = true;
            }
            if (has_images and supports_images) {
                if (emitted != 0) try w.writeByte(',');
                try writeOpenAIToolResultImagesMessage(w, request.messages[tool_start..index]);
                emitted += 1;
            }
        } else {
            if (emitted != 0) try w.writeByte(',');
            try writeMessage(w, message, supports_images);
            emitted += 1;
            index += 1;
        }
    }
    try w.writeAll("],\"stream\":");
    try w.writeAll(if (stream) "true" else "false");
    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (request.tools, 0..) |tool, tool_index| {
            if (tool_index != 0) try w.writeByte(',');
            try writeToolDefinition(w, tool);
        }
        try w.writeAll("],\"tool_choice\":\"auto\"");
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// Build the Azure OpenAI Responses request body. Mirrors azure-openai-responses
/// buildParams + the shared convertResponsesMessages: the `model` field carries
/// the resolved deployment name, and `input` is the Responses item array
/// (`input_text`/`input_image`/`output_text`/`function_call`/`function_call_output`).
fn buildAzureResponsesPayload(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    request: ChatTurnRequest,
    stream: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const supports_images = requestSupportsImages(request);
    const deployment = azureResolveDeploymentName(env, request.model);

    // The wire `model` is the Azure deployment name, not the catalog model id.
    try w.writeAll("{\"model\":");
    try writeJsonString(w, deployment);
    try w.writeAll(",\"input\":[");
    var emitted: usize = 0;
    var index: usize = 0;
    while (index < request.messages.len) {
        const message = request.messages[index];
        switch (message.role) {
            .tool => {
                while (index < request.messages.len and request.messages[index].role == .tool) : (index += 1) {
                    if (emitted != 0) try w.writeByte(',');
                    try writeResponsesToolResultItem(w, request.messages[index], supports_images);
                    emitted += 1;
                }
            },
            .assistant => {
                try writeResponsesAssistantItems(w, message, &emitted);
                index += 1;
            },
            else => {
                if (emitted != 0) try w.writeByte(',');
                try writeResponsesInputMessage(w, message, supports_images);
                emitted += 1;
                index += 1;
            },
        }
    }
    try w.writeAll("],\"stream\":");
    try w.writeAll(if (stream) "true" else "false");
    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (request.tools, 0..) |tool, tool_index| {
            if (tool_index != 0) try w.writeByte(',');
            try writeResponsesToolDefinition(w, tool);
        }
        try w.writeByte(']');
    }
    // Reasoning effort for reasoning-capable models (upstream buildParams sets
    // params.reasoning last, after tools). Omitted for non-reasoning models.
    if (azureDefaultReasoningEffort(request)) |effort| {
        try w.writeAll(",\"reasoning\":{\"effort\":");
        try writeJsonString(w, effort);
        try w.writeByte('}');
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// A `system`/`developer`/`user` input message. Upstream sends user content as
/// an array of `input_text`/`input_image` parts; system/developer prompts use a
/// bare string.
fn writeResponsesInputMessage(w: *std.Io.Writer, message: ChatMessage, supports_images: bool) !void {
    const role_label = switch (message.role) {
        .system => "system",
        .user => "user",
        else => "user",
    };
    try w.writeAll("{\"role\":\"");
    try w.writeAll(role_label);
    try w.writeAll("\",\"content\":");
    if (message.role != .user) {
        // System/developer prompt: bare string content.
        try writeJsonString(w, message.content);
        try w.writeByte('}');
        return;
    }
    try w.writeByte('[');
    var emitted: usize = 0;
    if (message.content_parts.len > 0) {
        const placeholder = imagePlaceholderForMessage(message, supports_images);
        for (message.content_parts) |part| {
            switch (part) {
                .text => |text| {
                    if (emitted != 0) try w.writeByte(',');
                    try writeResponsesInputText(w, text);
                    emitted += 1;
                },
                .image => |image| {
                    if (emitted != 0) try w.writeByte(',');
                    if (placeholder) |value| {
                        try writeResponsesInputText(w, value);
                    } else {
                        try writeResponsesInputImage(w, image);
                    }
                    emitted += 1;
                },
            }
        }
    } else {
        try writeResponsesInputText(w, message.content);
        emitted += 1;
    }
    try w.writeAll("]}");
}

fn writeResponsesInputText(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"type\":\"input_text\",\"text\":");
    try writeJsonString(w, text);
    try w.writeByte('}');
}

fn writeResponsesInputImage(w: *std.Io.Writer, image: ChatImageContent) !void {
    try w.writeAll("{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:");
    try writeJsonStringFragment(w, image.mime_type);
    try w.writeAll(";base64,");
    try writeJsonStringFragment(w, image.data);
    try w.writeAll("\"}");
}

/// An assistant turn becomes one `message` item (when it has text) plus one
/// `function_call` item per tool call, matching convertResponsesMessages.
fn writeResponsesAssistantItems(w: *std.Io.Writer, message: ChatMessage, emitted: *usize) !void {
    if (message.content.len > 0) {
        if (emitted.* != 0) try w.writeByte(',');
        try w.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
        try writeJsonString(w, message.content);
        try w.writeAll(",\"annotations\":[]}]}");
        emitted.* += 1;
    }
    for (message.tool_calls) |call| {
        if (emitted.* != 0) try w.writeByte(',');
        try w.writeAll("{\"type\":\"function_call\",\"call_id\":");
        try writeJsonString(w, call.id);
        try w.writeAll(",\"name\":");
        try writeJsonString(w, call.name);
        try w.writeAll(",\"arguments\":");
        try writeJsonString(w, call.arguments_json);
        try w.writeByte('}');
        emitted.* += 1;
    }
}

/// A `tool` message becomes a `function_call_output` item. Text-only results
/// send a string output; results with images (on vision models) send an array
/// of `input_text`/`input_image` parts.
fn writeResponsesToolResultItem(w: *std.Io.Writer, message: ChatMessage, supports_images: bool) !void {
    try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
    try writeJsonString(w, message.tool_call_id orelse "");
    try w.writeAll(",\"output\":");
    const has_images = hasImageContentParts(message.content_parts);
    if (has_images and supports_images) {
        try w.writeByte('[');
        var emitted: usize = 0;
        if (hasTextContentParts(message.content_parts)) {
            for (message.content_parts) |part| {
                switch (part) {
                    .text => |text| {
                        if (text.len == 0) continue;
                        if (emitted != 0) try w.writeByte(',');
                        try writeResponsesInputText(w, text);
                        emitted += 1;
                    },
                    .image => {},
                }
            }
        } else if (message.content.len > 0) {
            try writeResponsesInputText(w, message.content);
            emitted += 1;
        }
        for (message.content_parts) |part| {
            switch (part) {
                .image => |image| {
                    if (emitted != 0) try w.writeByte(',');
                    try writeResponsesInputImage(w, image);
                    emitted += 1;
                },
                .text => {},
            }
        }
        try w.writeByte(']');
    } else {
        // Text-only output. Mirror upstream's "(see attached image)" fallback
        // when a non-vision model would otherwise drop image-only results.
        try writeJsonString(w, writeResponsesToolResultText(message));
    }
    try w.writeByte('}');
}

fn writeResponsesToolResultText(message: ChatMessage) []const u8 {
    if (message.content.len > 0) return message.content;
    if (hasTextContentParts(message.content_parts)) {
        for (message.content_parts) |part| {
            switch (part) {
                .text => |text| if (text.len > 0) return text,
                .image => {},
            }
        }
    }
    if (hasImageContentParts(message.content_parts)) return "(see attached image)";
    return "";
}

fn writeResponsesToolDefinition(w: *std.Io.Writer, tool: ChatToolDefinition) !void {
    try w.writeAll("{\"type\":\"function\",\"name\":");
    try writeJsonString(w, tool.name);
    try w.writeAll(",\"description\":");
    try writeJsonString(w, tool.description);
    try w.writeAll(",\"parameters\":");
    try w.writeAll(tool.parameters_json);
    try w.writeAll(",\"strict\":false}");
}

fn buildAnthropicMessagesPayload(allocator: std.mem.Allocator, request: ChatTurnRequest, stream: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const supports_images = requestSupportsImages(request);

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
            try writeAnthropicToolResultMessage(w, request.messages, &index, supports_images);
        } else {
            try writeAnthropicMessage(w, message, supports_images);
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
    const supports_images = requestSupportsImages(request);

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
            try writeGoogleToolResultContent(w, request.messages, &index, supports_images);
        } else {
            try writeGoogleContent(w, message, supports_images);
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
    const supports_images = requestSupportsImages(request);

    try w.writeAll("{\"model\":");
    try writeJsonString(w, request.model);
    try w.writeAll(",\"stream\":");
    try w.writeAll(if (stream) "true" else "false");
    try w.writeAll(",\"messages\":[");
    for (request.messages, 0..) |message, index| {
        if (index != 0) try w.writeByte(',');
        try writeMistralMessage(w, request.messages, index, message, supports_images);
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

fn buildBedrockConversePayload(allocator: std.mem.Allocator, request: ChatTurnRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const supports_images = requestSupportsImages(request);

    try w.writeAll("{\"messages\":[");
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
            try writeBedrockToolResultMessage(w, request.messages, &index, supports_images);
        } else {
            try writeBedrockMessage(w, message, supports_images);
            index += 1;
        }
        emitted += 1;
    }
    try w.writeByte(']');
    try writeBedrockSystem(w, request.messages);
    if (request.tools.len > 0) {
        try w.writeAll(",\"toolConfig\":{\"tools\":[");
        for (request.tools, 0..) |tool, tool_index| {
            if (tool_index != 0) try w.writeByte(',');
            try writeBedrockToolDefinition(w, tool);
        }
        try w.writeAll("],\"toolChoice\":{\"auto\":{}}}");
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

fn writeAnthropicMessage(w: *std.Io.Writer, message: ChatMessage, supports_images: bool) !void {
    try w.writeAll("{\"role\":");
    try writeJsonString(w, switch (message.role) {
        .assistant => "assistant",
        else => "user",
    });
    try w.writeAll(",\"content\":[");
    var emitted: usize = 0;
    const image_placeholder = imagePlaceholderForMessage(message, supports_images);
    if (message.role == .assistant and message.content.len > 0) {
        try writeAnthropicTextBlock(w, message.content, &emitted);
    } else if (message.content_parts.len > 0) {
        try writeAnthropicContentPartsInto(w, message.content_parts, image_placeholder, &emitted);
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

fn writeAnthropicToolResultMessage(w: *std.Io.Writer, messages: []const ChatMessage, index: *usize, supports_images: bool) !void {
    try w.writeAll("{\"role\":\"user\",\"content\":[");
    var emitted: usize = 0;
    while (index.* < messages.len and messages[index.*].role == .tool) : (index.* += 1) {
        if (emitted != 0) try w.writeByte(',');
        const message = messages[index.*];
        const image_placeholder = imagePlaceholderForMessage(message, supports_images);
        try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
        try writeJsonString(w, message.tool_call_id orelse "");
        try w.writeAll(",\"content\":");
        if (message.content_parts.len > 0) {
            try writeAnthropicContentParts(w, message.content_parts, image_placeholder);
        } else {
            try writeJsonString(w, message.content);
        }
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

fn writeAnthropicTextPart(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.writeByte('}');
}

fn writeAnthropicContentPart(w: *std.Io.Writer, part: ChatContentPart, image_placeholder: ?[]const u8) !void {
    switch (part) {
        .text => |text| {
            try writeAnthropicTextPart(w, text);
        },
        .image => |image| {
            if (image_placeholder) |placeholder| {
                try writeAnthropicTextPart(w, placeholder);
                return;
            }
            try w.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
            try writeJsonString(w, image.mime_type);
            try w.writeAll(",\"data\":");
            try writeJsonString(w, image.data);
            try w.writeAll("}}");
        },
    }
}

fn writeAnthropicContentPartsInto(
    w: *std.Io.Writer,
    parts: []const ChatContentPart,
    image_placeholder: ?[]const u8,
    emitted: *usize,
) !void {
    var previous_was_placeholder = false;
    for (parts) |part| {
        switch (part) {
            .text => |text| {
                if (emitted.* != 0) try w.writeByte(',');
                try writeAnthropicTextPart(w, text);
                emitted.* += 1;
                previous_was_placeholder = if (image_placeholder) |placeholder| std.mem.eql(u8, text, placeholder) else false;
            },
            .image => {
                if (image_placeholder) |placeholder| {
                    if (previous_was_placeholder) continue;
                    if (emitted.* != 0) try w.writeByte(',');
                    try writeAnthropicTextPart(w, placeholder);
                    emitted.* += 1;
                    previous_was_placeholder = true;
                } else {
                    if (emitted.* != 0) try w.writeByte(',');
                    try writeAnthropicContentPart(w, part, null);
                    emitted.* += 1;
                    previous_was_placeholder = false;
                }
            },
        }
    }
}

fn writeAnthropicContentParts(w: *std.Io.Writer, parts: []const ChatContentPart, image_placeholder: ?[]const u8) !void {
    try w.writeByte('[');
    var emitted: usize = 0;
    try writeAnthropicContentPartsInto(w, parts, image_placeholder, &emitted);
    try w.writeByte(']');
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

fn writeGoogleContent(w: *std.Io.Writer, message: ChatMessage, supports_images: bool) !void {
    try w.writeAll("{\"role\":");
    try writeJsonString(w, if (message.role == .assistant) "model" else "user");
    try w.writeAll(",\"parts\":[");
    var emitted: usize = 0;
    const image_placeholder = imagePlaceholderForMessage(message, supports_images);
    if (message.role == .assistant and message.content.len > 0) {
        try writeGoogleTextPart(w, message.content, &emitted);
    } else if (message.content_parts.len > 0) {
        try writeGoogleContentPartsInto(w, message.content_parts, image_placeholder, &emitted);
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

fn writeGoogleToolResultContent(w: *std.Io.Writer, messages: []const ChatMessage, index: *usize, supports_images: bool) !void {
    try w.writeAll("{\"role\":\"user\",\"parts\":[");
    var emitted: usize = 0;
    while (index.* < messages.len and messages[index.*].role == .tool) : (index.* += 1) {
        const message = messages[index.*];
        const tool_call_id = message.tool_call_id orelse return error.ProviderResponseInvalid;
        const tool_name = findToolNameForToolResult(messages, index.*, tool_call_id) orelse return error.ProviderResponseInvalid;
        const has_images = hasImageContentParts(message.content_parts);
        if (emitted != 0) try w.writeByte(',');
        try w.writeAll("{\"functionResponse\":{\"name\":");
        try writeJsonString(w, tool_name);
        try w.writeAll(",\"response\":{\"output\":");
        if (!supports_images and has_images) {
            try writeJsonStringFromContentPartsWithImagePlaceholder(
                w,
                message.content_parts,
                message.content,
                non_vision_tool_image_placeholder,
            );
        } else {
            try writeJsonString(w, message.content);
        }
        try w.writeAll("}}}");
        emitted += 1;
        if (has_images and supports_images) {
            if (emitted != 0) try w.writeByte(',');
            try w.writeAll("{\"text\":\"Tool result image:\"}");
            emitted += 1;
            for (message.content_parts) |part| {
                switch (part) {
                    .text => {},
                    .image => {
                        if (emitted != 0) try w.writeByte(',');
                        try writeGoogleContentPart(w, part, null);
                        emitted += 1;
                    },
                }
            }
        }
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
    try writeGoogleTextPartValue(w, text);
    emitted.* += 1;
}

fn writeGoogleTextPartValue(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"text\":");
    try writeJsonString(w, text);
    try w.writeByte('}');
}

fn writeGoogleContentPart(w: *std.Io.Writer, part: ChatContentPart, image_placeholder: ?[]const u8) !void {
    switch (part) {
        .text => |text| {
            try writeGoogleTextPartValue(w, text);
        },
        .image => |image| {
            if (image_placeholder) |placeholder| {
                try writeGoogleTextPartValue(w, placeholder);
                return;
            }
            try w.writeAll("{\"inlineData\":{\"mimeType\":");
            try writeJsonString(w, image.mime_type);
            try w.writeAll(",\"data\":");
            try writeJsonString(w, image.data);
            try w.writeAll("}}");
        },
    }
}

fn writeGoogleContentPartsInto(
    w: *std.Io.Writer,
    parts: []const ChatContentPart,
    image_placeholder: ?[]const u8,
    emitted: *usize,
) !void {
    var previous_was_placeholder = false;
    for (parts) |part| {
        switch (part) {
            .text => |text| {
                if (emitted.* != 0) try w.writeByte(',');
                try writeGoogleTextPartValue(w, text);
                emitted.* += 1;
                previous_was_placeholder = if (image_placeholder) |placeholder| std.mem.eql(u8, text, placeholder) else false;
            },
            .image => {
                if (image_placeholder) |placeholder| {
                    if (previous_was_placeholder) continue;
                    if (emitted.* != 0) try w.writeByte(',');
                    try writeGoogleTextPartValue(w, placeholder);
                    emitted.* += 1;
                    previous_was_placeholder = true;
                } else {
                    if (emitted.* != 0) try w.writeByte(',');
                    try writeGoogleContentPart(w, part, null);
                    emitted.* += 1;
                    previous_was_placeholder = false;
                }
            },
        }
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
    try w.writeByte('}');
    if (call.thought_signature) |signature| {
        try w.writeAll(",\"thoughtSignature\":");
        try writeJsonString(w, signature);
    }
    try w.writeByte('}');
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

fn writeMistralMessage(
    w: *std.Io.Writer,
    messages: []const ChatMessage,
    index: usize,
    message: ChatMessage,
    supports_images: bool,
) !void {
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
        try w.writeAll(",\"content\":");
        if (message.content_parts.len > 0) {
            try writeMistralContentParts(w, message.content_parts, imagePlaceholderForMessage(message, supports_images));
        } else {
            try w.writeAll("[{\"type\":\"text\",\"text\":");
            try writeJsonString(w, if (message.content.len > 0) message.content else "(no tool output)");
            try w.writeAll("}]");
        }
    } else {
        try w.writeAll(",\"content\":");
        if (message.content_parts.len > 0) {
            try writeMistralContentParts(w, message.content_parts, imagePlaceholderForMessage(message, supports_images));
        } else {
            try writeJsonString(w, message.content);
        }
    }
    try w.writeByte('}');
}

fn writeMistralTextPart(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.writeByte('}');
}

fn writeMistralContentParts(w: *std.Io.Writer, parts: []const ChatContentPart, image_placeholder: ?[]const u8) !void {
    try w.writeByte('[');
    var emitted: usize = 0;
    var previous_was_placeholder = false;
    for (parts) |part| {
        switch (part) {
            .text => |text| {
                if (emitted != 0) try w.writeByte(',');
                try writeMistralTextPart(w, text);
                emitted += 1;
                previous_was_placeholder = if (image_placeholder) |placeholder| std.mem.eql(u8, text, placeholder) else false;
            },
            .image => |image| {
                if (image_placeholder) |placeholder| {
                    if (previous_was_placeholder) continue;
                    if (emitted != 0) try w.writeByte(',');
                    try writeMistralTextPart(w, placeholder);
                    emitted += 1;
                    previous_was_placeholder = true;
                    continue;
                }
                if (emitted != 0) try w.writeByte(',');
                try w.writeAll("{\"type\":\"image_url\",\"image_url\":\"data:");
                try writeJsonStringFragment(w, image.mime_type);
                try w.writeAll(";base64,");
                try writeJsonStringFragment(w, image.data);
                try w.writeAll("\"}");
                emitted += 1;
                previous_was_placeholder = false;
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

fn writeBedrockSystem(w: *std.Io.Writer, messages: []const ChatMessage) !void {
    var emitted: usize = 0;
    for (messages) |message| {
        if (message.role != .system or std.mem.trim(u8, message.content, " \t\r\n").len == 0) continue;
        if (emitted == 0) try w.writeAll(",\"system\":[") else try w.writeByte(',');
        try w.writeAll("{\"text\":");
        try writeJsonString(w, message.content);
        try w.writeByte('}');
        emitted += 1;
    }
    if (emitted != 0) try w.writeByte(']');
}

fn writeBedrockMessage(w: *std.Io.Writer, message: ChatMessage, supports_images: bool) !void {
    try w.writeAll("{\"role\":");
    try writeJsonString(w, if (message.role == .assistant) "assistant" else "user");
    try w.writeAll(",\"content\":[");
    var emitted: usize = 0;
    const image_placeholder = imagePlaceholderForMessage(message, supports_images);
    if (message.role == .assistant and message.content.len > 0) {
        try writeBedrockTextBlock(w, message.content, &emitted);
    } else if (message.content_parts.len > 0) {
        try writeBedrockContentPartsInto(w, message.content_parts, image_placeholder, &emitted);
    } else if (message.content.len > 0) {
        try writeBedrockTextBlock(w, message.content, &emitted);
    }
    if (message.role == .assistant and message.tool_calls.len > 0) {
        for (message.tool_calls) |call| {
            if (emitted != 0) try w.writeByte(',');
            try writeBedrockToolUseBlock(w, call);
            emitted += 1;
        }
    }
    try w.writeAll("]}");
}

fn writeBedrockToolResultMessage(w: *std.Io.Writer, messages: []const ChatMessage, index: *usize, supports_images: bool) !void {
    try w.writeAll("{\"role\":\"user\",\"content\":[");
    var emitted: usize = 0;
    while (index.* < messages.len and messages[index.*].role == .tool) : (index.* += 1) {
        if (emitted != 0) try w.writeByte(',');
        const message = messages[index.*];
        const image_placeholder = imagePlaceholderForMessage(message, supports_images);
        try w.writeAll("{\"toolResult\":{\"toolUseId\":");
        try writeJsonString(w, message.tool_call_id orelse "");
        try w.writeAll(",\"content\":");
        if (message.content_parts.len > 0) {
            try writeBedrockContentParts(w, message.content_parts, image_placeholder);
        } else {
            try w.writeAll("[{\"text\":");
            try writeJsonString(w, if (message.content.len > 0) message.content else "(no tool output)");
            try w.writeAll("}]");
        }
        try w.writeAll(",\"status\":\"success\"}}");
        emitted += 1;
    }
    try w.writeAll("]}");
}

fn writeBedrockTextBlock(w: *std.Io.Writer, text: []const u8, emitted: *usize) !void {
    if (emitted.* != 0) try w.writeByte(',');
    try w.writeAll("{\"text\":");
    try writeJsonString(w, text);
    try w.writeByte('}');
    emitted.* += 1;
}

fn writeBedrockTextPart(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"text\":");
    try writeJsonString(w, text);
    try w.writeByte('}');
}

fn writeBedrockContentPart(w: *std.Io.Writer, part: ChatContentPart, image_placeholder: ?[]const u8) !void {
    switch (part) {
        .text => |text| {
            try writeBedrockTextPart(w, text);
        },
        .image => |image| {
            if (image_placeholder) |placeholder| {
                try writeBedrockTextPart(w, placeholder);
                return;
            }
            try w.writeAll("{\"image\":{\"format\":");
            try writeJsonString(w, bedrockImageFormatFromMime(image.mime_type));
            try w.writeAll(",\"source\":{\"bytes\":");
            try writeJsonString(w, image.data);
            try w.writeAll("}}}");
        },
    }
}

fn writeBedrockContentPartsInto(
    w: *std.Io.Writer,
    parts: []const ChatContentPart,
    image_placeholder: ?[]const u8,
    emitted: *usize,
) !void {
    var previous_was_placeholder = false;
    for (parts) |part| {
        switch (part) {
            .text => |text| {
                if (emitted.* != 0) try w.writeByte(',');
                try writeBedrockTextPart(w, text);
                emitted.* += 1;
                previous_was_placeholder = if (image_placeholder) |placeholder| std.mem.eql(u8, text, placeholder) else false;
            },
            .image => {
                if (image_placeholder) |placeholder| {
                    if (previous_was_placeholder) continue;
                    if (emitted.* != 0) try w.writeByte(',');
                    try writeBedrockTextPart(w, placeholder);
                    emitted.* += 1;
                    previous_was_placeholder = true;
                } else {
                    if (emitted.* != 0) try w.writeByte(',');
                    try writeBedrockContentPart(w, part, null);
                    emitted.* += 1;
                    previous_was_placeholder = false;
                }
            },
        }
    }
}

fn writeBedrockContentParts(w: *std.Io.Writer, parts: []const ChatContentPart, image_placeholder: ?[]const u8) !void {
    try w.writeByte('[');
    var emitted: usize = 0;
    try writeBedrockContentPartsInto(w, parts, image_placeholder, &emitted);
    try w.writeByte(']');
}

fn writeBedrockToolUseBlock(w: *std.Io.Writer, call: ChatToolCall) !void {
    try w.writeAll("{\"toolUse\":{\"toolUseId\":");
    try writeJsonString(w, call.id);
    try w.writeAll(",\"name\":");
    try writeJsonString(w, call.name);
    try w.writeAll(",\"input\":");
    if (std.mem.trim(u8, call.arguments_json, " \t\r\n").len == 0) {
        try w.writeAll("{}");
    } else {
        try w.writeAll(call.arguments_json);
    }
    try w.writeAll("}}");
}

fn writeBedrockToolDefinition(w: *std.Io.Writer, tool: ChatToolDefinition) !void {
    try w.writeAll("{\"toolSpec\":{\"name\":");
    try writeJsonString(w, tool.name);
    try w.writeAll(",\"description\":");
    try writeJsonString(w, tool.description);
    try w.writeAll(",\"inputSchema\":{\"json\":");
    try w.writeAll(tool.parameters_json);
    try w.writeAll("}}}");
}

fn bedrockImageFormatFromMime(mime_type: []const u8) []const u8 {
    if (std.mem.eql(u8, mime_type, "image/jpeg") or std.mem.eql(u8, mime_type, "image/jpg")) return "jpeg";
    if (std.mem.eql(u8, mime_type, "image/png")) return "png";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "gif";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "webp";
    if (std.mem.startsWith(u8, mime_type, "image/")) return mime_type["image/".len..];
    return "png";
}

fn readAnthropicSseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
    cancellation: CancellationState,
) !void {
    var data_writer: std.Io.Writer.Allocating = .init(allocator);
    defer data_writer.deinit();
    var event_kind: AnthropicSseEventKind = .none;
    var saw_stop = false;

    while (true) {
        try checkCancellation(cancellation);
        const raw_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ProviderStreamIncomplete,
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
                try checkCancellation(cancellation);
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
        try checkCancellation(cancellation);
        if (try isAnthropicMessageStopData(allocator, data)) saw_stop = true;
    }
    if (!saw_stop) return error.ProviderStreamIncomplete;
}

fn readGoogleSseStream(
    reader: *std.Io.Reader,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
    cancellation: CancellationState,
) !void {
    var saw_data = false;
    while (true) {
        try checkCancellation(cancellation);
        const raw_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ProviderStreamIncomplete,
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
        try checkCancellation(cancellation);
        saw_data = true;
    }
    if (!saw_data) return error.ProviderStreamIncomplete;
}

fn readBedrockEventStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    callback_context: *anyopaque,
    callback: StreamDataCallback,
    cancellation: CancellationState,
) !void {
    var saw_event = false;
    while (true) {
        try checkCancellation(cancellation);
        const prelude = reader.takeArray(12) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ProviderStreamIncomplete,
        };
        const total_len = std.mem.readInt(u32, prelude[0..4], .big);
        const headers_len = std.mem.readInt(u32, prelude[4..8], .big);
        if (total_len < 16 or headers_len > total_len - 16) return error.ProviderResponseInvalid;

        const rest_len: usize = @intCast(total_len - 12);
        const rest = try reader.readAlloc(allocator, rest_len);
        defer allocator.free(rest);
        if (rest.len != rest_len) return error.ProviderResponseInvalid;

        const headers_end: usize = @intCast(headers_len);
        const payload_len: usize = @intCast(total_len - 16 - headers_len);
        const payload_end = headers_end + payload_len;
        if (payload_end + 4 != rest.len) return error.ProviderResponseInvalid;

        const headers = rest[0..headers_end];
        const payload = rest[headers_end..payload_end];
        const message_type = try bedrockEventStreamHeader(headers, ":message-type");
        if (message_type) |kind| {
            if (std.mem.eql(u8, kind, "exception")) return error.ProviderRequestFailed;
        }
        const event_type = try bedrockEventStreamHeader(headers, ":event-type");
        if (event_type) |kind| {
            if (std.mem.endsWith(u8, kind, "Exception") or std.mem.endsWith(u8, kind, "Error")) {
                return error.ProviderRequestFailed;
            }
        }
        if (payload.len == 0) continue;
        try callback(callback_context, payload);
        try checkCancellation(cancellation);
        saw_event = true;
    }
    if (!saw_event) return error.ProviderStreamIncomplete;
}

fn bedrockEventStreamHeader(headers: []const u8, wanted: []const u8) !?[]const u8 {
    var index: usize = 0;
    while (index < headers.len) {
        if (index + 2 > headers.len) return error.ProviderResponseInvalid;
        const name_len = headers[index];
        index += 1;
        if (index + name_len + 1 > headers.len) return error.ProviderResponseInvalid;
        const name = headers[index .. index + name_len];
        index += name_len;
        const header_type = headers[index];
        index += 1;
        switch (header_type) {
            0, 1 => {
                if (std.mem.eql(u8, name, wanted)) return null;
            },
            2 => {
                if (index + 1 > headers.len) return error.ProviderResponseInvalid;
                index += 1;
            },
            3 => {
                if (index + 2 > headers.len) return error.ProviderResponseInvalid;
                index += 2;
            },
            4 => {
                if (index + 4 > headers.len) return error.ProviderResponseInvalid;
                index += 4;
            },
            5, 8 => {
                if (index + 8 > headers.len) return error.ProviderResponseInvalid;
                index += 8;
            },
            6, 7 => {
                if (index + 2 > headers.len) return error.ProviderResponseInvalid;
                const len = std.mem.readInt(u16, headers[index..][0..2], .big);
                index += 2;
                if (index + len > headers.len) return error.ProviderResponseInvalid;
                const value = headers[index .. index + len];
                index += len;
                if (std.mem.eql(u8, name, wanted)) {
                    if (header_type != 7) return error.ProviderResponseInvalid;
                    return value;
                }
            },
            9 => {
                if (index + 16 > headers.len) return error.ProviderResponseInvalid;
                index += 16;
            },
            else => return error.ProviderResponseInvalid,
        }
    }
    return null;
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
            if (!isGoogleThinkingPart(part)) try text.writer.writeAll(text_value.string);
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
            var thought_signature: ?[]u8 = if (try optionalObjectString(part, "thoughtSignature")) |signature|
                try allocator.dupe(u8, signature)
            else
                null;
            errdefer if (thought_signature) |value| allocator.free(value);
            try calls.append(allocator, .{
                .id = id.?,
                .name = name_copy.?,
                .arguments_json = arguments_json.?,
                .thought_signature = thought_signature,
            });
            id = null;
            name_copy = null;
            arguments_json = null;
            thought_signature = null;
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
    if (isBedrockStreamEvent(parsed.value)) {
        try parseBedrockStreamTextDeltas(parsed.value, callback_context, callback);
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
    if (isBedrockStreamEvent(parsed.value)) {
        try accumulator.appendBedrockStreamEvent(parsed.value, text_callback_context, text_callback);
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
            if (!isGoogleThinkingPart(part) and text.string.len > 0) try callback(callback_context, text.string);
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

fn isBedrockStreamEvent(value: std.json.Value) bool {
    if (value != .object) return false;
    return value.object.get("messageStart") != null or
        value.object.get("contentBlockStart") != null or
        value.object.get("contentBlockDelta") != null or
        value.object.get("contentBlockStop") != null or
        value.object.get("messageStop") != null or
        value.object.get("metadata") != null;
}

fn parseBedrockStreamTextDeltas(
    value: std.json.Value,
    callback_context: *anyopaque,
    callback: StreamTextCallback,
) !void {
    if (value != .object) return error.ProviderResponseInvalid;
    const event = value.object.get("contentBlockDelta") orelse return;
    if (event != .object) return error.ProviderResponseInvalid;
    const delta = event.object.get("delta") orelse return;
    if (delta != .object) return error.ProviderResponseInvalid;
    if (delta.object.get("text")) |text| {
        if (text != .string) return error.ProviderResponseInvalid;
        if (text.string.len > 0) try callback(callback_context, text.string);
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
    thought_signature: std.Io.Writer.Allocating,
    seen: bool = false,

    fn init(allocator: std.mem.Allocator) StreamToolCallAccumulator {
        return .{
            .id = .init(allocator),
            .name = .init(allocator),
            .arguments_json = .init(allocator),
            .thought_signature = .init(allocator),
        };
    }

    fn deinit(self: *StreamToolCallAccumulator) void {
        self.id.deinit();
        self.name.deinit();
        self.arguments_json.deinit();
        self.thought_signature.deinit();
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
                if (!isGoogleThinkingPart(part)) try self.appendTextDelta(text.string, text_callback_context, text_callback);
            }
            if (part.object.get("functionCall")) |function_call| {
                try self.appendGoogleFunctionCall(function_call, try optionalObjectString(part, "thoughtSignature"));
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

    fn appendBedrockStreamEvent(
        self: *StreamChatAccumulator,
        value: std.json.Value,
        text_callback_context: ?*anyopaque,
        text_callback: ?StreamTextCallback,
    ) !void {
        if (value != .object) return error.ProviderResponseInvalid;
        if (value.object.get("contentBlockStart")) |event| {
            if (event != .object) return error.ProviderResponseInvalid;
            const start = event.object.get("start") orelse return;
            if (start != .object) return error.ProviderResponseInvalid;
            if (start.object.get("toolUse")) |tool_use| {
                const index = try bedrockContentBlockIndex(event);
                try self.startBedrockToolUse(index, tool_use);
            }
            return;
        }
        if (value.object.get("contentBlockDelta")) |event| {
            if (event != .object) return error.ProviderResponseInvalid;
            const delta = event.object.get("delta") orelse return error.ProviderResponseInvalid;
            if (delta != .object) return error.ProviderResponseInvalid;
            if (delta.object.get("text")) |text| {
                if (text != .string) return error.ProviderResponseInvalid;
                try self.appendTextDelta(text.string, text_callback_context, text_callback);
            }
            if (delta.object.get("toolUse")) |tool_use_delta| {
                if (tool_use_delta != .object) return error.ProviderResponseInvalid;
                const index = try bedrockContentBlockIndex(event);
                if (index >= self.tool_calls.items.len or !self.tool_calls.items[index].seen) return;
                if (tool_use_delta.object.get("input")) |input| {
                    if (input != .string) return error.ProviderResponseInvalid;
                    try self.tool_calls.items[index].arguments_json.writer.writeAll(input.string);
                }
            }
            return;
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

    fn appendGoogleFunctionCall(
        self: *StreamChatAccumulator,
        function_call: std.json.Value,
        thought_signature: ?[]const u8,
    ) !void {
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
        if (thought_signature) |signature| {
            if (signature.len > 0 and call.thought_signature.written().len == 0) {
                try call.thought_signature.writer.writeAll(signature);
            }
        }
    }

    fn startBedrockToolUse(self: *StreamChatAccumulator, index: usize, tool_use: std.json.Value) !void {
        if (tool_use != .object) return error.ProviderResponseInvalid;
        const call = try self.ensureToolCall(index);
        call.seen = true;
        try call.id.writer.writeAll(try requiredObjectString(tool_use, "toolUseId"));
        try call.name.writer.writeAll(try requiredObjectString(tool_use, "name"));
        if (tool_use.object.get("input")) |input| {
            if (try shouldSerializeInitialToolInput(input)) {
                const arguments_json = try jsonValueToOwnedString(self.allocator, input);
                defer self.allocator.free(arguments_json);
                try call.arguments_json.writer.writeAll(arguments_json);
            }
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
                var thought_signature: ?[]u8 = if (call.thought_signature.written().len > 0)
                    try call.thought_signature.toOwnedSlice()
                else
                    null;
                if (thought_signature != null) call.thought_signature = .init(self.allocator);
                errdefer if (thought_signature) |value| self.allocator.free(value);
                calls[len] = .{
                    .id = id.?,
                    .name = name.?,
                    .arguments_json = arguments_json.?,
                    .thought_signature = thought_signature,
                };
                id = null;
                name = null;
                arguments_json = null;
                thought_signature = null;
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

fn isGoogleThinkingPart(part: std.json.Value) bool {
    if (part != .object) return false;
    const thought = part.object.get("thought") orelse return false;
    return thought == .bool and thought.bool;
}

fn anthropicEventIndex(value: std.json.Value) !usize {
    if (value != .object) return error.ProviderResponseInvalid;
    const index = value.object.get("index") orelse return error.ProviderResponseInvalid;
    return streamToolCallIndex(index);
}

fn bedrockContentBlockIndex(value: std.json.Value) !usize {
    if (value != .object) return error.ProviderResponseInvalid;
    const index = value.object.get("contentBlockIndex") orelse return error.ProviderResponseInvalid;
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

fn writeMessage(w: *std.Io.Writer, message: ChatMessage, supports_images: bool) !void {
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
            try writeContentParts(w, message.content_parts, imagePlaceholderForMessage(message, supports_images));
        } else {
            try writeJsonString(w, message.content);
        }
    }
    try w.writeByte('}');
}

fn writeOpenAIToolTextMessage(w: *std.Io.Writer, message: ChatMessage, supports_images: bool) !void {
    try w.writeAll("{\"role\":\"tool\"");
    if (message.tool_call_id) |tool_call_id| {
        try w.writeAll(",\"tool_call_id\":");
        try writeJsonString(w, tool_call_id);
    }
    try w.writeAll(",\"content\":");
    if (!supports_images and hasImageContentParts(message.content_parts)) {
        try writeJsonStringFromContentPartsWithImagePlaceholder(
            w,
            message.content_parts,
            message.content,
            non_vision_tool_image_placeholder,
        );
    } else if (message.content.len > 0) {
        try writeJsonString(w, message.content);
    } else if (hasImageContentParts(message.content_parts)) {
        try writeJsonString(w, "(see attached image)");
    } else {
        try writeJsonString(w, "");
    }
    try w.writeByte('}');
}

fn writeOpenAIToolResultImagesMessage(w: *std.Io.Writer, messages: []const ChatMessage) !void {
    try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Attached image(s) from tool result:\"}");
    for (messages) |message| {
        for (message.content_parts) |part| {
            switch (part) {
                .text => {},
                .image => {
                    try w.writeByte(',');
                    try writeContentPart(w, part, null);
                },
            }
        }
    }
    try w.writeAll("]}");
}

fn writeTextContentPart(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.writeByte('}');
}

fn writeContentParts(w: *std.Io.Writer, parts: []const ChatContentPart, image_placeholder: ?[]const u8) !void {
    try w.writeByte('[');
    var emitted: usize = 0;
    var previous_was_placeholder = false;
    for (parts) |part| {
        switch (part) {
            .text => |text| {
                if (emitted != 0) try w.writeByte(',');
                try writeTextContentPart(w, text);
                emitted += 1;
                previous_was_placeholder = if (image_placeholder) |placeholder| std.mem.eql(u8, text, placeholder) else false;
            },
            .image => {
                if (image_placeholder) |placeholder| {
                    if (previous_was_placeholder) continue;
                    if (emitted != 0) try w.writeByte(',');
                    try writeTextContentPart(w, placeholder);
                    emitted += 1;
                    previous_was_placeholder = true;
                } else {
                    if (emitted != 0) try w.writeByte(',');
                    try writeContentPart(w, part, null);
                    emitted += 1;
                    previous_was_placeholder = false;
                }
            },
        }
    }
    try w.writeByte(']');
}

fn writeContentPart(w: *std.Io.Writer, part: ChatContentPart, image_placeholder: ?[]const u8) !void {
    switch (part) {
        .text => |text| {
            try writeTextContentPart(w, text);
        },
        .image => |image| {
            if (image_placeholder) |placeholder| {
                try writeTextContentPart(w, placeholder);
                return;
            }
            try w.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
            try writeJsonStringFragment(w, image.mime_type);
            try w.writeAll(";base64,");
            try writeJsonStringFragment(w, image.data);
            try w.writeAll("\"}}");
        },
    }
}

fn writeJsonStringFromContentPartsWithImagePlaceholder(
    w: *std.Io.Writer,
    parts: []const ChatContentPart,
    fallback_text: []const u8,
    image_placeholder: []const u8,
) !void {
    try w.writeByte('"');
    var emitted = false;
    var previous_was_placeholder = false;
    if (!hasTextContentParts(parts) and fallback_text.len > 0) {
        try writeJsonStringFragment(w, fallback_text);
        emitted = true;
        previous_was_placeholder = std.mem.eql(u8, fallback_text, image_placeholder);
    }
    for (parts) |part| {
        switch (part) {
            .text => |text| {
                if (text.len > 0) {
                    if (emitted) try w.writeAll("\\n");
                    try writeJsonStringFragment(w, text);
                    emitted = true;
                }
                previous_was_placeholder = std.mem.eql(u8, text, image_placeholder);
            },
            .image => {
                if (previous_was_placeholder) continue;
                if (emitted) try w.writeAll("\\n");
                try writeJsonStringFragment(w, image_placeholder);
                emitted = true;
                previous_was_placeholder = true;
            },
        }
    }
    if (!emitted) try writeJsonStringFragment(w, image_placeholder);
    try w.writeByte('"');
}

fn hasTextContentParts(parts: []const ChatContentPart) bool {
    for (parts) |part| {
        switch (part) {
            .text => return true,
            .image => {},
        }
    }
    return false;
}

fn hasImageContentParts(parts: []const ChatContentPart) bool {
    for (parts) |part| {
        switch (part) {
            .image => return true,
            .text => {},
        }
    }
    return false;
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

/// Parse a non-streaming OpenAI/Azure Responses API result. The Responses API
/// returns an `output[]` array whose items are `message` (with `content[]` of
/// `output_text`) and `function_call` entries; a top-level `output_text`
/// convenience string is also honored.
fn parseOpenAIResponsesResult(allocator: std.mem.Allocator, body: []const u8) !ChatCompletionResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderResponseInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ProviderResponseInvalid;

    var result: ChatCompletionResult = .{};
    errdefer result.deinit(allocator);

    var text_out: std.Io.Writer.Allocating = .init(allocator);
    defer text_out.deinit();

    var calls: std.ArrayList(ChatToolCall) = .empty;
    errdefer {
        for (calls.items) |call| call.deinit(allocator);
        calls.deinit(allocator);
    }

    if (parsed.value.object.get("output")) |output| {
        if (output != .array) return error.ProviderResponseInvalid;
        for (output.array.items) |item| {
            if (item != .object) continue;
            const item_type = item.object.get("type") orelse continue;
            if (item_type != .string) continue;
            if (std.mem.eql(u8, item_type.string, "message")) {
                const content = item.object.get("content") orelse continue;
                if (content != .array) continue;
                for (content.array.items) |part| {
                    if (part != .object) continue;
                    const part_type = part.object.get("type") orelse continue;
                    if (part_type != .string or !std.mem.eql(u8, part_type.string, "output_text")) continue;
                    const text = part.object.get("text") orelse continue;
                    if (text != .string) continue;
                    if (text_out.written().len != 0) try text_out.writer.writeByte('\n');
                    try text_out.writer.writeAll(text.string);
                }
            } else if (std.mem.eql(u8, item_type.string, "function_call")) {
                const call_id = item.object.get("call_id") orelse item.object.get("id") orelse continue;
                if (call_id != .string) continue;
                const name = item.object.get("name") orelse continue;
                if (name != .string) continue;
                const arguments = item.object.get("arguments") orelse continue;
                if (arguments != .string) continue;
                try calls.append(allocator, .{
                    .id = try allocator.dupe(u8, call_id.string),
                    .name = try allocator.dupe(u8, name.string),
                    .arguments_json = try allocator.dupe(u8, arguments.string),
                });
            }
        }
    } else if (parsed.value.object.get("output_text")) |output_text| {
        if (output_text == .string) try text_out.writer.writeAll(output_text.string);
    } else {
        return error.ProviderResponseInvalid;
    }

    if (text_out.written().len > 0) result.text = try text_out.toOwnedSlice();
    result.tool_calls = try calls.toOwnedSlice(allocator);
    if (result.text == null and result.tool_calls.len == 0) return error.ProviderResponseInvalid;
    return result;
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

fn writeUriPathSegment(w: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(byte),
            else => {
                try w.writeByte('%');
                try w.writeByte(hex[byte >> 4]);
                try w.writeByte(hex[byte & 0x0f]);
            },
        }
    }
}

fn writeUriPathPreservingSlashes(w: *std.Io.Writer, value: []const u8) !void {
    var segments = std.mem.splitScalar(u8, value, '/');
    var first = true;
    while (segments.next()) |segment| {
        if (!first) try w.writeByte('/');
        first = false;
        try writeUriPathSegment(w, segment);
    }
}

fn stripTrailingCarriageReturn(value: []const u8) []const u8 {
    if (value.len > 0 and value[value.len - 1] == '\r') return value[0 .. value.len - 1];
    return value;
}

fn writeBedrockTestFrame(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    event_type: []const u8,
    payload: []const u8,
) !void {
    var headers: std.Io.Writer.Allocating = .init(allocator);
    defer headers.deinit();
    try writeBedrockTestHeaderString(&headers.writer, ":message-type", "event");
    try writeBedrockTestHeaderString(&headers.writer, ":event-type", event_type);
    try writeBedrockTestHeaderString(&headers.writer, ":content-type", "application/json");
    const total_len: u32 = @intCast(12 + headers.written().len + payload.len + 4);
    try w.writeInt(u32, total_len, .big);
    try w.writeInt(u32, @intCast(headers.written().len), .big);
    try w.writeInt(u32, 0, .big);
    try w.writeAll(headers.written());
    try w.writeAll(payload);
    try w.writeInt(u32, 0, .big);
}

fn writeBedrockTestHeaderString(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try w.writeByte(@intCast(name.len));
    try w.writeAll(name);
    try w.writeByte(7);
    try w.writeInt(u16, @intCast(value.len), .big);
    try w.writeAll(value);
}

test "parses OpenAI-compatible chat completion text" {
    const body =
        \\{"choices":[{"message":{"content":"hello from provider"}}]}
    ;
    const text = try parseOpenAICompatibleText(std.testing.allocator, body);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello from provider", text);
}

test "classifies retryable provider error text without retrying context overflow" {
    try std.testing.expectEqual(error.ProviderRequestFailed, providerErrorForStatusAndBody(
        .bad_request,
        "{\"error\":{\"message\":\"provider returned error: upstream connect reset before headers\"}}",
    ));
    try std.testing.expectEqual(error.ProviderRequestFailed, providerErrorForStatusAndBody(
        .bad_request,
        "{\"error\":{\"message\":\"rate limit: too many requests\"}}",
    ));
    try std.testing.expectEqual(error.ProviderRequestFailed, providerErrorForStatusAndBody(
        .bad_request,
        "{\"error\":{\"message\":\"Throttling error: Too many tokens, please wait before trying again.\"}}",
    ));
    try std.testing.expectEqual(error.ProviderRequestFailed, providerErrorForStatusAndBody(
        .too_many_requests,
        "{\"error\":\"ordinary 429\"}",
    ));
    try std.testing.expectEqual(error.ProviderRequestFailed, providerErrorForStatusAndBody(
        .service_unavailable,
        "{\"error\":\"temporary outage\"}",
    ));
    try std.testing.expectEqual(error.ProviderClientError, providerErrorForStatusAndBody(
        .bad_request,
        "{\"error\":{\"message\":\"Your input exceeds the context window of this model\"}}",
    ));
    try std.testing.expectEqual(error.ProviderClientError, providerErrorForStatusAndBody(
        .payload_too_large,
        "{\"error\":{\"type\":\"request_too_large\",\"message\":\"Request exceeds the maximum size\"}}",
    ));
    try std.testing.expectEqual(error.ProviderClientError, providerErrorForStatusAndBody(
        .bad_request,
        "{\"error\":\"bad user request\"}",
    ));
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

test "serializes OpenAI-compatible tool result images as a follow-up user message" {
    const tool_result_parts = [_]ChatContentPart{
        .{ .text = "ok" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const tool_calls = [_]ChatToolCall{
        .{ .id = @constCast("call_1"), .name = @constCast("read"), .arguments_json = @constCast("{\"path\":\"image.png\"}") },
    };
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "inspect image" },
        .{ .role = .assistant, .content = "running", .tool_calls = tool_calls[0..] },
        .{ .role = .tool, .content = "ok", .content_parts = tool_result_parts[0..], .tool_call_id = "call_1" },
    };
    const payload = try buildPayload(std.testing.allocator, .{
        .provider = "openai",
        .model = "mock-image-tool-result-model",
        .api_key = "unused",
        .messages = messages[0..],
    });
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Attached image(s) from tool result:\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,aGVsbG8=\"}}]") != null);
}

test "downgrades OpenAI-compatible images for resolved non-vision models" {
    const parts = [_]ChatContentPart{
        .{ .text = "inspect this" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
        .{ .image = .{ .mime_type = "image/png", .data = "c2Vjb25k" } },
    };
    const tool_result_parts = [_]ChatContentPart{
        .{ .text = "ok" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const tool_calls = [_]ChatToolCall{
        .{ .id = @constCast("call_1"), .name = @constCast("read"), .arguments_json = @constCast("{\"path\":\"image.png\"}") },
    };
    const messages = [_]ChatMessage{
        .{ .role = .user, .content_parts = parts[0..] },
        .{ .role = .assistant, .content = "running", .tool_calls = tool_calls[0..] },
        .{ .role = .tool, .content = "ok", .content_parts = tool_result_parts[0..], .tool_call_id = "call_1" },
    };
    const payload = try buildPayload(std.testing.allocator, .{
        .provider = "openai",
        .model = "gpt-4",
        .api_key = "unused",
        .messages = messages[0..],
    });
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"content\":[{\"type\":\"text\",\"text\":\"inspect this\"},{\"type\":\"text\",\"text\":\"(image omitted: model does not support images)\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"ok\\n(tool image omitted: model does not support images)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "Attached image(s) from tool result") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "image_url") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "aGVsbG8=") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "c2Vjb25k") == null);
}

test "serializes Anthropic messages payload with images tools and tool results" {
    const parts = [_]ChatContentPart{
        .{ .text = "inspect this" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const tool_result_parts = [_]ChatContentPart{
        .{ .text = "ok" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const tool_calls = [_]ChatToolCall{
        .{ .id = @constCast("call_1"), .name = @constCast("bash"), .arguments_json = @constCast("{\"command\":\"printf ok\"}") },
    };
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "be terse" },
        .{ .role = .user, .content_parts = parts[0..] },
        .{ .role = .assistant, .content = "running", .tool_calls = tool_calls[0..] },
        .{ .role = .tool, .content = "ok", .content_parts = tool_result_parts[0..], .tool_call_id = "call_1" },
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
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"type\":\"tool_result\",\"tool_use_id\":\"call_1\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"},{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"aGVsbG8=\"}}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tools\":[{\"name\":\"bash\",\"description\":\"run shell\",\"input_schema\":{\"type\":\"object\"}}]") != null);
}

test "serializes Google generate content payload with images tools and tool results" {
    const parts = [_]ChatContentPart{
        .{ .text = "inspect this" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const tool_calls = [_]ChatToolCall{
        .{
            .id = @constCast("call_1"),
            .name = @constCast("bash"),
            .arguments_json = @constCast("{\"command\":\"printf ok\"}"),
            .thought_signature = @constCast("dGhvdWdodC1zaWduYXR1cmU="),
        },
    };
    const tool_result_parts = [_]ChatContentPart{
        .{ .text = "ok" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "be terse" },
        .{ .role = .user, .content_parts = parts[0..] },
        .{ .role = .assistant, .content = "running", .tool_calls = tool_calls[0..] },
        .{ .role = .tool, .content = "ok", .content_parts = tool_result_parts[0..], .tool_call_id = "call_1" },
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
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"functionCall\":{\"name\":\"bash\",\"args\":{\"command\":\"printf ok\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"thoughtSignature\":\"dGhvdWdodC1zaWduYXR1cmU=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"functionResponse\":{\"name\":\"bash\",\"response\":{\"output\":\"ok\"}}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"functionResponse\":{\"name\":\"bash\",\"response\":{\"output\":\"ok\"}}},{\"text\":\"Tool result image:\"},{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"aGVsbG8=\"}}") != null);
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
    const tool_result_parts = [_]ChatContentPart{
        .{ .text = "ok" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "be terse" },
        .{ .role = .user, .content_parts = parts[0..] },
        .{ .role = .assistant, .content = "running", .tool_calls = tool_calls[0..] },
        .{ .role = .tool, .content = "ok", .content_parts = tool_result_parts[0..], .tool_call_id = "call_1" },
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
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tool_call_id\":\"call_1\",\"name\":\"bash\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"},{\"type\":\"image_url\",\"image_url\":\"data:image/png;base64,aGVsbG8=\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"bash\",\"description\":\"run shell\",\"parameters\":{\"type\":\"object\"},\"strict\":false}}]") != null);
}

test "serializes Bedrock converse payload with images tools and tool results" {
    const parts = [_]ChatContentPart{
        .{ .text = "inspect this" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const tool_calls = [_]ChatToolCall{
        .{ .id = @constCast("call_1"), .name = @constCast("bash"), .arguments_json = @constCast("{\"command\":\"printf ok\"}") },
    };
    const tool_result_parts = [_]ChatContentPart{
        .{ .text = "ok" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "be terse" },
        .{ .role = .user, .content_parts = parts[0..] },
        .{ .role = .assistant, .content = "running", .tool_calls = tool_calls[0..] },
        .{ .role = .tool, .content = "ok", .content_parts = tool_result_parts[0..], .tool_call_id = "call_1" },
    };
    const tools = [_]ChatToolDefinition{
        .{ .name = "bash", .description = "run shell", .parameters_json = "{\"type\":\"object\"}" },
    };
    const payload = try buildBedrockConversePayload(std.testing.allocator, .{
        .provider = "amazon-bedrock",
        .model = "anthropic.claude-test-v1:0",
        .api_key = "bedrock-test",
        .messages = messages[0..],
        .tools = tools[0..],
    });
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"system\":[{\"text\":\"be terse\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"image\":{\"format\":\"png\",\"source\":{\"bytes\":\"aGVsbG8=\"}}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"toolUse\":{\"toolUseId\":\"call_1\",\"name\":\"bash\",\"input\":{\"command\":\"printf ok\"}}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"toolResult\":{\"toolUseId\":\"call_1\",\"content\":[{\"text\":\"ok\"},{\"image\":{\"format\":\"png\",\"source\":{\"bytes\":\"aGVsbG8=\"}}}],\"status\":\"success\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"toolConfig\":{\"tools\":[{\"toolSpec\":{\"name\":\"bash\",\"description\":\"run shell\",\"inputSchema\":{\"json\":{\"type\":\"object\"}}}}],\"toolChoice\":{\"auto\":{}}}") != null);
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

test "parses Google thought signatures without exposing thinking text" {
    const body =
        \\{"candidates":[{"content":{"parts":[{"text":"hidden thought","thought":true,"thoughtSignature":"aGlkZGVuLXNpZw=="},{"text":"visible "},{"functionCall":{"id":"call_1","name":"bash","args":{"command":"printf ok"}},"thoughtSignature":"ZnVuY3Rpb24tc2ln"}]},"finishReason":"STOP"}]}
    ;
    const result = try parseGoogleGenerateContentResult(std.testing.allocator, body);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("visible ", result.text.?);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf ok\"}", result.tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("ZnVuY3Rpb24tc2ln", result.tool_calls[0].thought_signature.?);
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
    try readAnthropicSseStream(std.testing.allocator, &reader, &context, handleStreamResultData, .{});
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
    try readGoogleSseStream(&reader, &context, handleStreamResultData, .{});
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("native google", result.text.?);
}

test "parses native Bedrock event stream frames" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    var context = StreamResultContext{
        .allocator = std.testing.allocator,
        .accumulator = &accumulator,
        .text_callback_context = null,
        .text_callback = null,
    };
    var stream: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stream.deinit();
    try writeBedrockTestFrame(std.testing.allocator, &stream.writer, "messageStart",
        \\{"messageStart":{"role":"assistant"}}
    );
    try writeBedrockTestFrame(std.testing.allocator, &stream.writer, "contentBlockDelta",
        \\{"contentBlockDelta":{"contentBlockIndex":0,"delta":{"text":"native "}}}
    );
    try writeBedrockTestFrame(std.testing.allocator, &stream.writer, "contentBlockDelta",
        \\{"contentBlockDelta":{"contentBlockIndex":0,"delta":{"text":"bedrock"}}}
    );
    try writeBedrockTestFrame(std.testing.allocator, &stream.writer, "messageStop",
        \\{"messageStop":{"stopReason":"end_turn"}}
    );

    var reader = std.Io.Reader.fixed(stream.written());
    try readBedrockEventStream(std.testing.allocator, &reader, &context, handleStreamResultData, .{});
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("native bedrock", result.text.?);
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

test "assembles Bedrock tool use stream events" {
    var accumulator = StreamChatAccumulator.init(std.testing.allocator);
    errdefer accumulator.deinit();
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"contentBlockStart":{"contentBlockIndex":0,"start":{"toolUse":{"toolUseId":"call_bedrock","name":"bash"}}}}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"contentBlockDelta":{"contentBlockIndex":0,"delta":{"toolUse":{"input":"{\"command\":\"printf "}}}}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"contentBlockDelta":{"contentBlockIndex":0,"delta":{"toolUse":{"input":"bedrock-ok\"}"}}}}
    , &accumulator, null, null);
    try parseOpenAICompatibleStreamResultData(std.testing.allocator,
        \\{"contentBlockStop":{"contentBlockIndex":0}}
    , &accumulator, null, null);
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.text == null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_bedrock", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf bedrock-ok\"}", result.tool_calls[0].arguments_json);
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
        \\{"candidates":[{"content":{"parts":[{"text":"hidden","thought":true},{"text":"google "}]}}]}
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
        \\{"candidates":[{"content":{"parts":[{"functionCall":{"id":"call_google","name":"bash","args":{"command":"printf google-ok"}},"thoughtSignature":"Z29vZ2xlLXNpZw=="}]},"finishReason":"STOP"}]}
    , &accumulator, null, null);
    const result = try accumulator.toResult();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.text == null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_google", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf google-ok\"}", result.tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("Z29vZ2xlLXNpZw==", result.tool_calls[0].thought_signature.?);
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

test "Google Vertex provider base URL appends express and project generate content endpoints" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43123/");
    const express_endpoint = try googleVertexGenerateContentEndpointForProvider(std.testing.allocator, &env, "gemini-3-flash-preview", true);
    defer std.testing.allocator.free(express_endpoint);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:43123/v1/publishers/google/models/gemini-3-flash-preview:streamGenerateContent?alt=sse",
        express_endpoint,
    );

    try env.put("GOOGLE_CLOUD_PROJECT", "test-project");
    try env.put("GOOGLE_CLOUD_LOCATION", "us-central1");
    const project_endpoint = try googleVertexGenerateContentEndpointForProvider(std.testing.allocator, &env, "gemini-3-flash-preview", false);
    defer std.testing.allocator.free(project_endpoint);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:43123/v1/projects/test-project/locations/us-central1/publishers/google/models/gemini-3-flash-preview:generateContent",
        project_endpoint,
    );
}

test "Anthropic OAuth auth sends Claude Code identity headers" {
    var oauth_auth = try anthropicAuthHeader(std.testing.allocator, "sk-ant-oat01-oauth-access-token");
    defer oauth_auth.deinit(std.testing.allocator);
    try std.testing.expect(oauth_auth.oauth);
    try std.testing.expectEqualStrings("Bearer sk-ant-oat01-oauth-access-token", oauth_auth.authorization.?);

    var oauth_buf: [5]std.http.Header = undefined;
    const oauth_headers = anthropicExtraHeaders(&oauth_buf, "sk-ant-oat01-oauth-access-token", oauth_auth.oauth);
    try std.testing.expectEqual(@as(usize, 3), oauth_headers.len);
    try std.testing.expectEqualStrings("anthropic-version", oauth_headers[0].name);
    try std.testing.expectEqualStrings("2023-06-01", oauth_headers[0].value);
    try std.testing.expectEqualStrings("anthropic-beta", oauth_headers[1].name);
    try std.testing.expectEqualStrings("claude-code-20250219,oauth-2025-04-20", oauth_headers[1].value);
    try std.testing.expectEqualStrings("x-app", oauth_headers[2].name);
    try std.testing.expectEqualStrings("cli", oauth_headers[2].value);

    // API key tokens with the oauth marker embedded mid-string still route through OAuth (upstream uses substring match).
    try std.testing.expect(isAnthropicOAuthToken("prefix-sk-ant-oat99-suffix"));

    var api_key_auth_header = try anthropicAuthHeader(std.testing.allocator, "sk-ant-api03-regular-key");
    defer api_key_auth_header.deinit(std.testing.allocator);
    try std.testing.expect(!api_key_auth_header.oauth);
    try std.testing.expect(api_key_auth_header.authorization == null);

    var api_key_buf: [5]std.http.Header = undefined;
    const api_key_headers = anthropicExtraHeaders(&api_key_buf, "sk-ant-api03-regular-key", api_key_auth_header.oauth);
    try std.testing.expectEqual(@as(usize, 2), api_key_headers.len);
    try std.testing.expectEqualStrings("anthropic-version", api_key_headers[0].name);
    try std.testing.expectEqualStrings("x-api-key", api_key_headers[1].name);
    try std.testing.expectEqualStrings("sk-ant-api03-regular-key", api_key_headers[1].value);
}

test "Google Vertex auth uses API key or explicit access token for placeholders" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var api_key_auth = try googleVertexAuthHeader(std.testing.allocator, &env, "AIzaSyExampleRealisticLookingApiKey123456");
    defer api_key_auth.deinit(std.testing.allocator);
    try std.testing.expect(api_key_auth.authorization == null);
    try std.testing.expectEqualStrings("AIzaSyExampleRealisticLookingApiKey123456", api_key_auth.api_key.?);

    try env.put("GOOGLE_CLOUD_ACCESS_TOKEN", "ya29.vertex-token");
    var bearer_auth = try googleVertexAuthHeader(std.testing.allocator, &env, "<authenticated>");
    defer bearer_auth.deinit(std.testing.allocator);
    try std.testing.expect(bearer_auth.api_key == null);
    try std.testing.expectEqualStrings("Bearer ya29.vertex-token", bearer_auth.authorization.?);

    var oauth_auth = try googleVertexAuthHeader(std.testing.allocator, &env, "ya29.stored-oauth-token");
    defer oauth_auth.deinit(std.testing.allocator);
    try std.testing.expect(oauth_auth.api_key == null);
    try std.testing.expectEqualStrings("Bearer ya29.stored-oauth-token", oauth_auth.authorization.?);
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

test "Bedrock provider base URL appends encoded converse stream endpoint" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43123/");
    const endpoint = try bedrockConverseStreamEndpointForProvider(std.testing.allocator, &env, "anthropic.claude-test-v1:0");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/model/anthropic.claude-test-v1%3A0/converse-stream", endpoint);
}

test "AWS SigV4 signing key matches AWS published derivation vector" {
    // From the AWS docs "Examples of how to derive a signing key for Signature
    // Version 4": secret + 20120215/us-east-1/iam yields a documented signing key.
    var initial_key_buf: [4 + 256]u8 = undefined;
    const initial_key = try std.fmt.bufPrint(&initial_key_buf, "AWS4{s}", .{"wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"});
    const k_date = hmacSha256(initial_key, "20120215");
    const k_region = hmacSha256(k_date[0..], "us-east-1");
    const k_service = hmacSha256(k_region[0..], "iam");
    const k_signing = hmacSha256(k_service[0..], aws_sigv4_request);
    const signing_hex = std.fmt.bytesToHex(k_signing, .lower);
    try std.testing.expectEqualStrings(
        "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d",
        signing_hex[0..],
    );
}

test "AWS SigV4 core reproduces the get-vanilla test-suite signature" {
    // Official aws-sig-v4-test-suite "get-vanilla" vector: GET / with only the
    // host and x-amz-date headers signed over an empty payload.
    const empty_payload_hash = sha256Hex("");
    const canonical_headers = "host:example.amazonaws.com\nx-amz-date:20150830T123600Z\n";
    var inputs = try awsSigV4SignCanonical(
        std.testing.allocator,
        "GET",
        "/",
        "",
        canonical_headers,
        "host;x-amz-date",
        empty_payload_hash[0..],
        "AKIDEXAMPLE",
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        "us-east-1",
        "service",
        "20150830T123600Z",
        "20150830",
    );
    defer inputs.deinit(std.testing.allocator);

    // Published canonical-request hash and signature for get-vanilla.
    const canonical_request_hash = sha256Hex(inputs.canonical_request);
    try std.testing.expectEqualStrings(
        "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63",
        canonical_request_hash[0..],
    );
    try std.testing.expectEqualStrings(
        "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
        inputs.signature_hex[0..],
    );
    try std.testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
        inputs.authorization,
    );
}

test "Bedrock SigV4 builds a stable, structurally-correct authorization header" {
    const uri = try std.Uri.parse("https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-test-v1%3A0/converse-stream");
    const credentials = BedrockSigV4Credentials{
        .access_key_id = "AKIDEXAMPLE",
        .secret_access_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
    };
    const timestamp = AwsTimestamp{ .amz_date = "20150830T123600Z".*, .date_stamp = "20150830".* };
    const payload = "{\"messages\":[]}";

    var first = try signBedrockSigV4(std.testing.allocator, uri, credentials, payload, timestamp);
    defer first.deinit(std.testing.allocator);

    // Authorization carries the SigV4 algorithm, the bedrock-scoped credential,
    // the deterministic SignedHeaders subset, and a 64-hex-char signature.
    try std.testing.expect(std.mem.startsWith(u8, first.authorization, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/bedrock/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature="));
    const sig_marker = "Signature=";
    const sig_index = std.mem.indexOf(u8, first.authorization, sig_marker).?;
    const signature = first.authorization[sig_index + sig_marker.len ..];
    try std.testing.expectEqual(@as(usize, 64), signature.len);
    for (signature) |byte| try std.testing.expect(std.ascii.isHex(byte) and !std.ascii.isUpper(byte));

    // The signed x-amz-date header value matches the timestamp, and the content
    // hash header is the SHA-256 of the exact payload.
    try std.testing.expectEqualStrings("20150830T123600Z", first.amz_date.?);
    const expected_payload_hash = sha256Hex(payload);
    try std.testing.expectEqualStrings(expected_payload_hash[0..], first.content_sha256.?);
    try std.testing.expect(first.security_token == null);

    // Determinism: identical inputs reproduce an identical signature.
    var second = try signBedrockSigV4(std.testing.allocator, uri, credentials, payload, timestamp);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first.authorization, second.authorization);

    // Sensitivity: a different payload changes the signature.
    var changed_payload = try signBedrockSigV4(std.testing.allocator, uri, credentials, "{\"messages\":[{\"role\":\"user\"}]}", timestamp);
    defer changed_payload.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, first.authorization, changed_payload.authorization));

    // Sensitivity: a different request date changes the signature.
    const other_timestamp = AwsTimestamp{ .amz_date = "20150831T000000Z".*, .date_stamp = "20150831".* };
    var changed_date = try signBedrockSigV4(std.testing.allocator, uri, credentials, payload, other_timestamp);
    defer changed_date.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, first.authorization, changed_date.authorization));
}

test "Bedrock SigV4 session token participates in SignedHeaders and changes the signature" {
    const uri = try std.Uri.parse("https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-test-v1%3A0/converse-stream");
    const timestamp = AwsTimestamp{ .amz_date = "20150830T123600Z".*, .date_stamp = "20150830".* };
    const payload = "{\"messages\":[]}";

    const base = BedrockSigV4Credentials{
        .access_key_id = "AKIDEXAMPLE",
        .secret_access_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
    };
    var without_token = try signBedrockSigV4(std.testing.allocator, uri, base, payload, timestamp);
    defer without_token.deinit(std.testing.allocator);

    var with_token_creds = base;
    with_token_creds.session_token = "FAKESESSIONTOKEN==";
    var with_token = try signBedrockSigV4(std.testing.allocator, uri, with_token_creds, payload, timestamp);
    defer with_token.deinit(std.testing.allocator);

    // The security token must be sent as an extra header and folded into the
    // signed-header list, which in turn changes the computed signature.
    try std.testing.expectEqualStrings("FAKESESSIONTOKEN==", with_token.security_token.?);
    try std.testing.expect(std.mem.indexOf(u8, with_token.authorization, "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token") != null);
    try std.testing.expect(!std.mem.eql(u8, without_token.authorization, with_token.authorization));

    var buf: [3]std.http.Header = undefined;
    const headers = with_token.extraHeaders(&buf);
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("x-amz-date", headers[0].name);
    try std.testing.expectEqualStrings("x-amz-content-sha256", headers[1].name);
    try std.testing.expectEqualStrings("x-amz-security-token", headers[2].name);
    try std.testing.expectEqualStrings("FAKESESSIONTOKEN==", headers[2].value);
}

test "Bedrock SigV4 canonical URI and query are AWS encoded" {
    const uri = try std.Uri.parse("https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-test-v1%3A0/converse-stream?b=2&a=1%20space");
    const canonical_uri = try awsCanonicalUriPath(std.testing.allocator, uri);
    defer std.testing.allocator.free(canonical_uri);
    // ':' encodes to %3A, '/' separators are preserved.
    try std.testing.expectEqualStrings("/model/anthropic.claude-test-v1%3A0/converse-stream", canonical_uri);

    const canonical_query = try awsCanonicalQueryString(std.testing.allocator, uri);
    defer std.testing.allocator.free(canonical_query);
    // Parameters are sorted by key and values AWS-encoded (space -> %20).
    try std.testing.expectEqualStrings("a=1%20space&b=2", canonical_query);

    // The host header matches the URI authority emitted by std.http.Client,
    // including a non-default port.
    const ported = try std.Uri.parse("http://127.0.0.1:43123/model/x/converse-stream");
    const host = try awsHostHeaderValue(std.testing.allocator, ported);
    defer std.testing.allocator.free(host);
    try std.testing.expectEqualStrings("127.0.0.1:43123", host);
}

test "Bedrock auth selects bearer token over SigV4 and falls back to SigV4 for placeholder keys" {
    const uri = try std.Uri.parse("https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-test-v1%3A0/converse-stream");
    const payload = "{\"messages\":[]}";

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // IAM credentials are present, but a real bearer token must still win.
    try env.put("AWS_ACCESS_KEY_ID", "AKIDEXAMPLE");
    try env.put("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");

    var bearer = try bedrockAuth(std.testing.io, std.testing.allocator, &env, uri, "real-bearer-token", payload);
    defer bearer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Bearer real-bearer-token", bearer.authorization);
    try std.testing.expect(bearer.amz_date == null);

    // The ambient `<authenticated>` placeholder routes to SigV4 over the IAM creds.
    var sigv4 = try bedrockAuth(std.testing.io, std.testing.allocator, &env, uri, "<authenticated>", payload);
    defer sigv4.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, sigv4.authorization, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"));
    try std.testing.expect(std.mem.indexOf(u8, sigv4.authorization, "/us-east-1/bedrock/aws4_request") != null);
    try std.testing.expect(sigv4.amz_date != null);

    // A placeholder key with no IAM credentials is a client error, not a silent
    // empty bearer header.
    var empty_env = std.process.Environ.Map.init(std.testing.allocator);
    defer empty_env.deinit();
    try std.testing.expectError(error.ProviderClientError, bedrockAuth(std.testing.io, std.testing.allocator, &empty_env, uri, "<authenticated>", payload));
}

test "Bedrock SigV4 credential resolution honors region and session-token env precedence" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    // No creds -> no SigV4 credentials.
    try std.testing.expect(bedrockSigV4CredentialsFromEnv(&env) == null);

    try env.put("AWS_ACCESS_KEY_ID", "AKIDEXAMPLE");
    // Missing secret key still yields null.
    try std.testing.expect(bedrockSigV4CredentialsFromEnv(&env) == null);

    try env.put("AWS_SECRET_ACCESS_KEY", "secret");
    const default_region = bedrockSigV4CredentialsFromEnv(&env).?;
    try std.testing.expectEqualStrings("us-east-1", default_region.region);
    try std.testing.expect(default_region.session_token == null);

    try env.put("AWS_DEFAULT_REGION", "eu-west-1");
    try std.testing.expectEqualStrings("eu-west-1", bedrockSigV4CredentialsFromEnv(&env).?.region);

    // AWS_REGION takes precedence over AWS_DEFAULT_REGION.
    try env.put("AWS_REGION", "ap-southeast-2");
    try std.testing.expectEqualStrings("ap-southeast-2", bedrockSigV4CredentialsFromEnv(&env).?.region);

    try env.put("AWS_SESSION_TOKEN", "session-token");
    try std.testing.expectEqualStrings("session-token", bedrockSigV4CredentialsFromEnv(&env).?.session_token.?);

    try std.testing.expect(isBedrockPlaceholderApiKey("<authenticated>"));
    try std.testing.expect(isBedrockPlaceholderApiKey(""));
    try std.testing.expect(isBedrockPlaceholderApiKey("   "));
    try std.testing.expect(!isBedrockPlaceholderApiKey("AWS_BEARER_real_token"));
}

// === Image generation tests ===================================================

test "serializes OpenRouter image-generation request with modalities" {
    const input = [_]ChatContentPart{
        .{ .text = "draw a red square" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const image_only = try buildOpenRouterImagesPayload(std.testing.allocator, .{
        .provider = "openrouter",
        .model = "google/gemini-2.5-flash-image",
        .api_key = "unused",
        .input = input[0..],
    });
    defer std.testing.allocator.free(image_only);

    try std.testing.expect(std.mem.indexOf(u8, image_only, "\"model\":\"google/gemini-2.5-flash-image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, image_only, "\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"draw a red square\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,aGVsbG8=\"}}]}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, image_only, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, image_only, "\"modalities\":[\"image\"]") != null);

    const with_text = try buildOpenRouterImagesPayload(std.testing.allocator, .{
        .provider = "openrouter",
        .model = "google/gemini-2.5-flash-image",
        .api_key = "unused",
        .input = input[0..],
        .include_text = true,
    });
    defer std.testing.allocator.free(with_text);
    try std.testing.expect(std.mem.indexOf(u8, with_text, "\"modalities\":[\"image\",\"text\"]") != null);
}

test "rejects empty OpenRouter image-generation input" {
    const blank = [_]ChatContentPart{.{ .text = "   " }};
    try std.testing.expectError(error.EmptyPrompt, buildOpenRouterImagesPayload(std.testing.allocator, .{
        .provider = "openrouter",
        .model = "google/gemini-2.5-flash-image",
        .api_key = "unused",
        .input = blank[0..],
    }));
}

test "parses OpenRouter image-generation response into image and text parts" {
    const body =
        \\{"id":"gen-123","choices":[{"message":{"content":"here is your image","images":[{"image_url":{"url":"data:image/png;base64,aGVsbG8="}},{"image_url":"data:image/jpeg;base64,d29ybGQ="},{"image_url":"https://example.com/not-a-data-url.png"}]}}]}
    ;
    var result = try parseOpenRouterImagesResult(std.testing.allocator, body);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gen-123", result.response_id.?);
    // text part + two valid data-url images; the http(s) url is skipped.
    try std.testing.expectEqual(@as(usize, 3), result.output.len);
    try std.testing.expectEqualStrings("here is your image", result.output[0].text);
    try std.testing.expectEqualStrings("image/png", result.output[1].image.mime_type);
    try std.testing.expectEqualStrings("aGVsbG8=", result.output[1].image.data);
    try std.testing.expectEqualStrings("image/jpeg", result.output[2].image.mime_type);
    try std.testing.expectEqualStrings("d29ybGQ=", result.output[2].image.data);
}

test "parses OpenRouter image-generation response with no images" {
    const body =
        \\{"id":"gen-empty","choices":[{"message":{"content":"refused"}}]}
    ;
    var result = try parseOpenRouterImagesResult(std.testing.allocator, body);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.output.len);
    try std.testing.expectEqualStrings("refused", result.output[0].text);
}

test "parses base64 data URLs and rejects non-data URLs" {
    const ok = parseBase64DataUrl("data:image/png;base64,aGVsbG8=").?;
    try std.testing.expectEqualStrings("image/png", ok.mime_type);
    try std.testing.expectEqualStrings("aGVsbG8=", ok.data);

    try std.testing.expect(parseBase64DataUrl("https://example.com/foo.png") == null);
    try std.testing.expect(parseBase64DataUrl("data:image/png,notbase64") == null);
    try std.testing.expect(parseBase64DataUrl("data:;base64,abc") == null);
    try std.testing.expect(parseBase64DataUrl("data:image/png;base64,") == null);
}

test "image-generation endpoint defaults to OpenRouter and honors overrides" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const default_endpoint = try imageGenerationEndpointForProvider(std.testing.allocator, &env, "openrouter");
    defer std.testing.allocator.free(default_endpoint);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", default_endpoint);

    try env.put("PI_ZIG_IMAGES_BASE_URL", "http://127.0.0.1:43321/v1/");
    const override_endpoint = try imageGenerationEndpointForProvider(std.testing.allocator, &env, "openrouter");
    defer std.testing.allocator.free(override_endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:43321/v1/chat/completions", override_endpoint);
}

// === Azure OpenAI Responses tests =============================================

test "Azure Responses endpoint maps deployment name and api-version" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    // Resource-name derivation + default api-version.
    try env.put("AZURE_OPENAI_RESOURCE_NAME", "contoso");
    const from_resource = try azureOpenAIResponsesEndpoint(std.testing.allocator, &env, "gpt-5");
    defer std.testing.allocator.free(from_resource);
    try std.testing.expectEqualStrings(
        "https://contoso.openai.azure.com/openai/v1/deployments/gpt-5/responses?api-version=v1",
        from_resource,
    );

    // Explicit base URL wins over resource name; deployment-name map applies.
    try env.put("AZURE_OPENAI_BASE_URL", "https://contoso.openai.azure.com/openai/v1/");
    try env.put("AZURE_OPENAI_DEPLOYMENT_NAME_MAP", "gpt-5=prod-gpt5,gpt-4o=prod-4o");
    try env.put("AZURE_OPENAI_API_VERSION", "2025-04-01-preview");
    const mapped = try azureOpenAIResponsesEndpoint(std.testing.allocator, &env, "gpt-5");
    defer std.testing.allocator.free(mapped);
    try std.testing.expectEqualStrings(
        "https://contoso.openai.azure.com/openai/v1/deployments/prod-gpt5/responses?api-version=2025-04-01-preview",
        mapped,
    );

    // Unmapped model falls back to its own id as the deployment name.
    const unmapped = try azureOpenAIResponsesEndpoint(std.testing.allocator, &env, "o3-mini");
    defer std.testing.allocator.free(unmapped);
    try std.testing.expectEqualStrings(
        "https://contoso.openai.azure.com/openai/v1/deployments/o3-mini/responses?api-version=2025-04-01-preview",
        unmapped,
    );
}

test "Azure Responses endpoint requires base URL or resource name" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.UnsupportedProvider, azureOpenAIResponsesEndpoint(std.testing.allocator, &env, "gpt-5"));
}

test "Azure Responses endpoint accepts test override base URL" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43777");
    try env.put("AZURE_OPENAI_DEPLOYMENT_NAME_MAP", "gpt-5=dep-5");
    const endpoint = try azureOpenAIResponsesEndpoint(std.testing.allocator, &env, "gpt-5");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:43777/deployments/dep-5/responses?api-version=v1",
        endpoint,
    );
}

test "serializes Azure Responses payload as input items" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("AZURE_OPENAI_DEPLOYMENT_NAME_MAP", "azure-test=prod-deployment");

    const user_parts = [_]ChatContentPart{
        .{ .text = "inspect this" },
        .{ .image = .{ .mime_type = "image/png", .data = "aGVsbG8=" } },
    };
    const tool_calls = [_]ChatToolCall{
        .{ .id = @constCast("call_1"), .name = @constCast("bash"), .arguments_json = @constCast("{\"command\":\"ls\"}") },
    };
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "be terse" },
        .{ .role = .user, .content_parts = user_parts[0..] },
        .{ .role = .assistant, .content = "running", .tool_calls = tool_calls[0..] },
        .{ .role = .tool, .content = "done", .tool_call_id = "call_1" },
    };
    const tools = [_]ChatToolDefinition{
        .{ .name = "bash", .description = "run shell", .parameters_json = "{\"type\":\"object\"}" },
    };
    const payload = try buildAzureResponsesPayload(std.testing.allocator, &env, .{
        .provider = "azure-openai-responses",
        .model = "azure-test",
        .api_key = "unused",
        .messages = messages[0..],
        .tools = tools[0..],
    }, true);
    defer std.testing.allocator.free(payload);

    // The wire model is the resolved deployment name, not the catalog id.
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"model\":\"prod-deployment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"role\":\"system\",\"content\":\"be terse\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"inspect this\"},{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:image/png;base64,aGVsbG8=\"}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"running\",\"annotations\":[]}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":\"done\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"type\":\"function\",\"name\":\"bash\",\"description\":\"run shell\",\"parameters\":{\"type\":\"object\"},\"strict\":false}") != null);
}

test "Azure Responses payload emits reasoning effort for reasoning models and omits it otherwise" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "hi" },
    };

    // o3-mini (azure-openai-responses) is reasoning-capable with no
    // thinkingLevelMap.off override, so upstream buildParams emits
    // params.reasoning = { effort: "none" } in the default (no explicit
    // reasoningEffort) path.
    const reasoning_payload = try buildAzureResponsesPayload(std.testing.allocator, &env, .{
        .provider = "azure-openai-responses",
        .model = "o3-mini",
        .api_key = "unused",
        .messages = messages[0..],
    }, false);
    defer std.testing.allocator.free(reasoning_payload);
    try std.testing.expect(std.mem.indexOf(u8, reasoning_payload, "\"reasoning\":{\"effort\":\"none\"}") != null);
    // The default path never sets params.include (only the explicit
    // reasoningEffort/Summary branch does).
    try std.testing.expect(std.mem.indexOf(u8, reasoning_payload, "\"include\"") == null);

    // gpt-5 (azure-openai-responses) is reasoning-capable but has
    // thinkingLevelMap.off === null (thinking_off_disabled), so the upstream
    // else-if guard is false and no reasoning field is emitted.
    const off_null_payload = try buildAzureResponsesPayload(std.testing.allocator, &env, .{
        .provider = "azure-openai-responses",
        .model = "gpt-5",
        .api_key = "unused",
        .messages = messages[0..],
    }, false);
    defer std.testing.allocator.free(off_null_payload);
    try std.testing.expect(std.mem.indexOf(u8, off_null_payload, "\"reasoning\"") == null);

    // gpt-4o-mini is not a reasoning model: no reasoning field at all (this is
    // the model the wave2-transports smoke drives, so it must stay unchanged).
    const non_reasoning_payload = try buildAzureResponsesPayload(std.testing.allocator, &env, .{
        .provider = "azure-openai-responses",
        .model = "gpt-4o-mini",
        .api_key = "unused",
        .messages = messages[0..],
    }, false);
    defer std.testing.allocator.free(non_reasoning_payload);
    try std.testing.expect(std.mem.indexOf(u8, non_reasoning_payload, "\"reasoning\"") == null);
}

test "parses Azure/OpenAI Responses result text and tool calls" {
    const body =
        \\{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello azure"}]},{"type":"function_call","call_id":"call_9","name":"bash","arguments":"{\"command\":\"pwd\"}"}]}
    ;
    var result = try parseOpenAIResponsesResult(std.testing.allocator, body);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello azure", result.text.?);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_9", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", result.tool_calls[0].arguments_json);
}

// === Image resize (system-tool shell-out) tests ===============================

test "resize tool detection and round-trip when a system tool is present" {
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const tiny_png_b64 = tinyPngBase64();
    const tool = detectResizeTool(io, std.testing.allocator);
    if (tool == null) {
        // Documented divergence: with no system image tool (sips/magick/convert),
        // resize cannot run in-process and must surface ResizeToolUnavailable.
        try std.testing.expectError(error.ResizeToolUnavailable, resizeImageWithSystemTool(
            io,
            std.testing.allocator,
            &env,
            .{ .mime_type = "image/png", .data = tiny_png_b64 },
            64,
        ));
        return error.SkipZigTest;
    }

    var resized = try resizeImageWithSystemTool(
        io,
        std.testing.allocator,
        &env,
        .{ .mime_type = "image/png", .data = tiny_png_b64 },
        64,
    );
    defer resized.deinit(std.testing.allocator);
    // Re-encoded output must be non-empty, valid base64, and keep the mime type.
    try std.testing.expectEqualStrings("image/png", resized.image.mime_type);
    try std.testing.expect(resized.image.data.len > 0);
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(resized.image.data);
    try std.testing.expect(decoded_len > 0);
}

/// A minimal valid 1x1 PNG, base64-encoded, used to exercise the resize path.
fn tinyPngBase64() []const u8 {
    return "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC";
}

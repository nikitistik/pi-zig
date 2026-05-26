const std = @import("std");
const config = @import("config.zig");

pub const ChatCompletionRequest = struct {
    provider: []const u8,
    model: []const u8,
    api_key: []const u8,
    prompt: []const u8,
    system_prompt: ?[]const u8 = null,
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

    return parseOpenAICompatibleText(allocator, body);
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

fn buildPayload(allocator: std.mem.Allocator, request: ChatCompletionRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"model\":");
    try writeJsonString(w, request.model);
    try w.writeAll(",\"messages\":[");
    var first = true;
    if (request.system_prompt) |system_prompt| {
        const trimmed_system = std.mem.trim(u8, system_prompt, " \t\r\n");
        if (trimmed_system.len > 0) {
            try writeMessage(w, "system", trimmed_system);
            first = false;
        }
    }
    if (!first) try w.writeByte(',');
    try writeMessage(w, "user", request.prompt);
    try w.writeAll("],\"stream\":false}");
    return out.toOwnedSlice();
}

fn writeMessage(w: *std.Io.Writer, role: []const u8, content: []const u8) !void {
    try w.writeAll("{\"role\":");
    try writeJsonString(w, role);
    try w.writeAll(",\"content\":");
    try writeJsonString(w, content);
    try w.writeByte('}');
}

fn parseOpenAICompatibleText(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderResponseInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ProviderResponseInvalid;

    if (parsed.value.object.get("choices")) |choices| {
        if (choices != .array or choices.array.items.len == 0) return error.ProviderResponseInvalid;
        const first = choices.array.items[0];
        if (first != .object) return error.ProviderResponseInvalid;
        const message = first.object.get("message") orelse return error.ProviderResponseInvalid;
        if (message != .object) return error.ProviderResponseInvalid;
        const content = message.object.get("content") orelse return error.ProviderResponseInvalid;
        if (content == .string) return allocator.dupe(u8, content.string);
        if (content == .array) return parseContentParts(allocator, content.array.items);
        return error.ProviderResponseInvalid;
    }

    if (parsed.value.object.get("output_text")) |output_text| {
        if (output_text == .string) return allocator.dupe(u8, output_text.string);
    }

    return error.ProviderResponseInvalid;
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

test "provider base URL appends chat completions endpoint" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PI_ZIG_PROVIDER_BASE_URL", "http://127.0.0.1:43123/v1/");
    const endpoint = try endpointForProvider(std.testing.allocator, &env, "openai");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/chat/completions", endpoint);
}

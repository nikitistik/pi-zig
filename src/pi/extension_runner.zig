const std = @import("std");
const agent = @import("agent.zig");
const ai_client = @import("ai_client.zig");

const max_hook_payload_bytes = 1024 * 1024;
const max_hook_output_bytes = 1024 * 1024;

pub const Runner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    extension_paths: []const []const u8,

    pub fn hasExtensions(self: Runner) bool {
        return self.extension_paths.len > 0;
    }

    pub fn beforeToolCall(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall) anyerror!agent.BeforeToolCallResult {
        const self: *Runner = @ptrCast(@alignCast(ctx_ptr));
        return self.runBeforeToolCall(call);
    }

    pub fn afterToolCall(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall, result: agent.ToolResult) anyerror!agent.AfterToolCallResult {
        const self: *Runner = @ptrCast(@alignCast(ctx_ptr));
        return self.runAfterToolCall(call, result);
    }

    fn runBeforeToolCall(self: *Runner, call: ai_client.ChatToolCall) !agent.BeforeToolCallResult {
        if (!self.hasExtensions()) return .{};

        const payload = try self.buildToolCallPayload(call);
        defer self.allocator.free(payload);
        const output = try self.runNodeHook(payload);
        defer if (output) |bytes| self.allocator.free(bytes);
        const bytes = output orelse return .{};

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return error.ExtensionHookInvalidResponse;
        defer parsed.deinit();
        if (parsed.value == .null) return .{};
        if (parsed.value != .object) return error.ExtensionHookInvalidResponse;

        var result: agent.BeforeToolCallResult = .{};
        errdefer result.deinit(self.allocator);
        if (parsed.value.object.get("block")) |block| {
            if (block != .bool) return error.ExtensionHookInvalidResponse;
            result.block = block.bool;
        }
        if (parsed.value.object.get("reason")) |reason| {
            if (reason != .null) {
                if (reason != .string) return error.ExtensionHookInvalidResponse;
                result.reason = try self.allocator.dupe(u8, reason.string);
            }
        }
        if (!result.block) {
            if (parsed.value.object.get("argumentsJson")) |arguments_json| {
                if (arguments_json != .string) return error.ExtensionHookInvalidResponse;
                result.arguments_json = try self.allocator.dupe(u8, arguments_json.string);
            } else if (parsed.value.object.get("input")) |input| {
                result.arguments_json = try jsonValueToOwnedString(self.allocator, input);
            }
        }
        return result;
    }

    fn runAfterToolCall(self: *Runner, call: ai_client.ChatToolCall, result: agent.ToolResult) !agent.AfterToolCallResult {
        if (!self.hasExtensions()) return .{};

        const payload = try self.buildToolResultPayload(call, result);
        defer self.allocator.free(payload);
        const output = try self.runNodeHook(payload);
        defer if (output) |bytes| self.allocator.free(bytes);
        const bytes = output orelse return .{};

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return error.ExtensionHookInvalidResponse;
        defer parsed.deinit();
        if (parsed.value == .null) return .{};
        if (parsed.value != .object) return error.ExtensionHookInvalidResponse;

        var patch: agent.AfterToolCallResult = .{};
        errdefer patch.deinit(self.allocator);
        if (parsed.value.object.get("contentText")) |content_text| {
            if (content_text != .string) return error.ExtensionHookInvalidResponse;
            patch.content = try self.allocator.dupe(u8, content_text.string);
        } else if (parsed.value.object.get("content")) |content| {
            patch.content = try textContentToOwnedString(self.allocator, content);
        }
        if (parsed.value.object.get("isError")) |is_error| {
            if (is_error != .bool) return error.ExtensionHookInvalidResponse;
            patch.is_error = is_error.bool;
        }
        if (parsed.value.object.get("terminate")) |terminate| {
            if (terminate != .bool) return error.ExtensionHookInvalidResponse;
            patch.terminate = terminate.bool;
        }
        return patch;
    }

    fn buildToolCallPayload(self: *Runner, call: ai_client.ChatToolCall) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try self.writePayloadHead(w);
        try w.writeAll(",\"event\":{\"type\":\"tool_call\",\"toolCallId\":");
        try writeJsonString(w, call.id);
        try w.writeAll(",\"toolName\":");
        try writeJsonString(w, call.name);
        try w.writeAll(",\"input\":");
        try writeJsonObjectOrEmpty(self.allocator, w, call.arguments_json);
        try w.writeAll("}}");
        return out.toOwnedSlice();
    }

    fn buildToolResultPayload(self: *Runner, call: ai_client.ChatToolCall, result: agent.ToolResult) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try self.writePayloadHead(w);
        try w.writeAll(",\"event\":{\"type\":\"tool_result\",\"toolCallId\":");
        try writeJsonString(w, result.tool_call_id);
        try w.writeAll(",\"toolName\":");
        try writeJsonString(w, result.tool_name);
        try w.writeAll(",\"input\":");
        try writeJsonObjectOrEmpty(self.allocator, w, call.arguments_json);
        try w.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
        try writeJsonString(w, result.content);
        try w.writeAll("}],\"details\":null,\"isError\":");
        try w.writeAll(if (result.is_error) "true" else "false");
        try w.writeAll("}}");
        return out.toOwnedSlice();
    }

    fn writePayloadHead(self: *Runner, w: *std.Io.Writer) !void {
        try w.writeAll("{\"extensions\":[");
        for (self.extension_paths, 0..) |path, index| {
            if (index != 0) try w.writeByte(',');
            try writeJsonString(w, path);
        }
        try w.writeByte(']');
    }

    fn runNodeHook(self: *Runner, payload: []const u8) !?[]u8 {
        if (payload.len > max_hook_payload_bytes) return error.ExtensionHookPayloadTooLarge;
        const argv = [_][]const u8{ "node", "-e", hook_runner_script, payload };
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &argv,
            .stdout_limit = .limited(max_hook_output_bytes),
            .stderr_limit = .limited(128 * 1024),
            .expand_arg0 = .expand,
        });
        errdefer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) {
                const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
                if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) {
                    self.allocator.free(result.stdout);
                    return null;
                }
                const owned = try self.allocator.dupe(u8, trimmed);
                self.allocator.free(result.stdout);
                return owned;
            },
            else => {},
        }
        return error.ExtensionHookFailed;
    }
};

fn writeJsonObjectOrEmpty(allocator: std.mem.Allocator, w: *std.Io.Writer, json: []const u8) !void {
    const trimmed = std.mem.trim(u8, json, " \t\r\n");
    if (trimmed.len == 0) {
        try w.writeAll("{}");
        return;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        try w.writeAll("{}");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try w.writeAll("{}");
        return;
    }
    try w.writeAll(trimmed);
}

fn textContentToOwnedString(allocator: std.mem.Allocator, content: std.json.Value) ![]u8 {
    if (content != .array) return error.ExtensionHookInvalidResponse;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (content.array.items) |item| {
        if (item != .object) return error.ExtensionHookInvalidResponse;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text")) continue;
        const text = item.object.get("text") orelse continue;
        if (text != .string) return error.ExtensionHookInvalidResponse;
        if (out.written().len != 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(text.string);
    }
    return out.toOwnedSlice();
}

fn jsonValueToOwnedString(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.encodeJsonString(value, .{}, w);
}

const hook_runner_script =
    \\const { pathToFileURL } = require("node:url");
    \\const payload = JSON.parse(process.argv[1] || "{}");
    \\const handlers = new Map();
    \\const diagnostics = [];
    \\const api = {
    \\  on(type, handler) {
    \\    if (!handlers.has(type)) handlers.set(type, []);
    \\    handlers.get(type).push(handler);
    \\  },
    \\  registerTool() {},
    \\  registerCommand() {},
    \\  registerFlag() {},
    \\  events: { on() {}, emit() {} },
    \\};
    \\const ctx = {
    \\  hasUI: false,
    \\  ui: {
    \\    notify() {},
    \\    select: async (_message, options) => Array.isArray(options) ? options[0] : undefined,
    \\    prompt: async () => undefined,
    \\    confirm: async () => false,
    \\  },
    \\  diagnostics,
    \\};
    \\async function loadExtension(extensionPath) {
    \\  const mod = await import(pathToFileURL(require("node:path").resolve(extensionPath)).href);
    \\  const factory = typeof mod.default === "function" ? mod.default : typeof mod === "function" ? mod : null;
    \\  if (factory) await factory(api);
    \\}
    \\function contentText(content) {
    \\  if (!Array.isArray(content)) return undefined;
    \\  return content.filter((part) => part && part.type === "text").map((part) => String(part.text ?? "")).join("\n");
    \\}
    \\(async () => {
    \\  for (const extensionPath of payload.extensions || []) await loadExtension(extensionPath);
    \\  const event = payload.event;
    \\  const eventHandlers = handlers.get(event?.type) || [];
    \\  if (eventHandlers.length === 0) {
    \\    process.stdout.write("null\n");
    \\    return;
    \\  }
    \\  if (event.type === "tool_call") {
    \\    for (const handler of eventHandlers) {
    \\      const result = await handler(event, ctx);
    \\      if (result?.block) {
    \\        process.stdout.write(JSON.stringify({ block: true, reason: result.reason || "Tool execution was blocked" }) + "\n");
    \\        return;
    \\      }
    \\    }
    \\    process.stdout.write(JSON.stringify({ input: event.input ?? {} }) + "\n");
    \\    return;
    \\  }
    \\  if (event.type === "tool_result") {
    \\    let modified = false;
    \\    for (const handler of eventHandlers) {
    \\      const result = await handler(event, ctx);
    \\      if (!result) continue;
    \\      if (result.content !== undefined) {
    \\        event.content = result.content;
    \\        modified = true;
    \\      }
    \\      if (result.isError !== undefined) {
    \\        event.isError = Boolean(result.isError);
    \\        modified = true;
    \\      }
    \\      if (result.terminate !== undefined) {
    \\        event.terminate = Boolean(result.terminate);
    \\        modified = true;
    \\      }
    \\    }
    \\    process.stdout.write(modified ? JSON.stringify({ content: event.content, contentText: contentText(event.content), isError: event.isError, terminate: event.terminate }) + "\n" : "null\n");
    \\    return;
    \\  }
    \\  process.stdout.write("null\n");
    \\})().catch((err) => {
    \\  console.error(err && err.stack ? err.stack : String(err));
    \\  process.exit(1);
    \\});
;

test "extension hook runner blocks and rewrites tool calls" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/hook.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\export default function(pi) {
        \\  pi.on("tool_call", (event) => {
        \\    if (event.toolName === "bash" && event.input.command === "block") return { block: true, reason: "blocked by extension" };
        \\    if (event.toolName === "bash") event.input.command = "printf rewritten";
        \\  });
        \\  pi.on("tool_result", () => ({ content: [{ type: "text", text: "patched result" }], isError: true, terminate: true }));
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    var call = ai_client.ChatToolCall{
        .id = try allocator.dupe(u8, "call_1"),
        .name = try allocator.dupe(u8, "bash"),
        .arguments_json = try allocator.dupe(u8, "{\"command\":\"original\"}"),
    };
    defer call.deinit(allocator);
    var before = try runner.runBeforeToolCall(call);
    defer before.deinit(allocator);
    try std.testing.expect(before.block == false);
    try std.testing.expectEqualStrings("{\"command\":\"printf rewritten\"}", before.arguments_json.?);

    var block_call = ai_client.ChatToolCall{
        .id = try allocator.dupe(u8, "call_2"),
        .name = try allocator.dupe(u8, "bash"),
        .arguments_json = try allocator.dupe(u8, "{\"command\":\"block\"}"),
    };
    defer block_call.deinit(allocator);
    var blocked = try runner.runBeforeToolCall(block_call);
    defer blocked.deinit(allocator);
    try std.testing.expect(blocked.block);
    try std.testing.expectEqualStrings("blocked by extension", blocked.reason.?);

    var tool_result = agent.ToolResult{
        .tool_call_id = try allocator.dupe(u8, "call_1"),
        .tool_name = try allocator.dupe(u8, "bash"),
        .arguments_json = try allocator.dupe(u8, "{\"command\":\"printf rewritten\"}"),
        .content = try allocator.dupe(u8, "original result"),
    };
    defer tool_result.deinit(allocator);
    var after = try runner.runAfterToolCall(call, tool_result);
    defer after.deinit(allocator);
    try std.testing.expectEqualStrings("patched result", after.content.?);
    try std.testing.expect(after.is_error.?);
    try std.testing.expect(after.terminate.?);
}

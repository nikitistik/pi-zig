const std = @import("std");
const agent = @import("agent.zig");
const ai_client = @import("ai_client.zig");

const max_hook_payload_bytes = 1024 * 1024;
const max_hook_output_bytes = 1024 * 1024;

pub const Runner = struct {
    pub const FlagValue = struct {
        name: []const u8,
        value: ?[]const u8 = null,
    };

    io: std.Io,
    allocator: std.mem.Allocator,
    extension_paths: []const []const u8,
    flag_values: []const FlagValue = &.{},

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

    pub fn executeRegisteredTool(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall) anyerror!agent.ToolExecutionResult {
        const self: *Runner = @ptrCast(@alignCast(ctx_ptr));
        return self.runRegisteredTool(call);
    }

    pub fn discoverToolDefinitions(self: *Runner) ![]ai_client.ChatToolDefinition {
        if (!self.hasExtensions()) return &.{};

        const payload = try self.buildDiscoverToolsPayload();
        defer self.allocator.free(payload);
        const output = try self.runNodeHook(payload);
        defer if (output) |bytes| self.allocator.free(bytes);
        const bytes = output orelse return &.{};

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return error.ExtensionHookInvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.ExtensionHookInvalidResponse;
        const tools = parsed.value.object.get("tools") orelse return &.{};
        if (tools != .array) return error.ExtensionHookInvalidResponse;

        var definitions: std.ArrayList(ai_client.ChatToolDefinition) = .empty;
        errdefer {
            for (definitions.items) |definition| {
                self.allocator.free(definition.name);
                self.allocator.free(definition.description);
                self.allocator.free(definition.parameters_json);
            }
            definitions.deinit(self.allocator);
        }

        for (tools.array.items) |item| {
            if (item != .object) return error.ExtensionHookInvalidResponse;
            const name = item.object.get("name") orelse return error.ExtensionHookInvalidResponse;
            if (name != .string or name.string.len == 0) return error.ExtensionHookInvalidResponse;
            const description = item.object.get("description") orelse return error.ExtensionHookInvalidResponse;
            if (description != .string) return error.ExtensionHookInvalidResponse;
            const parameters = item.object.get("parameters") orelse return error.ExtensionHookInvalidResponse;

            try definitions.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name.string),
                .description = try self.allocator.dupe(u8, description.string),
                .parameters_json = try jsonValueToOwnedString(self.allocator, parameters),
            });
        }
        if (definitions.items.len == 0) return &.{};
        return definitions.toOwnedSlice(self.allocator);
    }

    pub fn deinitToolDefinitions(self: *Runner, definitions: []ai_client.ChatToolDefinition) void {
        for (definitions) |definition| {
            self.allocator.free(definition.name);
            self.allocator.free(definition.description);
            self.allocator.free(definition.parameters_json);
        }
        self.allocator.free(definitions);
    }

    pub const CommandDefinition = struct {
        name: []const u8,
        description: []const u8,
        source_info_json: []const u8,
    };

    pub fn discoverCommandDefinitions(self: *Runner) ![]CommandDefinition {
        if (!self.hasExtensions()) return &.{};

        const payload = try self.buildDiscoverCommandsPayload();
        defer self.allocator.free(payload);
        const output = try self.runNodeHook(payload);
        defer if (output) |bytes| self.allocator.free(bytes);
        const bytes = output orelse return &.{};

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return error.ExtensionHookInvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.ExtensionHookInvalidResponse;
        const commands = parsed.value.object.get("commands") orelse return &.{};
        if (commands != .array) return error.ExtensionHookInvalidResponse;

        var definitions: std.ArrayList(CommandDefinition) = .empty;
        errdefer {
            for (definitions.items) |definition| {
                self.allocator.free(definition.name);
                self.allocator.free(definition.description);
                self.allocator.free(definition.source_info_json);
            }
            definitions.deinit(self.allocator);
        }

        for (commands.array.items) |item| {
            if (item != .object) return error.ExtensionHookInvalidResponse;
            const name = item.object.get("name") orelse return error.ExtensionHookInvalidResponse;
            if (name != .string or name.string.len == 0) return error.ExtensionHookInvalidResponse;
            const description = item.object.get("description");
            if (description != null and description.? != .string) return error.ExtensionHookInvalidResponse;
            const source_info = item.object.get("sourceInfo") orelse return error.ExtensionHookInvalidResponse;
            if (source_info != .object) return error.ExtensionHookInvalidResponse;

            try definitions.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name.string),
                .description = try self.allocator.dupe(u8, if (description) |value| value.string else ""),
                .source_info_json = try jsonValueToOwnedString(self.allocator, source_info),
            });
        }
        if (definitions.items.len == 0) return &.{};
        return definitions.toOwnedSlice(self.allocator);
    }

    pub fn deinitCommandDefinitions(self: *Runner, definitions: []CommandDefinition) void {
        for (definitions) |definition| {
            self.allocator.free(definition.name);
            self.allocator.free(definition.description);
            self.allocator.free(definition.source_info_json);
        }
        self.allocator.free(definitions);
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
            if (content == .string) {
                patch.content = try self.allocator.dupe(u8, content.string);
            } else {
                patch.content = try textContentToOwnedString(self.allocator, content);
                patch.content_parts = try contentPartsToOwned(self.allocator, content);
            }
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

    fn runRegisteredTool(self: *Runner, call: ai_client.ChatToolCall) !agent.ToolExecutionResult {
        if (!self.hasExtensions()) return agent.ToolExecutionResult{
            .content = try std.fmt.allocPrint(self.allocator, "Tool {s} is not implemented in pi-zig yet.", .{call.name}),
            .is_error = true,
        };

        const payload = try self.buildExecuteToolPayload(call);
        defer self.allocator.free(payload);
        const output = try self.runNodeHook(payload);
        defer if (output) |bytes| self.allocator.free(bytes);
        const bytes = output orelse return .{ .content = try self.allocator.dupe(u8, "") };

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return error.ExtensionHookInvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.ExtensionHookInvalidResponse;

        var content: ?[]u8 = null;
        errdefer if (content) |value| self.allocator.free(value);
        var content_parts: []ai_client.ChatContentPart = &.{};
        errdefer freeContentParts(self.allocator, content_parts);
        if (parsed.value.object.get("contentText")) |content_text| {
            if (content_text != .string) return error.ExtensionHookInvalidResponse;
            content = try self.allocator.dupe(u8, content_text.string);
        } else if (parsed.value.object.get("content")) |result_content| {
            if (result_content == .string) {
                content = try self.allocator.dupe(u8, result_content.string);
            } else {
                content = try textContentToOwnedString(self.allocator, result_content);
                content_parts = try contentPartsToOwned(self.allocator, result_content);
            }
        } else {
            content = try self.allocator.dupe(u8, "");
        }

        var is_error = false;
        if (parsed.value.object.get("isError")) |value| {
            if (value != .bool) return error.ExtensionHookInvalidResponse;
            is_error = value.bool;
        }
        var terminate = false;
        if (parsed.value.object.get("terminate")) |value| {
            if (value != .bool) return error.ExtensionHookInvalidResponse;
            terminate = value.bool;
        }

        return .{
            .content = content.?,
            .content_parts = content_parts,
            .is_error = is_error,
            .terminate = terminate,
        };
    }

    fn buildDiscoverToolsPayload(self: *Runner) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try self.writePayloadHead(w);
        try w.writeAll(",\"event\":{\"type\":\"discover_tools\"}}");
        return out.toOwnedSlice();
    }

    fn buildDiscoverCommandsPayload(self: *Runner) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try self.writePayloadHead(w);
        try w.writeAll(",\"event\":{\"type\":\"discover_commands\"}}");
        return out.toOwnedSlice();
    }

    fn buildExecuteToolPayload(self: *Runner, call: ai_client.ChatToolCall) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try self.writePayloadHead(w);
        try w.writeAll(",\"event\":{\"type\":\"execute_tool\",\"toolCallId\":");
        try writeJsonString(w, call.id);
        try w.writeAll(",\"toolName\":");
        try writeJsonString(w, call.name);
        try w.writeAll(",\"input\":");
        try writeJsonObjectOrEmpty(self.allocator, w, call.arguments_json);
        try w.writeAll("}}");
        return out.toOwnedSlice();
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
        try w.writeAll(",\"content\":");
        try writeToolResultContentJson(w, result);
        try w.writeAll(",\"details\":null,\"isError\":");
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
        try w.writeAll("],\"flags\":{");
        for (self.flag_values, 0..) |flag, index| {
            if (index != 0) try w.writeByte(',');
            try writeJsonString(w, flag.name);
            try w.writeByte(':');
            if (flag.value) |value| {
                try writeJsonString(w, value);
            } else {
                try w.writeAll("true");
            }
        }
        try w.writeByte('}');
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
        errdefer self.allocator.free(result.stdout);
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

fn contentPartsToOwned(allocator: std.mem.Allocator, content: std.json.Value) ![]ai_client.ChatContentPart {
    if (content != .array) return error.ExtensionHookInvalidResponse;
    if (content.array.items.len == 0) return &.{};

    const parts = try allocator.alloc(ai_client.ChatContentPart, content.array.items.len);
    var len: usize = 0;
    errdefer {
        for (parts[0..len]) |part| {
            switch (part) {
                .text => |text| allocator.free(text),
                .image => |image| {
                    allocator.free(image.data);
                    allocator.free(image.mime_type);
                },
            }
        }
        allocator.free(parts);
    }

    for (content.array.items) |item| {
        if (item != .object) return error.ExtensionHookInvalidResponse;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string) return error.ExtensionHookInvalidResponse;
        if (std.mem.eql(u8, kind.string, "text")) {
            const text = item.object.get("text") orelse continue;
            if (text != .string) return error.ExtensionHookInvalidResponse;
            parts[len] = .{ .text = try allocator.dupe(u8, text.string) };
            len += 1;
        } else if (std.mem.eql(u8, kind.string, "image")) {
            const data = item.object.get("data") orelse return error.ExtensionHookInvalidResponse;
            const mime_type = item.object.get("mimeType") orelse return error.ExtensionHookInvalidResponse;
            if (data != .string or mime_type != .string) return error.ExtensionHookInvalidResponse;
            const owned_data = try allocator.dupe(u8, data.string);
            errdefer allocator.free(owned_data);
            const owned_mime_type = try allocator.dupe(u8, mime_type.string);
            errdefer allocator.free(owned_mime_type);
            parts[len] = .{ .image = .{
                .data = owned_data,
                .mime_type = owned_mime_type,
            } };
            len += 1;
        }
    }
    if (len == 0) {
        allocator.free(parts);
        return &.{};
    }
    if (len == parts.len) return parts;
    const trimmed = try allocator.realloc(parts, len);
    return trimmed;
}

fn freeContentParts(allocator: std.mem.Allocator, parts: []ai_client.ChatContentPart) void {
    if (parts.len == 0) return;
    for (parts) |part| {
        switch (part) {
            .text => |text| allocator.free(text),
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
        }
    }
    allocator.free(parts);
}

fn writeToolResultContentJson(w: *std.Io.Writer, result: agent.ToolResult) !void {
    if (result.content_parts.len == 0) {
        try w.writeAll("[{\"type\":\"text\",\"text\":");
        try writeJsonString(w, result.content);
        try w.writeAll("}]");
        return;
    }
    try w.writeByte('[');
    for (result.content_parts, 0..) |part, index| {
        if (index != 0) try w.writeByte(',');
        switch (part) {
            .text => |text| {
                try w.writeAll("{\"type\":\"text\",\"text\":");
                try writeJsonString(w, text);
                try w.writeByte('}');
            },
            .image => |image| {
                try w.writeAll("{\"type\":\"image\",\"data\":");
                try writeJsonString(w, image.data);
                try w.writeAll(",\"mimeType\":");
                try writeJsonString(w, image.mime_type);
                try w.writeByte('}');
            },
        }
    }
    try w.writeByte(']');
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
    \\const fs = require("node:fs");
    \\const path = require("node:path");
    \\const moduleApi = require("node:module");
    \\const { createRequire } = moduleApi;
    \\const { fileURLToPath, pathToFileURL } = require("node:url");
    \\function requireFromPackage(packageJson, specifier) {
    \\  try {
    \\    return createRequire(pathToFileURL(packageJson).href)(specifier);
    \\  } catch {
    \\    return undefined;
    \\  }
    \\}
    \\function loadTypeScriptCompiler() {
    \\  const candidates = [
    \\    path.join(process.cwd(), "package.json"),
    \\    path.join(process.cwd(), "frontend", "package.json"),
    \\  ];
    \\  let cursor = process.cwd();
    \\  for (;;) {
    \\    candidates.push(path.join(cursor, "package.json"));
    \\    const parent = path.dirname(cursor);
    \\    if (parent === cursor) break;
    \\    cursor = parent;
    \\  }
    \\  for (const candidate of candidates) {
    \\    const ts = requireFromPackage(candidate, "typescript");
    \\    if (ts) return ts;
    \\  }
    \\  try {
    \\    return require("typescript");
    \\  } catch {
    \\    return undefined;
    \\  }
    \\}
    \\function makeTypeScriptTransformer() {
    \\  if (typeof moduleApi.stripTypeScriptTypes === "function") {
    \\    return (source, url) => moduleApi.stripTypeScriptTypes(source, { mode: "transform", sourceUrl: url });
    \\  }
    \\  const ts = loadTypeScriptCompiler();
    \\  if (!ts) return undefined;
    \\  return (source, url) => {
    \\    const output = ts.transpileModule(source, {
    \\      compilerOptions: {
    \\        module: ts.ModuleKind.ES2022,
    \\        target: ts.ScriptTarget.ES2022,
    \\        esModuleInterop: true,
    \\        moduleResolution: ts.ModuleResolutionKind.Bundler ?? ts.ModuleResolutionKind.NodeNext,
    \\        sourceMap: false,
    \\        inlineSources: false,
    \\      },
    \\    }).outputText;
    \\    return output + "\n//# sourceURL=" + url + "\n";
    \\  };
    \\}
    \\const transformTypeScript = makeTypeScriptTransformer();
    \\let typeScriptHooksRegistered = false;
    \\if (typeof moduleApi.registerHooks === "function" && transformTypeScript) {
    \\  moduleApi.registerHooks({
    \\    load(url, context, nextLoad) {
    \\      if (url.startsWith("file:")) {
    \\        const filename = fileURLToPath(url);
    \\        if (filename.endsWith(".ts")) {
    \\          const source = fs.readFileSync(filename, "utf8");
    \\          return { format: "module", shortCircuit: true, source: transformTypeScript(source, url) };
    \\        }
    \\      }
    \\      return nextLoad(url, context);
    \\    },
    \\  });
    \\  typeScriptHooksRegistered = true;
    \\}
    \\async function importExtensionModule(resolvedPath) {
    \\  const url = pathToFileURL(resolvedPath).href;
    \\  if (!resolvedPath.endsWith(".ts") || typeScriptHooksRegistered) return import(url);
    \\  if (!transformTypeScript) {
    \\    throw new Error("TypeScript extension support requires Node.js type stripping or the typescript package");
    \\  }
    \\  const source = fs.readFileSync(resolvedPath, "utf8");
    \\  const encoded = Buffer.from(transformTypeScript(source, url)).toString("base64");
    \\  return import("data:text/javascript;base64," + encoded);
    \\}
    \\const payload = JSON.parse(process.argv[1] || "{}");
    \\const handlers = new Map();
    \\const extensionToolMaps = [];
    \\const extensionCommandMaps = [];
    \\const extensionFlagMaps = [];
    \\let activeToolMap = null;
    \\let activeCommandMap = null;
    \\let activeFlagMap = null;
    \\const payloadFlags = payload.flags && typeof payload.flags === "object" ? payload.flags : {};
    \\const diagnostics = [];
    \\const api = {
    \\  on(type, handler) {
    \\    if (!handlers.has(type)) handlers.set(type, []);
    \\    handlers.get(type).push(handler);
    \\  },
    \\  registerTool(tool) {
    \\    if (tool && typeof tool.name === "string" && activeToolMap) activeToolMap.set(tool.name, tool);
    \\  },
    \\  registerCommand(name, options) {
    \\    if (typeof name === "string" && name.length > 0 && activeCommandMap) activeCommandMap.set(name, { name, ...(options || {}) });
    \\  },
    \\  registerFlag(name, options) {
    \\    if (typeof name === "string" && name.length > 0 && activeFlagMap) activeFlagMap.set(name, { name, ...(options || {}) });
    \\  },
    \\  getFlag(name) {
    \\    if (Object.prototype.hasOwnProperty.call(payloadFlags, name)) return payloadFlags[name];
    \\    const active = activeFlagMap && activeFlagMap.get(name);
    \\    if (active && Object.prototype.hasOwnProperty.call(active, "default")) return active.default;
    \\    if (active && Object.prototype.hasOwnProperty.call(active, "defaultValue")) return active.defaultValue;
    \\    for (const flagMap of extensionFlagMaps) {
    \\      const flag = flagMap.get(name);
    \\      if (!flag) continue;
    \\      if (Object.prototype.hasOwnProperty.call(flag, "default")) return flag.default;
    \\      if (Object.prototype.hasOwnProperty.call(flag, "defaultValue")) return flag.defaultValue;
    \\    }
    \\    return undefined;
    \\  },
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
    \\  const resolvedExtensionPath = path.resolve(extensionPath);
    \\  const mod = await importExtensionModule(resolvedExtensionPath);
    \\  const factory = typeof mod.default === "function" ? mod.default : typeof mod === "function" ? mod : null;
    \\  const toolMap = new Map();
    \\  const commandMap = new Map();
    \\  const flagMap = new Map();
    \\  const previousToolMap = activeToolMap;
    \\  const previousCommandMap = activeCommandMap;
    \\  const previousFlagMap = activeFlagMap;
    \\  activeToolMap = toolMap;
    \\  activeCommandMap = commandMap;
    \\  activeFlagMap = flagMap;
    \\  try {
    \\    if (factory) await factory(api);
    \\  } finally {
    \\    activeToolMap = previousToolMap;
    \\    activeCommandMap = previousCommandMap;
    \\    activeFlagMap = previousFlagMap;
    \\  }
    \\  extensionToolMaps.push(toolMap);
    \\  extensionCommandMaps.push({ extensionPath: resolvedExtensionPath, commands: commandMap });
    \\  extensionFlagMaps.push(flagMap);
    \\}
    \\function allRegisteredTools() {
    \\  const toolsByName = new Map();
    \\  for (const toolMap of extensionToolMaps) {
    \\    for (const tool of toolMap.values()) {
    \\      if (!toolsByName.has(tool.name)) toolsByName.set(tool.name, tool);
    \\    }
    \\  }
    \\  return Array.from(toolsByName.values());
    \\}
    \\function sourceInfoForExtension(extensionPath) {
    \\  return { path: extensionPath, source: "extension", scope: "temporary", origin: "top-level", baseDir: path.dirname(extensionPath) };
    \\}
    \\function allRegisteredCommands() {
    \\  const commands = [];
    \\  const counts = new Map();
    \\  for (const entry of extensionCommandMaps) {
    \\    for (const command of entry.commands.values()) {
    \\      commands.push({ ...command, extensionPath: entry.extensionPath });
    \\      counts.set(command.name, (counts.get(command.name) || 0) + 1);
    \\    }
    \\  }
    \\  const seen = new Map();
    \\  const taken = new Set();
    \\  return commands.map((command) => {
    \\    const occurrence = (seen.get(command.name) || 0) + 1;
    \\    seen.set(command.name, occurrence);
    \\    let invocationName = (counts.get(command.name) || 0) > 1 ? `${command.name}:${occurrence}` : command.name;
    \\    if (taken.has(invocationName)) {
    \\      let suffix = occurrence;
    \\      do {
    \\        suffix++;
    \\        invocationName = `${command.name}:${suffix}`;
    \\      } while (taken.has(invocationName));
    \\    }
    \\    taken.add(invocationName);
    \\    return { ...command, invocationName };
    \\  });
    \\}
    \\function contentText(content) {
    \\  if (!Array.isArray(content)) return undefined;
    \\  return content.filter((part) => part && part.type === "text").map((part) => String(part.text ?? "")).join("\n");
    \\}
    \\function toolParameters(tool) {
    \\  return tool.parameters ?? tool.parametersJsonSchema ?? tool.schema ?? { type: "object", properties: {}, additionalProperties: true };
    \\}
    \\function toolSummary(tool) {
    \\  return {
    \\    name: String(tool.name),
    \\    description: String(tool.description ?? tool.label ?? tool.name),
    \\    parameters: toolParameters(tool),
    \\  };
    \\}
    \\function normalizeToolResult(result) {
    \\  if (result === undefined || result === null) return { content: [{ type: "text", text: "" }], contentText: "", isError: false, terminate: false };
    \\  const content = result.content !== undefined ? result.content : [{ type: "text", text: String(result) }];
    \\  const text = Array.isArray(content) ? contentText(content) : String(content ?? "");
    \\  return { content, contentText: text, isError: Boolean(result.isError), terminate: Boolean(result.terminate) };
    \\}
    \\(async () => {
    \\  for (const extensionPath of payload.extensions || []) {
    \\    try {
    \\      await loadExtension(extensionPath);
    \\    } catch (err) {
    \\      diagnostics.push({ extensionPath: String(extensionPath), error: err && err.message ? err.message : String(err) });
    \\    }
    \\  }
    \\  const event = payload.event;
    \\  if (event?.type === "discover_tools") {
    \\    process.stdout.write(JSON.stringify({ tools: allRegisteredTools().map(toolSummary) }) + "\n");
    \\    return;
    \\  }
    \\  if (event?.type === "discover_commands") {
    \\    process.stdout.write(JSON.stringify({ commands: allRegisteredCommands().map((command) => ({
    \\      name: String(command.invocationName),
    \\      description: String(command.description ?? ""),
    \\      sourceInfo: sourceInfoForExtension(command.extensionPath),
    \\    })) }) + "\n");
    \\    return;
    \\  }
    \\  if (event?.type === "execute_tool") {
    \\    const tool = allRegisteredTools().find((candidate) => candidate.name === event.toolName);
    \\    if (!tool || typeof tool.execute !== "function") throw new Error(`Extension tool not found: ${event.toolName}`);
    \\    process.stdout.write(JSON.stringify(normalizeToolResult(await tool.execute(event.toolCallId, event.input ?? {}, undefined, undefined, ctx))) + "\n");
    \\    return;
    \\  }
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

test "extension runner discovers and executes registered tools" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-tool-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/tool.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\export default function(pi) {
        \\  pi.registerTool({
        \\    name: "hello_ext",
        \\    label: "Hello Ext",
        \\    description: "Greet through an extension tool",
        \\    parameters: {
        \\      type: "object",
        \\      properties: { name: { type: "string" } },
        \\      required: ["name"],
        \\      additionalProperties: false
        \\    },
        \\    execute: async (_toolCallId, params) => ({
        \\      content: [{ type: "text", text: `hello ${params.name}` }],
        \\      isError: false
        \\    })
        \\  });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    const definitions = try runner.discoverToolDefinitions();
    defer runner.deinitToolDefinitions(definitions);
    try std.testing.expectEqual(@as(usize, 1), definitions.len);
    try std.testing.expectEqualStrings("hello_ext", definitions[0].name);
    try std.testing.expectEqualStrings("Greet through an extension tool", definitions[0].description);
    try std.testing.expect(std.mem.indexOf(u8, definitions[0].parameters_json, "\"required\":[\"name\"]") != null);

    var call = ai_client.ChatToolCall{
        .id = try allocator.dupe(u8, "call_ext_1"),
        .name = try allocator.dupe(u8, "hello_ext"),
        .arguments_json = try allocator.dupe(u8, "{\"name\":\"world\"}"),
    };
    defer call.deinit(allocator);
    const result = try runner.runRegisteredTool(call);
    defer allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("hello world", result.content);
}

test "extension runner keeps first extension tool when names collide" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-tool-conflict-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const first_path = fixture_dir ++ "/a-first.mjs";
    const second_path = fixture_dir ++ "/b-second.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = first_path, .data =
        \\export default function(pi) {
        \\  pi.registerTool({
        \\    name: "shared_ext",
        \\    description: "first initial",
        \\    parameters: { type: "object", properties: {}, additionalProperties: false },
        \\    execute: async () => ({ content: [{ type: "text", text: "first initial" }], isError: false })
        \\  });
        \\  pi.registerTool({
        \\    name: "shared_ext",
        \\    description: "first final",
        \\    parameters: { type: "object", properties: {}, additionalProperties: false },
        \\    execute: async () => ({ content: [{ type: "text", text: "first final" }], isError: false })
        \\  });
        \\}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = second_path, .data =
        \\export default function(pi) {
        \\  pi.registerTool({
        \\    name: "shared_ext",
        \\    description: "second",
        \\    parameters: { type: "object", properties: {}, additionalProperties: false },
        \\    execute: async () => ({ content: [{ type: "text", text: "second" }], isError: false })
        \\  });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{ first_path, second_path } };
    const definitions = try runner.discoverToolDefinitions();
    defer runner.deinitToolDefinitions(definitions);
    try std.testing.expectEqual(@as(usize, 1), definitions.len);
    try std.testing.expectEqualStrings("shared_ext", definitions[0].name);
    try std.testing.expectEqualStrings("first final", definitions[0].description);

    var call = ai_client.ChatToolCall{
        .id = try allocator.dupe(u8, "call_shared_ext_1"),
        .name = try allocator.dupe(u8, "shared_ext"),
        .arguments_json = try allocator.dupe(u8, "{}"),
    };
    defer call.deinit(allocator);
    const result = try runner.runRegisteredTool(call);
    defer allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("first final", result.content);
}

test "extension runner discovers registered commands with upstream invocation names" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-command-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const first_path = fixture_dir ++ "/a-first.mjs";
    const second_path = fixture_dir ++ "/b-second.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = first_path, .data =
        \\export default function(pi) {
        \\  pi.registerCommand("deploy", { description: "Deploy from first", handler: async () => {} });
        \\  pi.registerCommand("review", { description: "Review from first", handler: async () => {} });
        \\}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = second_path, .data =
        \\export default function(pi) {
        \\  pi.registerCommand("deploy", { description: "Deploy from second", handler: async () => {} });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{ first_path, second_path } };
    const definitions = try runner.discoverCommandDefinitions();
    defer runner.deinitCommandDefinitions(definitions);
    try std.testing.expectEqual(@as(usize, 3), definitions.len);
    try std.testing.expectEqualStrings("deploy:1", definitions[0].name);
    try std.testing.expectEqualStrings("Deploy from first", definitions[0].description);
    try std.testing.expect(std.mem.indexOf(u8, definitions[0].source_info_json, "\"source\":\"extension\"") != null);
    try std.testing.expectEqualStrings("review", definitions[1].name);
    try std.testing.expectEqualStrings("Review from first", definitions[1].description);
    try std.testing.expectEqualStrings("deploy:2", definitions[2].name);
    try std.testing.expectEqualStrings("Deploy from second", definitions[2].description);
}

test "extension runner loads TypeScript registered tools" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-ts-tool-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const helper_path = fixture_dir ++ "/helper.ts";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = helper_path, .data =
        \\export const prefix: string = "ts";
    });
    const extension_path = fixture_dir ++ "/tool.ts";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\import { prefix } from "./helper.ts";
        \\
        \\type Params = { name: string };
        \\
        \\export default function(pi: any): void {
        \\  pi.registerTool({
        \\    name: "ts_echo",
        \\    description: "Echo through a TypeScript extension tool",
        \\    parameters: {
        \\      type: "object",
        \\      properties: { name: { type: "string" } },
        \\      required: ["name"],
        \\      additionalProperties: false
        \\    },
        \\    execute: async (_toolCallId: string, params: Params) => ({
        \\      content: [{ type: "text", text: prefix + ": " + params.name }],
        \\      isError: false
        \\    })
        \\  });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    const definitions = try runner.discoverToolDefinitions();
    defer runner.deinitToolDefinitions(definitions);
    try std.testing.expectEqual(@as(usize, 1), definitions.len);
    try std.testing.expectEqualStrings("ts_echo", definitions[0].name);
    try std.testing.expectEqualStrings("Echo through a TypeScript extension tool", definitions[0].description);

    var call = ai_client.ChatToolCall{
        .id = try allocator.dupe(u8, "call_ts_ext_1"),
        .name = try allocator.dupe(u8, "ts_echo"),
        .arguments_json = try allocator.dupe(u8, "{\"name\":\"world\"}"),
    };
    defer call.deinit(allocator);
    const result = try runner.runRegisteredTool(call);
    defer allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("ts: world", result.content);
}

test "extension runner exposes registered flag defaults and overrides" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-flag-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/flags.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\export default function(pi) {
        \\  pi.registerFlag("mode", { default: "default-mode" });
        \\  pi.registerFlag("debug", { default: false });
        \\  pi.registerTool({
        \\    name: "flag_echo",
        \\    description: "Echo extension flag values",
        \\    parameters: { type: "object", properties: {}, additionalProperties: false },
        \\    execute: async () => ({
        \\      content: [{
        \\        type: "text",
        \\        text: `mode=${String(pi.getFlag("mode"))};debug=${String(pi.getFlag("debug"))};missing=${String(pi.getFlag("missing"))}`
        \\      }],
        \\      isError: false
        \\    })
        \\  });
        \\}
    });

    var call = ai_client.ChatToolCall{
        .id = try allocator.dupe(u8, "call_flag_ext_1"),
        .name = try allocator.dupe(u8, "flag_echo"),
        .arguments_json = try allocator.dupe(u8, "{}"),
    };
    defer call.deinit(allocator);

    var default_runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    const default_result = try default_runner.runRegisteredTool(call);
    defer allocator.free(default_result.content);
    try std.testing.expect(!default_result.is_error);
    try std.testing.expectEqualStrings("mode=default-mode;debug=false;missing=undefined", default_result.content);

    const flag_values = [_]Runner.FlagValue{
        .{ .name = "mode", .value = "override-mode" },
        .{ .name = "debug", .value = null },
    };
    var override_runner = Runner{
        .io = std.testing.io,
        .allocator = allocator,
        .extension_paths = &.{extension_path},
        .flag_values = &flag_values,
    };
    const override_result = try override_runner.runRegisteredTool(call);
    defer allocator.free(override_result.content);
    try std.testing.expect(!override_result.is_error);
    try std.testing.expectEqualStrings("mode=override-mode;debug=true;missing=undefined", override_result.content);
}

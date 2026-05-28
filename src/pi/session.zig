const std = @import("std");
const ai_client = @import("ai_client.zig");
const html_export = @import("html_export.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");

pub const default_session_file = "zig-out/pi-zig-session.jsonl";
const max_path_bytes = std.Io.Dir.max_path_bytes;
const max_session_id_bytes = 96;
const max_entry_id_bytes = 32;
const max_header_bytes = 4096;

pub const SessionState = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    messages: []const types.Message = &.{},
    is_streaming: bool = false,
    is_compacting: bool = false,

    pub fn messageCount(self: SessionState) usize {
        return self.messages.len;
    }

    pub fn hasMessages(self: SessionState) bool {
        return self.messages.len > 0;
    }
};

pub const QueuedMessage = struct {
    content: []const u8,
    delivery: Delivery,
};

pub const Delivery = enum {
    immediate,
    steer,
    follow_up,
};

pub const PersistentStore = struct {
    path_buf: [max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    session_id_buf: [max_session_id_bytes]u8 = undefined,
    session_id_len: usize = 0,
    leaf_id_buf: [max_entry_id_bytes]u8 = undefined,
    leaf_id_len: usize = 0,
    entry_counter: usize = 0,
    user_messages: usize = 0,
    assistant_messages: usize = 0,
    tool_results: usize = 0,
    tool_calls: usize = 0,
    bash_executions: usize = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, session_path: []const u8) !PersistentStore {
        var store: PersistentStore = .{};
        try copyBounded(&store.path_buf, &store.path_len, session_path);
        store.loadExisting(io, allocator) catch |err| switch (err) {
            error.FileNotFound, error.EmptySession => try store.newSession(io, allocator, null),
            else => return err,
        };
        return store;
    }

    pub fn create(io: std.Io, allocator: std.mem.Allocator, session_path: []const u8, parent_session: ?[]const u8) !PersistentStore {
        var store: PersistentStore = .{};
        try copyBounded(&store.path_buf, &store.path_len, session_path);
        try store.newSession(io, allocator, parent_session);
        return store;
    }

    pub fn open(io: std.Io, allocator: std.mem.Allocator, session_path: []const u8) !PersistentStore {
        var store: PersistentStore = .{};
        try copyBounded(&store.path_buf, &store.path_len, session_path);
        try store.loadExisting(io, allocator);
        return store;
    }

    pub fn path(self: *const PersistentStore) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn sessionId(self: *const PersistentStore) []const u8 {
        return self.session_id_buf[0..self.session_id_len];
    }

    pub fn totalMessages(self: *const PersistentStore) usize {
        return self.user_messages + self.assistant_messages + self.tool_results + self.bash_executions;
    }

    pub fn newSession(self: *PersistentStore, io: std.Io, allocator: std.mem.Allocator, parent_session: ?[]const u8) !void {
        self.entry_counter = 0;
        self.leaf_id_len = 0;
        self.user_messages = 0;
        self.assistant_messages = 0;
        self.tool_results = 0;
        self.tool_calls = 0;
        self.bash_executions = 0;
        try self.refreshSessionId(io);
        try ensureParentDir(io, self.path());

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"session\",\"version\":3,\"id\":");
        try writeJsonString(w, self.sessionId());
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"cwd\":\".\"");
        if (parent_session) |parent| {
            try w.writeAll(",\"parentSession\":");
            try writeJsonString(w, parent);
        }
        try w.writeAll("}\n");
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.path(), .data = out.written() });
    }

    pub fn loadExisting(self: *PersistentStore, io: std.Io, allocator: std.mem.Allocator) !void {
        self.entry_counter = 0;
        self.leaf_id_len = 0;
        self.user_messages = 0;
        self.assistant_messages = 0;
        self.tool_results = 0;
        self.tool_calls = 0;
        self.bash_executions = 0;

        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, self.path(), allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var line_no: usize = 0;
        var saw_header = false;
        while (lines.next()) |raw_line| {
            const line = stripTrailingCarriageReturn(raw_line);
            if (std.mem.trim(u8, line, " \t").len == 0) continue;
            line_no += 1;

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidSessionJson;
            defer parsed.deinit();
            const object = switch (parsed.value) {
                .object => |object| object,
                else => return error.InvalidSessionJson,
            };

            const entry_type = getStringFieldObject(object, "type") orelse return error.InvalidSessionEntry;
            if (!saw_header) {
                if (!std.mem.eql(u8, entry_type, "session")) return error.InvalidSessionHeader;
                const version = object.get("version") orelse return error.InvalidSessionHeader;
                if (version != .integer or version.integer != 3) return error.UnsupportedSessionVersion;
                const id = getStringFieldObject(object, "id") orelse return error.InvalidSessionHeader;
                try copyBounded(&self.session_id_buf, &self.session_id_len, id);
                saw_header = true;
                continue;
            }

            if (std.mem.eql(u8, entry_type, "leaf")) {
                if (object.get("targetId")) |target| {
                    switch (target) {
                        .null => self.leaf_id_len = 0,
                        .string => |target_id| try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, target_id),
                        else => return error.InvalidSessionEntry,
                    }
                }
                continue;
            }

            const id = getStringFieldObject(object, "id") orelse return error.InvalidSessionEntry;
            try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
            self.entry_counter = @max(self.entry_counter, numericEntryCounter(id) orelse line_no - 1);

            if (std.mem.eql(u8, entry_type, "message")) {
                const message = object.get("message") orelse return error.InvalidSessionEntry;
                if (message != .object) return error.InvalidSessionEntry;
                const role = getStringFieldObject(message.object, "role") orelse return error.InvalidSessionEntry;
                if (std.mem.eql(u8, role, "user")) {
                    self.user_messages += 1;
                } else if (std.mem.eql(u8, role, "assistant")) {
                    self.assistant_messages += 1;
                    self.tool_calls += countAssistantToolCalls(message.object);
                } else if (std.mem.eql(u8, role, "toolResult") or std.mem.eql(u8, role, "tool")) {
                    self.tool_results += 1;
                } else if (std.mem.eql(u8, role, "bashExecution")) {
                    self.bash_executions += 1;
                }
            }
        }

        if (!saw_header) return error.EmptySession;
    }

    pub fn appendMessage(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        role: types.Role,
        content: []const u8,
    ) ![]const u8 {
        self.entry_counter += 1;

        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        var fixed = std.Io.Writer.fixed(&entry_id_buf);
        try fixed.print("m-{d}", .{self.entry_counter});
        const entry_id = fixed.buffered();

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"message\",\"id\":");
        try writeJsonString(w, entry_id);
        try w.writeAll(",\"parentId\":");
        if (self.leaf_id_len == 0) {
            try w.writeAll("null");
        } else {
            try writeJsonString(w, self.leaf_id_buf[0..self.leaf_id_len]);
        }
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"message\":{\"role\":");
        try writeJsonString(w, role.label());
        try w.writeAll(",\"content\":");
        try writeJsonString(w, content);
        try w.writeAll("}}\n");

        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, entry_id);
        switch (role) {
            .user => self.user_messages += 1,
            .assistant => self.assistant_messages += 1,
            .tool => self.tool_results += 1,
            .system => {},
        }
        return self.leaf_id_buf[0..self.leaf_id_len];
    }

    pub fn appendMessageWithContentParts(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        role: types.Role,
        content: []const u8,
        content_parts: []const ai_client.ChatContentPart,
    ) ![]const u8 {
        if (content_parts.len == 0) return self.appendMessage(io, allocator, role, content);
        self.entry_counter += 1;

        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        var fixed = std.Io.Writer.fixed(&entry_id_buf);
        try fixed.print("m-{d}", .{self.entry_counter});
        const entry_id = fixed.buffered();

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"message\",\"id\":");
        try writeJsonString(w, entry_id);
        try w.writeAll(",\"parentId\":");
        if (self.leaf_id_len == 0) {
            try w.writeAll("null");
        } else {
            try writeJsonString(w, self.leaf_id_buf[0..self.leaf_id_len]);
        }
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"message\":{\"role\":");
        try writeJsonString(w, role.label());
        try w.writeAll(",\"content\":[");
        var emitted = false;
        if (content.len > 0) {
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try writeJsonString(w, content);
            try w.writeByte('}');
            emitted = true;
        }
        for (content_parts) |part| {
            switch (part) {
                .text => |text| {
                    if (emitted) try w.writeByte(',');
                    try w.writeAll("{\"type\":\"text\",\"text\":");
                    try writeJsonString(w, text);
                    try w.writeByte('}');
                    emitted = true;
                },
                .image => |image| {
                    if (emitted) try w.writeByte(',');
                    try w.writeAll("{\"type\":\"image\",\"data\":");
                    try writeJsonString(w, image.data);
                    try w.writeAll(",\"mimeType\":");
                    try writeJsonString(w, image.mime_type);
                    try w.writeByte('}');
                    emitted = true;
                },
            }
        }
        try w.writeAll("]}}\n");

        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, entry_id);
        switch (role) {
            .user => self.user_messages += 1,
            .assistant => self.assistant_messages += 1,
            .tool => self.tool_results += 1,
            .system => {},
        }
        return self.leaf_id_buf[0..self.leaf_id_len];
    }

    pub fn appendCustomMessage(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        custom_type: []const u8,
        content: []const u8,
        display: bool,
    ) ![]const u8 {
        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        const id = try self.nextEntryId(&entry_id_buf);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;

        try w.writeAll("{\"type\":\"custom_message\",\"id\":");
        try writeJsonString(w, id);
        try w.writeAll(",\"parentId\":");
        try self.writeLeafParent(w);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"customType\":");
        try writeJsonString(w, custom_type);
        try w.writeAll(",\"content\":");
        try writeJsonString(w, content);
        try w.writeAll(",\"display\":");
        try w.writeAll(if (display) "true" else "false");
        try w.writeAll("}\n");

        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
        return self.leaf_id_buf[0..self.leaf_id_len];
    }

    pub fn appendCustomEntry(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        custom_type: []const u8,
        data: std.json.Value,
    ) ![]const u8 {
        var data_json: std.Io.Writer.Allocating = .init(allocator);
        defer data_json.deinit();
        try std.json.Stringify.value(data, .{}, &data_json.writer);
        return self.appendCustomEntryValidatedJson(io, allocator, custom_type, data_json.written());
    }

    pub fn appendCustomEntryRawJson(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        custom_type: []const u8,
        data_json: []const u8,
    ) ![]const u8 {
        const trimmed = std.mem.trim(u8, data_json, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidCustomEntryDataJson;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.InvalidCustomEntryDataJson;
        defer parsed.deinit();
        return self.appendCustomEntryValidatedJson(io, allocator, custom_type, trimmed);
    }

    fn appendCustomEntryValidatedJson(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        custom_type: []const u8,
        data_json: []const u8,
    ) ![]const u8 {
        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        const id = try self.nextEntryId(&entry_id_buf);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;

        try w.writeAll("{\"type\":\"custom\",\"id\":");
        try writeJsonString(w, id);
        try w.writeAll(",\"parentId\":");
        try self.writeLeafParent(w);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"customType\":");
        try writeJsonString(w, custom_type);
        try w.writeAll(",\"data\":");
        try w.writeAll(data_json);
        try w.writeAll("}\n");

        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
        return self.leaf_id_buf[0..self.leaf_id_len];
    }

    pub fn appendAssistantToolCallMessage(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        content: []const u8,
        tool_calls: []const ai_client.ChatToolCall,
    ) ![]const u8 {
        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        const id = try self.nextEntryId(&entry_id_buf);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;

        try w.writeAll("{\"type\":\"message\",\"id\":");
        try writeJsonString(w, id);
        try w.writeAll(",\"parentId\":");
        try self.writeLeafParent(w);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"message\":{\"role\":\"assistant\",\"content\":[");
        var emitted = false;
        if (content.len > 0) {
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try writeJsonString(w, content);
            try w.writeByte('}');
            emitted = true;
        }
        for (tool_calls) |call| {
            if (emitted) try w.writeByte(',');
            try w.writeAll("{\"type\":\"toolCall\",\"id\":");
            try writeJsonString(w, call.id);
            try w.writeAll(",\"name\":");
            try writeJsonString(w, call.name);
            try w.writeAll(",\"argumentsJson\":");
            try writeJsonString(w, call.arguments_json);
            if (call.thought_signature) |signature| {
                try w.writeAll(",\"thoughtSignature\":");
                try writeJsonString(w, signature);
            }
            if (std.json.parseFromSlice(std.json.Value, allocator, call.arguments_json, .{})) |parsed_arguments| {
                defer parsed_arguments.deinit();
                try w.writeAll(",\"arguments\":");
                try w.writeAll(std.mem.trim(u8, call.arguments_json, " \t\r\n"));
            } else |_| {}
            try w.writeByte('}');
            emitted = true;
        }
        try w.writeAll("]}}\n");
        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
        self.assistant_messages += 1;
        self.tool_calls += tool_calls.len;
        return self.leaf_id_buf[0..self.leaf_id_len];
    }

    pub fn appendAssistantStatusMessage(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        content: []const u8,
        api: ?[]const u8,
        provider: ?[]const u8,
        model: ?[]const u8,
        stop_reason: []const u8,
        error_message: ?[]const u8,
    ) ![]const u8 {
        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        const id = try self.nextEntryId(&entry_id_buf);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;

        try w.writeAll("{\"type\":\"message\",\"id\":");
        try writeJsonString(w, id);
        try w.writeAll(",\"parentId\":");
        try self.writeLeafParent(w);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":");
        try writeJsonString(w, content);
        try w.writeAll("}]");
        if (api) |value| {
            try w.writeAll(",\"api\":");
            try writeJsonString(w, value);
        }
        if (provider) |value| {
            try w.writeAll(",\"provider\":");
            try writeJsonString(w, value);
        }
        if (model) |value| {
            try w.writeAll(",\"model\":");
            try writeJsonString(w, value);
        }
        try w.writeAll(",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}}");
        try w.writeAll(",\"stopReason\":");
        try writeJsonString(w, stop_reason);
        if (error_message) |message| {
            try w.writeAll(",\"errorMessage\":");
            try writeJsonString(w, message);
        }
        try w.writeAll("}}\n");
        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
        self.assistant_messages += 1;
        return self.leaf_id_buf[0..self.leaf_id_len];
    }

    pub fn appendToolResultMessage(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        result: anytype,
    ) ![]const u8 {
        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        const id = try self.nextEntryId(&entry_id_buf);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;

        try w.writeAll("{\"type\":\"message\",\"id\":");
        try writeJsonString(w, id);
        try w.writeAll(",\"parentId\":");
        try self.writeLeafParent(w);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"message\":{\"role\":\"tool\",\"toolCallId\":");
        try writeJsonString(w, result.tool_call_id);
        try w.writeAll(",\"toolName\":");
        try writeJsonString(w, result.tool_name);
        try w.writeAll(",\"content\":");
        if (result.content_parts.len > 0) {
            try writeContentParts(w, result.content_parts);
        } else {
            try writeJsonString(w, result.content);
        }
        try w.writeAll(",\"isError\":");
        try w.writeAll(if (result.is_error) "true" else "false");
        try w.writeAll(",\"terminate\":");
        try w.writeAll(if (result.terminate) "true" else "false");
        try w.writeAll("}}\n");
        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
        self.tool_results += 1;
        return self.leaf_id_buf[0..self.leaf_id_len];
    }

    fn writeContentParts(w: *std.Io.Writer, content_parts: []const ai_client.ChatContentPart) !void {
        try w.writeByte('[');
        for (content_parts, 0..) |part, index| {
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

    pub fn appendSessionInfo(self: *PersistentStore, io: std.Io, allocator: std.mem.Allocator, name: []const u8) !void {
        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        const id = try self.nextEntryId(&entry_id_buf);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"session_info\",\"id\":");
        try writeJsonString(w, id);
        try w.writeAll(",\"parentId\":");
        try self.writeLeafParent(w);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"name\":");
        try writeJsonString(w, std.mem.trim(u8, name, " \t\r\n"));
        try w.writeAll("}\n");
        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
    }

    pub fn appendThinkingLevelChange(self: *PersistentStore, io: std.Io, allocator: std.mem.Allocator, level: []const u8) !void {
        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        const id = try self.nextEntryId(&entry_id_buf);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"thinking_level_change\",\"id\":");
        try writeJsonString(w, id);
        try w.writeAll(",\"parentId\":");
        try self.writeLeafParent(w);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"thinkingLevel\":");
        try writeJsonString(w, level);
        try w.writeAll("}\n");
        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
    }

    pub fn appendModelChange(self: *PersistentStore, io: std.Io, allocator: std.mem.Allocator, provider: []const u8, model_id: []const u8) !void {
        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        const id = try self.nextEntryId(&entry_id_buf);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"model_change\",\"id\":");
        try writeJsonString(w, id);
        try w.writeAll(",\"parentId\":");
        try self.writeLeafParent(w);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"provider\":");
        try writeJsonString(w, provider);
        try w.writeAll(",\"modelId\":");
        try writeJsonString(w, model_id);
        try w.writeAll("}\n");
        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
    }

    /// Optional provenance metadata for an LLM-generated compaction summary.
    /// When present, the compaction is recorded with `local:false` plus the
    /// provider/model that produced the summary. When absent the legacy
    /// `local:true` static-summary shape is written, keeping existing readers
    /// (loadCompactionEntry only consumes summary/firstKeptEntryId/tokensBefore)
    /// fully backward-compatible.
    pub const CompactionProvider = struct {
        provider: []const u8,
        model: []const u8,
    };

    pub fn appendCompaction(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: usize,
        custom_instructions: ?[]const u8,
        message_count: usize,
        provider_meta: ?CompactionProvider,
    ) ![]const u8 {
        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        const id = try self.nextEntryId(&entry_id_buf);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"compaction\",\"id\":");
        try writeJsonString(w, id);
        try w.writeAll(",\"parentId\":");
        try self.writeLeafParent(w);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"summary\":");
        try writeJsonString(w, summary);
        try w.writeAll(",\"firstKeptEntryId\":");
        try writeJsonString(w, first_kept_entry_id);
        try w.writeAll(",\"tokensBefore\":");
        try w.print("{d}", .{tokens_before});
        if (provider_meta) |meta| {
            try w.writeAll(",\"details\":{\"local\":false,\"provider\":");
            try writeJsonString(w, meta.provider);
            try w.writeAll(",\"model\":");
            try writeJsonString(w, meta.model);
            try w.writeAll(",\"messageCount\":");
        } else {
            try w.writeAll(",\"details\":{\"local\":true,\"messageCount\":");
        }
        try w.print("{d}", .{message_count});
        if (custom_instructions) |instructions| {
            try w.writeAll(",\"customInstructions\":");
            try writeJsonString(w, instructions);
        }
        try w.writeAll("}}\n");
        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
        return self.leaf_id_buf[0..self.leaf_id_len];
    }

    // [FLOW_G_SESSION_TREE] Append a branch_summary entry (upstream session-manager.ts
    // branchWithSummary / BranchSummaryEntry): when navigateTree abandons a branch with
    // summarization on, a branch_summary captures the abandoned path's context at the
    // navigation-target position. Shape mirrors upstream
    // {type,id,parentId,timestamp,fromId,summary,fromHook}; `from_id` is the target the
    // leaf moved to ("root" when null), and `from_hook` is false for pi-generated
    // summaries (the html exporter + tree preview already recognize branch_summary).
    pub fn appendBranchSummary(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        summary: []const u8,
        from_id: []const u8,
        from_hook: bool,
    ) ![]const u8 {
        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        const id = try self.nextEntryId(&entry_id_buf);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"branch_summary\",\"id\":");
        try writeJsonString(w, id);
        try w.writeAll(",\"parentId\":");
        try self.writeLeafParent(w);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"fromId\":");
        try writeJsonString(w, from_id);
        try w.writeAll(",\"summary\":");
        try writeJsonString(w, summary);
        try w.writeAll(",\"fromHook\":");
        try w.writeAll(if (from_hook) "true" else "false");
        try w.writeAll("}\n");
        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
        return self.leaf_id_buf[0..self.leaf_id_len];
    }

    pub fn appendBashExecution(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        command: []const u8,
        result: tools.ShellResult,
    ) ![]const u8 {
        var entry_id_buf: [max_entry_id_bytes]u8 = undefined;
        const id = try self.nextEntryId(&entry_id_buf);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"message\",\"id\":");
        try writeJsonString(w, id);
        try w.writeAll(",\"parentId\":");
        try self.writeLeafParent(w);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll(",\"message\":{\"role\":\"bashExecution\",\"command\":");
        try writeJsonString(w, command);
        try w.writeAll(",\"output\":");
        try writeJsonString(w, result.output);
        try w.writeAll(",\"exitCode\":");
        if (result.exit_code) |code| {
            try w.print("{d}", .{code});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"cancelled\":");
        try w.writeAll(if (result.cancelled) "true" else "false");
        try w.writeAll(",\"truncated\":");
        try w.writeAll(if (result.truncated) "true" else "false");
        if (result.full_output_path) |full_path| {
            try w.writeAll(",\"fullOutputPath\":");
            try writeJsonString(w, full_path);
        }
        try w.writeAll(",\"timestamp\":");
        try w.print("{d}", .{@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms)});
        try w.writeAll("}}\n");
        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
        self.bash_executions += 1;
        return self.leaf_id_buf[0..self.leaf_id_len];
    }

    // ===== [FLOW_G_SESSION_TREE] begin same-file tree navigation =====
    // Mirrors upstream/pi/packages/coding-agent/src/core/session-manager.ts
    // getTree()/branch()/resetLeaf()/getLeafId() and agent-session.ts navigateTree():
    // the session JSONL is an append-only id/parentId tree; the "leaf" pointer marks
    // the active branch tip. Branch switching moves the leaf to an earlier entry by
    // appending a `{"type":"leaf","targetId":...}` record (already honored by
    // loadExisting above) WITHOUT creating a new file (that is fork/clone's job).
    pub const tree_max_nodes = 512;
    const tree_max_preview_bytes = 80;

    pub const TreeNode = struct {
        id_buf: [max_entry_id_bytes]u8 = undefined,
        id_len: usize = 0,
        parent_buf: [max_entry_id_bytes]u8 = undefined,
        parent_len: usize = 0,
        has_parent: bool = false,
        kind_buf: [32]u8 = undefined,
        kind_len: usize = 0,
        role_buf: [24]u8 = undefined,
        role_len: usize = 0,
        preview_buf: [tree_max_preview_bytes]u8 = undefined,
        preview_len: usize = 0,

        pub fn id(self: *const TreeNode) []const u8 {
            return self.id_buf[0..self.id_len];
        }

        pub fn parentId(self: *const TreeNode) ?[]const u8 {
            if (!self.has_parent) return null;
            return self.parent_buf[0..self.parent_len];
        }

        pub fn kind(self: *const TreeNode) []const u8 {
            return self.kind_buf[0..self.kind_len];
        }

        pub fn role(self: *const TreeNode) ?[]const u8 {
            if (self.role_len == 0) return null;
            return self.role_buf[0..self.role_len];
        }

        pub fn preview(self: *const TreeNode) []const u8 {
            return self.preview_buf[0..self.preview_len];
        }
    };

    pub const SessionTree = struct {
        nodes: [tree_max_nodes]TreeNode = undefined,
        count: usize = 0,

        pub fn slice(self: *const SessionTree) []const TreeNode {
            return self.nodes[0..self.count];
        }

        pub fn contains(self: *const SessionTree, target_id: []const u8) bool {
            for (self.nodes[0..self.count]) |*node| {
                if (std.mem.eql(u8, node.id(), target_id)) return true;
            }
            return false;
        }
    };

    /// Parse the durable JSONL into a flat node list carrying id/parentId/type so
    /// callers can reconstruct the tree (upstream getTree()). The session header is
    /// excluded; `leaf` entries are pointer updates, not nodes. Non-fatal: malformed
    /// individual entries are skipped so a partially written tail never breaks reads.
    /// Heap-friendly variant of readTree: fills the caller-provided `out` pointer
    /// in place, with NO return-by-value of the 128 KB SessionTree. Use this on
    /// any code path where stack pressure matters (worker threads, the test
    /// runner, or callers that compose multiple frames before this call).
    pub fn readTreeInto(self: *const PersistentStore, io: std.Io, allocator: std.mem.Allocator, out: *SessionTree) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, self.path(), allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);

        out.* = .{};
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var saw_header = false;
        while (lines.next()) |raw_line| {
            const line = stripTrailingCarriageReturn(raw_line);
            if (std.mem.trim(u8, line, " \t").len == 0) continue;

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const object = parsed.value.object;
            const entry_type = getStringFieldObject(object, "type") orelse continue;
            if (!saw_header) {
                saw_header = true;
                if (std.mem.eql(u8, entry_type, "session")) continue;
            }
            if (std.mem.eql(u8, entry_type, "session")) continue;
            if (std.mem.eql(u8, entry_type, "leaf")) continue;
            const id = getStringFieldObject(object, "id") orelse continue;
            if (id.len > max_entry_id_bytes) continue;
            if (out.count >= tree_max_nodes) break;

            var node = &out.nodes[out.count];
            node.* = .{};
            @memcpy(node.id_buf[0..id.len], id);
            node.id_len = id.len;
            switch (object.get("parentId") orelse std.json.Value.null) {
                .string => |parent| {
                    if (parent.len <= max_entry_id_bytes) {
                        @memcpy(node.parent_buf[0..parent.len], parent);
                        node.parent_len = parent.len;
                        node.has_parent = true;
                    }
                },
                else => node.has_parent = false,
            }
            copyTreeField(&node.kind_buf, &node.kind_len, entry_type);
            fillTreePreview(node, object, entry_type);
            out.count += 1;
        }
    }

    pub fn readTree(self: *const PersistentStore, io: std.Io, allocator: std.mem.Allocator) !SessionTree {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, self.path(), allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);

        // Heap-allocate the working tree: SessionTree is ~128 KB (tree_max_nodes
        // fixed-size TreeNodes), which overflows worker/test thread stacks if held
        // as a value-type local. Return-by-value still works via RVO into the
        // caller's slot, so the public signature is preserved.
        const tree_ptr = try allocator.create(SessionTree);
        defer allocator.destroy(tree_ptr);
        tree_ptr.* = .{};
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var saw_header = false;
        while (lines.next()) |raw_line| {
            const line = stripTrailingCarriageReturn(raw_line);
            if (std.mem.trim(u8, line, " \t").len == 0) continue;

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const object = parsed.value.object;
            const entry_type = getStringFieldObject(object, "type") orelse continue;
            if (!saw_header) {
                saw_header = true;
                if (std.mem.eql(u8, entry_type, "session")) continue;
            }
            if (std.mem.eql(u8, entry_type, "session")) continue;
            if (std.mem.eql(u8, entry_type, "leaf")) continue;
            const id = getStringFieldObject(object, "id") orelse continue;
            if (id.len > max_entry_id_bytes) continue;
            if (tree_ptr.count >= tree_max_nodes) break;

            var node = &tree_ptr.nodes[tree_ptr.count];
            node.* = .{};
            @memcpy(node.id_buf[0..id.len], id);
            node.id_len = id.len;
            switch (object.get("parentId") orelse std.json.Value.null) {
                .string => |parent| {
                    if (parent.len <= max_entry_id_bytes) {
                        @memcpy(node.parent_buf[0..parent.len], parent);
                        node.parent_len = parent.len;
                        node.has_parent = true;
                    }
                },
                else => node.has_parent = false,
            }
            copyTreeField(&node.kind_buf, &node.kind_len, entry_type);
            fillTreePreview(node, object, entry_type);
            tree_ptr.count += 1;
        }
        return tree_ptr.*;
    }

    /// Move the active leaf pointer to `target_id` (upstream branch()/navigateTree()).
    /// Appends a durable `leaf` record so a later reload restores the same branch tip,
    /// staying in the SAME file. The target must already exist in the tree.
    pub fn setLeaf(self: *PersistentStore, io: std.Io, allocator: std.mem.Allocator, target_id: []const u8) !void {
        if (target_id.len > max_entry_id_bytes) return error.ValueTooLong;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"leaf\",\"targetId\":");
        try writeJsonString(w, target_id);
        try w.writeAll(",\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll("}\n");
        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, target_id);
    }

    /// Reset the leaf pointer to before any entries (upstream resetLeaf()). Used when
    /// navigating to the root so the next append starts a fresh branch at parentId=null.
    pub fn resetLeaf(self: *PersistentStore, io: std.Io, allocator: std.mem.Allocator) !void {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"leaf\",\"targetId\":null,\"timestamp\":");
        try writeJsonString(w, timestampString(io));
        try w.writeAll("}\n");
        try appendBytes(io, self.path(), out.written());
        self.leaf_id_len = 0;
    }

    pub fn leafId(self: *const PersistentStore) ?[]const u8 {
        if (self.leaf_id_len == 0) return null;
        return self.leaf_id_buf[0..self.leaf_id_len];
    }
    // ===== [FLOW_G_SESSION_TREE] end same-file tree navigation =====

    fn refreshSessionId(self: *PersistentStore, io: std.Io) !void {
        const now = std.Io.Clock.real.now(io).nanoseconds;
        var fixed = std.Io.Writer.fixed(&self.session_id_buf);
        try fixed.print("pi-zig-{d}", .{now});
        self.session_id_len = fixed.buffered().len;
    }

    fn nextEntryId(self: *PersistentStore, buffer: []u8) ![]const u8 {
        self.entry_counter += 1;
        var fixed = std.Io.Writer.fixed(buffer);
        try fixed.print("m-{d}", .{self.entry_counter});
        return fixed.buffered();
    }

    fn writeLeafParent(self: *const PersistentStore, w: *std.Io.Writer) !void {
        if (self.leaf_id_len == 0) {
            try w.writeAll("null");
        } else {
            try writeJsonString(w, self.leaf_id_buf[0..self.leaf_id_len]);
        }
    }
};

/// Export a session JSONL file to a self-contained HTML document.
/// Delegates to html_export, which renders every supported entry/message type with
/// upstream content semantics (upstream/pi/packages/coding-agent/src/core/export-html).
pub fn exportHtmlFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    input_path: []const u8,
    requested_output_path: ?[]const u8,
) ![]u8 {
    return html_export.exportHtmlFromFile(io, allocator, input_path, requested_output_path);
}

pub fn defaultSessionDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
) ![]u8 {
    _ = io;
    const agent_dir = try agentDir(allocator, env);
    defer allocator.free(agent_dir);

    var safe: std.Io.Writer.Allocating = .init(allocator);
    defer safe.deinit();
    const w = &safe.writer;
    try w.writeAll("--");
    var start: usize = 0;
    while (start < cwd.len and (cwd[start] == '/' or cwd[start] == '\\')) : (start += 1) {}
    for (cwd[start..]) |byte| {
        switch (byte) {
            '/', '\\', ':' => try w.writeByte('-'),
            else => try w.writeByte(byte),
        }
    }
    try w.writeAll("--");

    return std.fs.path.join(allocator, &.{ agent_dir, "sessions", safe.written() });
}

pub fn newSessionPath(io: std.Io, allocator: std.mem.Allocator, session_dir: []const u8) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(io, session_dir);
    const now = std.Io.Clock.real.now(io).nanoseconds;
    return std.fmt.allocPrint(allocator, "{s}/{d}_pi-zig-{d}.jsonl", .{ session_dir, now, now });
}

pub fn findMostRecentSession(io: std.Io, allocator: std.mem.Allocator, session_dir: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir => return null,
        else => return err,
    };
    defer dir.close(io);

    var best_path: ?[]u8 = null;
    var best_mtime: i128 = std.math.minInt(i128);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const path = try std.fs.path.join(allocator, &.{ session_dir, entry.name });
        errdefer allocator.free(path);
        if (!try isValidSessionFile(io, allocator, path)) {
            allocator.free(path);
            continue;
        }
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        const mtime = stat.mtime.nanoseconds;
        if (mtime > best_mtime) {
            if (best_path) |old| allocator.free(old);
            best_path = path;
            best_mtime = mtime;
        } else {
            allocator.free(path);
        }
    }
    return best_path;
}

pub fn findSessionByIdPrefix(io: std.Io, allocator: std.mem.Allocator, session_dir: []const u8, prefix: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir => return null,
        else => return err,
    };
    defer dir.close(io);

    var best_path: ?[]u8 = null;
    var best_mtime: i128 = std.math.minInt(i128);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const path = try std.fs.path.join(allocator, &.{ session_dir, entry.name });
        errdefer allocator.free(path);
        const id = (try readSessionHeaderId(io, allocator, path)) orelse {
            allocator.free(path);
            continue;
        };
        defer allocator.free(id);
        if (!std.mem.startsWith(u8, id, prefix)) {
            allocator.free(path);
            continue;
        }
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        const mtime = stat.mtime.nanoseconds;
        if (mtime > best_mtime) {
            if (best_path) |old| allocator.free(old);
            best_path = path;
            best_mtime = mtime;
        } else {
            allocator.free(path);
        }
    }
    return best_path;
}

pub fn forkFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_path: []const u8,
    target_session_dir: []const u8,
    cwd: []const u8,
) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var saw_header = false;
    while (lines.next()) |raw_line| {
        const line = stripTrailingCarriageReturn(raw_line);
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidSessionJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSessionJson;
        const entry_type = getStringFieldObject(parsed.value.object, "type") orelse return error.InvalidSessionEntry;
        if (!std.mem.eql(u8, entry_type, "session")) return error.InvalidSessionHeader;
        saw_header = true;
        break;
    }
    if (!saw_header) return error.InvalidSessionHeader;

    const output_path = try newSessionPath(io, allocator, target_session_dir);
    errdefer allocator.free(output_path);
    const now = std.Io.Clock.real.now(io).nanoseconds;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"type\":\"session\",\"version\":3,\"id\":");
    try w.print("\"pi-zig-{d}\"", .{now});
    try w.writeAll(",\"timestamp\":");
    try writeJsonString(w, timestampString(io));
    try w.writeAll(",\"cwd\":");
    try writeJsonString(w, cwd);
    try w.writeAll(",\"parentSession\":");
    try writeJsonString(w, source_path);
    try w.writeAll("}\n");

    var copy_lines = std.mem.splitScalar(u8, bytes, '\n');
    var skipped_header = false;
    while (copy_lines.next()) |raw_line| {
        const line = stripTrailingCarriageReturn(raw_line);
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        if (!skipped_header) {
            skipped_header = true;
            continue;
        }
        try w.writeAll(line);
        try w.writeByte('\n');
    }

    try ensureParentDir(io, output_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = out.written() });
    return output_path;
}

fn timestampString(io: std.Io) []const u8 {
    _ = io;
    return "local-foundation";
}

fn agentDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("PI_CODING_AGENT_DIR")) |value| return expandMaybeTilde(allocator, env, value);
    return std.fs.path.join(allocator, &.{ env.get("HOME") orelse ".", ".pi", "agent" });
}

fn expandMaybeTilde(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, env.get("HOME") orelse ".");
    if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(allocator, &.{ env.get("HOME") orelse ".", path[2..] });
    return allocator.dupe(u8, path);
}

fn isValidSessionFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !bool {
    const id = try readSessionHeaderId(io, allocator, path);
    if (id) |value| {
        allocator.free(value);
        return true;
    }
    return false;
}

fn readSessionHeaderId(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_header_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    const newline = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    const first_line = stripTrailingCarriageReturn(bytes[0..newline]);
    if (std.mem.trim(u8, first_line, " \t").len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, first_line, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const entry_type = getStringFieldObject(parsed.value.object, "type") orelse return null;
    if (!std.mem.eql(u8, entry_type, "session")) return null;
    const id = getStringFieldObject(parsed.value.object, "id") orelse return null;
    const owned = try allocator.dupe(u8, id);
    return owned;
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn appendBytes(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try ensureParentDir(io, path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    const offset = try file.length(io);
    try file.writePositionalAll(io, bytes, offset);
}

fn stripTrailingCarriageReturn(value: []const u8) []const u8 {
    if (value.len > 0 and value[value.len - 1] == '\r') return value[0 .. value.len - 1];
    return value;
}

fn getStringFieldObject(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const field = object.get(name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn numericEntryCounter(id: []const u8) ?usize {
    if (id.len <= 2 or id[0] != 'm' or id[1] != '-') return null;
    return std.fmt.parseInt(usize, id[2..], 10) catch null;
}

fn countAssistantToolCalls(object: std.json.ObjectMap) usize {
    const content = object.get("content") orelse return 0;
    if (content != .array) return 0;
    var count: usize = 0;
    for (content.array.items) |item| {
        if (item != .object) continue;
        const block_type = getStringFieldObject(item.object, "type") orelse continue;
        if (std.mem.eql(u8, block_type, "toolCall")) count += 1;
    }
    return count;
}

fn copyBounded(buffer: []u8, len: *usize, value: []const u8) !void {
    if (value.len > buffer.len) return error.ValueTooLong;
    @memcpy(buffer[0..value.len], value);
    len.* = value.len;
}

// [FLOW_G_SESSION_TREE] Copy at most buffer.len bytes (truncating, never failing)
// into a bounded tree-node field. Tree previews/kinds are advisory display data, so
// over-long values are clipped rather than rejecting the whole entry.
fn copyTreeField(buffer: []u8, len: *usize, value: []const u8) void {
    const n = @min(value.len, buffer.len);
    @memcpy(buffer[0..n], value[0..n]);
    len.* = n;
}

// [FLOW_G_SESSION_TREE] Fill a node's role + short preview for tree display. Mirrors
// the kind of summary upstream surfaces per tree node (message role/text, compaction
// summary, bash command). Pure best-effort: missing fields just yield an empty preview.
fn fillTreePreview(node: *PersistentStore.TreeNode, object: std.json.ObjectMap, entry_type: []const u8) void {
    if (std.mem.eql(u8, entry_type, "message")) {
        const message = object.get("message") orelse return;
        if (message != .object) return;
        if (getStringFieldObject(message.object, "role")) |role| {
            copyTreeField(&node.role_buf, &node.role_len, role);
        }
        if (std.mem.eql(u8, node.role_buf[0..node.role_len], "bashExecution")) {
            if (getStringFieldObject(message.object, "command")) |command| {
                copyTreePreview(node, command);
            }
            return;
        }
        copyTreePreviewFromContent(node, message.object.get("content") orelse .null);
    } else if (std.mem.eql(u8, entry_type, "compaction")) {
        if (getStringFieldObject(object, "summary")) |summary| copyTreePreview(node, summary);
    } else if (std.mem.eql(u8, entry_type, "branch_summary")) {
        if (getStringFieldObject(object, "summary")) |summary| copyTreePreview(node, summary);
    } else if (std.mem.eql(u8, entry_type, "custom_message")) {
        copyTreePreviewFromContent(node, object.get("content") orelse .null);
    } else if (std.mem.eql(u8, entry_type, "session_info")) {
        if (getStringFieldObject(object, "name")) |name| copyTreePreview(node, name);
    }
}

fn copyTreePreviewFromContent(node: *PersistentStore.TreeNode, content: std.json.Value) void {
    switch (content) {
        .string => |text| copyTreePreview(node, text),
        .array => |array| {
            for (array.items) |item| {
                if (item != .object) continue;
                const block_type = getStringFieldObject(item.object, "type") orelse continue;
                if (!std.mem.eql(u8, block_type, "text")) continue;
                if (getStringFieldObject(item.object, "text")) |text| {
                    copyTreePreview(node, text);
                    return;
                }
            }
        },
        else => {},
    }
}

fn copyTreePreview(node: *PersistentStore.TreeNode, text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    copyTreeField(&node.preview_buf, &node.preview_len, trimmed);
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789abcdef";
    try w.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11...12, 14...0x1f => {
                try w.writeAll("\\u00");
                try w.writeByte(hex[byte >> 4]);
                try w.writeByte(hex[byte & 0x0f]);
            },
            else => try w.writeByte(byte),
        }
    }
    try w.writeByte('"');
}

test "session state counts messages" {
    const messages = [_]types.Message{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .content = "world" },
    };
    const state = SessionState{ .id = "test-session", .messages = &messages };
    try std.testing.expectEqual(@as(usize, 2), state.messageCount());
    try std.testing.expect(state.hasMessages());
}

test "persistent session store writes upstream-shaped jsonl" {
    const path = "zig-out/pi-zig-session-test.jsonl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var store = try PersistentStore.init(std.testing.io, std.testing.allocator, path);
    _ = try store.appendMessage(std.testing.io, std.testing.allocator, .user, "hello");
    try std.testing.expectEqual(@as(usize, 1), store.user_messages);
    try std.testing.expect(store.sessionId().len > 0);
}

test "persistent session store appends upstream custom entries without message counters" {
    const path = "zig-out/pi-zig-session-custom-entry-test.jsonl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var store = try PersistentStore.init(std.testing.io, std.testing.allocator, path);

    const raw_id = try store.appendCustomEntryRawJson(
        std.testing.io,
        std.testing.allocator,
        "state",
        " {\"count\":42,\"items\":[true,null]} ",
    );
    try std.testing.expectEqualStrings("m-1", raw_id);
    try std.testing.expectEqual(@as(usize, 0), store.totalMessages());

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"source\":\"value\",\"nested\":{\"ok\":true}}", .{});
    defer parsed.deinit();
    const value_id = try store.appendCustomEntry(std.testing.io, std.testing.allocator, "value-state", parsed.value);
    try std.testing.expectEqualStrings("m-2", value_id);
    try std.testing.expectEqual(@as(usize, 0), store.totalMessages());

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next() orelse return error.MissingSessionHeader;
    const raw_entry = lines.next() orelse return error.MissingCustomEntry;
    const value_entry = lines.next() orelse return error.MissingCustomEntry;
    try std.testing.expectEqualStrings(
        "{\"type\":\"custom\",\"id\":\"m-1\",\"parentId\":null,\"timestamp\":\"local-foundation\",\"customType\":\"state\",\"data\":{\"count\":42,\"items\":[true,null]}}",
        raw_entry,
    );
    try std.testing.expectEqualStrings(
        "{\"type\":\"custom\",\"id\":\"m-2\",\"parentId\":\"m-1\",\"timestamp\":\"local-foundation\",\"customType\":\"value-state\",\"data\":{\"source\":\"value\",\"nested\":{\"ok\":true}}}",
        value_entry,
    );

    const loaded = try PersistentStore.open(std.testing.io, std.testing.allocator, path);
    try std.testing.expectEqualStrings("m-2", loaded.leaf_id_buf[0..loaded.leaf_id_len]);
    try std.testing.expectEqual(@as(usize, 0), loaded.totalMessages());
    try std.testing.expectEqual(@as(usize, 2), loaded.entry_counter);
}

test "persistent session store rejects invalid raw custom entry JSON" {
    const path = "zig-out/pi-zig-session-custom-entry-invalid-test.jsonl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var store = try PersistentStore.init(std.testing.io, std.testing.allocator, path);
    try std.testing.expectError(
        error.InvalidCustomEntryDataJson,
        store.appendCustomEntryRawJson(std.testing.io, std.testing.allocator, "state", "{\"unterminated\""),
    );
    try std.testing.expectEqual(@as(usize, 0), store.totalMessages());
    try std.testing.expectEqual(@as(usize, 0), store.entry_counter);
}

test "persistent session store records llm compaction provenance and stays reloadable" {
    const path = "zig-out/pi-zig-session-llm-compaction-test.jsonl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var store = try PersistentStore.init(std.testing.io, std.testing.allocator, path);
    const user_id = try store.appendMessage(std.testing.io, std.testing.allocator, .user, "first turn");
    const first_kept = try std.testing.allocator.dupe(u8, user_id);
    defer std.testing.allocator.free(first_kept);

    _ = try store.appendCompaction(
        std.testing.io,
        std.testing.allocator,
        "LLM COMPACTION SUMMARY: alpha",
        first_kept,
        128,
        null,
        1,
        .{ .provider = "openai", .model = "gpt-4o" },
    );

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(bytes);
    // LLM-generated compaction marks local:false and records provenance.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"local\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"provider\":\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"model\":\"gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "LLM COMPACTION SUMMARY: alpha") != null);

    // The compaction entry must survive reopen (existing readers only need the
    // header to parse; the additive details fields are ignored gracefully).
    const reloaded = try PersistentStore.open(std.testing.io, std.testing.allocator, path);
    try std.testing.expect(reloaded.sessionId().len > 0);
}

test "[FLOW_G_SESSION_TREE] persistent session store appends an upstream-shaped branch_summary" {
    const path = "zig-out/pi-zig-session-branch-summary-test.jsonl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var store = try PersistentStore.init(std.testing.io, std.testing.allocator, path);
    const first = try store.appendMessage(std.testing.io, std.testing.allocator, .user, "root question");
    const first_id = try std.testing.allocator.dupe(u8, first);
    defer std.testing.allocator.free(first_id);

    const summary_id = try store.appendBranchSummary(
        std.testing.io,
        std.testing.allocator,
        "## Goal\nabandoned branch work",
        first_id,
        false,
    );
    try std.testing.expectEqualStrings("m-2", summary_id);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(bytes);
    // Upstream BranchSummaryEntry shape: type/id/parentId/fromId/summary/fromHook.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"type\":\"branch_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"fromId\":\"m-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"parentId\":\"m-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"fromHook\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "abandoned branch work") != null);

    // The branch_summary surfaces as a tree node with a preview (readTree + fillTreePreview
    // already recognize it) and the entry survives reopen.
    var tree = try store.readTree(std.testing.io, std.testing.allocator);
    var found = false;
    for (tree.slice()) |*node| {
        if (std.mem.eql(u8, node.id(), "m-2")) {
            try std.testing.expectEqualStrings("branch_summary", node.kind());
            try std.testing.expect(node.preview().len > 0);
            found = true;
        }
    }
    try std.testing.expect(found);

    const reloaded = try PersistentStore.open(std.testing.io, std.testing.allocator, path);
    try std.testing.expectEqualStrings("m-2", reloaded.leafId().?);
}

test "persistent session store keeps legacy local compaction shape without provenance" {
    const path = "zig-out/pi-zig-session-local-compaction-test.jsonl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var store = try PersistentStore.init(std.testing.io, std.testing.allocator, path);
    _ = try store.appendCompaction(std.testing.io, std.testing.allocator, "Local summary of 0 message(s).", "", 1, null, 0, null);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"local\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"provider\"") == null);
}

test "persistent session store opens existing jsonl without truncating" {
    const path = "zig-out/pi-zig-session-open-test.jsonl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var created = try PersistentStore.init(std.testing.io, std.testing.allocator, path);
    _ = try created.appendMessage(std.testing.io, std.testing.allocator, .user, "hello");
    try created.appendSessionInfo(std.testing.io, std.testing.allocator, "named");

    const loaded = try PersistentStore.open(std.testing.io, std.testing.allocator, path);
    try std.testing.expectEqual(@as(usize, 1), loaded.user_messages);
    try std.testing.expectEqual(@as(usize, 1), loaded.totalMessages());
    try std.testing.expect(loaded.sessionId().len > 0);
}

test "session tree exposes id/parentId structure with previews" {
    const path = "zig-out/pi-zig-session-tree-test.jsonl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var store = try PersistentStore.init(std.testing.io, std.testing.allocator, path);
    _ = try store.appendMessage(std.testing.io, std.testing.allocator, .user, "root question");
    _ = try store.appendMessage(std.testing.io, std.testing.allocator, .assistant, "first answer");

    var tree = try store.readTree(std.testing.io, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), tree.count);
    const nodes = tree.slice();
    try std.testing.expectEqualStrings("m-1", nodes[0].id());
    try std.testing.expectEqual(@as(?[]const u8, null), nodes[0].parentId());
    try std.testing.expectEqualStrings("message", nodes[0].kind());
    try std.testing.expectEqualStrings("user", nodes[0].role().?);
    try std.testing.expectEqualStrings("root question", nodes[0].preview());
    // The second message is a child of the first (parentId chains the tree).
    try std.testing.expectEqualStrings("m-2", nodes[1].id());
    try std.testing.expectEqualStrings("m-1", nodes[1].parentId().?);
    try std.testing.expect(tree.contains("m-1"));
    try std.testing.expect(!tree.contains("m-99"));
}

test "session tree leaf move branches in the same file and survives reload" {
    const path = "zig-out/pi-zig-session-tree-branch-test.jsonl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var store = try PersistentStore.init(std.testing.io, std.testing.allocator, path);
    const first = try store.appendMessage(std.testing.io, std.testing.allocator, .user, "alpha");
    const first_id = try std.testing.allocator.dupe(u8, first);
    defer std.testing.allocator.free(first_id);
    _ = try store.appendMessage(std.testing.io, std.testing.allocator, .assistant, "alpha reply");
    try std.testing.expectEqualStrings("m-2", store.leafId().?);

    // Branch back onto the first user message: the leaf moves WITHOUT a new file.
    try store.setLeaf(std.testing.io, std.testing.allocator, first_id);
    try std.testing.expectEqualStrings("m-1", store.leafId().?);

    // The next append becomes a sibling branch (parentId == first_id).
    _ = try store.appendMessage(std.testing.io, std.testing.allocator, .assistant, "alpha reply v2");
    var tree = try store.readTree(std.testing.io, std.testing.allocator);
    var children_of_first: usize = 0;
    for (tree.slice()) |*node| {
        if (node.parentId()) |parent| {
            if (std.mem.eql(u8, parent, first_id)) children_of_first += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), children_of_first);

    // Reload restores the branch tip from the durable leaf record.
    const reloaded = try PersistentStore.open(std.testing.io, std.testing.allocator, path);
    try std.testing.expectEqualStrings("m-3", reloaded.leafId().?);
}

test "session tree setLeaf rejects oversized target ids" {
    const path = "zig-out/pi-zig-session-tree-reject-test.jsonl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var store = try PersistentStore.init(std.testing.io, std.testing.allocator, path);
    const oversized = "x" ** (max_entry_id_bytes + 1);
    try std.testing.expectError(error.ValueTooLong, store.setLeaf(std.testing.io, std.testing.allocator, oversized));
}

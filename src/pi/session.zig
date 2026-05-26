const std = @import("std");
const tools = @import("tools.zig");
const types = @import("types.zig");

pub const default_session_file = "zig-out/pi-zig-session.jsonl";
const max_path_bytes = std.Io.Dir.max_path_bytes;
const max_session_id_bytes = 96;
const max_entry_id_bytes = 32;

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

    pub fn appendCompaction(
        self: *PersistentStore,
        io: std.Io,
        allocator: std.mem.Allocator,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: usize,
        custom_instructions: ?[]const u8,
        message_count: usize,
    ) !void {
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
        try w.writeAll(",\"details\":{\"local\":true,\"messageCount\":");
        try w.print("{d}", .{message_count});
        if (custom_instructions) |instructions| {
            try w.writeAll(",\"customInstructions\":");
            try writeJsonString(w, instructions);
        }
        try w.writeAll("}}\n");
        try appendBytes(io, self.path(), out.written());
        try copyBounded(&self.leaf_id_buf, &self.leaf_id_len, id);
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

fn timestampString(io: std.Io) []const u8 {
    _ = io;
    return "local-foundation";
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

const std = @import("std");
const ai_client = @import("ai_client.zig");
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
        try writeJsonString(w, result.content);
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
        try w.writeAll(",\"details\":{\"local\":true,\"messageCount\":");
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

pub fn exportHtmlFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    input_path: []const u8,
    requested_output_path: ?[]const u8,
) ![]u8 {
    const output_path = if (requested_output_path) |path|
        try allocator.dupe(u8, path)
    else
        try defaultExportPath(allocator, input_path);
    errdefer allocator.free(output_path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><title>pi-zig session</title>");
    try w.writeAll("<style>body{font-family:system-ui,sans-serif;margin:32px;color:#1f2328}article{border-top:1px solid #d0d7de;padding:12px 0}b{display:block;margin-bottom:6px}pre{white-space:pre-wrap}</style>");
    try w.writeAll("</head><body><h1>pi-zig session</h1><p>Session file: ");
    try writeHtmlEscaped(w, input_path);
    try w.writeAll("</p>");

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = stripTrailingCarriageReturn(raw_line);
        if (std.mem.trim(u8, line, " \t").len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidSessionJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSessionJson;
        const entry_type = getStringFieldObject(parsed.value.object, "type") orelse return error.InvalidSessionEntry;
        if (!std.mem.eql(u8, entry_type, "message")) continue;

        const message = parsed.value.object.get("message") orelse return error.InvalidSessionEntry;
        if (message != .object) return error.InvalidSessionEntry;
        const role = getStringFieldObject(message.object, "role") orelse return error.InvalidSessionEntry;

        try w.writeAll("<article><b>");
        try writeHtmlEscaped(w, role);
        try w.writeAll("</b><pre>");
        if (std.mem.eql(u8, role, "bashExecution")) {
            if (getStringFieldObject(message.object, "command")) |command| {
                try writeHtmlEscaped(w, "$ ");
                try writeHtmlEscaped(w, command);
                try w.writeByte('\n');
            }
            try writeHtmlEscaped(w, getStringFieldObject(message.object, "output") orelse "");
        } else {
            try writeMessageContentText(w, message.object);
        }
        try w.writeAll("</pre></article>");
    }

    try w.writeAll("</body></html>\n");
    try ensureParentDir(io, output_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = out.written() });
    return output_path;
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

fn defaultExportPath(allocator: std.mem.Allocator, input_path: []const u8) ![]u8 {
    var base = std.fs.path.basename(input_path);
    if (std.mem.endsWith(u8, base, ".jsonl")) {
        base = base[0 .. base.len - ".jsonl".len];
    }
    return std.fmt.allocPrint(allocator, "pi-zig-session-{s}.html", .{base});
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

fn writeMessageContentText(w: *std.Io.Writer, object: std.json.ObjectMap) !void {
    const content = object.get("content") orelse return;
    switch (content) {
        .string => |text| try writeHtmlEscaped(w, text),
        .array => |array| {
            var emitted = false;
            for (array.items) |item| {
                if (item != .object) continue;
                const block_type = getStringFieldObject(item.object, "type") orelse continue;
                if (std.mem.eql(u8, block_type, "text")) {
                    if (getStringFieldObject(item.object, "text")) |text| {
                        if (emitted) try w.writeByte('\n');
                        try writeHtmlEscaped(w, text);
                        emitted = true;
                    }
                } else if (std.mem.eql(u8, block_type, "thinking")) {
                    if (getStringFieldObject(item.object, "thinking")) |thinking| {
                        if (emitted) try w.writeByte('\n');
                        try writeHtmlEscaped(w, thinking);
                        emitted = true;
                    }
                } else if (std.mem.eql(u8, block_type, "toolCall")) {
                    if (emitted) try w.writeByte('\n');
                    try w.writeAll("tool call");
                    if (getStringFieldObject(item.object, "name")) |name| {
                        try w.writeAll(": ");
                        try writeHtmlEscaped(w, name);
                    }
                    emitted = true;
                }
            }
        },
        else => {},
    }
}

fn writeHtmlEscaped(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(byte),
        }
    }
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

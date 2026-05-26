const std = @import("std");
const agent = @import("agent.zig");
const ai_client = @import("ai_client.zig");
const auth = @import("auth.zig");
const commands = @import("commands.zig");
const context_files = @import("context_files.zig");
const models = @import("models.zig");
const session = @import("session.zig");
const settings = @import("settings.zig");
const system_prompt = @import("system_prompt.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");

const all_tool_names = [_][]const u8{ "read", "bash", "edit", "write", "grep", "find", "ls" };
const max_messages = 128;
const max_message_bytes = 8 * 1024;
const max_command_bytes = 4 * 1024;
const max_session_name_bytes = 256;
const max_session_file_bytes = 16 * 1024 * 1024;
const max_session_path_bytes = std.Io.Dir.max_path_bytes;
const max_tool_calls_per_message = 16;
const max_tool_call_id_bytes = 128;
const max_tool_name_bytes = 64;
const max_tool_arguments_bytes = 4 * 1024;
const max_compaction_kept_id_bytes = 32;
const max_pending_messages = 32;
const max_auto_retry_attempts = 3;
const default_auto_retry_base_delay_ms = 0;
const default_auto_retry_max_delay_ms = 60_000;
const compaction_summary_prefix = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n";
const compaction_summary_suffix = "\n</summary>";

const StoredRole = enum {
    system,
    user,
    assistant,
    tool,
    bash_execution,
    compaction_summary,

    fn label(self: StoredRole) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
            .bash_execution => "bashExecution",
            .compaction_summary => "compactionSummary",
        };
    }

    fn fromBase(role: types.Role) StoredRole {
        return switch (role) {
            .system => .system,
            .user => .user,
            .assistant => .assistant,
            .tool => .tool,
        };
    }
};

const QueueMode = enum {
    all,
    one_at_a_time,

    fn label(self: QueueMode) []const u8 {
        return switch (self) {
            .all => "all",
            .one_at_a_time => "one-at-a-time",
        };
    }

    fn parse(value: []const u8) ?QueueMode {
        if (std.mem.eql(u8, value, "all")) return .all;
        if (std.mem.eql(u8, value, "one-at-a-time")) return .one_at_a_time;
        return null;
    }
};

const StoredToolCall = struct {
    id_len: usize = 0,
    id: [max_tool_call_id_bytes]u8 = undefined,
    name_len: usize = 0,
    name: [max_tool_name_bytes]u8 = undefined,
    arguments_json_len: usize = 0,
    arguments_json: [max_tool_arguments_bytes]u8 = undefined,

    fn idText(self: *const StoredToolCall) []const u8 {
        return self.id[0..self.id_len];
    }

    fn nameText(self: *const StoredToolCall) []const u8 {
        return self.name[0..self.name_len];
    }

    fn argumentsJson(self: *const StoredToolCall) []const u8 {
        return self.arguments_json[0..self.arguments_json_len];
    }
};

const StoredMessage = struct {
    role: StoredRole = .user,
    id_len: usize = 0,
    id: [32]u8 = undefined,
    len: usize = 0,
    content: [max_message_bytes]u8 = undefined,
    image_parts: []ai_client.ChatContentPart = &.{},
    command_len: usize = 0,
    command: [max_command_bytes]u8 = undefined,
    exit_code: ?u8 = null,
    cancelled: bool = false,
    truncated: bool = false,
    full_output_path_len: usize = 0,
    full_output_path: [max_session_path_bytes]u8 = undefined,
    tool_call_id_len: usize = 0,
    tool_call_id: [max_tool_call_id_bytes]u8 = undefined,
    tool_name_len: usize = 0,
    tool_name: [max_tool_name_bytes]u8 = undefined,
    tool_is_error: bool = false,
    tool_terminate: bool = false,
    tool_calls_count: usize = 0,
    tool_calls: [max_tool_calls_per_message]StoredToolCall = undefined,
    first_kept_entry_id_len: usize = 0,
    first_kept_entry_id: [max_compaction_kept_id_bytes]u8 = undefined,
    tokens_before: usize = 0,

    fn entryId(self: *const StoredMessage) []const u8 {
        return self.id[0..self.id_len];
    }

    fn text(self: *const StoredMessage) []const u8 {
        return self.content[0..self.len];
    }

    fn commandText(self: *const StoredMessage) []const u8 {
        return self.command[0..self.command_len];
    }

    fn fullOutputPath(self: *const StoredMessage) ?[]const u8 {
        if (self.full_output_path_len == 0) return null;
        return self.full_output_path[0..self.full_output_path_len];
    }

    fn toolCallId(self: *const StoredMessage) ?[]const u8 {
        if (self.tool_call_id_len == 0) return null;
        return self.tool_call_id[0..self.tool_call_id_len];
    }

    fn toolName(self: *const StoredMessage) ?[]const u8 {
        if (self.tool_name_len == 0) return null;
        return self.tool_name[0..self.tool_name_len];
    }

    fn firstKeptEntryId(self: *const StoredMessage) []const u8 {
        return self.first_kept_entry_id[0..self.first_kept_entry_id_len];
    }
};

const PendingMessageQueue = struct {
    count: usize = 0,
    lengths: [max_pending_messages]usize = undefined,
    messages: [max_pending_messages][max_message_bytes]u8 = undefined,
    image_parts: [max_pending_messages][]ai_client.ChatContentPart = [_][]ai_client.ChatContentPart{&.{}} ** max_pending_messages,

    fn enqueue(
        self: *PendingMessageQueue,
        allocator: std.mem.Allocator,
        message: []const u8,
        image_parts: []const ai_client.ChatContentPart,
    ) !void {
        if (message.len > max_message_bytes) return error.MessageTooLarge;
        if (self.count >= max_pending_messages) return error.PendingMessageLimitReached;
        const owned_image_parts = try cloneImageParts(allocator, image_parts);
        errdefer freeRpcContentParts(allocator, owned_image_parts);
        self.lengths[self.count] = message.len;
        @memcpy(self.messages[self.count][0..message.len], message);
        self.image_parts[self.count] = owned_image_parts;
        self.count += 1;
    }

    fn clear(self: *PendingMessageQueue, allocator: std.mem.Allocator) void {
        for (self.image_parts[0..self.count]) |parts| freeRpcContentParts(allocator, parts);
        self.count = 0;
    }

    fn drainCount(self: *const PendingMessageQueue, mode: QueueMode) usize {
        return switch (mode) {
            .all => self.count,
            .one_at_a_time => @min(self.count, 1),
        };
    }

    fn at(self: *const PendingMessageQueue, index: usize) UserBatchMessage {
        return .{
            .text = self.messages[index][0..self.lengths[index]],
            .image_parts = self.image_parts[index],
        };
    }

    fn dropPrefix(self: *PendingMessageQueue, allocator: std.mem.Allocator, prefix_count: usize) void {
        for (self.image_parts[0..@min(prefix_count, self.count)]) |parts| freeRpcContentParts(allocator, parts);
        if (prefix_count >= self.count) {
            self.count = 0;
            return;
        }
        const remaining = self.count - prefix_count;
        for (0..remaining) |index| {
            const source = index + prefix_count;
            self.lengths[index] = self.lengths[source];
            @memcpy(self.messages[index][0..self.lengths[source]], self.messages[source][0..self.lengths[source]]);
            self.image_parts[index] = self.image_parts[source];
            self.image_parts[source] = &.{};
        }
        self.count = remaining;
    }
};

const UserBatchMessage = struct {
    text: []const u8,
    image_parts: []const ai_client.ChatContentPart = &.{},
};

const Runtime = struct {
    store: session.PersistentStore = .{},
    messages: [max_messages]StoredMessage = undefined,
    message_count: usize = 0,
    session_generation: usize = 1,
    session_name: [max_session_name_bytes]u8 = undefined,
    session_name_len: usize = 0,
    has_session_name: bool = false,
    selected_model: ?*const models.ModelEntry = null,
    thinking_level: types.ThinkingLevel = .medium,
    steering_mode: QueueMode = .all,
    follow_up_mode: QueueMode = .one_at_a_time,
    steering_queue: PendingMessageQueue = .{},
    follow_up_queue: PendingMessageQueue = .{},
    auto_compaction_enabled: bool = false,
    auto_retry_enabled: bool = false,
    auto_retry_max_attempts: usize = max_auto_retry_attempts,
    auto_retry_base_delay_ms: usize = default_auto_retry_base_delay_ms,
    auto_retry_max_delay_ms: usize = default_auto_retry_max_delay_ms,
    last_retry_attempts: usize = 0,
    last_retry_delay_ms: usize = 0,
    command_options: commands.Options = .{},
    env: ?*const std.process.Environ.Map = null,

    fn init(
        self: *Runtime,
        io: std.Io,
        allocator: std.mem.Allocator,
        env: *const std.process.Environ.Map,
        session_file: []const u8,
        command_options: commands.Options,
    ) !void {
        self.resetInMemory(allocator);
        self.env = env;
        self.command_options = command_options;
        self.store = try session.PersistentStore.init(io, allocator, session_file);
        try self.loadSessionEntries(io, allocator);
    }

    fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
        self.clearLoadedImages(allocator);
        self.steering_queue.clear(allocator);
        self.follow_up_queue.clear(allocator);
    }

    fn resetInMemory(self: *Runtime, allocator: std.mem.Allocator) void {
        self.clearLoadedImages(allocator);
        self.message_count = 0;
        self.session_name_len = 0;
        self.has_session_name = false;
        self.selected_model = null;
        self.thinking_level = .medium;
        self.steering_queue.clear(allocator);
        self.follow_up_queue.clear(allocator);
        self.auto_compaction_enabled = false;
        self.auto_retry_enabled = false;
        self.auto_retry_max_attempts = max_auto_retry_attempts;
        self.auto_retry_base_delay_ms = default_auto_retry_base_delay_ms;
        self.auto_retry_max_delay_ms = default_auto_retry_max_delay_ms;
        self.last_retry_attempts = 0;
        self.last_retry_delay_ms = 0;
    }

    fn clearLoadedImages(self: *Runtime, allocator: std.mem.Allocator) void {
        for (self.messages[0..self.message_count]) |*message| {
            freeRpcContentParts(allocator, message.image_parts);
            message.image_parts = &.{};
        }
    }

    fn clearSession(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, parent_session: ?[]const u8) !void {
        self.resetInMemory(allocator);
        self.session_generation += 1;
        try self.store.newSession(io, allocator, parent_session);
    }

    fn switchSession(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, session_file: []const u8) !void {
        self.resetInMemory(allocator);
        self.session_generation += 1;
        self.store = try session.PersistentStore.open(io, allocator, session_file);
        try self.loadSessionEntries(io, allocator);
    }

    fn forkSession(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, entry_id: []const u8, text_buffer: []u8) ![]const u8 {
        const selected_index = self.findUserMessageIndex(entry_id) orelse return error.EntryNotFound;
        const selected_text = self.messages[selected_index].text();
        if (selected_text.len > text_buffer.len) return error.MessageTooLarge;
        @memcpy(text_buffer[0..selected_text.len], selected_text);
        try self.copyIntoSiblingSession(io, allocator, "fork", selected_index);
        return text_buffer[0..selected_text.len];
    }

    fn cloneSession(self: *Runtime, io: std.Io, allocator: std.mem.Allocator) !void {
        if (self.message_count == 0) return error.NoCurrentEntry;
        try self.copyIntoSiblingSession(io, allocator, "clone", self.message_count);
    }

    fn copyIntoSiblingSession(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, kind: []const u8, copy_count: usize) !void {
        const source_path = self.store.path();
        const previous_model = self.selected_model;
        const previous_thinking = self.thinking_level;
        const previous_name = self.sessionName();

        var path_buf: [max_session_path_bytes]u8 = undefined;
        var fixed = std.Io.Writer.fixed(&path_buf);
        try fixed.print("{s}.{s}-{d}.jsonl", .{ source_path, kind, self.session_generation + 1 });
        const target_path = fixed.buffered();

        var new_store = try session.PersistentStore.create(io, allocator, target_path, source_path);
        for (self.messages[0..copy_count]) |*message| {
            switch (message.role) {
                .system => _ = try new_store.appendMessage(io, allocator, .system, message.text()),
                .user => _ = try new_store.appendMessageWithContentParts(io, allocator, .user, message.text(), message.image_parts),
                .assistant => {
                    if (message.tool_calls_count > 0) {
                        var calls: [max_tool_calls_per_message]ai_client.ChatToolCall = undefined;
                        for (message.tool_calls[0..message.tool_calls_count], 0..) |*call, index| {
                            calls[index] = .{
                                .id = @constCast(call.idText()),
                                .name = @constCast(call.nameText()),
                                .arguments_json = @constCast(call.argumentsJson()),
                            };
                        }
                        _ = try new_store.appendAssistantToolCallMessage(io, allocator, message.text(), calls[0..message.tool_calls_count]);
                    } else {
                        _ = try new_store.appendMessage(io, allocator, .assistant, message.text());
                    }
                },
                .tool => {
                    if (message.toolCallId()) |_| {
                        _ = try new_store.appendToolResultMessage(io, allocator, .{
                            .tool_call_id = message.toolCallId().?,
                            .tool_name = message.toolName() orelse "",
                            .content = message.text(),
                            .is_error = message.tool_is_error,
                            .terminate = message.tool_terminate,
                        });
                    } else {
                        _ = try new_store.appendMessage(io, allocator, .tool, message.text());
                    }
                },
                .bash_execution => {
                    const result: tools.ShellResult = .{
                        .output = message.content[0..message.len],
                        .exit_code = message.exit_code,
                        .cancelled = message.cancelled,
                        .truncated = message.truncated,
                        .full_output_path = message.fullOutputPath(),
                    };
                    _ = try new_store.appendBashExecution(io, allocator, message.commandText(), result);
                },
                .compaction_summary => {
                    _ = try new_store.appendCompaction(io, allocator, message.text(), message.firstKeptEntryId(), message.tokens_before, null, copy_count);
                },
            }
        }
        if (previous_model) |model| try new_store.appendModelChange(io, allocator, model.provider, model.id);
        try new_store.appendThinkingLevelChange(io, allocator, thinkingLevelLabel(previous_thinking));
        if (previous_name) |name| try new_store.appendSessionInfo(io, allocator, name);

        self.resetInMemory(allocator);
        self.session_generation += 1;
        self.store = new_store;
        try self.loadSessionEntries(io, allocator);
    }

    fn findUserMessageIndex(self: *const Runtime, entry_id: []const u8) ?usize {
        for (self.messages[0..self.message_count], 0..) |*message, i| {
            if (message.role == .user and std.mem.eql(u8, message.entryId(), entry_id)) return i;
        }
        return null;
    }

    fn loadSessionEntries(self: *Runtime, io: std.Io, allocator: std.mem.Allocator) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, self.store.path(), allocator, .limited(max_session_file_bytes));
        defer allocator.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            const line = stripTrailingCarriageReturn(raw_line);
            if (std.mem.trim(u8, line, " \t").len == 0) continue;

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidSessionJson;
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidSessionJson;
            const entry_type = getStringFieldObject(parsed.value.object, "type") orelse return error.InvalidSessionEntry;

            if (std.mem.eql(u8, entry_type, "message")) {
                try self.loadMessageEntry(allocator, parsed.value.object);
            } else if (std.mem.eql(u8, entry_type, "session_info")) {
                if (getStringFieldObject(parsed.value.object, "name")) |name| {
                    try self.setSessionNameMemory(name);
                }
            } else if (std.mem.eql(u8, entry_type, "thinking_level_change")) {
                if (getStringFieldObject(parsed.value.object, "thinkingLevel")) |level| {
                    if (types.ThinkingLevel.parse(level)) |parsed_level| self.thinking_level = parsed_level;
                }
            } else if (std.mem.eql(u8, entry_type, "model_change")) {
                const provider = getStringFieldObject(parsed.value.object, "provider") orelse continue;
                const model_id = getStringFieldObject(parsed.value.object, "modelId") orelse continue;
                if (models.find(provider, model_id)) |model| self.selected_model = model;
            } else if (std.mem.eql(u8, entry_type, "compaction")) {
                try self.loadCompactionEntry(parsed.value.object);
            }
        }
    }

    fn loadCompactionEntry(self: *Runtime, object: std.json.ObjectMap) !void {
        const id = getStringFieldObject(object, "id") orelse return error.InvalidSessionEntry;
        const summary = getStringFieldObject(object, "summary") orelse return error.InvalidSessionEntry;
        const first_kept_entry_id = getStringFieldObject(object, "firstKeptEntryId") orelse "";
        const tokens_before_value = object.get("tokensBefore") orelse return error.InvalidSessionEntry;
        const tokens_before: usize = switch (tokens_before_value) {
            .integer => |value| if (value < 0) 0 else @intCast(value),
            .float => |value| if (value < 0) 0 else @intFromFloat(value),
            else => return error.InvalidSessionEntry,
        };
        try self.addLoadedCompaction(id, summary, first_kept_entry_id, tokens_before);
    }

    fn loadMessageEntry(self: *Runtime, allocator: std.mem.Allocator, object: std.json.ObjectMap) !void {
        const id = getStringFieldObject(object, "id") orelse return error.InvalidSessionEntry;
        const message = object.get("message") orelse return error.InvalidSessionEntry;
        if (message != .object) return error.InvalidSessionEntry;
        const role_label = getStringFieldObject(message.object, "role") orelse return error.InvalidSessionEntry;
        const role = parseStoredRole(role_label) orelse return;

        if (role == .bash_execution) {
            const output = getStringFieldObject(message.object, "output") orelse "";
            const result: tools.ShellResult = .{
                .output = @constCast(output),
                .exit_code = getOptionalExitCode(message.object),
                .cancelled = getBoolFieldObject(message.object, "cancelled") orelse false,
                .truncated = getBoolFieldObject(message.object, "truncated") orelse false,
                .full_output_path = getStringFieldObject(message.object, "fullOutputPath"),
            };
            try self.addLoadedBash(id, getStringFieldObject(message.object, "command") orelse "", result);
        } else {
            var text_buf: [max_message_bytes]u8 = undefined;
            const text_len = try extractMessageText(message.object, &text_buf);
            var image_parts: []ai_client.ChatContentPart = if (role == .user) try extractMessageImages(allocator, message.object) else &.{};
            errdefer freeRpcContentParts(allocator, image_parts);
            try self.addLoadedMessage(role, id, text_buf[0..text_len]);
            const slot = &self.messages[self.message_count - 1];
            slot.image_parts = image_parts;
            image_parts = &.{};
            if (role == .assistant) {
                try copyToolCallsFromMessage(message.object, slot);
            } else if (role == .tool) {
                try copyToolResultFieldsFromMessage(message.object, slot);
            }
            if (role == .assistant) {
                const provider = getStringFieldObject(message.object, "provider") orelse return;
                const model_id = getStringFieldObject(message.object, "model") orelse return;
                if (models.find(provider, model_id)) |model| self.selected_model = model;
            }
        }
    }

    fn addLoadedMessage(self: *Runtime, role: StoredRole, entry_id: []const u8, content: []const u8) !void {
        if (content.len > max_message_bytes) return error.MessageTooLarge;
        if (entry_id.len > 32) return error.ValueTooLong;
        if (self.message_count >= max_messages) return;

        var slot = &self.messages[self.message_count];
        slot.role = role;
        slot.id_len = entry_id.len;
        @memcpy(slot.id[0..entry_id.len], entry_id);
        slot.len = content.len;
        @memcpy(slot.content[0..content.len], content);
        slot.image_parts = &.{};
        slot.command_len = 0;
        slot.exit_code = null;
        slot.cancelled = false;
        slot.truncated = false;
        slot.full_output_path_len = 0;
        slot.tool_call_id_len = 0;
        slot.tool_name_len = 0;
        slot.tool_is_error = false;
        slot.tool_terminate = false;
        slot.tool_calls_count = 0;
        slot.first_kept_entry_id_len = 0;
        slot.tokens_before = 0;
        self.message_count += 1;
    }

    fn addLoadedCompaction(self: *Runtime, entry_id: []const u8, summary: []const u8, first_kept_entry_id: []const u8, tokens_before: usize) !void {
        if (summary.len > max_message_bytes) return error.MessageTooLarge;
        if (entry_id.len > 32) return error.ValueTooLong;
        if (first_kept_entry_id.len > max_compaction_kept_id_bytes) return error.ValueTooLong;
        if (self.message_count >= max_messages) return error.MessageLimitReached;

        try self.addLoadedMessage(.compaction_summary, entry_id, summary);
        var slot = &self.messages[self.message_count - 1];
        slot.first_kept_entry_id_len = first_kept_entry_id.len;
        @memcpy(slot.first_kept_entry_id[0..first_kept_entry_id.len], first_kept_entry_id);
        slot.tokens_before = tokens_before;
    }

    fn addMessage(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, role: types.Role, content: []const u8) !void {
        if (content.len > max_message_bytes) return error.MessageTooLarge;
        if (self.message_count >= max_messages) return error.MessageLimitReached;

        const entry_id = try self.store.appendMessage(io, allocator, role, content);
        try self.addLoadedMessage(StoredRole.fromBase(role), entry_id, content);
    }

    fn addUserMessageWithImages(
        self: *Runtime,
        io: std.Io,
        allocator: std.mem.Allocator,
        content: []const u8,
        image_parts: []const ai_client.ChatContentPart,
    ) !void {
        if (content.len > max_message_bytes) return error.MessageTooLarge;
        if (self.message_count >= max_messages) return error.MessageLimitReached;

        const owned_image_parts = try cloneImageParts(allocator, image_parts);
        errdefer freeRpcContentParts(allocator, owned_image_parts);
        const entry_id = try self.store.appendMessageWithContentParts(io, allocator, .user, content, image_parts);
        try self.addLoadedMessage(.user, entry_id, content);
        self.messages[self.message_count - 1].image_parts = owned_image_parts;
    }

    fn addLoadedBash(self: *Runtime, entry_id: []const u8, command: []const u8, result: tools.ShellResult) !void {
        if (command.len > max_command_bytes) return error.CommandTooLarge;
        if (entry_id.len > 32) return error.ValueTooLong;
        if (self.message_count >= max_messages) return error.MessageLimitReached;
        const output = boundedStoredOutput(result.output);
        const full_output_path = result.full_output_path orelse "";
        if (full_output_path.len > max_session_path_bytes) return error.ValueTooLong;

        var slot = &self.messages[self.message_count];
        slot.role = .bash_execution;
        slot.id_len = entry_id.len;
        @memcpy(slot.id[0..entry_id.len], entry_id);
        slot.command_len = command.len;
        @memcpy(slot.command[0..command.len], command);
        slot.len = output.len;
        @memcpy(slot.content[0..output.len], output);
        slot.image_parts = &.{};
        slot.exit_code = result.exit_code;
        slot.cancelled = result.cancelled;
        slot.truncated = result.truncated or output.len < result.output.len;
        slot.full_output_path_len = full_output_path.len;
        if (full_output_path.len > 0) @memcpy(slot.full_output_path[0..full_output_path.len], full_output_path);
        slot.tool_call_id_len = 0;
        slot.tool_name_len = 0;
        slot.tool_is_error = false;
        slot.tool_terminate = false;
        slot.tool_calls_count = 0;
        slot.first_kept_entry_id_len = 0;
        slot.tokens_before = 0;
        self.message_count += 1;
    }

    fn executeBash(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, shell_command: []const u8, timeout_ms: ?i64) !tools.ShellResult {
        var shell_settings: settings.ShellSettings = .{};
        if (self.env) |env| shell_settings = try settings.loadShellSettings(io, allocator, env);
        defer shell_settings.deinit(allocator);

        const result = try tools.runShellCaptureWithUpdates(io, allocator, shell_command, .{
            .timeout_ms = timeout_ms,
            .shell_path = shell_settings.shell_path,
            .command_prefix = shell_settings.shell_command_prefix,
            .env = self.env,
        });
        errdefer allocator.free(result.output);
        const entry_id = try self.store.appendBashExecution(io, allocator, shell_command, result);
        try self.addLoadedBash(entry_id, shell_command, result);
        return result;
    }

    fn setSessionNameMemory(self: *Runtime, name: []const u8) !void {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len > max_session_name_bytes) return error.SessionNameTooLarge;
        @memcpy(self.session_name[0..trimmed.len], trimmed);
        self.session_name_len = trimmed.len;
        self.has_session_name = trimmed.len > 0;
    }

    fn setSessionName(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, name: []const u8) !void {
        try self.setSessionNameMemory(name);
        try self.store.appendSessionInfo(io, allocator, name);
    }

    fn setThinkingLevel(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, level: types.ThinkingLevel) !void {
        const effective_level = if (self.selected_model) |model| models.clampThinkingLevel(model, level) else level;
        if (self.thinking_level == effective_level) return;
        self.thinking_level = effective_level;
        try self.store.appendThinkingLevelChange(io, allocator, thinkingLevelLabel(effective_level));
    }

    fn setModel(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, model: *const models.ModelEntry) !void {
        self.selected_model = model;
        try self.store.appendModelChange(io, allocator, model.provider, model.id);
        try self.setThinkingLevel(io, allocator, self.thinking_level);
    }

    fn writeCompactResponse(
        self: *Runtime,
        io: std.Io,
        allocator: std.mem.Allocator,
        w: *std.Io.Writer,
        id: ?[]const u8,
        command: []const u8,
        custom_instructions: ?[]const u8,
    ) !void {
        var summary_writer: std.Io.Writer.Allocating = .init(allocator);
        defer summary_writer.deinit();
        const sw = &summary_writer.writer;
        if (self.message_count == 0) {
            try sw.writeAll("No messages to compact.");
        } else {
            try sw.print("Local summary of {d} message(s).", .{self.message_count});
            for (self.messages[0..self.message_count]) |*message| {
                try sw.writeAll("\n- ");
                try sw.writeAll(message.role.label());
                try sw.writeAll(": ");
                if (message.role == .bash_execution) {
                    try appendSummarySnippet(sw, message.commandText());
                    try sw.writeAll(" => ");
                }
                try appendSummarySnippet(sw, message.text());
            }
        }

        const summary = summary_writer.written();
        const first_kept_entry_id = if (self.message_count > 0) self.messages[0].entryId() else "";
        const tokens_before = self.estimateTokensBeforeCompaction();
        const entry_id = try self.store.appendCompaction(io, allocator, summary, first_kept_entry_id, tokens_before, custom_instructions, self.message_count);
        try self.addLoadedCompaction(entry_id, summary, first_kept_entry_id, tokens_before);

        try writeResponseHead(w, id, command, true);
        try w.writeAll(",\"data\":{\"summary\":");
        try writeJsonString(w, summary);
        try w.writeAll(",\"firstKeptEntryId\":");
        try writeJsonString(w, first_kept_entry_id);
        try w.writeAll(",\"tokensBefore\":");
        try w.print("{d}", .{tokens_before});
        try w.writeAll(",\"details\":{\"local\":true,\"messageCount\":");
        try w.print("{d}", .{self.message_count});
        if (custom_instructions) |instructions| {
            try w.writeAll(",\"customInstructions\":");
            try writeJsonString(w, instructions);
        }
        try w.writeAll("}}}\n");
    }

    fn estimateTokensBeforeCompaction(self: *const Runtime) usize {
        var bytes: usize = 0;
        for (self.messages[0..self.message_count]) |*message| {
            bytes += message.text().len;
            bytes += message.commandText().len;
        }
        return @max(@as(usize, 1), (bytes + 3) / 4);
    }

    fn lastAssistantText(self: *Runtime) ?[]const u8 {
        var idx = self.message_count;
        while (idx > 0) {
            idx -= 1;
            const message = &self.messages[idx];
            if (message.role == .assistant) return message.text();
        }
        return null;
    }

    fn runAgentIfAuthenticatedOnce(
        self: *Runtime,
        io: std.Io,
        allocator: std.mem.Allocator,
        history_limit: usize,
        batch_history_messages: []const UserBatchMessage,
        prompt: []const u8,
        prompt_image_parts: []const ai_client.ChatContentPart,
    ) !?agent.RunResult {
        const model = self.selected_model orelse return null;
        const env = self.env orelse return null;
        const api_key = try auth.resolveProviderApiKey(io, allocator, env, model.provider) orelse return null;
        defer allocator.free(api_key);
        const runtime_system_prompt = try buildRuntimeSystemPrompt(io, allocator, env);
        defer allocator.free(runtime_system_prompt);
        const shell_settings = try settings.loadShellSettings(io, allocator, env);
        defer shell_settings.deinit(allocator);
        var history = try self.buildAgentHistory(allocator, history_limit);
        defer deinitAgentHistory(allocator, &history);
        for (batch_history_messages) |message| {
            try appendBatchHistoryMessage(allocator, &history, message);
        }
        const prompt_content_parts = try buildPromptContentParts(allocator, prompt, prompt_image_parts);
        defer if (prompt_content_parts.len > 0) allocator.free(prompt_content_parts);

        return try agent.runPrompt(io, allocator, env, .{
            .provider = model.provider,
            .model = model.id,
            .api_key = api_key,
            .prompt = prompt,
            .prompt_content_parts = prompt_content_parts,
            .system_prompt = runtime_system_prompt,
            .env = env,
            .shell_path = shell_settings.shell_path,
            .shell_command_prefix = shell_settings.shell_command_prefix,
            .history = history.items,
            .tool_set = .all,
        });
    }

    fn runAgentIfAuthenticated(
        self: *Runtime,
        io: std.Io,
        allocator: std.mem.Allocator,
        history_limit: usize,
        batch_history_messages: []const UserBatchMessage,
        prompt: []const u8,
        prompt_image_parts: []const ai_client.ChatContentPart,
    ) !?agent.RunResult {
        var retry_attempts: usize = 0;
        self.last_retry_attempts = 0;
        self.last_retry_delay_ms = 0;
        while (true) {
            return self.runAgentIfAuthenticatedOnce(io, allocator, history_limit, batch_history_messages, prompt, prompt_image_parts) catch |err| {
                if (!self.auto_retry_enabled or !isRetryableAgentError(err) or retry_attempts >= self.auto_retry_max_attempts) return err;
                retry_attempts += 1;
                self.last_retry_attempts = retry_attempts;
                const delay_ms = self.retryDelayMs(retry_attempts);
                self.last_retry_delay_ms += delay_ms;
                if (delay_ms > 0) try sleepMilliseconds(io, delay_ms);
                continue;
            };
        }
    }

    fn retryDelayMs(self: *const Runtime, attempt: usize) usize {
        if (self.auto_retry_base_delay_ms == 0) return 0;
        const shift: std.math.Log2Int(usize) = @intCast(@min(attempt - 1, @bitSizeOf(usize) - 2));
        const multiplier = @as(usize, 1) << shift;
        const delay = std.math.mul(usize, self.auto_retry_base_delay_ms, multiplier) catch self.auto_retry_max_delay_ms;
        return @min(delay, self.auto_retry_max_delay_ms);
    }

    fn buildAgentHistory(self: *Runtime, allocator: std.mem.Allocator, history_limit: usize) !std.ArrayList(ai_client.ChatMessage) {
        var history: std.ArrayList(ai_client.ChatMessage) = .empty;
        errdefer deinitAgentHistory(allocator, &history);

        const limit = @min(history_limit, self.message_count);
        if (self.latestCompactionIndex(limit)) |compaction_index| {
            try appendCompactionHistoryMessage(allocator, &history, &self.messages[compaction_index]);
            const first_kept_index = self.firstKeptMessageIndex(compaction_index) orelse compaction_index + 1;
            try self.appendHistoryRange(allocator, &history, first_kept_index, compaction_index);
            try self.appendHistoryRange(allocator, &history, compaction_index + 1, limit);
        } else {
            try self.appendHistoryRange(allocator, &history, 0, limit);
        }
        return history;
    }

    fn appendHistoryRange(self: *Runtime, allocator: std.mem.Allocator, history: *std.ArrayList(ai_client.ChatMessage), start: usize, end: usize) !void {
        if (start >= end) return;
        for (self.messages[start..end]) |*message| {
            try self.appendStoredHistoryMessage(allocator, history, message);
        }
    }

    fn appendStoredHistoryMessage(self: *Runtime, allocator: std.mem.Allocator, history: *std.ArrayList(ai_client.ChatMessage), message: *StoredMessage) !void {
        switch (message.role) {
            .user => {
                if (message.image_parts.len > 0) {
                    try appendBatchHistoryMessage(allocator, history, .{
                        .text = message.text(),
                        .image_parts = message.image_parts,
                    });
                } else {
                    try appendHistoryMessage(allocator, history, .user, message.text());
                }
            },
            .assistant => try appendAssistantHistoryMessage(allocator, history, message),
            .tool => try appendToolHistoryMessage(allocator, history, message),
            .bash_execution => try appendOwnedHistoryMessage(allocator, history, .user, try self.bashExecutionHistoryText(allocator, message)),
            .compaction_summary => {},
            else => {},
        }
    }

    fn latestCompactionIndex(self: *Runtime, limit: usize) ?usize {
        var index = @min(limit, self.message_count);
        while (index > 0) {
            index -= 1;
            if (self.messages[index].role == .compaction_summary) return index;
        }
        return null;
    }

    fn firstKeptMessageIndex(self: *Runtime, compaction_index: usize) ?usize {
        const first_kept_entry_id = self.messages[compaction_index].firstKeptEntryId();
        if (first_kept_entry_id.len == 0) return null;
        for (self.messages[0..compaction_index], 0..) |*message, index| {
            if (std.mem.eql(u8, message.entryId(), first_kept_entry_id)) return index;
        }
        return null;
    }

    fn appendHistoryMessage(allocator: std.mem.Allocator, history: *std.ArrayList(ai_client.ChatMessage), role: ai_client.ChatRole, content: []const u8) !void {
        const owned = try allocator.dupe(u8, content);
        try appendOwnedHistoryMessage(allocator, history, role, owned);
    }

    fn appendBatchHistoryMessage(allocator: std.mem.Allocator, history: *std.ArrayList(ai_client.ChatMessage), message: UserBatchMessage) !void {
        const chat_message: ai_client.ChatMessage = blk: {
            const owned_text = try allocator.dupe(u8, message.text);
            errdefer allocator.free(owned_text);
            const owned_content_parts = try buildOwnedPromptContentParts(allocator, message.text, message.image_parts);
            break :blk .{
                .role = .user,
                .content = owned_text,
                .content_parts = owned_content_parts,
            };
        };
        errdefer deinitHistoryMessage(allocator, chat_message);
        try history.append(allocator, chat_message);
    }

    fn appendOwnedHistoryMessage(allocator: std.mem.Allocator, history: *std.ArrayList(ai_client.ChatMessage), role: ai_client.ChatRole, content: []u8) !void {
        errdefer allocator.free(content);
        try history.append(allocator, .{ .role = role, .content = content });
    }

    fn appendAssistantHistoryMessage(allocator: std.mem.Allocator, history: *std.ArrayList(ai_client.ChatMessage), message: *const StoredMessage) !void {
        var chat_message = ai_client.ChatMessage{
            .role = .assistant,
            .content = try allocator.dupe(u8, message.text()),
            .tool_calls = &.{},
        };
        errdefer deinitHistoryMessage(allocator, chat_message);
        if (message.tool_calls_count > 0) {
            const calls = try allocator.alloc(ai_client.ChatToolCall, message.tool_calls_count);
            var copied: usize = 0;
            errdefer {
                for (calls[0..copied]) |call| call.deinit(allocator);
                allocator.free(calls);
            }
            for (message.tool_calls[0..message.tool_calls_count], 0..) |*call, index| {
                calls[index] = .{
                    .id = try allocator.dupe(u8, call.idText()),
                    .name = try allocator.dupe(u8, call.nameText()),
                    .arguments_json = try allocator.dupe(u8, call.argumentsJson()),
                };
                copied += 1;
            }
            chat_message.tool_calls = calls;
        }
        try history.append(allocator, chat_message);
    }

    fn appendToolHistoryMessage(allocator: std.mem.Allocator, history: *std.ArrayList(ai_client.ChatMessage), message: *const StoredMessage) !void {
        var chat_message = ai_client.ChatMessage{
            .role = .tool,
            .content = try allocator.dupe(u8, message.text()),
            .tool_call_id = null,
        };
        errdefer deinitHistoryMessage(allocator, chat_message);
        if (message.toolCallId()) |id| {
            chat_message.tool_call_id = try allocator.dupe(u8, id);
        }
        try history.append(allocator, chat_message);
    }

    fn appendCompactionHistoryMessage(allocator: std.mem.Allocator, history: *std.ArrayList(ai_client.ChatMessage), message: *const StoredMessage) !void {
        const content = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ compaction_summary_prefix, message.text(), compaction_summary_suffix });
        try appendOwnedHistoryMessage(allocator, history, .user, content);
    }

    fn deinitAgentHistory(allocator: std.mem.Allocator, history: *std.ArrayList(ai_client.ChatMessage)) void {
        for (history.items) |message| deinitHistoryMessage(allocator, message);
        history.deinit(allocator);
    }

    fn deinitHistoryMessage(allocator: std.mem.Allocator, message: ai_client.ChatMessage) void {
        allocator.free(message.content);
        freeRpcContentParts(allocator, message.content_parts);
        if (message.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
        for (message.tool_calls) |call| call.deinit(allocator);
        if (message.tool_calls.len > 0) allocator.free(message.tool_calls);
    }

    fn bashExecutionHistoryText(self: *Runtime, allocator: std.mem.Allocator, message: *const StoredMessage) ![]u8 {
        _ = self;
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;

        try w.print("Ran `{s}`\n", .{message.commandText()});
        if (message.text().len > 0) {
            try w.print("```\n{s}\n```", .{message.text()});
        } else {
            try w.writeAll("(no output)");
        }
        if (message.cancelled) {
            try w.writeAll("\n\n(command cancelled)");
        } else if (message.exit_code) |code| {
            if (code != 0) try w.print("\n\nCommand exited with code {d}", .{code});
        }
        if (message.truncated) {
            if (message.fullOutputPath()) |path| {
                try w.print("\n\n[Output truncated. Full output: {s}]", .{path});
            } else {
                try w.writeAll("\n\n[Output truncated.]");
            }
        }
        return out.toOwnedSlice();
    }

    fn addAgentResultMessages(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, result: agent.RunResult) !void {
        var next_tool_result_index: usize = 0;
        for (result.tool_call_batches) |batch| {
            while (next_tool_result_index < batch.first_tool_result_index and next_tool_result_index < result.tool_results_count) : (next_tool_result_index += 1) {
                try self.addToolResultMessage(io, allocator, result.tool_results[next_tool_result_index]);
            }
            try self.addAssistantToolCallMessage(io, allocator, batch.content, batch.tool_calls);
            const end = @min(result.tool_results_count, batch.first_tool_result_index + batch.tool_results_count);
            while (next_tool_result_index < end) : (next_tool_result_index += 1) {
                try self.addToolResultMessage(io, allocator, result.tool_results[next_tool_result_index]);
            }
        }
        while (next_tool_result_index < result.tool_results_count) : (next_tool_result_index += 1) {
            try self.addToolResultMessage(io, allocator, result.tool_results[next_tool_result_index]);
        }
        try self.addMessage(io, allocator, .assistant, result.final_text);
    }

    fn addAssistantToolCallMessage(
        self: *Runtime,
        io: std.Io,
        allocator: std.mem.Allocator,
        content: []const u8,
        tool_calls: []const ai_client.ChatToolCall,
    ) !void {
        if (tool_calls.len > max_tool_calls_per_message) return error.ValueTooLong;
        const entry_id = try self.store.appendAssistantToolCallMessage(io, allocator, content, tool_calls);
        try self.addLoadedMessage(.assistant, entry_id, content);
        var slot = &self.messages[self.message_count - 1];
        for (tool_calls, 0..) |call, index| {
            try copyBounded(&slot.tool_calls[index].id, &slot.tool_calls[index].id_len, call.id);
            try copyBounded(&slot.tool_calls[index].name, &slot.tool_calls[index].name_len, call.name);
            try copyBounded(&slot.tool_calls[index].arguments_json, &slot.tool_calls[index].arguments_json_len, call.arguments_json);
        }
        slot.tool_calls_count = tool_calls.len;
    }

    fn addToolResultMessage(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, result: agent.ToolResult) !void {
        const entry_id = try self.store.appendToolResultMessage(io, allocator, result);
        try self.addLoadedMessage(.tool, entry_id, result.content);
        var slot = &self.messages[self.message_count - 1];
        try copyBounded(&slot.tool_call_id, &slot.tool_call_id_len, result.tool_call_id);
        try copyBounded(&slot.tool_name, &slot.tool_name_len, result.tool_name);
        slot.tool_is_error = result.is_error;
        slot.tool_terminate = result.terminate;
    }

    fn writePromptAgentResult(
        self: *Runtime,
        w: *std.Io.Writer,
        id: ?[]const u8,
        command: []const u8,
        result: agent.RunResult,
    ) !void {
        try writeResponseHead(w, id, command, true);
        try w.writeAll(",\"data\":{\"text\":");
        try writeJsonString(w, result.final_text);
        try w.writeAll(",\"toolResults\":");
        try writeAgentToolResultsJson(w, result.tool_results[0..result.tool_results_count]);
        try w.writeAll(",\"retry\":{\"attempts\":");
        try w.print("{d}", .{self.last_retry_attempts});
        try w.writeAll(",\"totalDelayMs\":");
        try w.print("{d}", .{self.last_retry_delay_ms});
        try w.writeAll(",\"maxAttempts\":");
        try w.print("{d}", .{self.auto_retry_max_attempts});
        try w.writeAll("}");
        if (self.selected_model) |model| {
            try w.writeAll(",\"model\":");
            try models.writeModelJson(w, model);
        }
        try w.writeAll("}}\n");
    }

    fn runUserBatch(
        self: *Runtime,
        io: std.Io,
        allocator: std.mem.Allocator,
        messages: []const UserBatchMessage,
        last_result: *?agent.RunResult,
    ) !void {
        if (messages.len == 0) return;
        const history_limit = self.message_count;
        for (messages) |message| {
            try self.addUserMessageWithImages(io, allocator, message.text, message.image_parts);
        }

        const prompt_message = messages[messages.len - 1];
        const maybe_run_result = try self.runAgentIfAuthenticated(
            io,
            allocator,
            history_limit,
            messages[0 .. messages.len - 1],
            prompt_message.text,
            prompt_message.image_parts,
        );
        var run_result = maybe_run_result orelse return;
        errdefer run_result.deinit(allocator);

        try self.addAgentResultMessages(io, allocator, run_result);
        if (last_result.*) |previous| previous.deinit(allocator);
        last_result.* = run_result;
    }

    fn drainQueueBatch(self: *Runtime, queue: *PendingMessageQueue, mode: QueueMode, batch: []UserBatchMessage) usize {
        _ = self;
        const count = queue.drainCount(mode);
        for (0..count) |index| {
            batch[index] = queue.at(index);
        }
        return count;
    }

    fn drainQueuedMessages(
        self: *Runtime,
        io: std.Io,
        allocator: std.mem.Allocator,
        last_result: *?agent.RunResult,
    ) !void {
        var batch: [max_pending_messages]UserBatchMessage = undefined;
        while (self.steering_queue.count > 0 or self.follow_up_queue.count > 0) {
            if (self.steering_queue.count > 0) {
                const count = self.drainQueueBatch(&self.steering_queue, self.steering_mode, &batch);
                try self.runUserBatch(io, allocator, batch[0..count], last_result);
                self.steering_queue.dropPrefix(allocator, count);
                continue;
            }
            const count = self.drainQueueBatch(&self.follow_up_queue, self.follow_up_mode, &batch);
            try self.runUserBatch(io, allocator, batch[0..count], last_result);
            self.follow_up_queue.dropPrefix(allocator, count);
        }
    }

    fn sessionName(self: *const Runtime) ?[]const u8 {
        if (!self.has_session_name) return null;
        return self.session_name[0..self.session_name_len];
    }

    fn enqueuePendingMessage(
        self: *Runtime,
        allocator: std.mem.Allocator,
        w: *std.Io.Writer,
        id: ?[]const u8,
        command: []const u8,
        queue: *PendingMessageQueue,
        message: []const u8,
        image_parts: []const ai_client.ChatContentPart,
    ) !void {
        queue.enqueue(allocator, message, image_parts) catch |err| {
            return writeError(w, id, command, @errorName(err));
        };
        try writeResponseHead(w, id, command, true);
        try w.writeAll(",\"data\":{\"pendingMessageCount\":");
        try w.print("{d}", .{self.steering_queue.count + self.follow_up_queue.count});
        try w.writeAll(",\"steeringCount\":");
        try w.print("{d}", .{self.steering_queue.count});
        try w.writeAll(",\"followUpCount\":");
        try w.print("{d}", .{self.follow_up_queue.count});
        try w.writeAll("}}\n");
    }

    fn handlePromptCommand(
        self: *Runtime,
        io: std.Io,
        allocator: std.mem.Allocator,
        w: *std.Io.Writer,
        id: ?[]const u8,
        command: []const u8,
        message: []const u8,
        image_parts: []const ai_client.ChatContentPart,
    ) !void {
        var last_result: ?agent.RunResult = null;
        defer if (last_result) |result| result.deinit(allocator);

        var initial_batch: [1 + max_pending_messages]UserBatchMessage = undefined;
        initial_batch[0] = .{ .text = message, .image_parts = image_parts };
        const steering_count = self.drainQueueBatch(&self.steering_queue, self.steering_mode, initial_batch[1..]);
        self.runUserBatch(io, allocator, initial_batch[0 .. 1 + steering_count], &last_result) catch |err| {
            return writeError(w, id, command, @errorName(err));
        };
        self.steering_queue.dropPrefix(allocator, steering_count);

        self.drainQueuedMessages(io, allocator, &last_result) catch |err| {
            return writeError(w, id, command, @errorName(err));
        };

        const result = last_result orelse return writeSuccess(w, id, command);
        return self.writePromptAgentResult(w, id, command, result);
    }

    fn handleValue(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, w: *std.Io.Writer, value: std.json.Value) !void {
        const id = getStringField(value, "id");
        const command = getStringField(value, "type") orelse {
            return writeError(w, id, "unknown", "missing string command type");
        };

        if (std.mem.eql(u8, command, "prompt")) {
            const message = getStringField(value, "message") orelse {
                return writeError(w, id, command, "prompt requires a string message");
            };
            const image_parts = parseRpcImages(allocator, value) catch {
                return writeError(w, id, command, "prompt images must be ImageContent objects with type=image, data, and mimeType");
            };
            defer freeRpcImages(allocator, image_parts);
            return self.handlePromptCommand(io, allocator, w, id, command, message, image_parts);
        }

        if (std.mem.eql(u8, command, "steer")) {
            const message = getStringField(value, "message") orelse {
                return writeError(w, id, command, "steer requires a string message");
            };
            const image_parts = parseRpcImages(allocator, value) catch {
                return writeError(w, id, command, "steer images must be ImageContent objects with type=image, data, and mimeType");
            };
            defer freeRpcImages(allocator, image_parts);
            return self.enqueuePendingMessage(allocator, w, id, command, &self.steering_queue, message, image_parts);
        }

        if (std.mem.eql(u8, command, "follow_up")) {
            const message = getStringField(value, "message") orelse {
                return writeError(w, id, command, "follow_up requires a string message");
            };
            const image_parts = parseRpcImages(allocator, value) catch {
                return writeError(w, id, command, "follow_up images must be ImageContent objects with type=image, data, and mimeType");
            };
            defer freeRpcImages(allocator, image_parts);
            return self.enqueuePendingMessage(allocator, w, id, command, &self.follow_up_queue, message, image_parts);
        }

        if (std.mem.eql(u8, command, "abort")) {
            self.steering_queue.clear(allocator);
            self.follow_up_queue.clear(allocator);
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "bash")) {
            const shell_command = getStringField(value, "command") orelse {
                return writeError(w, id, command, "bash requires a string command");
            };
            const timeout_ms = getOptionalTimeoutMillisecondsField(value, "timeout") catch {
                return writeError(w, id, command, "bash timeout must be a non-negative finite number");
            };
            const result = self.executeBash(io, allocator, shell_command, timeout_ms) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            defer allocator.free(result.output);
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":");
            try writeBashResultJson(w, result);
            try w.writeAll("}\n");
            return;
        }

        if (std.mem.eql(u8, command, "abort_bash")) {
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "new_session")) {
            const parent_session = getStringField(value, "parentSession");
            self.clearSession(io, allocator, parent_session) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":{\"cancelled\":false}}\n");
            return;
        }

        if (std.mem.eql(u8, command, "get_state")) {
            return self.writeState(w, id, command);
        }

        if (std.mem.eql(u8, command, "get_messages")) {
            return self.writeMessages(w, id, command);
        }

        if (std.mem.eql(u8, command, "set_model")) {
            const provider = getStringField(value, "provider") orelse {
                return writeError(w, id, command, "set_model requires a string provider");
            };
            const model_id = getStringField(value, "modelId") orelse {
                return writeError(w, id, command, "set_model requires a string modelId");
            };
            const model = models.find(provider, model_id) orelse {
                return writeError(w, id, command, "model not found");
            };
            self.setModel(io, allocator, model) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":");
            try models.writeModelJson(w, model);
            try w.writeAll("}\n");
            return;
        }

        if (std.mem.eql(u8, command, "get_available_models")) {
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":");
            try models.writeRpcAvailableModelsData(w);
            try w.writeAll("}\n");
            return;
        }

        if (std.mem.eql(u8, command, "cycle_model")) {
            if (models.all.len <= 1) {
                try writeResponseHead(w, id, command, true);
                try w.writeAll(",\"data\":null}\n");
                return;
            }
            const model = models.next(self.selected_model);
            self.setModel(io, allocator, model) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":{\"model\":");
            try models.writeModelJson(w, model);
            try w.writeAll(",\"thinkingLevel\":");
            try writeJsonString(w, thinkingLevelLabel(self.thinking_level));
            try w.writeAll(",\"isScoped\":false}}\n");
            return;
        }

        if (std.mem.eql(u8, command, "get_session_stats")) {
            return self.writeSessionStats(w, id, command);
        }

        if (std.mem.eql(u8, command, "get_fork_messages")) {
            return self.writeForkMessages(w, id, command);
        }

        if (std.mem.eql(u8, command, "get_last_assistant_text")) {
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":{\"text\":");
            if (self.lastAssistantText()) |text| {
                try writeJsonString(w, text);
            } else {
                try w.writeAll("null");
            }
            try w.writeAll("}}\n");
            return;
        }

        if (std.mem.eql(u8, command, "export_html")) {
            const output_path = getStringField(value, "outputPath") orelse "zig-out/pi-zig-session-export.html";
            self.exportHtml(io, allocator, output_path) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":{\"path\":");
            try writeJsonString(w, output_path);
            try w.writeAll("}}\n");
            return;
        }

        if (std.mem.eql(u8, command, "set_session_name")) {
            const name = getStringField(value, "name") orelse {
                return writeError(w, id, command, "set_session_name requires a string name");
            };
            self.setSessionName(io, allocator, name) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "set_thinking_level")) {
            const level = getStringField(value, "level") orelse {
                return writeError(w, id, command, "set_thinking_level requires a string level");
            };
            const parsed_level = types.ThinkingLevel.parse(level) orelse {
                return writeError(w, id, command, "unknown thinking level");
            };
            self.setThinkingLevel(io, allocator, parsed_level) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "cycle_thinking_level")) {
            const next_level = models.nextThinkingLevel(self.selected_model, self.thinking_level) orelse {
                try writeResponseHead(w, id, command, true);
                try w.writeAll(",\"data\":null}\n");
                return;
            };
            self.setThinkingLevel(io, allocator, next_level) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":{\"level\":");
            try writeJsonString(w, thinkingLevelLabel(self.thinking_level));
            try w.writeAll("}}\n");
            return;
        }

        if (std.mem.eql(u8, command, "set_steering_mode")) {
            const mode = getStringField(value, "mode") orelse {
                return writeError(w, id, command, "set_steering_mode requires a string mode");
            };
            self.steering_mode = QueueMode.parse(mode) orelse {
                return writeError(w, id, command, "unknown steering mode");
            };
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "set_follow_up_mode")) {
            const mode = getStringField(value, "mode") orelse {
                return writeError(w, id, command, "set_follow_up_mode requires a string mode");
            };
            self.follow_up_mode = QueueMode.parse(mode) orelse {
                return writeError(w, id, command, "unknown follow-up mode");
            };
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "compact")) {
            const custom_instructions = getStringField(value, "customInstructions");
            self.writeCompactResponse(io, allocator, w, id, command, custom_instructions) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            return;
        }

        if (std.mem.eql(u8, command, "set_auto_compaction")) {
            self.auto_compaction_enabled = getBoolField(value, "enabled") orelse {
                return writeError(w, id, command, "set_auto_compaction requires a boolean enabled");
            };
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "set_auto_retry")) {
            self.auto_retry_enabled = getBoolField(value, "enabled") orelse {
                return writeError(w, id, command, "set_auto_retry requires a boolean enabled");
            };
            if (getOptionalUsizeField(value, "maxRetries")) |max_retries| self.auto_retry_max_attempts = max_retries;
            if (getOptionalUsizeField(value, "baseDelayMs")) |base_delay_ms| self.auto_retry_base_delay_ms = base_delay_ms;
            if (getOptionalUsizeField(value, "maxDelayMs")) |max_delay_ms| self.auto_retry_max_delay_ms = max_delay_ms;
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "abort_retry")) {
            self.auto_retry_enabled = false;
            self.last_retry_attempts = 0;
            self.last_retry_delay_ms = 0;
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "get_commands")) {
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":");
            try commands.writeCommandsDataJsonWithOptions(io, allocator, w, self.command_options);
            try w.writeAll("}\n");
            return;
        }

        if (std.mem.eql(u8, command, "switch_session")) {
            const session_path = getStringField(value, "sessionPath") orelse {
                return writeError(w, id, command, "switch_session requires a string sessionPath");
            };
            self.switchSession(io, allocator, session_path) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":{\"cancelled\":false}}\n");
            return;
        }

        if (std.mem.eql(u8, command, "fork")) {
            const entry_id = getStringField(value, "entryId") orelse {
                return writeError(w, id, command, "fork requires a string entryId");
            };
            var text_buffer: [max_message_bytes]u8 = undefined;
            const text = self.forkSession(io, allocator, entry_id, &text_buffer) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":{\"text\":");
            try writeJsonString(w, text);
            try w.writeAll(",\"cancelled\":false}}\n");
            return;
        }

        if (std.mem.eql(u8, command, "clone")) {
            self.cloneSession(io, allocator) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            try writeResponseHead(w, id, command, true);
            try w.writeAll(",\"data\":{\"cancelled\":false}}\n");
            return;
        }

        return writeError(w, id, command, "command not implemented in the foundation RPC runtime");
    }

    fn writeState(self: *Runtime, w: *std.Io.Writer, id: ?[]const u8, command: []const u8) !void {
        try writeResponseHead(w, id, command, true);
        try w.writeAll(",\"data\":{\"model\":");
        if (self.selected_model) |model| {
            try models.writeModelJson(w, model);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"thinkingLevel\":");
        try writeJsonString(w, thinkingLevelLabel(self.thinking_level));
        try w.writeAll(",\"isStreaming\":false,\"isCompacting\":false,\"steeringMode\":");
        try writeJsonString(w, self.steering_mode.label());
        try w.writeAll(",\"followUpMode\":");
        try writeJsonString(w, self.follow_up_mode.label());
        try w.writeAll(",\"sessionId\":");
        try writeJsonString(w, self.store.sessionId());
        try w.writeAll(",\"sessionFile\":");
        try writeJsonString(w, self.store.path());
        try w.writeAll(",\"autoCompactionEnabled\":");
        try w.writeAll(if (self.auto_compaction_enabled) "true" else "false");
        try w.writeAll(",\"autoRetryEnabled\":");
        try w.writeAll(if (self.auto_retry_enabled) "true" else "false");
        try w.writeAll(",\"autoRetryMaxAttempts\":");
        try w.print("{d}", .{self.auto_retry_max_attempts});
        try w.writeAll(",\"autoRetryBaseDelayMs\":");
        try w.print("{d}", .{self.auto_retry_base_delay_ms});
        try w.writeAll(",\"autoRetryMaxDelayMs\":");
        try w.print("{d}", .{self.auto_retry_max_delay_ms});
        try w.writeAll(",\"lastRetryAttempts\":");
        try w.print("{d}", .{self.last_retry_attempts});
        try w.writeAll(",\"lastRetryDelayMs\":");
        try w.print("{d}", .{self.last_retry_delay_ms});
        try w.writeAll(",\"messageCount\":");
        try w.print("{d}", .{self.message_count});
        try w.writeAll(",\"pendingMessageCount\":");
        try w.print("{d}", .{self.steering_queue.count + self.follow_up_queue.count});
        try w.writeAll(",\"pendingSteeringCount\":");
        try w.print("{d}", .{self.steering_queue.count});
        try w.writeAll(",\"pendingFollowUpCount\":");
        try w.print("{d}", .{self.follow_up_queue.count});
        if (self.sessionName()) |name| {
            try w.writeAll(",\"sessionName\":");
            try writeJsonString(w, name);
        }
        try w.writeAll("}}\n");
    }

    fn writeMessages(self: *Runtime, w: *std.Io.Writer, id: ?[]const u8, command: []const u8) !void {
        try writeResponseHead(w, id, command, true);
        try w.writeAll(",\"data\":{\"messages\":[");
        var emitted: usize = 0;
        if (self.latestCompactionIndex(self.message_count)) |compaction_index| {
            try self.writeStoredMessageWithComma(w, &self.messages[compaction_index], &emitted);
            const first_kept_index = self.firstKeptMessageIndex(compaction_index) orelse compaction_index + 1;
            try self.writeMessageRange(w, first_kept_index, compaction_index, &emitted);
            try self.writeMessageRange(w, compaction_index + 1, self.message_count, &emitted);
        } else {
            try self.writeMessageRange(w, 0, self.message_count, &emitted);
        }
        try w.writeAll("]}}\n");
    }

    fn writeMessageRange(self: *Runtime, w: *std.Io.Writer, start: usize, end: usize, emitted: *usize) !void {
        if (start >= end) return;
        for (self.messages[start..end]) |*message| {
            if (message.role == .compaction_summary) continue;
            try self.writeStoredMessageWithComma(w, message, emitted);
        }
    }

    fn writeStoredMessageWithComma(self: *Runtime, w: *std.Io.Writer, message: *const StoredMessage, emitted: *usize) !void {
        if (emitted.* != 0) try w.writeByte(',');
        try self.writeStoredMessage(w, message);
        emitted.* += 1;
    }

    fn writeStoredMessage(self: *Runtime, w: *std.Io.Writer, message: *const StoredMessage) !void {
        _ = self;
        try w.writeAll("{\"role\":");
        try writeJsonString(w, message.role.label());
        if (message.role == .bash_execution) {
            try w.writeAll(",\"command\":");
            try writeJsonString(w, message.commandText());
            try w.writeAll(",\"output\":");
            try writeJsonString(w, message.text());
            try w.writeAll(",\"exitCode\":");
            if (message.exit_code) |code| {
                try w.print("{d}", .{code});
            } else {
                try w.writeAll("null");
            }
            try w.writeAll(",\"cancelled\":");
            try w.writeAll(if (message.cancelled) "true" else "false");
            try w.writeAll(",\"truncated\":");
            try w.writeAll(if (message.truncated) "true" else "false");
            if (message.fullOutputPath()) |path| {
                try w.writeAll(",\"fullOutputPath\":");
                try writeJsonString(w, path);
            }
        } else if (message.role == .compaction_summary) {
            try w.writeAll(",\"summary\":");
            try writeJsonString(w, message.text());
            try w.writeAll(",\"tokensBefore\":");
            try w.print("{d}", .{message.tokens_before});
            try w.writeAll(",\"firstKeptEntryId\":");
            try writeJsonString(w, message.firstKeptEntryId());
        } else {
            try w.writeAll(",\"content\":");
            try writeJsonString(w, message.text());
            if (message.role == .user and message.image_parts.len > 0) {
                try w.writeAll(",\"images\":");
                try writeImagePartsJson(w, message.image_parts);
            }
            if (message.role == .assistant and message.tool_calls_count > 0) {
                try w.writeAll(",\"toolCalls\":[");
                for (message.tool_calls[0..message.tool_calls_count], 0..) |*call, index| {
                    if (index != 0) try w.writeByte(',');
                    try w.writeAll("{\"id\":");
                    try writeJsonString(w, call.idText());
                    try w.writeAll(",\"name\":");
                    try writeJsonString(w, call.nameText());
                    try w.writeAll(",\"argumentsJson\":");
                    try writeJsonString(w, call.argumentsJson());
                    try w.writeByte('}');
                }
                try w.writeByte(']');
            } else if (message.role == .tool) {
                if (message.toolCallId()) |tool_call_id| {
                    try w.writeAll(",\"toolCallId\":");
                    try writeJsonString(w, tool_call_id);
                }
                if (message.toolName()) |tool_name| {
                    try w.writeAll(",\"toolName\":");
                    try writeJsonString(w, tool_name);
                }
                try w.writeAll(",\"isError\":");
                try w.writeAll(if (message.tool_is_error) "true" else "false");
                try w.writeAll(",\"terminate\":");
                try w.writeAll(if (message.tool_terminate) "true" else "false");
            }
        }
        try w.writeByte('}');
    }

    fn writeSessionStats(self: *Runtime, w: *std.Io.Writer, id: ?[]const u8, command: []const u8) !void {
        try writeResponseHead(w, id, command, true);
        try w.writeAll(",\"data\":{\"sessionFile\":");
        try writeJsonString(w, self.store.path());
        try w.writeAll(",\"sessionId\":");
        try writeJsonString(w, self.store.sessionId());
        try w.writeAll(",\"userMessages\":");
        try w.print("{d}", .{self.store.user_messages});
        try w.writeAll(",\"assistantMessages\":");
        try w.print("{d}", .{self.store.assistant_messages});
        try w.writeAll(",\"toolCalls\":");
        try w.print("{d}", .{self.store.tool_calls});
        try w.writeAll(",\"toolResults\":");
        try w.print("{d}", .{self.store.tool_results});
        try w.writeAll(",\"totalMessages\":");
        try w.print("{d}", .{self.store.totalMessages()});
        try w.writeAll(",\"tokens\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0},\"cost\":0}}\n");
    }

    fn writeForkMessages(self: *Runtime, w: *std.Io.Writer, id: ?[]const u8, command: []const u8) !void {
        try writeResponseHead(w, id, command, true);
        try w.writeAll(",\"data\":{\"messages\":[");
        var emitted: usize = 0;
        for (self.messages[0..self.message_count]) |*message| {
            if (message.role != .user) continue;
            if (emitted != 0) try w.writeByte(',');
            try w.writeAll("{\"entryId\":");
            try writeJsonString(w, message.entryId());
            try w.writeAll(",\"text\":");
            try writeJsonString(w, message.text());
            try w.writeByte('}');
            emitted += 1;
        }
        try w.writeAll("]}}\n");
    }

    fn exportHtml(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, output_path: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><title>pi-zig session</title>");
        try w.writeAll("<style>body{font-family:system-ui,sans-serif;margin:32px;color:#1f2328}article{border-top:1px solid #d0d7de;padding:12px 0}b{display:block;margin-bottom:6px}</style>");
        try w.writeAll("</head><body><h1>pi-zig session</h1><p>Session file: ");
        try writeHtmlEscaped(w, self.store.path());
        try w.writeAll("</p>");
        for (self.messages[0..self.message_count]) |*message| {
            try w.writeAll("<article><b>");
            try writeHtmlEscaped(w, message.role.label());
            try w.writeAll("</b><pre>");
            try writeHtmlEscaped(w, message.text());
            try w.writeAll("</pre></article>");
        }
        try w.writeAll("</body></html>\n");
        try ensureParentDir(io, output_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = out.written() });
    }
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    session_file: []const u8,
    command_options: commands.Options,
) !void {
    var runtime: Runtime = .{};
    try runtime.init(io, allocator, env, session_file, command_options);
    defer runtime.deinit(allocator);

    var in_buf: [16 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &in_buf);
    const r = &stdin_reader.interface;

    var out_buf: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout_writer.interface;
    defer w.flush() catch {};

    while (true) {
        const raw_line = r.takeDelimiter('\n') catch |err| {
            try writeError(w, null, "parse", @errorName(err));
            try w.flush();
            return err;
        };
        const line_with_cr = raw_line orelse break;
        const line = stripTrailingCarriageReturn(line_with_cr);
        if (std.mem.trim(u8, line, " \t").len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
            try writeError(w, null, "parse", @errorName(err));
            try w.flush();
            continue;
        };
        defer parsed.deinit();

        try runtime.handleValue(io, allocator, w, parsed.value);
        try w.flush();
    }
}

fn getStringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    return getStringFieldObject(value.object, name);
}

fn getBoolField(value: std.json.Value, name: []const u8) ?bool {
    if (value != .object) return null;
    return getBoolFieldObject(value.object, name);
}

fn getOptionalUsizeField(value: std.json.Value, name: []const u8) ?usize {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .float => |float| if (float >= 0 and @floor(float) == float) @intFromFloat(float) else null,
        else => null,
    };
}

fn getOptionalTimeoutMillisecondsField(value: std.json.Value, name: []const u8) !?i64 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    const seconds: f64 = switch (field) {
        .integer => |integer| blk: {
            if (integer < 0) return error.InvalidTimeout;
            break :blk @floatFromInt(integer);
        },
        .float => |float| blk: {
            if (float < 0 or !std.math.isFinite(float)) return error.InvalidTimeout;
            break :blk float;
        },
        else => return error.InvalidTimeout,
    };
    if (seconds <= 0) return null;
    const milliseconds = @round(seconds * 1000.0);
    if (milliseconds > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return error.InvalidTimeout;
    return @max(1, @as(i64, @intFromFloat(milliseconds)));
}

fn parseRpcImages(allocator: std.mem.Allocator, value: std.json.Value) ![]ai_client.ChatContentPart {
    if (value != .object) return &.{};
    const images = value.object.get("images") orelse return &.{};
    if (images != .array) return error.InvalidRpcImages;
    if (images.array.items.len == 0) return &.{};

    const parts = try allocator.alloc(ai_client.ChatContentPart, images.array.items.len);
    var len: usize = 0;
    errdefer {
        for (parts[0..len]) |part| {
            switch (part) {
                .text => {},
                .image => |image| {
                    allocator.free(image.data);
                    allocator.free(image.mime_type);
                },
            }
        }
        allocator.free(parts);
    }

    for (images.array.items) |item| {
        if (item != .object) return error.InvalidRpcImages;
        const image_type = getStringFieldObject(item.object, "type") orelse return error.InvalidRpcImages;
        if (!std.mem.eql(u8, image_type, "image")) return error.InvalidRpcImages;
        const data = getStringFieldObject(item.object, "data") orelse return error.InvalidRpcImages;
        const mime_type = getStringFieldObject(item.object, "mimeType") orelse return error.InvalidRpcImages;
        const owned_data = try allocator.dupe(u8, data);
        errdefer allocator.free(owned_data);
        const owned_mime_type = try allocator.dupe(u8, mime_type);
        errdefer allocator.free(owned_mime_type);
        parts[len] = .{ .image = .{
            .data = owned_data,
            .mime_type = owned_mime_type,
        } };
        len += 1;
    }
    return parts;
}

fn freeRpcImages(allocator: std.mem.Allocator, parts: []ai_client.ChatContentPart) void {
    if (parts.len == 0) return;
    for (parts) |part| {
        switch (part) {
            .text => {},
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
        }
    }
    allocator.free(parts);
}

fn cloneImageParts(allocator: std.mem.Allocator, parts: []const ai_client.ChatContentPart) ![]ai_client.ChatContentPart {
    if (parts.len == 0) return &.{};
    const cloned = try allocator.alloc(ai_client.ChatContentPart, parts.len);
    var len: usize = 0;
    errdefer {
        for (cloned[0..len]) |part| {
            switch (part) {
                .text => |text| allocator.free(text),
                .image => |image| {
                    allocator.free(image.data);
                    allocator.free(image.mime_type);
                },
            }
        }
        allocator.free(cloned);
    }
    for (parts) |part| {
        switch (part) {
            .text => |text| {
                cloned[len] = .{ .text = try allocator.dupe(u8, text) };
            },
            .image => |image| {
                const owned_data = try allocator.dupe(u8, image.data);
                errdefer allocator.free(owned_data);
                const owned_mime_type = try allocator.dupe(u8, image.mime_type);
                errdefer allocator.free(owned_mime_type);
                cloned[len] = .{ .image = .{
                    .data = owned_data,
                    .mime_type = owned_mime_type,
                } };
            },
        }
        len += 1;
    }
    return cloned;
}

fn freeRpcContentParts(allocator: std.mem.Allocator, parts: []const ai_client.ChatContentPart) void {
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

fn buildPromptContentParts(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    image_parts: []const ai_client.ChatContentPart,
) ![]ai_client.ChatContentPart {
    if (image_parts.len == 0) return &.{};
    const text_parts: usize = if (prompt.len > 0) 1 else 0;
    const parts = try allocator.alloc(ai_client.ChatContentPart, text_parts + image_parts.len);
    var index: usize = 0;
    if (prompt.len > 0) {
        parts[index] = .{ .text = prompt };
        index += 1;
    }
    for (image_parts) |part| {
        parts[index] = part;
        index += 1;
    }
    return parts;
}

fn buildOwnedPromptContentParts(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    image_parts: []const ai_client.ChatContentPart,
) ![]ai_client.ChatContentPart {
    if (image_parts.len == 0) return &.{};
    const text_parts: usize = if (prompt.len > 0) 1 else 0;
    const parts = try allocator.alloc(ai_client.ChatContentPart, text_parts + image_parts.len);
    var index: usize = 0;
    errdefer {
        for (parts[0..index]) |part| {
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
    if (prompt.len > 0) {
        parts[index] = .{ .text = try allocator.dupe(u8, prompt) };
        index += 1;
    }
    for (image_parts) |part| {
        switch (part) {
            .text => |text| {
                parts[index] = .{ .text = try allocator.dupe(u8, text) };
            },
            .image => |image| {
                const owned_data = try allocator.dupe(u8, image.data);
                errdefer allocator.free(owned_data);
                const owned_mime_type = try allocator.dupe(u8, image.mime_type);
                errdefer allocator.free(owned_mime_type);
                parts[index] = .{ .image = .{
                    .data = owned_data,
                    .mime_type = owned_mime_type,
                } };
            },
        }
        index += 1;
    }
    return parts;
}

fn getStringFieldObject(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const field = object.get(name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn getBoolFieldObject(object: std.json.ObjectMap, name: []const u8) ?bool {
    const field = object.get(name) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn isRetryableAgentError(err: anyerror) bool {
    return switch (err) {
        error.ProviderRequestFailed => true,
        else => false,
    };
}

fn sleepMilliseconds(io: std.Io, milliseconds: usize) !void {
    const bounded = @min(milliseconds, @as(usize, @intCast(std.math.maxInt(i64))));
    try std.Io.sleep(io, .fromMilliseconds(@intCast(bounded)), .awake);
}

fn getOptionalExitCode(object: std.json.ObjectMap) ?u8 {
    const field = object.get("exitCode") orelse return null;
    return switch (field) {
        .integer => |value| if (value >= 0 and value <= 255) @intCast(value) else null,
        else => null,
    };
}

fn stripTrailingCarriageReturn(value: []const u8) []const u8 {
    if (value.len > 0 and value[value.len - 1] == '\r') return value[0 .. value.len - 1];
    return value;
}

fn writeSuccess(w: *std.Io.Writer, id: ?[]const u8, command: []const u8) !void {
    try writeResponseHead(w, id, command, true);
    try w.writeAll("}\n");
}

fn writeError(w: *std.Io.Writer, id: ?[]const u8, command: []const u8, message: []const u8) !void {
    try writeResponseHead(w, id, command, false);
    try w.writeAll(",\"error\":");
    try writeJsonString(w, message);
    try w.writeAll("}\n");
}

fn writeResponseHead(w: *std.Io.Writer, id: ?[]const u8, command: []const u8, success: bool) !void {
    try w.writeByte('{');
    if (id) |request_id| {
        try w.writeAll("\"id\":");
        try writeJsonString(w, request_id);
        try w.writeByte(',');
    }
    try w.writeAll("\"type\":\"response\",\"command\":");
    try writeJsonString(w, command);
    try w.writeAll(",\"success\":");
    try w.writeAll(if (success) "true" else "false");
}

fn writeBashResultJson(w: *std.Io.Writer, result: tools.ShellResult) !void {
    try w.writeAll("{\"output\":");
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
    try w.writeByte('}');
}

fn writeImagePartsJson(w: *std.Io.Writer, parts: []const ai_client.ChatContentPart) !void {
    try w.writeByte('[');
    var emitted = false;
    for (parts) |part| {
        switch (part) {
            .text => {},
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
    try w.writeByte(']');
}

fn writeAgentToolResultsJson(w: *std.Io.Writer, results: []const agent.ToolResult) !void {
    try w.writeByte('[');
    for (results, 0..) |result, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"toolCallId\":");
        try writeJsonString(w, result.tool_call_id);
        try w.writeAll(",\"toolName\":");
        try writeJsonString(w, result.tool_name);
        try w.writeAll(",\"arguments\":");
        try writeJsonString(w, result.arguments_json);
        try w.writeAll(",\"content\":");
        try writeJsonString(w, result.content);
        try w.writeAll(",\"isError\":");
        try w.writeAll(if (result.is_error) "true" else "false");
        try w.writeAll(",\"terminate\":");
        try w.writeAll(if (result.terminate) "true" else "false");
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn buildRuntimeSystemPrompt(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
) ![]u8 {
    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);

    const package_dir = try system_prompt.resolvePackageDir(io, allocator, env, cwd, null);
    defer allocator.free(package_dir);

    var discovery = try context_files.discover(io, allocator, env, .{});
    defer discovery.deinit();

    const append_prompt = try system_prompt.combineAppendPrompt(allocator, discovery.append_system_prompt, &.{});
    defer if (append_prompt) |value| allocator.free(value);

    var date_buf: [10]u8 = undefined;
    const current_date = try system_prompt.currentUtcDate(io, &date_buf);

    return system_prompt.build(allocator, .{
        .custom_prompt = if (discovery.system_prompt) |file| file.content else null,
        .append_system_prompt = append_prompt,
        .selected_tools = all_tool_names[0..],
        .cwd = cwd,
        .package_dir = package_dir,
        .date = current_date,
        .context_files = discovery.context_files.items,
        .include_builtin_tool_metadata = true,
    });
}

fn currentPathOwned(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
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

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn parseStoredRole(role: []const u8) ?StoredRole {
    if (std.mem.eql(u8, role, "system")) return .system;
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    if (std.mem.eql(u8, role, "tool") or std.mem.eql(u8, role, "toolResult")) return .tool;
    if (std.mem.eql(u8, role, "bashExecution")) return .bash_execution;
    if (std.mem.eql(u8, role, "compactionSummary")) return .compaction_summary;
    return null;
}

fn copyToolCallsFromMessage(object: std.json.ObjectMap, message: *StoredMessage) !void {
    message.tool_calls_count = 0;
    const content = object.get("content") orelse return;
    if (content != .array) return;
    for (content.array.items) |item| {
        if (item != .object) continue;
        const block_type = getStringFieldObject(item.object, "type") orelse continue;
        if (!std.mem.eql(u8, block_type, "toolCall")) continue;
        if (message.tool_calls_count >= max_tool_calls_per_message) return error.ValueTooLong;
        const id = getStringFieldObject(item.object, "id") orelse return error.InvalidSessionEntry;
        const name = getStringFieldObject(item.object, "name") orelse return error.InvalidSessionEntry;
        const arguments_json = getStringFieldObject(item.object, "argumentsJson") orelse "{}";
        var target = &message.tool_calls[message.tool_calls_count];
        try copyBounded(&target.id, &target.id_len, id);
        try copyBounded(&target.name, &target.name_len, name);
        try copyBounded(&target.arguments_json, &target.arguments_json_len, arguments_json);
        message.tool_calls_count += 1;
    }
}

fn copyToolResultFieldsFromMessage(object: std.json.ObjectMap, message: *StoredMessage) !void {
    message.tool_call_id_len = 0;
    message.tool_name_len = 0;
    if (getStringFieldObject(object, "toolCallId")) |id| {
        try copyBounded(&message.tool_call_id, &message.tool_call_id_len, id);
    }
    if (getStringFieldObject(object, "toolName")) |name| {
        try copyBounded(&message.tool_name, &message.tool_name_len, name);
    }
    message.tool_is_error = getBoolFieldObject(object, "isError") orelse false;
    message.tool_terminate = getBoolFieldObject(object, "terminate") orelse false;
}

fn copyBounded(buffer: []u8, len: *usize, value: []const u8) !void {
    if (value.len > buffer.len) return error.ValueTooLong;
    @memcpy(buffer[0..value.len], value);
    len.* = value.len;
}

fn extractMessageText(object: std.json.ObjectMap, buffer: []u8) !usize {
    const content = object.get("content") orelse return 0;
    var writer = std.Io.Writer.fixed(buffer);
    switch (content) {
        .string => |text| try appendBoundedText(&writer, text),
        .array => |array| {
            for (array.items) |item| {
                if (item != .object) continue;
                const block_type = getStringFieldObject(item.object, "type") orelse continue;
                if (std.mem.eql(u8, block_type, "text")) {
                    if (getStringFieldObject(item.object, "text")) |text| {
                        if (writer.buffered().len > 0) try writer.writeByte('\n');
                        try appendBoundedText(&writer, text);
                    }
                } else if (std.mem.eql(u8, block_type, "thinking")) {
                    if (getStringFieldObject(item.object, "thinking")) |thinking| {
                        if (writer.buffered().len > 0) try writer.writeByte('\n');
                        try appendBoundedText(&writer, thinking);
                    }
                }
            }
        },
        else => {},
    }
    return writer.buffered().len;
}

fn extractMessageImages(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]ai_client.ChatContentPart {
    const content = object.get("content") orelse return &.{};
    if (content != .array) return &.{};
    var count: usize = 0;
    for (content.array.items) |item| {
        if (item != .object) continue;
        const block_type = getStringFieldObject(item.object, "type") orelse continue;
        if (std.mem.eql(u8, block_type, "image")) count += 1;
    }
    if (count == 0) return &.{};

    const parts = try allocator.alloc(ai_client.ChatContentPart, count);
    var len: usize = 0;
    errdefer {
        for (parts[0..len]) |part| {
            switch (part) {
                .text => {},
                .image => |image| {
                    allocator.free(image.data);
                    allocator.free(image.mime_type);
                },
            }
        }
        allocator.free(parts);
    }

    for (content.array.items) |item| {
        if (item != .object) continue;
        const block_type = getStringFieldObject(item.object, "type") orelse continue;
        if (!std.mem.eql(u8, block_type, "image")) continue;
        const data = getStringFieldObject(item.object, "data") orelse return error.InvalidSessionEntry;
        const mime_type = getStringFieldObject(item.object, "mimeType") orelse return error.InvalidSessionEntry;
        const owned_data = try allocator.dupe(u8, data);
        errdefer allocator.free(owned_data);
        const owned_mime_type = try allocator.dupe(u8, mime_type);
        errdefer allocator.free(owned_mime_type);
        parts[len] = .{ .image = .{
            .data = owned_data,
            .mime_type = owned_mime_type,
        } };
        len += 1;
    }
    return parts;
}

fn appendBoundedText(w: *std.Io.Writer, text: []const u8) !void {
    w.writeAll(text) catch return error.MessageTooLarge;
}

fn boundedStoredOutput(output: []const u8) []const u8 {
    if (output.len <= max_message_bytes) return output;
    var start = output.len - max_message_bytes;
    while (start < output.len and (output[start] & 0xc0) == 0x80) : (start += 1) {}
    return output[start..];
}

fn appendSummarySnippet(w: *std.Io.Writer, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const max_len = @min(trimmed.len, 120);
    try w.writeAll(trimmed[0..max_len]);
    if (trimmed.len > max_len) try w.writeAll("...");
}

fn nextThinkingLevel(level: types.ThinkingLevel) types.ThinkingLevel {
    return switch (level) {
        .off => .minimal,
        .minimal => .low,
        .low => .medium,
        .medium => .high,
        .high => .xhigh,
        .xhigh => .off,
    };
}

fn thinkingLevelLabel(level: types.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

test "json string escaping covers control characters" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeJsonString(&writer, "a\"b\nc");
    try std.testing.expectEqualStrings("\"a\\\"b\\nc\"", writer.buffered());
}

test "runtime stores prompt messages and resets sessions" {
    std.Io.Dir.cwd().deleteFile(std.testing.io, "zig-out/pi-zig-rpc-test.jsonl") catch {};
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var runtime: Runtime = .{};
    try runtime.init(std.testing.io, std.testing.allocator, &env, "zig-out/pi-zig-rpc-test.jsonl", .{});
    try runtime.addMessage(std.testing.io, std.testing.allocator, .user, "hello");
    try std.testing.expectEqual(@as(usize, 1), runtime.message_count);
    try runtime.clearSession(std.testing.io, std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 0), runtime.message_count);
    try std.testing.expectEqual(@as(usize, 2), runtime.session_generation);
}

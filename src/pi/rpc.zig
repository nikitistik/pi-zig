const std = @import("std");
const commands = @import("commands.zig");
const models = @import("models.zig");
const session = @import("session.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");

const max_messages = 128;
const max_message_bytes = 8 * 1024;
const max_command_bytes = 4 * 1024;
const max_session_name_bytes = 256;
const max_session_file_bytes = 16 * 1024 * 1024;
const max_session_path_bytes = std.Io.Dir.max_path_bytes;

const StoredRole = enum {
    system,
    user,
    assistant,
    tool,
    bash_execution,

    fn label(self: StoredRole) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
            .bash_execution => "bashExecution",
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

const StoredMessage = struct {
    role: StoredRole = .user,
    id_len: usize = 0,
    id: [32]u8 = undefined,
    len: usize = 0,
    content: [max_message_bytes]u8 = undefined,
    command_len: usize = 0,
    command: [max_command_bytes]u8 = undefined,
    exit_code: ?u8 = null,
    cancelled: bool = false,
    truncated: bool = false,

    fn entryId(self: *const StoredMessage) []const u8 {
        return self.id[0..self.id_len];
    }

    fn text(self: *const StoredMessage) []const u8 {
        return self.content[0..self.len];
    }

    fn commandText(self: *const StoredMessage) []const u8 {
        return self.command[0..self.command_len];
    }
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
    auto_compaction_enabled: bool = false,
    auto_retry_enabled: bool = false,
    command_options: commands.Options = .{},

    fn init(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, session_file: []const u8, command_options: commands.Options) !void {
        self.resetInMemory();
        self.command_options = command_options;
        self.store = try session.PersistentStore.init(io, allocator, session_file);
        try self.loadSessionEntries(io, allocator);
    }

    fn resetInMemory(self: *Runtime) void {
        self.message_count = 0;
        self.session_name_len = 0;
        self.has_session_name = false;
        self.selected_model = null;
        self.thinking_level = .medium;
        self.auto_compaction_enabled = false;
        self.auto_retry_enabled = false;
    }

    fn clearSession(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, parent_session: ?[]const u8) !void {
        self.resetInMemory();
        self.session_generation += 1;
        try self.store.newSession(io, allocator, parent_session);
    }

    fn switchSession(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, session_file: []const u8) !void {
        self.resetInMemory();
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
                .user => _ = try new_store.appendMessage(io, allocator, .user, message.text()),
                .assistant => _ = try new_store.appendMessage(io, allocator, .assistant, message.text()),
                .tool => _ = try new_store.appendMessage(io, allocator, .tool, message.text()),
                .bash_execution => {
                    const result: tools.ShellResult = .{
                        .output = message.content[0..message.len],
                        .exit_code = message.exit_code,
                        .cancelled = message.cancelled,
                        .truncated = message.truncated,
                    };
                    _ = try new_store.appendBashExecution(io, allocator, message.commandText(), result);
                },
            }
        }
        if (previous_model) |model| try new_store.appendModelChange(io, allocator, model.provider, model.id);
        try new_store.appendThinkingLevelChange(io, allocator, thinkingLevelLabel(previous_thinking));
        if (previous_name) |name| try new_store.appendSessionInfo(io, allocator, name);

        self.resetInMemory();
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
                try self.loadMessageEntry(parsed.value.object);
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
            }
        }
    }

    fn loadMessageEntry(self: *Runtime, object: std.json.ObjectMap) !void {
        const id = getStringFieldObject(object, "id") orelse return error.InvalidSessionEntry;
        const message = object.get("message") orelse return error.InvalidSessionEntry;
        if (message != .object) return error.InvalidSessionEntry;
        const role_label = getStringFieldObject(message.object, "role") orelse return error.InvalidSessionEntry;
        const role = parseStoredRole(role_label) orelse return;

        if (role == .bash_execution) {
            var output_buf: [max_message_bytes]u8 = undefined;
            const output = getStringFieldObject(message.object, "output") orelse "";
            if (output.len > output_buf.len) return error.MessageTooLarge;
            @memcpy(output_buf[0..output.len], output);
            const result: tools.ShellResult = .{
                .output = output_buf[0..output.len],
                .exit_code = getOptionalExitCode(message.object),
                .cancelled = getBoolFieldObject(message.object, "cancelled") orelse false,
                .truncated = getBoolFieldObject(message.object, "truncated") orelse false,
            };
            try self.addLoadedBash(id, getStringFieldObject(message.object, "command") orelse "", result);
        } else {
            var text_buf: [max_message_bytes]u8 = undefined;
            const text_len = try extractMessageText(message.object, &text_buf);
            try self.addLoadedMessage(role, id, text_buf[0..text_len]);
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
        slot.command_len = 0;
        slot.exit_code = null;
        slot.cancelled = false;
        slot.truncated = false;
        self.message_count += 1;
    }

    fn addMessage(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, role: types.Role, content: []const u8) !void {
        if (content.len > max_message_bytes) return error.MessageTooLarge;
        if (self.message_count >= max_messages) return error.MessageLimitReached;

        const entry_id = try self.store.appendMessage(io, allocator, role, content);
        try self.addLoadedMessage(StoredRole.fromBase(role), entry_id, content);
    }

    fn addLoadedBash(self: *Runtime, entry_id: []const u8, command: []const u8, result: tools.ShellResult) !void {
        if (command.len > max_command_bytes) return error.CommandTooLarge;
        if (result.output.len > max_message_bytes) return error.MessageTooLarge;
        if (entry_id.len > 32) return error.ValueTooLong;
        if (self.message_count >= max_messages) return error.MessageLimitReached;

        var slot = &self.messages[self.message_count];
        slot.role = .bash_execution;
        slot.id_len = entry_id.len;
        @memcpy(slot.id[0..entry_id.len], entry_id);
        slot.command_len = command.len;
        @memcpy(slot.command[0..command.len], command);
        slot.len = result.output.len;
        @memcpy(slot.content[0..result.output.len], result.output);
        slot.exit_code = result.exit_code;
        slot.cancelled = result.cancelled;
        slot.truncated = result.truncated;
        self.message_count += 1;
    }

    fn executeBash(self: *Runtime, io: std.Io, allocator: std.mem.Allocator, shell_command: []const u8) !tools.ShellResult {
        const result = try tools.runShellCapture(io, allocator, shell_command);
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
        try self.store.appendCompaction(io, allocator, summary, first_kept_entry_id, tokens_before, custom_instructions, self.message_count);

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

    fn sessionName(self: *const Runtime) ?[]const u8 {
        if (!self.has_session_name) return null;
        return self.session_name[0..self.session_name_len];
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
            self.addMessage(io, allocator, .user, message) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "steer")) {
            const message = getStringField(value, "message") orelse {
                return writeError(w, id, command, "steer requires a string message");
            };
            self.addMessage(io, allocator, .user, message) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "follow_up")) {
            const message = getStringField(value, "message") orelse {
                return writeError(w, id, command, "follow_up requires a string message");
            };
            self.addMessage(io, allocator, .user, message) catch |err| {
                return writeError(w, id, command, @errorName(err));
            };
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "abort")) {
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "bash")) {
            const shell_command = getStringField(value, "command") orelse {
                return writeError(w, id, command, "bash requires a string command");
            };
            const result = self.executeBash(io, allocator, shell_command) catch |err| {
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
            return writeSuccess(w, id, command);
        }

        if (std.mem.eql(u8, command, "abort_retry")) {
            self.auto_retry_enabled = false;
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
        try w.writeAll(",\"messageCount\":");
        try w.print("{d}", .{self.message_count});
        try w.writeAll(",\"pendingMessageCount\":0");
        if (self.sessionName()) |name| {
            try w.writeAll(",\"sessionName\":");
            try writeJsonString(w, name);
        }
        try w.writeAll("}}\n");
    }

    fn writeMessages(self: *Runtime, w: *std.Io.Writer, id: ?[]const u8, command: []const u8) !void {
        try writeResponseHead(w, id, command, true);
        try w.writeAll(",\"data\":{\"messages\":[");
        for (self.messages[0..self.message_count], 0..) |*message, i| {
            if (i != 0) try w.writeByte(',');
            try self.writeStoredMessage(w, message);
        }
        try w.writeAll("]}}\n");
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
        } else {
            try w.writeAll(",\"content\":");
            try writeJsonString(w, message.text());
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

pub fn run(io: std.Io, allocator: std.mem.Allocator, session_file: []const u8, command_options: commands.Options) !void {
    var runtime: Runtime = .{};
    try runtime.init(io, allocator, session_file, command_options);

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
    return null;
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

fn appendBoundedText(w: *std.Io.Writer, text: []const u8) !void {
    w.writeAll(text) catch return error.MessageTooLarge;
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
    var runtime: Runtime = .{};
    try runtime.init(std.testing.io, std.testing.allocator, "zig-out/pi-zig-rpc-test.jsonl", .{});
    try runtime.addMessage(std.testing.io, std.testing.allocator, .user, "hello");
    try std.testing.expectEqual(@as(usize, 1), runtime.message_count);
    try runtime.clearSession(std.testing.io, std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 0), runtime.message_count);
    try std.testing.expectEqual(@as(usize, 2), runtime.session_generation);
}

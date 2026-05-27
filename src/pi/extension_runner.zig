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

    pub const CommandExecutionResult = struct {
        handled: bool = false,
        actions: []CommandAction = &.{},

        pub fn deinit(self: CommandExecutionResult, allocator: std.mem.Allocator) void {
            for (self.actions) |action| action.deinit(allocator);
            if (self.actions.len > 0) allocator.free(self.actions);
        }
    };

    pub const CommandDelivery = enum {
        steer,
        follow_up,
        next_turn,
    };

    pub const CommandAction = union(enum) {
        send_user_message: CommandUserMessageAction,
        send_message: CommandCustomMessageAction,
        append_entry: CommandAppendEntryAction,

        pub fn deinit(self: CommandAction, allocator: std.mem.Allocator) void {
            switch (self) {
                .send_user_message => |message| message.deinit(allocator),
                .send_message => |message| message.deinit(allocator),
                .append_entry => |entry| entry.deinit(allocator),
            }
        }
    };

    pub const CommandUserMessageAction = struct {
        content: []u8,
        image_parts: []ai_client.ChatContentPart = &.{},
        deliver_as: ?CommandDelivery = null,

        pub fn deinit(self: CommandUserMessageAction, allocator: std.mem.Allocator) void {
            allocator.free(self.content);
            freeContentParts(allocator, self.image_parts);
        }
    };

    pub const CommandCustomMessageAction = struct {
        custom_type: []u8,
        content: []u8,
        display: bool = true,
        trigger_turn: bool = false,
        deliver_as: ?CommandDelivery = null,

        pub fn deinit(self: CommandCustomMessageAction, allocator: std.mem.Allocator) void {
            allocator.free(self.custom_type);
            allocator.free(self.content);
        }
    };

    pub const CommandAppendEntryAction = struct {
        custom_type: []u8,
        data_json: []u8,

        pub fn deinit(self: CommandAppendEntryAction, allocator: std.mem.Allocator) void {
            allocator.free(self.custom_type);
            allocator.free(self.data_json);
        }
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

    /// `unspecified` mirrors upstream extensions that call registerFlag without a `type`.
    /// Upstream treats such flags like string flags for value handling (see
    /// applyExtensionFlagValues in agent-session-services.ts) and like boolean flags for
    /// the help `<value>` hint (printHelp checks `flag.type === "string"`).
    pub const FlagType = enum { boolean, string, unspecified };

    pub const FlagDefinition = struct {
        name: []const u8,
        flag_type: FlagType = .unspecified,
        description: ?[]const u8 = null,
        /// Default value serialized as JSON (e.g. "true", "false", "\"text\"") or null when none.
        default_json: ?[]const u8 = null,
        extension_path: []const u8,
    };

    /// Discover CLI flags registered by extensions. First registration per name wins,
    /// matching ExtensionRunner.getFlags() (upstream runner.ts).
    pub fn discoverFlagDefinitions(self: *Runner) ![]FlagDefinition {
        if (!self.hasExtensions()) return &.{};

        const payload = try self.buildDiscoverFlagsPayload();
        defer self.allocator.free(payload);
        const output = try self.runNodeHook(payload);
        defer if (output) |bytes| self.allocator.free(bytes);
        const bytes = output orelse return &.{};

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return error.ExtensionHookInvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.ExtensionHookInvalidResponse;
        const flags = parsed.value.object.get("flags") orelse return &.{};
        if (flags != .array) return error.ExtensionHookInvalidResponse;

        var definitions: std.ArrayList(FlagDefinition) = .empty;
        errdefer deinitFlagDefinitionList(self.allocator, &definitions);

        for (flags.array.items) |item| {
            if (item != .object) return error.ExtensionHookInvalidResponse;
            const name = item.object.get("name") orelse return error.ExtensionHookInvalidResponse;
            if (name != .string or name.string.len == 0) return error.ExtensionHookInvalidResponse;
            var flag_type: FlagType = .unspecified;
            if (item.object.get("type")) |type_value| {
                if (type_value != .null) {
                    if (type_value != .string) return error.ExtensionHookInvalidResponse;
                    if (std.mem.eql(u8, type_value.string, "boolean")) {
                        flag_type = .boolean;
                    } else if (std.mem.eql(u8, type_value.string, "string")) {
                        flag_type = .string;
                    } else {
                        return error.ExtensionHookInvalidResponse;
                    }
                }
            }
            const extension_path = item.object.get("extensionPath") orelse return error.ExtensionHookInvalidResponse;
            if (extension_path != .string) return error.ExtensionHookInvalidResponse;

            var description: ?[]const u8 = null;
            errdefer if (description) |value| self.allocator.free(value);
            if (item.object.get("description")) |value| {
                if (value != .null) {
                    if (value != .string) return error.ExtensionHookInvalidResponse;
                    description = try self.allocator.dupe(u8, value.string);
                }
            }

            var default_json: ?[]const u8 = null;
            errdefer if (default_json) |value| self.allocator.free(value);
            if (item.object.get("default")) |value| {
                if (value != .null) default_json = try jsonValueToOwnedString(self.allocator, value);
            }

            const owned_name = try self.allocator.dupe(u8, name.string);
            errdefer self.allocator.free(owned_name);
            const owned_path = try self.allocator.dupe(u8, extension_path.string);
            errdefer self.allocator.free(owned_path);
            try definitions.append(self.allocator, .{
                .name = owned_name,
                .flag_type = flag_type,
                .description = description,
                .default_json = default_json,
                .extension_path = owned_path,
            });
            description = null;
            default_json = null;
        }
        if (definitions.items.len == 0) return &.{};
        return definitions.toOwnedSlice(self.allocator);
    }

    pub fn deinitFlagDefinitions(self: *Runner, definitions: []FlagDefinition) void {
        for (definitions) |definition| {
            self.allocator.free(definition.name);
            if (definition.description) |value| self.allocator.free(value);
            if (definition.default_json) |value| self.allocator.free(value);
            self.allocator.free(definition.extension_path);
        }
        self.allocator.free(definitions);
    }

    pub const FlagValidationError = struct {
        name: []const u8,
        message: []const u8,

        pub fn deinit(self: FlagValidationError, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.message);
        }
    };

    /// Validate CLI-provided flag values against registered extension flag definitions.
    ///
    /// Mirrors upstream applyExtensionFlagValues (agent-session-services.ts):
    /// - A boolean flag accepts any presence and coerces to `true`; it never errors.
    /// - A string flag requires a value; a bare flag (no value) errors with
    ///   `Extension flag "--name" requires a value`.
    ///
    /// DIVERGENCE: upstream also routes flags registered without an explicit `type`
    /// through the string branch (so a bare untyped flag errors). pi-zig keeps untyped
    /// flags as passthrough — they are not value-validated — because pi-zig captures and
    /// forwards untyped flags to getFlag() rather than rejecting them, and example
    /// extensions register flags without a type. Flags unknown to every extension are
    /// likewise ignored (upstream reports `Unknown option`; pi-zig passes them through).
    /// Returns owned errors; empty slice when all provided flags pass.
    pub fn validateFlags(
        self: *Runner,
        definitions: []const FlagDefinition,
        provided: []const FlagValue,
    ) ![]FlagValidationError {
        var errors: std.ArrayList(FlagValidationError) = .empty;
        errdefer {
            for (errors.items) |err| err.deinit(self.allocator);
            errors.deinit(self.allocator);
        }
        for (provided) |flag| {
            const definition = findFlagDefinition(definitions, flag.name) orelse continue;
            switch (definition.flag_type) {
                .boolean, .unspecified => {},
                .string => {
                    if (flag.value == null) {
                        try appendFlagError(self.allocator, &errors, flag.name, "Extension flag \"--{s}\" requires a value");
                    }
                },
            }
        }
        if (errors.items.len == 0) return &.{};
        return errors.toOwnedSlice(self.allocator);
    }

    pub fn deinitFlagValidationErrors(self: *Runner, errors: []FlagValidationError) void {
        for (errors) |err| err.deinit(self.allocator);
        if (errors.len > 0) self.allocator.free(errors);
    }

    pub const LifecycleEvent = struct {
        type: []const u8,
        /// Optional extra fields merged into the emitted event object, serialized as a JSON object.
        fields_json: ?[]const u8 = null,
    };

    pub const LifecycleResult = struct {
        /// Per-event observable markers returned by the extension handler (JSON-encoded), in order.
        observations: [][]u8 = &.{},
        /// Actions accumulated across the whole sequence (sendUserMessage/sendMessage/appendEntry).
        actions: []CommandAction = &.{},

        pub fn deinit(self: LifecycleResult, allocator: std.mem.Allocator) void {
            for (self.observations) |observation| allocator.free(observation);
            if (self.observations.len > 0) allocator.free(self.observations);
            for (self.actions) |action| action.deinit(allocator);
            if (self.actions.len > 0) allocator.free(self.actions);
        }
    };

    /// Drive a sequence of lifecycle events through a single long-lived runner process.
    ///
    /// Extensions are loaded once and the same module instances handle every event in the
    /// sequence, so module-level state persists across events exactly as it does in the
    /// upstream long-lived ExtensionRunner. Each handler may return a value which is
    /// captured per-event as an observation, and queued actions accumulate across events.
    pub fn runLifecycleSequence(self: *Runner, events: []const LifecycleEvent) !LifecycleResult {
        if (!self.hasExtensions()) return .{};

        const payload = try self.buildLifecycleSequencePayload(events);
        defer self.allocator.free(payload);
        const output = try self.runNodeHook(payload);
        defer if (output) |bytes| self.allocator.free(bytes);
        const bytes = output orelse return .{};

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return error.ExtensionHookInvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.ExtensionHookInvalidResponse;

        var observations: std.ArrayList([]u8) = .empty;
        errdefer {
            for (observations.items) |observation| self.allocator.free(observation);
            observations.deinit(self.allocator);
        }
        if (parsed.value.object.get("observations")) |observations_value| {
            if (observations_value != .array) return error.ExtensionHookInvalidResponse;
            for (observations_value.array.items) |observation| {
                try observations.append(self.allocator, try jsonValueToOwnedString(self.allocator, observation));
            }
        }

        var actions: []CommandAction = &.{};
        errdefer {
            for (actions) |action| action.deinit(self.allocator);
            if (actions.len > 0) self.allocator.free(actions);
        }
        if (parsed.value.object.get("actions")) |action_value| {
            actions = try commandActionsToOwned(self.allocator, action_value);
        }

        return .{
            .observations = try observations.toOwnedSlice(self.allocator),
            .actions = actions,
        };
    }

    pub fn runRegisteredCommand(self: *Runner, command_name: []const u8, args: []const u8) !CommandExecutionResult {
        if (!self.hasExtensions()) return .{};

        const payload = try self.buildExecuteCommandPayload(command_name, args);
        defer self.allocator.free(payload);
        const output = try self.runNodeHook(payload);
        defer if (output) |bytes| self.allocator.free(bytes);
        const bytes = output orelse return .{};

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return error.ExtensionHookInvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.ExtensionHookInvalidResponse;
        const handled = parsed.value.object.get("handled") orelse return error.ExtensionHookInvalidResponse;
        if (handled != .bool) return error.ExtensionHookInvalidResponse;
        var actions: []CommandAction = &.{};
        errdefer {
            for (actions) |action| action.deinit(self.allocator);
            if (actions.len > 0) self.allocator.free(actions);
        }
        if (handled.bool) {
            if (parsed.value.object.get("actions")) |action_value| {
                actions = try commandActionsToOwned(self.allocator, action_value);
            }
        }
        return .{ .handled = handled.bool, .actions = actions };
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

    fn buildDiscoverFlagsPayload(self: *Runner) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try self.writePayloadHead(w);
        try w.writeAll(",\"event\":{\"type\":\"discover_flags\"}}");
        return out.toOwnedSlice();
    }

    fn buildLifecycleSequencePayload(self: *Runner, events: []const LifecycleEvent) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try self.writePayloadHead(w);
        try w.writeAll(",\"event\":{\"type\":\"lifecycle_sequence\",\"events\":[");
        for (events, 0..) |event, index| {
            if (index != 0) try w.writeByte(',');
            try w.writeAll("{\"type\":");
            try writeJsonString(w, event.type);
            if (event.fields_json) |fields| {
                try w.writeAll(",\"fields\":");
                try writeJsonObjectOrEmpty(self.allocator, w, fields);
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}}");
        return out.toOwnedSlice();
    }

    fn buildExecuteCommandPayload(self: *Runner, command_name: []const u8, args: []const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try self.writePayloadHead(w);
        try w.writeAll(",\"event\":{\"type\":\"execute_command\",\"commandName\":");
        try writeJsonString(w, command_name);
        try w.writeAll(",\"args\":");
        try writeJsonString(w, args);
        try w.writeAll("}}");
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

fn imageContentPartsToOwned(allocator: std.mem.Allocator, content: std.json.Value) ![]ai_client.ChatContentPart {
    const parts = try contentPartsToOwned(allocator, content);
    if (parts.len == 0) return &.{};

    var image_count: usize = 0;
    for (parts) |part| {
        if (part == .image) image_count += 1;
    }
    if (image_count == 0) {
        freeContentParts(allocator, parts);
        return &.{};
    }

    const images = try allocator.alloc(ai_client.ChatContentPart, image_count);
    var index: usize = 0;
    for (parts) |part| {
        switch (part) {
            .text => |text| allocator.free(text),
            .image => |image| {
                images[index] = .{ .image = image };
                index += 1;
            },
        }
    }
    allocator.free(parts);
    return images;
}

fn commandActionsToOwned(allocator: std.mem.Allocator, value: std.json.Value) ![]Runner.CommandAction {
    if (value != .array) return error.ExtensionHookInvalidResponse;
    if (value.array.items.len == 0) return &.{};

    var actions: std.ArrayList(Runner.CommandAction) = .empty;
    errdefer {
        for (actions.items) |action| action.deinit(allocator);
        actions.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .object) return error.ExtensionHookInvalidResponse;
        const kind = item.object.get("type") orelse return error.ExtensionHookInvalidResponse;
        if (kind != .string) return error.ExtensionHookInvalidResponse;
        if (std.mem.eql(u8, kind.string, "send_user_message")) {
            const content = item.object.get("content") orelse return error.ExtensionHookInvalidResponse;
            var image_parts: []ai_client.ChatContentPart = &.{};
            errdefer freeContentParts(allocator, image_parts);
            const owned_content = switch (content) {
                .string => try allocator.dupe(u8, content.string),
                .array => blk: {
                    image_parts = try imageContentPartsToOwned(allocator, content);
                    break :blk try textContentToOwnedString(allocator, content);
                },
                else => return error.ExtensionHookInvalidResponse,
            };
            var deliver_as: ?Runner.CommandDelivery = null;
            if (item.object.get("options")) |options| {
                if (options != .object) return error.ExtensionHookInvalidResponse;
                if (options.object.get("deliverAs")) |deliver_value| {
                    deliver_as = try parseCommandDelivery(deliver_value, false);
                }
            }
            actions.append(allocator, .{ .send_user_message = .{
                .content = owned_content,
                .image_parts = image_parts,
                .deliver_as = deliver_as,
            } }) catch |err| {
                allocator.free(owned_content);
                return err;
            };
            image_parts = &.{};
        } else if (std.mem.eql(u8, kind.string, "send_message")) {
            const message = item.object.get("message") orelse return error.ExtensionHookInvalidResponse;
            if (message != .object) return error.ExtensionHookInvalidResponse;
            const custom_type = message.object.get("customType") orelse return error.ExtensionHookInvalidResponse;
            if (custom_type != .string or custom_type.string.len == 0) return error.ExtensionHookInvalidResponse;
            const content = message.object.get("content") orelse return error.ExtensionHookInvalidResponse;
            const owned_content = switch (content) {
                .string => try allocator.dupe(u8, content.string),
                .array => try textContentToOwnedString(allocator, content),
                else => return error.ExtensionHookInvalidResponse,
            };
            const owned_custom_type = try allocator.dupe(u8, custom_type.string);
            var appended = false;
            errdefer if (!appended) {
                allocator.free(owned_content);
                allocator.free(owned_custom_type);
            };
            var display = true;
            if (message.object.get("display")) |display_value| {
                if (display_value != .bool) return error.ExtensionHookInvalidResponse;
                display = display_value.bool;
            }
            var trigger_turn = false;
            var deliver_as: ?Runner.CommandDelivery = null;
            if (item.object.get("options")) |options| {
                if (options != .object) return error.ExtensionHookInvalidResponse;
                if (options.object.get("triggerTurn")) |trigger_value| {
                    if (trigger_value != .bool) return error.ExtensionHookInvalidResponse;
                    trigger_turn = trigger_value.bool;
                }
                if (options.object.get("deliverAs")) |deliver_value| {
                    deliver_as = try parseCommandDelivery(deliver_value, true);
                }
            }
            actions.append(allocator, .{ .send_message = .{
                .custom_type = owned_custom_type,
                .content = owned_content,
                .display = display,
                .trigger_turn = trigger_turn,
                .deliver_as = deliver_as,
            } }) catch |err| {
                allocator.free(owned_content);
                allocator.free(owned_custom_type);
                return err;
            };
            appended = true;
        } else if (std.mem.eql(u8, kind.string, "append_entry")) {
            const custom_type = item.object.get("customType") orelse return error.ExtensionHookInvalidResponse;
            if (custom_type != .string or custom_type.string.len == 0) return error.ExtensionHookInvalidResponse;
            const owned_custom_type = try allocator.dupe(u8, custom_type.string);
            var appended = false;
            errdefer if (!appended) allocator.free(owned_custom_type);
            const owned_data_json = if (item.object.get("data")) |data|
                try jsonValueToOwnedString(allocator, data)
            else
                try allocator.dupe(u8, "null");
            errdefer if (!appended) allocator.free(owned_data_json);
            try actions.append(allocator, .{ .append_entry = .{
                .custom_type = owned_custom_type,
                .data_json = owned_data_json,
            } });
            appended = true;
        } else {
            return error.ExtensionHookInvalidResponse;
        }
    }
    if (actions.items.len == 0) return &.{};
    return actions.toOwnedSlice(allocator);
}

fn parseCommandDelivery(value: std.json.Value, allow_next_turn: bool) !Runner.CommandDelivery {
    if (value != .string) return error.ExtensionHookInvalidResponse;
    if (std.mem.eql(u8, value.string, "steer")) return .steer;
    if (std.mem.eql(u8, value.string, "followUp")) return .follow_up;
    if (std.mem.eql(u8, value.string, "nextTurn") and allow_next_turn) return .next_turn;
    return error.ExtensionHookInvalidResponse;
}

fn findFlagDefinition(definitions: []const Runner.FlagDefinition, name: []const u8) ?Runner.FlagDefinition {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return definition;
    }
    return null;
}

fn appendFlagError(
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(Runner.FlagValidationError),
    name: []const u8,
    comptime template: []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const message = try std.fmt.allocPrint(allocator, template, .{name});
    errdefer allocator.free(message);
    try errors.append(allocator, .{ .name = owned_name, .message = message });
}

fn deinitFlagDefinitionList(allocator: std.mem.Allocator, definitions: *std.ArrayList(Runner.FlagDefinition)) void {
    for (definitions.items) |definition| {
        allocator.free(definition.name);
        if (definition.description) |value| allocator.free(value);
        if (definition.default_json) |value| allocator.free(value);
        allocator.free(definition.extension_path);
    }
    definitions.deinit(allocator);
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
    \\const actions = [];
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
    \\    for (const entry of extensionFlagMaps) {
    \\      const flag = entry.flags.get(name);
    \\      if (!flag) continue;
    \\      if (Object.prototype.hasOwnProperty.call(flag, "default")) return flag.default;
    \\      if (Object.prototype.hasOwnProperty.call(flag, "defaultValue")) return flag.defaultValue;
    \\    }
    \\    return undefined;
    \\  },
    \\  sendUserMessage(content, options = {}) {
    \\    actions.push({ type: "send_user_message", content, options });
    \\  },
    \\  sendMessage(message, options = {}) {
    \\    actions.push({ type: "send_message", message, options });
    \\  },
    \\  appendEntry(customType, data) {
    \\    actions.push({ type: "append_entry", customType, data });
    \\  },
    \\  events: { on() {}, emit() {} },
    \\};
    \\const ctx = {
    \\  hasUI: false,
    \\  ui: {
    \\    notify() {},
    \\    select: async (_message, options) => Array.isArray(options) ? options[0] : undefined,
    \\    input: async () => undefined,
    \\    prompt: async () => undefined,
    \\    confirm: async () => false,
    \\  },
    \\  diagnostics,
    \\};
    \\function createCommandContext() {
    \\  return {
    \\    ...ctx,
    \\    waitForIdle: async () => {},
    \\    newSession: async () => ({ cancelled: true }),
    \\    fork: async () => ({ cancelled: true }),
    \\    navigateTree: async () => ({ cancelled: true }),
    \\    switchSession: async () => ({ cancelled: true }),
    \\    reload: async () => {},
    \\  };
    \\}
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
    \\  extensionFlagMaps.push({ extensionPath: extensionPath, flags: flagMap });
    \\}
    \\function allRegisteredFlags() {
    \\  const flagsByName = new Map();
    \\  for (const entry of extensionFlagMaps) {
    \\    for (const flag of entry.flags.values()) {
    \\      if (flagsByName.has(flag.name)) continue;
    \\      const out = { name: String(flag.name), extensionPath: entry.extensionPath };
    \\      if (flag.type === "boolean" || flag.type === "string") out.type = flag.type;
    \\      if (flag.description !== undefined && flag.description !== null) out.description = String(flag.description);
    \\      if (Object.prototype.hasOwnProperty.call(flag, "default") && flag.default !== undefined) out.default = flag.default;
    \\      else if (Object.prototype.hasOwnProperty.call(flag, "defaultValue") && flag.defaultValue !== undefined) out.default = flag.defaultValue;
    \\      flagsByName.set(flag.name, out);
    \\    }
    \\  }
    \\  return Array.from(flagsByName.values());
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
    \\  if (event?.type === "discover_flags") {
    \\    process.stdout.write(JSON.stringify({ flags: allRegisteredFlags() }) + "\n");
    \\    return;
    \\  }
    \\  if (event?.type === "lifecycle_sequence") {
    \\    const observations = [];
    \\    for (const step of event.events || []) {
    \\      const lifecycleEvent = { type: String(step?.type ?? ""), ...(step?.fields && typeof step.fields === "object" ? step.fields : {}) };
    \\      const stepHandlers = handlers.get(lifecycleEvent.type) || [];
    \\      let observation = null;
    \\      for (const handler of stepHandlers) {
    \\        try {
    \\          const result = await handler(lifecycleEvent, ctx);
    \\          if (result !== undefined && result !== null) observation = result;
    \\        } catch (err) {
    \\          diagnostics.push({ extensionPath: `lifecycle:${lifecycleEvent.type}`, event: lifecycleEvent.type, error: err && err.message ? err.message : String(err) });
    \\        }
    \\      }
    \\      observations.push(observation);
    \\    }
    \\    process.stdout.write(JSON.stringify({ observations, actions, diagnostics }) + "\n");
    \\    return;
    \\  }
    \\  if (event?.type === "execute_command") {
    \\    const commandName = String(event.commandName ?? "");
    \\    const command = allRegisteredCommands().find((candidate) => candidate.invocationName === commandName);
    \\    if (!command) {
    \\      process.stdout.write(JSON.stringify({ handled: false }) + "\n");
    \\      return;
    \\    }
    \\    try {
    \\      if (typeof command.handler !== "function") throw new Error(`Extension command has no handler: ${commandName}`);
    \\      await command.handler(String(event.args ?? ""), createCommandContext());
    \\    } catch (err) {
    \\      diagnostics.push({
    \\        extensionPath: `command:${commandName}`,
    \\        event: "command",
    \\        error: err && err.message ? err.message : String(err),
    \\        stack: err && err.stack ? err.stack : undefined,
    \\      });
    \\    }
    \\    process.stdout.write(JSON.stringify({ handled: true, actions, diagnostics }) + "\n");
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

test "extension runner executes registered commands by invocation name" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-command-exec-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/command.mjs";
    const marker_path = fixture_dir ++ "/marker.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\import fs from "node:fs";
        \\
        \\export default function(pi) {
        \\  pi.registerCommand("write-marker", {
        \\    description: "Write command args to a marker file",
        \\    handler: async (args, ctx) => {
        \\      await ctx.waitForIdle();
        \\      fs.writeFileSync("zig-out/pi-zig-extension-runner-command-exec-test/marker.txt", `${args}|hasUI:${ctx.hasUI}`);
        \\    }
        \\  });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    const result = try runner.runRegisteredCommand("write-marker", "hello world");
    try std.testing.expect(result.handled);

    const marker = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, marker_path, allocator, .limited(1024));
    defer allocator.free(marker);
    try std.testing.expectEqualStrings("hello world|hasUI:false", marker);

    const missing = try runner.runRegisteredCommand("missing-command", "ignored");
    try std.testing.expect(!missing.handled);
}

test "extension runner returns send user message command actions" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-command-action-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/command-action.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\export default function(pi) {
        \\  pi.registerCommand("send-user", {
        \\    description: "Send a raw user message",
        \\    handler: async (args) => {
        \\      await pi.sendUserMessage(args);
        \\    }
        \\  });
        \\  pi.registerCommand("send-user-image", {
        \\    description: "Send raw user text with an image",
        \\    handler: async (args) => {
        \\      await pi.sendUserMessage([
        \\        { type: "text", text: args },
        \\        { type: "image", data: "aW1hZ2Utc21va2U=", mimeType: "image/png" }
        \\      ]);
        \\    }
        \\  });
        \\  pi.registerCommand("send-user-steer", {
        \\    description: "Queue a raw steering message",
        \\    handler: async (args) => {
        \\      await pi.sendUserMessage(args, { deliverAs: "steer" });
        \\    }
        \\  });
        \\  pi.registerCommand("send-user-follow", {
        \\    description: "Queue a raw follow-up message",
        \\    handler: async (args) => {
        \\      await pi.sendUserMessage(args, { deliverAs: "followUp" });
        \\    }
        \\  });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    const result = try runner.runRegisteredCommand("send-user", "/write-marker raw user");
    defer result.deinit(allocator);
    try std.testing.expect(result.handled);
    try std.testing.expectEqual(@as(usize, 1), result.actions.len);
    switch (result.actions[0]) {
        .send_user_message => |message| {
            try std.testing.expectEqualStrings("/write-marker raw user", message.content);
            try std.testing.expectEqual(@as(usize, 0), message.image_parts.len);
            try std.testing.expect(message.deliver_as == null);
        },
        else => return error.UnexpectedCommandAction,
    }

    const image_result = try runner.runRegisteredCommand("send-user-image", "raw user image");
    defer image_result.deinit(allocator);
    try std.testing.expect(image_result.handled);
    try std.testing.expectEqual(@as(usize, 1), image_result.actions.len);
    switch (image_result.actions[0]) {
        .send_user_message => |message| {
            try std.testing.expectEqualStrings("raw user image", message.content);
            try std.testing.expectEqual(@as(usize, 1), message.image_parts.len);
            switch (message.image_parts[0]) {
                .image => |image| {
                    try std.testing.expectEqualStrings("aW1hZ2Utc21va2U=", image.data);
                    try std.testing.expectEqualStrings("image/png", image.mime_type);
                },
                else => return error.UnexpectedCommandAction,
            }
            try std.testing.expect(message.deliver_as == null);
        },
        else => return error.UnexpectedCommandAction,
    }

    const steer_result = try runner.runRegisteredCommand("send-user-steer", "queued steer");
    defer steer_result.deinit(allocator);
    try std.testing.expect(steer_result.handled);
    try std.testing.expectEqual(@as(usize, 1), steer_result.actions.len);
    switch (steer_result.actions[0]) {
        .send_user_message => |message| {
            try std.testing.expectEqualStrings("queued steer", message.content);
            try std.testing.expect(message.deliver_as.? == .steer);
        },
        else => return error.UnexpectedCommandAction,
    }

    const follow_result = try runner.runRegisteredCommand("send-user-follow", "queued follow");
    defer follow_result.deinit(allocator);
    try std.testing.expect(follow_result.handled);
    try std.testing.expectEqual(@as(usize, 1), follow_result.actions.len);
    switch (follow_result.actions[0]) {
        .send_user_message => |message| {
            try std.testing.expectEqualStrings("queued follow", message.content);
            try std.testing.expect(message.deliver_as.? == .follow_up);
        },
        else => return error.UnexpectedCommandAction,
    }
}

test "extension runner returns send custom message command actions" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-command-custom-message-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/command-custom-message.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\export default function(pi) {
        \\  pi.registerCommand("send-custom", {
        \\    description: "Send a custom message",
        \\    handler: async (args) => {
        \\      await pi.sendMessage({ customType: "test-extension", content: args, display: false });
        \\    }
        \\  });
        \\  pi.registerCommand("trigger-custom", {
        \\    description: "Send a custom message and trigger a turn",
        \\    handler: async (args) => {
        \\      await pi.sendMessage({ customType: "test-extension", content: args, display: true }, { triggerTurn: true });
        \\    }
        \\  });
        \\  pi.registerCommand("next-turn-custom", {
        \\    description: "Queue a custom message for the next turn",
        \\    handler: async (args) => {
        \\      await pi.sendMessage({ customType: "test-extension", content: args, display: true }, { deliverAs: "nextTurn" });
        \\    }
        \\  });
        \\  pi.registerCommand("steer-custom", {
        \\    description: "Queue a custom steering message",
        \\    handler: async (args) => {
        \\      await pi.sendMessage({ customType: "test-extension", content: args, display: true }, { deliverAs: "steer" });
        \\    }
        \\  });
        \\  pi.registerCommand("follow-custom", {
        \\    description: "Queue a custom follow-up message",
        \\    handler: async (args) => {
        \\      await pi.sendMessage({ customType: "test-extension", content: args, display: true }, { deliverAs: "followUp" });
        \\    }
        \\  });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    const result = try runner.runRegisteredCommand("send-custom", "custom note");
    defer result.deinit(allocator);
    try std.testing.expect(result.handled);
    try std.testing.expectEqual(@as(usize, 1), result.actions.len);
    switch (result.actions[0]) {
        .send_message => |message| {
            try std.testing.expectEqualStrings("test-extension", message.custom_type);
            try std.testing.expectEqualStrings("custom note", message.content);
            try std.testing.expect(!message.display);
            try std.testing.expect(!message.trigger_turn);
            try std.testing.expect(message.deliver_as == null);
        },
        else => return error.UnexpectedCommandAction,
    }

    const trigger_result = try runner.runRegisteredCommand("trigger-custom", "custom prompt");
    defer trigger_result.deinit(allocator);
    try std.testing.expect(trigger_result.handled);
    try std.testing.expectEqual(@as(usize, 1), trigger_result.actions.len);
    switch (trigger_result.actions[0]) {
        .send_message => |message| {
            try std.testing.expectEqualStrings("test-extension", message.custom_type);
            try std.testing.expectEqualStrings("custom prompt", message.content);
            try std.testing.expect(message.display);
            try std.testing.expect(message.trigger_turn);
            try std.testing.expect(message.deliver_as == null);
        },
        else => return error.UnexpectedCommandAction,
    }

    const next_turn_result = try runner.runRegisteredCommand("next-turn-custom", "queued custom");
    defer next_turn_result.deinit(allocator);
    try std.testing.expect(next_turn_result.handled);
    try std.testing.expectEqual(@as(usize, 1), next_turn_result.actions.len);
    switch (next_turn_result.actions[0]) {
        .send_message => |message| {
            try std.testing.expectEqualStrings("test-extension", message.custom_type);
            try std.testing.expectEqualStrings("queued custom", message.content);
            try std.testing.expect(message.display);
            try std.testing.expect(!message.trigger_turn);
            try std.testing.expect(message.deliver_as.? == .next_turn);
        },
        else => return error.UnexpectedCommandAction,
    }

    const steer_result = try runner.runRegisteredCommand("steer-custom", "custom steer");
    defer steer_result.deinit(allocator);
    try std.testing.expect(steer_result.handled);
    try std.testing.expectEqual(@as(usize, 1), steer_result.actions.len);
    switch (steer_result.actions[0]) {
        .send_message => |message| {
            try std.testing.expectEqualStrings("test-extension", message.custom_type);
            try std.testing.expectEqualStrings("custom steer", message.content);
            try std.testing.expect(message.deliver_as.? == .steer);
        },
        else => return error.UnexpectedCommandAction,
    }

    const follow_result = try runner.runRegisteredCommand("follow-custom", "custom follow");
    defer follow_result.deinit(allocator);
    try std.testing.expect(follow_result.handled);
    try std.testing.expectEqual(@as(usize, 1), follow_result.actions.len);
    switch (follow_result.actions[0]) {
        .send_message => |message| {
            try std.testing.expectEqualStrings("test-extension", message.custom_type);
            try std.testing.expectEqualStrings("custom follow", message.content);
            try std.testing.expect(message.deliver_as.? == .follow_up);
        },
        else => return error.UnexpectedCommandAction,
    }
}

test "extension runner returns append entry command actions" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-command-append-entry-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/command-append-entry.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\export default function(pi) {
        \\  pi.registerCommand("append-state", {
        \\    description: "Append custom extension state",
        \\    handler: async (args) => {
        \\      await pi.appendEntry("state-entry", { args, nested: { ok: true }, items: [1, "two"] });
        \\    }
        \\  });
        \\  pi.registerCommand("append-empty", {
        \\    description: "Append custom extension state without data",
        \\    handler: async () => {
        \\      await pi.appendEntry("empty-entry");
        \\    }
        \\  });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    const result = try runner.runRegisteredCommand("append-state", "persist me");
    defer result.deinit(allocator);
    try std.testing.expect(result.handled);
    try std.testing.expectEqual(@as(usize, 1), result.actions.len);
    switch (result.actions[0]) {
        .append_entry => |entry| {
            try std.testing.expectEqualStrings("state-entry", entry.custom_type);
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.data_json, .{});
            defer parsed.deinit();
            try std.testing.expect(parsed.value == .object);
            const args = parsed.value.object.get("args") orelse return error.MissingAppendEntryArgs;
            try std.testing.expect(args == .string);
            try std.testing.expectEqualStrings("persist me", args.string);
            const nested = parsed.value.object.get("nested") orelse return error.MissingAppendEntryNested;
            try std.testing.expect(nested == .object);
            const ok = nested.object.get("ok") orelse return error.MissingAppendEntryOk;
            try std.testing.expect(ok == .bool);
            try std.testing.expect(ok.bool);
            const items = parsed.value.object.get("items") orelse return error.MissingAppendEntryItems;
            try std.testing.expect(items == .array);
            try std.testing.expectEqual(@as(usize, 2), items.array.items.len);
        },
        else => return error.UnexpectedCommandAction,
    }

    const empty_result = try runner.runRegisteredCommand("append-empty", "");
    defer empty_result.deinit(allocator);
    try std.testing.expect(empty_result.handled);
    try std.testing.expectEqual(@as(usize, 1), empty_result.actions.len);
    switch (empty_result.actions[0]) {
        .append_entry => |entry| {
            try std.testing.expectEqualStrings("empty-entry", entry.custom_type);
            try std.testing.expectEqualStrings("null", entry.data_json);
        },
        else => return error.UnexpectedCommandAction,
    }
}

test "extension runner executes duplicate registered commands by suffix" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-command-exec-duplicate-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const first_path = fixture_dir ++ "/a-first.mjs";
    const second_path = fixture_dir ++ "/b-second.mjs";
    const marker_path = fixture_dir ++ "/marker.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = first_path, .data =
        \\import fs from "node:fs";
        \\
        \\export default function(pi) {
        \\  pi.registerCommand("deploy", {
        \\    description: "first deploy",
        \\    handler: async (args) => fs.writeFileSync("zig-out/pi-zig-extension-runner-command-exec-duplicate-test/marker.txt", `first:${args}`)
        \\  });
        \\}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = second_path, .data =
        \\import fs from "node:fs";
        \\
        \\export default function(pi) {
        \\  pi.registerCommand("deploy", {
        \\    description: "second deploy",
        \\    handler: async (args) => fs.writeFileSync("zig-out/pi-zig-extension-runner-command-exec-duplicate-test/marker.txt", `second:${args}`)
        \\  });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{ first_path, second_path } };
    try std.testing.expect((try runner.runRegisteredCommand("deploy:1", "one")).handled);
    const marker = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, marker_path, allocator, .limited(1024));
    defer allocator.free(marker);
    try std.testing.expectEqualStrings("first:one", marker);

    try std.testing.expect((try runner.runRegisteredCommand("deploy:2", "two")).handled);
    const marker_second = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, marker_path, allocator, .limited(1024));
    defer allocator.free(marker_second);
    try std.testing.expectEqualStrings("second:two", marker_second);
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

test "extension runner discovers registered flag definitions with first-wins precedence" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-flag-discovery-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const first_path = fixture_dir ++ "/a-first.mjs";
    const second_path = fixture_dir ++ "/b-second.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = first_path, .data =
        \\export default function(pi) {
        \\  pi.registerFlag("mode", { description: "Pick a mode", type: "string", default: "fast" });
        \\  pi.registerFlag("verbose", { description: "Verbose logging", type: "boolean", default: false });
        \\}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = second_path, .data =
        \\export default function(pi) {
        \\  pi.registerFlag("mode", { description: "Second mode flag", type: "string" });
        \\  pi.registerFlag("trace", { type: "boolean" });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{ first_path, second_path } };
    const definitions = try runner.discoverFlagDefinitions();
    defer runner.deinitFlagDefinitions(definitions);
    try std.testing.expectEqual(@as(usize, 3), definitions.len);

    const mode = findFlagDefinition(definitions, "mode").?;
    try std.testing.expect(mode.flag_type == .string);
    try std.testing.expectEqualStrings("Pick a mode", mode.description.?);
    try std.testing.expectEqualStrings("\"fast\"", mode.default_json.?);
    try std.testing.expectEqualStrings(first_path, mode.extension_path);

    const verbose = findFlagDefinition(definitions, "verbose").?;
    try std.testing.expect(verbose.flag_type == .boolean);
    try std.testing.expectEqualStrings("false", verbose.default_json.?);

    const trace = findFlagDefinition(definitions, "trace").?;
    try std.testing.expect(trace.flag_type == .boolean);
    try std.testing.expect(trace.description == null);
    try std.testing.expect(trace.default_json == null);
}

test "extension runner validates flag values against registered types" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-flag-validation-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/flags.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\export default function(pi) {
        \\  pi.registerFlag("mode", { type: "string" });
        \\  pi.registerFlag("verbose", { type: "boolean" });
        \\  pi.registerFlag("untyped", {});
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    const definitions = try runner.discoverFlagDefinitions();
    defer runner.deinitFlagDefinitions(definitions);
    try std.testing.expect(findFlagDefinition(definitions, "untyped").?.flag_type == .unspecified);

    // Valid (matches upstream applyExtensionFlagValues):
    // - string flag with value
    // - boolean flag bare (coerced to true, never errors)
    // - boolean flag given a value (coerced to true, never errors)
    // - untyped flag bare (pi-zig passthrough, not validated)
    // - unknown flag ignored (pi-zig passthrough)
    const valid = [_]Runner.FlagValue{
        .{ .name = "mode", .value = "plan" },
        .{ .name = "verbose", .value = null },
        .{ .name = "verbose", .value = "loud" },
        .{ .name = "untyped", .value = null },
        .{ .name = "trace", .value = "anything" },
    };
    const valid_errors = try runner.validateFlags(definitions, &valid);
    defer runner.deinitFlagValidationErrors(valid_errors);
    try std.testing.expectEqual(@as(usize, 0), valid_errors.len);

    // Invalid: an explicitly typed string flag given no value.
    const invalid = [_]Runner.FlagValue{.{ .name = "mode", .value = null }};
    const invalid_errors = try runner.validateFlags(definitions, &invalid);
    defer runner.deinitFlagValidationErrors(invalid_errors);
    try std.testing.expectEqual(@as(usize, 1), invalid_errors.len);
    try std.testing.expectEqualStrings("mode", invalid_errors[0].name);
    try std.testing.expectEqualStrings("Extension flag \"--mode\" requires a value", invalid_errors[0].message);
}

test "extension runner keeps long-lived state across a lifecycle sequence" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-lifecycle-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/lifecycle.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\let startCount = 0;
        \\let turns = 0;
        \\export default function(pi) {
        \\  pi.on("session_start", (event) => {
        \\    startCount++;
        \\    pi.appendEntry("start-state", { count: startCount, reason: event.reason });
        \\    return { startCount, reason: event.reason };
        \\  });
        \\  pi.on("turn_start", (event) => {
        \\    turns++;
        \\    return { turnIndex: event.turnIndex, turns, startCount };
        \\  });
        \\  pi.on("session_shutdown", (event) => {
        \\    return { shuttingDown: true, totalStarts: startCount, totalTurns: turns, reason: event.reason };
        \\  });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    const events = [_]Runner.LifecycleEvent{
        .{ .type = "session_start", .fields_json = "{\"reason\":\"startup\"}" },
        .{ .type = "turn_start", .fields_json = "{\"turnIndex\":0,\"timestamp\":1}" },
        .{ .type = "turn_start", .fields_json = "{\"turnIndex\":1,\"timestamp\":2}" },
        .{ .type = "session_shutdown", .fields_json = "{\"reason\":\"quit\"}" },
    };
    const result = try runner.runLifecycleSequence(&events);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), result.observations.len);

    var start_obs = try std.json.parseFromSlice(std.json.Value, allocator, result.observations[0], .{});
    defer start_obs.deinit();
    try std.testing.expectEqual(@as(i64, 1), start_obs.value.object.get("startCount").?.integer);

    var turn0 = try std.json.parseFromSlice(std.json.Value, allocator, result.observations[1], .{});
    defer turn0.deinit();
    try std.testing.expectEqual(@as(i64, 1), turn0.value.object.get("turns").?.integer);

    var turn1 = try std.json.parseFromSlice(std.json.Value, allocator, result.observations[2], .{});
    defer turn1.deinit();
    // Second turn observes accumulated state from the same long-lived module instance.
    try std.testing.expectEqual(@as(i64, 2), turn1.value.object.get("turns").?.integer);
    try std.testing.expectEqual(@as(i64, 1), turn1.value.object.get("startCount").?.integer);

    var shutdown_obs = try std.json.parseFromSlice(std.json.Value, allocator, result.observations[3], .{});
    defer shutdown_obs.deinit();
    try std.testing.expectEqual(@as(i64, 2), shutdown_obs.value.object.get("totalTurns").?.integer);
    try std.testing.expect(shutdown_obs.value.object.get("shuttingDown").?.bool);

    // The session_start handler queued a persistent appendEntry action.
    try std.testing.expectEqual(@as(usize, 1), result.actions.len);
    switch (result.actions[0]) {
        .append_entry => |entry| {
            try std.testing.expectEqualStrings("start-state", entry.custom_type);
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.data_json, .{});
            defer parsed.deinit();
            try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("count").?.integer);
        },
        else => return error.UnexpectedCommandAction,
    }
}

const std = @import("std");
const agent = @import("agent.zig");
const ai_client = @import("ai_client.zig");

const max_hook_payload_bytes = 1024 * 1024;
const max_hook_output_bytes = 1024 * 1024;

/// A long-lived `node --persistent` child that imports the extension set once and
/// services many newline-delimited JSON payloads over stdin, replying one line per
/// payload over stdout. Reusing the same process across separate Runner calls is
/// what makes extension module-local state persist (upstream's long-lived
/// ExtensionRunner behavior), instead of resetting on every spawn.
///
/// The owner (e.g. the RPC Runtime) is responsible for keeping this alive across
/// commands and calling `deinit` when the session ends. A Runner with `.persistent`
/// set routes every hook through this process; a Runner without it keeps the
/// one-shot spawn path used by the CLI and unit tests.
pub const PersistentProcess = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Extension set this process was started for. The owner must only reuse the
    /// process for a Runner whose extension_paths match (same load set), otherwise
    /// it must be torn down and restarted.
    extension_paths_signature: []u8,
    child: std.process.Child,
    stdin_writer: std.Io.File.Writer,
    stdout_reader: std.Io.File.Reader,
    stdin_buffer: []u8,
    stdout_buffer: []u8,
    /// Serializes request/response exchanges. The RPC Runtime runs the prompt
    /// worker on its own thread while the main thread may dispatch extension
    /// commands; both can reach the same process, so one exchange completes its
    /// full write+read before another begins.
    exchange_mutex: std.atomic.Mutex = .unlocked,

    /// Spawn the persistent node process for `extension_paths`. The process loads
    /// extensions lazily on the first payload it receives.
    pub fn start(io: std.Io, allocator: std.mem.Allocator, extension_paths: []const []const u8) !*PersistentProcess {
        const signature = try joinPathSignature(allocator, extension_paths);
        errdefer allocator.free(signature);

        var child = try std.process.spawn(io, .{
            // The sentinel must NOT start with "-": args after `-e <script>` that
            // look like flags are consumed by node itself, not passed as argv[1].
            // One-shot payloads are always JSON objects starting with "{", so the
            // bare "persistent" token is unambiguous.
            .argv = &.{ "node", "-e", hook_runner_script, "persistent" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .expand_arg0 = .expand,
        });
        errdefer child.kill(io);

        // The stdout reader buffer must hold a full response line, since
        // takeDelimiterInclusive requires the delimiter within buffer capacity.
        const stdout_buffer = try allocator.alloc(u8, max_hook_output_bytes + 4096);
        errdefer allocator.free(stdout_buffer);
        const stdin_buffer = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(stdin_buffer);

        const self = try allocator.create(PersistentProcess);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .extension_paths_signature = signature,
            .child = child,
            // Pipes are not seekable: use streaming readers/writers to avoid a
            // failed positional syscall on the child's stdio pipes.
            .stdin_writer = child.stdin.?.writerStreaming(io, stdin_buffer),
            .stdout_reader = child.stdout.?.readerStreaming(io, stdout_buffer),
            .stdin_buffer = stdin_buffer,
            .stdout_buffer = stdout_buffer,
        };
        return self;
    }

    pub fn matchesExtensions(self: *PersistentProcess, allocator: std.mem.Allocator, extension_paths: []const []const u8) bool {
        const signature = joinPathSignature(allocator, extension_paths) catch return false;
        defer allocator.free(signature);
        return std.mem.eql(u8, self.extension_paths_signature, signature);
    }

    pub fn deinit(self: *PersistentProcess) void {
        // kill() forcibly terminates the long-lived child and reaps it. This is
        // uncancelable and idempotent, so session teardown never blocks on the
        // extension process draining its stdin.
        self.child.kill(self.io);
        self.allocator.free(self.stdin_buffer);
        self.allocator.free(self.stdout_buffer);
        self.allocator.free(self.extension_paths_signature);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Send one payload, read one response line. Returns the owned, trimmed
    /// response bytes (caller frees) or null when the response is empty/`null`.
    fn exchange(self: *PersistentProcess, allocator: std.mem.Allocator, payload: []const u8) !?[]u8 {
        while (!self.exchange_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.exchange_mutex.unlock();
        const w = &self.stdin_writer.interface;
        try w.writeAll(payload);
        try w.writeByte('\n');
        try w.flush();

        const r = &self.stdout_reader.interface;
        // takeDelimiterInclusive consumes the trailing newline (unlike the
        // exclusive variant, which would leave it buffered and make the next read
        // observe a spurious empty line). The trailing delimiter is stripped by
        // the trim below.
        const line = r.takeDelimiterInclusive('\n') catch return error.ExtensionHookFailed;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) return null;
        return try allocator.dupe(u8, trimmed);
    }
};

fn joinPathSignature(allocator: std.mem.Allocator, extension_paths: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (extension_paths, 0..) |path, index| {
        if (index != 0) try out.writer.writeByte('\x00');
        try out.writer.writeAll(path);
    }
    return out.toOwnedSlice();
}

pub const Runner = struct {
    pub const FlagValue = struct {
        name: []const u8,
        value: ?[]const u8 = null,
    };

    io: std.Io,
    allocator: std.mem.Allocator,
    extension_paths: []const []const u8,
    flag_values: []const FlagValue = &.{},
    /// When set, every hook is routed through this long-lived node process so
    /// extension module-local state persists across separate Runner calls. When
    /// null, each hook spawns a fresh one-shot node process (CLI/test default).
    persistent: ?*PersistentProcess = null,

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
        /// Per-event semantically-applied result (JSON-encoded), in order: the transformed value
        /// for transform events (before_provider_request/after_provider_response/context), the
        /// decisive value for short-circuit events (user_bash/model_select/thinking_level_select),
        /// the aggregated {skillPaths,promptPaths,themePaths} for resources_discover, or the last
        /// handler result for notify-style events.
        results: [][]u8 = &.{},
        /// Actions accumulated across the whole sequence (sendUserMessage/sendMessage/appendEntry).
        actions: []CommandAction = &.{},

        pub fn deinit(self: LifecycleResult, allocator: std.mem.Allocator) void {
            for (self.observations) |observation| allocator.free(observation);
            if (self.observations.len > 0) allocator.free(self.observations);
            for (self.results) |result| allocator.free(result);
            if (self.results.len > 0) allocator.free(self.results);
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

        var results: std.ArrayList([]u8) = .empty;
        errdefer {
            for (results.items) |result| self.allocator.free(result);
            results.deinit(self.allocator);
        }
        if (parsed.value.object.get("results")) |results_value| {
            if (results_value != .array) return error.ExtensionHookInvalidResponse;
            for (results_value.array.items) |result| {
                try results.append(self.allocator, try jsonValueToOwnedString(self.allocator, result));
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
            .results = try results.toOwnedSlice(self.allocator),
            .actions = actions,
        };
    }

    pub const SingleLifecycleResult = struct {
        /// JSON-encoded semantically-applied result for the event (null when no handler produced one).
        result_json: []u8,
        /// JSON-encoded raw last-handler observation (null when no handler produced one).
        observation_json: []u8,
        /// Queued actions (sendUserMessage/sendMessage/appendEntry) produced by the handlers.
        actions: []CommandAction = &.{},

        pub fn deinit(self: SingleLifecycleResult, allocator: std.mem.Allocator) void {
            allocator.free(self.result_json);
            allocator.free(self.observation_json);
            for (self.actions) |action| action.deinit(allocator);
            if (self.actions.len > 0) allocator.free(self.actions);
        }
    };

    /// Dispatch a single lifecycle event with upstream per-event result semantics and return
    /// the applied result, the raw observation, and any queued actions. This is the seam
    /// callers (e.g. rpc.zig/agent.zig) use to fan a session/agent/turn/message/provider/user_bash
    /// event out to extensions; it reuses the long-lived runner so module state persists.
    pub fn dispatchLifecycleEvent(self: *Runner, event: LifecycleEvent) !SingleLifecycleResult {
        if (!self.hasExtensions()) {
            return .{
                .result_json = try self.allocator.dupe(u8, "null"),
                .observation_json = try self.allocator.dupe(u8, "null"),
            };
        }
        var sequence = try self.runLifecycleSequence(&.{event});
        defer sequence.deinit(self.allocator);
        const result_json = try self.allocator.dupe(u8, if (sequence.results.len > 0) sequence.results[0] else "null");
        errdefer self.allocator.free(result_json);
        const observation_json = try self.allocator.dupe(u8, if (sequence.observations.len > 0) sequence.observations[0] else "null");
        errdefer self.allocator.free(observation_json);
        // Transfer ownership of the actions slice out of the sequence so deinit above does not free it.
        const actions = sequence.actions;
        sequence.actions = &.{};
        return .{ .result_json = result_json, .observation_json = observation_json, .actions = actions };
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
        // Persistent path: reuse the long-lived process so extension module-local
        // state survives across separate Runner calls. Falls back to a fresh spawn
        // per call when no persistent process is attached.
        if (self.persistent) |proc| return proc.exchange(self.allocator, payload);
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
    \\// jiti-style module aliasing. Upstream loader.ts maps these specifiers (both the
    \\// @earendil-works and legacy @mariozechner scopes, plus typebox) onto resolved entry
    \\// points so extensions can `import` the host packages by name. pi-zig resolves them from
    \\// the extension's own dependency roots when present, then falls back to the host process's
    \\// resolver, mirroring jiti's alias behavior in Node/dev mode.
    \\const ALIAS_TARGETS = {
    \\  "@earendil-works/pi-coding-agent": "@earendil-works/pi-coding-agent",
    \\  "@earendil-works/pi-agent-core": "@earendil-works/pi-agent-core",
    \\  "@earendil-works/pi-tui": "@earendil-works/pi-tui",
    \\  "@earendil-works/pi-ai": "@earendil-works/pi-ai",
    \\  "@earendil-works/pi-ai/oauth": "@earendil-works/pi-ai/oauth",
    \\  "@mariozechner/pi-coding-agent": "@earendil-works/pi-coding-agent",
    \\  "@mariozechner/pi-agent-core": "@earendil-works/pi-agent-core",
    \\  "@mariozechner/pi-tui": "@earendil-works/pi-tui",
    \\  "@mariozechner/pi-ai": "@earendil-works/pi-ai",
    \\  "@mariozechner/pi-ai/oauth": "@earendil-works/pi-ai/oauth",
    \\  "@sinclair/typebox": "typebox",
    \\  "@sinclair/typebox/compile": "typebox/compile",
    \\  "@sinclair/typebox/value": "typebox/value",
    \\};
    \\// jiti-style virtual modules. The host may inject extra modules by name through
    \\// PI_EXT_VIRTUAL_MODULES (a JSON object mapping specifier -> ESM source text). The resolve
    \\// hook rewrites matching specifiers to a data: URL so the import resolves to the supplied
    \\// source, mirroring jiti's `virtualModules` option (used for the compiled Bun binary).
    \\const virtualModules = (() => {
    \\  try {
    \\    const raw = process.env.PI_EXT_VIRTUAL_MODULES;
    \\    if (!raw) return new Map();
    \\    const parsed = JSON.parse(raw);
    \\    const map = new Map();
    \\    for (const key of Object.keys(parsed)) {
    \\      if (typeof parsed[key] === "string") map.set(key, parsed[key]);
    \\    }
    \\    return map;
    \\  } catch {
    \\    return new Map();
    \\  }
    \\})();
    \\function virtualModuleUrl(specifier) {
    \\  const source = virtualModules.get(specifier);
    \\  if (source === undefined) return undefined;
    \\  return "data:text/javascript;base64," + Buffer.from(source).toString("base64");
    \\}
    \\// jiti-style dependency roots: resolve a bare specifier by walking up from the importing
    \\// module's directory, trying Node's resolver anchored at each ancestor. This lets an
    \\// extension import packages installed in its own (or an ancestor's) node_modules even when
    \\// the runner process's cwd differs and the extension was transformed to a data: URL.
    \\function dependencyRootsFor(fromPath) {
    \\  const roots = [];
    \\  let dir = fromPath && fromPath.startsWith("file:") ? path.dirname(fileURLToPath(fromPath)) : (fromPath ? path.dirname(fromPath) : process.cwd());
    \\  for (;;) {
    \\    roots.push(dir);
    \\    const parent = path.dirname(dir);
    \\    if (parent === dir) break;
    \\    dir = parent;
    \\  }
    \\  return roots;
    \\}
    \\function resolveFromDependencyRoots(specifier, fromPath) {
    \\  for (const root of dependencyRootsFor(fromPath)) {
    \\    try {
    \\      const anchor = pathToFileURL(path.join(root, "package.json")).href;
    \\      const resolved = createRequire(anchor).resolve(specifier);
    \\      return pathToFileURL(resolved).href;
    \\    } catch {}
    \\  }
    \\  return undefined;
    \\}
    \\// Resolve an aliased/virtual/bare specifier to a URL, or undefined to defer to Node's
    \\// default resolution. Mirrors jiti's alias + virtualModules + dependency-root resolution.
    \\function jitiResolve(specifier, parentURL) {
    \\  const virtual = virtualModuleUrl(specifier);
    \\  if (virtual) return virtual;
    \\  const aliasTarget = ALIAS_TARGETS[specifier];
    \\  if (aliasTarget) {
    \\    const aliasVirtual = virtualModuleUrl(aliasTarget);
    \\    if (aliasVirtual) return aliasVirtual;
    \\    const fromAlias = resolveFromDependencyRoots(aliasTarget, parentURL);
    \\    if (fromAlias) return fromAlias;
    \\  }
    \\  if (specifier[0] !== "." && specifier[0] !== "/" && !specifier.startsWith("file:") && !specifier.startsWith("node:") && !specifier.startsWith("data:")) {
    \\    const fromRoots = resolveFromDependencyRoots(specifier, parentURL);
    \\    if (fromRoots) return fromRoots;
    \\  }
    \\  return undefined;
    \\}
    \\let typeScriptHooksRegistered = false;
    \\if (typeof moduleApi.registerHooks === "function") {
    \\  moduleApi.registerHooks({
    \\    resolve(specifier, context, nextResolve) {
    \\      const rewritten = jitiResolve(specifier, context && context.parentURL);
    \\      if (rewritten) return { url: rewritten, shortCircuit: true };
    \\      return nextResolve(specifier, context);
    \\    },
    \\    load(url, context, nextLoad) {
    \\      if (transformTypeScript && url.startsWith("file:")) {
    \\        const filename = fileURLToPath(url);
    \\        if (filename.endsWith(".ts")) {
    \\          const source = fs.readFileSync(filename, "utf8");
    \\          return { format: "module", shortCircuit: true, source: transformTypeScript(source, url) };
    \\        }
    \\      }
    \\      return nextLoad(url, context);
    \\    },
    \\  });
    \\  typeScriptHooksRegistered = transformTypeScript ? true : false;
    \\}
    \\async function importExtensionModule(resolvedPath) {
    \\  const url = pathToFileURL(resolvedPath).href;
    \\  if (!resolvedPath.endsWith(".ts") || typeScriptHooksRegistered) return import(url);
    \\  if (!transformTypeScript) {
    \\    throw new Error("TypeScript extension support requires Node.js type stripping or the typescript package");
    \\  }
    \\  // Fallback path (Node without registerHooks): transform to a data: URL. Bare imports are
    \\  // rewritten ahead of time against the extension's dependency roots since a data: URL has
    \\  // no base path for Node's resolver to anchor bare specifiers on.
    \\  const source = fs.readFileSync(resolvedPath, "utf8");
    \\  const transformed = transformTypeScript(source, url);
    \\  const encoded = Buffer.from(rewriteBareImportsForDataUrl(transformed, url)).toString("base64");
    \\  return import("data:text/javascript;base64," + encoded);
    \\}
    \\// Rewrite static `import ... from "spec"` / `export ... from "spec"` and dynamic
    \\// `import("spec")` whose specifier resolves through jitiResolve, so a data:-URL TS module
    \\// (which has no base path) can still reach aliased/virtual/dependency-root modules.
    \\function rewriteBareImportsForDataUrl(code, parentURL) {
    \\  const rewriteSpecifier = (spec) => jitiResolve(spec, parentURL) || spec;
    \\  let out = code.replace(/(\bfrom\s*)(["'])([^"']+)\2/g, (m, pre, q, spec) => pre + q + rewriteSpecifier(spec) + q);
    \\  out = out.replace(/(\bimport\s*\(\s*)(["'])([^"']+)\2(\s*\))/g, (m, pre, q, spec, post) => pre + q + rewriteSpecifier(spec) + q + post);
    \\  return out;
    \\}
    \\const PERSISTENT_MODE = process.argv[1] === "persistent";
    \\const handlers = new Map();
    \\const extensionToolMaps = [];
    \\const extensionCommandMaps = [];
    \\const extensionFlagMaps = [];
    \\let activeToolMap = null;
    \\let activeCommandMap = null;
    \\let activeFlagMap = null;
    \\// `payloadFlags`/`diagnostics`/`actions` are per-request buffers. In persistent
    \\// mode they are reset before each payload so one command never observes the
    \\// queued actions of another, while imported extension modules (and the maps
    \\// built from them) stay loaded so module-local state survives across requests.
    \\let payloadFlags = {};
    \\let diagnostics = [];
    \\let actions = [];
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
    \\let extensionsLoaded = false;
    \\async function ensureExtensionsLoaded(extensionList) {
    \\  if (extensionsLoaded) return;
    \\  for (const extensionPath of extensionList || []) {
    \\    try {
    \\      await loadExtension(extensionPath);
    \\    } catch (err) {
    \\      diagnostics.push({ extensionPath: String(extensionPath), error: err && err.message ? err.message : String(err) });
    \\    }
    \\  }
    \\  extensionsLoaded = true;
    \\}
    \\// Transform-style events chain a value across handlers (last non-undefined wins): the
    \\// returned value is fed into the event for the next handler. Mirrors upstream
    \\// emitBeforeProviderRequest (payload) and emitContext (messages).
    \\const TRANSFORM_EVENTS = { before_provider_request: "payload", after_provider_response: "response", context: "messages" };
    \\// Short-circuit events: the first non-null/undefined handler result is decisive and stops
    \\// the chain. Mirrors upstream emitUserBash and model/thinking selection seams.
    \\const SHORT_CIRCUIT_EVENTS = new Set(["user_bash", "model_select", "thinking_level_select"]);
    \\// session_before_* events cancel the pending operation when a handler returns { cancel: true }
    \\// (upstream emit()). Other return values are observed but do not short-circuit.
    \\const SESSION_BEFORE_EVENTS = new Set(["session_before_switch", "session_before_fork", "session_before_compact", "session_before_tree"]);
    \\// Dispatch one lifecycle event with the upstream per-event result semantics. Returns the
    \\// last raw handler result as `observation` (for assertions) plus the semantically-applied
    \\// `result` (transformed value / short-circuit decision / aggregated resources).
    \\async function dispatchLifecycleEvent(lifecycleEvent) {
    \\  const type = lifecycleEvent.type;
    \\  const stepHandlers = handlers.get(type) || [];
    \\  const runHandler = async (handler, eventArg) => {
    \\    try {
    \\      return { ok: true, value: await handler(eventArg, ctx) };
    \\    } catch (err) {
    \\      diagnostics.push({ extensionPath: `lifecycle:${type}`, event: type, error: err && err.message ? err.message : String(err) });
    \\      return { ok: false, value: undefined };
    \\    }
    \\  };
    \\  // resources_discover: aggregate skill/prompt/theme paths across all handlers (emitResourcesDiscover).
    \\  if (type === "resources_discover") {
    \\    const skillPaths = []; const promptPaths = []; const themePaths = [];
    \\    let observation = null;
    \\    for (const handler of stepHandlers) {
    \\      const r = await runHandler(handler, lifecycleEvent);
    \\      if (!r.ok || r.value == null) continue;
    \\      observation = r.value;
    \\      if (Array.isArray(r.value.skillPaths)) skillPaths.push(...r.value.skillPaths);
    \\      if (Array.isArray(r.value.promptPaths)) promptPaths.push(...r.value.promptPaths);
    \\      if (Array.isArray(r.value.themePaths)) themePaths.push(...r.value.themePaths);
    \\    }
    \\    return { observation, result: { skillPaths, promptPaths, themePaths } };
    \\  }
    \\  // Transform-style: chain the value into the next handler via the event's payload key.
    \\  if (TRANSFORM_EVENTS[type]) {
    \\    const key = TRANSFORM_EVENTS[type];
    \\    let current = lifecycleEvent[key];
    \\    let observation = null;
    \\    for (const handler of stepHandlers) {
    \\      const eventArg = { ...lifecycleEvent, [key]: current };
    \\      const r = await runHandler(handler, eventArg);
    \\      if (r.ok && r.value !== undefined) {
    \\        observation = r.value;
    \\        current = type === "context" ? (r.value && r.value.messages !== undefined ? r.value.messages : current) : r.value;
    \\      }
    \\    }
    \\    return { observation, result: current };
    \\  }
    \\  // Short-circuit: first decisive result wins.
    \\  if (SHORT_CIRCUIT_EVENTS.has(type)) {
    \\    for (const handler of stepHandlers) {
    \\      const r = await runHandler(handler, lifecycleEvent);
    \\      if (r.ok && r.value !== undefined && r.value !== null) return { observation: r.value, result: r.value };
    \\    }
    \\    return { observation: null, result: null };
    \\  }
    \\  // session_before_*: a { cancel: true } result stops the chain (operation cancelled).
    \\  if (SESSION_BEFORE_EVENTS.has(type)) {
    \\    let observation = null;
    \\    for (const handler of stepHandlers) {
    \\      const r = await runHandler(handler, lifecycleEvent);
    \\      if (r.ok && r.value != null) {
    \\        observation = r.value;
    \\        if (r.value.cancel) return { observation: r.value, result: r.value };
    \\      }
    \\    }
    \\    return { observation, result: observation };
    \\  }
    \\  // Notify-style (session/agent/turn/message/tool_execution events): run every handler;
    \\  // the last non-null result is observed. No value is fed back into the run.
    \\  let observation = null;
    \\  for (const handler of stepHandlers) {
    \\    const r = await runHandler(handler, lifecycleEvent);
    \\    if (r.ok && r.value !== undefined && r.value !== null) observation = r.value;
    \\  }
    \\  return { observation, result: observation };
    \\}
    \\// Compute the response string for a single event. Extensions are loaded once
    \\// (module cache + extensionsLoaded guard); persistent reuse keeps the same
    \\// imported module instances so extension module-local state persists.
    \\async function computeResponse(event) {
    \\  if (event?.type === "discover_tools") {
    \\    return JSON.stringify({ tools: allRegisteredTools().map(toolSummary) }) + "\n";
    \\  }
    \\  if (event?.type === "discover_commands") {
    \\    return JSON.stringify({ commands: allRegisteredCommands().map((command) => ({
    \\      name: String(command.invocationName),
    \\      description: String(command.description ?? ""),
    \\      sourceInfo: sourceInfoForExtension(command.extensionPath),
    \\    })) }) + "\n";
    \\  }
    \\  if (event?.type === "discover_flags") {
    \\    return JSON.stringify({ flags: allRegisteredFlags() }) + "\n";
    \\  }
    \\  if (event?.type === "lifecycle_sequence") {
    \\    const observations = [];
    \\    const results = [];
    \\    for (const step of event.events || []) {
    \\      const lifecycleEvent = { type: String(step?.type ?? ""), ...(step?.fields && typeof step.fields === "object" ? step.fields : {}) };
    \\      const outcome = await dispatchLifecycleEvent(lifecycleEvent);
    \\      observations.push(outcome.observation);
    \\      results.push(outcome.result);
    \\    }
    \\    return JSON.stringify({ observations, results, actions, diagnostics }) + "\n";
    \\  }
    \\  if (event?.type === "execute_command") {
    \\    const commandName = String(event.commandName ?? "");
    \\    const command = allRegisteredCommands().find((candidate) => candidate.invocationName === commandName);
    \\    if (!command) {
    \\      return JSON.stringify({ handled: false }) + "\n";
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
    \\    return JSON.stringify({ handled: true, actions, diagnostics }) + "\n";
    \\  }
    \\  if (event?.type === "execute_tool") {
    \\    const tool = allRegisteredTools().find((candidate) => candidate.name === event.toolName);
    \\    if (!tool || typeof tool.execute !== "function") throw new Error(`Extension tool not found: ${event.toolName}`);
    \\    return JSON.stringify(normalizeToolResult(await tool.execute(event.toolCallId, event.input ?? {}, undefined, undefined, ctx))) + "\n";
    \\  }
    \\  const eventHandlers = handlers.get(event?.type) || [];
    \\  if (eventHandlers.length === 0) {
    \\    return "null\n";
    \\  }
    \\  if (event.type === "tool_call") {
    \\    for (const handler of eventHandlers) {
    \\      const result = await handler(event, ctx);
    \\      if (result?.block) {
    \\        return JSON.stringify({ block: true, reason: result.reason || "Tool execution was blocked" }) + "\n";
    \\      }
    \\    }
    \\    return JSON.stringify({ input: event.input ?? {} }) + "\n";
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
    \\    return modified ? JSON.stringify({ content: event.content, contentText: contentText(event.content), isError: event.isError, terminate: event.terminate }) + "\n" : "null\n";
    \\  }
    \\  return "null\n";
    \\}
    \\async function handlePayload(payload) {
    \\  // Reset per-request buffers; loaded extension modules/maps are untouched.
    \\  payloadFlags = payload.flags && typeof payload.flags === "object" ? payload.flags : {};
    \\  diagnostics = [];
    \\  actions = [];
    \\  await ensureExtensionsLoaded(payload.extensions);
    \\  return computeResponse(payload.event);
    \\}
    \\async function runOneShot() {
    \\  const payload = JSON.parse(process.argv[1] || "{}");
    \\  process.stdout.write(await handlePayload(payload));
    \\}
    \\// Persistent driver: load extensions once on the first payload, then service
    \\// every subsequent newline-delimited JSON payload over stdin from the same
    \\// process so extension module-local state survives across separate requests.
    \\async function runPersistent() {
    \\  let buffer = "";
    \\  let chain = Promise.resolve();
    \\  let exiting = false;
    \\  process.stdin.setEncoding("utf8");
    \\  process.stdin.on("data", (chunk) => {
    \\    buffer += chunk;
    \\    let newlineIndex;
    \\    while ((newlineIndex = buffer.indexOf("\n")) >= 0) {
    \\      const line = buffer.slice(0, newlineIndex);
    \\      buffer = buffer.slice(newlineIndex + 1);
    \\      if (line.trim().length === 0) continue;
    \\      // Serialize requests through a promise chain so async handlers run in
    \\      // arrival order and responses stay correlated one-per-request.
    \\      chain = chain.then(async () => {
    \\        let response;
    \\        try {
    \\          response = await handlePayload(JSON.parse(line));
    \\        } catch (err) {
    \\          response = JSON.stringify({ error: err && err.message ? err.message : String(err) }) + "\n";
    \\        }
    \\        process.stdout.write(response);
    \\      });
    \\    }
    \\  });
    \\  process.stdin.on("end", () => {
    \\    exiting = true;
    \\    chain.finally(() => process.exit(0));
    \\  });
    \\  process.stdin.on("close", () => {
    \\    if (!exiting) chain.finally(() => process.exit(0));
    \\  });
    \\}
    \\(PERSISTENT_MODE ? runPersistent() : runOneShot()).catch((err) => {
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

test "persistent runner keeps module-local state across separate tool calls" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-persistent-tool-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/counter.mjs";
    // Module-level counter: incremented on every tool execution. A fresh process
    // would reset it to 0; a long-lived process preserves it across calls.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\let count = 0;
        \\export default function(pi) {
        \\  pi.registerTool({
        \\    name: "counter",
        \\    description: "Increment a module-level counter",
        \\    parameters: { type: "object", properties: {}, additionalProperties: false },
        \\    execute: async () => {
        \\      count++;
        \\      return { content: [{ type: "text", text: String(count) }], isError: false };
        \\    }
        \\  });
        \\}
    });

    var call = ai_client.ChatToolCall{
        .id = try allocator.dupe(u8, "call_counter_1"),
        .name = try allocator.dupe(u8, "counter"),
        .arguments_json = try allocator.dupe(u8, "{}"),
    };
    defer call.deinit(allocator);

    // Persistent path: one long-lived process services both calls.
    const proc = try PersistentProcess.start(std.testing.io, allocator, &.{extension_path});
    defer proc.deinit();
    var runner = Runner{
        .io = std.testing.io,
        .allocator = allocator,
        .extension_paths = &.{extension_path},
        .persistent = proc,
    };

    const first = try runner.runRegisteredTool(call);
    defer allocator.free(first.content);
    try std.testing.expect(!first.is_error);
    try std.testing.expectEqualStrings("1", first.content);

    const second = try runner.runRegisteredTool(call);
    defer allocator.free(second.content);
    try std.testing.expect(!second.is_error);
    // State survived the second SEPARATE call because the same process handled it.
    try std.testing.expectEqualStrings("2", second.content);

    const third = try runner.runRegisteredTool(call);
    defer allocator.free(third.content);
    try std.testing.expectEqualStrings("3", third.content);

    // Control: the non-persistent path spawns a fresh process per call, so the
    // module-level counter resets to 1 every time.
    var oneshot_runner = Runner{
        .io = std.testing.io,
        .allocator = allocator,
        .extension_paths = &.{extension_path},
    };
    const oneshot_first = try oneshot_runner.runRegisteredTool(call);
    defer allocator.free(oneshot_first.content);
    try std.testing.expectEqualStrings("1", oneshot_first.content);
    const oneshot_second = try oneshot_runner.runRegisteredTool(call);
    defer allocator.free(oneshot_second.content);
    try std.testing.expectEqualStrings("1", oneshot_second.content);
}

test "persistent runner reuses one process across discovery and lifecycle events" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-persistent-lifecycle-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/persistent-lifecycle.mjs";
    // The module records the PID once at load; if discovery and every later event
    // observe the SAME pid, they were all served by one reused process. Separate
    // counters per event type prove state accumulates across separate calls.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\const pid = process.pid;
        \\let sessions = 0;
        \\let turns = 0;
        \\let requests = 0;
        \\export default function(pi) {
        \\  pi.registerTool({
        \\    name: "pid_probe",
        \\    description: "Report the loading process id and request count",
        \\    parameters: { type: "object", properties: {}, additionalProperties: false },
        \\    execute: async () => {
        \\      requests++;
        \\      return { content: [{ type: "text", text: `${pid}:${requests}` }], isError: false };
        \\    }
        \\  });
        \\  pi.on("session_start", () => { sessions++; return { pid, sessions }; });
        \\  pi.on("provider_request", () => { requests++; return { pid, requests }; });
        \\  pi.on("turn_start", () => { turns++; return { pid, turns, sessions }; });
        \\  pi.on("turn_end", () => { return { pid, turns }; });
        \\  pi.on("session_shutdown", () => { return { pid, sessions, turns, requests }; });
        \\}
    });

    const proc = try PersistentProcess.start(std.testing.io, allocator, &.{extension_path});
    defer proc.deinit();
    var runner = Runner{
        .io = std.testing.io,
        .allocator = allocator,
        .extension_paths = &.{extension_path},
        .persistent = proc,
    };

    // 1) A separate discovery call against the same process.
    const definitions = try runner.discoverToolDefinitions();
    defer runner.deinitToolDefinitions(definitions);
    try std.testing.expectEqual(@as(usize, 1), definitions.len);
    try std.testing.expectEqualStrings("pid_probe", definitions[0].name);

    // 2) A separate tool execution: capture the loading pid.
    var probe_call = ai_client.ChatToolCall{
        .id = try allocator.dupe(u8, "call_pid_probe_1"),
        .name = try allocator.dupe(u8, "pid_probe"),
        .arguments_json = try allocator.dupe(u8, "{}"),
    };
    defer probe_call.deinit(allocator);
    const probe = try runner.runRegisteredTool(probe_call);
    defer allocator.free(probe.content);
    const colon = std.mem.indexOfScalar(u8, probe.content, ':') orelse return error.UnexpectedToolResult;
    const observed_pid = probe.content[0..colon];
    try std.testing.expect(observed_pid.len > 0);

    // 3) A separate lifecycle sequence: drives session/turn/provider events that
    // were previously only inventoried. session_start -> turn_start -> turn_end ->
    // session_shutdown all observe the SAME pid as the discovery/tool calls above,
    // proving one reused long-lived process, and accumulate state across events.
    const events = [_]Runner.LifecycleEvent{
        .{ .type = "session_start", .fields_json = "{\"reason\":\"startup\"}" },
        .{ .type = "turn_start", .fields_json = "{\"turnIndex\":0}" },
        .{ .type = "turn_end", .fields_json = "{\"turnIndex\":0}" },
        .{ .type = "session_shutdown", .fields_json = "{\"reason\":\"quit\"}" },
    };
    const lifecycle = try runner.runLifecycleSequence(&events);
    defer lifecycle.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), lifecycle.observations.len);

    var session_obs = try std.json.parseFromSlice(std.json.Value, allocator, lifecycle.observations[0], .{});
    defer session_obs.deinit();
    const lifecycle_pid = session_obs.value.object.get("pid").?.integer;
    // Same pid as the tool/discovery calls => one reused process across all calls.
    var pid_buf: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buf, "{d}", .{lifecycle_pid});
    try std.testing.expectEqualStrings(observed_pid, pid_text);

    var shutdown_obs = try std.json.parseFromSlice(std.json.Value, allocator, lifecycle.observations[3], .{});
    defer shutdown_obs.deinit();
    // session_shutdown sees 1 session + 1 turn accumulated from earlier events in
    // the same process.
    try std.testing.expectEqual(@as(i64, 1), shutdown_obs.value.object.get("sessions").?.integer);
    try std.testing.expectEqual(@as(i64, 1), shutdown_obs.value.object.get("turns").?.integer);
}

test "lifecycle before_provider_request chains the payload across handlers" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-before-provider-request-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/before-provider-request.mjs";
    // Two handlers each append to the payload's headers array; the second observes the first's
    // transform, proving the payload is chained (upstream emitBeforeProviderRequest semantics).
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\export default function(pi) {
        \\  pi.on("before_provider_request", (event) => {
        \\    const payload = event.payload || {};
        \\    return { ...payload, headers: [...(payload.headers || []), "first"] };
        \\  });
        \\  pi.on("before_provider_request", (event) => {
        \\    const payload = event.payload || {};
        \\    return { ...payload, headers: [...(payload.headers || []), "second"] };
        \\  });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    const outcome = try runner.dispatchLifecycleEvent(.{ .type = "before_provider_request", .fields_json = "{\"payload\":{\"model\":\"x\"}}" });
    defer outcome.deinit(allocator);

    var result = try std.json.parseFromSlice(std.json.Value, allocator, outcome.result_json, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("x", result.value.object.get("model").?.string);
    const headers = result.value.object.get("headers").?.array;
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expectEqualStrings("first", headers.items[0].string);
    try std.testing.expectEqualStrings("second", headers.items[1].string);
}

test "lifecycle user_bash short-circuits on the first decisive handler result" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-user-bash-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const extension_path = fixture_dir ++ "/user-bash.mjs";
    // The first handler returns nothing (undefined); the second returns a decisive result that
    // must win and stop the chain (the third handler must never run). Mirrors emitUserBash.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\let thirdRan = false;
        \\export default function(pi) {
        \\  pi.on("user_bash", () => undefined);
        \\  pi.on("user_bash", (event) => ({ handled: true, command: event.command + " --safe" }));
        \\  pi.on("user_bash", () => { thirdRan = true; return { handled: false }; });
        \\  pi.registerTool({
        \\    name: "third_ran",
        \\    description: "Report whether the third user_bash handler ran",
        \\    parameters: { type: "object", properties: {}, additionalProperties: false },
        \\    execute: async () => ({ content: [{ type: "text", text: String(thirdRan) }], isError: false })
        \\  });
        \\}
    });

    const proc = try PersistentProcess.start(std.testing.io, allocator, &.{extension_path});
    defer proc.deinit();
    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path}, .persistent = proc };

    const outcome = try runner.dispatchLifecycleEvent(.{ .type = "user_bash", .fields_json = "{\"command\":\"ls\"}" });
    defer outcome.deinit(allocator);
    var result = try std.json.parseFromSlice(std.json.Value, allocator, outcome.result_json, .{});
    defer result.deinit();
    try std.testing.expect(result.value.object.get("handled").?.bool);
    try std.testing.expectEqualStrings("ls --safe", result.value.object.get("command").?.string);

    // Confirm the third handler never ran (short-circuit) by probing the module-level flag
    // through the same long-lived process.
    var probe = ai_client.ChatToolCall{
        .id = try allocator.dupe(u8, "call_third_ran"),
        .name = try allocator.dupe(u8, "third_ran"),
        .arguments_json = try allocator.dupe(u8, "{}"),
    };
    defer probe.deinit(allocator);
    const probe_result = try runner.runRegisteredTool(probe);
    defer allocator.free(probe_result.content);
    try std.testing.expectEqualStrings("false", probe_result.content);
}

test "lifecycle resources_discover aggregates paths across handlers" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-resources-discover-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir);
    const first_path = fixture_dir ++ "/a-first.mjs";
    const second_path = fixture_dir ++ "/b-second.mjs";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = first_path, .data =
        \\export default function(pi) {
        \\  pi.on("resources_discover", () => ({ skillPaths: ["/skills/a.md"], promptPaths: ["/prompts/a.md"] }));
        \\}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = second_path, .data =
        \\export default function(pi) {
        \\  pi.on("resources_discover", () => ({ skillPaths: ["/skills/b.md"], themePaths: ["/themes/b.json"] }));
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{ first_path, second_path } };
    const outcome = try runner.dispatchLifecycleEvent(.{ .type = "resources_discover", .fields_json = "{\"cwd\":\"/work\",\"reason\":\"startup\"}" });
    defer outcome.deinit(allocator);
    var result = try std.json.parseFromSlice(std.json.Value, allocator, outcome.result_json, .{});
    defer result.deinit();
    const skills = result.value.object.get("skillPaths").?.array;
    try std.testing.expectEqual(@as(usize, 2), skills.items.len);
    try std.testing.expectEqualStrings("/skills/a.md", skills.items[0].string);
    try std.testing.expectEqualStrings("/skills/b.md", skills.items[1].string);
    try std.testing.expectEqual(@as(usize, 1), result.value.object.get("promptPaths").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.value.object.get("themePaths").?.array.items.len);
}

test "jiti dependency-root resolution imports a bare package from the extension node_modules" {
    const allocator = std.testing.allocator;
    const fixture_dir = "zig-out/pi-zig-extension-runner-jiti-deproot-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, fixture_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture_dir ++ "/node_modules/dep-pkg");
    // A bare dependency installed in the extension's own node_modules. jiti-style dependency-root
    // resolution must find it even though the runner process cwd is the repo root.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = fixture_dir ++ "/node_modules/dep-pkg/package.json", .data =
        \\{"name":"dep-pkg","version":"1.0.0","type":"module","main":"index.js"}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = fixture_dir ++ "/node_modules/dep-pkg/index.js", .data =
        \\export const greeting = "from-dep";
    });
    // A TypeScript extension (transformed at load) importing the bare dependency by name.
    const extension_path = fixture_dir ++ "/tool.ts";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extension_path, .data =
        \\import { greeting } from "dep-pkg";
        \\export default function(pi: any): void {
        \\  pi.registerTool({
        \\    name: "dep_echo",
        \\    description: "Echo a value imported from a bare dependency",
        \\    parameters: { type: "object", properties: {}, additionalProperties: false },
        \\    execute: async () => ({ content: [{ type: "text", text: greeting }], isError: false })
        \\  });
        \\}
    });

    var runner = Runner{ .io = std.testing.io, .allocator = allocator, .extension_paths = &.{extension_path} };
    const definitions = try runner.discoverToolDefinitions();
    defer runner.deinitToolDefinitions(definitions);
    try std.testing.expectEqual(@as(usize, 1), definitions.len);
    try std.testing.expectEqualStrings("dep_echo", definitions[0].name);

    var call = ai_client.ChatToolCall{
        .id = try allocator.dupe(u8, "call_dep_echo_1"),
        .name = try allocator.dupe(u8, "dep_echo"),
        .arguments_json = try allocator.dupe(u8, "{}"),
    };
    defer call.deinit(allocator);
    const result = try runner.runRegisteredTool(call);
    defer allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("from-dep", result.content);
}

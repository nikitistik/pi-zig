const std = @import("std");
const ai_client = @import("ai_client.zig");
const models = @import("models.zig");
const tools = @import("tools.zig");

pub const ToolStartCallback = *const fn (ctx: *anyopaque, call: ai_client.ChatToolCall) anyerror!void;
pub const ToolUpdateCallback = *const fn (ctx: *anyopaque, update: ToolUpdate) anyerror!void;
pub const ToolEndCallback = *const fn (ctx: *anyopaque, result: ToolResult) anyerror!void;
pub const TextDeltaCallback = ai_client.StreamTextCallback;
pub const BeforeToolCallCallback = *const fn (ctx: *anyopaque, call: ai_client.ChatToolCall) anyerror!BeforeToolCallResult;
pub const AfterToolCallCallback = *const fn (ctx: *anyopaque, call: ai_client.ChatToolCall, result: ToolResult) anyerror!AfterToolCallResult;
pub const CustomToolCallback = *const fn (ctx: *anyopaque, call: ai_client.ChatToolCall) anyerror!ToolExecutionResult;
pub const PrepareNextTurnCallback = *const fn (ctx: *anyopaque, turn: TurnContext) anyerror!PrepareNextTurnResult;
pub const ShouldStopAfterTurnCallback = *const fn (ctx: *anyopaque, turn: TurnContext) anyerror!bool;
pub const CancellationCallback = *const fn (ctx: *anyopaque) bool;

// [FLOW_J_EXTENSION_EVENTS] Notify-style lifecycle emission seam fired from the
// provider-backed prompt loop. The callback mirrors the upstream emit() points
// (agent-session.ts _emitExtensionEvent + sdk.ts onPayload/onResponse): turn_start,
// before_provider_request, after_provider_response, message_start, message_end, and
// turn_end fire at the same positions upstream emits them. rpc.zig provides the
// callback and fans each event out to the extension runner (reusing the persistent
// process). It is notify-style here: pi-zig builds the low-level provider payload
// inside ai_client (not owned by this seam), so before_provider_request surfaces the
// provider/model for observation rather than rewriting the raw HTTP body. The callback
// is best-effort and must not abort the turn, so callers swallow emission failures.
pub const LifecycleEmitEvent = struct {
    type: []const u8,
    /// JSON object of extra fields merged into the emitted event (e.g.
    /// {"turnIndex":0,"timestamp":1}); never null (use "{}" when empty).
    fields_json: []const u8 = "{}",
};
pub const LifecycleEmitCallback = *const fn (ctx: *anyopaque, event: LifecycleEmitEvent) anyerror!void;

pub const RunOptions = struct {
    provider: []const u8,
    model: []const u8,
    api_key: []const u8,
    prompt: []const u8,
    system_prompt: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
    shell_path: ?[]const u8 = null,
    shell_command_prefix: ?[]const u8 = null,
    history: []const ai_client.ChatMessage = &.{},
    prompt_content_parts: []const ai_client.ChatContentPart = &.{},
    max_turns: usize = 8,
    tool_set: ToolSet = .all,
    custom_tools: []const ai_client.ChatToolDefinition = &.{},
    custom_tool_context: ?*anyopaque = null,
    execute_custom_tool: ?CustomToolCallback = null,
    stream_turns: bool = false,
    tool_event_context: ?*anyopaque = null,
    on_tool_start: ?ToolStartCallback = null,
    on_tool_update: ?ToolUpdateCallback = null,
    on_tool_end: ?ToolEndCallback = null,
    tool_hook_context: ?*anyopaque = null,
    before_tool_call: ?BeforeToolCallCallback = null,
    after_tool_call: ?AfterToolCallCallback = null,
    turn_lifecycle_context: ?*anyopaque = null,
    prepare_next_turn: ?PrepareNextTurnCallback = null,
    should_stop_after_turn: ?ShouldStopAfterTurnCallback = null,
    cancellation_context: ?*anyopaque = null,
    should_cancel: ?CancellationCallback = null,
    text_event_context: ?*anyopaque = null,
    on_text_delta: ?TextDeltaCallback = null,
    // [FLOW_J_EXTENSION_EVENTS] Optional extension lifecycle emission. When set, the
    // prompt loop fires turn/provider/message events through this callback at the
    // upstream-matching points (see LifecycleEmitCallback). Left null by callers that
    // load no extensions, keeping the loop allocation-free on the hot path.
    lifecycle_context: ?*anyopaque = null,
    on_lifecycle_event: ?LifecycleEmitCallback = null,
    // Honors the resolved `images.autoResize` setting. When true (default) the read-tool keeps the
    // upstream-shaped encoded-size gate: oversized inline images are omitted with the resize note
    // because pi-zig has no embedded image decoder to downscale them. When false the user has opted
    // out of resizing entirely, so images always pass through at their original size with no resize
    // note (pi-zig has no resize worker, so "false" simply means "never gate/omit on size").
    auto_resize_images: bool = true,
};

pub const BeforeToolCallResult = struct {
    block: bool = false,
    reason: ?[]u8 = null,
    arguments_json: ?[]u8 = null,

    pub fn deinit(self: BeforeToolCallResult, allocator: std.mem.Allocator) void {
        if (self.reason) |reason| allocator.free(reason);
        if (self.arguments_json) |arguments_json| allocator.free(arguments_json);
    }
};

pub const AfterToolCallResult = struct {
    content: ?[]u8 = null,
    content_parts: []ai_client.ChatContentPart = &.{},
    is_error: ?bool = null,
    terminate: ?bool = null,

    pub fn deinit(self: AfterToolCallResult, allocator: std.mem.Allocator) void {
        if (self.content) |content| allocator.free(content);
        freeContentParts(allocator, self.content_parts);
    }
};

pub const TurnContext = struct {
    turn_index: usize,
    assistant_text: []const u8,
    tool_results: []const ToolResult,
    system_prompt: []const u8,
    provider: []const u8,
    model: []const u8,
};

pub const PrepareNextTurnResult = struct {
    system_prompt: ?[]u8 = null,
    provider: ?[]u8 = null,
    model: ?[]u8 = null,
    api_key: ?[]u8 = null,

    pub fn deinit(self: PrepareNextTurnResult, allocator: std.mem.Allocator) void {
        if (self.system_prompt) |system_prompt| allocator.free(system_prompt);
        if (self.provider) |provider| allocator.free(provider);
        if (self.model) |model| allocator.free(model);
        if (self.api_key) |api_key| allocator.free(api_key);
    }
};

pub const ToolSet = struct {
    read: bool = true,
    bash: bool = true,
    edit: bool = true,
    write: bool = true,
    grep: bool = true,
    find: bool = true,
    ls: bool = true,

    pub const none: ToolSet = .{
        .read = false,
        .bash = false,
        .edit = false,
        .write = false,
        .grep = false,
        .find = false,
        .ls = false,
    };
    pub const all: ToolSet = .{};

    pub fn contains(self: ToolSet, name: []const u8) bool {
        if (std.mem.eql(u8, name, "read")) return self.read;
        if (std.mem.eql(u8, name, "bash")) return self.bash;
        if (std.mem.eql(u8, name, "edit")) return self.edit;
        if (std.mem.eql(u8, name, "write")) return self.write;
        if (std.mem.eql(u8, name, "grep")) return self.grep;
        if (std.mem.eql(u8, name, "find")) return self.find;
        if (std.mem.eql(u8, name, "ls")) return self.ls;
        return false;
    }
};

pub const RunResult = struct {
    final_text: []u8,
    tool_call_batches: []ToolCallBatch = &.{},
    tool_results: []ToolResult = &.{},
    tool_results_count: usize = 0,
    stopped_after_turn: bool = false,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.final_text);
        for (self.tool_call_batches) |batch| batch.deinit(allocator);
        allocator.free(self.tool_call_batches);
        for (self.tool_results) |result| result.deinit(allocator);
        allocator.free(self.tool_results);
    }
};

pub const ToolCallBatch = struct {
    content: []u8,
    tool_calls: []ai_client.ChatToolCall,
    first_tool_result_index: usize,
    tool_results_count: usize,

    pub fn deinit(self: ToolCallBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        for (self.tool_calls) |call| call.deinit(allocator);
        allocator.free(self.tool_calls);
    }
};

pub const ToolResult = struct {
    tool_call_id: []u8,
    tool_name: []u8,
    arguments_json: []u8,
    content: []u8,
    content_parts: []ai_client.ChatContentPart = &.{},
    is_error: bool = false,
    terminate: bool = false,

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        if (self.tool_call_id.len > 0) allocator.free(self.tool_call_id);
        if (self.tool_name.len > 0) allocator.free(self.tool_name);
        if (self.arguments_json.len > 0) allocator.free(self.arguments_json);
        if (self.content.len > 0) allocator.free(self.content);
        freeContentParts(allocator, self.content_parts);
    }
};

pub const ToolUpdate = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    content: []const u8,
    is_error: bool = false,
    terminate: bool = false,
    truncated: bool = false,
    full_output_path: ?[]const u8 = null,
    truncation: ?tools.ShellTruncationDetails = null,
};

pub const ToolExecutionResult = struct {
    content: []u8,
    content_parts: []ai_client.ChatContentPart = &.{},
    is_error: bool = false,
    terminate: bool = false,
    arguments_json: ?[]u8 = null,

    fn deinit(self: ToolExecutionResult, allocator: std.mem.Allocator) void {
        if (self.content.len > 0) allocator.free(self.content);
        freeContentParts(allocator, self.content_parts);
        if (self.arguments_json) |arguments_json| allocator.free(arguments_json);
    }
};

pub const AgentError = anyerror;

const bash_parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string","description":"Bash command to execute"},"timeout":{"type":"number","description":"Timeout in seconds (optional, no default timeout)"}},"required":["command"],"additionalProperties":false}
;
const read_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to read (relative or absolute)"},"offset":{"type":"number","description":"Line number to start reading from (1-indexed)"},"limit":{"type":"number","description":"Maximum number of lines to read"}},"required":["path"],"additionalProperties":false}
;
const edit_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to edit (relative or absolute)"},"edits":{"type":"array","description":"One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits. If two changes touch the same block or nearby lines, merge them into one edit instead.","items":{"type":"object","properties":{"oldText":{"type":"string","description":"Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call."},"newText":{"type":"string","description":"Replacement text for this targeted edit."}},"required":["oldText","newText"],"additionalProperties":false}}},"required":["path","edits"],"additionalProperties":false}
;
const write_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to write (relative or absolute)"},"content":{"type":"string","description":"Content to write to the file"}},"required":["path","content"],"additionalProperties":false}
;
const grep_parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Search pattern (regex or literal string)"},"path":{"type":"string","description":"Directory or file to search (default: current directory)"},"glob":{"type":"string","description":"Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'"},"ignoreCase":{"type":"boolean","description":"Case-insensitive search (default: false)"},"literal":{"type":"boolean","description":"Treat pattern as literal string instead of regex (default: false)"},"context":{"type":"number","description":"Number of lines to show before and after each match (default: 0)"},"limit":{"type":"number","description":"Maximum number of matches to return (default: 100)"}},"required":["pattern"],"additionalProperties":false}
;
const find_parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'"},"path":{"type":"string","description":"Directory to search in (default: current directory)"},"limit":{"type":"number","description":"Maximum number of results (default: 1000)"}},"required":["pattern"],"additionalProperties":false}
;
const ls_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Directory to list (default: current directory)"},"limit":{"type":"number","description":"Maximum number of entries to return (default: 500)"}},"additionalProperties":false}
;
const non_vision_image_note = "[Current model does not support images. The image will be omitted from this request.]";
const image_resize_omitted_note = "[Image omitted: could not be resized below the inline image size limit.]";
// 4.5MB of base64 payload, matching upstream image-resize-core DEFAULT_MAX_BYTES. Provides
// headroom below Anthropic's 5MB inline-image limit. pi-zig has no embedded WASM image decoder
// (upstream's Photon), so it can enforce this encoded-size gate but cannot pixel-downscale an
// over-limit image; such images are omitted exactly like upstream's no-Photon resize path.
const image_resize_max_base64_bytes: usize = (9 * 1024 * 1024) / 2;

const all_tool_definitions = [_]ai_client.ChatToolDefinition{
    .{
        .name = "read",
        .description = "Read the contents of a file. Supports text files and images (jpg, png, gif, webp). Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
        .parameters_json = read_parameters_json,
    },
    .{
        .name = "bash",
        .description = "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds.",
        .parameters_json = bash_parameters_json,
    },
    .{
        .name = "edit",
        .description = "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits. Do not include large unchanged regions just to connect distant changes.",
        .parameters_json = edit_parameters_json,
    },
    .{
        .name = "write",
        .description = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        .parameters_json = write_parameters_json,
    },
    .{
        .name = "grep",
        .description = "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Respects .gitignore. Output is truncated to 100 matches or 50KB (whichever is hit first). Long lines are truncated to 500 chars.",
        .parameters_json = grep_parameters_json,
    },
    .{
        .name = "find",
        .description = "Search for files by glob pattern. Returns matching file paths relative to the search directory. Respects .gitignore. Output is truncated to 1000 results or 50KB (whichever is hit first).",
        .parameters_json = find_parameters_json,
    },
    .{
        .name = "ls",
        .description = "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. Includes dotfiles. Output is truncated to 500 entries or 50KB (whichever is hit first).",
        .parameters_json = ls_parameters_json,
    },
};

const OwnedMessage = struct {
    role: ai_client.ChatRole,
    content: []u8,
    content_parts: []ai_client.ChatContentPart = &.{},
    tool_call_id: ?[]u8 = null,
    tool_calls: []ai_client.ChatToolCall = &.{},

    fn deinit(self: OwnedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        freeContentParts(allocator, self.content_parts);
        if (self.tool_call_id) |id| allocator.free(id);
        for (self.tool_calls) |call| call.deinit(allocator);
        allocator.free(self.tool_calls);
    }

    fn borrowed(self: *const OwnedMessage) ai_client.ChatMessage {
        return .{
            .role = self.role,
            .content = self.content,
            .content_parts = self.content_parts,
            .tool_call_id = self.tool_call_id,
            .tool_calls = self.tool_calls,
        };
    }
};

pub fn runPrompt(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    options: RunOptions,
) AgentError!RunResult {
    var messages: std.ArrayList(OwnedMessage) = .empty;
    defer {
        for (messages.items) |message| message.deinit(allocator);
        messages.deinit(allocator);
    }

    if (options.system_prompt) |system_prompt| {
        const trimmed = std.mem.trim(u8, system_prompt, " \t\r\n");
        if (trimmed.len > 0) {
            try messages.append(allocator, .{
                .role = .system,
                .content = try allocator.dupe(u8, trimmed),
            });
        }
    }
    for (options.history) |message| {
        try messages.append(allocator, try cloneChatMessage(allocator, message));
    }
    try messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, options.prompt),
        .content_parts = try cloneContentParts(allocator, options.prompt_content_parts),
    });

    var tool_results_count: usize = 0;
    var tool_results: std.ArrayList(ToolResult) = .empty;
    errdefer {
        for (tool_results.items) |result| result.deinit(allocator);
        tool_results.deinit(allocator);
    }
    var tool_call_batches: std.ArrayList(ToolCallBatch) = .empty;
    errdefer {
        for (tool_call_batches.items) |batch| batch.deinit(allocator);
        tool_call_batches.deinit(allocator);
    }

    var built_in_tool_definitions_buf: [all_tool_definitions.len]ai_client.ChatToolDefinition = undefined;
    const built_in_tool_definitions = enabledToolDefinitions(options.tool_set, options.custom_tools, &built_in_tool_definitions_buf);
    var tool_definitions_list: std.ArrayList(ai_client.ChatToolDefinition) = .empty;
    defer tool_definitions_list.deinit(allocator);
    try tool_definitions_list.appendSlice(allocator, built_in_tool_definitions);
    try tool_definitions_list.appendSlice(allocator, options.custom_tools);
    var active_provider: ?[]u8 = null;
    defer if (active_provider) |provider| allocator.free(provider);
    var active_model: ?[]u8 = null;
    defer if (active_model) |model| allocator.free(model);
    var active_api_key: ?[]u8 = null;
    defer if (active_api_key) |api_key| allocator.free(api_key);
    var turn: usize = 0;
    while (turn < options.max_turns) : (turn += 1) {
        try checkCancellation(options);
        // [FLOW_J_EXTENSION_EVENTS] turn_start (upstream agent-session.ts TurnStartEvent:
        // {turnIndex,timestamp}). Fired before the provider request for this turn.
        var turn_fields_buf: [64]u8 = undefined;
        emitLifecycle(options, "turn_start", lifecycleTurnFields(&turn_fields_buf, turn));
        const borrowed = try borrowMessages(allocator, messages.items);
        defer allocator.free(borrowed);
        const request_provider = active_provider orelse options.provider;
        const request_model = active_model orelse options.model;
        const request_api_key = active_api_key orelse options.api_key;

        const request: ai_client.ChatTurnRequest = .{
            .provider = request_provider,
            .model = request_model,
            .api_key = request_api_key,
            .messages = borrowed,
            .tools = tool_definitions_list.items,
            .cancellation_context = options.cancellation_context,
            .should_cancel = options.should_cancel,
        };
        // [FLOW_J_EXTENSION_EVENTS] before_provider_request (upstream sdk.ts onPayload):
        // surfaces the provider/model for the upcoming request. Notify-style here because
        // pi-zig assembles the raw HTTP payload inside ai_client (outside this seam).
        var provider_fields_buf: [256]u8 = undefined;
        emitLifecycle(options, "before_provider_request", lifecycleProviderRequestFields(&provider_fields_buf, request_provider, request_model));
        var response = if (options.stream_turns)
            try ai_client.streamChatTurnWithTextCallback(io, allocator, env, request, options.text_event_context, options.on_text_delta)
        else
            try ai_client.runChatTurn(io, allocator, env, request);
        defer response.deinit(allocator);
        // [FLOW_J_EXTENSION_EVENTS] after_provider_response (upstream sdk.ts onResponse):
        // fired once the provider response is received, before consuming the stream/tools.
        emitLifecycle(options, "after_provider_response", "{\"status\":200}");
        try checkCancellation(options);

        if (response.tool_calls.len == 0) {
            const text = if (response.text) |value| value else try allocator.dupe(u8, "");
            response.text = null;
            // [FLOW_J_EXTENSION_EVENTS] A final assistant message (no tool calls) ends the
            // loop. Emit message_start/message_end around it and a terminal turn_end so the
            // single-turn case still observes the message + turn lifecycle (upstream fires
            // message_start/message_end per assistant message and turn_end per turn).
            emitLifecycle(options, "message_start", "{\"role\":\"assistant\"}");
            emitLifecycle(options, "message_end", "{\"role\":\"assistant\"}");
            emitLifecycle(options, "turn_end", lifecycleTurnFields(&turn_fields_buf, turn));
            return .{
                .final_text = text,
                .tool_call_batches = try tool_call_batches.toOwnedSlice(allocator),
                .tool_results = try tool_results.toOwnedSlice(allocator),
                .tool_results_count = tool_results_count,
            };
        }

        // [FLOW_J_EXTENSION_EVENTS] An assistant message carrying tool calls: emit
        // message_start/message_end around recording it (upstream MessageStart/MessageEnd).
        emitLifecycle(options, "message_start", "{\"role\":\"assistant\"}");
        try appendAssistantToolCallMessage(allocator, &messages, &response);
        emitLifecycle(options, "message_end", "{\"role\":\"assistant\"}");
        const tool_calls = messages.items[messages.items.len - 1].tool_calls;
        response.tool_calls = &.{};

        var terminating_results: usize = 0;
        const batch_results_start = tool_results.items.len;
        try tool_call_batches.append(allocator, .{
            .content = try allocator.dupe(u8, messages.items[messages.items.len - 1].content),
            .tool_calls = try cloneToolCalls(allocator, tool_calls),
            .first_tool_result_index = batch_results_start,
            .tool_results_count = tool_calls.len,
        });
        var tool_options = options;
        tool_options.provider = request_provider;
        tool_options.model = request_model;
        tool_options.api_key = request_api_key;
        for (tool_calls) |call| {
            try checkCancellation(options);
            if (options.on_tool_start) |callback| {
                if (options.tool_event_context) |context| try callback(context, call);
            }
            var tool_execution = try executeToolCallWithHooks(io, allocator, call, tool_options);
            errdefer tool_execution.deinit(allocator);
            try checkCancellation(options);
            const tool_call_id = try allocator.dupe(u8, call.id);
            errdefer allocator.free(tool_call_id);
            const trace_call: ai_client.ChatToolCall = .{
                .id = call.id,
                .name = call.name,
                .arguments_json = tool_execution.arguments_json orelse call.arguments_json,
            };
            const traced_tool_result = try createToolResultTrace(
                allocator,
                trace_call,
                tool_execution.content,
                tool_execution.content_parts,
                tool_execution.is_error,
                tool_execution.terminate,
            );
            errdefer traced_tool_result.deinit(allocator);
            if (options.on_tool_end) |callback| {
                if (options.tool_event_context) |context| try callback(context, traced_tool_result);
            }
            try tool_results.append(allocator, traced_tool_result);
            try messages.append(allocator, .{
                .role = .tool,
                .content = tool_execution.content,
                .content_parts = tool_execution.content_parts,
                .tool_call_id = tool_call_id,
            });
            tool_execution.content = &.{};
            tool_execution.content_parts = &.{};
            if (tool_execution.arguments_json) |arguments_json| allocator.free(arguments_json);
            tool_execution.arguments_json = null;
            tool_results_count += 1;
            if (traced_tool_result.terminate) terminating_results += 1;
        }

        // [FLOW_J_EXTENSION_EVENTS] turn_end after the turn's tool results are recorded
        // (upstream TurnEndEvent: {turnIndex,...}). The steering/prepare-next-turn hooks
        // below are pi-zig's existing turn-lifecycle callbacks and stay unchanged.
        emitLifecycle(options, "turn_end", lifecycleTurnFields(&turn_fields_buf, turn));

        const should_stop = try finishTurnLifecycle(allocator, &messages, options, .{
            .turn_index = turn,
            .assistant_text = messages.items[messages.items.len - 1].content,
            .tool_results = tool_results.items[batch_results_start..],
            .system_prompt = currentSystemPrompt(messages.items),
            .provider = active_provider orelse options.provider,
            .model = active_model orelse options.model,
        }, &active_provider, &active_model, &active_api_key);
        try checkCancellation(options);
        if (should_stop) {
            return .{
                .final_text = try allocator.dupe(u8, ""),
                .tool_call_batches = try tool_call_batches.toOwnedSlice(allocator),
                .tool_results = try tool_results.toOwnedSlice(allocator),
                .tool_results_count = tool_results_count,
                .stopped_after_turn = true,
            };
        }

        if (terminating_results == tool_calls.len) {
            return .{
                .final_text = try allocator.dupe(u8, ""),
                .tool_call_batches = try tool_call_batches.toOwnedSlice(allocator),
                .tool_results = try tool_results.toOwnedSlice(allocator),
                .tool_results_count = tool_results_count,
            };
        }
    }

    return error.MaxAgentTurnsExceeded;
}

fn borrowMessages(allocator: std.mem.Allocator, messages: []const OwnedMessage) ![]ai_client.ChatMessage {
    const borrowed = try allocator.alloc(ai_client.ChatMessage, messages.len);
    for (messages, 0..) |*message, index| {
        borrowed[index] = message.borrowed();
    }
    return borrowed;
}

fn cloneChatMessage(allocator: std.mem.Allocator, message: ai_client.ChatMessage) !OwnedMessage {
    var owned = OwnedMessage{
        .role = message.role,
        .content = try allocator.dupe(u8, message.content),
        .content_parts = try cloneContentParts(allocator, message.content_parts),
        .tool_call_id = null,
        .tool_calls = &.{},
    };
    errdefer owned.deinit(allocator);
    if (message.tool_call_id) |tool_call_id| {
        owned.tool_call_id = try allocator.dupe(u8, tool_call_id);
    }
    if (message.tool_calls.len > 0) {
        owned.tool_calls = try cloneToolCalls(allocator, message.tool_calls);
    }
    return owned;
}

fn cloneContentParts(allocator: std.mem.Allocator, parts: []const ai_client.ChatContentPart) ![]ai_client.ChatContentPart {
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
        cloned[len] = switch (part) {
            .text => |text| .{ .text = try allocator.dupe(u8, text) },
            .image => |image| .{ .image = .{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            } },
        };
        len += 1;
    }
    return cloned;
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

fn cloneToolCalls(allocator: std.mem.Allocator, tool_calls: []const ai_client.ChatToolCall) ![]ai_client.ChatToolCall {
    const cloned = try allocator.alloc(ai_client.ChatToolCall, tool_calls.len);
    var len: usize = 0;
    errdefer {
        for (cloned[0..len]) |call| call.deinit(allocator);
        allocator.free(cloned);
    }
    for (tool_calls) |call| {
        cloned[len] = .{
            .id = try allocator.dupe(u8, call.id),
            .name = try allocator.dupe(u8, call.name),
            .arguments_json = try allocator.dupe(u8, call.arguments_json),
            .thought_signature = if (call.thought_signature) |signature| try allocator.dupe(u8, signature) else null,
        };
        len += 1;
    }
    return cloned;
}

fn enabledToolDefinitions(
    tool_set: ToolSet,
    custom_tools: []const ai_client.ChatToolDefinition,
    buf: *[all_tool_definitions.len]ai_client.ChatToolDefinition,
) []const ai_client.ChatToolDefinition {
    var len: usize = 0;
    for (all_tool_definitions) |definition| {
        if (!tool_set.contains(definition.name)) continue;
        if (customToolEnabled(custom_tools, definition.name)) continue;
        buf[len] = definition;
        len += 1;
    }
    return buf[0..len];
}

fn appendAssistantToolCallMessage(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(OwnedMessage),
    response: *ai_client.ChatCompletionResult,
) !void {
    const content = if (response.text) |text| text else try allocator.dupe(u8, "");
    errdefer allocator.free(content);
    response.text = null;
    try messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .tool_calls = response.tool_calls,
    });
}

fn finishTurnLifecycle(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(OwnedMessage),
    options: RunOptions,
    turn_context: TurnContext,
    active_provider: *?[]u8,
    active_model: *?[]u8,
    active_api_key: *?[]u8,
) !bool {
    if (options.prepare_next_turn) |callback| {
        if (options.turn_lifecycle_context) |context| {
            var update = try callback(context, turn_context);
            defer update.deinit(allocator);

            if (update.system_prompt) |system_prompt| {
                try applySystemPromptUpdate(allocator, messages, system_prompt);
                allocator.free(system_prompt);
                update.system_prompt = null;
            }
            if (update.provider) |provider| {
                replaceOwnedString(allocator, active_provider, provider);
                update.provider = null;
            }
            if (update.model) |model| {
                replaceOwnedString(allocator, active_model, model);
                update.model = null;
            }
            if (update.api_key) |api_key| {
                replaceOwnedString(allocator, active_api_key, api_key);
                update.api_key = null;
            }
        }
    }

    if (options.should_stop_after_turn) |callback| {
        if (options.turn_lifecycle_context) |context| {
            const updated_turn_context: TurnContext = .{
                .turn_index = turn_context.turn_index,
                .assistant_text = turn_context.assistant_text,
                .tool_results = turn_context.tool_results,
                .system_prompt = currentSystemPrompt(messages.items),
                .provider = active_provider.* orelse options.provider,
                .model = active_model.* orelse options.model,
            };
            return try callback(context, updated_turn_context);
        }
    }

    return false;
}

fn applySystemPromptUpdate(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(OwnedMessage),
    system_prompt: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, system_prompt, " \t\r\n");
    if (messages.items.len > 0 and messages.items[0].role == .system) {
        allocator.free(messages.items[0].content);
        messages.items[0].content = try allocator.dupe(u8, trimmed);
        return;
    }
    try messages.insert(allocator, 0, .{
        .role = .system,
        .content = try allocator.dupe(u8, trimmed),
    });
}

fn currentSystemPrompt(messages: []const OwnedMessage) []const u8 {
    if (messages.len > 0 and messages[0].role == .system) return messages[0].content;
    return "";
}

fn replaceOwnedString(allocator: std.mem.Allocator, target: *?[]u8, value: []u8) void {
    if (target.*) |previous| allocator.free(previous);
    target.* = value;
}

fn checkCancellation(options: RunOptions) !void {
    if (options.should_cancel) |callback| {
        if (options.cancellation_context) |context| {
            if (callback(context)) return error.AgentAborted;
        }
    }
}

// [FLOW_J_EXTENSION_EVENTS] Fire one notify-style lifecycle event from the prompt
// loop. Best-effort: an extension/runner failure must not abort the turn (upstream's
// emit() catches handler errors), so emission errors are swallowed. No-op when no
// callback is registered (the no-extensions hot path).
fn emitLifecycle(options: RunOptions, event_type: []const u8, fields_json: []const u8) void {
    const callback = options.on_lifecycle_event orelse return;
    const context = options.lifecycle_context orelse return;
    callback(context, .{ .type = event_type, .fields_json = fields_json }) catch {};
}

// [FLOW_J_EXTENSION_EVENTS] Build a one-shot JSON fields object for an emission on the
// fixed-size stack buffer (events carry a few small scalars). On overflow the event is
// still emitted with empty fields rather than dropped, matching the best-effort contract.
fn lifecycleTurnFields(buf: []u8, turn_index: usize) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    writer.print("{{\"turnIndex\":{d}}}", .{turn_index}) catch return "{}";
    return writer.buffered();
}

fn lifecycleProviderRequestFields(buf: []u8, provider: []const u8, model: []const u8) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    writer.writeAll("{\"payload\":{\"provider\":") catch return "{}";
    writeJsonStringValue(&writer, provider) catch return "{}";
    writer.writeAll(",\"model\":") catch return "{}";
    writeJsonStringValue(&writer, model) catch return "{}";
    writer.writeAll("}}") catch return "{}";
    return writer.buffered();
}

fn writeJsonStringValue(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11...12, 14...0x1f => try w.print("\\u{x:0>4}", .{byte}),
            else => try w.writeByte(byte),
        }
    }
    try w.writeByte('"');
}

fn emitToolUpdate(
    options: ?RunOptions,
    call: ai_client.ChatToolCall,
    content: []const u8,
    is_error: bool,
    terminate: bool,
) !void {
    try emitToolUpdateWithDetails(options, call, content, is_error, terminate, false, null, null);
}

fn emitToolUpdateWithDetails(
    options: ?RunOptions,
    call: ai_client.ChatToolCall,
    content: []const u8,
    is_error: bool,
    terminate: bool,
    truncated: bool,
    full_output_path: ?[]const u8,
    truncation: ?tools.ShellTruncationDetails,
) !void {
    if (options) |run_options| {
        if (run_options.on_tool_update) |callback| {
            if (run_options.tool_event_context) |context| {
                try callback(context, .{
                    .tool_call_id = call.id,
                    .tool_name = call.name,
                    .arguments_json = call.arguments_json,
                    .content = content,
                    .is_error = is_error,
                    .terminate = terminate,
                    .truncated = truncated,
                    .full_output_path = full_output_path,
                    .truncation = truncation,
                });
            }
        }
    }
}

const BashShellUpdateContext = struct {
    options: ?RunOptions,
    call: ai_client.ChatToolCall,
};

fn handleBashShellUpdate(ctx_ptr: *anyopaque, update: tools.ShellUpdate) anyerror!void {
    const ctx: *BashShellUpdateContext = @ptrCast(@alignCast(ctx_ptr));
    try emitToolUpdateWithDetails(ctx.options, ctx.call, update.output, false, false, update.truncated, update.full_output_path, update.truncation);
}

fn createToolResultTrace(
    allocator: std.mem.Allocator,
    call: ai_client.ChatToolCall,
    content: []const u8,
    content_parts: []const ai_client.ChatContentPart,
    is_error: bool,
    terminate: bool,
) !ToolResult {
    var result: ToolResult = .{
        .tool_call_id = try allocator.dupe(u8, call.id),
        .tool_name = &.{},
        .arguments_json = &.{},
        .content = &.{},
        .content_parts = &.{},
        .is_error = is_error,
        .terminate = terminate,
    };
    errdefer result.deinit(allocator);
    result.tool_name = try allocator.dupe(u8, call.name);
    result.arguments_json = try allocator.dupe(u8, call.arguments_json);
    result.content = try allocator.dupe(u8, content);
    result.content_parts = try cloneContentParts(allocator, content_parts);
    return result;
}

fn executeToolCallWithHooks(
    io: std.Io,
    allocator: std.mem.Allocator,
    call: ai_client.ChatToolCall,
    options: RunOptions,
) !ToolExecutionResult {
    try checkCancellation(options);

    var effective_call = call;
    var overridden_arguments_json: ?[]u8 = null;
    errdefer if (overridden_arguments_json) |arguments_json| allocator.free(arguments_json);

    if (options.before_tool_call) |callback| {
        if (options.tool_hook_context) |context| {
            var before_result = callback(context, call) catch |err| {
                return toolError(try std.fmt.allocPrint(allocator, "beforeToolCall failed: {s}", .{@errorName(err)}));
            };
            defer before_result.deinit(allocator);

            if (before_result.block) {
                const reason = before_result.reason orelse "Tool execution was blocked";
                return toolError(try allocator.dupe(u8, reason));
            }

            try checkCancellation(options);
            if (before_result.arguments_json) |arguments_json| {
                effective_call.arguments_json = arguments_json;
                overridden_arguments_json = arguments_json;
                before_result.arguments_json = null;
            }
        }
    }

    try checkCancellation(options);
    var result = try executeToolCallWithUpdates(io, allocator, effective_call, options);
    errdefer result.deinit(allocator);
    try checkCancellation(options);

    if (options.after_tool_call) |callback| {
        if (options.tool_hook_context) |context| {
            const provisional_result: ToolResult = .{
                .tool_call_id = effective_call.id,
                .tool_name = effective_call.name,
                .arguments_json = effective_call.arguments_json,
                .content = result.content,
                .content_parts = result.content_parts,
                .is_error = result.is_error,
                .terminate = result.terminate,
            };
            var after_result = callback(context, effective_call, provisional_result) catch |err| {
                allocator.free(result.content);
                freeContentParts(allocator, result.content_parts);
                result.content = try std.fmt.allocPrint(allocator, "afterToolCall failed: {s}", .{@errorName(err)});
                result.content_parts = &.{};
                result.is_error = true;
                result.terminate = false;
                result.arguments_json = overridden_arguments_json;
                overridden_arguments_json = null;
                return result;
            };
            defer after_result.deinit(allocator);

            if (after_result.content) |content| {
                allocator.free(result.content);
                freeContentParts(allocator, result.content_parts);
                result.content = content;
                result.content_parts = &.{};
                after_result.content = null;
            }
            if (after_result.content_parts.len > 0) {
                freeContentParts(allocator, result.content_parts);
                result.content_parts = after_result.content_parts;
                after_result.content_parts = &.{};
            }
            if (after_result.is_error) |is_error| result.is_error = is_error;
            if (after_result.terminate) |terminate| result.terminate = terminate;
        }
    }

    try checkCancellation(options);
    result.arguments_json = overridden_arguments_json;
    overridden_arguments_json = null;
    return result;
}

fn executeToolCall(
    io: std.Io,
    allocator: std.mem.Allocator,
    call: ai_client.ChatToolCall,
) !ToolExecutionResult {
    return executeToolCallWithUpdates(io, allocator, call, null);
}

fn executeToolCallWithUpdates(
    io: std.Io,
    allocator: std.mem.Allocator,
    call: ai_client.ChatToolCall,
    options: ?RunOptions,
) !ToolExecutionResult {
    if (options) |run_options| {
        if (run_options.execute_custom_tool) |callback| {
            if (customToolEnabled(run_options.custom_tools, call.name)) {
                const context = run_options.custom_tool_context orelse return toolError(try std.fmt.allocPrint(allocator, "Tool {s} is registered but has no executor context.", .{call.name}));
                return callback(context, call);
            }
        }
    }
    if (std.mem.eql(u8, call.name, "read")) return executeReadTool(io, allocator, call.arguments_json, readToolModelSupportsImages(options), readToolAutoResizeImages(options));
    if (std.mem.eql(u8, call.name, "bash")) return executeBashTool(io, allocator, call, options);
    if (std.mem.eql(u8, call.name, "edit")) return executeEditTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "write")) return executeWriteTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "grep")) return executeGrepTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "find")) return executeFindTool(io, allocator, call.arguments_json);
    if (std.mem.eql(u8, call.name, "ls")) return executeLsTool(io, allocator, call.arguments_json);
    return toolError(try std.fmt.allocPrint(allocator, "Tool {s} is not implemented in pi-zig yet.", .{call.name}));
}

fn customToolEnabled(custom_tools: []const ai_client.ChatToolDefinition, name: []const u8) bool {
    for (custom_tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return true;
    }
    return false;
}

fn readToolModelSupportsImages(options: ?RunOptions) bool {
    const run_options = options orelse return true;
    const model = models.find(run_options.provider, run_options.model) orelse return true;
    return model.input_image;
}

fn readToolAutoResizeImages(options: ?RunOptions) bool {
    const run_options = options orelse return true;
    return run_options.auto_resize_images;
}

fn executeReadTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8, model_supports_images: bool, auto_resize_images: bool) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "read", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "read", err));
    defer parsed.deinit();
    const path = requiredString(parsed.value, "path") orelse return toolError(try allocator.dupe(u8, "read tool arguments are missing path."));
    const detected_mime = detectImageMimeTypeForFile(io, path) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "read tool failed: {s}", .{@errorName(err)}));
    };
    if (detected_mime) |mime_type| {
        return executeReadImageTool(io, allocator, path, mime_type, model_supports_images, auto_resize_images) catch |err| {
            return toolError(try std.fmt.allocPrint(allocator, "read tool failed: {s}", .{@errorName(err)}));
        };
    }
    const offset = optionalUsize(parsed.value, "offset") catch return toolError(try allocator.dupe(u8, "read tool offset must be a non-negative number."));
    const limit = optionalUsize(parsed.value, "limit") catch return toolError(try allocator.dupe(u8, "read tool limit must be a non-negative number."));
    const content = tools.readFileForToolText(io, allocator, path, offset, limit) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "read tool failed: {s}", .{@errorName(err)}));
    };
    return toolOk(content);
}

fn executeReadImageTool(io: std.Io, allocator: std.mem.Allocator, path: []const u8, mime_type: []const u8, model_supports_images: bool, auto_resize_images: bool) !ToolExecutionResult {
    const bytes = try tools.readFile(io, allocator, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);

    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);

    // Upstream resizes images to fit within 2000x2000 and 4.5MB of base64 before sending them to
    // the model. pi-zig has no embedded image decoder, so it can only honor the encoded-size gate:
    // images already under the limit pass through unchanged (upstream's "already within limits"
    // path), and oversized images are omitted with the same note upstream emits when Photon cannot
    // produce an under-limit encoding.
    //
    // When `images.autoResize` is false the user has opted out of resizing entirely. pi-zig has no
    // resize worker, so honoring that setting means skipping the size gate altogether: the image
    // always passes through at its original size with no resize note, mirroring upstream's behavior
    // of sending the un-resized bytes when auto-resize is disabled.
    if (auto_resize_images and encoded_len >= image_resize_max_base64_bytes) {
        const content = if (model_supports_images)
            try std.fmt.allocPrint(allocator, "Read image file [{s}]\n{s}", .{ mime_type, image_resize_omitted_note })
        else
            try std.fmt.allocPrint(allocator, "Read image file [{s}]\n{s}\n{s}", .{ mime_type, image_resize_omitted_note, non_vision_image_note });
        return toolOk(content);
    }

    const encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);

    const mime_owned = try allocator.dupe(u8, mime_type);
    errdefer allocator.free(mime_owned);

    const content = if (model_supports_images)
        try std.fmt.allocPrint(allocator, "Read image file [{s}]", .{mime_type})
    else
        try std.fmt.allocPrint(allocator, "Read image file [{s}]\n{s}", .{ mime_type, non_vision_image_note });
    errdefer allocator.free(content);

    const content_note = try allocator.dupe(u8, content);
    errdefer allocator.free(content_note);

    const parts = try allocator.alloc(ai_client.ChatContentPart, 2);
    errdefer allocator.free(parts);
    parts[0] = .{ .text = content_note };
    parts[1] = .{ .image = .{
        .data = encoded,
        .mime_type = mime_owned,
    } };

    return .{
        .content = content,
        .content_parts = parts,
    };
}

fn executeBashTool(io: std.Io, allocator: std.mem.Allocator, call: ai_client.ChatToolCall, options: ?RunOptions) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "bash", call.arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "bash", err));
    defer parsed.deinit();

    if (parsed.value != .object) return toolError(try allocator.dupe(u8, "bash tool arguments must be a JSON object."));
    const command = requiredString(parsed.value, "command") orelse return toolError(try allocator.dupe(u8, "bash tool arguments are missing command."));
    const timeout_ms = optionalTimeoutMilliseconds(parsed.value, "timeout") catch return toolError(try allocator.dupe(u8, "bash tool timeout must be a non-negative finite number."));

    try emitToolUpdate(options, call, "", false, false);
    var update_context = BashShellUpdateContext{
        .options = options,
        .call = call,
    };
    const shell_result = tools.runShellCaptureWithUpdates(io, allocator, command, .{
        .update_context = &update_context,
        .on_update = handleBashShellUpdate,
        .timeout_ms = timeout_ms,
        .cancellation_context = if (options) |run_options| run_options.cancellation_context else null,
        .should_cancel = if (options) |run_options| run_options.should_cancel else null,
        .shell_path = if (options) |run_options| run_options.shell_path else null,
        .command_prefix = if (options) |run_options| run_options.shell_command_prefix else null,
        .env = if (options) |run_options| run_options.env else null,
    }) catch |err| {
        const shell_path = if (options) |run_options| run_options.shell_path else null;
        return toolError(try bashSetupErrorMessage(allocator, err, shell_path));
    };
    defer allocator.free(shell_result.output);

    const content = try allocator.dupe(u8, shell_result.output);
    errdefer allocator.free(content);
    const is_error = shell_result.exit_code == null or shell_result.exit_code.? != 0;
    try emitToolUpdateWithDetails(options, call, content, is_error, false, shell_result.truncated, shell_result.full_output_path, shell_result.truncation);
    return .{
        .content = content,
        .is_error = is_error,
    };
}

fn bashSetupErrorMessage(allocator: std.mem.Allocator, err: anyerror, custom_shell_path: ?[]const u8) ![]u8 {
    if (err == error.ShellPathNotFound) {
        if (custom_shell_path) |path| {
            return std.fmt.allocPrint(allocator, "bash tool failed before execution: Custom shell path not found: {s}", .{path});
        }
        return allocator.dupe(u8, "bash tool failed before execution: No bash shell found");
    }
    return std.fmt.allocPrint(allocator, "bash tool failed before execution: {s}", .{@errorName(err)});
}

fn executeEditTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "edit", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "edit", err));
    defer parsed.deinit();
    const path = requiredString(parsed.value, "path") orelse return toolError(try allocator.dupe(u8, "edit tool arguments are missing path."));
    const edits_value = fieldValue(parsed.value, "edits") orelse return toolError(try allocator.dupe(u8, "edit tool arguments are missing edits."));
    if (edits_value != .array) return toolError(try allocator.dupe(u8, "edit tool edits must be an array."));

    var edit_replacements: std.ArrayList(tools.EditReplacement) = .empty;
    defer edit_replacements.deinit(allocator);
    for (edits_value.array.items) |edit_value| {
        if (edit_value != .object) return toolError(try allocator.dupe(u8, "edit tool edits entries must be objects."));
        const old_text = requiredString(edit_value, "oldText") orelse return toolError(try allocator.dupe(u8, "edit tool edit is missing oldText."));
        const new_text = requiredString(edit_value, "newText") orelse return toolError(try allocator.dupe(u8, "edit tool edit is missing newText."));
        try edit_replacements.append(allocator, .{ .old_text = old_text, .new_text = new_text });
    }
    const outcome = tools.editFileManyResult(io, allocator, path, edit_replacements.items) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "edit tool failed: {s}", .{@errorName(err)}));
    };
    return .{ .content = outcome.message, .is_error = outcome.is_error };
}

fn executeWriteTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "write", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "write", err));
    defer parsed.deinit();
    const path = requiredString(parsed.value, "path") orelse return toolError(try allocator.dupe(u8, "write tool arguments are missing path."));
    const content = requiredString(parsed.value, "content") orelse return toolError(try allocator.dupe(u8, "write tool arguments are missing content."));
    const output = tools.writeFileForToolText(io, allocator, path, content) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "write tool failed: {s}", .{@errorName(err)}));
    };
    return toolOk(output);
}

fn executeGrepTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "grep", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "grep", err));
    defer parsed.deinit();
    const pattern = requiredString(parsed.value, "pattern") orelse return toolError(try allocator.dupe(u8, "grep tool arguments are missing pattern."));
    const path = optionalString(parsed.value, "path") orelse ".";
    const options: tools.GrepOptions = .{
        .glob = optionalString(parsed.value, "glob"),
        .ignore_case = optionalBool(parsed.value, "ignoreCase") catch return toolError(try allocator.dupe(u8, "grep tool ignoreCase must be a boolean.")),
        .literal = optionalBool(parsed.value, "literal") catch return toolError(try allocator.dupe(u8, "grep tool literal must be a boolean.")),
        .context = (optionalUsize(parsed.value, "context") catch return toolError(try allocator.dupe(u8, "grep tool context must be a non-negative number."))) orelse 0,
        .limit = (optionalUsize(parsed.value, "limit") catch return toolError(try allocator.dupe(u8, "grep tool limit must be a non-negative number."))) orelse 100,
    };
    const content = tools.grepText(io, allocator, pattern, path, options) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "grep tool failed: {s}", .{@errorName(err)}));
    };
    return toolOk(content);
}

fn executeFindTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "find", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "find", err));
    defer parsed.deinit();
    const pattern = requiredString(parsed.value, "pattern") orelse return toolError(try allocator.dupe(u8, "find tool arguments are missing pattern."));
    const path = optionalString(parsed.value, "path") orelse ".";
    const limit = (optionalUsize(parsed.value, "limit") catch return toolError(try allocator.dupe(u8, "find tool limit must be a non-negative number."))) orelse 1000;
    const content = tools.findFilesText(io, allocator, pattern, path, limit) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "find tool failed: {s}", .{@errorName(err)}));
    };
    return toolOk(content);
}

fn executeLsTool(io: std.Io, allocator: std.mem.Allocator, arguments_json: []const u8) !ToolExecutionResult {
    var parsed = parseArguments(allocator, "ls", arguments_json) catch |err| return toolError(try invalidJsonMessage(allocator, "ls", err));
    defer parsed.deinit();
    const path = optionalString(parsed.value, "path") orelse ".";
    const limit = (optionalUsize(parsed.value, "limit") catch return toolError(try allocator.dupe(u8, "ls tool limit must be a non-negative number."))) orelse 500;
    const content = tools.listDirText(io, allocator, path, limit) catch |err| {
        return toolError(try std.fmt.allocPrint(allocator, "ls tool failed: {s}", .{@errorName(err)}));
    };
    return toolOk(content);
}

fn parseArguments(allocator: std.mem.Allocator, tool_name: []const u8, arguments_json: []const u8) !std.json.Parsed(std.json.Value) {
    _ = tool_name;
    return std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
}

fn invalidJsonMessage(allocator: std.mem.Allocator, tool_name: []const u8, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} tool argument JSON is invalid: {s}", .{ tool_name, @errorName(err) });
}

fn toolOk(content: []u8) ToolExecutionResult {
    return .{ .content = content };
}

fn toolError(content: []u8) ToolExecutionResult {
    return .{ .content = content, .is_error = true };
}

fn detectImageMimeTypeForFile(io: std.Io, path: []const u8) !?[]const u8 {
    // Sniff only the leading bytes upstream reads (mime.ts), regardless of file size.
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    // Use a reader buffer distinct from the sniff destination. Passing the reader's own
    // buffer as the read target aliases memory and corrupts reads that fill the buffer
    // (latent: F08's detection tests used <4100B PNGs; F06's 4.5MB fixtures surfaced it).
    var reader_buf: [tools.image_type_sniff_bytes]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    var buf: [tools.image_type_sniff_bytes]u8 = undefined;
    const read_len = reader.interface.readSliceShort(&buf) catch 0;
    return tools.detectImageMimeType(buf[0..read_len]);
}

fn fieldValue(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn requiredString(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = fieldValue(value, name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn optionalString(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = fieldValue(value, name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn optionalBool(value: std.json.Value, name: []const u8) !bool {
    const field = fieldValue(value, name) orelse return false;
    if (field != .bool) return error.InvalidToolArgument;
    return field.bool;
}

fn optionalUsize(value: std.json.Value, name: []const u8) !?usize {
    const field = fieldValue(value, name) orelse return null;
    switch (field) {
        .integer => |integer| {
            if (integer < 0) return error.InvalidToolArgument;
            return @intCast(integer);
        },
        .float => |float| {
            if (float < 0 or @floor(float) != float) return error.InvalidToolArgument;
            return @intFromFloat(float);
        },
        else => return error.InvalidToolArgument,
    }
}

fn optionalTimeoutMilliseconds(value: std.json.Value, name: []const u8) !?i64 {
    const field = fieldValue(value, name) orelse return null;
    const seconds: f64 = switch (field) {
        .integer => |integer| blk: {
            if (integer < 0) return error.InvalidToolArgument;
            break :blk @floatFromInt(integer);
        },
        .float => |float| blk: {
            if (float < 0 or !std.math.isFinite(float)) return error.InvalidToolArgument;
            break :blk float;
        },
        else => return error.InvalidToolArgument,
    };
    if (seconds <= 0) return null;
    const milliseconds = @round(seconds * 1000.0);
    if (milliseconds > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return error.InvalidToolArgument;
    return @max(1, @as(i64, @intFromFloat(milliseconds)));
}

test "[FLOW_J_EXTENSION_EVENTS] lifecycle field builders emit upstream-shaped JSON" {
    var turn_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"turnIndex\":0}", lifecycleTurnFields(&turn_buf, 0));
    try std.testing.expectEqualStrings("{\"turnIndex\":7}", lifecycleTurnFields(&turn_buf, 7));

    var provider_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"payload\":{\"provider\":\"openai\",\"model\":\"gpt-4o\"}}",
        lifecycleProviderRequestFields(&provider_buf, "openai", "gpt-4o"),
    );
    // A provider/model with a quote is escaped so the fields stay valid JSON.
    try std.testing.expectEqualStrings(
        "{\"payload\":{\"provider\":\"a\\\"b\",\"model\":\"m\"}}",
        lifecycleProviderRequestFields(&provider_buf, "a\"b", "m"),
    );
}

test "[FLOW_J_EXTENSION_EVENTS] emitLifecycle fires through the registered callback" {
    const Collector = struct {
        types: std.ArrayList([]const u8) = .empty,
        allocator: std.mem.Allocator,
        fn cb(ctx: *anyopaque, event: LifecycleEmitEvent) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.types.append(self.allocator, try self.allocator.dupe(u8, event.type));
        }
        fn deinit(self: *@This()) void {
            for (self.types.items) |t| self.allocator.free(t);
            self.types.deinit(self.allocator);
        }
    };
    var collector = Collector{ .allocator = std.testing.allocator };
    defer collector.deinit();
    const options: RunOptions = .{
        .provider = "p",
        .model = "m",
        .api_key = "k",
        .prompt = "hi",
        .lifecycle_context = &collector,
        .on_lifecycle_event = Collector.cb,
    };
    emitLifecycle(options, "turn_start", "{}");
    emitLifecycle(options, "after_provider_response", "{\"status\":200}");
    try std.testing.expectEqual(@as(usize, 2), collector.types.items.len);
    try std.testing.expectEqualStrings("turn_start", collector.types.items[0]);
    try std.testing.expectEqualStrings("after_provider_response", collector.types.items[1]);

    // With no callback registered the emission is a cheap no-op (no crash).
    const no_cb: RunOptions = .{ .provider = "p", .model = "m", .api_key = "k", .prompt = "hi" };
    emitLifecycle(no_cb, "turn_start", "{}");
}

test "unsupported tool call returns a tool result instead of aborting" {
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_unsupported"),
        .name = try std.testing.allocator.dupe(u8, "unknown_tool"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCall(std.testing.io, std.testing.allocator, call);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("Tool unknown_tool is not implemented in pi-zig yet.", result.content);
}

test "failed tool calls are marked as errors" {
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_missing_read"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"path\":\"zig-out/does-not-exist-for-agent-test.txt\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCall(std.testing.io, std.testing.allocator, call);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "read tool failed:"));
}

// Canonical 1x1 PNG used by image read tests; matches the verify-basic.mjs
// fixture so magic-byte detection (tools.detectImageMimeType) recognizes it.
const test_png_bytes = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x04, 0x00, 0x00, 0x00, 0xb5, 0x1c, 0x0c,
    0x02, 0x00, 0x00, 0x00, 0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xfc, 0xff, 0x1f, 0x00,
    0x03, 0x03, 0x02, 0x00, 0xef, 0xbf, 0xa7, 0xdb, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
    0xae, 0x42, 0x60, 0x82,
};
const test_png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=";

test "read image appends non-vision note and keeps image parts for provider downgrade" {
    const path = "zig-out/pi-zig-read-nonvision-test.png";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try tools.writeFile(std.testing.io, path, &test_png_bytes);

    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_read_nonvision_image"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path}),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithUpdates(std.testing.io, std.testing.allocator, call, .{
        .provider = "amazon-bedrock",
        .model = "amazon.nova-micro-v1:0",
        .api_key = "",
        .prompt = "",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "Read image file [image/png]\n" ++ non_vision_image_note,
        result.content,
    );
    try std.testing.expectEqual(@as(usize, 2), result.content_parts.len);
    switch (result.content_parts[0]) {
        .text => |text| try std.testing.expectEqualStrings("Read image file [image/png]\n" ++ non_vision_image_note, text),
        .image => return error.ExpectedTextContentPart,
    }
    switch (result.content_parts[1]) {
        .image => |image| {
            try std.testing.expectEqualStrings("image/png", image.mime_type);
            try std.testing.expectEqualStrings(test_png_base64, image.data);
        },
        .text => return error.ExpectedImageContentPart,
    }
}

test "read image keeps image parts for vision model" {
    const path = "zig-out/pi-zig-read-vision-test.png";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try tools.writeFile(std.testing.io, path, &test_png_bytes);

    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_read_vision_image"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path}),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithUpdates(std.testing.io, std.testing.allocator, call, .{
        .provider = "amazon-bedrock",
        .model = "amazon.nova-pro-v1:0",
        .api_key = "",
        .prompt = "",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("Read image file [image/png]", result.content);
    try std.testing.expectEqual(@as(usize, 2), result.content_parts.len);
    switch (result.content_parts[0]) {
        .text => |text| try std.testing.expectEqualStrings("Read image file [image/png]", text),
        .image => return error.ExpectedTextContentPart,
    }
    switch (result.content_parts[1]) {
        .image => |image| {
            try std.testing.expectEqualStrings("image/png", image.mime_type);
            try std.testing.expectEqualStrings(test_png_base64, image.data);
        },
        .text => return error.ExpectedImageContentPart,
    }
}

test "read image omits oversized image with upstream resize note" {
    const path = "zig-out/pi-zig-read-oversized-image-test.png";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const oversized = try std.testing.allocator.alloc(u8, image_resize_max_base64_bytes);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'A');
    // Valid PNG header (signature + IHDR length 13 + "IHDR") so magic-byte detection
    // (tools.detectImageMimeType) recognizes this oversized payload as image/png; the
    // 'A' padding keeps it above the resize size gate so it is omitted like upstream.
    const png_header = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52 };
    @memcpy(oversized[0..png_header.len], &png_header);
    try tools.writeFile(std.testing.io, path, oversized);

    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_read_oversized_image"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path}),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithUpdates(std.testing.io, std.testing.allocator, call, .{
        .provider = "amazon-bedrock",
        .model = "amazon.nova-pro-v1:0",
        .api_key = "",
        .prompt = "",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "Read image file [image/png]\n" ++ image_resize_omitted_note,
        result.content,
    );
    try std.testing.expectEqual(@as(usize, 0), result.content_parts.len);
}

test "read oversized image for non-vision model appends both resize and non-vision notes" {
    const path = "zig-out/pi-zig-read-oversized-nonvision-test.png";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const oversized = try std.testing.allocator.alloc(u8, image_resize_max_base64_bytes);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'A');
    // Valid PNG header (signature + IHDR length 13 + "IHDR") so magic-byte detection
    // (tools.detectImageMimeType) recognizes this oversized payload as image/png; the
    // 'A' padding keeps it above the resize size gate so it is omitted like upstream.
    const png_header = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52 };
    @memcpy(oversized[0..png_header.len], &png_header);
    try tools.writeFile(std.testing.io, path, oversized);

    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_read_oversized_nonvision_image"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path}),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithUpdates(std.testing.io, std.testing.allocator, call, .{
        .provider = "amazon-bedrock",
        .model = "amazon.nova-micro-v1:0",
        .api_key = "",
        .prompt = "",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "Read image file [image/png]\n" ++ image_resize_omitted_note ++ "\n" ++ non_vision_image_note,
        result.content,
    );
    try std.testing.expectEqual(@as(usize, 0), result.content_parts.len);
}

test "read oversized image passes through unchanged when auto-resize is disabled" {
    // images.autoResize=false threads through RunOptions.auto_resize_images=false. pi-zig has no
    // resize worker, so disabling auto-resize means the read-tool skips the encoded-size gate
    // entirely: even an oversized image keeps its image part and emits no resize-omitted note,
    // distinguishing this path from the default (auto_resize_images=true) which omits it.
    const path = "zig-out/pi-zig-read-oversized-no-resize-test.png";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const oversized = try std.testing.allocator.alloc(u8, image_resize_max_base64_bytes);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'A');
    const png_header = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52 };
    @memcpy(oversized[0..png_header.len], &png_header);
    try tools.writeFile(std.testing.io, path, oversized);

    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_read_oversized_no_resize_image"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path}),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithUpdates(std.testing.io, std.testing.allocator, call, .{
        .provider = "amazon-bedrock",
        .model = "amazon.nova-pro-v1:0",
        .api_key = "",
        .prompt = "",
        .auto_resize_images = false,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    // No resize-omitted note: the bytes pass through at original size.
    try std.testing.expectEqualStrings("Read image file [image/png]", result.content);
    try std.testing.expect(std.mem.indexOf(u8, result.content, image_resize_omitted_note) == null);
    try std.testing.expectEqual(@as(usize, 2), result.content_parts.len);
    switch (result.content_parts[1]) {
        .image => |image| try std.testing.expectEqualStrings("image/png", image.mime_type),
        .text => return error.ExpectedImageContentPart,
    }
}

test "read oversized image keeps default resize-omit when auto-resize stays enabled" {
    // Companion to the auto_resize_images=false test above: with the default RunOptions
    // (auto_resize_images=true) the same oversized image is omitted with the resize note, proving
    // the flag — not some unrelated change — is what flips the behavior.
    const path = "zig-out/pi-zig-read-oversized-resize-default-test.png";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const oversized = try std.testing.allocator.alloc(u8, image_resize_max_base64_bytes);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'A');
    const png_header = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52 };
    @memcpy(oversized[0..png_header.len], &png_header);
    try tools.writeFile(std.testing.io, path, oversized);

    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_read_oversized_resize_default_image"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path}),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithUpdates(std.testing.io, std.testing.allocator, call, .{
        .provider = "amazon-bedrock",
        .model = "amazon.nova-pro-v1:0",
        .api_key = "",
        .prompt = "",
        // auto_resize_images defaults to true.
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "Read image file [image/png]\n" ++ image_resize_omitted_note,
        result.content,
    );
    try std.testing.expectEqual(@as(usize, 0), result.content_parts.len);
}

test "invalid tool argument JSON returns a tool error result" {
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_invalid_bash_json"),
        .name = try std.testing.allocator.dupe(u8, "bash"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"command\":"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCall(std.testing.io, std.testing.allocator, call);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(!result.terminate);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "bash tool argument JSON is invalid:"));
}

test "bash missing custom shell path returns upstream-shaped setup error" {
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_missing_shell"),
        .name = try std.testing.allocator.dupe(u8, "bash"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"command\":\"printf should-not-run\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithHooks(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .shell_path = "zig-out/pi-zig-missing-shell",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings(
        "bash tool failed before execution: Custom shell path not found: zig-out/pi-zig-missing-shell",
        result.content,
    );
}

test "before tool hook can block execution with an error result" {
    const HookContext = struct {
        allocator: std.mem.Allocator,
        before_calls: usize = 0,
        after_calls: usize = 0,
    };
    const Hooks = struct {
        fn before(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall) anyerror!BeforeToolCallResult {
            const ctx: *HookContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.before_calls += 1;
            try std.testing.expectEqualStrings("bash", call.name);
            return .{
                .block = true,
                .reason = try ctx.allocator.dupe(u8, "blocked by before hook"),
            };
        }

        fn after(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall, result: ToolResult) anyerror!AfterToolCallResult {
            _ = call;
            _ = result;
            const ctx: *HookContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.after_calls += 1;
            return .{};
        }
    };

    var ctx = HookContext{ .allocator = std.testing.allocator };
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_blocked"),
        .name = try std.testing.allocator.dupe(u8, "bash"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"command\":\"printf should-not-run\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithHooks(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .tool_hook_context = &ctx,
        .before_tool_call = Hooks.before,
        .after_tool_call = Hooks.after,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("blocked by before hook", result.content);
    try std.testing.expectEqual(@as(usize, 1), ctx.before_calls);
    try std.testing.expectEqual(@as(usize, 0), ctx.after_calls);
}

test "before tool hook can replace arguments before execution" {
    const HookContext = struct {
        allocator: std.mem.Allocator,
        before_calls: usize = 0,
    };
    const Hooks = struct {
        fn before(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall) anyerror!BeforeToolCallResult {
            const ctx: *HookContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.before_calls += 1;
            try std.testing.expectEqualStrings("read", call.name);
            return .{
                .arguments_json = try ctx.allocator.dupe(u8, "{\"path\":\"build.zig\",\"limit\":1}"),
            };
        }
    };

    var ctx = HookContext{ .allocator = std.testing.allocator };
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_rewrite_args"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"path\":\"zig-out/does-not-exist-for-agent-test.txt\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithHooks(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .tool_hook_context = &ctx,
        .before_tool_call = Hooks.before,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "const std") != null);
    try std.testing.expectEqualStrings("{\"path\":\"build.zig\",\"limit\":1}", result.arguments_json.?);
    try std.testing.expectEqual(@as(usize, 1), ctx.before_calls);
}

test "after tool hook can override content error state and termination" {
    const HookContext = struct {
        allocator: std.mem.Allocator,
        after_calls: usize = 0,
    };
    const Hooks = struct {
        fn after(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall, result: ToolResult) anyerror!AfterToolCallResult {
            const ctx: *HookContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.after_calls += 1;
            try std.testing.expectEqualStrings("read", call.name);
            try std.testing.expect(result.is_error);
            try std.testing.expect(std.mem.startsWith(u8, result.content, "read tool failed:"));
            return .{
                .content = try ctx.allocator.dupe(u8, "patched by after hook"),
                .is_error = false,
                .terminate = true,
            };
        }
    };

    var ctx = HookContext{ .allocator = std.testing.allocator };
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_after_patch"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"path\":\"zig-out/does-not-exist-for-agent-test.txt\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithHooks(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .tool_hook_context = &ctx,
        .after_tool_call = Hooks.after,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.terminate);
    try std.testing.expectEqualStrings("patched by after hook", result.content);
    try std.testing.expectEqual(@as(usize, 1), ctx.after_calls);
}

test "bash tool emits execution update callbacks" {
    const UpdateContext = struct {
        allocator: std.mem.Allocator,
        updates: usize = 0,
        last_content: []u8 = &.{},
        saw_empty_start: bool = false,

        fn deinit(self: *@This()) void {
            if (self.last_content.len > 0) self.allocator.free(self.last_content);
        }
    };
    const Hooks = struct {
        fn update(ctx_ptr: *anyopaque, update_event: ToolUpdate) anyerror!void {
            const ctx: *UpdateContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.updates += 1;
            if (update_event.content.len == 0) ctx.saw_empty_start = true;
            if (ctx.last_content.len > 0) ctx.allocator.free(ctx.last_content);
            ctx.last_content = try ctx.allocator.dupe(u8, update_event.content);
            try std.testing.expectEqualStrings("bash", update_event.tool_name);
            try std.testing.expectEqualStrings("call_bash_updates", update_event.tool_call_id);
        }
    };

    var ctx = UpdateContext{ .allocator = std.testing.allocator };
    defer ctx.deinit();
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_bash_updates"),
        .name = try std.testing.allocator.dupe(u8, "bash"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"command\":\"printf update-ok\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithUpdates(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .tool_event_context = &ctx,
        .on_tool_update = Hooks.update,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("update-ok", result.content);
    try std.testing.expect(ctx.updates >= 2);
    try std.testing.expect(ctx.saw_empty_start);
    try std.testing.expectEqualStrings("update-ok", ctx.last_content);
}

test "bash tool emits intermediate output update snapshots" {
    const UpdateContext = struct {
        updates: usize = 0,
        saw_empty_start: bool = false,
        saw_first_snapshot: bool = false,
        saw_combined_snapshot: bool = false,
    };
    const Hooks = struct {
        fn update(ctx_ptr: *anyopaque, update_event: ToolUpdate) anyerror!void {
            const ctx: *UpdateContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.updates += 1;
            if (update_event.content.len == 0) ctx.saw_empty_start = true;
            if (std.mem.eql(u8, update_event.content, "slow-first")) ctx.saw_first_snapshot = true;
            if (std.mem.indexOf(u8, update_event.content, "slow-firstslow-second") != null) ctx.saw_combined_snapshot = true;
            try std.testing.expectEqualStrings("bash", update_event.tool_name);
            try std.testing.expectEqualStrings("call_bash_intermediate_updates", update_event.tool_call_id);
        }
    };

    var ctx = UpdateContext{};
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_bash_intermediate_updates"),
        .name = try std.testing.allocator.dupe(u8, "bash"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"command\":\"printf slow-first; sleep 0.2; printf slow-second\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithUpdates(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .tool_event_context = &ctx,
        .on_tool_update = Hooks.update,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("slow-firstslow-second", result.content);
    try std.testing.expect(ctx.updates >= 3);
    try std.testing.expect(ctx.saw_empty_start);
    try std.testing.expect(ctx.saw_first_snapshot);
    try std.testing.expect(ctx.saw_combined_snapshot);
}

test "bash tool timeout returns partial output as an error result" {
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_bash_timeout"),
        .name = try std.testing.allocator.dupe(u8, "bash"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"command\":\"printf before-timeout; sleep 1; printf after-timeout\",\"timeout\":0.1}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithUpdates(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "before-timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "after-timeout") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Command timed out after 0.100 seconds") != null);
}

test "bash tool cancellation stops a running shell command" {
    const CancelContext = struct {
        checks: usize = 0,
    };
    const Hooks = struct {
        fn shouldCancel(ctx_ptr: *anyopaque) bool {
            const ctx: *CancelContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.checks += 1;
            return ctx.checks >= 4;
        }
    };

    var ctx = CancelContext{};
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_bash_cancel"),
        .name = try std.testing.allocator.dupe(u8, "bash"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"command\":\"printf before-cancel; sleep 1; printf after-cancel\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCallWithUpdates(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .cancellation_context = &ctx,
        .should_cancel = Hooks.shouldCancel,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "before-cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "after-cancel") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Command cancelled") != null);
    try std.testing.expect(ctx.checks >= 4);
}

test "prepare next turn can update request state before should-stop runs" {
    const LifecycleContext = struct {
        allocator: std.mem.Allocator,
        prepare_calls: usize = 0,
        stop_calls: usize = 0,
    };
    const Hooks = struct {
        fn prepare(ctx_ptr: *anyopaque, turn: TurnContext) anyerror!PrepareNextTurnResult {
            const ctx: *LifecycleContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.prepare_calls += 1;
            try std.testing.expectEqual(@as(usize, 3), turn.turn_index);
            try std.testing.expectEqualStrings("first system", turn.system_prompt);
            try std.testing.expectEqualStrings("openai", turn.provider);
            try std.testing.expectEqualStrings("first-model", turn.model);
            return .{
                .system_prompt = try ctx.allocator.dupe(u8, "second system"),
                .provider = try ctx.allocator.dupe(u8, "openrouter"),
                .model = try ctx.allocator.dupe(u8, "second-model"),
                .api_key = try ctx.allocator.dupe(u8, "second-key"),
            };
        }

        fn shouldStop(ctx_ptr: *anyopaque, turn: TurnContext) anyerror!bool {
            const ctx: *LifecycleContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.stop_calls += 1;
            try std.testing.expectEqualStrings("second system", turn.system_prompt);
            try std.testing.expectEqualStrings("openrouter", turn.provider);
            try std.testing.expectEqualStrings("second-model", turn.model);
            try std.testing.expectEqualStrings("assistant asked for a tool", turn.assistant_text);
            try std.testing.expectEqual(@as(usize, 1), turn.tool_results.len);
            try std.testing.expectEqualStrings("call_lifecycle", turn.tool_results[0].tool_call_id);
            return true;
        }
    };

    var messages: std.ArrayList(OwnedMessage) = .empty;
    defer {
        for (messages.items) |message| message.deinit(std.testing.allocator);
        messages.deinit(std.testing.allocator);
    }
    try messages.append(std.testing.allocator, .{
        .role = .system,
        .content = try std.testing.allocator.dupe(u8, "first system"),
    });
    try messages.append(std.testing.allocator, .{
        .role = .assistant,
        .content = try std.testing.allocator.dupe(u8, "assistant asked for a tool"),
    });

    var tool_results = [_]ToolResult{.{
        .tool_call_id = try std.testing.allocator.dupe(u8, "call_lifecycle"),
        .tool_name = try std.testing.allocator.dupe(u8, "read"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{}"),
        .content = try std.testing.allocator.dupe(u8, "ok"),
    }};
    defer tool_results[0].deinit(std.testing.allocator);
    var lifecycle = LifecycleContext{ .allocator = std.testing.allocator };
    var active_provider: ?[]u8 = null;
    defer if (active_provider) |provider| std.testing.allocator.free(provider);
    var active_model: ?[]u8 = null;
    defer if (active_model) |model| std.testing.allocator.free(model);
    var active_api_key: ?[]u8 = null;
    defer if (active_api_key) |api_key| std.testing.allocator.free(api_key);

    const should_stop = try finishTurnLifecycle(std.testing.allocator, &messages, .{
        .provider = "openai",
        .model = "first-model",
        .api_key = "first-key",
        .prompt = "",
        .turn_lifecycle_context = &lifecycle,
        .prepare_next_turn = Hooks.prepare,
        .should_stop_after_turn = Hooks.shouldStop,
    }, .{
        .turn_index = 3,
        .assistant_text = messages.items[1].content,
        .tool_results = &tool_results,
        .system_prompt = currentSystemPrompt(messages.items),
        .provider = "openai",
        .model = "first-model",
    }, &active_provider, &active_model, &active_api_key);

    try std.testing.expect(should_stop);
    try std.testing.expectEqual(@as(usize, 1), lifecycle.prepare_calls);
    try std.testing.expectEqual(@as(usize, 1), lifecycle.stop_calls);
    try std.testing.expectEqualStrings("second system", messages.items[0].content);
    try std.testing.expectEqualStrings("openrouter", active_provider.?);
    try std.testing.expectEqualStrings("second-model", active_model.?);
    try std.testing.expectEqualStrings("second-key", active_api_key.?);
}

test "prepare next turn inserts a system prompt when the transcript has none" {
    var messages: std.ArrayList(OwnedMessage) = .empty;
    defer {
        for (messages.items) |message| message.deinit(std.testing.allocator);
        messages.deinit(std.testing.allocator);
    }
    try messages.append(std.testing.allocator, .{
        .role = .user,
        .content = try std.testing.allocator.dupe(u8, "hello"),
    });

    try applySystemPromptUpdate(std.testing.allocator, &messages, " inserted system ");

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expect(messages.items[0].role == .system);
    try std.testing.expect(messages.items[1].role == .user);
    try std.testing.expectEqualStrings("inserted system", messages.items[0].content);
}

test "agent run checks cancellation before provider requests" {
    const CancelContext = struct {
        checks: usize = 0,
    };
    const Hooks = struct {
        fn shouldCancel(ctx_ptr: *anyopaque) bool {
            const ctx: *CancelContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.checks += 1;
            return true;
        }
    };

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var ctx = CancelContext{};

    const result = runPrompt(std.testing.io, std.testing.allocator, &env, .{
        .provider = "openai",
        .model = "cancel-model",
        .api_key = "fake-key",
        .prompt = "should not reach provider",
        .cancellation_context = &ctx,
        .should_cancel = Hooks.shouldCancel,
    });

    try std.testing.expectError(error.AgentAborted, result);
    try std.testing.expectEqual(@as(usize, 1), ctx.checks);
}

test "tool execution checks cancellation after before hook before executing" {
    const CancelContext = struct {
        allocator: std.mem.Allocator,
        checks: usize = 0,
        before_calls: usize = 0,
    };
    const Hooks = struct {
        fn shouldCancel(ctx_ptr: *anyopaque) bool {
            const ctx: *CancelContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.checks += 1;
            return ctx.checks >= 2;
        }

        fn before(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall) anyerror!BeforeToolCallResult {
            const ctx: *CancelContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.before_calls += 1;
            try std.testing.expectEqualStrings("bash", call.name);
            return .{
                .arguments_json = try ctx.allocator.dupe(u8, "{\"command\":\"printf should-not-run\"}"),
            };
        }
    };

    var ctx = CancelContext{ .allocator = std.testing.allocator };
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_cancel_after_before"),
        .name = try std.testing.allocator.dupe(u8, "bash"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"command\":\"printf original\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = executeToolCallWithHooks(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .tool_hook_context = &ctx,
        .before_tool_call = Hooks.before,
        .cancellation_context = &ctx,
        .should_cancel = Hooks.shouldCancel,
    });

    try std.testing.expectError(error.AgentAborted, result);
    try std.testing.expectEqual(@as(usize, 2), ctx.checks);
    try std.testing.expectEqual(@as(usize, 1), ctx.before_calls);
}

test "custom tool with built-in name overrides provider definition and execution" {
    const custom_tools = [_]ai_client.ChatToolDefinition{.{
        .name = "bash",
        .description = "Custom bash override",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}},\"required\":[\"value\"]}",
    }};
    var definitions_buf: [all_tool_definitions.len]ai_client.ChatToolDefinition = undefined;
    const definitions = enabledToolDefinitions(.all, &custom_tools, &definitions_buf);
    for (definitions) |definition| {
        try std.testing.expect(!std.mem.eql(u8, definition.name, "bash"));
    }

    const CustomContext = struct {
        allocator: std.mem.Allocator,
        calls: usize = 0,
    };
    const Hooks = struct {
        fn execute(ctx_ptr: *anyopaque, call: ai_client.ChatToolCall) anyerror!ToolExecutionResult {
            const ctx: *CustomContext = @ptrCast(@alignCast(ctx_ptr));
            ctx.calls += 1;
            try std.testing.expectEqualStrings("bash", call.name);
            try std.testing.expect(std.mem.indexOf(u8, call.arguments_json, "\"value\":\"unit-override\"") != null);
            return .{ .content = try ctx.allocator.dupe(u8, "custom bash override") };
        }
    };

    var ctx = CustomContext{ .allocator = std.testing.allocator };
    var call = ai_client.ChatToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_custom_bash"),
        .name = try std.testing.allocator.dupe(u8, "bash"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"value\":\"unit-override\"}"),
    };
    defer call.deinit(std.testing.allocator);

    var result = try executeToolCallWithUpdates(std.testing.io, std.testing.allocator, call, .{
        .provider = "",
        .model = "",
        .api_key = "",
        .prompt = "",
        .custom_tools = &custom_tools,
        .custom_tool_context = &ctx,
        .execute_custom_tool = Hooks.execute,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
    try std.testing.expectEqualStrings("custom bash override", result.content);
    try std.testing.expect(!result.is_error);
}

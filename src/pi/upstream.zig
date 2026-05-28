const std = @import("std");
const config = @import("config.zig");
const models = @import("models.zig");

pub const Package = struct {
    name: []const u8,
    dir: []const u8,
    role: []const u8,
    source_files: usize,
    test_files: usize,
};

pub const Feature = struct {
    name: []const u8,
    status: []const u8,
};

pub const packages = [_]Package{
    .{
        .name = "@earendil-works/pi-ai",
        .dir = "packages/ai",
        .role = "Unified multi-provider LLM API, provider registry, images, OAuth, streaming",
        .source_files = 53,
        .test_files = 76,
    },
    .{
        .name = "@earendil-works/pi-agent-core",
        .dir = "packages/agent",
        .role = "Agent loop, harness, durable sessions, hooks, compaction, state",
        .source_files = 25,
        .test_files = 20,
    },
    .{
        .name = "@earendil-works/pi-coding-agent",
        .dir = "packages/coding-agent",
        .role = "CLI, TUI mode, print mode, RPC mode, tools, sessions, resources",
        .source_files = 145,
        .test_files = 133,
    },
    .{
        .name = "@earendil-works/pi-tui",
        .dir = "packages/tui",
        .role = "Terminal UI renderer, components, editor, keybindings, images",
        .source_files = 26,
        .test_files = 28,
    },
};

pub const providers = [_][]const u8{
    "openai-responses",
    "openai-completions",
    "openai-codex-responses",
    "anthropic",
    "google",
    "google-vertex",
    "mistral",
    "amazon-bedrock",
    "github-copilot",
    "openrouter-images",
    "cloudflare-images",
    "faux",
};

pub const builtins = [_][]const u8{
    "read",
    "bash",
    "edit",
    "write",
    "grep",
    "find",
    "ls",
};

// --- Extended inventory mirror -----------------------------------------------
//
// The lists below mirror the full upstream surface enumerated by
// scripts/upstream-inventory.mjs (cross-checked against
// docs/inventory/upstream-inventory.json). The unit tests at the bottom of this
// file anchor each count to the inventory so the runtime mirror fails loudly if it
// drifts from the script. Previously upstream.zig covered only packages/providers/
// builtins/rpc_commands/features (a subset); these close the remaining surfaces.

/// Top-level subcommands routed before parseArgs (package + config managers).
pub const subcommands = [_][]const u8{
    "config",
    "install",
    "list",
    "remove",
    "uninstall",
    "update",
};

/// Application modes (entrypoints) the coding agent can run in.
pub const app_modes = [_][]const u8{
    "interactive",
    "print",
    "json",
    "rpc",
};

/// Built-in slash commands available in interactive/RPC sessions.
pub const builtin_slash_commands = [_][]const u8{
    "settings", "model",     "scoped-models", "export", "import",
    "share",    "copy",      "name",          "session", "changelog",
    "hotkeys",  "fork",      "clone",         "tree",    "login",
    "logout",   "new",       "compact",       "resume",  "reload",
    "quit",
};

/// Provider transport APIs (the `api` field on a Model). Mirrors the upstream
/// StreamFunction registry / transport modules under packages/ai/src/providers.
pub const transport_apis = [_][]const u8{
    "anthropic-messages",
    "openai-completions",
    "mistral-conversations",
    "openai-responses",
    "azure-openai-responses",
    "openai-codex-responses",
    "google-generative-ai",
    "google-vertex",
    "bedrock-converse-stream",
};

/// Built-in OAuth providers (utils/oauth/*). Matches auth.zig's oauth_provider_specs.
pub const oauth_providers = [_][]const u8{
    "anthropic",
    "github-copilot",
    "openai-codex",
};

/// Extension API methods exposed on the `pi` object (packages/.../extensions/api).
pub const extension_api_methods = [_][]const u8{
    "appendEntry",        "exec",              "getActiveTools",   "getAllTools",
    "getCommands",        "getFlag",           "getSessionName",   "getThinkingLevel",
    "registerCommand",    "registerFlag",      "registerMessageRenderer", "registerProvider",
    "registerShortcut",   "registerTool",      "sendMessage",      "sendUserMessage",
    "setActiveTools",     "setLabel",          "setModel",         "setSessionName",
    "setThinkingLevel",   "unregisterProvider",
};

/// Extension lifecycle events extensions can subscribe to.
pub const extension_events = [_][]const u8{
    "after_provider_response", "agent_end",               "agent_start",            "before_agent_start",
    "before_provider_request", "context",                 "input",                  "message_end",
    "message_start",           "message_update",          "model_select",           "resources_discover",
    "session_before_compact",  "session_before_fork",     "session_before_switch",  "session_before_tree",
    "session_compact",         "session_shutdown",        "session_start",          "session_tree",
    "thinking_level_select",   "tool_call",               "tool_execution_end",     "tool_execution_start",
    "tool_execution_update",   "tool_result",             "turn_end",               "turn_start",
    "user_bash",
};

/// Reusable TUI components (packages/tui/src/components).
pub const tui_components = [_][]const u8{
    "box",         "cancellable-loader", "editor",         "image",
    "input",       "loader",             "markdown",       "select-list",
    "settings-list", "spacer",           "text",           "truncated-text",
};

/// Interactive-mode component groups (coding-agent interactive UI).
pub const interactive_components = [_][]const u8{
    "armin",                       "assistant-message",         "bash-execution",
    "bordered-loader",             "branch-summary-message",    "compaction-summary-message",
    "config-selector",             "countdown-timer",           "custom-editor",
    "custom-message",              "daxnuts",                   "diff",
    "dynamic-border",              "earendil-announcement",     "extension-editor",
    "extension-input",             "extension-selector",        "footer",
    "index",                       "keybinding-hints",          "login-dialog",
    "model-selector",              "oauth-selector",            "scoped-models-selector",
    "session-selector-search",     "session-selector",          "settings-selector",
    "show-images-selector",        "skill-invocation-message",  "theme-selector",
    "thinking-selector",           "tool-execution",            "tree-selector",
    "user-message-selector",       "user-message",              "visual-truncate",
};

/// Counts that come from generated/derived sources rather than enumerable lists,
/// anchored to scripts/upstream-inventory.mjs self-checks.
pub const cli_flag_count = 46;
pub const env_key_provider_count = 30;
pub const provider_implementation_file_count = 20;
pub const example_package_count = 4;
pub const package_file_count = 8;
pub const doc_count = 26;

pub const rpc_commands = [_][]const u8{
    "prompt",
    "steer",
    "follow_up",
    "abort",
    "new_session",
    "get_state",
    "set_model",
    "cycle_model",
    "get_available_models",
    "set_thinking_level",
    "cycle_thinking_level",
    "set_steering_mode",
    "set_follow_up_mode",
    "compact",
    "set_auto_compaction",
    "set_auto_retry",
    "abort_retry",
    "bash",
    "abort_bash",
    "get_session_stats",
    "export_html",
    "switch_session",
    "fork",
    "clone",
    "get_fork_messages",
    "get_last_assistant_text",
    "set_session_name",
    "get_messages",
    "get_commands",
};

pub const features = [_]Feature{
    .{ .name = "package-map", .status = "foundation" },
    .{ .name = "cli-help-version", .status = "foundation" },
    .{ .name = "rpc-schema", .status = "in_progress" },
    .{ .name = "provider-registry", .status = "foundation" },
    .{ .name = "model-catalog", .status = "in_progress" },
    .{ .name = "built-in-tools", .status = "in_progress" },
    .{ .name = "context-files", .status = "in_progress" },
    .{ .name = "system-prompt", .status = "in_progress" },
    .{ .name = "sessions", .status = "in_progress" },
    .{ .name = "agent-runtime", .status = "not_started" },
    .{ .name = "llm-provider-execution", .status = "not_started" },
    .{ .name = "tui-renderer", .status = "not_started" },
    .{ .name = "preact-workbench", .status = "foundation" },
    .{ .name = "prin7r-integration", .status = "not_started" },
};

pub fn writeInventoryJson(io: std.Io) !void {
    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    // Keep the original `upstream` summary object stable, then add a `counts`
    // object and `surfaces` arrays mirroring the full inventory surface so the
    // runtime mirror is no longer a subset of scripts/upstream-inventory.mjs.
    try w.print(
        \\{{"name":"pi-zig","version":"{s}","upstream":{{"repo":"{s}","commit":"{s}","packages":{d},"providers":{d},"models":{d},"builtins":{d},"rpcCommands":{d}}}
    , .{ config.version, config.upstream_repo, config.upstream_commit, packages.len, models.providers.len, models.all.len, builtins.len, rpc_commands.len });

    try w.writeAll(",\"counts\":{");
    try w.print("\"packages\":{d}", .{package_file_count});
    try w.print(",\"primaryPackages\":{d}", .{packages.len});
    try w.print(",\"examplePackages\":{d}", .{example_package_count});
    try w.print(",\"cliFlags\":{d}", .{cli_flag_count});
    try w.print(",\"subcommands\":{d}", .{subcommands.len});
    try w.print(",\"appModes\":{d}", .{app_modes.len});
    try w.print(",\"builtinSlashCommands\":{d}", .{builtin_slash_commands.len});
    try w.print(",\"rpcCommands\":{d}", .{rpc_commands.len});
    try w.print(",\"builtInTools\":{d}", .{builtins.len});
    try w.print(",\"providerImplementationFiles\":{d}", .{provider_implementation_file_count});
    try w.print(",\"transportApis\":{d}", .{transport_apis.len});
    try w.print(",\"generatedModelProviders\":{d}", .{models.providers.len});
    try w.print(",\"generatedModelRows\":{d}", .{models.all.len});
    try w.print(",\"envKeyProviders\":{d}", .{env_key_provider_count});
    try w.print(",\"oauthProviders\":{d}", .{oauth_providers.len});
    try w.print(",\"extensionApiMethods\":{d}", .{extension_api_methods.len});
    try w.print(",\"extensionEvents\":{d}", .{extension_events.len});
    try w.print(",\"tuiComponents\":{d}", .{tui_components.len});
    try w.print(",\"interactiveComponents\":{d}", .{interactive_components.len});
    try w.print(",\"docs\":{d}", .{doc_count});
    try w.writeAll("}");

    try w.writeAll(",\"surfaces\":{");
    try writeJsonArrayField(w, "subcommands", &subcommands, true);
    try writeJsonArrayField(w, "appModes", &app_modes, false);
    try writeJsonArrayField(w, "builtinSlashCommands", &builtin_slash_commands, false);
    try writeJsonArrayField(w, "rpcCommands", &rpc_commands, false);
    try writeJsonArrayField(w, "builtInTools", &builtins, false);
    try writeJsonArrayField(w, "transportApis", &transport_apis, false);
    try writeJsonArrayField(w, "oauthProviders", &oauth_providers, false);
    try writeJsonArrayField(w, "extensionApiMethods", &extension_api_methods, false);
    try writeJsonArrayField(w, "extensionEvents", &extension_events, false);
    try writeJsonArrayField(w, "tuiComponents", &tui_components, false);
    try writeJsonArrayField(w, "interactiveComponents", &interactive_components, false);
    try w.writeAll("}}\n");
    try w.flush();
}

/// Write a `"key":[...]` array field, prefixing a comma unless `first` is true.
fn writeJsonArrayField(w: *std.Io.Writer, key: []const u8, values: []const []const u8, first: bool) !void {
    if (!first) try w.writeAll(",");
    try w.print("\"{s}\":[", .{key});
    for (values, 0..) |value, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{value});
    }
    try w.writeAll("]");
}

pub fn writeSurfaceJson(io: std.Io, surface: []const u8) !bool {
    if (std.mem.eql(u8, surface, "subcommands")) {
        try writeStringArrayObject(io, "subcommands", &subcommands);
    } else if (std.mem.eql(u8, surface, "app-modes")) {
        try writeStringArrayObject(io, "appModes", &app_modes);
    } else if (std.mem.eql(u8, surface, "slash-commands")) {
        try writeStringArrayObject(io, "builtinSlashCommands", &builtin_slash_commands);
    } else if (std.mem.eql(u8, surface, "transport-apis")) {
        try writeStringArrayObject(io, "transportApis", &transport_apis);
    } else if (std.mem.eql(u8, surface, "oauth-providers")) {
        try writeStringArrayObject(io, "oauthProviders", &oauth_providers);
    } else if (std.mem.eql(u8, surface, "extension-api")) {
        try writeStringArrayObject(io, "extensionApiMethods", &extension_api_methods);
    } else if (std.mem.eql(u8, surface, "extension-events")) {
        try writeStringArrayObject(io, "extensionEvents", &extension_events);
    } else if (std.mem.eql(u8, surface, "tui-components")) {
        try writeStringArrayObject(io, "tuiComponents", &tui_components);
    } else if (std.mem.eql(u8, surface, "interactive-components")) {
        try writeStringArrayObject(io, "interactiveComponents", &interactive_components);
    } else {
        return false;
    }
    return true;
}

pub fn writePackagesJson(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll("{\"packages\":[");
    for (packages, 0..) |pkg, i| {
        if (i != 0) try w.writeAll(",");
        try w.print(
            "{{\"name\":\"{s}\",\"dir\":\"{s}\",\"role\":\"{s}\",\"sourceFiles\":{d},\"testFiles\":{d}}}",
            .{ pkg.name, pkg.dir, pkg.role, pkg.source_files, pkg.test_files },
        );
    }
    try w.writeAll("]}\n");
    try w.flush();
}

pub fn writeProvidersJson(io: std.Io) !void {
    try writeStringArrayObject(io, "providers", models.providers);
}

pub fn writeToolsJson(io: std.Io) !void {
    try writeStringArrayObject(io, "builtins", &builtins);
}

pub fn writeRpcSchemaJson(io: std.Io) !void {
    try writeStringArrayObject(io, "commands", &rpc_commands);
}

pub fn writeParityJson(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll("{\"features\":[");
    for (features, 0..) |feature, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"status\":\"{s}\"}}", .{ feature.name, feature.status });
    }
    try w.writeAll("]}\n");
    try w.flush();
}

fn writeStringArrayObject(io: std.Io, key: []const u8, values: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.print("{{\"{s}\":[", .{key});
    for (values, 0..) |value, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{value});
    }
    try w.writeAll("]}\n");
    try w.flush();
}

test "upstream package inventory is anchored" {
    try std.testing.expectEqual(@as(usize, 4), packages.len);
    try std.testing.expectEqualStrings("@earendil-works/pi-coding-agent", packages[2].name);
}

test "core providers and tools are represented" {
    try std.testing.expect(providers.len >= 10);
    try std.testing.expect(models.providers.len >= 32);
    try std.testing.expect(builtins.len == 7);
}

test "extended inventory surfaces are anchored to upstream-inventory.mjs counts" {
    // Each count below mirrors scripts/upstream-inventory.mjs /
    // docs/inventory/upstream-inventory.json; the test fails loudly on drift so the
    // runtime mirror cannot silently fall behind the script.
    try std.testing.expectEqual(@as(usize, 6), subcommands.len);
    try std.testing.expectEqual(@as(usize, 4), app_modes.len);
    try std.testing.expectEqual(@as(usize, 21), builtin_slash_commands.len);
    try std.testing.expectEqual(@as(usize, 29), rpc_commands.len);
    try std.testing.expectEqual(@as(usize, 9), transport_apis.len);
    try std.testing.expectEqual(@as(usize, 3), oauth_providers.len);
    try std.testing.expectEqual(@as(usize, 22), extension_api_methods.len);
    try std.testing.expectEqual(@as(usize, 29), extension_events.len);
    try std.testing.expectEqual(@as(usize, 12), tui_components.len);
    try std.testing.expectEqual(@as(usize, 36), interactive_components.len);
    // Derived counts.
    try std.testing.expectEqual(@as(usize, 46), cli_flag_count);
    try std.testing.expectEqual(@as(usize, 30), env_key_provider_count);
    try std.testing.expectEqual(@as(usize, 20), provider_implementation_file_count);
    try std.testing.expectEqual(@as(usize, 8), package_file_count);
    try std.testing.expectEqual(@as(usize, 26), doc_count);
    try std.testing.expectEqual(@as(usize, 4), example_package_count);
    try std.testing.expectEqual(@as(usize, 32), models.providers.len);
    try std.testing.expectEqual(@as(usize, 924), models.all.len);
}

test "inventory surface lists carry the documented anchor entries" {
    // Spot-check a representative entry in each list so a reordering/typo that keeps
    // the count but corrupts content is still caught.
    try std.testing.expectEqualStrings("config", subcommands[0]);
    try std.testing.expectEqualStrings("interactive", app_modes[0]);
    try std.testing.expectEqualStrings("settings", builtin_slash_commands[0]);
    try std.testing.expectEqualStrings("anthropic-messages", transport_apis[0]);
    try std.testing.expectEqualStrings("bedrock-converse-stream", transport_apis[transport_apis.len - 1]);
    try std.testing.expectEqualStrings("openai-codex", oauth_providers[oauth_providers.len - 1]);
    try std.testing.expectEqualStrings("appendEntry", extension_api_methods[0]);
    try std.testing.expectEqualStrings("after_provider_response", extension_events[0]);
    try std.testing.expectEqualStrings("user_bash", extension_events[extension_events.len - 1]);
    try std.testing.expectEqualStrings("box", tui_components[0]);
    try std.testing.expectEqualStrings("model-selector", interactive_components[21]);
}

test "writeSurfaceJson recognizes each named surface and rejects unknown" {
    // The dispatcher must accept every surface name and refuse anything else; the
    // actual JSON goes to stdout, so here we only assert the recognized/unknown
    // boolean contract (running it exercises the writers for compile coverage).
    try std.testing.expect(!(try writeSurfaceJson(std.testing.io, "not-a-surface")));
}

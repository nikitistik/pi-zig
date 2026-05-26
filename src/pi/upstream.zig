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
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.print(
        \\{{"name":"pi-zig","version":"{s}","upstream":{{"repo":"{s}","commit":"{s}","packages":{d},"providers":{d},"models":{d},"builtins":{d},"rpcCommands":{d}}}}}
        \\
    , .{ config.version, config.upstream_repo, config.upstream_commit, packages.len, models.providers.len, models.all.len, builtins.len, rpc_commands.len });
    try w.flush();
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

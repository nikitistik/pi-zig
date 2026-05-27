const std = @import("std");

const max_settings_bytes = 1024 * 1024;
const default_http_idle_timeout_ms: i64 = 300_000;
const project_settings_file = ".pi/settings.json";

const Scope = enum {
    global,
    project,
};

const LoadResult = struct {
    parsed: std.json.Parsed(std.json.Value),
    existed: bool,
    error_name: ?[]const u8 = null,

    fn deinit(self: *LoadResult) void {
        self.parsed.deinit();
    }
};

pub const ShellSettings = struct {
    shell_path: ?[]u8 = null,
    shell_command_prefix: ?[]u8 = null,

    pub fn deinit(self: ShellSettings, allocator: std.mem.Allocator) void {
        if (self.shell_path) |value| allocator.free(value);
        if (self.shell_command_prefix) |value| allocator.free(value);
    }
};

pub const RetrySettings = struct {
    enabled: bool = true,
    max_retries: usize = 3,
    base_delay_ms: usize = 2_000,
};

pub fn loadRetrySettings(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !RetrySettings {
    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);
    const paths = try settingsPaths(allocator, env, cwd);
    defer paths.deinit(allocator);

    var global = try loadSettings(io, allocator, paths.global);
    defer global.deinit();
    var project = try loadSettings(io, allocator, paths.project);
    defer project.deinit();

    return .{
        .enabled = nestedBool(project.parsed.value, &.{ "retry", "enabled" }) orelse nestedBool(global.parsed.value, &.{ "retry", "enabled" }) orelse true,
        .max_retries = positiveUsize(numberAt(project.parsed.value, &.{ "retry", "maxRetries" })) orelse positiveUsize(numberAt(global.parsed.value, &.{ "retry", "maxRetries" })) orelse 3,
        .base_delay_ms = positiveUsize(numberAt(project.parsed.value, &.{ "retry", "baseDelayMs" })) orelse positiveUsize(numberAt(global.parsed.value, &.{ "retry", "baseDelayMs" })) orelse 2_000,
    };
}

pub fn loadShellSettings(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !ShellSettings {
    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);
    const paths = try settingsPaths(allocator, env, cwd);
    defer paths.deinit(allocator);

    var global = try loadSettings(io, allocator, paths.global);
    defer global.deinit();
    var project = try loadSettings(io, allocator, paths.project);
    defer project.deinit();

    var result = ShellSettings{};
    errdefer result.deinit(allocator);

    const shell_path_setting = fieldString(project.parsed.value, "shellPath") orelse fieldString(global.parsed.value, "shellPath");
    const shell_prefix_setting = fieldString(project.parsed.value, "shellCommandPrefix") orelse fieldString(global.parsed.value, "shellCommandPrefix");

    if (nonEmptyString(shell_path_setting)) |shell_path| {
        result.shell_path = try expandMaybeTilde(allocator, env, shell_path);
    }
    if (nonEmptyString(shell_prefix_setting)) |prefix| {
        result.shell_command_prefix = try allocator.dupe(u8, prefix);
    }
    return result;
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !bool {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "settings")) return false;

    if (args.len == 1 or (args.len == 2 and std.mem.eql(u8, args[1], "--json"))) {
        try writeSettingsReport(io, allocator, env);
        return true;
    }

    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try writeHelp(io);
        return true;
    }

    if (std.mem.eql(u8, args[1], "paths")) {
        try writeSettingsPaths(io, allocator, env);
        return true;
    }

    if (std.mem.eql(u8, args[1], "get")) {
        if (args.len != 3) return usageError(io, "Usage: pi-zig settings get <key>");
        try writeSettingValue(io, allocator, env, args[2]);
        return true;
    }

    if (std.mem.eql(u8, args[1], "set")) {
        try setCommand(io, allocator, env, args[2..]);
        return true;
    }

    if (std.mem.eql(u8, args[1], "set-model")) {
        try setModelCommand(io, allocator, env, args[2..]);
        return true;
    }

    return usageError(io, "Unknown settings command");
}

fn writeSettingsReport(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !void {
    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);
    const paths = try settingsPaths(allocator, env, cwd);
    defer paths.deinit(allocator);

    var global = try loadSettings(io, allocator, paths.global);
    defer global.deinit();
    var project = try loadSettings(io, allocator, paths.project);
    defer project.deinit();

    const merged = try mergeSettings(allocator, global.parsed.value, project.parsed.value);
    const resolved = try resolvedSettings(allocator, env, merged);

    var root = std.json.ObjectMap.empty;
    try root.put(allocator, "globalPath", .{ .string = paths.global });
    try root.put(allocator, "projectPath", .{ .string = paths.project });
    try root.put(allocator, "globalSettings", global.parsed.value);
    try root.put(allocator, "projectSettings", project.parsed.value);
    try root.put(allocator, "settings", merged);
    try root.put(allocator, "resolved", resolved);
    try root.put(allocator, "errors", try loadErrorsArray(allocator, &global, &project));
    try writeJsonValue(io, allocator, .{ .object = root });
}

fn writeSettingsPaths(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !void {
    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);
    const paths = try settingsPaths(allocator, env, cwd);
    defer paths.deinit(allocator);

    var root = std.json.ObjectMap.empty;
    try root.put(allocator, "globalPath", .{ .string = paths.global });
    try root.put(allocator, "projectPath", .{ .string = paths.project });
    try writeJsonValue(io, allocator, .{ .object = root });
}

fn writeSettingValue(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, key: []const u8) !void {
    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);
    const paths = try settingsPaths(allocator, env, cwd);
    defer paths.deinit(allocator);

    var global = try loadSettings(io, allocator, paths.global);
    defer global.deinit();
    var project = try loadSettings(io, allocator, paths.project);
    defer project.deinit();

    const merged = try mergeSettings(allocator, global.parsed.value, project.parsed.value);
    const resolved = try resolvedSettings(allocator, env, merged);

    const value = if (std.mem.startsWith(u8, key, "resolved."))
        findPath(resolved, key["resolved.".len..])
    else
        findPath(merged, key) orelse findPath(resolved, key);
    try writeJsonValue(io, allocator, value orelse .null);
}

fn setCommand(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    var scope: Scope = .global;
    var positionals: [2][]const u8 = undefined;
    var positional_count: usize = 0;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "--project")) {
            scope = .project;
            continue;
        }
        if (std.mem.eql(u8, arg, "--global")) {
            scope = .global;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return usageError(io, "Unknown settings set option");
        if (positional_count >= positionals.len) return usageError(io, "Usage: pi-zig settings set <key> <value> [--local]");
        positionals[positional_count] = arg;
        positional_count += 1;
    }

    if (positional_count != 2) return usageError(io, "Usage: pi-zig settings set <key> <value> [--local]");

    var parsed_value = std.json.parseFromSlice(std.json.Value, allocator, positionals[1], .{}) catch null;
    defer if (parsed_value) |*parsed| parsed.deinit();
    const value: std.json.Value = if (parsed_value) |parsed| parsed.value else .{ .string = positionals[1] };

    try updateSettingsFile(io, allocator, env, scope, &.{.{ .path = positionals[0], .value = value }});
    try writeStdout(io, "Updated ");
    try writeStdout(io, scopeName(scope));
    try writeStdout(io, " settings: ");
    try writeStdout(io, positionals[0]);
    try writeStdout(io, "\n");
}

fn setModelCommand(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    if (args.len != 2) return usageError(io, "Usage: pi-zig settings set-model <provider> <model-id>");
    try updateSettingsFile(io, allocator, env, .global, &.{
        .{ .path = "defaultProvider", .value = .{ .string = args[0] } },
        .{ .path = "defaultModel", .value = .{ .string = args[1] } },
    });
    try writeStdout(io, "Updated global default model: ");
    try writeStdout(io, args[0]);
    try writeStdout(io, "/");
    try writeStdout(io, args[1]);
    try writeStdout(io, "\n");
}

const SettingUpdate = struct {
    path: []const u8,
    value: std.json.Value,
};

fn updateSettingsFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    scope: Scope,
    updates: []const SettingUpdate,
) !void {
    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);
    const paths = try settingsPaths(allocator, env, cwd);
    defer paths.deinit(allocator);
    const path = switch (scope) {
        .global => paths.global,
        .project => paths.project,
    };

    var parsed = try loadSettingsStrict(io, allocator, path);
    defer parsed.deinit();
    try migrateSettings(allocator, &parsed.value);
    for (updates) |update| {
        try setDottedValue(allocator, &parsed.value, update.path, update.value);
    }
    try writeSettings(io, allocator, path, parsed.value);
}

fn loadSettings(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !LoadResult {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_settings_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
            try migrateSettings(allocator, &parsed.value);
            return .{ .parsed = parsed, .existed = false };
        },
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| {
        const empty = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
        return .{
            .parsed = empty,
            .existed = true,
            .error_name = try allocator.dupe(u8, @errorName(err)),
        };
    };
    try migrateSettings(allocator, &parsed.value);
    return .{ .parsed = parsed, .existed = true };
}

fn loadSettingsStrict(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_settings_bytes)) catch |err| switch (err) {
        error.FileNotFound => return std.json.parseFromSlice(std.json.Value, allocator, "{}", .{}),
        else => return err,
    };
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| {
        try writeStderr(io, "Refusing to overwrite invalid settings file ");
        try writeStderr(io, path);
        try writeStderr(io, ": ");
        try writeStderr(io, @errorName(err));
        try writeStderr(io, "\n");
        std.process.exit(1);
    };
}

fn migrateSettings(allocator: std.mem.Allocator, value: *std.json.Value) !void {
    const root = try ensureObject(value);

    if (root.get("queueMode") != null and root.get("steeringMode") == null) {
        try root.put(allocator, "steeringMode", root.get("queueMode").?);
    }
    _ = root.orderedRemove("queueMode");

    if (root.get("transport") == null) {
        if (root.get("websockets")) |websockets| {
            if (websockets == .bool) {
                try root.put(allocator, "transport", .{ .string = if (websockets.bool) "websocket" else "sse" });
            }
        }
    }
    _ = root.orderedRemove("websockets");

    if (root.getPtr("skills")) |skills_value| {
        if (skills_value.* == .object) {
            const skills_object = skills_value.object;
            if (root.get("enableSkillCommands") == null) {
                if (skills_object.get("enableSkillCommands")) |enabled| {
                    try root.put(allocator, "enableSkillCommands", enabled);
                }
            }
            if (skills_object.get("customDirectories")) |directories| {
                if (directories == .array and directories.array.items.len > 0) {
                    try root.put(allocator, "skills", directories);
                } else {
                    _ = root.orderedRemove("skills");
                }
            } else {
                _ = root.orderedRemove("skills");
            }
        }
    }

    if (root.getPtr("retry")) |retry_value| {
        if (retry_value.* == .object) {
            var retry_object = &retry_value.object;
            if (retry_object.get("maxDelayMs")) |max_delay| {
                if (numberToI64(max_delay) != null) {
                    var provider_value = retry_object.get("provider") orelse std.json.Value{ .object = std.json.ObjectMap.empty };
                    if (provider_value != .object) provider_value = .{ .object = std.json.ObjectMap.empty };
                    if (provider_value.object.get("maxRetryDelayMs") == null or provider_value.object.get("maxRetryDelayMs").? == .null) {
                        try provider_value.object.put(allocator, "maxRetryDelayMs", max_delay);
                    }
                    try retry_object.put(allocator, "provider", provider_value);
                }
            }
            _ = retry_object.orderedRemove("maxDelayMs");
        }
    }
}

fn mergeSettings(allocator: std.mem.Allocator, global: std.json.Value, project: std.json.Value) !std.json.Value {
    var merged = std.json.ObjectMap.empty;
    if (global == .object) {
        var it = global.object.iterator();
        while (it.next()) |entry| {
            try merged.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    if (project == .object) {
        var it = project.object.iterator();
        while (it.next()) |entry| {
            const override_value = entry.value_ptr.*;
            if (override_value == .object) {
                if (merged.get(entry.key_ptr.*)) |base_value| {
                    if (base_value == .object) {
                        var nested = std.json.ObjectMap.empty;
                        var base_it = base_value.object.iterator();
                        while (base_it.next()) |base_entry| {
                            try nested.put(allocator, base_entry.key_ptr.*, base_entry.value_ptr.*);
                        }
                        var override_it = override_value.object.iterator();
                        while (override_it.next()) |override_entry| {
                            try nested.put(allocator, override_entry.key_ptr.*, override_entry.value_ptr.*);
                        }
                        try merged.put(allocator, entry.key_ptr.*, .{ .object = nested });
                        continue;
                    }
                }
            }
            try merged.put(allocator, entry.key_ptr.*, override_value);
        }
    }
    return .{ .object = merged };
}

fn resolvedSettings(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, settings: std.json.Value) !std.json.Value {
    var root = std.json.ObjectMap.empty;
    try root.put(allocator, "defaultProvider", optionalStringValue(fieldString(settings, "defaultProvider")));
    try root.put(allocator, "defaultModel", optionalStringValue(fieldString(settings, "defaultModel")));
    try root.put(allocator, "defaultThinkingLevel", optionalStringValue(fieldString(settings, "defaultThinkingLevel")));
    try root.put(allocator, "transport", .{ .string = fieldString(settings, "transport") orelse "auto" });
    try root.put(allocator, "steeringMode", .{ .string = fieldString(settings, "steeringMode") orelse "one-at-a-time" });
    try root.put(allocator, "followUpMode", .{ .string = fieldString(settings, "followUpMode") orelse "one-at-a-time" });
    try root.put(allocator, "theme", optionalStringValue(fieldString(settings, "theme")));
    try root.put(allocator, "shellPath", try resolvedShellPathValue(allocator, env, fieldString(settings, "shellPath")));
    try root.put(allocator, "shellCommandPrefix", optionalStringValue(nonEmptyString(fieldString(settings, "shellCommandPrefix"))));
    try root.put(allocator, "sessionDir", try resolvedSessionDir(allocator, env, fieldString(settings, "sessionDir")));
    try root.put(allocator, "compaction", try compactionSettings(allocator, settings));
    try root.put(allocator, "branchSummary", try branchSummarySettings(allocator, settings));
    try root.put(allocator, "retry", try retrySettings(allocator, settings));
    try root.put(allocator, "httpIdleTimeoutMs", .{ .integer = try resolvedHttpIdleTimeoutMs(settings) });
    try root.put(allocator, "hideThinkingBlock", .{ .bool = nestedBool(settings, &.{"hideThinkingBlock"}) orelse false });
    try root.put(allocator, "quietStartup", .{ .bool = nestedBool(settings, &.{"quietStartup"}) orelse false });
    try root.put(allocator, "collapseChangelog", .{ .bool = nestedBool(settings, &.{"collapseChangelog"}) orelse false });
    try root.put(allocator, "enableInstallTelemetry", .{ .bool = nestedBool(settings, &.{"enableInstallTelemetry"}) orelse true });
    try root.put(allocator, "enableSkillCommands", .{ .bool = nestedBool(settings, &.{"enableSkillCommands"}) orelse true });
    try root.put(allocator, "terminal", try terminalSettings(allocator, env, settings));
    try root.put(allocator, "images", try imageSettings(allocator, settings));
    try root.put(allocator, "doubleEscapeAction", .{ .string = validChoice(fieldString(settings, "doubleEscapeAction"), &.{ "fork", "tree", "none" }) orelse "tree" });
    try root.put(allocator, "treeFilterMode", .{ .string = validChoice(fieldString(settings, "treeFilterMode"), &.{ "default", "no-tools", "user-only", "labeled-only", "all" }) orelse "default" });
    try root.put(allocator, "showHardwareCursor", .{ .bool = nestedBool(settings, &.{"showHardwareCursor"}) orelse envBool(env, "PI_HARDWARE_CURSOR") });
    try root.put(allocator, "editorPaddingX", .{ .integer = clamp(numberAt(settings, &.{"editorPaddingX"}) orelse 0, 0, 3) });
    try root.put(allocator, "autocompleteMaxVisible", .{ .integer = clamp(numberAt(settings, &.{"autocompleteMaxVisible"}) orelse 5, 3, 20) });
    try root.put(allocator, "markdown", try markdownSettings(allocator, settings));
    try root.put(allocator, "warnings", nestedObjectValue(settings, &.{"warnings"}) orelse std.json.Value{ .object = std.json.ObjectMap.empty });
    return .{ .object = root };
}

fn compactionSettings(allocator: std.mem.Allocator, settings: std.json.Value) !std.json.Value {
    var root = std.json.ObjectMap.empty;
    try root.put(allocator, "enabled", .{ .bool = nestedBool(settings, &.{ "compaction", "enabled" }) orelse true });
    try root.put(allocator, "reserveTokens", .{ .integer = numberAt(settings, &.{ "compaction", "reserveTokens" }) orelse 16_384 });
    try root.put(allocator, "keepRecentTokens", .{ .integer = numberAt(settings, &.{ "compaction", "keepRecentTokens" }) orelse 20_000 });
    return .{ .object = root };
}

fn branchSummarySettings(allocator: std.mem.Allocator, settings: std.json.Value) !std.json.Value {
    var root = std.json.ObjectMap.empty;
    try root.put(allocator, "reserveTokens", .{ .integer = numberAt(settings, &.{ "branchSummary", "reserveTokens" }) orelse 16_384 });
    try root.put(allocator, "skipPrompt", .{ .bool = nestedBool(settings, &.{ "branchSummary", "skipPrompt" }) orelse false });
    return .{ .object = root };
}

fn retrySettings(allocator: std.mem.Allocator, settings: std.json.Value) !std.json.Value {
    var provider = std.json.ObjectMap.empty;
    if (numberAt(settings, &.{ "retry", "provider", "timeoutMs" })) |timeout| try provider.put(allocator, "timeoutMs", .{ .integer = timeout });
    if (numberAt(settings, &.{ "retry", "provider", "maxRetries" })) |max_retries| try provider.put(allocator, "maxRetries", .{ .integer = max_retries });
    try provider.put(allocator, "maxRetryDelayMs", .{ .integer = numberAt(settings, &.{ "retry", "provider", "maxRetryDelayMs" }) orelse 60_000 });

    var root = std.json.ObjectMap.empty;
    try root.put(allocator, "enabled", .{ .bool = nestedBool(settings, &.{ "retry", "enabled" }) orelse true });
    try root.put(allocator, "maxRetries", .{ .integer = numberAt(settings, &.{ "retry", "maxRetries" }) orelse 3 });
    try root.put(allocator, "baseDelayMs", .{ .integer = numberAt(settings, &.{ "retry", "baseDelayMs" }) orelse 2_000 });
    try root.put(allocator, "provider", .{ .object = provider });
    return .{ .object = root };
}

fn terminalSettings(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, settings: std.json.Value) !std.json.Value {
    var root = std.json.ObjectMap.empty;
    try root.put(allocator, "showImages", .{ .bool = nestedBool(settings, &.{ "terminal", "showImages" }) orelse true });
    try root.put(allocator, "imageWidthCells", .{ .integer = @max(1, numberAt(settings, &.{ "terminal", "imageWidthCells" }) orelse 60) });
    try root.put(allocator, "clearOnShrink", .{ .bool = nestedBool(settings, &.{ "terminal", "clearOnShrink" }) orelse envBool(env, "PI_CLEAR_ON_SHRINK") });
    try root.put(allocator, "showTerminalProgress", .{ .bool = nestedBool(settings, &.{ "terminal", "showTerminalProgress" }) orelse false });
    return .{ .object = root };
}

fn imageSettings(allocator: std.mem.Allocator, settings: std.json.Value) !std.json.Value {
    var root = std.json.ObjectMap.empty;
    try root.put(allocator, "autoResize", .{ .bool = nestedBool(settings, &.{ "images", "autoResize" }) orelse true });
    try root.put(allocator, "blockImages", .{ .bool = nestedBool(settings, &.{ "images", "blockImages" }) orelse false });
    return .{ .object = root };
}

fn markdownSettings(allocator: std.mem.Allocator, settings: std.json.Value) !std.json.Value {
    var root = std.json.ObjectMap.empty;
    try root.put(allocator, "codeBlockIndent", .{ .string = nestedString(settings, &.{ "markdown", "codeBlockIndent" }) orelse "  " });
    return .{ .object = root };
}

fn resolvedHttpIdleTimeoutMs(settings: std.json.Value) !i64 {
    const value = findPath(settings, "httpIdleTimeoutMs") orelse return default_http_idle_timeout_ms;
    if (parseHttpIdleTimeoutMs(value)) |timeout| return timeout;
    return error.InvalidHttpIdleTimeoutMs;
}

fn parseHttpIdleTimeoutMs(value: std.json.Value) ?i64 {
    switch (value) {
        .integer => |int| return if (int >= 0) int else null,
        .float => |float| {
            if (!std.math.isFinite(float) or float < 0) return null;
            return @intFromFloat(@floor(float));
        },
        .string => |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(trimmed, "disabled")) return 0;
            if (trimmed.len == 0) return null;
            const int = std.fmt.parseInt(i64, trimmed, 10) catch return null;
            return if (int >= 0) int else null;
        },
        else => return null,
    }
}

fn setDottedValue(allocator: std.mem.Allocator, value: *std.json.Value, path: []const u8, new_value: std.json.Value) !void {
    var iter = std.mem.splitScalar(u8, path, '.');
    var current = value;
    while (iter.next()) |segment| {
        if (segment.len == 0) return error.InvalidSettingPath;
        const is_last = iter.peek() == null;
        const object = try ensureObject(current);
        if (is_last) {
            try object.put(allocator, segment, new_value);
            return;
        }
        if (object.getPtr(segment)) |child| {
            if (child.* != .object) child.* = .{ .object = std.json.ObjectMap.empty };
            current = child;
        } else {
            try object.put(allocator, segment, .{ .object = std.json.ObjectMap.empty });
            current = object.getPtr(segment).?;
        }
    }
    return error.InvalidSettingPath;
}

fn findPath(value: std.json.Value, path: []const u8) ?std.json.Value {
    var current = value;
    var iter = std.mem.splitScalar(u8, path, '.');
    while (iter.next()) |segment| {
        if (segment.len == 0 or current != .object) return null;
        current = current.object.get(segment) orelse return null;
    }
    return current;
}

fn nestedString(value: std.json.Value, path: []const []const u8) ?[]const u8 {
    const found = nestedValue(value, path) orelse return null;
    return if (found == .string) found.string else null;
}

fn fieldString(value: std.json.Value, field: []const u8) ?[]const u8 {
    return nestedString(value, &.{field});
}

fn nestedBool(value: std.json.Value, path: []const []const u8) ?bool {
    const found = nestedValue(value, path) orelse return null;
    return if (found == .bool) found.bool else null;
}

fn numberAt(value: std.json.Value, path: []const []const u8) ?i64 {
    const found = nestedValue(value, path) orelse return null;
    return numberToI64(found);
}

fn positiveUsize(value: ?i64) ?usize {
    const number = value orelse return null;
    if (number < 0) return null;
    return @intCast(number);
}

fn nestedObjectValue(value: std.json.Value, path: []const []const u8) ?std.json.Value {
    const found = nestedValue(value, path) orelse return null;
    return if (found == .object) found else null;
}

fn nestedValue(value: std.json.Value, path: []const []const u8) ?std.json.Value {
    var current = value;
    for (path) |segment| {
        if (current != .object) return null;
        current = current.object.get(segment) orelse return null;
    }
    return current;
}

fn numberToI64(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |int| int,
        .float => |float| if (std.math.isFinite(float)) @as(i64, @intFromFloat(@floor(float))) else null,
        else => null,
    };
}

fn optionalStringValue(value: ?[]const u8) std.json.Value {
    return if (value) |string| .{ .string = string } else .null;
}

fn nonEmptyString(value: ?[]const u8) ?[]const u8 {
    const string = value orelse return null;
    const trimmed = std.mem.trim(u8, string, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn resolvedShellPathValue(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, value: ?[]const u8) !std.json.Value {
    const raw = nonEmptyString(value) orelse return .null;
    return .{ .string = try expandMaybeTilde(allocator, env, raw) };
}

fn resolvedSessionDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, value: ?[]const u8) !std.json.Value {
    const raw = value orelse return .null;
    return .{ .string = try expandMaybeTilde(allocator, env, raw) };
}

fn validChoice(value: ?[]const u8, choices: []const []const u8) ?[]const u8 {
    const string = value orelse return null;
    for (choices) |choice| {
        if (std.mem.eql(u8, string, choice)) return string;
    }
    return null;
}

fn envBool(env: *const std.process.Environ.Map, name: []const u8) bool {
    return if (env.get(name)) |value| std.mem.eql(u8, value, "1") else false;
}

fn clamp(value: i64, min: i64, max: i64) i64 {
    return @min(max, @max(min, value));
}

fn loadErrorsArray(allocator: std.mem.Allocator, global: *const LoadResult, project: *const LoadResult) !std.json.Value {
    var errors = std.json.Array.init(allocator);
    if (global.error_name) |name| try errors.append(try loadErrorObject(allocator, "global", name));
    if (project.error_name) |name| try errors.append(try loadErrorObject(allocator, "project", name));
    return .{ .array = errors };
}

fn loadErrorObject(allocator: std.mem.Allocator, scope: []const u8, error_name: []const u8) !std.json.Value {
    var root = std.json.ObjectMap.empty;
    try root.put(allocator, "scope", .{ .string = scope });
    try root.put(allocator, "error", .{ .string = error_name });
    return .{ .object = root };
}

const Paths = struct {
    global: []u8,
    project: []u8,

    fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.global);
        allocator.free(self.project);
    }
};

fn settingsPaths(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, cwd: []const u8) !Paths {
    const agent_dir = try agentDir(allocator, env);
    defer allocator.free(agent_dir);
    return .{
        .global = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" }),
        .project = try std.fs.path.join(allocator, &.{ cwd, project_settings_file }),
    };
}

fn agentDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("PI_CODING_AGENT_DIR")) |value| {
        return expandMaybeTilde(allocator, env, value);
    }
    const home = env.get("HOME") orelse ".";
    return std.fs.path.join(allocator, &.{ home, ".pi", "agent" });
}

fn expandMaybeTilde(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, env.get("HOME") orelse ".");
    if (std.mem.startsWith(u8, path, "~/")) {
        return std.fs.path.join(allocator, &.{ env.get("HOME") orelse ".", path[2..] });
    }
    return allocator.dupe(u8, path);
}

fn ensureObject(value: *std.json.Value) !*std.json.ObjectMap {
    if (value.* != .object) value.* = .{ .object = std.json.ObjectMap.empty };
    return &value.object;
}

fn writeSettings(io: std.Io, allocator: std.mem.Allocator, path: []const u8, value: std.json.Value) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

fn writeJsonValue(io: std.Io, allocator: std.mem.Allocator, value: std.json.Value) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
}

fn currentPathOwned(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

fn usageError(io: std.Io, message: []const u8) noreturn {
    writeStderr(io, message) catch {};
    writeStderr(io, "\n") catch {};
    writeStderr(io, "Use \"pi-zig settings --help\".\n") catch {};
    std.process.exit(1);
}

fn writeHelp(io: std.Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  pi-zig settings [--json]
        \\  pi-zig settings paths
        \\  pi-zig settings get <key>
        \\  pi-zig settings set <key> <value> [--local|--project|--global]
        \\  pi-zig settings set-model <provider> <model-id>
        \\
        \\Reads global settings from $PI_CODING_AGENT_DIR/settings.json or
        \\$HOME/.pi/agent/settings.json, then overlays .pi/settings.json from
        \\the current project. Writes preserve unrelated file keys.
        \\
    );
}

fn scopeName(scope: Scope) []const u8 {
    return switch (scope) {
        .global => "global",
        .project => "project",
    };
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeStderr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

// Migrations mirror production by allocating new keys from a long-lived arena
// (main.zig passes init.arena.allocator()); the parsed JSON keeps its own arena.
fn parseAndMigrate(allocator: std.mem.Allocator, json: []const u8) !std.json.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    try migrateSettings(allocator, &parsed.value);
    return parsed.value;
}

test "migrateSettings renames queueMode to steeringMode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseAndMigrate(arena.allocator(), "{\"queueMode\":\"all\"}");
    try std.testing.expect(value.object.get("queueMode") == null);
    try std.testing.expectEqualStrings("all", value.object.get("steeringMode").?.string);
}

test "migrateSettings keeps explicit steeringMode over legacy queueMode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseAndMigrate(arena.allocator(), "{\"queueMode\":\"all\",\"steeringMode\":\"one-at-a-time\"}");
    try std.testing.expect(value.object.get("queueMode") == null);
    try std.testing.expectEqualStrings("one-at-a-time", value.object.get("steeringMode").?.string);
}

test "migrateSettings converts websockets boolean to transport" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const on = try parseAndMigrate(arena.allocator(), "{\"websockets\":true}");
    try std.testing.expect(on.object.get("websockets") == null);
    try std.testing.expectEqualStrings("websocket", on.object.get("transport").?.string);

    const off = try parseAndMigrate(arena.allocator(), "{\"websockets\":false}");
    try std.testing.expectEqualStrings("sse", off.object.get("transport").?.string);

    // An explicit transport wins over the legacy websockets flag.
    const explicit = try parseAndMigrate(arena.allocator(), "{\"websockets\":true,\"transport\":\"sse\"}");
    try std.testing.expectEqualStrings("sse", explicit.object.get("transport").?.string);
}

test "migrateSettings flattens legacy skills object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseAndMigrate(
        arena.allocator(),
        "{\"skills\":{\"enableSkillCommands\":false,\"customDirectories\":[\"legacy-skills\"]}}",
    );
    try std.testing.expectEqual(false, value.object.get("enableSkillCommands").?.bool);
    const skills = value.object.get("skills").?;
    try std.testing.expectEqual(@as(usize, 1), skills.array.items.len);
    try std.testing.expectEqualStrings("legacy-skills", skills.array.items[0].string);
}

test "migrateSettings drops legacy skills object without custom directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseAndMigrate(arena.allocator(), "{\"skills\":{\"enableSkillCommands\":true}}");
    try std.testing.expectEqual(true, value.object.get("enableSkillCommands").?.bool);
    try std.testing.expect(value.object.get("skills") == null);
}

test "migrateSettings moves retry maxDelayMs to provider maxRetryDelayMs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseAndMigrate(arena.allocator(), "{\"retry\":{\"maxDelayMs\":1234,\"maxRetries\":4}}");
    const retry = value.object.get("retry").?.object;
    try std.testing.expect(retry.get("maxDelayMs") == null);
    try std.testing.expectEqual(@as(i64, 4), numberToI64(retry.get("maxRetries").?).?);
    try std.testing.expectEqual(@as(i64, 1234), numberToI64(retry.get("provider").?.object.get("maxRetryDelayMs").?).?);
}

test "migrateSettings preserves explicit provider maxRetryDelayMs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseAndMigrate(
        arena.allocator(),
        "{\"retry\":{\"maxDelayMs\":1234,\"provider\":{\"maxRetryDelayMs\":555}}}",
    );
    const retry = value.object.get("retry").?.object;
    try std.testing.expect(retry.get("maxDelayMs") == null);
    try std.testing.expectEqual(@as(i64, 555), numberToI64(retry.get("provider").?.object.get("maxRetryDelayMs").?).?);
}

test "mergeSettings merges nested objects with project precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const global = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"theme\":\"dark\",\"compaction\":{\"enabled\":true,\"reserveTokens\":16384}}",
        .{},
    );
    const project = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"compaction\":{\"reserveTokens\":8192}}",
        .{},
    );

    const merged = try mergeSettings(allocator, global.value, project.value);
    // Top-level key only present globally is preserved.
    try std.testing.expectEqualStrings("dark", merged.object.get("theme").?.string);
    const compaction = merged.object.get("compaction").?.object;
    // Project override wins for the overlapping nested key...
    try std.testing.expectEqual(@as(i64, 8192), compaction.get("reserveTokens").?.integer);
    // ...while sibling nested keys from global survive the merge.
    try std.testing.expectEqual(true, compaction.get("enabled").?.bool);
}

fn parseHttpIdleProbe(json: []const u8) !?i64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    return parseHttpIdleTimeoutMs(parsed.value);
}

test "parseHttpIdleTimeoutMs accepts numbers, disabled, and rejects negatives" {
    try std.testing.expectEqual(@as(?i64, 1000), try parseHttpIdleProbe("1000"));
    try std.testing.expectEqual(@as(?i64, 0), try parseHttpIdleProbe("\"disabled\""));
    try std.testing.expectEqual(@as(?i64, 2000), try parseHttpIdleProbe("\"2000\""));
    try std.testing.expectEqual(@as(?i64, 0), try parseHttpIdleProbe("0"));
    try std.testing.expectEqual(@as(?i64, null), try parseHttpIdleProbe("-5"));
    try std.testing.expectEqual(@as(?i64, null), try parseHttpIdleProbe("\"oops\""));
    try std.testing.expectEqual(@as(?i64, null), try parseHttpIdleProbe("true"));
}

test "setDottedValue creates nested objects and preserves siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"theme\":\"dark\"}", .{});
    try setDottedValue(allocator, &parsed.value, "compaction.reserveTokens", .{ .integer = 4096 });
    try std.testing.expectEqualStrings("dark", parsed.value.object.get("theme").?.string);
    try std.testing.expectEqual(@as(i64, 4096), parsed.value.object.get("compaction").?.object.get("reserveTokens").?.integer);

    try std.testing.expectError(error.InvalidSettingPath, setDottedValue(allocator, &parsed.value, "", .{ .bool = true }));
}

test "findPath reads nested dotted values" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"compaction\":{\"keepRecentTokens\":222}}",
        .{},
    );
    defer parsed.deinit();
    const value = findPath(parsed.value, "compaction.keepRecentTokens").?;
    try std.testing.expectEqual(@as(i64, 222), value.integer);
    try std.testing.expect(findPath(parsed.value, "compaction.missing") == null);
    try std.testing.expect(findPath(parsed.value, "absent") == null);
}

const std = @import("std");
const providers = @import("providers.zig");

const max_auth_bytes = 1024 * 1024;

const Command = enum {
    list,
    status,
    resolve,
    set_api_key,
    set_oauth,
    remove,
    providers,
};

const Options = struct {
    command: Command,
    provider: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    access: ?[]const u8 = null,
    refresh: ?[]const u8 = null,
    expires: ?i64 = null,
    json: bool = false,
    help: bool = false,
    invalid_option: ?[]const u8 = null,
    invalid_argument: ?[]const u8 = null,
    missing_argument: ?[]const u8 = null,
};

const AuthStatus = struct {
    has_auth: bool,
    configured: bool,
    source: ?[]const u8 = null,
    label: ?[]const u8 = null,
    credential_type: ?[]const u8 = null,
};

pub fn resolveProviderApiKey(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    provider: []const u8,
) !?[]u8 {
    var parsed = try loadAuth(io, allocator, env);
    defer parsed.deinit();
    return resolveApiKey(io, allocator, env, parsed.value, provider);
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !bool {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "auth")) return false;

    const options = parse(args[1..]) orelse {
        try writeHelp(io);
        return true;
    };

    if (options.help) {
        try writeHelp(io);
        return true;
    }

    if (options.invalid_option) |option| {
        try writeStderr(io, "Unknown option ");
        try writeStderr(io, option);
        try writeStderr(io, " for \"auth\".\n");
        std.process.exit(1);
    }
    if (options.invalid_argument) |argument| {
        try writeStderr(io, "Unexpected argument ");
        try writeStderr(io, argument);
        try writeStderr(io, ".\n");
        std.process.exit(1);
    }
    if (options.missing_argument) |message| {
        try writeStderr(io, message);
        try writeStderr(io, "\n");
        std.process.exit(1);
    }

    switch (options.command) {
        .list => try listStored(io, allocator, env, options.json),
        .status => try writeStatus(io, allocator, env, options.provider.?, options.json),
        .resolve => try resolveCommand(io, allocator, env, options.provider.?, options.json),
        .set_api_key => try setApiKey(io, allocator, env, options.provider.?, options.api_key.?),
        .set_oauth => try setOAuth(io, allocator, env, options.provider.?, options.access.?, options.refresh.?, options.expires.?),
        .remove => try removeProvider(io, allocator, env, options.provider.?),
        .providers => try listOAuthProviders(io, options.json),
    }
    return true;
}

fn parse(args: []const []const u8) ?Options {
    if (args.len == 0) return null;
    if (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) {
        return .{ .command = .list, .help = true };
    }

    const command: Command = if (std.mem.eql(u8, args[0], "list"))
        .list
    else if (std.mem.eql(u8, args[0], "status"))
        .status
    else if (std.mem.eql(u8, args[0], "resolve") or std.mem.eql(u8, args[0], "get-api-key"))
        .resolve
    else if (std.mem.eql(u8, args[0], "set-api-key"))
        .set_api_key
    else if (std.mem.eql(u8, args[0], "set-oauth"))
        .set_oauth
    else if (std.mem.eql(u8, args[0], "remove") or std.mem.eql(u8, args[0], "logout"))
        .remove
    else if (std.mem.eql(u8, args[0], "providers"))
        .providers
    else
        return null;

    var options = Options{ .command = command };
    var positionals: [5][]const u8 = undefined;
    var positional_len: usize = 0;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            options.invalid_option = options.invalid_option orelse arg;
            continue;
        }
        if (positional_len >= positionals.len) {
            options.invalid_argument = options.invalid_argument orelse arg;
            continue;
        }
        positionals[positional_len] = arg;
        positional_len += 1;
    }

    switch (command) {
        .list, .providers => {
            if (positional_len > 0) options.invalid_argument = options.invalid_argument orelse positionals[0];
        },
        .status, .resolve, .remove => {
            if (positional_len < 1) {
                options.missing_argument = "Missing provider.";
            } else {
                options.provider = positionals[0];
            }
            if (positional_len > 1) options.invalid_argument = options.invalid_argument orelse positionals[1];
        },
        .set_api_key => {
            if (positional_len < 2) {
                options.missing_argument = "Usage: pi-zig auth set-api-key <provider> <key>";
            } else {
                options.provider = positionals[0];
                options.api_key = positionals[1];
            }
            if (positional_len > 2) options.invalid_argument = options.invalid_argument orelse positionals[2];
        },
        .set_oauth => {
            if (positional_len < 4) {
                options.missing_argument = "Usage: pi-zig auth set-oauth <provider> <access> <refresh> <expires-ms>";
            } else {
                options.provider = positionals[0];
                options.access = positionals[1];
                options.refresh = positionals[2];
                options.expires = std.fmt.parseInt(i64, positionals[3], 10) catch {
                    options.missing_argument = "OAuth expires value must be an epoch timestamp in milliseconds.";
                    return options;
                };
            }
            if (positional_len > 4) options.invalid_argument = options.invalid_argument orelse positionals[4];
        },
    }
    return options;
}

fn writeHelp(io: std.Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  pi-zig auth list [--json]
        \\  pi-zig auth status <provider> [--json]
        \\  pi-zig auth resolve <provider> [--json]
        \\  pi-zig auth set-api-key <provider> <key>
        \\  pi-zig auth set-oauth <provider> <access> <refresh> <expires-ms>
        \\  pi-zig auth remove <provider>
        \\  pi-zig auth providers [--json]
        \\
        \\Credential storage uses ~/.pi/agent/auth.json, or PI_CODING_AGENT_DIR/auth.json.
        \\API key values follow upstream config resolution: !shell commands, env vars, then literals.
        \\
    );
}

fn listStored(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, json: bool) !void {
    var parsed = try loadAuth(io, allocator, env);
    defer parsed.deinit();

    if (parsed.value != .object) {
        try writeStderr(io, "Invalid auth storage: root must be an object.\n");
        std.process.exit(1);
    }

    if (json) {
        try writeStdout(io, "{\"providers\":[");
        var first = true;
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            if (!first) try writeStdout(io, ",");
            first = false;
            try writeStdout(io, "{\"provider\":");
            try writeJsonString(io, entry.key_ptr.*);
            try writeStdout(io, ",\"type\":");
            try writeJsonString(io, credentialType(entry.value_ptr.*) orelse "unknown");
            try writeStdout(io, "}");
        }
        try writeStdout(io, "]}\n");
        return;
    }

    var count: usize = 0;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        count += 1;
        try writeStdout(io, entry.key_ptr.*);
        try writeStdout(io, " ");
        try writeStdout(io, credentialType(entry.value_ptr.*) orelse "unknown");
        try writeStdout(io, "\n");
    }
    if (count == 0) try writeStdout(io, "No auth credentials stored.\n");
}

fn writeStatus(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, provider: []const u8, json: bool) !void {
    var parsed = try loadAuth(io, allocator, env);
    defer parsed.deinit();
    const status = authStatus(env, parsed.value, provider);
    if (json) {
        try writeStatusJson(io, provider, status);
        return;
    }
    try writeStdout(io, provider);
    try writeStdout(io, ": ");
    if (!status.has_auth) {
        try writeStdout(io, "not configured\n");
        return;
    }
    try writeStdout(io, status.source orelse "unknown");
    if (status.label) |label| {
        try writeStdout(io, " ");
        try writeStdout(io, label);
    }
    if (status.credential_type) |kind| {
        try writeStdout(io, " ");
        try writeStdout(io, kind);
    }
    try writeStdout(io, "\n");
}

fn resolveCommand(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, provider: []const u8, json: bool) !void {
    var parsed = try loadAuth(io, allocator, env);
    defer parsed.deinit();
    const resolved = try resolveApiKey(io, allocator, env, parsed.value, provider);
    defer if (resolved) |value| allocator.free(value);

    if (json) {
        try writeStdout(io, "{\"provider\":");
        try writeJsonString(io, provider);
        try writeStdout(io, ",\"resolved\":");
        try writeStdout(io, if (resolved != null) "true" else "false");
        try writeStdout(io, ",\"value\":");
        if (resolved) |value| {
            try writeJsonString(io, value);
        } else {
            try writeStdout(io, "null");
        }
        try writeStdout(io, "}\n");
        return;
    }

    if (resolved) |value| {
        try writeStdout(io, value);
        try writeStdout(io, "\n");
    } else {
        try writeStderr(io, "No API key found for ");
        try writeStderr(io, provider);
        try writeStderr(io, ".\n");
        std.process.exit(1);
    }
}

fn setApiKey(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, provider: []const u8, key: []const u8) !void {
    var parsed = try loadAuth(io, allocator, env);
    defer parsed.deinit();
    const root = try ensureRootObject(allocator, &parsed.value);
    var credential: std.json.ObjectMap = .empty;
    try credential.put(allocator, "type", .{ .string = "api_key" });
    try credential.put(allocator, "key", .{ .string = key });
    try root.put(allocator, provider, .{ .object = credential });
    try writeAuth(io, allocator, env, parsed.value);
    try writeStdout(io, "Stored API key credential for ");
    try writeStdout(io, provider);
    try writeStdout(io, "\n");
}

fn setOAuth(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    provider: []const u8,
    access: []const u8,
    refresh: []const u8,
    expires: i64,
) !void {
    var parsed = try loadAuth(io, allocator, env);
    defer parsed.deinit();
    const root = try ensureRootObject(allocator, &parsed.value);
    var credential: std.json.ObjectMap = .empty;
    try credential.put(allocator, "type", .{ .string = "oauth" });
    try credential.put(allocator, "access", .{ .string = access });
    try credential.put(allocator, "refresh", .{ .string = refresh });
    try credential.put(allocator, "expires", .{ .integer = expires });
    try root.put(allocator, provider, .{ .object = credential });
    try writeAuth(io, allocator, env, parsed.value);
    try writeStdout(io, "Stored OAuth credential for ");
    try writeStdout(io, provider);
    try writeStdout(io, "\n");
}

fn removeProvider(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, provider: []const u8) !void {
    var parsed = try loadAuth(io, allocator, env);
    defer parsed.deinit();
    if (parsed.value != .object or !parsed.value.object.swapRemove(provider)) {
        try writeStderr(io, "No stored auth credential for ");
        try writeStderr(io, provider);
        try writeStderr(io, ".\n");
        std.process.exit(1);
    }
    try writeAuth(io, allocator, env, parsed.value);
    try writeStdout(io, "Removed auth credential for ");
    try writeStdout(io, provider);
    try writeStdout(io, "\n");
}

fn listOAuthProviders(io: std.Io, json: bool) !void {
    const ids = [_]struct { id: []const u8, name: []const u8 }{
        .{ .id = "anthropic", .name = "Anthropic Console OAuth" },
        .{ .id = "github-copilot", .name = "GitHub Copilot" },
        .{ .id = "openai-codex", .name = "ChatGPT Plus/Pro (Codex Subscription)" },
    };
    if (json) {
        try writeStdout(io, "{\"providers\":[");
        for (ids, 0..) |provider, i| {
            if (i != 0) try writeStdout(io, ",");
            try writeStdout(io, "{\"id\":");
            try writeJsonString(io, provider.id);
            try writeStdout(io, ",\"name\":");
            try writeJsonString(io, provider.name);
            try writeStdout(io, "}");
        }
        try writeStdout(io, "]}\n");
        return;
    }
    for (ids) |provider| {
        try writeStdout(io, provider.id);
        try writeStdout(io, " - ");
        try writeStdout(io, provider.name);
        try writeStdout(io, "\n");
    }
}

fn authStatus(env: *const std.process.Environ.Map, root: std.json.Value, provider: []const u8) AuthStatus {
    if (root == .object) {
        if (root.object.get(provider)) |credential| {
            return .{
                .has_auth = true,
                .configured = true,
                .source = "stored",
                .credential_type = credentialType(credential),
            };
        }
    }
    if (findEnvKey(env, provider)) |key| {
        return .{ .has_auth = true, .configured = false, .source = "environment", .label = key };
    }
    if (hasAmbientProviderAuth(env, provider)) |label| {
        return .{ .has_auth = true, .configured = false, .source = "environment", .label = label };
    }
    return .{ .has_auth = false, .configured = false };
}

fn resolveApiKey(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    root: std.json.Value,
    provider: []const u8,
) !?[]u8 {
    if (root == .object) {
        if (root.object.get(provider)) |credential| {
            if (credential == .object) {
                const kind = credentialType(credential) orelse "";
                if (std.mem.eql(u8, kind, "api_key")) {
                    const key = credential.object.get("key") orelse return null;
                    if (key != .string) return null;
                    return try resolveConfigValue(io, allocator, env, key.string);
                }
                if (std.mem.eql(u8, kind, "oauth")) {
                    const access = credential.object.get("access") orelse return null;
                    const expires = credential.object.get("expires") orelse return null;
                    if (access != .string or expires != .integer) return null;
                    if (expires.integer <= std.Io.Clock.real.now(io).toMilliseconds()) {
                        try writeStderr(io, "OAuth credential for ");
                        try writeStderr(io, provider);
                        try writeStderr(io, " is expired; refresh is not implemented yet.\n");
                        return null;
                    }
                    return try allocator.dupe(u8, access.string);
                }
            }
        }
    }
    if (findEnvKey(env, provider)) |key| {
        if (env.get(key)) |value| return try allocator.dupe(u8, value);
    }
    if (hasAmbientProviderAuth(env, provider) != null) return try allocator.dupe(u8, "<authenticated>");
    return null;
}

fn resolveConfigValue(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    value: []const u8,
) !?[]u8 {
    if (std.mem.startsWith(u8, value, "!")) {
        return executeShellConfig(io, allocator, value[1..]);
    }
    if (env.get(value)) |env_value| {
        return try allocator.dupe(u8, env_value);
    }
    return try allocator.dupe(u8, value);
}

fn executeShellConfig(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !?[]u8 {
    const argv = [_][]const u8{ "sh", "-c", command };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(0),
        .expand_arg0 = .expand,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn credentialType(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const kind = value.object.get("type") orelse return null;
    if (kind != .string) return null;
    return kind.string;
}

fn findEnvKey(env: *const std.process.Environ.Map, provider: []const u8) ?[]const u8 {
    const keys = providers.envKeysFor(provider) orelse return null;
    for (keys) |key| {
        if (env.get(key)) |value| {
            if (value.len > 0) return key;
        }
    }
    return null;
}

fn hasAmbientProviderAuth(env: *const std.process.Environ.Map, provider: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider, "google-vertex")) {
        const has_project = hasAnyEnv(env, &.{ "GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT" });
        const has_location = hasAnyEnv(env, &.{"GOOGLE_CLOUD_LOCATION"});
        if (has_project and has_location and hasAnyEnv(env, &.{"GOOGLE_CLOUD_ACCESS_TOKEN"})) {
            return "GOOGLE_CLOUD_ACCESS_TOKEN";
        }
        if (has_project and has_location and hasAnyEnv(env, &.{"GOOGLE_APPLICATION_CREDENTIALS"})) {
            return "GOOGLE_APPLICATION_CREDENTIALS";
        }
    }
    if (std.mem.eql(u8, provider, "amazon-bedrock")) {
        if (hasAnyEnv(env, &.{ "AWS_PROFILE", "AWS_BEARER_TOKEN_BEDROCK", "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_WEB_IDENTITY_TOKEN_FILE" })) {
            return "AWS_PROFILE/AWS_*";
        }
        if (hasAnyEnv(env, &.{"AWS_ACCESS_KEY_ID"}) and hasAnyEnv(env, &.{"AWS_SECRET_ACCESS_KEY"})) {
            return "AWS_ACCESS_KEY_ID";
        }
    }
    return null;
}

fn hasAnyEnv(env: *const std.process.Environ.Map, keys: []const []const u8) bool {
    for (keys) |key| {
        if (env.get(key)) |value| {
            if (value.len > 0) return true;
        }
    }
    return false;
}

fn loadAuth(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !std.json.Parsed(std.json.Value) {
    const path = try authPath(allocator, env);
    defer allocator.free(path);
    ensureAuthFile(io, allocator, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_auth_bytes));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn writeAuth(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, value: std.json.Value) !void {
    const path = try authPath(allocator, env);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

fn ensureAuthFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| return else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{}\n" });
    _ = allocator;
}

fn ensureRootObject(allocator: std.mem.Allocator, value: *std.json.Value) !*std.json.ObjectMap {
    _ = allocator;
    if (value.* != .object) value.* = .{ .object = .empty };
    return &value.object;
}

fn authPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const dir = try agentDir(allocator, env);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "auth.json" });
}

fn agentDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("PI_CODING_AGENT_DIR")) |value| return expandMaybeTilde(allocator, env, value);
    const home = env.get("HOME") orelse ".";
    return std.fs.path.join(allocator, &.{ home, ".pi", "agent" });
}

fn expandMaybeTilde(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, env.get("HOME") orelse ".");
    if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(allocator, &.{ env.get("HOME") orelse ".", path[2..] });
    return allocator.dupe(u8, path);
}

fn writeStatusJson(io: std.Io, provider: []const u8, status: AuthStatus) !void {
    try writeStdout(io, "{\"provider\":");
    try writeJsonString(io, provider);
    try writeStdout(io, ",\"configured\":");
    try writeStdout(io, if (status.configured) "true" else "false");
    try writeStdout(io, ",\"hasAuth\":");
    try writeStdout(io, if (status.has_auth) "true" else "false");
    try writeStdout(io, ",\"source\":");
    if (status.source) |source| {
        try writeJsonString(io, source);
    } else {
        try writeStdout(io, "null");
    }
    try writeStdout(io, ",\"label\":");
    if (status.label) |label| {
        try writeJsonString(io, label);
    } else {
        try writeStdout(io, "null");
    }
    try writeStdout(io, ",\"type\":");
    if (status.credential_type) |kind| {
        try writeJsonString(io, kind);
    } else {
        try writeStdout(io, "null");
    }
    try writeStdout(io, "}\n");
}

fn writeJsonString(io: std.Io, value: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    defer writer.interface.flush() catch {};
    try std.json.Stringify.encodeJsonString(value, .{}, &writer.interface);
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeStderr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

test "stored API key status reports stored auth" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"openai\":{\"type\":\"api_key\",\"key\":\"OPENAI_API_KEY\"}}", .{});
    defer value.deinit();
    const status = authStatus(&env, value.value, "openai");
    try std.testing.expect(status.has_auth);
    try std.testing.expect(status.configured);
    try std.testing.expectEqualStrings("stored", status.source.?);
}

test "provider env map participates in auth status" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("OPENAI_API_KEY", "test-key");
    const value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer value.deinit();
    const status = authStatus(&env, value.value, "openai");
    try std.testing.expect(status.has_auth);
    try std.testing.expect(!status.configured);
    try std.testing.expectEqualStrings("environment", status.source.?);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", status.label.?);
}

test "Google Vertex access token participates in ambient auth status" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GOOGLE_CLOUD_PROJECT", "test-project");
    try env.put("GOOGLE_CLOUD_LOCATION", "us-central1");
    try env.put("GOOGLE_CLOUD_ACCESS_TOKEN", "ya29.vertex-token");
    const value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer value.deinit();

    const status = authStatus(&env, value.value, "google-vertex");
    try std.testing.expect(status.has_auth);
    try std.testing.expect(!status.configured);
    try std.testing.expectEqualStrings("environment", status.source.?);
    try std.testing.expectEqualStrings("GOOGLE_CLOUD_ACCESS_TOKEN", status.label.?);

    const resolved = try resolveApiKey(std.testing.io, std.testing.allocator, &env, value.value, "google-vertex");
    defer if (resolved) |api_key| std.testing.allocator.free(api_key);
    try std.testing.expectEqualStrings("<authenticated>", resolved.?);
}

test "stored Google Vertex OAuth resolves to access token for bearer routing" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"google-vertex\":{\"type\":\"oauth\",\"access\":\"ya29.stored-oauth-token\",\"refresh\":\"refresh-token\",\"expires\":4102444800000}}",
        .{},
    );
    defer value.deinit();

    const resolved = try resolveApiKey(std.testing.io, std.testing.allocator, &env, value.value, "google-vertex");
    defer if (resolved) |api_key| std.testing.allocator.free(api_key);
    try std.testing.expectEqualStrings("ya29.stored-oauth-token", resolved.?);
}

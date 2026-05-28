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
    var refreshed = false;
    const resolved = try resolveApiKeyMutable(io, allocator, env, &parsed.value, provider, &refreshed);
    if (refreshed) writeAuth(io, allocator, env, parsed.value) catch {};
    return resolved;
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
    var refreshed = false;
    const resolved = try resolveApiKeyMutable(io, allocator, env, &parsed.value, provider, &refreshed);
    defer if (resolved) |value| allocator.free(value);
    if (refreshed) writeAuth(io, allocator, env, parsed.value) catch {};

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
    if (json) {
        try writeStdout(io, "{\"providers\":[");
        for (oauth_provider_specs, 0..) |provider, i| {
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
    for (oauth_provider_specs) |provider| {
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
    var root_copy = root;
    return resolveApiKeyMutable(io, allocator, env, &root_copy, provider, null);
}

/// Resolve a provider API key, optionally refreshing expired OAuth tokens.
/// When `refreshed_out` is non-null and a refresh succeeds, the parsed `root`
/// object is updated in place and `refreshed_out.*` is set so the caller can
/// persist the new credentials back to auth.json.
fn resolveApiKeyMutable(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    root_ptr: *std.json.Value,
    provider: []const u8,
    refreshed_out: ?*bool,
) !?[]u8 {
    const root = root_ptr.*;
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
                    if (expires.integer > std.Io.Clock.real.now(io).toMilliseconds()) {
                        return try allocator.dupe(u8, access.string);
                    }
                    return resolveExpiredOAuth(io, allocator, env, root_ptr, provider, credential, refreshed_out);
                }
            }
        }
    }
    if (findEnvKey(env, provider)) |key| {
        if (env.get(key)) |value| return try allocator.dupe(u8, value);
    }
    if (std.mem.eql(u8, provider, "google-vertex")) {
        // Only the disk-backed callers (which pass refreshed_out) may mint a Vertex
        // access token over the network, mirroring how resolveExpiredOAuth gates its
        // refresh. When GOOGLE_CLOUD_ACCESS_TOKEN is present, ai_client resolves the
        // bearer from env via the <authenticated> placeholder, so ADC minting is only
        // attempted when Application Default Credentials are the credential source.
        if (refreshed_out != null and !hasAnyEnv(env, &.{"GOOGLE_CLOUD_ACCESS_TOKEN"})) {
            if (try mintVertexAdcToken(io, allocator, env)) |access_token| {
                return access_token;
            }
        }
    }
    if (hasAmbientProviderAuth(env, provider) != null) return try allocator.dupe(u8, "<authenticated>");
    return null;
}

fn resolveExpiredOAuth(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    root_ptr: *std.json.Value,
    provider: []const u8,
    credential: std.json.Value,
    refreshed_out: ?*bool,
) !?[]u8 {
    // Only the disk-backed callers (which pass refreshed_out) may perform a network
    // refresh and persist the result; the pure resolveApiKey path stays side-effect free.
    const flag = refreshed_out orelse {
        try writeStderr(io, "OAuth credential for ");
        try writeStderr(io, provider);
        try writeStderr(io, " is expired.\n");
        return null;
    };

    if (oauthProviderSpec(provider) == null) {
        try writeStderr(io, "OAuth credential for ");
        try writeStderr(io, provider);
        try writeStderr(io, " is expired and no refresh provider is registered.\n");
        return null;
    }

    var refreshed = refreshOAuthCredential(io, allocator, env, provider, credential) catch {
        try writeStderr(io, "OAuth token refresh failed for ");
        try writeStderr(io, provider);
        try writeStderr(io, "; credential preserved for retry.\n");
        return null;
    } orelse return null;
    defer refreshed.deinit(allocator);

    const access_copy = try allocator.dupe(u8, refreshed.access);
    errdefer allocator.free(access_copy);

    // Update the in-memory credential so the caller can persist it back to auth.json.
    try updateStoredOAuthCredential(allocator, root_ptr, provider, refreshed);
    flag.* = true;
    return access_copy;
}

fn updateStoredOAuthCredential(
    allocator: std.mem.Allocator,
    root_ptr: *std.json.Value,
    provider: []const u8,
    refreshed: RefreshedOAuth,
) !void {
    if (root_ptr.* != .object) return;
    var credential: std.json.ObjectMap = .empty;
    try credential.put(allocator, "type", .{ .string = "oauth" });
    try credential.put(allocator, "access", .{ .string = try allocator.dupe(u8, refreshed.access) });
    try credential.put(allocator, "refresh", .{ .string = try allocator.dupe(u8, refreshed.refresh) });
    try credential.put(allocator, "expires", .{ .integer = refreshed.expires });
    if (refreshed.account_id) |account_id| {
        try credential.put(allocator, "accountId", .{ .string = try allocator.dupe(u8, account_id) });
    }
    try root_ptr.object.put(allocator, provider, .{ .object = credential });
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

const max_oauth_response_bytes = 64 * 1024;

const OAuthGrant = enum { post_json, post_form, copilot_bearer };

const OAuthProviderSpec = struct {
    id: []const u8,
    name: []const u8,
    client_id: []const u8,
    token_url: []const u8,
    grant: OAuthGrant,
    /// Subtracted from the absolute expiry to refresh slightly ahead of the deadline.
    expiry_skew_ms: i64,
    requires_account_id: bool = false,
};

// Mirrors upstream BUILT_IN_OAUTH_PROVIDERS (packages/ai/src/utils/oauth/index.ts).
// Refresh request shapes match the provider modules under utils/oauth/*.ts.
const oauth_provider_specs = [_]OAuthProviderSpec{
    .{
        .id = "anthropic",
        .name = "Anthropic (Claude Pro/Max)",
        .client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        .token_url = "https://platform.claude.com/v1/oauth/token",
        .grant = .post_json,
        .expiry_skew_ms = 5 * 60 * 1000,
    },
    .{
        .id = "github-copilot",
        .name = "GitHub Copilot",
        .client_id = "Iv1.b507a08c87ecfe98",
        .token_url = "https://api.github.com/copilot_internal/v2/token",
        .grant = .copilot_bearer,
        .expiry_skew_ms = 5 * 60 * 1000,
    },
    .{
        .id = "openai-codex",
        .name = "ChatGPT Plus/Pro (Codex Subscription)",
        .client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
        .token_url = "https://auth.openai.com/oauth/token",
        .grant = .post_form,
        .expiry_skew_ms = 0,
        .requires_account_id = true,
    },
};

fn oauthProviderSpec(provider: []const u8) ?OAuthProviderSpec {
    for (oauth_provider_specs) |spec| {
        if (std.mem.eql(u8, spec.id, provider)) return spec;
    }
    return null;
}

const RefreshedOAuth = struct {
    access: []u8,
    refresh: []u8,
    expires: i64,
    account_id: ?[]u8 = null,

    fn deinit(self: *RefreshedOAuth, allocator: std.mem.Allocator) void {
        allocator.free(self.access);
        allocator.free(self.refresh);
        if (self.account_id) |value| allocator.free(value);
    }
};

/// Refresh an OAuth access token using the provider's documented token endpoint.
/// Returns freshly allocated credentials, or null when the provider is unknown.
/// Errors propagate as visible refresh failures (parity with upstream throwing).
fn refreshOAuthCredential(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    provider: []const u8,
    credential: std.json.Value,
) !?RefreshedOAuth {
    const spec = oauthProviderSpec(provider) orelse return null;
    if (credential != .object) return error.OAuthRefreshFailed;
    const refresh_value = credential.object.get("refresh") orelse return error.OAuthRefreshFailed;
    if (refresh_value != .string) return error.OAuthRefreshFailed;
    const refresh_token = refresh_value.string;

    // Test/integration override mirrors PI_ZIG_PROVIDER_BASE_URL used by ai_client transports.
    const token_url = env.get("PI_ZIG_OAUTH_TOKEN_URL") orelse spec.token_url;

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = switch (spec.grant) {
        .post_json => blk: {
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"grant_type\":\"refresh_token\",\"client_id\":\"{s}\",\"refresh_token\":\"{s}\"}}",
                .{ spec.client_id, refresh_token },
            );
            defer allocator.free(payload);
            break :blk try client.fetch(.{
                .location = .{ .url = token_url },
                .method = .POST,
                .payload = payload,
                .response_writer = &response_body.writer,
                .headers = .{
                    .content_type = .{ .override = "application/json" },
                    .accept_encoding = .{ .override = "identity" },
                },
                .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
            });
        },
        .post_form => blk: {
            const payload = try std.fmt.allocPrint(
                allocator,
                "grant_type=refresh_token&refresh_token={s}&client_id={s}",
                .{ refresh_token, spec.client_id },
            );
            defer allocator.free(payload);
            break :blk try client.fetch(.{
                .location = .{ .url = token_url },
                .method = .POST,
                .payload = payload,
                .response_writer = &response_body.writer,
                .headers = .{
                    .content_type = .{ .override = "application/x-www-form-urlencoded" },
                    .accept_encoding = .{ .override = "identity" },
                },
            });
        },
        .copilot_bearer => blk: {
            const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{refresh_token});
            defer allocator.free(authorization);
            break :blk try client.fetch(.{
                .location = .{ .url = token_url },
                .method = .GET,
                .response_writer = &response_body.writer,
                .headers = .{
                    .authorization = .{ .override = authorization },
                    .user_agent = .{ .override = "GitHubCopilotChat/0.35.0" },
                    .accept_encoding = .{ .override = "identity" },
                },
                .extra_headers = &.{
                    .{ .name = "accept", .value = "application/json" },
                    .{ .name = "editor-version", .value = "vscode/1.107.0" },
                    .{ .name = "editor-plugin-version", .value = "copilot-chat/0.35.0" },
                    .{ .name = "copilot-integration-id", .value = "vscode-chat" },
                },
            });
        },
    };
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.OAuthRefreshFailed;
    }

    return try parseRefreshResponse(io, allocator, spec, refresh_token, response_body.written());
}

fn parseRefreshResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    spec: OAuthProviderSpec,
    refresh_token: []const u8,
    body: []const u8,
) !RefreshedOAuth {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.OAuthRefreshFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.OAuthRefreshFailed;
    const root = parsed.value.object;

    if (spec.grant == .copilot_bearer) {
        // GitHub Copilot returns {token, expires_at}; the GitHub access token doubles as the refresh token.
        const token = root.get("token") orelse return error.OAuthRefreshFailed;
        const expires_at = root.get("expires_at") orelse return error.OAuthRefreshFailed;
        if (token != .string or expires_at != .integer) return error.OAuthRefreshFailed;
        return .{
            .access = try allocator.dupe(u8, token.string),
            .refresh = try allocator.dupe(u8, refresh_token),
            .expires = expires_at.integer * 1000 - spec.expiry_skew_ms,
        };
    }

    const access = root.get("access_token") orelse return error.OAuthRefreshFailed;
    const refresh = root.get("refresh_token") orelse return error.OAuthRefreshFailed;
    const expires_in = root.get("expires_in") orelse return error.OAuthRefreshFailed;
    if (access != .string or refresh != .string or expires_in != .integer) return error.OAuthRefreshFailed;

    var account_id: ?[]u8 = null;
    errdefer if (account_id) |value| allocator.free(value);
    if (spec.requires_account_id) {
        account_id = (try chatGptAccountIdFromAccessToken(allocator, access.string)) orelse return error.OAuthRefreshFailed;
    }

    return .{
        .access = try allocator.dupe(u8, access.string),
        .refresh = try allocator.dupe(u8, refresh.string),
        .expires = std.Io.Clock.real.now(io).toMilliseconds() + expires_in.integer * 1000 - spec.expiry_skew_ms,
        .account_id = account_id,
    };
}

/// Extract the chatgpt_account_id claim from an OpenAI Codex JWT access token.
/// Mirrors upstream getAccountId (packages/ai/src/utils/oauth/openai-codex.ts).
fn chatGptAccountIdFromAccessToken(allocator: std.mem.Allocator, access_token: []const u8) !?[]u8 {
    var parts = std.mem.splitScalar(u8, access_token, '.');
    _ = parts.next() orelse return null;
    const payload_b64 = parts.next() orelse return null;
    if (parts.next() == null) return null;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const trimmed = std.mem.trimEnd(u8, payload_b64, "=");
    const decoded_len = decoder.calcSizeForSlice(trimmed) catch return null;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    decoder.decode(decoded, trimmed) catch return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const auth_claim = parsed.value.object.get("https://api.openai.com/auth") orelse return null;
    if (auth_claim != .object) return null;
    const account_id = auth_claim.object.get("chatgpt_account_id") orelse return null;
    if (account_id != .string or account_id.string.len == 0) return null;
    return try allocator.dupe(u8, account_id.string);
}

// --- Google Vertex Application Default Credentials (ADC) ---------------------
//
// gcloud writes Application Default Credentials to a JSON file containing one of
// two grant types:
//
//   * authorized_user: { client_id, client_secret, refresh_token, type }. We
//     exchange the refresh_token at Google's OAuth2 token endpoint for a
//     short-lived ya29.* access token (the same request @google/genai's GoogleAuth
//     issues).
//   * service_account: { client_email, private_key, token_uri, type, ... }. We
//     build and RS256-sign a JWT assertion with the service-account private key
//     (RFC 7523 jwt-bearer grant) and exchange it for an access token. RS256
//     signing is implemented over std.crypto primitives (SHA-256 + RSA modular
//     exponentiation via std.crypto.ff); no external SDK is used.
//
// Upstream's Vertex provider delegates to @google/genai; both flows mirror what
// GoogleAuth performs for the corresponding credential file.

const google_oauth_token_url = "https://oauth2.googleapis.com/token";
const google_token_scope = "https://www.googleapis.com/auth/cloud-platform";
const jwt_bearer_grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer";

/// Resolution order for the ADC file path:
///   1. GOOGLE_APPLICATION_CREDENTIALS (explicit override, gcloud-standard env var)
///   2. $CLOUDSDK_CONFIG/application_default_credentials.json
///   3. $HOME/.config/gcloud/application_default_credentials.json (gcloud default)
/// Returns null when no candidate path exists on disk.
fn vertexAdcPath(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("GOOGLE_APPLICATION_CREDENTIALS")) |explicit| {
        const trimmed = std.mem.trim(u8, explicit, " \t\r\n");
        if (trimmed.len > 0) return try expandMaybeTilde(allocator, env, trimmed);
    }
    if (env.get("CLOUDSDK_CONFIG")) |config_dir| {
        const trimmed = std.mem.trim(u8, config_dir, " \t\r\n");
        if (trimmed.len > 0) {
            const expanded = try expandMaybeTilde(allocator, env, trimmed);
            defer allocator.free(expanded);
            const path = try std.fs.path.join(allocator, &.{ expanded, "application_default_credentials.json" });
            if (try fileExists(io, path)) return path;
            allocator.free(path);
        }
    }
    if (env.get("HOME")) |home| {
        const path = try std.fs.path.join(allocator, &.{ home, ".config", "gcloud", "application_default_credentials.json" });
        if (try fileExists(io, path)) return path;
        allocator.free(path);
    }
    return null;
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| {
        return true;
    } else |err| switch (err) {
        error.FileNotFound => return false,
        else => return false,
    }
}

/// Authorized-user fields parsed from an ADC file. Slices borrow from `parsed`.
const VertexAuthorizedUser = struct {
    client_id: []const u8,
    client_secret: []const u8,
    refresh_token: []const u8,
};

/// Service-account fields parsed from an ADC file. Slices borrow from `parsed`.
const VertexServiceAccount = struct {
    client_email: []const u8,
    private_key: []const u8,
    token_uri: []const u8,
};

/// A parsed Vertex ADC credential, tagged by grant type.
const VertexAdc = union(enum) {
    authorized_user: VertexAuthorizedUser,
    service_account: VertexServiceAccount,
};

const VertexAdcError = error{
    AdcMalformed,
};

/// Parse an ADC JSON document into its grant-type-specific fields. Both the
/// authorized_user and service_account grants are supported. Returns AdcMalformed
/// when the required fields for the detected type are missing.
fn parseVertexAdc(root: std.json.Value) VertexAdcError!VertexAdc {
    if (root != .object) return error.AdcMalformed;
    const obj = root.object;

    const is_service_account = blk: {
        const kind = obj.get("type") orelse break :blk false;
        break :blk kind == .string and std.mem.eql(u8, kind.string, "service_account");
    };

    if (is_service_account) {
        const client_email = obj.get("client_email") orelse return error.AdcMalformed;
        const private_key = obj.get("private_key") orelse return error.AdcMalformed;
        if (client_email != .string or private_key != .string) return error.AdcMalformed;
        if (client_email.string.len == 0 or private_key.string.len == 0) return error.AdcMalformed;
        // token_uri is optional in the file; default to Google's standard endpoint.
        const token_uri = blk: {
            const value = obj.get("token_uri") orelse break :blk google_oauth_token_url;
            break :blk if (value == .string and value.string.len > 0) value.string else google_oauth_token_url;
        };
        return .{ .service_account = .{
            .client_email = client_email.string,
            .private_key = private_key.string,
            .token_uri = token_uri,
        } };
    }

    const client_id = obj.get("client_id") orelse return error.AdcMalformed;
    const client_secret = obj.get("client_secret") orelse return error.AdcMalformed;
    const refresh_token = obj.get("refresh_token") orelse return error.AdcMalformed;
    if (client_id != .string or client_secret != .string or refresh_token != .string) return error.AdcMalformed;
    if (client_id.string.len == 0 or refresh_token.string.len == 0) return error.AdcMalformed;

    return .{ .authorized_user = .{
        .client_id = client_id.string,
        .client_secret = client_secret.string,
        .refresh_token = refresh_token.string,
    } };
}

/// Read, parse, and exchange the ADC refresh_token for a Vertex access token.
/// Returns a freshly allocated ya29.* bearer on success, or null when:
///   - no ADC file is present,
///   - the file is a service_account key (unsupported), or
///   - the file/token exchange is malformed or fails.
/// Never throws on the absent-credentials path so callers degrade cleanly.
fn mintVertexAdcToken(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    const path = (try vertexAdcPath(io, allocator, env)) orelse return null;
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_auth_bytes)) catch {
        // [VERTEX_ADC_DEBUG] ADC path resolved but file unreadable; degrade to placeholder routing.
        return null;
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        // [VERTEX_ADC_DEBUG] ADC file is not valid JSON.
        return null;
    };
    defer parsed.deinit();

    const adc = parseVertexAdc(parsed.value) catch |err| switch (err) {
        error.AdcMalformed => {
            // [VERTEX_ADC_DEBUG] ADC file missing required fields for its grant type.
            return null;
        },
    };

    switch (adc) {
        .authorized_user => |authorized_user| {
            const minted = exchangeVertexAdc(io, allocator, env, authorized_user) catch {
                // Never log the refresh_token/client_secret; report the failure shape only.
                try writeStderr(io, "Vertex ADC token exchange failed; falling back to ambient credential routing.\n");
                return null;
            };
            return minted;
        },
        .service_account => |service_account| {
            const minted = mintServiceAccountToken(io, allocator, env, service_account) catch {
                // Never log the private_key or signed assertion; report the shape only.
                try writeStderr(io, "Vertex ADC service_account token mint failed; falling back to ambient credential routing.\n");
                return null;
            };
            return minted;
        },
    }
}

/// Exchange the ADC refresh_token at Google's OAuth2 token endpoint using the
/// form-encoded grant_type=refresh_token flow (the same request @google/genai's
/// GoogleAuth issues). Returns a freshly allocated access token.
fn exchangeVertexAdc(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    adc: VertexAuthorizedUser,
) ![]u8 {
    // Test/integration override mirrors the PI_ZIG_OAUTH_TOKEN_URL hook used by
    // refreshOAuthCredential so a fake token server can stand in for Google.
    const token_url = env.get("PI_ZIG_OAUTH_TOKEN_URL") orelse google_oauth_token_url;

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const payload = try std.fmt.allocPrint(
        allocator,
        "grant_type=refresh_token&client_id={s}&client_secret={s}&refresh_token={s}",
        .{ adc.client_id, adc.client_secret, adc.refresh_token },
    );
    defer allocator.free(payload);

    const result = try client.fetch(.{
        .location = .{ .url = token_url },
        .method = .POST,
        .payload = payload,
        .response_writer = &response_body.writer,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.VertexAdcExchangeFailed;
    }

    return parseVertexAdcToken(allocator, response_body.written());
}

/// Extract `access_token` from a Google OAuth2 token response.
/// Google returns { access_token, expires_in, scope, token_type } for the
/// authorized_user refresh flow (no rotated refresh_token).
fn parseVertexAdcToken(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.VertexAdcExchangeFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.VertexAdcExchangeFailed;
    const access = parsed.value.object.get("access_token") orelse return error.VertexAdcExchangeFailed;
    if (access != .string or access.string.len == 0) return error.VertexAdcExchangeFailed;
    return try allocator.dupe(u8, access.string);
}

// --- Service-account JWT-bearer mint (RFC 7523) ------------------------------
//
// The service_account ADC flow signs a JWT assertion with the account's RSA
// private key and exchanges it for an access token. The JWT is:
//   header  = base64url({"alg":"RS256","typ":"JWT"})
//   claims  = base64url({"iss":<client_email>,"scope":<scope>,
//                        "aud":<token_uri>,"iat":<now>,"exp":<now+3600>})
//   jwt     = header "." claims "." base64url(RS256(header "." claims))
// where RS256 = RSASSA-PKCS1-v1_5 over SHA-256. We sign using std.crypto: the
// SHA-256 digest is DigestInfo-wrapped + PKCS#1 v1.5 padded to the modulus size,
// then raised to the private exponent modulo the modulus via std.crypto.ff. The
// private key (n, d) is extracted from the PKCS#8 PEM in the ADC file.

const max_rsa_modulus_bits = 4096;
const RsaModulus = std.crypto.ff.Modulus(max_rsa_modulus_bits);
const RsaFe = RsaModulus.Fe;

const ServiceAccountError = error{
    ServiceAccountKeyMalformed,
    ServiceAccountSignFailed,
    VertexAdcExchangeFailed,
};

/// RSA private key material extracted from a PKCS#8 document: the modulus `n` and
/// the private exponent `d`, as big-endian byte slices (allocator-owned).
const RsaPrivateKey = struct {
    modulus: []u8,
    private_exponent: []u8,

    fn deinit(self: *RsaPrivateKey, allocator: std.mem.Allocator) void {
        // Zero the private exponent before freeing — it is secret material.
        @memset(self.private_exponent, 0);
        allocator.free(self.private_exponent);
        allocator.free(self.modulus);
    }
};

/// Build, sign, and exchange a service-account JWT assertion for an access token.
/// Returns the freshly allocated access token. The token endpoint is overridable
/// via PI_ZIG_OAUTH_TOKEN_URL (same hook the other flows use) so a fake server can
/// stand in for Google with no live call and no real key.
fn mintServiceAccountToken(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    account: VertexServiceAccount,
) ![]u8 {
    const token_url = env.get("PI_ZIG_OAUTH_TOKEN_URL") orelse account.token_uri;

    const now_ms = std.Io.Clock.real.now(io).toMilliseconds();
    const now_s = @divTrunc(now_ms, 1000);

    const assertion = try buildSignedServiceAccountJwt(allocator, account, account.token_uri, now_s);
    defer allocator.free(assertion);

    const payload = try std.fmt.allocPrint(
        allocator,
        "grant_type={s}&assertion={s}",
        .{ jwt_bearer_grant_type, assertion },
    );
    defer allocator.free(payload);

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = token_url },
        .method = .POST,
        .payload = payload,
        .response_writer = &response_body.writer,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.VertexAdcExchangeFailed;
    }
    return parseVertexAdcToken(allocator, response_body.written());
}

/// Assemble and RS256-sign a service-account JWT, returning the compact
/// `header.claims.signature` string (allocator-owned). `aud` is the token URI the
/// assertion is bound to (the real Google endpoint, even when the request is
/// redirected to a fake server for testing — the audience claim must match the SA
/// file's token_uri, not the override).
fn buildSignedServiceAccountJwt(
    allocator: std.mem.Allocator,
    account: VertexServiceAccount,
    aud: []const u8,
    iat_seconds: i64,
) ![]u8 {
    const url_encoder = std.base64.url_safe_no_pad.Encoder;

    // Header: {"alg":"RS256","typ":"JWT"} — stable, so encode the literal once.
    const header_json = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    const header_b64 = try base64UrlAlloc(allocator, url_encoder, header_json);
    defer allocator.free(header_b64);

    const exp_seconds = iat_seconds + 3600;
    const claims_json = try std.fmt.allocPrint(
        allocator,
        "{{\"iss\":\"{s}\",\"scope\":\"{s}\",\"aud\":\"{s}\",\"iat\":{d},\"exp\":{d}}}",
        .{ account.client_email, google_token_scope, aud, iat_seconds, exp_seconds },
    );
    defer allocator.free(claims_json);
    const claims_b64 = try base64UrlAlloc(allocator, url_encoder, claims_json);
    defer allocator.free(claims_b64);

    // Signing input is "<header_b64>.<claims_b64>".
    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, claims_b64 });
    defer allocator.free(signing_input);

    var key = try parseRsaPrivateKeyFromPem(allocator, account.private_key);
    defer key.deinit(allocator);

    const signature = try rs256Sign(allocator, key, signing_input);
    defer allocator.free(signature);

    const signature_b64 = try base64UrlAlloc(allocator, url_encoder, signature);
    defer allocator.free(signature_b64);

    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, signature_b64 });
}

fn base64UrlAlloc(allocator: std.mem.Allocator, encoder: std.base64.Base64Encoder, data: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, encoder.calcSize(data.len));
    errdefer allocator.free(buf);
    _ = encoder.encode(buf, data);
    return buf;
}

/// RSASSA-PKCS1-v1_5 sign `message` with SHA-256, returning the raw signature
/// (modulus-length, big-endian, allocator-owned). Mirrors RS256: digest the
/// message, wrap in the SHA-256 DigestInfo, PKCS#1 v1.5 pad to the modulus size,
/// then s = m^d mod n via constant-time modular exponentiation (std.crypto.ff).
fn rs256Sign(allocator: std.mem.Allocator, key: RsaPrivateKey, message: []const u8) ![]u8 {
    const modulus_len = key.modulus.len;
    if (modulus_len == 0 or modulus_len > max_rsa_modulus_bits / 8) return error.ServiceAccountSignFailed;

    // SHA-256 digest of the signing input.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message, &digest, .{});

    // DigestInfo prefix for SHA-256 (RFC 8017 / PKCS#1 v1.5 EMSA).
    const sha256_digest_info = [_]u8{
        0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
        0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
        0x00, 0x04, 0x20,
    };
    const t_len = sha256_digest_info.len + digest.len;
    // EM = 0x00 || 0x01 || PS (0xFF...) || 0x00 || T, where len(EM) == modulus_len.
    // Minimum padding is 8 bytes of 0xFF (RFC 8017 §9.2 step 3).
    if (modulus_len < t_len + 11) return error.ServiceAccountSignFailed;

    const em = try allocator.alloc(u8, modulus_len);
    defer allocator.free(em);
    em[0] = 0x00;
    em[1] = 0x01;
    const ps_len = modulus_len - t_len - 3;
    @memset(em[2 .. 2 + ps_len], 0xFF);
    em[2 + ps_len] = 0x00;
    @memcpy(em[3 + ps_len ..][0..sha256_digest_info.len], &sha256_digest_info);
    @memcpy(em[3 + ps_len + sha256_digest_info.len ..][0..digest.len], &digest);

    // s = EM^d mod n, big-endian, constant-time (secret exponent).
    const modulus = RsaModulus.fromBytes(key.modulus, .big) catch return error.ServiceAccountSignFailed;
    const base = RsaFe.fromBytes(modulus, em, .big) catch return error.ServiceAccountSignFailed;
    const exponent = RsaFe.fromBytes(modulus, key.private_exponent, .big) catch return error.ServiceAccountSignFailed;
    const signed = modulus.pow(base, exponent) catch return error.ServiceAccountSignFailed;

    const out = try allocator.alloc(u8, modulus_len);
    errdefer allocator.free(out);
    signed.toBytes(out, .big) catch {
        allocator.free(out);
        return error.ServiceAccountSignFailed;
    };
    return out;
}

/// Parse a PEM-wrapped PKCS#8 (`-----BEGIN PRIVATE KEY-----`) or PKCS#1
/// (`-----BEGIN RSA PRIVATE KEY-----`) RSA private key, returning the modulus and
/// private exponent. Walks the DER with std.crypto.Certificate.der.Element.
fn parseRsaPrivateKeyFromPem(allocator: std.mem.Allocator, pem: []const u8) !RsaPrivateKey {
    const der = try pemToDer(allocator, pem);
    defer allocator.free(der);
    return parseRsaPrivateKeyDer(allocator, der);
}

/// Decode the base64 body between the first PEM `-----BEGIN ...-----` and
/// `-----END ...-----` markers into raw DER bytes (allocator-owned).
fn pemToDer(allocator: std.mem.Allocator, pem: []const u8) ![]u8 {
    const begin = std.mem.indexOf(u8, pem, "-----BEGIN") orelse return error.ServiceAccountKeyMalformed;
    const body_start_nl = std.mem.indexOfScalarPos(u8, pem, begin, '\n') orelse return error.ServiceAccountKeyMalformed;
    const end = std.mem.indexOfPos(u8, pem, body_start_nl, "-----END") orelse return error.ServiceAccountKeyMalformed;
    const body = pem[body_start_nl + 1 .. end];

    // Strip all whitespace (the SA file stores the key with literal "\n" already
    // un-escaped by JSON parsing, so body contains real newlines).
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(allocator);
    for (body) |c| {
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') continue;
        try cleaned.append(allocator, c);
    }

    const decoder = std.base64.standard.Decoder;
    const der_len = decoder.calcSizeForSlice(cleaned.items) catch return error.ServiceAccountKeyMalformed;
    const der = try allocator.alloc(u8, der_len);
    errdefer allocator.free(der);
    decoder.decode(der, cleaned.items) catch return error.ServiceAccountKeyMalformed;
    return der;
}

const der_mod = std.crypto.Certificate.der;

/// Extract (modulus, privateExponent) from a PKCS#8 PrivateKeyInfo or a bare
/// PKCS#1 RSAPrivateKey DER. PKCS#8 wraps the RSAPrivateKey in an OCTET STRING
/// after a version INTEGER and an AlgorithmIdentifier SEQUENCE.
fn parseRsaPrivateKeyDer(allocator: std.mem.Allocator, der: []const u8) !RsaPrivateKey {
    const outer = der_mod.Element.parse(der, 0) catch return error.ServiceAccountKeyMalformed;
    if (outer.identifier.tag != .sequence) return error.ServiceAccountKeyMalformed;

    const first = der_mod.Element.parse(der, outer.slice.start) catch return error.ServiceAccountKeyMalformed;
    if (first.identifier.tag != .integer) return error.ServiceAccountKeyMalformed;

    // Detect PKCS#8: version INTEGER (0) followed by an AlgorithmIdentifier SEQUENCE
    // and a privateKey OCTET STRING that itself holds the RSAPrivateKey.
    const after_version = der_mod.Element.parse(der, first.slice.end) catch return error.ServiceAccountKeyMalformed;
    if (after_version.identifier.tag == .sequence) {
        const private_key_octets = der_mod.Element.parse(der, after_version.slice.end) catch return error.ServiceAccountKeyMalformed;
        if (private_key_octets.identifier.tag != .octetstring) return error.ServiceAccountKeyMalformed;
        return parsePkcs1RsaPrivateKey(allocator, der, private_key_octets.slice.start);
    }

    // Otherwise treat the outer SEQUENCE as a bare PKCS#1 RSAPrivateKey.
    return parsePkcs1RsaPrivateKey(allocator, der, outer.slice.start);
}

/// Parse a PKCS#1 RSAPrivateKey SEQUENCE whose contents begin at `seq_start`:
///   version, modulus(n), publicExponent(e), privateExponent(d), ...
/// Returns owned big-endian copies of n and d (leading 0x00 sign bytes stripped).
fn parsePkcs1RsaPrivateKey(allocator: std.mem.Allocator, der: []const u8, seq_start: u32) !RsaPrivateKey {
    const seq = der_mod.Element.parse(der, seq_start) catch return error.ServiceAccountKeyMalformed;
    if (seq.identifier.tag != .sequence) return error.ServiceAccountKeyMalformed;

    const version = der_mod.Element.parse(der, seq.slice.start) catch return error.ServiceAccountKeyMalformed;
    if (version.identifier.tag != .integer) return error.ServiceAccountKeyMalformed;
    const modulus_elem = der_mod.Element.parse(der, version.slice.end) catch return error.ServiceAccountKeyMalformed;
    if (modulus_elem.identifier.tag != .integer) return error.ServiceAccountKeyMalformed;
    const public_exp = der_mod.Element.parse(der, modulus_elem.slice.end) catch return error.ServiceAccountKeyMalformed;
    if (public_exp.identifier.tag != .integer) return error.ServiceAccountKeyMalformed;
    const private_exp = der_mod.Element.parse(der, public_exp.slice.end) catch return error.ServiceAccountKeyMalformed;
    if (private_exp.identifier.tag != .integer) return error.ServiceAccountKeyMalformed;

    const modulus = try dupeDerInteger(allocator, der[modulus_elem.slice.start..modulus_elem.slice.end]);
    errdefer allocator.free(modulus);
    const private_exponent = try dupeDerInteger(allocator, der[private_exp.slice.start..private_exp.slice.end]);
    errdefer allocator.free(private_exponent);

    return .{ .modulus = modulus, .private_exponent = private_exponent };
}

/// Copy a DER INTEGER's big-endian magnitude, stripping a single leading 0x00 byte
/// that DER inserts to keep the high bit from signaling a negative value.
fn dupeDerInteger(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var bytes = raw;
    if (bytes.len > 1 and bytes[0] == 0x00) bytes = bytes[1..];
    return allocator.dupe(u8, bytes);
}

// --- AWS ~/.aws/credentials profile resolution (Amazon Bedrock) --------------
//
// The Bedrock SigV4 signer in ai_client consumes IAM credentials from the
// environment (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN).
// When the user instead configures AWS_PROFILE (the common local case), the SDK
// would resolve those keys from the shared credentials file. We mirror just that
// step: parse the requested profile out of ~/.aws/credentials (or
// AWS_SHARED_CREDENTIALS_FILE) and surface its access key / secret / session token
// in the same env-equivalent shape the signer already understands. This is gated
// on AWS_PROFILE being set; container/IMDS credential providers remain out of
// scope (documented SDK-only behavior).

/// IAM credentials resolved from an AWS shared-credentials profile. All slices are
/// allocator-owned; `deinit` zeroes the secret material before freeing.
pub const AwsProfileCredentials = struct {
    access_key_id: []u8,
    secret_access_key: []u8,
    session_token: ?[]u8 = null,
    region: ?[]u8 = null,

    pub fn deinit(self: *AwsProfileCredentials, allocator: std.mem.Allocator) void {
        @memset(self.secret_access_key, 0);
        allocator.free(self.secret_access_key);
        allocator.free(self.access_key_id);
        if (self.session_token) |token| {
            @memset(token, 0);
            allocator.free(token);
        }
        if (self.region) |region| allocator.free(region);
    }
};

/// Resolve IAM credentials for the active AWS profile, mirroring the SDK's shared
/// credentials file lookup. Returns null when AWS_PROFILE is unset, the file is
/// absent/unreadable, or the profile/keys are missing — callers then degrade to
/// the existing env-based signer path. Never prints secrets.
pub fn resolveAwsProfileCredentials(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
) !?AwsProfileCredentials {
    const profile = env.get("AWS_PROFILE") orelse return null;
    const profile_name = std.mem.trim(u8, profile, " \t\r\n");
    if (profile_name.len == 0) return null;

    const path = (try awsCredentialsPath(allocator, env)) orelse return null;
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_auth_bytes)) catch return null;
    defer allocator.free(bytes);

    return parseAwsProfile(allocator, bytes, profile_name);
}

/// Resolution order for the AWS shared credentials file:
///   1. AWS_SHARED_CREDENTIALS_FILE (explicit override, SDK-standard env var)
///   2. $HOME/.aws/credentials (SDK default)
fn awsCredentialsPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("AWS_SHARED_CREDENTIALS_FILE")) |explicit| {
        const trimmed = std.mem.trim(u8, explicit, " \t\r\n");
        if (trimmed.len > 0) return try expandMaybeTilde(allocator, env, trimmed);
    }
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(allocator, &.{ home, ".aws", "credentials" });
}

/// Parse a single `[profile]` section out of an AWS credentials ini file. Supports
/// the bare profile name and the `[profile <name>]` form (used in ~/.aws/config).
/// Returns null when the profile or the required keys are missing.
fn parseAwsProfile(allocator: std.mem.Allocator, contents: []const u8, profile: []const u8) !?AwsProfileCredentials {
    var in_section = false;
    var access_key_id: ?[]const u8 = null;
    var secret_access_key: ?[]const u8 = null;
    var session_token: ?[]const u8 = null;
    var region: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            // Section header. We were collecting the target profile → stop on the
            // next header (ini sections do not nest).
            if (in_section) break;
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            var name = std.mem.trim(u8, line[1..close], " \t");
            // ~/.aws/config uses "[profile foo]"; accept that spelling too.
            if (std.mem.startsWith(u8, name, "profile ")) {
                name = std.mem.trim(u8, name["profile ".len..], " \t");
            }
            in_section = std.mem.eql(u8, name, profile);
            continue;
        }

        if (!in_section) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "aws_access_key_id")) {
            access_key_id = value;
        } else if (std.ascii.eqlIgnoreCase(key, "aws_secret_access_key")) {
            secret_access_key = value;
        } else if (std.ascii.eqlIgnoreCase(key, "aws_session_token")) {
            session_token = value;
        } else if (std.ascii.eqlIgnoreCase(key, "region")) {
            region = value;
        }
    }

    const id = access_key_id orelse return null;
    const secret = secret_access_key orelse return null;
    if (id.len == 0 or secret.len == 0) return null;

    var creds = AwsProfileCredentials{
        .access_key_id = try allocator.dupe(u8, id),
        .secret_access_key = try allocator.dupe(u8, secret),
    };
    errdefer creds.deinit(allocator);
    if (session_token) |token| {
        if (token.len > 0) creds.session_token = try allocator.dupe(u8, token);
    }
    if (region) |value| {
        if (value.len > 0) creds.region = try allocator.dupe(u8, value);
    }
    return creds;
}

// --- Interactive OAuth login scaffold ----------------------------------------
//
// Upstream supports an interactive browser/device-code login that exchanges a
// user authorization for stored OAuth credentials. A full PKCE/device-code loop
// (open browser, run a loopback callback server, poll the device endpoint) is a
// large, network- and TTY-bound surface. This scaffold establishes the opt-in
// entry point and the per-provider parameters; it must SKIP CLEANLY (no crash, no
// secret output) when invoked without the interactive prerequisites, so it is safe
// to wire into the CLI today and fill in the live loop later.

const InteractiveLoginError = error{
    InteractiveLoginUnavailable,
    InteractiveLoginUnsupportedProvider,
};

/// Begin an interactive OAuth login for `provider`. Opt-in only: callers must pass
/// `enabled = true` (e.g. behind an explicit `auth login` subcommand). Returns
/// InteractiveLoginUnavailable when login is not enabled or there is no TTY, and
/// InteractiveLoginUnsupportedProvider for providers without an OAuth spec. The
/// live authorization loop is not yet implemented; this never prints secrets and
/// never blocks, so absent prerequisites degrade cleanly.
pub fn beginInteractiveLogin(
    io: std.Io,
    env: *const std.process.Environ.Map,
    provider: []const u8,
    enabled: bool,
) InteractiveLoginError!void {
    if (!enabled) return error.InteractiveLoginUnavailable;
    if (oauthProviderSpec(provider) == null) return error.InteractiveLoginUnsupportedProvider;
    if (!interactiveLoginAvailable(io, env)) {
        writeStderr(io, "Interactive login requires a terminal; set the credential with `auth set-oauth` instead.\n") catch {};
        return error.InteractiveLoginUnavailable;
    }
    // Live PKCE/device-code authorization loop is not yet implemented. Report the
    // documented limitation rather than faking a credential.
    writeStderr(io, "Interactive OAuth login is not yet implemented for this build; use `auth set-oauth`.\n") catch {};
    return error.InteractiveLoginUnavailable;
}

/// Interactive login needs an attached terminal (a browser/device-code prompt is
/// meaningless in a pipe/CI). PI_OFFLINE disables all startup network operations,
/// so it also disables interactive login.
fn interactiveLoginAvailable(io: std.Io, env: *const std.process.Environ.Map) bool {
    if (envFlagEnabled(env, "PI_OFFLINE")) return false;
    const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
    const stdout_tty = std.Io.File.stdout().isTty(io) catch false;
    return stdin_tty and stdout_tty;
}

fn envFlagEnabled(env: *const std.process.Environ.Map, key: []const u8) bool {
    const value = env.get(key) orelse return false;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.mem.eql(u8, trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes");
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

test "OAuth provider registry matches upstream built-ins" {
    try std.testing.expectEqual(@as(usize, 3), oauth_provider_specs.len);
    try std.testing.expectEqualStrings("anthropic", oauthProviderSpec("anthropic").?.id);
    try std.testing.expectEqualStrings("9d1c250a-e61b-44d9-88ed-5944d1962f5e", oauthProviderSpec("anthropic").?.client_id);
    try std.testing.expect(oauthProviderSpec("anthropic").?.grant == .post_json);
    try std.testing.expectEqualStrings("Iv1.b507a08c87ecfe98", oauthProviderSpec("github-copilot").?.client_id);
    try std.testing.expect(oauthProviderSpec("github-copilot").?.grant == .copilot_bearer);
    try std.testing.expectEqualStrings("app_EMoamEEZ73f0CkXaXp7hrann", oauthProviderSpec("openai-codex").?.client_id);
    try std.testing.expect(oauthProviderSpec("openai-codex").?.grant == .post_form);
    try std.testing.expect(oauthProviderSpec("openai-codex").?.requires_account_id);
    try std.testing.expect(oauthProviderSpec("google-vertex") == null);
}

test "Anthropic refresh response applies five minute expiry skew" {
    const spec = oauthProviderSpec("anthropic").?;
    const now = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
    var refreshed = try parseRefreshResponse(
        std.testing.io,
        std.testing.allocator,
        spec,
        "old-refresh",
        "{\"access_token\":\"new-anthropic-access\",\"refresh_token\":\"new-anthropic-refresh\",\"expires_in\":3600}",
    );
    defer refreshed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new-anthropic-access", refreshed.access);
    try std.testing.expectEqualStrings("new-anthropic-refresh", refreshed.refresh);
    try std.testing.expect(refreshed.account_id == null);
    // expires ~= now + 3600s - 5min, allow a small window for clock movement during the test.
    const expected = now + 3600 * 1000 - 5 * 60 * 1000;
    try std.testing.expect(refreshed.expires >= expected - 2000 and refreshed.expires <= expected + 2000);
}

test "GitHub Copilot refresh response uses expires_at seconds and preserves refresh token" {
    const spec = oauthProviderSpec("github-copilot").?;
    var refreshed = try parseRefreshResponse(
        std.testing.io,
        std.testing.allocator,
        spec,
        "github-access-token",
        "{\"token\":\"copilot-session-token\",\"expires_at\":1893456000}",
    );
    defer refreshed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("copilot-session-token", refreshed.access);
    // Copilot reuses the GitHub access token as the refresh token.
    try std.testing.expectEqualStrings("github-access-token", refreshed.refresh);
    try std.testing.expectEqual(@as(i64, 1893456000 * 1000 - 5 * 60 * 1000), refreshed.expires);
}

test "OpenAI Codex refresh extracts chatgpt account id from JWT" {
    const spec = oauthProviderSpec("openai-codex").?;
    // JWT with payload {"https://api.openai.com/auth":{"chatgpt_account_id":"acct_codex_123"}}
    const header = "eyJhbGciOiJSUzI1NiJ9";
    const payload = blk: {
        const json = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_codex_123\"}}";
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const buf = try std.testing.allocator.alloc(u8, encoder.calcSize(json.len));
        _ = encoder.encode(buf, json);
        break :blk buf;
    };
    defer std.testing.allocator.free(payload);
    const jwt = try std.fmt.allocPrint(std.testing.allocator, "{s}.{s}.signature", .{ header, payload });
    defer std.testing.allocator.free(jwt);
    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"codex-refresh\",\"expires_in\":3600}}",
        .{jwt},
    );
    defer std.testing.allocator.free(body);

    var refreshed = try parseRefreshResponse(std.testing.io, std.testing.allocator, spec, "old", body);
    defer refreshed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(jwt, refreshed.access);
    try std.testing.expectEqualStrings("codex-refresh", refreshed.refresh);
    try std.testing.expectEqualStrings("acct_codex_123", refreshed.account_id.?);
}

test "OpenAI Codex refresh fails when JWT lacks account id" {
    const spec = oauthProviderSpec("openai-codex").?;
    try std.testing.expectError(error.OAuthRefreshFailed, parseRefreshResponse(
        std.testing.io,
        std.testing.allocator,
        spec,
        "old",
        "{\"access_token\":\"not-a-jwt\",\"refresh_token\":\"codex-refresh\",\"expires_in\":3600}",
    ));
}

test "refresh response rejects malformed token bodies" {
    const spec = oauthProviderSpec("anthropic").?;
    try std.testing.expectError(error.OAuthRefreshFailed, parseRefreshResponse(
        std.testing.io,
        std.testing.allocator,
        spec,
        "old",
        "not json",
    ));
    try std.testing.expectError(error.OAuthRefreshFailed, parseRefreshResponse(
        std.testing.io,
        std.testing.allocator,
        spec,
        "old",
        "{\"access_token\":\"only-access\"}",
    ));
}

test "Vertex ADC authorized_user document parses client_id/secret/refresh_token" {
    const sample =
        \\{
        \\  "client_id": "764086051850-adc.apps.googleusercontent.com",
        \\  "client_secret": "d-secret-value",
        \\  "refresh_token": "1//adc-refresh-token",
        \\  "type": "authorized_user"
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sample, .{});
    defer parsed.deinit();
    const adc = try parseVertexAdc(parsed.value);
    try std.testing.expect(adc == .authorized_user);
    try std.testing.expectEqualStrings("764086051850-adc.apps.googleusercontent.com", adc.authorized_user.client_id);
    try std.testing.expectEqualStrings("d-secret-value", adc.authorized_user.client_secret);
    try std.testing.expectEqualStrings("1//adc-refresh-token", adc.authorized_user.refresh_token);
}

test "Vertex ADC service_account document parses client_email/private_key/token_uri" {
    const sample =
        \\{"type":"service_account","client_email":"svc@project.iam.gserviceaccount.com","private_key":"-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n","token_uri":"https://oauth2.googleapis.com/token"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sample, .{});
    defer parsed.deinit();
    const adc = try parseVertexAdc(parsed.value);
    try std.testing.expect(adc == .service_account);
    try std.testing.expectEqualStrings("svc@project.iam.gserviceaccount.com", adc.service_account.client_email);
    try std.testing.expect(std.mem.indexOf(u8, adc.service_account.private_key, "BEGIN PRIVATE KEY") != null);
    try std.testing.expectEqualStrings("https://oauth2.googleapis.com/token", adc.service_account.token_uri);
}

test "Vertex ADC service_account token_uri defaults to Google when absent" {
    const sample =
        \\{"type":"service_account","client_email":"svc@project.iam.gserviceaccount.com","private_key":"-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sample, .{});
    defer parsed.deinit();
    const adc = try parseVertexAdc(parsed.value);
    try std.testing.expect(adc == .service_account);
    try std.testing.expectEqualStrings(google_oauth_token_url, adc.service_account.token_uri);
}

test "Vertex ADC parsing rejects documents missing required fields" {
    const cases = [_][]const u8{
        "{}",
        "{\"client_id\":\"only-id\"}",
        "{\"client_id\":\"id\",\"client_secret\":\"secret\"}",
        "{\"client_id\":\"\",\"client_secret\":\"s\",\"refresh_token\":\"r\"}",
        "{\"client_id\":\"id\",\"client_secret\":\"s\",\"refresh_token\":\"\"}",
        // service_account missing private_key / client_email.
        "{\"type\":\"service_account\",\"client_email\":\"svc@x.iam.gserviceaccount.com\"}",
        "{\"type\":\"service_account\",\"private_key\":\"-----BEGIN PRIVATE KEY-----\\nx\\n-----END PRIVATE KEY-----\"}",
        "{\"type\":\"service_account\",\"client_email\":\"\",\"private_key\":\"k\"}",
    };
    for (cases) |body| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.AdcMalformed, parseVertexAdc(parsed.value));
    }
}

test "Vertex ADC token exchange request payload shape matches Google refresh_token grant" {
    // Assert the exact form-encoded body and field ordering the OAuth2 token
    // endpoint receives, without performing any network I/O or printing secrets.
    const adc = VertexAuthorizedUser{
        .client_id = "764086051850-adc.apps.googleusercontent.com",
        .client_secret = "d-secret-value",
        .refresh_token = "1//adc-refresh-token",
    };
    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "grant_type=refresh_token&client_id={s}&client_secret={s}&refresh_token={s}",
        .{ adc.client_id, adc.client_secret, adc.refresh_token },
    );
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualStrings(
        "grant_type=refresh_token&client_id=764086051850-adc.apps.googleusercontent.com&client_secret=d-secret-value&refresh_token=1//adc-refresh-token",
        payload,
    );
}

test "Vertex ADC token endpoint defaults to Google, env override redirects to fake server" {
    // Mirrors the PI_ZIG_OAUTH_TOKEN_URL hook reused from refreshOAuthCredential so
    // the Node smoke can point token minting at a local fake endpoint.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqualStrings(
        google_oauth_token_url,
        env.get("PI_ZIG_OAUTH_TOKEN_URL") orelse google_oauth_token_url,
    );
    try env.put("PI_ZIG_OAUTH_TOKEN_URL", "http://127.0.0.1:45999/token");
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:45999/token",
        env.get("PI_ZIG_OAUTH_TOKEN_URL") orelse google_oauth_token_url,
    );
}

test "Vertex ADC token response parsing extracts ya29 access token" {
    const minted = try parseVertexAdcToken(
        std.testing.allocator,
        "{\"access_token\":\"ya29.minted-vertex-token\",\"expires_in\":3599,\"scope\":\"https://www.googleapis.com/auth/cloud-platform\",\"token_type\":\"Bearer\"}",
    );
    defer std.testing.allocator.free(minted);
    try std.testing.expectEqualStrings("ya29.minted-vertex-token", minted);
}

test "Vertex ADC token response parsing rejects malformed bodies" {
    try std.testing.expectError(error.VertexAdcExchangeFailed, parseVertexAdcToken(std.testing.allocator, "not json"));
    try std.testing.expectError(error.VertexAdcExchangeFailed, parseVertexAdcToken(std.testing.allocator, "{\"expires_in\":3600}"));
    try std.testing.expectError(error.VertexAdcExchangeFailed, parseVertexAdcToken(std.testing.allocator, "{\"access_token\":\"\"}"));
}

// A throwaway 2048-bit RSA private key (PKCS#8 PEM) used ONLY to unit-test the
// RS256 signer/JWT assembly. It is a freshly generated test key, not a real
// service-account credential, and signs nothing that reaches a live endpoint.
const test_rsa_pkcs8_pem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCzFGyixKiix3La
    \\uAXYF3SUVFiZ+ndGtt20RIL7xXhJ2Jimusk6CWufnOC6kreLMUQbxncUWItmHIUE
    \\MJToKwkgkZlF1YlgP7+SfJ9l0X04ygLUsPfvz1P++bx9MOtu0TE4PAmfDIc585gQ
    \\e5giv/CEWfc4pbJ835IPKAwTT/33RbQDRtrVTTePURnmPPjTvuoLiTTFzTJJgEYi
    \\dYn5sgVg5OcDdeyRkd8eoHBczhqFxA2/NL9W4YowJm5VmCYN2TTLkZixC4dtrmHc
    \\AkuQrlTDgsvj10VfRjGv38nutUX2DqZtkCQbx11I+UpfPohqYCPlehqs4gARBsWQ
    \\RUSH4u9ZAgMBAAECggEAANI/db7qimr8dFWYFQ91lMh2sWNCi8K+ktfxWiaJX2wn
    \\pIQKJSCN4Zq2bwemRuTtqaoncOCBvDDdntsQ1mGSAe4Z1vaSi0+AXJSUgqqbvnzV
    \\yikunIg+DEv0wSTQZy90DsGPYxSqYNKvu3V7TcgvK7Tob6FN3+GUXREsJi1jEx8R
    \\OWliU1kVsbtsSoHWhxNPRevt7lWUw6rMW3UbP5XXzR6ftfThvgQ3l8NvSG9IhDIp
    \\eJjuTf2Xdv0T3Mx8Q5/rvfa0FMe8YAFNByFpUNKF0CVVVZyzJUCTd+YxCVYIHHiu
    \\6D23vG/Qnfr77YPUhMsEqJzPhyIoEjATaAlK2xwgxQKBgQDbVNIFTnsavvL4hVVc
    \\hi7LBW+atUOeS2nXGImmMgtXGeMCysdoTSGo8ODu7NGldBDIfZkOGNX/A6vGWGh2
    \\ShrKobSkROF96c8IgmrV5ojA+NPnQn01jejZwpgvJ9I93Gm8obe+0/JiSpNhBN1F
    \\AXSLwZnnHz7pqCwHLZbYsoALfQKBgQDRBN/sFW6MKpbW8n6CGPeJ47BcZ4W2cCr1
    \\IcWTsxojF+jbr9bmihDt0bUCn9ccQ2l3nHnFrXoJVumkSJPaK3vuRkvKOUn4WTdd
    \\vZOGlqhZ7Y2nvY4T4ecBc7nlS6gUJZFD2grUVKy/mtdym/UT+Xb7w29MocDA9O3b
    \\Z0cBGpbiDQKBgQDYRcA+iU+sZOOTGW69qHaVrMuK4vhFK5m3BrQclDZIcfc+NpQA
    \\jiYFv1gdYJmtK1CtUePNWcISDx2fnGeNVK8sZd2JKX6sORP0ER2lxAfPOM1CuXZb
    \\i44yw8ZqoTqX0zLUVSapXbchIuZGgZRqSfARKxtGIrJXloOrpFGdZg4KxQKBgFoR
    \\4LBqN938yE1N58gGHD12OVxIW+1W/pvtdqeECWJP/k8UweVMX6krsfW0jUynm/4o
    \\Fq1haPI3Wq0pfVUJYfk2n5hAAakcQOiLNdRMfbVq0Z0T6PKWaSZOCTBO3tn3qlZz
    \\0jDXYC2c+vRvUjfOS0CIYiDCnz5HDWx7X7SREa3NAoGBAKNyOioRkFHQ1h5c3EUk
    \\F5mWUMF7w+IPDPTc/O51ZfQY/5Ra0w7/D+bgpoiSR+Sjeys/puoX4HY84pwE4LTy
    \\alNlrA2CRM9ebkMMTPuplqqJNxwmcG1SDmgMDAacvB30ASUAEZekBaBE1SJ0RHBK
    \\cQbYF5c5gAgE83x+tEs13nBc
    \\-----END PRIVATE KEY-----
;

test "service_account PKCS#8 PEM parses into RSA modulus and private exponent" {
    var key = try parseRsaPrivateKeyFromPem(std.testing.allocator, test_rsa_pkcs8_pem);
    defer key.deinit(std.testing.allocator);
    // 2048-bit key -> 256-byte modulus.
    try std.testing.expectEqual(@as(usize, 256), key.modulus.len);
    // The private exponent for a 2048-bit key is ~256 bytes (no leading zero here).
    try std.testing.expect(key.private_exponent.len >= 255 and key.private_exponent.len <= 256);
}

test "RS256 signer produces a signature that verifies against the public key" {
    var key = try parseRsaPrivateKeyFromPem(std.testing.allocator, test_rsa_pkcs8_pem);
    defer key.deinit(std.testing.allocator);

    const message = "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJzdmMifQ";
    const signature = try rs256Sign(std.testing.allocator, key, message);
    defer std.testing.allocator.free(signature);
    try std.testing.expectEqual(@as(usize, 256), signature.len);

    // Independently verify with std.crypto's RSA PKCS1v1.5 + SHA-256. The public
    // exponent is the standard 65537 (0x010001).
    const Rsa = std.crypto.Certificate.rsa;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const public_exponent = [_]u8{ 0x01, 0x00, 0x01 };
    const public_key = try Rsa.PublicKey.fromBytes(&public_exponent, key.modulus);
    var sig_array: [256]u8 = undefined;
    @memcpy(&sig_array, signature);
    try Rsa.PKCS1v1_5Signature.verify(256, sig_array, message, public_key, Sha256);

    // A tampered message must NOT verify against the same signature.
    try std.testing.expectError(
        error.InvalidSignature,
        Rsa.PKCS1v1_5Signature.verify(256, sig_array, "tampered", public_key, Sha256),
    );
}

test "service_account JWT has three base64url segments and a verifiable signature" {
    const account = VertexServiceAccount{
        .client_email = "svc@flow.iam.gserviceaccount.com",
        .private_key = test_rsa_pkcs8_pem,
        .token_uri = google_oauth_token_url,
    };
    const jwt = try buildSignedServiceAccountJwt(std.testing.allocator, account, account.token_uri, 1_700_000_000);
    defer std.testing.allocator.free(jwt);

    // Exactly two dots -> three segments.
    var dots: usize = 0;
    for (jwt) |c| {
        if (c == '.') dots += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), dots);

    var it = std.mem.splitScalar(u8, jwt, '.');
    const header_b64 = it.next().?;
    const claims_b64 = it.next().?;
    const sig_b64 = it.next().?;

    // Decode and check the header + claims content.
    const decoder = std.base64.url_safe_no_pad.Decoder;
    var header_buf: [128]u8 = undefined;
    const header_len = try decoder.calcSizeForSlice(header_b64);
    try decoder.decode(header_buf[0..header_len], header_b64);
    try std.testing.expectEqualStrings("{\"alg\":\"RS256\",\"typ\":\"JWT\"}", header_buf[0..header_len]);

    var claims_buf: [512]u8 = undefined;
    const claims_len = try decoder.calcSizeForSlice(claims_b64);
    try decoder.decode(claims_buf[0..claims_len], claims_b64);
    const claims = claims_buf[0..claims_len];
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"iss\":\"svc@flow.iam.gserviceaccount.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"aud\":\"https://oauth2.googleapis.com/token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"scope\":\"https://www.googleapis.com/auth/cloud-platform\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"iat\":1700000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"exp\":1700003600") != null);

    // The signature must verify over "<header>.<claims>".
    var key = try parseRsaPrivateKeyFromPem(std.testing.allocator, test_rsa_pkcs8_pem);
    defer key.deinit(std.testing.allocator);
    const signing_input = jwt[0 .. header_b64.len + 1 + claims_b64.len];
    var sig_buf: [256]u8 = undefined;
    const sig_len = try decoder.calcSizeForSlice(sig_b64);
    try std.testing.expectEqual(@as(usize, 256), sig_len);
    try decoder.decode(sig_buf[0..sig_len], sig_b64);

    const Rsa = std.crypto.Certificate.rsa;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const public_exponent = [_]u8{ 0x01, 0x00, 0x01 };
    const public_key = try Rsa.PublicKey.fromBytes(&public_exponent, key.modulus);
    try Rsa.PKCS1v1_5Signature.verify(256, sig_buf, signing_input, public_key, Sha256);
}

test "service_account JWT-bearer payload uses the RFC 7523 grant type" {
    // Assert the exact form-encoded grant_type field the token endpoint receives
    // (the assertion value itself is the signed JWT). No network I/O, no secrets.
    const grant_prefix = "grant_type=" ++ jwt_bearer_grant_type ++ "&assertion=";
    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "grant_type={s}&assertion={s}",
        .{ jwt_bearer_grant_type, "HEADER.CLAIMS.SIG" },
    );
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.startsWith(u8, payload, grant_prefix));
    try std.testing.expectEqualStrings(
        "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=HEADER.CLAIMS.SIG",
        payload,
    );
}

test "service_account key parsing rejects malformed PEM" {
    try std.testing.expectError(
        error.ServiceAccountKeyMalformed,
        parseRsaPrivateKeyFromPem(std.testing.allocator, "not a pem"),
    );
    try std.testing.expectError(
        error.ServiceAccountKeyMalformed,
        parseRsaPrivateKeyFromPem(std.testing.allocator, "-----BEGIN PRIVATE KEY-----\n!!!notbase64!!!\n-----END PRIVATE KEY-----"),
    );
}

test "AWS profile credentials parse from a shared credentials ini" {
    const ini =
        \\[default]
        \\aws_access_key_id = AKIADEFAULT
        \\aws_secret_access_key = default-secret
        \\
        \\# the bedrock profile is what AWS_PROFILE points at
        \\[bedrock]
        \\aws_access_key_id = AKIABEDROCK
        \\aws_secret_access_key = bedrock-secret
        \\aws_session_token = bedrock-session-token
        \\region = us-west-2
    ;
    var creds = (try parseAwsProfile(std.testing.allocator, ini, "bedrock")).?;
    defer creds.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("AKIABEDROCK", creds.access_key_id);
    try std.testing.expectEqualStrings("bedrock-secret", creds.secret_access_key);
    try std.testing.expectEqualStrings("bedrock-session-token", creds.session_token.?);
    try std.testing.expectEqualStrings("us-west-2", creds.region.?);

    // The default profile has no session token / region.
    var default_creds = (try parseAwsProfile(std.testing.allocator, ini, "default")).?;
    defer default_creds.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("AKIADEFAULT", default_creds.access_key_id);
    try std.testing.expect(default_creds.session_token == null);
    try std.testing.expect(default_creds.region == null);
}

test "AWS profile parsing accepts the [profile name] config spelling and rejects gaps" {
    const config_style =
        \\[profile bedrock]
        \\aws_access_key_id = AKIACONFIG
        \\aws_secret_access_key = config-secret
    ;
    var creds = (try parseAwsProfile(std.testing.allocator, config_style, "bedrock")).?;
    defer creds.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("AKIACONFIG", creds.access_key_id);

    // Missing profile -> null.
    try std.testing.expect((try parseAwsProfile(std.testing.allocator, config_style, "absent")) == null);
    // Present profile but missing secret -> null (no partial credentials).
    const missing_secret = "[bedrock]\naws_access_key_id = AKIA\n";
    try std.testing.expect((try parseAwsProfile(std.testing.allocator, missing_secret, "bedrock")) == null);
}

test "AWS profile resolution is gated on AWS_PROFILE" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // No AWS_PROFILE -> never reads the file, returns null.
    try std.testing.expect((try resolveAwsProfileCredentials(std.testing.io, std.testing.allocator, &env)) == null);
    // AWS_PROFILE set but the shared credentials file is absent -> clean null.
    try env.put("AWS_PROFILE", "bedrock");
    try env.put("HOME", "/nonexistent-pi-zig-aws-home-xyz");
    try std.testing.expect((try resolveAwsProfileCredentials(std.testing.io, std.testing.allocator, &env)) == null);
}

test "AWS credentials path honors AWS_SHARED_CREDENTIALS_FILE override" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("AWS_SHARED_CREDENTIALS_FILE", "/tmp/pi-zig-aws/credentials");
    const path = (try awsCredentialsPath(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/pi-zig-aws/credentials", path);
}

test "interactive login is opt-in and skips cleanly without prerequisites" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // Disabled by default -> unavailable, no crash, no output.
    try std.testing.expectError(
        error.InteractiveLoginUnavailable,
        beginInteractiveLogin(std.testing.io, &env, "anthropic", false),
    );
    // Unknown provider -> unsupported.
    try std.testing.expectError(
        error.InteractiveLoginUnsupportedProvider,
        beginInteractiveLogin(std.testing.io, &env, "not-a-provider", true),
    );
    // Enabled + known provider, but the test harness has no TTY (and the live loop
    // is unimplemented) -> still unavailable, degrades cleanly.
    try std.testing.expectError(
        error.InteractiveLoginUnavailable,
        beginInteractiveLogin(std.testing.io, &env, "anthropic", true),
    );
    // PI_OFFLINE forces unavailable regardless of TTY.
    try env.put("PI_OFFLINE", "1");
    try std.testing.expect(!interactiveLoginAvailable(std.testing.io, &env));
}

test "Vertex ADC path resolution prefers GOOGLE_APPLICATION_CREDENTIALS override" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // An explicit override is honored verbatim (after tilde expansion) without a
    // disk stat, so a caller-provided path is always tried first.
    try env.put("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/pi-zig-test-adc/application_default_credentials.json");
    const path = (try vertexAdcPath(std.testing.io, std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/pi-zig-test-adc/application_default_credentials.json", path);
}

test "Vertex ADC path resolution returns null when no credentials are discoverable" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // No GOOGLE_APPLICATION_CREDENTIALS, no CLOUDSDK_CONFIG, and a HOME with no
    // gcloud ADC file → clean null (callers must not crash when creds are absent).
    try env.put("HOME", "/nonexistent-pi-zig-home-xyz");
    const path = try vertexAdcPath(std.testing.io, std.testing.allocator, &env);
    try std.testing.expect(path == null);
}

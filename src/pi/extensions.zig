const std = @import("std");

const max_settings_bytes = 1024 * 1024;
const max_manifest_bytes = 256 * 1024;
const project_settings_file = ".pi/settings.json";

const Entry = struct {
    path: []const u8,
    enabled: bool = true,
    exists: bool = true,
    source: []const u8,
    scope: []const u8,
    origin: []const u8,
    base_dir: []const u8,
};

const Options = struct {
    json: bool = false,
    no_extensions: bool = false,
    explicit_paths: std.ArrayList([]const u8) = .empty,
    help: bool = false,
    invalid_option: ?[]const u8 = null,
    missing_option_value: ?[]const u8 = null,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !bool {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "extensions")) return false;
    var options = try parse(allocator, args[1..]);
    defer options.explicit_paths.deinit(allocator);

    if (options.help) {
        try writeHelp(io);
        return true;
    }
    if (options.invalid_option) |option| {
        try writeStderr(io, "Unknown option ");
        try writeStderr(io, option);
        try writeStderr(io, " for \"extensions\".\n");
        std.process.exit(1);
    }
    if (options.missing_option_value) |option| {
        try writeStderr(io, "Missing value for ");
        try writeStderr(io, option);
        try writeStderr(io, ".\n");
        std.process.exit(1);
    }

    var entries = try discover(io, allocator, env, options);
    defer entries.deinit(allocator);
    sortEntries(entries.items);

    if (options.json) {
        try writeJson(io, entries.items);
    } else {
        try writeText(io, entries.items);
    }
    return true;
}

fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
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
        if (std.mem.eql(u8, arg, "--no-extensions") or std.mem.eql(u8, arg, "-ne")) {
            options.no_extensions = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--extension") or std.mem.eql(u8, arg, "-e")) {
            const value = if (index + 1 < args.len) args[index + 1] else "";
            if (value.len == 0 or std.mem.startsWith(u8, value, "-")) {
                options.missing_option_value = options.missing_option_value orelse arg;
            } else {
                try options.explicit_paths.append(allocator, value);
                index += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            options.invalid_option = options.invalid_option orelse arg;
            continue;
        }
        try options.explicit_paths.append(allocator, arg);
    }
    return options;
}

fn writeHelp(io: std.Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  pi-zig extensions [--json] [--no-extensions] [--extension <path>] [path...]
        \\
        \\Discover extension entry points using upstream order:
        \\  project settings, project .pi/extensions, user settings, user extensions,
        \\  package-provided extensions, then explicit CLI paths.
        \\
        \\This command inventories load targets only. Extension execution is not ported yet.
        \\
    );
}

fn discover(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    options: Options,
) !std.ArrayList(Entry) {
    var entries: std.ArrayList(Entry) = .empty;

    const cwd = try currentPathOwned(io, allocator);
    const agent_dir = try agentDir(allocator, env);
    const project_base = try std.fs.path.join(allocator, &.{ cwd, ".pi" });
    defer allocator.free(project_base);

    if (!options.no_extensions) {
        var project_settings = try loadSettings(io, allocator, project_settings_file);
        defer project_settings.deinit();
        const global_settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
        defer allocator.free(global_settings_path);
        var global_settings = try loadSettings(io, allocator, global_settings_path);
        defer global_settings.deinit();

        try addSettingsExtensionEntries(io, allocator, env, &entries, project_settings.value, project_base, "project");
        try addAutoExtensionEntries(io, allocator, &entries, project_settings.value, project_base, "project");
        try addSettingsExtensionEntries(io, allocator, env, &entries, global_settings.value, agent_dir, "user");
        try addAutoExtensionEntries(io, allocator, &entries, global_settings.value, agent_dir, "user");
        try addPackageExtensionEntries(io, allocator, env, &entries, project_settings.value, cwd, agent_dir, project_base, "project");
        try addPackageExtensionEntries(io, allocator, env, &entries, global_settings.value, cwd, agent_dir, agent_dir, "user");
    }

    for (options.explicit_paths.items) |raw| {
        const resolved = try resolvePath(allocator, env, cwd, raw);
        defer allocator.free(resolved);
        try addExplicitPath(io, allocator, &entries, resolved, cwd);
    }

    return entries;
}

fn addSettingsExtensionEntries(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    entries: *std.ArrayList(Entry),
    settings: std.json.Value,
    base_dir: []const u8,
    scope: []const u8,
) !void {
    if (settings != .object) return;
    const extensions = settings.object.get("extensions") orelse return;
    if (extensions != .array or extensions.array.items.len == 0) return;

    var plain: std.ArrayList([]const u8) = .empty;
    defer plain.deinit(allocator);
    var patterns: std.ArrayList([]const u8) = .empty;
    defer patterns.deinit(allocator);
    for (extensions.array.items) |item| {
        if (item != .string) continue;
        if (isPattern(item.string)) {
            try patterns.append(allocator, item.string);
        } else {
            try plain.append(allocator, item.string);
        }
    }

    var collected: std.ArrayList([]const u8) = .empty;
    defer collected.deinit(allocator);
    for (plain.items) |raw| {
        const resolved = try resolvePath(allocator, env, base_dir, raw);
        defer allocator.free(resolved);
        try collectExtensionFilesFromPath(io, allocator, &collected, resolved);
    }
    for (collected.items) |path| {
        try addEntry(allocator, entries, path, isEnabledByPatterns(path, base_dir, patterns.items), "local", scope, "top-level", base_dir, true);
    }
}

fn addAutoExtensionEntries(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    settings: std.json.Value,
    base_dir: []const u8,
    scope: []const u8,
) !void {
    const dir = try std.fs.path.join(allocator, &.{ base_dir, "extensions" });
    defer allocator.free(dir);
    var discovered: std.ArrayList([]const u8) = .empty;
    defer discovered.deinit(allocator);
    try collectAutoExtensionEntries(io, allocator, &discovered, dir);

    const overrides = settingsArray(settings, "extensions");
    for (discovered.items) |path| {
        try addEntry(allocator, entries, path, isEnabledByJsonOverrides(path, base_dir, overrides), "auto", scope, "top-level", base_dir, true);
    }
}

fn addPackageExtensionEntries(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    entries: *std.ArrayList(Entry),
    settings: std.json.Value,
    cwd: []const u8,
    agent_dir: []const u8,
    base_dir: []const u8,
    scope: []const u8,
) !void {
    if (settings != .object) return;
    const packages = settings.object.get("packages") orelse return;
    if (packages != .array) return;

    for (packages.array.items) |item| {
        const source = packageSource(item) orelse continue;
        const package_root = try packageRoot(allocator, env, cwd, agent_dir, base_dir, source, scope);
        defer allocator.free(package_root);
        if (!pathExists(io, package_root)) continue;
        const filter = packageFilter(item, "extensions");
        try collectPackageExtensions(io, allocator, entries, package_root, filter, source, scope);
    }
}

fn addExplicitPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    path: []const u8,
    cwd: []const u8,
) !void {
    var collected: std.ArrayList([]const u8) = .empty;
    defer collected.deinit(allocator);
    try collectExtensionFilesFromPath(io, allocator, &collected, path);
    if (collected.items.len == 0) {
        try addEntry(allocator, entries, path, true, "cli", "temporary", "top-level", cwd, pathExists(io, path));
        return;
    }
    for (collected.items) |entry_path| {
        try addEntry(allocator, entries, entry_path, true, "cli", "temporary", "top-level", cwd, true);
    }
}

fn collectPackageExtensions(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    package_root: []const u8,
    filter: ?[]const std.json.Value,
    source: []const u8,
    scope: []const u8,
) !void {
    var collected: std.ArrayList([]const u8) = .empty;
    defer collected.deinit(allocator);

    if (try readManifestExtensions(io, allocator, &collected, package_root)) {
        // Manifest entries define package extension sources. Package filters
        // below can still disable or narrow them.
    } else {
        const convention = try std.fs.path.join(allocator, &.{ package_root, "extensions" });
        defer allocator.free(convention);
        try collectAutoExtensionEntries(io, allocator, &collected, convention);
    }

    if (filter) |patterns| {
        if (patterns.len == 0) {
            for (collected.items) |path| {
                try addEntry(allocator, entries, path, false, source, scope, "package", package_root, true);
            }
            return;
        }
        for (collected.items) |path| {
            try addEntry(allocator, entries, path, isEnabledByJsonPatterns(path, package_root, patterns), source, scope, "package", package_root, true);
        }
    } else {
        for (collected.items) |path| {
            try addEntry(allocator, entries, path, true, source, scope, "package", package_root, true);
        }
    }
}

fn collectExtensionFilesFromPath(io: std.Io, allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), path: []const u8) anyerror!void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };
    switch (stat.kind) {
        .file, .sym_link => {
            if (isExtensionFile(path)) try out.append(allocator, try allocator.dupe(u8, path));
        },
        .directory => {
            if (try resolveExtensionEntries(io, allocator, out, path)) return;
            try collectAutoExtensionEntries(io, allocator, out, path);
        },
        else => {},
    }
}

fn collectAutoExtensionEntries(io: std.Io, allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), dir_path: []const u8) !void {
    if (try resolveExtensionEntries(io, allocator, out, dir_path)) return;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "node_modules")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    for (names.items) |name| {
        const full = try std.fs.path.join(allocator, &.{ dir_path, name });
        defer allocator.free(full);
        const stat = std.Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        switch (stat.kind) {
            .file, .sym_link => if (isExtensionFile(name)) try out.append(allocator, try allocator.dupe(u8, full)),
            .directory => _ = try resolveExtensionEntries(io, allocator, out, full),
            else => {},
        }
    }
}

fn resolveExtensionEntries(io: std.Io, allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), dir_path: []const u8) anyerror!bool {
    const before = out.items.len;
    _ = try readManifestExtensions(io, allocator, out, dir_path);
    if (out.items.len > before) return true;

    const index_ts = try std.fs.path.join(allocator, &.{ dir_path, "index.ts" });
    defer allocator.free(index_ts);
    if (pathExists(io, index_ts)) {
        try out.append(allocator, try allocator.dupe(u8, index_ts));
        return true;
    }
    const index_js = try std.fs.path.join(allocator, &.{ dir_path, "index.js" });
    defer allocator.free(index_js);
    if (pathExists(io, index_js)) {
        try out.append(allocator, try allocator.dupe(u8, index_js));
        return true;
    }
    return false;
}

fn readManifestExtensions(io: std.Io, allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), package_root: []const u8) anyerror!bool {
    const package_json = try std.fs.path.join(allocator, &.{ package_root, "package.json" });
    defer allocator.free(package_json);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, package_json, allocator, .limited(max_manifest_bytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const pi = parsed.value.object.get("pi") orelse return false;
    if (pi != .object) return false;
    const extensions = pi.object.get("extensions") orelse return false;
    if (extensions != .array or extensions.array.items.len == 0) return false;

    for (extensions.array.items) |item| {
        if (item != .string or isOverridePattern(item.string)) continue;
        const resolved = try resolvePackagePath(allocator, package_root, item.string);
        defer allocator.free(resolved);
        try collectExtensionFilesFromPath(io, allocator, out, resolved);
    }
    return true;
}

fn addEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    path: []const u8,
    enabled: bool,
    source: []const u8,
    scope: []const u8,
    origin: []const u8,
    base_dir: []const u8,
    exists: bool,
) !void {
    const canonical = std.fs.path.resolve(allocator, &.{path}) catch try allocator.dupe(u8, path);
    try entries.append(allocator, .{
        .path = canonical,
        .enabled = enabled,
        .exists = exists,
        .source = try allocator.dupe(u8, source),
        .scope = try allocator.dupe(u8, scope),
        .origin = try allocator.dupe(u8, origin),
        .base_dir = try allocator.dupe(u8, base_dir),
    });
}

fn writeJson(io: std.Io, entries: []Entry) !void {
    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll("{\"extensions\":[");
    var emitted: usize = 0;
    var previous: ?[]const u8 = null;
    for (entries) |entry| {
        if (previous) |prev| if (std.mem.eql(u8, prev, entry.path)) continue;
        previous = entry.path;
        if (emitted != 0) try w.writeAll(",");
        emitted += 1;
        try w.writeAll("{\"path\":");
        try writeJsonString(w, entry.path);
        try w.writeAll(",\"enabled\":");
        try w.writeAll(if (entry.enabled) "true" else "false");
        try w.writeAll(",\"exists\":");
        try w.writeAll(if (entry.exists) "true" else "false");
        try w.writeAll(",\"sourceInfo\":{\"source\":");
        try writeJsonString(w, entry.source);
        try w.writeAll(",\"scope\":");
        try writeJsonString(w, entry.scope);
        try w.writeAll(",\"origin\":");
        try writeJsonString(w, entry.origin);
        try w.writeAll(",\"baseDir\":");
        try writeJsonString(w, entry.base_dir);
        try w.writeAll("}}");
    }
    try w.writeAll("]}\n");
    try w.flush();
}

fn writeText(io: std.Io, entries: []Entry) !void {
    var emitted: usize = 0;
    var previous: ?[]const u8 = null;
    for (entries) |entry| {
        if (previous) |prev| if (std.mem.eql(u8, prev, entry.path)) continue;
        previous = entry.path;
        emitted += 1;
        try writeStdout(io, if (entry.enabled) "" else "disabled ");
        try writeStdout(io, entry.path);
        try writeStdout(io, " [");
        try writeStdout(io, entry.scope);
        try writeStdout(io, " ");
        try writeStdout(io, entry.source);
        try writeStdout(io, " ");
        try writeStdout(io, entry.origin);
        try writeStdout(io, "]\n");
    }
    if (emitted == 0) try writeStdout(io, "No extensions discovered.\n");
}

fn sortEntries(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, lessThanEntry);
}

fn lessThanEntry(_: void, left: Entry, right: Entry) bool {
    const left_rank = precedenceRank(left);
    const right_rank = precedenceRank(right);
    if (left_rank != right_rank) return left_rank < right_rank;
    return std.mem.lessThan(u8, left.path, right.path);
}

fn precedenceRank(entry: Entry) usize {
    if (std.mem.eql(u8, entry.source, "cli")) return 0;
    if (std.mem.eql(u8, entry.origin, "package")) return 5;
    const base: usize = if (std.mem.eql(u8, entry.scope, "project")) 1 else 3;
    return base + if (std.mem.eql(u8, entry.source, "local")) @as(usize, 0) else @as(usize, 1);
}

fn settingsArray(settings: std.json.Value, name: []const u8) []const std.json.Value {
    if (settings != .object) return &.{};
    const value = settings.object.get(name) orelse return &.{};
    if (value != .array) return &.{};
    return value.array.items;
}

fn loadSettings(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_settings_bytes)) catch |err| switch (err) {
        error.FileNotFound => return std.json.parseFromSlice(std.json.Value, allocator, "{}", .{}),
        else => return err,
    };
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
}

fn packageSource(value: std.json.Value) ?[]const u8 {
    switch (value) {
        .string => |source| return source,
        .object => |object| {
            const source = object.get("source") orelse return null;
            if (source != .string) return null;
            return source.string;
        },
        else => return null,
    }
}

fn packageFilter(value: std.json.Value, name: []const u8) ?[]const std.json.Value {
    if (value != .object) return null;
    const filter = value.object.get(name) orelse return null;
    if (filter != .array) return null;
    return filter.array.items;
}

fn packageRoot(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    agent_dir: []const u8,
    base_dir: []const u8,
    source: []const u8,
    scope: []const u8,
) ![]u8 {
    if (std.mem.startsWith(u8, source, "npm:")) {
        const spec = source["npm:".len..];
        const name = npmPackageName(spec);
        const root = if (std.mem.eql(u8, scope, "project"))
            try std.fs.path.join(allocator, &.{ cwd, ".pi", "npm", "node_modules", name })
        else
            try std.fs.path.join(allocator, &.{ agent_dir, "npm", "node_modules", name });
        return root;
    }
    if (try parseGitSourceOwned(allocator, source)) |git| {
        defer allocator.free(git.host);
        defer allocator.free(git.path);
        if (std.mem.eql(u8, scope, "project")) {
            return std.fs.path.join(allocator, &.{ cwd, ".pi", "git", git.host, git.path });
        }
        return std.fs.path.join(allocator, &.{ agent_dir, "git", git.host, git.path });
    }
    return resolvePath(allocator, env, base_dir, source);
}

const GitParts = struct {
    host: []const u8,
    path: []const u8,
};

fn parseGitSourceOwned(allocator: std.mem.Allocator, source: []const u8) !?GitParts {
    if (std.mem.startsWith(u8, source, "git:")) {
        const raw = source["git:".len..];
        if (std.mem.startsWith(u8, raw, "git@")) {
            const after_user = raw["git@".len..];
            const colon = std.mem.indexOfScalar(u8, after_user, ':') orelse return null;
            const host = after_user[0..colon];
            const split = splitGitPathRef(after_user[colon + 1 ..]);
            return .{ .host = try allocator.dupe(u8, host), .path = try allocator.dupe(u8, stripGitSuffix(split.path)) };
        }
        return parseGitHostPath(allocator, raw);
    }
    if (std.mem.indexOf(u8, source, "://") != null) return parseProtocolGit(allocator, source);
    return null;
}

fn parseProtocolGit(allocator: std.mem.Allocator, raw: []const u8) !?GitParts {
    const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return null;
    const after_scheme = raw[scheme_end + "://".len ..];
    const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return null;
    var host = after_scheme[0..slash];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    const split = splitGitPathRef(after_scheme[slash + 1 ..]);
    return .{ .host = try allocator.dupe(u8, host), .path = try allocator.dupe(u8, stripGitSuffix(split.path)) };
}

fn parseGitHostPath(allocator: std.mem.Allocator, raw: []const u8) !?GitParts {
    if (std.mem.indexOf(u8, raw, "://") != null) return parseProtocolGit(allocator, raw);
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return null;
    const host = raw[0..slash];
    if (!std.mem.eql(u8, host, "localhost") and std.mem.indexOfScalar(u8, host, '.') == null) return null;
    const split = splitGitPathRef(raw[slash + 1 ..]);
    return .{ .host = try allocator.dupe(u8, host), .path = try allocator.dupe(u8, stripGitSuffix(split.path)) };
}

const GitPathRef = struct {
    path: []const u8,
};

fn splitGitPathRef(value: []const u8) GitPathRef {
    if (std.mem.lastIndexOfScalar(u8, value, '@')) |at| {
        if (at > 0 and at + 1 < value.len) return .{ .path = value[0..at] };
    }
    return .{ .path = value };
}

fn stripGitSuffix(value: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, value, ".git")) value[0 .. value.len - ".git".len] else value;
}

fn npmPackageName(spec: []const u8) []const u8 {
    const search_start: usize = if (spec.len > 0 and spec[0] == '@') 1 else 0;
    if (std.mem.lastIndexOfScalar(u8, spec[search_start..], '@')) |relative_at| {
        const at = search_start + relative_at;
        return spec[0..at];
    }
    return spec;
}

fn resolvePackagePath(allocator: std.mem.Allocator, root: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    return std.fs.path.resolve(allocator, &.{ root, path });
}

fn resolvePath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, base_dir: []const u8, raw: []const u8) ![]u8 {
    const expanded = try expandMaybeTilde(allocator, env, raw);
    defer allocator.free(expanded);
    if (std.fs.path.isAbsolute(expanded)) return std.fs.path.resolve(allocator, &.{expanded});
    return std.fs.path.resolve(allocator, &.{ base_dir, expanded });
}

fn isEnabledByJsonPatterns(path: []const u8, base_dir: []const u8, patterns: []const std.json.Value) bool {
    if (patterns.len == 0) return true;
    var has_include = false;
    var enabled = false;
    for (patterns) |pattern_value| {
        if (pattern_value != .string) continue;
        const pattern = pattern_value.string;
        if (!isPattern(pattern)) {
            has_include = true;
            if (matchesPattern(path, base_dir, pattern)) enabled = true;
        }
    }
    if (!has_include) enabled = true;
    for (patterns) |pattern_value| {
        if (pattern_value != .string) continue;
        const pattern = pattern_value.string;
        if (pattern.len == 0) continue;
        if (pattern[0] == '!' and matchesPattern(path, base_dir, pattern[1..])) enabled = false;
        if (pattern[0] == '+' and matchesExact(path, base_dir, pattern[1..])) enabled = true;
        if (pattern[0] == '-' and matchesExact(path, base_dir, pattern[1..])) enabled = false;
    }
    return enabled;
}

fn isEnabledByJsonOverrides(path: []const u8, base_dir: []const u8, patterns: []const std.json.Value) bool {
    var enabled = true;
    for (patterns) |pattern_value| {
        if (pattern_value != .string or pattern_value.string.len == 0) continue;
        const pattern = pattern_value.string;
        if (pattern[0] == '!' and matchesPattern(path, base_dir, pattern[1..])) enabled = false;
        if (pattern[0] == '+' and matchesExact(path, base_dir, pattern[1..])) enabled = true;
        if (pattern[0] == '-' and matchesExact(path, base_dir, pattern[1..])) enabled = false;
    }
    return enabled;
}

fn isEnabledByPatterns(path: []const u8, base_dir: []const u8, patterns: []const []const u8) bool {
    var has_include = false;
    var enabled = false;
    for (patterns) |pattern| {
        if (!isOverridePattern(pattern)) {
            has_include = true;
            if (matchesPattern(path, base_dir, pattern)) enabled = true;
        }
    }
    if (!has_include) enabled = true;
    for (patterns) |pattern| {
        if (pattern.len == 0) continue;
        if (pattern[0] == '!' and matchesPattern(path, base_dir, pattern[1..])) enabled = false;
        if (pattern[0] == '+' and matchesExact(path, base_dir, pattern[1..])) enabled = true;
        if (pattern[0] == '-' and matchesExact(path, base_dir, pattern[1..])) enabled = false;
    }
    return enabled;
}

fn matchesPattern(path: []const u8, base_dir: []const u8, pattern: []const u8) bool {
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, pattern) or std.mem.eql(u8, path, pattern)) return true;
    const rel = relativeSuffix(path, base_dir);
    if (std.mem.eql(u8, rel, pattern)) return true;
    if (std.mem.indexOfScalar(u8, pattern, '*') != null or std.mem.indexOfScalar(u8, pattern, '?') != null) {
        return wildcardMatch(rel, pattern) or wildcardMatch(basename, pattern) or wildcardMatch(path, pattern);
    }
    return false;
}

fn matchesExact(path: []const u8, base_dir: []const u8, pattern: []const u8) bool {
    const normalized = if (std.mem.startsWith(u8, pattern, "./")) pattern[2..] else pattern;
    const rel = relativeSuffix(path, base_dir);
    return std.mem.eql(u8, rel, normalized) or std.mem.eql(u8, path, normalized);
}

fn relativeSuffix(path: []const u8, base_dir: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, base_dir)) {
        var rel = path[base_dir.len..];
        while (std.mem.startsWith(u8, rel, "/")) rel = rel[1..];
        return rel;
    }
    return path;
}

fn wildcardMatch(value: []const u8, pattern: []const u8) bool {
    var value_index: usize = 0;
    var pattern_index: usize = 0;
    var star: ?usize = null;
    var match_index: usize = 0;
    while (value_index < value.len) {
        if (pattern_index < pattern.len and (pattern[pattern_index] == '?' or pattern[pattern_index] == value[value_index])) {
            pattern_index += 1;
            value_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star = pattern_index;
            match_index = value_index;
            pattern_index += 1;
        } else if (star) |star_index| {
            pattern_index = star_index + 1;
            match_index += 1;
            value_index = match_index;
        } else {
            return false;
        }
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn isPattern(value: []const u8) bool {
    return isOverridePattern(value) or std.mem.indexOfScalar(u8, value, '*') != null or std.mem.indexOfScalar(u8, value, '?') != null;
}

fn isOverridePattern(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "!") or std.mem.startsWith(u8, value, "+") or std.mem.startsWith(u8, value, "-");
}

fn isExtensionFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".js");
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn agentDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("PI_CODING_AGENT_DIR")) |value| return expandMaybeTilde(allocator, env, value);
    return std.fs.path.join(allocator, &.{ env.get("HOME") orelse ".", ".pi", "agent" });
}

fn expandMaybeTilde(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, env.get("HOME") orelse ".");
    if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(allocator, &.{ env.get("HOME") orelse ".", path[2..] });
    return allocator.dupe(u8, path);
}

fn currentPathOwned(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.encodeJsonString(value, .{}, w);
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeStderr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

test "wildcard extension pattern matches basename" {
    try std.testing.expect(wildcardMatch("alpha.ts", "*.ts"));
    try std.testing.expect(!wildcardMatch("alpha.js", "*.ts"));
}

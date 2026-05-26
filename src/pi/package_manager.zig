const std = @import("std");

const max_settings_bytes = 1024 * 1024;
const project_settings_file = ".pi/settings.json";

const Command = enum {
    install,
    remove,
    update,
    list,
};

const SourceKind = enum {
    npm,
    git,
    local,
};

const ParsedSource = struct {
    kind: SourceKind,
    source: []const u8,
    name: []const u8 = "",
    host: []const u8 = "",
    path: []const u8 = "",
};

const PackageOptions = struct {
    command: Command,
    source: ?[]const u8 = null,
    local: bool = false,
    force: bool = false,
    help: bool = false,
    self: bool = false,
    extensions: bool = false,
    extension_source: ?[]const u8 = null,
    invalid_option: ?[]const u8 = null,
    invalid_argument: ?[]const u8 = null,
    missing_option_value: ?[]const u8 = null,
    conflicting_options: ?[]const u8 = null,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !bool {
    const options = parsePackageCommand(args) orelse return false;

    if (options.help) {
        return writeHelp(io, options.command);
    }

    if (options.invalid_option) |option| {
        try writeStderr(io, "Unknown option ");
        try writeStderr(io, option);
        try writeStderr(io, " for \"");
        try writeStderr(io, commandName(options.command));
        try writeStderr(io, "\".\n");
        try writeUsageHint(io, options.command);
        std.process.exit(1);
    }

    if (options.missing_option_value) |option| {
        try writeStderr(io, "Missing value for ");
        try writeStderr(io, option);
        try writeStderr(io, ".\n");
        try writeUsageLine(io, options.command);
        std.process.exit(1);
    }

    if (options.invalid_argument) |argument| {
        try writeStderr(io, "Unexpected argument ");
        try writeStderr(io, argument);
        try writeStderr(io, ".\n");
        try writeUsageLine(io, options.command);
        std.process.exit(1);
    }

    if (options.conflicting_options) |message| {
        try writeStderr(io, message);
        try writeStderr(io, "\n");
        try writeUsageLine(io, options.command);
        std.process.exit(1);
    }

    if ((options.command == .install or options.command == .remove) and options.source == null) {
        try writeStderr(io, "Missing ");
        try writeStderr(io, commandName(options.command));
        try writeStderr(io, " source.\n");
        try writeUsageLine(io, options.command);
        std.process.exit(1);
    }

    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);

    const agent_dir = try agentDir(allocator, env);
    defer allocator.free(agent_dir);

    switch (options.command) {
        .install => {
            const source = options.source.?;
            const parsed = parseSource(source);
            if (parsed.kind != .local) {
                try writeStderr(io, "pi-zig package install currently supports local package paths only; npm/git installation is not implemented yet.\n");
                std.process.exit(1);
            }
            const resolved = try resolveLocalPath(allocator, cwd, parsed.path);
            defer allocator.free(resolved);
            if (!pathExists(io, resolved)) {
                try writeStderr(io, "Path does not exist: ");
                try writeStderr(io, resolved);
                try writeStderr(io, "\n");
                std.process.exit(1);
            }
            const changed = try addSourceToSettings(io, allocator, env, cwd, agent_dir, source, options.local);
            _ = changed;
            try writeStdout(io, "Installed ");
            try writeStdout(io, source);
            try writeStdout(io, "\n");
            return true;
        },
        .remove => {
            const source = options.source.?;
            const removed = try removeSourceFromSettings(io, allocator, env, cwd, agent_dir, source, options.local);
            if (!removed) {
                try writeStderr(io, "No matching package found for ");
                try writeStderr(io, source);
                try writeStderr(io, "\n");
                std.process.exit(1);
            }
            try writeStdout(io, "Removed ");
            try writeStdout(io, source);
            try writeStdout(io, "\n");
            return true;
        },
        .list => {
            try listConfiguredPackages(io, allocator, env, cwd, agent_dir);
            return true;
        },
        .update => {
            try writeStderr(io, "pi-zig package update is not implemented yet.\n");
            std.process.exit(1);
        },
    }
}

fn parsePackageCommand(args: []const []const u8) ?PackageOptions {
    if (args.len == 0) return null;
    const raw_command = args[0];
    const command: Command = if (std.mem.eql(u8, raw_command, "install"))
        .install
    else if (std.mem.eql(u8, raw_command, "remove") or std.mem.eql(u8, raw_command, "uninstall"))
        .remove
    else if (std.mem.eql(u8, raw_command, "update"))
        .update
    else if (std.mem.eql(u8, raw_command, "list"))
        .list
    else
        return null;

    var options = PackageOptions{ .command = command };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--local")) {
            if (command == .install or command == .remove) {
                options.local = true;
            } else {
                options.invalid_option = options.invalid_option orelse arg;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--self")) {
            if (command == .update) {
                options.self = true;
            } else {
                options.invalid_option = options.invalid_option orelse arg;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--extensions")) {
            if (command == .update) {
                options.extensions = true;
            } else {
                options.invalid_option = options.invalid_option orelse arg;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--force")) {
            if (command == .update) {
                options.force = true;
            } else {
                options.invalid_option = options.invalid_option orelse arg;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--extension")) {
            if (command != .update) {
                options.invalid_option = options.invalid_option orelse arg;
                continue;
            }
            const value = if (index + 1 < args.len) args[index + 1] else "";
            if (value.len == 0 or std.mem.startsWith(u8, value, "-")) {
                options.missing_option_value = options.missing_option_value orelse arg;
            } else if (options.extension_source != null) {
                options.conflicting_options = options.conflicting_options orelse "--extension can only be provided once";
                index += 1;
            } else {
                options.extension_source = value;
                index += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            options.invalid_option = options.invalid_option orelse arg;
            continue;
        }
        if (options.source == null) {
            options.source = arg;
        } else {
            options.invalid_argument = options.invalid_argument orelse arg;
        }
    }

    if (command == .update) {
        if (options.extension_source != null) {
            if (options.self or options.extensions) {
                options.conflicting_options = options.conflicting_options orelse "--extension cannot be combined with --self or --extensions";
            }
            if (options.source != null) {
                options.conflicting_options = options.conflicting_options orelse "--extension cannot be combined with a positional source";
            }
            options.extensions = true;
        } else if (options.source) |source| {
            if (std.mem.eql(u8, source, "self") or std.mem.eql(u8, source, "pi")) {
                if (!options.extensions) options.self = true;
            } else {
                if (options.extensions or options.self) {
                    options.conflicting_options = options.conflicting_options orelse "positional update targets cannot be combined with --self or --extensions";
                }
                options.extensions = true;
            }
        } else if (!options.self and !options.extensions) {
            options.self = true;
            options.extensions = true;
        }
    }

    return options;
}

fn writeHelp(io: std.Io, command: Command) !bool {
    switch (command) {
        .install => try writeStdout(io,
            \\Usage:
            \\  pi-zig install <source> [-l]
            \\
            \\Install a package and add it to settings.
            \\
            \\Options:
            \\  -l, --local    Install project-locally (.pi/settings.json)
            \\
        ),
        .remove => try writeStdout(io,
            \\Usage:
            \\  pi-zig remove <source> [-l]
            \\
            \\Remove a package and its source from settings.
            \\Alias: pi-zig uninstall <source> [-l]
            \\
            \\Options:
            \\  -l, --local    Remove from project settings (.pi/settings.json)
            \\
        ),
        .update => try writeStdout(io,
            \\Usage:
            \\  pi-zig update [source|self|pi] [--self] [--extensions] [--extension <source>] [--force]
            \\
            \\Update pi and installed packages.
            \\
        ),
        .list => try writeStdout(io,
            \\Usage:
            \\  pi-zig list
            \\
            \\List installed packages from user and project settings.
            \\
        ),
    }
    return true;
}

fn addSourceToSettings(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    agent_dir: []const u8,
    source: []const u8,
    local: bool,
) !bool {
    const settings_path = try settingsPath(allocator, agent_dir, local);
    defer allocator.free(settings_path);
    const base_dir = try settingsBaseDir(allocator, cwd, agent_dir, local);
    defer allocator.free(base_dir);
    const normalized = try normalizePackageSourceForSettings(allocator, env, cwd, base_dir, source);
    defer allocator.free(normalized);

    var parsed = try loadSettings(io, allocator, settings_path);
    defer parsed.deinit();
    const root = try ensureObject(allocator, &parsed.value);
    var packages = try ensurePackagesArray(allocator, root);
    const match_key = try sourceMatchKeyForInput(allocator, env, cwd, source);
    defer allocator.free(match_key);

    for (packages.items) |*item| {
        const existing_source = packageSourceString(item.*) orelse continue;
        const existing_key = try sourceMatchKeyForSettings(allocator, env, base_dir, existing_source);
        defer allocator.free(existing_key);
        if (!std.mem.eql(u8, existing_key, match_key)) continue;

        if (item.* == .object) {
            try item.object.put(allocator, "source", .{ .string = normalized });
        } else {
            item.* = .{ .string = normalized };
        }
        try writeSettings(io, allocator, settings_path, parsed.value);
        return !std.mem.eql(u8, existing_source, normalized);
    }

    try packages.append(.{ .string = normalized });
    try writeSettings(io, allocator, settings_path, parsed.value);
    return true;
}

fn removeSourceFromSettings(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    agent_dir: []const u8,
    source: []const u8,
    local: bool,
) !bool {
    const settings_path = try settingsPath(allocator, agent_dir, local);
    defer allocator.free(settings_path);
    const base_dir = try settingsBaseDir(allocator, cwd, agent_dir, local);
    defer allocator.free(base_dir);

    var parsed = try loadSettings(io, allocator, settings_path);
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const package_value = parsed.value.object.getPtr("packages") orelse return false;
    if (package_value.* != .array) return false;
    const match_key = try sourceMatchKeyForInput(allocator, env, cwd, source);
    defer allocator.free(match_key);

    var write_index: usize = 0;
    var removed = false;
    for (package_value.array.items) |item| {
        const existing_source = packageSourceString(item);
        var keep = true;
        if (existing_source) |existing| {
            const existing_key = try sourceMatchKeyForSettings(allocator, env, base_dir, existing);
            defer allocator.free(existing_key);
            if (std.mem.eql(u8, existing_key, match_key)) {
                keep = false;
                removed = true;
            }
        }
        if (keep) {
            package_value.array.items[write_index] = item;
            write_index += 1;
        }
    }
    if (!removed) return false;
    package_value.array.shrinkRetainingCapacity(write_index);
    try writeSettings(io, allocator, settings_path, parsed.value);
    return true;
}

fn listConfiguredPackages(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, cwd: []const u8, agent_dir: []const u8) !void {
    const user_settings = try settingsPath(allocator, agent_dir, false);
    defer allocator.free(user_settings);
    const project_settings = try settingsPath(allocator, agent_dir, true);
    defer allocator.free(project_settings);

    const user_count = try writePackageListForScope(io, allocator, env, user_settings, agent_dir, "User packages:", "user");
    const project_base = try settingsBaseDir(allocator, cwd, agent_dir, true);
    defer allocator.free(project_base);
    const project_count = try writePackageListForScope(io, allocator, env, project_settings, project_base, "Project packages:", "project");
    if (user_count == 0 and project_count == 0) {
        try writeStdout(io, "No packages installed.\n");
    }
}

fn writePackageListForScope(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    settings_path: []const u8,
    base_dir: []const u8,
    heading: []const u8,
    scope: []const u8,
) !usize {
    var parsed = try loadSettings(io, allocator, settings_path);
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    const packages = parsed.value.object.get("packages") orelse return 0;
    if (packages != .array or packages.array.items.len == 0) return 0;

    try writeStdout(io, heading);
    try writeStdout(io, "\n");
    var count: usize = 0;
    for (packages.array.items) |item| {
        const source = packageSourceString(item) orelse continue;
        try writeStdout(io, "  ");
        try writeStdout(io, source);
        if (item == .object) try writeStdout(io, " (filtered)");
        try writeStdout(io, "\n");
        if (try installedPath(io, allocator, env, base_dir, source, scope)) |path| {
            defer allocator.free(path);
            try writeStdout(io, "    ");
            try writeStdout(io, path);
            try writeStdout(io, "\n");
        }
        count += 1;
    }
    return count;
}

fn loadSettings(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_settings_bytes)) catch |err| switch (err) {
        error.FileNotFound => return std.json.parseFromSlice(std.json.Value, allocator, "{}", .{}),
        else => return err,
    };
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
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

fn ensureObject(allocator: std.mem.Allocator, value: *std.json.Value) !*std.json.ObjectMap {
    _ = allocator;
    if (value.* != .object) {
        value.* = .{ .object = .empty };
    }
    return &value.object;
}

fn ensurePackagesArray(allocator: std.mem.Allocator, object: *std.json.ObjectMap) !*std.json.Array {
    if (object.getPtr("packages")) |value| {
        if (value.* != .array) {
            value.* = .{ .array = std.json.Array.init(allocator) };
        }
        return &value.array;
    }
    try object.put(allocator, "packages", .{ .array = std.json.Array.init(allocator) });
    return &object.getPtr("packages").?.array;
}

fn packageSourceString(value: std.json.Value) ?[]const u8 {
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

fn parseSource(source: []const u8) ParsedSource {
    if (std.mem.startsWith(u8, source, "npm:")) {
        const spec = std.mem.trim(u8, source["npm:".len..], " \t\r\n");
        return .{ .kind = .npm, .source = source, .name = npmPackageName(spec) };
    }
    if (isLocalPath(source)) return .{ .kind = .local, .source = source, .path = source };
    if (parseGitSource(source)) |git| return git;
    return .{ .kind = .local, .source = source, .path = source };
}

fn parseGitSource(source: []const u8) ?ParsedSource {
    if (std.mem.startsWith(u8, source, "git:")) {
        const rest = source["git:".len..];
        if (std.mem.startsWith(u8, rest, "git@")) return parseGitAt(source, rest);
        if (parseProtocolGit(source, rest)) |git| return git;
        return parseHostPath(source, rest);
    }
    return parseProtocolGit(source, source);
}

fn parseProtocolGit(original: []const u8, raw: []const u8) ?ParsedSource {
    const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return null;
    const after_scheme = raw[scheme_end + "://".len ..];
    const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return null;
    var host = after_scheme[0..slash];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    const path_with_ref = after_scheme[slash + 1 ..];
    const path = stripGitSuffix(stripRef(path_with_ref));
    if (host.len == 0 or path.len == 0) return null;
    return .{ .kind = .git, .source = original, .host = host, .path = path };
}

fn parseGitAt(original: []const u8, raw: []const u8) ?ParsedSource {
    const after_user = raw["git@".len..];
    const colon = std.mem.indexOfScalar(u8, after_user, ':') orelse return null;
    const host = after_user[0..colon];
    const path = stripGitSuffix(stripRef(after_user[colon + 1 ..]));
    if (host.len == 0 or path.len == 0) return null;
    return .{ .kind = .git, .source = original, .host = host, .path = path };
}

fn parseHostPath(original: []const u8, raw: []const u8) ?ParsedSource {
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return null;
    const host = raw[0..slash];
    const path = stripGitSuffix(stripRef(raw[slash + 1 ..]));
    if (host.len == 0 or path.len == 0) return null;
    return .{ .kind = .git, .source = original, .host = host, .path = path };
}

fn npmPackageName(spec: []const u8) []const u8 {
    if (spec.len == 0) return spec;
    const search_start: usize = if (spec[0] == '@') 1 else 0;
    if (std.mem.lastIndexOfScalar(u8, spec[search_start..], '@')) |relative_at| {
        const at = search_start + relative_at;
        return spec[0..at];
    }
    return spec;
}

fn stripRef(value: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, value, '@')) |at| return value[0..at];
    return value;
}

fn stripGitSuffix(value: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, value, ".git")) value[0 .. value.len - ".git".len] else value;
}

fn sourceMatchKeyForInput(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, cwd: []const u8, source: []const u8) ![]u8 {
    const parsed = parseSource(source);
    return sourceMatchKey(allocator, env, cwd, parsed);
}

fn sourceMatchKeyForSettings(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, base_dir: []const u8, source: []const u8) ![]u8 {
    const parsed = parseSource(source);
    return sourceMatchKey(allocator, env, base_dir, parsed);
}

fn sourceMatchKey(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, base_dir: []const u8, parsed: ParsedSource) ![]u8 {
    switch (parsed.kind) {
        .npm => return try std.fmt.allocPrint(allocator, "npm:{s}", .{parsed.name}),
        .git => return try std.fmt.allocPrint(allocator, "git:{s}/{s}", .{ parsed.host, parsed.path }),
        .local => {
            const resolved = try resolveLocalPathWithEnv(allocator, env, base_dir, parsed.path);
            defer allocator.free(resolved);
            return trimTrailingSlashesOwned(allocator, resolved);
        },
    }
}

fn normalizePackageSourceForSettings(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    base_dir: []const u8,
    source: []const u8,
) ![]u8 {
    const parsed = parseSource(source);
    if (parsed.kind != .local) return allocator.dupe(u8, source);
    const resolved = try resolveLocalPathWithEnv(allocator, env, cwd, parsed.path);
    defer allocator.free(resolved);
    const rel = try std.fs.path.relative(allocator, cwd, env, base_dir, resolved);
    if (rel.len == 0) return rel;
    if (std.fs.path.isAbsolute(rel) or std.mem.startsWith(u8, rel, ".")) return rel;
    defer allocator.free(rel);
    return std.fmt.allocPrint(allocator, "./{s}", .{rel});
}

fn installedPath(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, base_dir: []const u8, source: []const u8, scope: []const u8) !?[]u8 {
    const parsed = parseSource(source);
    const path = switch (parsed.kind) {
        .local => try resolveLocalPathWithEnv(allocator, env, base_dir, parsed.path),
        .npm => try std.fs.path.join(allocator, &.{ base_dir, "npm", "node_modules", parsed.name }),
        .git => try std.fs.path.join(allocator, &.{ base_dir, "git", parsed.host, parsed.path }),
    };
    errdefer allocator.free(path);
    _ = scope;
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| {
        return path;
    } else |_| {
        allocator.free(path);
        return null;
    }
}

fn settingsPath(allocator: std.mem.Allocator, agent_dir: []const u8, local: bool) ![]u8 {
    if (local) return allocator.dupe(u8, project_settings_file);
    return std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
}

fn settingsBaseDir(allocator: std.mem.Allocator, cwd: []const u8, agent_dir: []const u8, local: bool) ![]u8 {
    if (!local) return allocator.dupe(u8, agent_dir);
    return std.fs.path.join(allocator, &.{ cwd, ".pi" });
}

fn agentDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("PI_CODING_AGENT_DIR")) |value| {
        return expandMaybeTilde(allocator, env, value);
    }
    const home = env.get("HOME") orelse ".";
    return std.fs.path.join(allocator, &.{ home, ".pi", "agent" });
}

fn expandMaybeTilde(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~")) {
        return allocator.dupe(u8, env.get("HOME") orelse ".");
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        return std.fs.path.join(allocator, &.{ env.get("HOME") orelse ".", path[2..] });
    }
    return allocator.dupe(u8, path);
}

fn resolveLocalPath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn resolveLocalPathWithEnv(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, base_dir: []const u8, path: []const u8) ![]u8 {
    const expanded = try expandMaybeTilde(allocator, env, path);
    defer allocator.free(expanded);
    return resolveLocalPath(allocator, base_dir, expanded);
}

fn trimTrailingSlashesOwned(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var end = value.len;
    while (end > 1 and (value[end - 1] == '/' or value[end - 1] == '\\')) : (end -= 1) {}
    return allocator.dupe(u8, value[0..end]);
}

fn currentPathOwned(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn isLocalPath(source: []const u8) bool {
    return std.fs.path.isAbsolute(source) or
        std.mem.eql(u8, source, "~") or
        std.mem.startsWith(u8, source, "~/") or
        std.mem.startsWith(u8, source, "./") or
        std.mem.startsWith(u8, source, "../");
}

fn commandName(command: Command) []const u8 {
    return switch (command) {
        .install => "install",
        .remove => "remove",
        .update => "update",
        .list => "list",
    };
}

fn writeUsageHint(io: std.Io, command: Command) !void {
    try writeStderr(io, "Use \"pi-zig --help\" or \"");
    try writeStderr(io, usageText(command));
    try writeStderr(io, "\".\n");
}

fn writeUsageLine(io: std.Io, command: Command) !void {
    try writeStderr(io, "Usage: ");
    try writeStderr(io, usageText(command));
    try writeStderr(io, "\n");
}

fn usageText(command: Command) []const u8 {
    return switch (command) {
        .install => "pi-zig install <source> [-l]",
        .remove => "pi-zig remove <source> [-l]",
        .update => "pi-zig update [source|self|pi] [--self] [--extensions] [--extension <source>] [--force]",
        .list => "pi-zig list",
    };
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeStderr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

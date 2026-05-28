const std = @import("std");

const max_theme_bytes = 1024 * 1024;
const max_settings_bytes = 1024 * 1024;

const dark_json = @embedFile("themes/dark.json");
const light_json = @embedFile("themes/light.json");

const builtin_dark_path = "upstream/pi/packages/coding-agent/src/modes/interactive/theme/dark.json";
const builtin_light_path = "upstream/pi/packages/coding-agent/src/modes/interactive/theme/light.json";

const builtin_themes = [_]BuiltinTheme{
    .{ .name = "dark", .path = builtin_dark_path, .bytes = dark_json },
    .{ .name = "light", .path = builtin_light_path, .bytes = light_json },
};

const BuiltinTheme = struct {
    name: []const u8,
    path: []const u8,
    bytes: []const u8,
};

const Options = struct {
    help: bool = false,
    detect: bool = false,
    export_name: ?[]const u8 = null,
    resolved_name: ?[]const u8 = null,
    no_themes: bool = false,
    paths: [16][]const u8 = undefined,
    paths_len: usize = 0,
    invalid_option: ?[]const u8 = null,
    missing_option_value: ?[]const u8 = null,

    fn addPath(self: *Options, path: []const u8) void {
        if (self.paths_len >= self.paths.len) {
            self.invalid_option = self.invalid_option orelse "too many --theme values";
            return;
        }
        self.paths[self.paths_len] = path;
        self.paths_len += 1;
    }
};

const ThemeEntry = struct {
    name: []u8,
    source: []const u8,
    path: ?[]u8 = null,
    builtin: ?[]const u8 = null,

    fn deinit(self: ThemeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.path) |path| allocator.free(path);
    }
};

// Mirrors upstream ResourceCollision (core/diagnostics.ts): the shadowed
// duplicate's resource type/name plus the winner and loser source paths.
const ThemeCollision = struct {
    resource_type: []const u8 = "theme",
    name: []u8,
    winner_path: []u8,
    loser_path: []u8,

    fn deinit(self: ThemeCollision, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.winner_path);
        allocator.free(self.loser_path);
    }
};

const Diagnostic = struct {
    severity: []const u8 = "warning",
    message: []u8,
    path: ?[]u8 = null,
    // Upstream diagnostics carry a `type` discriminant ("warning"|"error"|
    // "collision"); when this is set the diagnostic is a name-collision and also
    // serializes a `collision` object matching dedupeThemes.
    collision: ?ThemeCollision = null,

    fn deinit(self: Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.path) |path| allocator.free(path);
        if (self.collision) |collision| collision.deinit(allocator);
    }
};

const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ThemeEntry),
    diagnostics: std.ArrayList(Diagnostic),
    seen: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .diagnostics = .empty,
            .seen = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *Registry) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        for (self.diagnostics.items) |diagnostic| diagnostic.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.seen.deinit();
    }

    fn addDiagnostic(self: *Registry, message: []const u8, path: ?[]const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .message = try self.allocator.dupe(u8, message),
            .path = if (path) |p| try self.allocator.dupe(u8, p) else null,
        });
    }

    // Emit an upstream-shaped `collision` diagnostic for a theme name that is
    // shadowed by an already-registered (higher-precedence) theme. Mirrors
    // resource-loader.ts dedupeThemes: message `name "<name>" collision`, the
    // diagnostic `path` is the loser's source path, and winner/loser source
    // paths fall back to "<builtin>" when a theme has no file path.
    fn addCollisionDiagnostic(self: *Registry, name: []const u8, loser_path: ?[]const u8) !void {
        const winner_path = self.themePathForName(name) orelse "<builtin>";
        const message = try std.fmt.allocPrint(self.allocator, "name \"{s}\" collision", .{name});
        errdefer self.allocator.free(message);
        const loser = loser_path orelse "<builtin>";
        try self.diagnostics.append(self.allocator, .{
            .severity = "collision",
            .message = message,
            .path = if (loser_path) |p| try self.allocator.dupe(u8, p) else null,
            .collision = .{
                .name = try self.allocator.dupe(u8, name),
                .winner_path = try self.allocator.dupe(u8, winner_path),
                .loser_path = try self.allocator.dupe(u8, loser),
            },
        });
    }

    fn themePathForName(self: *const Registry, name: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.path;
        }
        return null;
    }

    fn addBytes(self: *Registry, name_hint: []const u8, source: []const u8, path: ?[]const u8, bytes: []const u8, builtin: ?[]const u8) !void {
        const name = themeNameFromBytes(self.allocator, name_hint, bytes) catch |err| {
            const message = try std.fmt.allocPrint(self.allocator, "failed to load theme: {s}", .{@errorName(err)});
            defer self.allocator.free(message);
            try self.addDiagnostic(message, path);
            return;
        };
        errdefer self.allocator.free(name);

        if (self.seen.contains(name)) {
            try self.addCollisionDiagnostic(name, path);
            self.allocator.free(name);
            return;
        }
        try self.seen.put(name, {});
        errdefer _ = self.seen.remove(name);

        try self.entries.append(self.allocator, .{
            .name = name,
            .source = source,
            .path = if (path) |p| try self.allocator.dupe(u8, p) else null,
            .builtin = builtin,
        });
    }

    fn addFile(self: *Registry, io: std.Io, source: []const u8, path: []const u8) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(max_theme_bytes)) catch |err| {
            const message = try std.fmt.allocPrint(self.allocator, "failed to read theme: {s}", .{@errorName(err)});
            defer self.allocator.free(message);
            try self.addDiagnostic(message, path);
            return;
        };
        defer self.allocator.free(bytes);
        try self.addBytes(path, source, path, bytes, null);
    }

    fn addPath(self: *Registry, io: std.Io, source: []const u8, path: []const u8) !void {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try self.addDiagnostic("theme path does not exist", path);
                return;
            },
            else => {
                const message = try std.fmt.allocPrint(self.allocator, "failed to stat theme path: {s}", .{@errorName(err)});
                defer self.allocator.free(message);
                try self.addDiagnostic(message, path);
                return;
            },
        };

        switch (stat.kind) {
            .directory => try self.addDir(io, source, path),
            .file, .sym_link => {
                if (!std.mem.endsWith(u8, path, ".json")) {
                    try self.addDiagnostic("theme path is not a json file", path);
                    return;
                }
                try self.addFile(io, source, path);
            },
            else => try self.addDiagnostic("theme path is neither file nor directory", path),
        }
    }

    fn addDefaultDir(self: *Registry, io: std.Io, source: []const u8, dir_path: []const u8) !void {
        const stat = std.Io.Dir.cwd().statFile(io, dir_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stat.kind != .directory) return;
        try self.addDir(io, source, dir_path);
    }

    fn addDir(self: *Registry, io: std.Io, source: []const u8, dir_path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                const message = try std.fmt.allocPrint(self.allocator, "failed to read theme directory: {s}", .{@errorName(err)});
                defer self.allocator.free(message);
                try self.addDiagnostic(message, dir_path);
                return;
            },
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const child = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer self.allocator.free(child);
            try self.addFile(io, source, child);
        }
    }

    fn addBuiltins(self: *Registry) !void {
        for (builtin_themes) |builtin| {
            try self.addBytes(builtin.name, "builtin", builtin.path, builtin.bytes, builtin.name);
        }
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !bool {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "themes")) return false;
    const options = parseOptions(args[1..]);

    if (options.help) {
        try writeHelp(io);
        return true;
    }
    if (options.invalid_option) |option| {
        try writeStderr(io, "Unknown option ");
        try writeStderr(io, option);
        try writeStderr(io, " for \"themes\".\n");
        try writeStderr(io, "Use \"pi-zig themes --help\".\n");
        std.process.exit(1);
    }
    if (options.missing_option_value) |option| {
        try writeStderr(io, "Missing value for ");
        try writeStderr(io, option);
        try writeStderr(io, ".\n");
        std.process.exit(1);
    }

    if (options.detect) {
        return writeDetectionJson(io, env);
    }

    var registry = try buildRegistry(io, allocator, env, options);
    defer registry.deinit();

    if (options.export_name) |name| {
        try writeThemeExportJson(io, allocator, &registry, name);
        return true;
    }
    if (options.resolved_name) |name| {
        try writeResolvedThemeJson(io, allocator, &registry, name);
        return true;
    }

    try writeThemeListJson(io, &registry);
    return true;
}

fn parseOptions(args: []const []const u8) Options {
    var options = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--detect")) {
            options.detect = true;
        } else if (std.mem.eql(u8, arg, "--no-themes")) {
            options.no_themes = true;
        } else if (std.mem.eql(u8, arg, "--theme")) {
            const value = if (i + 1 < args.len) args[i + 1] else "";
            if (value.len == 0 or std.mem.startsWith(u8, value, "-")) {
                options.missing_option_value = options.missing_option_value orelse arg;
            } else {
                options.addPath(value);
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--export")) {
            const value = if (i + 1 < args.len) args[i + 1] else "";
            if (value.len == 0 or std.mem.startsWith(u8, value, "-")) {
                options.missing_option_value = options.missing_option_value orelse arg;
            } else {
                options.export_name = value;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--resolved")) {
            const value = if (i + 1 < args.len) args[i + 1] else "";
            if (value.len == 0 or std.mem.startsWith(u8, value, "-")) {
                options.missing_option_value = options.missing_option_value orelse arg;
            } else {
                options.resolved_name = value;
                i += 1;
            }
        } else {
            options.invalid_option = options.invalid_option orelse arg;
        }
    }
    return options;
}

fn buildRegistry(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, options: Options) !Registry {
    var registry = Registry.init(allocator);
    errdefer registry.deinit();

    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);
    const agent_dir = try agentDir(allocator, env);
    defer allocator.free(agent_dir);

    // Built-in themes are added first: upstream resolves names against the
    // built-in map before any custom theme (config.ts loadThemeJson / theme.ts
    // getAvailableThemesWithPaths), so a user theme named "dark"/"light" cannot
    // shadow a built-in. First-wins dedup then gives built-ins highest priority.
    try registry.addBuiltins();

    if (!options.no_themes) {
        const project_base = try std.fs.path.join(allocator, &.{ cwd, ".pi" });
        defer allocator.free(project_base);
        const user_settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
        defer allocator.free(user_settings_path);

        // Discovered themes follow the package-manager precedence ranking
        // (resourcePrecedenceRank): project settings (rank 0) -> project auto
        // (rank 1) -> user settings (rank 2) -> user auto (rank 3) -> packages
        // (rank 4). First-wins dedup makes the highest-precedence theme win a
        // name collision, matching upstream's resolved theme list.
        try addThemeSettings(io, allocator, env, &registry, ".pi/settings.json", project_base, "project");

        const project_themes = try std.fs.path.join(allocator, &.{ cwd, ".pi", "themes" });
        defer allocator.free(project_themes);
        try registry.addDefaultDir(io, "project", project_themes);

        try addThemeSettings(io, allocator, env, &registry, user_settings_path, agent_dir, "user");

        const user_themes = try std.fs.path.join(allocator, &.{ agent_dir, "themes" });
        defer allocator.free(user_themes);
        try registry.addDefaultDir(io, "user", user_themes);

        try addPackageThemesFromSettings(io, allocator, env, &registry, ".pi/settings.json", project_base);
        try addPackageThemesFromSettings(io, allocator, env, &registry, user_settings_path, agent_dir);
    }

    // Temporary (--theme) paths are appended last, matching upstream's
    // additionalThemePaths being merged after resolved + package themes.
    for (options.paths[0..options.paths_len]) |raw_path| {
        const resolved = try resolvePathWithBase(allocator, env, cwd, raw_path);
        defer allocator.free(resolved);
        try registry.addPath(io, "temporary", resolved);
    }

    return registry;
}

fn addThemeSettings(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    registry: *Registry,
    settings_path: []const u8,
    base_dir: []const u8,
    source: []const u8,
) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, settings_path, allocator, .limited(max_settings_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const themes = parsed.value.object.get("themes") orelse return;
    if (themes != .array) return;

    for (themes.array.items) |entry| {
        if (entry != .string) continue;
        const raw = std.mem.trim(u8, entry.string, " \t\r\n");
        if (raw.len == 0 or raw[0] == '!' or raw[0] == '+' or raw[0] == '-') continue;
        const resolved = try resolvePathWithBase(allocator, env, base_dir, raw);
        defer allocator.free(resolved);
        try registry.addPath(io, source, resolved);
    }
}

fn addPackageThemesFromSettings(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    registry: *Registry,
    settings_path: []const u8,
    base_dir: []const u8,
) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, settings_path, allocator, .limited(max_settings_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const packages = parsed.value.object.get("packages") orelse return;
    if (packages != .array) return;

    for (packages.array.items) |package| {
        const source = packageSourceString(package) orelse continue;
        if (!isLocalPackageSource(source)) continue;
        const package_root = resolvePathWithBase(allocator, env, base_dir, source) catch continue;
        defer allocator.free(package_root);

        const filter_entries: ?[]const std.json.Value = if (package == .object)
            if (package.object.get("themes")) |themes| if (themes == .array) themes.array.items else null else null
        else
            null;

        try addPackageThemeFiles(io, allocator, registry, package_root, filter_entries);
    }
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

fn addPackageThemeFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    registry: *Registry,
    package_root: []const u8,
    filter_entries: ?[]const std.json.Value,
) !void {
    var files: std.ArrayList([]u8) = .empty;
    defer freeStringList(allocator, &files);

    var manifest_entries: ?[]const std.json.Value = null;
    const package_json = try std.fmt.allocPrint(allocator, "{s}/package.json", .{package_root});
    defer allocator.free(package_json);
    const package_json_bytes = std.Io.Dir.cwd().readFileAlloc(io, package_json, allocator, .limited(max_settings_bytes)) catch null;
    defer if (package_json_bytes) |bytes| allocator.free(bytes);
    var manifest_parsed: ?std.json.Parsed(std.json.Value) = if (package_json_bytes) |bytes|
        std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch null
    else
        null;
    defer if (manifest_parsed) |*parsed| parsed.deinit();

    if (manifest_parsed) |parsed| {
        if (parsed.value == .object) {
            if (parsed.value.object.get("pi")) |pi_value| {
                if (pi_value == .object) {
                    if (pi_value.object.get("themes")) |themes| {
                        if (themes == .array and themes.array.items.len > 0) {
                            manifest_entries = themes.array.items;
                            try collectManifestThemeFiles(io, allocator, package_root, manifest_entries.?, &files);
                        }
                    }
                }
            }
        }
    }

    if (manifest_entries == null) {
        const themes_dir = try std.fmt.allocPrint(allocator, "{s}/themes", .{package_root});
        defer allocator.free(themes_dir);
        try collectThemeFilesRecursive(io, allocator, themes_dir, &files);
    }

    if (filter_entries) |entries| {
        if (entries.len == 0) return;
    }

    for (files.items) |path| {
        if (manifest_entries) |entries| {
            if (!isEnabledByThemeEntries(path, package_root, entries, false)) continue;
        }
        if (filter_entries) |entries| {
            if (!isEnabledByThemeEntries(path, package_root, entries, true)) continue;
        }
        try registry.addFile(io, "package", path);
    }
}

fn collectManifestThemeFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    package_root: []const u8,
    entries: []const std.json.Value,
    files: *std.ArrayList([]u8),
) !void {
    for (entries) |entry| {
        if (entry != .string) continue;
        const raw = std.mem.trim(u8, entry.string, " \t\r\n");
        if (raw.len == 0 or isOverrideEntry(raw)) continue;

        if (hasGlobPattern(raw)) {
            var all_files: std.ArrayList([]u8) = .empty;
            defer freeStringList(allocator, &all_files);
            try collectThemeFilesRecursive(io, allocator, package_root, &all_files);
            for (all_files.items) |path| {
                if (!matchesThemePattern(path, raw, package_root)) continue;
                try appendUniquePath(allocator, files, path);
            }
            continue;
        }

        const resolved = try resolvePathWithBase(allocator, undefined, package_root, raw);
        defer allocator.free(resolved);
        try collectThemeFilesFromPath(io, allocator, resolved, files);
    }
}

fn collectThemeFilesFromPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8, files: *std.ArrayList([]u8)) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };
    switch (stat.kind) {
        .directory => try collectThemeFilesRecursive(io, allocator, path, files),
        .file, .sym_link => if (std.mem.endsWith(u8, path, ".json")) try appendUniquePath(allocator, files, path),
        else => {},
    }
}

fn collectThemeFilesRecursive(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8, files: *std.ArrayList([]u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "node_modules")) continue;
        const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(child);
        if (entry.kind == .directory) {
            try collectThemeFilesRecursive(io, allocator, child, files);
        } else if ((entry.kind == .file or entry.kind == .sym_link) and std.mem.endsWith(u8, entry.name, ".json")) {
            try appendUniquePath(allocator, files, child);
        }
    }
}

fn appendUniquePath(allocator: std.mem.Allocator, files: *std.ArrayList([]u8), path: []const u8) !void {
    for (files.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try files.append(allocator, try allocator.dupe(u8, path));
}

fn freeStringList(allocator: std.mem.Allocator, files: *std.ArrayList([]u8)) void {
    for (files.items) |path| allocator.free(path);
    files.deinit(allocator);
}

fn isEnabledByThemeEntries(path: []const u8, base_dir: []const u8, entries: []const std.json.Value, plain_entries_are_includes: bool) bool {
    var include_count: usize = 0;
    var include_match = false;
    var exclude_match = false;
    var force_include_match = false;
    var force_exclude_match = false;

    for (entries) |entry| {
        if (entry != .string) continue;
        const raw = std.mem.trim(u8, entry.string, " \t\r\n");
        if (raw.len == 0) continue;

        if (raw[0] == '+') {
            force_include_match = force_include_match or matchesExactThemePattern(path, raw[1..], base_dir);
        } else if (raw[0] == '-') {
            force_exclude_match = force_exclude_match or matchesExactThemePattern(path, raw[1..], base_dir);
        } else if (raw[0] == '!') {
            exclude_match = exclude_match or matchesThemePattern(path, raw[1..], base_dir);
        } else if (plain_entries_are_includes) {
            include_count += 1;
            include_match = include_match or matchesThemePattern(path, raw, base_dir);
        }
    }

    var enabled = if (include_count == 0) true else include_match;
    if (exclude_match) enabled = false;
    if (force_include_match) enabled = true;
    if (force_exclude_match) enabled = false;
    return enabled;
}

fn isOverrideEntry(value: []const u8) bool {
    return value[0] == '!' or value[0] == '+' or value[0] == '-';
}

fn hasGlobPattern(value: []const u8) bool {
    for (value) |byte| {
        switch (byte) {
            '*', '?', '[', ']' => return true,
            else => {},
        }
    }
    return false;
}

fn matchesThemePattern(path: []const u8, raw_pattern: []const u8, base_dir: []const u8) bool {
    const pattern = normalizePattern(raw_pattern);
    if (pattern.len == 0) return false;
    if (wildcardMatch(pattern, path)) return true;
    if (pathRelativeToBase(path, base_dir)) |relative| {
        if (wildcardMatch(pattern, relative)) return true;
    }
    return wildcardMatch(pattern, std.fs.path.basename(path));
}

fn matchesExactThemePattern(path: []const u8, raw_pattern: []const u8, base_dir: []const u8) bool {
    const pattern = normalizePattern(raw_pattern);
    if (pattern.len == 0) return false;
    if (std.mem.eql(u8, pattern, path)) return true;
    if (pathRelativeToBase(path, base_dir)) |relative| {
        if (std.mem.eql(u8, pattern, relative)) return true;
    }
    return false;
}

fn normalizePattern(pattern: []const u8) []const u8 {
    var normalized = std.mem.trim(u8, pattern, " \t\r\n");
    if (std.mem.startsWith(u8, normalized, "./") or std.mem.startsWith(u8, normalized, ".\\")) {
        normalized = normalized[2..];
    }
    return normalized;
}

fn wildcardMatch(pattern: []const u8, value: []const u8) bool {
    if (pattern.len == 0) return value.len == 0;
    if (pattern[0] == '*') {
        var next_index: usize = 1;
        while (next_index < pattern.len and pattern[next_index] == '*') : (next_index += 1) {}
        const rest = pattern[next_index..];
        if (rest.len == 0) return true;

        var index: usize = 0;
        while (index <= value.len) : (index += 1) {
            if (wildcardMatch(rest, value[index..])) return true;
        }
        return false;
    }

    if (value.len == 0) return false;
    if (pattern[0] == '?') return wildcardMatch(pattern[1..], value[1..]);
    if (pattern[0] != value[0]) return false;
    return wildcardMatch(pattern[1..], value[1..]);
}

fn pathRelativeToBase(path: []const u8, base_dir: []const u8) ?[]const u8 {
    if (base_dir.len == 0) return null;
    if (std.mem.eql(u8, path, base_dir)) return "";
    if (!std.mem.startsWith(u8, path, base_dir)) return null;
    if (path.len <= base_dir.len) return null;
    if (path[base_dir.len] != '/') return null;
    return path[base_dir.len + 1 ..];
}

fn isLocalPackageSource(source: []const u8) bool {
    return !(std.mem.startsWith(u8, source, "npm:") or
        std.mem.startsWith(u8, source, "git:") or
        std.mem.startsWith(u8, source, "github:") or
        std.mem.startsWith(u8, source, "http:") or
        std.mem.startsWith(u8, source, "https:") or
        std.mem.startsWith(u8, source, "ssh:"));
}

fn writeThemeListJson(io: std.Io, registry: *const Registry) !void {
    var buf: [32 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;

    try w.writeAll("{\"themes\":[");
    for (registry.entries.items, 0..) |entry, index| {
        if (index != 0) try w.writeByte(',');
        try writeThemeEntryJson(w, entry);
    }
    try w.writeAll("],\"diagnostics\":[");
    for (registry.diagnostics.items, 0..) |diagnostic, index| {
        if (index != 0) try w.writeByte(',');
        try writeDiagnosticJson(w, diagnostic);
    }
    try w.writeAll("]}\n");
    try w.flush();
}

fn writeThemeEntryJson(w: *std.Io.Writer, entry: ThemeEntry) !void {
    try w.writeAll("{\"name\":");
    try writeJsonString(w, entry.name);
    try w.writeAll(",\"source\":");
    try writeJsonString(w, entry.source);
    try w.writeAll(",\"path\":");
    if (entry.path) |path| {
        try writeJsonString(w, path);
    } else {
        try w.writeAll("null");
    }
    try w.writeByte('}');
}

fn writeDiagnosticJson(w: *std.Io.Writer, diagnostic: Diagnostic) !void {
    // `severity` is retained for backward compatibility; `type` is the upstream
    // ResourceDiagnostic discriminant ("warning"|"error"|"collision") and equals
    // severity here. Collisions additionally serialize a `collision` object.
    try w.writeAll("{\"severity\":");
    try writeJsonString(w, diagnostic.severity);
    try w.writeAll(",\"type\":");
    try writeJsonString(w, diagnostic.severity);
    try w.writeAll(",\"message\":");
    try writeJsonString(w, diagnostic.message);
    try w.writeAll(",\"path\":");
    if (diagnostic.path) |path| {
        try writeJsonString(w, path);
    } else {
        try w.writeAll("null");
    }
    if (diagnostic.collision) |collision| {
        try w.writeAll(",\"collision\":{\"resourceType\":");
        try writeJsonString(w, collision.resource_type);
        try w.writeAll(",\"name\":");
        try writeJsonString(w, collision.name);
        try w.writeAll(",\"winnerPath\":");
        try writeJsonString(w, collision.winner_path);
        try w.writeAll(",\"loserPath\":");
        try writeJsonString(w, collision.loser_path);
        try w.writeByte('}');
    }
    try w.writeByte('}');
}

fn writeThemeExportJson(io: std.Io, allocator: std.mem.Allocator, registry: *const Registry, name: []const u8) !void {
    var parsed = try loadThemeByName(io, allocator, registry, name);
    defer parsed.deinit();
    const theme_object = parsed.value.object;
    const export_value = theme_object.get("export");
    const vars = if (theme_object.get("vars")) |vars_value| if (vars_value == .object) vars_value.object else null else null;

    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll("{\"name\":");
    try writeJsonString(w, theme_object.get("name").?.string);
    try w.writeAll(",\"export\":{");

    var emitted: usize = 0;
    if (export_value) |value| {
        if (value == .object) {
            try writeExportField(allocator, w, &emitted, value.object, vars, "pageBg");
            try writeExportField(allocator, w, &emitted, value.object, vars, "cardBg");
            try writeExportField(allocator, w, &emitted, value.object, vars, "infoBg");
        }
    }
    try w.writeAll("}}\n");
    try w.flush();
}

fn writeExportField(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    object: std.json.ObjectMap,
    vars: ?std.json.ObjectMap,
    key: []const u8,
) !void {
    const value = object.get(key) orelse return;
    const resolved = try resolveColorValue(allocator, value, vars);
    switch (resolved) {
        .empty => return,
        else => {},
    }
    if (emitted.* != 0) try w.writeByte(',');
    try writeJsonString(w, key);
    try w.writeByte(':');
    try writeResolvedColorAsHexJson(allocator, w, resolved, "#e5e5e7");
    emitted.* += 1;
}

fn writeResolvedThemeJson(io: std.Io, allocator: std.mem.Allocator, registry: *const Registry, name: []const u8) !void {
    var parsed = try loadThemeByName(io, allocator, registry, name);
    defer parsed.deinit();
    const theme_object = parsed.value.object;
    const colors = theme_object.get("colors").?.object;
    const vars = if (theme_object.get("vars")) |vars_value| if (vars_value == .object) vars_value.object else null else null;
    const default_text = if (std.mem.eql(u8, theme_object.get("name").?.string, "light")) "#000000" else "#e5e5e7";

    var buf: [64 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll("{\"name\":");
    try writeJsonString(w, theme_object.get("name").?.string);
    try w.writeAll(",\"colors\":{");

    var emitted: usize = 0;
    for (required_color_keys) |key| {
        const value = colors.get(key) orelse continue;
        const resolved = try resolveColorValue(allocator, value, vars);
        if (emitted != 0) try w.writeByte(',');
        try writeJsonString(w, key);
        try w.writeByte(':');
        try writeResolvedColorAsHexJson(allocator, w, resolved, default_text);
        emitted += 1;
    }
    try w.writeAll("}}\n");
    try w.flush();
}

fn writeDetectionJson(io: std.Io, env: *const std.process.Environ.Map) !bool {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    if (env.get("COLORFGBG")) |colorfgbg| {
        if (colorFgBgBackgroundIndex(colorfgbg)) |index| {
            const hex = ansi256ToHexBuffer(index);
            const rgb = hexToRgb(hex[0..]) catch Rgb{ .r = 0, .g = 0, .b = 0 };
            const theme_name: []const u8 = if (rgbLuminance(rgb) >= 0.5) "light" else "dark";
            try w.writeAll("{\"theme\":");
            try writeJsonString(w, theme_name);
            try w.writeAll(",\"source\":\"COLORFGBG\",\"detail\":\"background color index ");
            try w.print("{d}", .{index});
            try w.writeAll("\",\"confidence\":\"high\"}\n");
            try w.flush();
            return true;
        }
    }
    try w.writeAll("{\"theme\":\"dark\",\"source\":\"fallback\",\"detail\":\"no terminal background hint found\",\"confidence\":\"low\"}\n");
    try w.flush();
    return true;
}

fn loadThemeByName(io: std.Io, allocator: std.mem.Allocator, registry: *const Registry, name: []const u8) !std.json.Parsed(std.json.Value) {
    for (registry.entries.items) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (entry.builtin) |builtin_name| {
            const bytes = builtinBytes(builtin_name) orelse return error.ThemeNotFound;
            return parseThemeJson(allocator, builtin_name, bytes);
        }
        if (entry.path) |path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_theme_bytes));
            defer allocator.free(bytes);
            return parseThemeJson(allocator, path, bytes);
        }
    }
    return error.ThemeNotFound;
}

fn themeNameFromBytes(allocator: std.mem.Allocator, label: []const u8, bytes: []const u8) ![]u8 {
    var parsed = try parseThemeJson(allocator, label, bytes);
    defer parsed.deinit();
    return allocator.dupe(u8, parsed.value.object.get("name").?.string);
}

fn parseThemeJson(allocator: std.mem.Allocator, label: []const u8, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    _ = label;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    errdefer parsed.deinit();
    try validateThemeJson(parsed.value);
    return parsed;
}

fn validateThemeJson(value: std.json.Value) !void {
    if (value != .object) return error.InvalidThemeJson;
    const name = value.object.get("name") orelse return error.InvalidThemeJson;
    if (name != .string or name.string.len == 0) return error.InvalidThemeJson;
    const colors = value.object.get("colors") orelse return error.InvalidThemeJson;
    if (colors != .object) return error.InvalidThemeJson;
    for (required_color_keys) |key| {
        const color = colors.object.get(key) orelse return error.InvalidThemeJson;
        try validateColorValue(color);
    }
    if (value.object.get("vars")) |vars| {
        if (vars != .object) return error.InvalidThemeJson;
        var it = vars.object.iterator();
        while (it.next()) |entry| try validateColorValue(entry.value_ptr.*);
    }
}

fn validateColorValue(value: std.json.Value) !void {
    switch (value) {
        .string => {},
        .integer => |int| if (int < 0 or int > 255) return error.InvalidThemeJson,
        else => return error.InvalidThemeJson,
    }
}

const ResolvedColor = union(enum) {
    string: []const u8,
    number: u8,
    empty,
};

fn resolveColorValue(allocator: std.mem.Allocator, value: std.json.Value, vars: ?std.json.ObjectMap) !ResolvedColor {
    var visited: std.ArrayList([]const u8) = .empty;
    defer visited.deinit(allocator);
    return resolveColorValueInner(allocator, value, vars, &visited);
}

fn resolveColorValueInner(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    vars: ?std.json.ObjectMap,
    visited: *std.ArrayList([]const u8),
) !ResolvedColor {
    switch (value) {
        .integer => |int| {
            if (int < 0 or int > 255) return error.InvalidThemeJson;
            return .{ .number = @intCast(int) };
        },
        .string => |text| {
            if (text.len == 0) return .empty;
            if (std.mem.startsWith(u8, text, "#")) return .{ .string = text };
            const vars_object = vars orelse return error.ThemeVariableNotFound;
            for (visited.items) |seen| {
                if (std.mem.eql(u8, seen, text)) return error.CircularThemeVariable;
            }
            const next = vars_object.get(text) orelse return error.ThemeVariableNotFound;
            try visited.append(allocator, text);
            return resolveColorValueInner(allocator, next, vars, visited);
        },
        else => return error.InvalidThemeJson,
    }
}

fn writeResolvedColorAsHexJson(allocator: std.mem.Allocator, w: *std.Io.Writer, color: ResolvedColor, default_text: []const u8) !void {
    switch (color) {
        .string => |text| try writeJsonString(w, text),
        .number => |index| {
            const hex = ansi256ToHexBuffer(index);
            try writeJsonString(w, hex[0..]);
        },
        .empty => try writeJsonString(w, default_text),
    }
    _ = allocator;
}

const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

fn hexToRgb(hex: []const u8) !Rgb {
    const cleaned = if (std.mem.startsWith(u8, hex, "#")) hex[1..] else hex;
    if (cleaned.len != 6) return error.InvalidHex;
    return .{
        .r = try std.fmt.parseInt(u8, cleaned[0..2], 16),
        .g = try std.fmt.parseInt(u8, cleaned[2..4], 16),
        .b = try std.fmt.parseInt(u8, cleaned[4..6], 16),
    };
}

fn rgbLuminance(rgb: Rgb) f64 {
    return 0.2126 * linearChannel(rgb.r) + 0.7152 * linearChannel(rgb.g) + 0.0722 * linearChannel(rgb.b);
}

fn linearChannel(channel: u8) f64 {
    const value: f64 = @as(f64, @floatFromInt(channel)) / 255.0;
    if (value <= 0.03928) return value / 12.92;
    return std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}

fn colorFgBgBackgroundIndex(colorfgbg: []const u8) ?u8 {
    var parts = std.mem.splitScalar(u8, colorfgbg, ';');
    var last: ?u8 = null;
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        const value = std.fmt.parseInt(u8, trimmed, 10) catch continue;
        last = value;
    }
    return last;
}

fn ansi256ToHexBuffer(index: u8) [7]u8 {
    const basic = [_][]const u8{
        "#000000", "#800000", "#008000", "#808000",
        "#000080", "#800080", "#008080", "#c0c0c0",
        "#808080", "#ff0000", "#00ff00", "#ffff00",
        "#0000ff", "#ff00ff", "#00ffff", "#ffffff",
    };
    if (index < 16) {
        var out: [7]u8 = undefined;
        @memcpy(&out, basic[index][0..7]);
        return out;
    }
    if (index < 232) {
        const cube = index - 16;
        const r = cube / 36;
        const g = (cube % 36) / 6;
        const b = cube % 6;
        return rgbHexBuffer(cubeChannel(r), cubeChannel(g), cubeChannel(b));
    }
    const gray: u8 = 8 + (index - 232) * 10;
    return rgbHexBuffer(gray, gray, gray);
}

fn cubeChannel(value: u8) u8 {
    return if (value == 0) 0 else 55 + value * 40;
}

fn rgbHexBuffer(r: u8, g: u8, b: u8) [7]u8 {
    const hex = "0123456789abcdef";
    var out = [_]u8{ '#', '0', '0', '0', '0', '0', '0' };
    out[1] = hex[r >> 4];
    out[2] = hex[r & 0x0f];
    out[3] = hex[g >> 4];
    out[4] = hex[g & 0x0f];
    out[5] = hex[b >> 4];
    out[6] = hex[b & 0x0f];
    return out;
}

fn builtinBytes(name: []const u8) ?[]const u8 {
    for (builtin_themes) |builtin| {
        if (std.mem.eql(u8, builtin.name, name)) return builtin.bytes;
    }
    return null;
}

// [FLOW_TUI_THEME] Public accessor for built-in theme JSON bytes. Used by
// `tui_theme.zig` to derive ANSI palette escapes from the active theme at TUI
// startup without re-embedding the JSON. Returns null when `name` is not a
// built-in (the TUI palette then falls back to the static `tui.sgr.*`
// constants), so callers don't need to allocate or read the filesystem.
pub fn builtinThemeBytes(name: []const u8) ?[]const u8 {
    return builtinBytes(name);
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

fn resolvePathWithBase(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, base_dir: []const u8, raw_path: []const u8) ![]u8 {
    const expanded = try expandMaybeTilde(allocator, env, raw_path);
    defer allocator.free(expanded);
    if (std.fs.path.isAbsolute(expanded)) return std.fs.path.resolve(allocator, &.{expanded});
    return std.fs.path.resolve(allocator, &.{ base_dir, expanded });
}

fn currentPathOwned(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

fn writeHelp(io: std.Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  pi-zig themes [--theme <path>] [--no-themes]
        \\  pi-zig themes --export <name>
        \\  pi-zig themes --resolved <name>
        \\  pi-zig themes --detect
        \\
        \\List and inspect theme resources using upstream theme JSON semantics.
        \\
        \\Options:
        \\  --theme <path>     Add a temporary theme file or directory
        \\  --no-themes        Skip user/project theme discovery
        \\  --export <name>    Print resolved HTML export colors
        \\  --resolved <name>  Print all resolved theme colors as CSS hex
        \\  --detect           Detect dark/light default from COLORFGBG
        \\
    );
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeStderr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789abcdef";
    try w.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11...12, 14...0x1f => {
                try w.writeAll("\\u00");
                try w.writeByte(hex[byte >> 4]);
                try w.writeByte(hex[byte & 0x0f]);
            },
            else => try w.writeByte(byte),
        }
    }
    try w.writeByte('"');
}

const required_color_keys = [_][]const u8{
    "accent",
    "border",
    "borderAccent",
    "borderMuted",
    "success",
    "error",
    "warning",
    "muted",
    "dim",
    "text",
    "thinkingText",
    "selectedBg",
    "userMessageBg",
    "userMessageText",
    "customMessageBg",
    "customMessageText",
    "customMessageLabel",
    "toolPendingBg",
    "toolSuccessBg",
    "toolErrorBg",
    "toolTitle",
    "toolOutput",
    "mdHeading",
    "mdLink",
    "mdLinkUrl",
    "mdCode",
    "mdCodeBlock",
    "mdCodeBlockBorder",
    "mdQuote",
    "mdQuoteBorder",
    "mdHr",
    "mdListBullet",
    "toolDiffAdded",
    "toolDiffRemoved",
    "toolDiffContext",
    "syntaxComment",
    "syntaxKeyword",
    "syntaxFunction",
    "syntaxVariable",
    "syntaxString",
    "syntaxNumber",
    "syntaxType",
    "syntaxOperator",
    "syntaxPunctuation",
    "thinkingOff",
    "thinkingMinimal",
    "thinkingLow",
    "thinkingMedium",
    "thinkingHigh",
    "thinkingXhigh",
    "bashMode",
};

test "COLORFGBG detection uses last valid background index" {
    try std.testing.expectEqual(@as(?u8, 15), colorFgBgBackgroundIndex("0;7;15"));
    try std.testing.expectEqual(@as(?u8, 0), colorFgBgBackgroundIndex("15;0"));
}

test "theme export resolves recursive vars and ansi colors" {
    const custom =
        \\{
        \\  "name": "custom",
        \\  "vars": {
        \\    "deepPageBg": "#abcdef",
        \\    "pageBgAlias": "deepPageBg",
        \\    "cardBgAnsi": 24
        \\  },
        \\  "colors": {
        \\    "accent": "#ffffff",
        \\    "border": "#ffffff",
        \\    "borderAccent": "#ffffff",
        \\    "borderMuted": "#ffffff",
        \\    "success": "#ffffff",
        \\    "error": "#ffffff",
        \\    "warning": "#ffffff",
        \\    "muted": "#ffffff",
        \\    "dim": "#ffffff",
        \\    "text": "#ffffff",
        \\    "thinkingText": "#ffffff",
        \\    "selectedBg": "#ffffff",
        \\    "userMessageBg": "#ffffff",
        \\    "userMessageText": "#ffffff",
        \\    "customMessageBg": "#ffffff",
        \\    "customMessageText": "#ffffff",
        \\    "customMessageLabel": "#ffffff",
        \\    "toolPendingBg": "#ffffff",
        \\    "toolSuccessBg": "#ffffff",
        \\    "toolErrorBg": "#ffffff",
        \\    "toolTitle": "#ffffff",
        \\    "toolOutput": "#ffffff",
        \\    "mdHeading": "#ffffff",
        \\    "mdLink": "#ffffff",
        \\    "mdLinkUrl": "#ffffff",
        \\    "mdCode": "#ffffff",
        \\    "mdCodeBlock": "#ffffff",
        \\    "mdCodeBlockBorder": "#ffffff",
        \\    "mdQuote": "#ffffff",
        \\    "mdQuoteBorder": "#ffffff",
        \\    "mdHr": "#ffffff",
        \\    "mdListBullet": "#ffffff",
        \\    "toolDiffAdded": "#ffffff",
        \\    "toolDiffRemoved": "#ffffff",
        \\    "toolDiffContext": "#ffffff",
        \\    "syntaxComment": "#ffffff",
        \\    "syntaxKeyword": "#ffffff",
        \\    "syntaxFunction": "#ffffff",
        \\    "syntaxVariable": "#ffffff",
        \\    "syntaxString": "#ffffff",
        \\    "syntaxNumber": "#ffffff",
        \\    "syntaxType": "#ffffff",
        \\    "syntaxOperator": "#ffffff",
        \\    "syntaxPunctuation": "#ffffff",
        \\    "thinkingOff": "#ffffff",
        \\    "thinkingMinimal": "#ffffff",
        \\    "thinkingLow": "#ffffff",
        \\    "thinkingMedium": "#ffffff",
        \\    "thinkingHigh": "#ffffff",
        \\    "thinkingXhigh": "#ffffff",
        \\    "bashMode": "#ffffff"
        \\  },
        \\  "export": {
        \\    "pageBg": "pageBgAlias",
        \\    "cardBg": "cardBgAnsi",
        \\    "infoBg": ""
        \\  }
        \\}
    ;
    var parsed = try parseThemeJson(std.testing.allocator, "custom", custom);
    defer parsed.deinit();
    const vars = parsed.value.object.get("vars").?.object;
    const export_object = parsed.value.object.get("export").?.object;
    try std.testing.expectEqualStrings("#abcdef", (try resolveColorValue(std.testing.allocator, export_object.get("pageBg").?, vars)).string);
    try std.testing.expectEqual(@as(u8, 24), (try resolveColorValue(std.testing.allocator, export_object.get("cardBg").?, vars)).number);
    try std.testing.expectEqual(ResolvedColor.empty, try resolveColorValue(std.testing.allocator, export_object.get("infoBg").?, vars));
}

// Build a minimal valid theme JSON (all required colors present) for tests.
fn writeMinimalThemeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, name: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"name\":\"{s}\",\"colors\":{{", .{name});
    for (required_color_keys, 0..) |key, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.print("\"{s}\":\"#000000\"", .{key});
    }
    try out.writer.writeAll("}}");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

fn themeSourceInRegistry(registry: *const Registry, name: []const u8) ?[]const u8 {
    for (registry.entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.source;
    }
    return null;
}

test "buildRegistry keeps built-in dark/light non-overridable and lists them" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const theme_dir = "zig-out/pi-zig-theme-precedence";
    std.Io.Dir.cwd().deleteTree(io, theme_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, theme_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, theme_dir);

    // A custom theme that tries to shadow the built-in "dark" must lose, and a
    // uniquely-named custom theme must be discovered.
    try writeMinimalThemeFile(io, allocator, theme_dir ++ "/dark.json", "dark");
    try writeMinimalThemeFile(io, allocator, theme_dir ++ "/ocean.json", "ocean");

    // Isolate user/agent theme discovery to an empty temp dir.
    const agent_dir = "zig-out/pi-zig-theme-precedence-agent";
    std.Io.Dir.cwd().deleteTree(io, agent_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, agent_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PI_CODING_AGENT_DIR", agent_dir);

    var options = Options{};
    options.addPath(theme_dir);

    var registry = try buildRegistry(io, allocator, &env, options);
    defer registry.deinit();

    // Built-in "dark" wins over the custom dark.json (upstream resolves
    // built-ins first); "light" built-in is present; the unique custom theme
    // is discovered as a temporary source.
    try std.testing.expectEqualStrings("builtin", themeSourceInRegistry(&registry, "dark").?);
    try std.testing.expectEqualStrings("builtin", themeSourceInRegistry(&registry, "light").?);
    try std.testing.expectEqualStrings("temporary", themeSourceInRegistry(&registry, "ocean").?);

    // The custom dark.json that lost to the built-in must surface a collision
    // diagnostic naming the shadowed theme; the built-in winner is unchanged.
    const collision = collisionDiagnosticForName(&registry, "dark") orelse return error.MissingCollisionDiagnostic;
    try std.testing.expectEqualStrings("collision", collision.severity);
    try std.testing.expectEqualStrings("name \"dark\" collision", collision.message);
    try std.testing.expect(collision.collision != null);
    try std.testing.expectEqualStrings("theme", collision.collision.?.resource_type);
    try std.testing.expectEqualStrings("dark", collision.collision.?.name);
    // pi-zig built-in themes carry their upstream source path (unlike upstream,
    // whose built-ins have sourcePath === undefined -> "<builtin>"), so the
    // winner path here is that embedded built-in path. The loser is the
    // discovered custom file under the temp theme dir.
    try std.testing.expect(std.mem.indexOf(u8, collision.collision.?.winner_path, "theme/dark.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, collision.collision.?.loser_path, theme_dir) != null);
}

fn collisionDiagnosticForName(registry: *const Registry, name: []const u8) ?Diagnostic {
    for (registry.diagnostics.items) |diagnostic| {
        const collision = diagnostic.collision orelse continue;
        if (std.mem.eql(u8, collision.name, name)) return diagnostic;
    }
    return null;
}

test "theme dedup emits a collision diagnostic for two same-named custom themes and keeps the first" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const dir_a = "zig-out/pi-zig-theme-collision-a";
    const dir_b = "zig-out/pi-zig-theme-collision-b";
    for ([_][]const u8{ dir_a, dir_b }) |dir| {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir_a) catch {};
        std.Io.Dir.cwd().deleteTree(io, dir_b) catch {};
    }

    // Two custom themes that both declare the name "twin".
    try writeMinimalThemeFile(io, allocator, dir_a ++ "/twin.json", "twin");
    try writeMinimalThemeFile(io, allocator, dir_b ++ "/twin.json", "twin");

    const agent_dir = "zig-out/pi-zig-theme-collision-agent";
    std.Io.Dir.cwd().deleteTree(io, agent_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, agent_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PI_CODING_AGENT_DIR", agent_dir);

    // dir_a is added first, so its "twin" wins; dir_b is the loser.
    var options = Options{};
    options.addPath(dir_a);
    options.addPath(dir_b);

    var registry = try buildRegistry(io, allocator, &env, options);
    defer registry.deinit();

    // Winner unchanged: exactly one "twin" entry, sourced from dir_a.
    var twin_count: usize = 0;
    var winner_path: []const u8 = "";
    for (registry.entries.items) |entry| {
        if (!std.mem.eql(u8, entry.name, "twin")) continue;
        twin_count += 1;
        if (entry.path) |p| winner_path = p;
    }
    try std.testing.expectEqual(@as(usize, 1), twin_count);
    try std.testing.expect(std.mem.indexOf(u8, winner_path, dir_a) != null);

    const collision = collisionDiagnosticForName(&registry, "twin") orelse return error.MissingCollisionDiagnostic;
    try std.testing.expectEqualStrings("name \"twin\" collision", collision.message);
    try std.testing.expect(collision.collision != null);
    try std.testing.expectEqualStrings("theme", collision.collision.?.resource_type);
    try std.testing.expect(std.mem.indexOf(u8, collision.collision.?.winner_path, dir_a) != null);
    try std.testing.expect(std.mem.indexOf(u8, collision.collision.?.loser_path, dir_b) != null);
}

test "buildRegistry re-discovers a theme added between calls (reload round-trip)" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const theme_dir = "zig-out/pi-zig-theme-reload";
    std.Io.Dir.cwd().deleteTree(io, theme_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, theme_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, theme_dir);

    const agent_dir = "zig-out/pi-zig-theme-reload-agent";
    std.Io.Dir.cwd().deleteTree(io, agent_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, agent_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PI_CODING_AGENT_DIR", agent_dir);

    var options = Options{};
    options.addPath(theme_dir);

    {
        var registry = try buildRegistry(io, allocator, &env, options);
        defer registry.deinit();
        try std.testing.expect(themeSourceInRegistry(&registry, "sunrise") == null);
    }

    try writeMinimalThemeFile(io, allocator, theme_dir ++ "/sunrise.json", "sunrise");

    {
        var registry = try buildRegistry(io, allocator, &env, options);
        defer registry.deinit();
        try std.testing.expectEqualStrings("temporary", themeSourceInRegistry(&registry, "sunrise").?);
    }
}

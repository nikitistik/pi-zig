const std = @import("std");
const extension_runner = @import("extension_runner.zig");

const legacy_project_prompts_dir = ".pi/agent/prompts";
const legacy_project_skills_dir = ".pi/agent/skills";
const project_prompts_dir = ".pi/prompts";
const project_skills_dir = ".pi/skills";
const project_settings_file = ".pi/settings.json";
const max_resource_bytes = 256 * 1024;

pub const Options = struct {
    home: ?[]const u8 = null,
    additional_skill_paths: []const []const u8 = &.{},
    additional_prompt_paths: []const []const u8 = &.{},
    extension_paths: []const []const u8 = &.{},
    no_skills: bool = false,
    no_prompt_templates: bool = false,
};

pub fn writeCommandsJson(io: std.Io, allocator: std.mem.Allocator) !void {
    return writeCommandsJsonWithOptions(io, allocator, .{});
}

pub fn writeCommandsJsonWithOptions(io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try writeCommandsDataJsonWithOptions(io, allocator, w, options);
    try w.writeByte('\n');
    try w.flush();
}

pub fn writeCommandsDataJson(io: std.Io, allocator: std.mem.Allocator, w: *std.Io.Writer) !void {
    return writeCommandsDataJsonWithOptions(io, allocator, w, .{});
}

pub fn writeCommandsDataJsonWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    options: Options,
) !void {
    // Build the raw, precedence-ordered command list, then dedup by name
    // (first-wins) so the emitted list matches upstream's resolved+deduped
    // getPrompts()/getSkills() output. The raw pass already emits in upstream
    // precedence order, so the first entry per name is the highest-precedence
    // resource (project over user, settings over auto, top-level over package).
    // Wrap the comma-joined entries in brackets so the whole list parses as a
    // single JSON array value.
    var raw: std.Io.Writer.Allocating = .init(allocator);
    defer raw.deinit();
    try raw.writer.writeByte('[');
    try emitCommandsArrayBody(io, allocator, &raw.writer, options);
    try raw.writer.writeByte(']');

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw.written(), .{}) catch {
        // Defensive fallback: if anything failed to parse, emit the raw body
        // verbatim rather than dropping commands.
        try w.writeAll("{\"commands\":");
        try w.writeAll(raw.written());
        try w.writeAll("}");
        return;
    };
    defer parsed.deinit();

    try w.writeAll("{\"commands\":[");
    // Buffer collision diagnostics produced during dedup so we can emit them in
    // a sibling `diagnostics` array after the deduped command list. Mirrors
    // upstream resource-loader dedupePrompts/dedupeSkills, which return both the
    // first-wins resource list and a `collision` diagnostic per shadowed
    // duplicate. The winner (first occurrence) is never changed.
    var collisions: std.Io.Writer.Allocating = .init(allocator);
    defer collisions.deinit();
    var collision_count: usize = 0;

    if (parsed.value == .array) {
        // Map each seen name to its winning entry so loser diagnostics can
        // reference the winner's path (upstream `existing.filePath`).
        var seen = std.StringHashMap(std.json.Value).init(allocator);
        defer seen.deinit();
        var written: usize = 0;
        for (parsed.value.array.items) |entry| {
            const name = objectString(entry, "name") orelse continue;
            if (seen.get(name)) |winner| {
                if (collision_count != 0) try collisions.writer.writeByte(',');
                try writeCollisionDiagnostic(&collisions.writer, name, winner, entry);
                collision_count += 1;
                continue;
            }
            try seen.put(name, entry);
            if (written != 0) try w.writeByte(',');
            try std.json.Stringify.value(entry, .{}, w);
            written += 1;
        }
    }
    try w.writeAll("],\"diagnostics\":[");
    try w.writeAll(collisions.written());
    try w.writeAll("]}");
}

/// Emit one upstream-shaped `collision` diagnostic for a shadowed duplicate
/// command. Matches resource-loader.ts dedupePrompts (prompts) and skills.ts
/// (skills): the message is `name "/<name>" collision` for prompts and
/// `name "<name>" collision` for skills, and the embedded collision object
/// carries resourceType/name/winnerPath/loserPath. `path` is the loser's path,
/// exactly as upstream sets `path: prompt.filePath` / `path: skill.filePath`.
fn writeCollisionDiagnostic(
    w: *std.Io.Writer,
    command_name: []const u8,
    winner: std.json.Value,
    loser: std.json.Value,
) !void {
    const source = objectString(loser, "source") orelse "";
    const is_skill = std.mem.eql(u8, source, "skill");
    const resource_type: []const u8 = if (is_skill) "skill" else "prompt";
    // Upstream prompt names carry no prefix; skill command names are stored as
    // `skill:<name>` here but upstream's skill.name is the bare name.
    const resource_name = if (is_skill and std.mem.startsWith(u8, command_name, "skill:"))
        command_name["skill:".len..]
    else
        command_name;
    const winner_path = sourceInfoPath(winner) orelse "";
    const loser_path = sourceInfoPath(loser) orelse "";

    try w.writeAll("{\"type\":\"collision\",\"message\":");
    if (is_skill) {
        try w.writeAll("\"name \\\"");
        try writeJsonStringContents(w, resource_name);
        try w.writeAll("\\\" collision\"");
    } else {
        try w.writeAll("\"name \\\"/");
        try writeJsonStringContents(w, resource_name);
        try w.writeAll("\\\" collision\"");
    }
    try w.writeAll(",\"path\":");
    try writeJsonString(w, loser_path);
    try w.writeAll(",\"collision\":{\"resourceType\":");
    try writeJsonString(w, resource_type);
    try w.writeAll(",\"name\":");
    try writeJsonString(w, resource_name);
    try w.writeAll(",\"winnerPath\":");
    try writeJsonString(w, winner_path);
    try w.writeAll(",\"loserPath\":");
    try writeJsonString(w, loser_path);
    try w.writeAll("}}");
}

fn sourceInfoPath(entry: std.json.Value) ?[]const u8 {
    if (entry != .object) return null;
    const source_info = entry.object.get("sourceInfo") orelse return null;
    return objectString(source_info, "path");
}

/// Emit the comma-joined command objects (without the surrounding
/// `{"commands":[ ]}`) in upstream precedence order.
///
/// Emission order mirrors upstream's resource precedence (package-manager.ts
/// resourcePrecedenceRank): project settings (rank 0) -> project auto-discovered
/// (rank 1) -> user settings (rank 2) -> user auto (rank 3) -> packages (rank 4).
/// expandSlashResourceCommand resolves to the first matching name, so this order
/// makes a project resource win over a same-named user resource exactly as
/// upstream does. Temporary (--prompt/--skill) paths are emitted last, matching
/// upstream's additionalSkillPaths/additionalPromptTemplatePaths being appended
/// last.
fn emitCommandsArrayBody(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    options: Options,
) !void {
    var emitted: usize = 0;

    try writeExtensionCommands(io, allocator, w, &emitted, options.extension_paths);

    if (!options.no_prompt_templates) {
        try writeProjectSettingsPromptCommands(io, allocator, w, &emitted, options.home);
        try writeProjectAutoPromptCommands(io, allocator, w, &emitted);
        try writeUserSettingsPromptCommands(io, allocator, w, &emitted, options.home);
        try writeUserAutoPromptCommands(io, allocator, w, &emitted, options.home);
        try writePackagePromptCommands(io, allocator, w, &emitted, options.home);
    }
    try writePromptCommandsForPaths(io, allocator, w, &emitted, options.additional_prompt_paths, "temporary");

    if (!options.no_skills) {
        try writeProjectSettingsSkillCommands(io, allocator, w, &emitted, options.home);
        try writeProjectAutoSkillCommands(io, allocator, w, &emitted, options.home);
        try writeUserSettingsSkillCommands(io, allocator, w, &emitted, options.home);
        try writeUserAutoSkillCommands(io, allocator, w, &emitted, options.home);
        try writePackageSkillCommands(io, allocator, w, &emitted, options.home);
    }
    try writeSkillCommandsForPaths(io, allocator, w, &emitted, options.additional_skill_paths, "temporary", true);
}

/// On-demand reload entrypoint for prompts/skills (and, via the extension
/// runner, extension commands). Re-discovers every resource directory from
/// disk on each call and returns the freshly-built commands JSON (caller owns
/// the returned slice).
///
/// This is the function the TUI/RPC `/reload` path calls to mirror upstream's
/// `resourceLoader.reload()` ("Reload keybindings, extensions, skills, prompts,
/// and themes"). Discovery here is stateless — there is no in-memory cache to
/// invalidate — so re-invoking it picks up files added/removed since the last
/// call. Themes/context-files are reloaded by their own discover() entrypoints
/// (themes.zig / context_files.zig) on the same on-demand basis.
///
/// Divergence from upstream: upstream keeps a live `fs.watch` on theme files to
/// hot-reload the active theme, and caches resources between `/reload`s. pi-zig
/// has no long-lived resource cache and no fs-watch daemon; instead every list
/// (`get_commands`, `themes`, `context-files`) re-reads disk, which is a strict
/// superset of upstream's reload guarantee (always fresh, never stale).
pub fn reloadCommandsJson(io: std.Io, allocator: std.mem.Allocator, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeCommandsDataJsonWithOptions(io, allocator, &out.writer, options);
    return out.toOwnedSlice();
}

pub fn expandSlashResourceCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
) !?[]u8 {
    const invocation = parseSlashInvocation(text) orelse return null;
    var commands_out: std.Io.Writer.Allocating = .init(allocator);
    defer commands_out.deinit();
    var resource_options = options;
    resource_options.extension_paths = &.{};
    try writeCommandsDataJsonWithOptions(io, allocator, &commands_out.writer, resource_options);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, commands_out.written(), .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const command_entries = parsed.value.object.get("commands") orelse return null;
    if (command_entries != .array) return null;

    for (command_entries.array.items) |entry| {
        if (entry != .object) continue;
        const name = objectString(entry, "name") orelse continue;
        if (!std.mem.eql(u8, name, invocation.name)) continue;
        const source = objectString(entry, "source") orelse continue;
        const source_info = entry.object.get("sourceInfo") orelse return null;
        const path = objectString(source_info, "path") orelse return null;
        if (std.mem.eql(u8, source, "prompt")) {
            return try expandPromptTemplateFile(io, allocator, path, invocation.args);
        }
        if (std.mem.eql(u8, source, "skill")) {
            const base_dir = objectString(source_info, "baseDir") orelse std.fs.path.dirname(path) orelse ".";
            return try expandSkillFile(io, allocator, path, base_dir, invocation.name, invocation.args);
        }
        return null;
    }
    return null;
}

fn writeExtensionCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    extension_paths: []const []const u8,
) !void {
    if (extension_paths.len == 0) return;
    var runner = extension_runner.Runner{ .io = io, .allocator = allocator, .extension_paths = extension_paths };
    const definitions = try runner.discoverCommandDefinitions();
    defer if (definitions.len > 0) runner.deinitCommandDefinitions(definitions);
    for (definitions) |definition| {
        if (emitted.* != 0) try w.writeByte(',');
        try writeCommandHead(w, definition.name, definition.description, "extension");
        try w.writeAll(definition.source_info_json);
        try w.writeByte('}');
        emitted.* += 1;
    }
}

// --- Prompt command scopes, in upstream precedence order (rank 0..4). ---

/// rank 0: project settings-file prompt entries (source "local", non-package).
fn writeProjectSettingsPromptCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    home: ?[]const u8,
) !void {
    try writePromptCommandsFromSettings(io, allocator, w, emitted, project_settings_file, ".pi", "project", home);
}

/// rank 1: project auto-discovered prompt directories.
fn writeProjectAutoPromptCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
) !void {
    try writePromptCommandsFromPath(io, allocator, w, emitted, project_prompts_dir, "project");
    try writePromptCommandsFromPath(io, allocator, w, emitted, legacy_project_prompts_dir, "project");
}

/// rank 2: user settings-file prompt entries.
fn writeUserSettingsPromptCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    home: ?[]const u8,
) !void {
    const home_dir = home orelse return;
    const global_agent_dir = try std.fs.path.join(allocator, &.{ home_dir, ".pi", "agent" });
    defer allocator.free(global_agent_dir);
    const global_settings = try std.fs.path.join(allocator, &.{ global_agent_dir, "settings.json" });
    defer allocator.free(global_settings);
    try writePromptCommandsFromSettings(io, allocator, w, emitted, global_settings, global_agent_dir, "user", home);
}

/// rank 3: user auto-discovered prompt directory.
fn writeUserAutoPromptCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    home: ?[]const u8,
) !void {
    const home_dir = home orelse return;
    const user_prompts = try std.fs.path.join(allocator, &.{ home_dir, ".pi", "agent", "prompts" });
    defer allocator.free(user_prompts);
    try writePromptCommandsFromPath(io, allocator, w, emitted, user_prompts, "user");
}

/// rank 4: package prompt sources (project package sources before user).
fn writePackagePromptCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    home: ?[]const u8,
) !void {
    try writePackagePromptCommandsFromSettings(io, allocator, w, emitted, project_settings_file, ".pi", "project", home);
    if (home) |home_dir| {
        const global_agent_dir = try std.fs.path.join(allocator, &.{ home_dir, ".pi", "agent" });
        defer allocator.free(global_agent_dir);
        const global_settings = try std.fs.path.join(allocator, &.{ global_agent_dir, "settings.json" });
        defer allocator.free(global_settings);
        try writePackagePromptCommandsFromSettings(io, allocator, w, emitted, global_settings, global_agent_dir, "user", home);
    }
}

// --- Skill command scopes, in upstream precedence order (rank 0..4). ---

/// rank 0: project settings-file skill entries.
fn writeProjectSettingsSkillCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    home: ?[]const u8,
) !void {
    try writeSkillCommandsFromSettings(io, allocator, w, emitted, project_settings_file, ".pi", "project", home);
}

/// rank 1: project auto-discovered skill directories (incl. ancestor .agents/skills).
fn writeProjectAutoSkillCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    home: ?[]const u8,
) !void {
    try writeSkillCommandsFromPath(io, allocator, w, emitted, project_skills_dir, "project", true);
    try writeSkillCommandsFromPath(io, allocator, w, emitted, legacy_project_skills_dir, "project", true);
    try writeAncestorAgentsSkillCommands(io, allocator, w, emitted, home);
}

/// rank 2: user settings-file skill entries.
fn writeUserSettingsSkillCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    home: ?[]const u8,
) !void {
    const home_dir = home orelse return;
    const global_agent_dir = try std.fs.path.join(allocator, &.{ home_dir, ".pi", "agent" });
    defer allocator.free(global_agent_dir);
    const global_settings = try std.fs.path.join(allocator, &.{ global_agent_dir, "settings.json" });
    defer allocator.free(global_settings);
    try writeSkillCommandsFromSettings(io, allocator, w, emitted, global_settings, global_agent_dir, "user", home);
}

/// rank 3: user auto-discovered skill directories (~/.pi/agent/skills, ~/.agents/skills).
fn writeUserAutoSkillCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    home: ?[]const u8,
) !void {
    const home_dir = home orelse return;
    const user_pi_skills = try std.fs.path.join(allocator, &.{ home_dir, ".pi", "agent", "skills" });
    defer allocator.free(user_pi_skills);
    try writeSkillCommandsFromPath(io, allocator, w, emitted, user_pi_skills, "user", true);

    const user_agents_skills = try std.fs.path.join(allocator, &.{ home_dir, ".agents", "skills" });
    defer allocator.free(user_agents_skills);
    try writeSkillCommandsFromPath(io, allocator, w, emitted, user_agents_skills, "user", false);
}

/// rank 4: package skill sources (project package sources before user).
fn writePackageSkillCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    home: ?[]const u8,
) !void {
    try writePackageSkillCommandsFromSettings(io, allocator, w, emitted, project_settings_file, ".pi", "project", home);
    if (home) |home_dir| {
        const global_agent_dir = try std.fs.path.join(allocator, &.{ home_dir, ".pi", "agent" });
        defer allocator.free(global_agent_dir);
        const global_settings = try std.fs.path.join(allocator, &.{ global_agent_dir, "settings.json" });
        defer allocator.free(global_settings);
        try writePackageSkillCommandsFromSettings(io, allocator, w, emitted, global_settings, global_agent_dir, "user", home);
    }
}

fn writePackagePromptCommandsFromSettings(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    settings_path: []const u8,
    base_dir: []const u8,
    scope: []const u8,
    home: ?[]const u8,
) !void {
    const settings_bytes = std.Io.Dir.cwd().readFileAlloc(io, settings_path, allocator, .limited(max_resource_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(settings_bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, settings_bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const packages = parsed.value.object.get("packages") orelse return;
    if (packages != .array) return;
    for (packages.array.items) |package_value| {
        try writePackagePromptCommandsFromValue(io, allocator, w, emitted, package_value, base_dir, scope, home);
    }
}

fn writePackageSkillCommandsFromSettings(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    settings_path: []const u8,
    base_dir: []const u8,
    scope: []const u8,
    home: ?[]const u8,
) !void {
    const settings_bytes = std.Io.Dir.cwd().readFileAlloc(io, settings_path, allocator, .limited(max_resource_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(settings_bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, settings_bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const enable_skill_commands = getBoolField(parsed.value.object, "enableSkillCommands") orelse true;
    if (!enable_skill_commands) return;

    const packages = parsed.value.object.get("packages") orelse return;
    if (packages != .array) return;
    for (packages.array.items) |package_value| {
        try writePackageSkillCommandsFromValue(io, allocator, w, emitted, package_value, base_dir, scope, home);
    }
}

fn writePromptCommandsFromSettings(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    settings_path: []const u8,
    base_dir: []const u8,
    scope: []const u8,
    home: ?[]const u8,
) !void {
    const settings_bytes = std.Io.Dir.cwd().readFileAlloc(io, settings_path, allocator, .limited(max_resource_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(settings_bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, settings_bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    try writePromptCommandsFromSettingsArray(io, allocator, w, emitted, parsed.value.object, "prompts", base_dir, scope, home);
    try writePromptCommandsFromSettingsArray(io, allocator, w, emitted, parsed.value.object, "promptTemplates", base_dir, scope, home);
}

fn writeSkillCommandsFromSettings(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    settings_path: []const u8,
    base_dir: []const u8,
    scope: []const u8,
    home: ?[]const u8,
) !void {
    const settings_bytes = std.Io.Dir.cwd().readFileAlloc(io, settings_path, allocator, .limited(max_resource_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(settings_bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, settings_bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const enable_skill_commands = getBoolField(parsed.value.object, "enableSkillCommands") orelse true;
    if (!enable_skill_commands) return;
    try writeSkillCommandsFromSettingsArray(io, allocator, w, emitted, parsed.value.object, "skills", base_dir, scope, home);
}

fn writePromptCommandsFromSettingsArray(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    object: std.json.ObjectMap,
    field: []const u8,
    base_dir: []const u8,
    scope: []const u8,
    home: ?[]const u8,
) !void {
    const value = object.get(field) orelse return;
    if (value != .array) return;
    for (value.array.items) |item| {
        if (item != .string) continue;
        const resolved = try resolveSettingsPath(allocator, item.string, base_dir, home);
        if (resolved) |path| {
            defer allocator.free(path);
            try writePromptCommandsFromSettingsPath(io, allocator, w, emitted, path, scope, path, base_dir, value.array.items);
        }
    }
}

fn writeSkillCommandsFromSettingsArray(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    object: std.json.ObjectMap,
    field: []const u8,
    base_dir: []const u8,
    scope: []const u8,
    home: ?[]const u8,
) !void {
    const value = object.get(field) orelse return;
    if (value != .array) return;
    for (value.array.items) |item| {
        if (item != .string) continue;
        const resolved = try resolveSettingsPath(allocator, item.string, base_dir, home);
        if (resolved) |path| {
            defer allocator.free(path);
            try writeSkillCommandsFromSettingsPath(io, allocator, w, emitted, path, scope, true, base_dir, value.array.items);
        }
    }
}

fn writePackagePromptCommandsFromValue(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    package_value: std.json.Value,
    base_dir: []const u8,
    scope: []const u8,
    home: ?[]const u8,
) !void {
    const source = packageSourceString(package_value) orelse return;
    const filter_entries = packageFilterEntries(package_value, "prompts");
    const package_root = try resolveLocalPackagePath(allocator, source, base_dir, home);
    if (package_root) |root| {
        defer allocator.free(root);
        try writePackagePromptCommandsFromRoot(io, allocator, w, emitted, root, source, scope, filter_entries);
    }
}

fn writePackageSkillCommandsFromValue(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    package_value: std.json.Value,
    base_dir: []const u8,
    scope: []const u8,
    home: ?[]const u8,
) !void {
    const source = packageSourceString(package_value) orelse return;
    const filter_entries = packageFilterEntries(package_value, "skills");
    const package_root = try resolveLocalPackagePath(allocator, source, base_dir, home);
    if (package_root) |root| {
        defer allocator.free(root);
        try writePackageSkillCommandsFromRoot(io, allocator, w, emitted, root, source, scope, filter_entries);
    }
}

fn packageSourceString(package_value: std.json.Value) ?[]const u8 {
    switch (package_value) {
        .string => |source| return source,
        .object => |object| {
            const source = object.get("source") orelse return null;
            if (source != .string) return null;
            return source.string;
        },
        else => return null,
    }
}

fn packageFilterEntries(package_value: std.json.Value, field: []const u8) ?[]const std.json.Value {
    if (package_value != .object) return null;
    const value = package_value.object.get(field) orelse return null;
    if (value != .array) return null;
    return value.array.items;
}

fn writePackagePromptCommandsFromRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    package_root: []const u8,
    source: []const u8,
    scope: []const u8,
    filter_entries: ?[]const std.json.Value,
) !void {
    if (filter_entries) |entries| {
        if (entries.len == 0) return;
    }

    const stat = std.Io.Dir.cwd().statFile(io, package_root, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };
    if (stat.kind != .directory) return;

    if (try writePackagePromptCommandsFromManifest(io, allocator, w, emitted, package_root, source, scope, filter_entries)) return;

    const prompts_dir = try std.fs.path.join(allocator, &.{ package_root, "prompts" });
    defer allocator.free(prompts_dir);
    try writePackagePromptCommandsFromPath(io, allocator, w, emitted, prompts_dir, source, scope, package_root, filter_entries);
}

fn writePackageSkillCommandsFromRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    package_root: []const u8,
    source: []const u8,
    scope: []const u8,
    filter_entries: ?[]const std.json.Value,
) !void {
    if (filter_entries) |entries| {
        if (entries.len == 0) return;
    }

    const stat = std.Io.Dir.cwd().statFile(io, package_root, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };
    if (stat.kind != .directory) return;

    if (try writePackageSkillCommandsFromManifest(io, allocator, w, emitted, package_root, source, scope, filter_entries)) return;

    const skills_dir = try std.fs.path.join(allocator, &.{ package_root, "skills" });
    defer allocator.free(skills_dir);
    try writePackageSkillCommandsFromPath(io, allocator, w, emitted, skills_dir, source, scope, package_root, true, filter_entries);
}

fn writePackagePromptCommandsFromManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    package_root: []const u8,
    source: []const u8,
    scope: []const u8,
    filter_entries: ?[]const std.json.Value,
) !bool {
    const package_json = try std.fs.path.join(allocator, &.{ package_root, "package.json" });
    defer allocator.free(package_json);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, package_json, allocator, .limited(max_resource_bytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const pi_value = parsed.value.object.get("pi") orelse return false;
    if (pi_value != .object) return false;
    const prompts = pi_value.object.get("prompts") orelse return true;
    if (prompts != .array) return true;

    for (prompts.array.items) |entry| {
        if (entry != .string) continue;
        if (isSettingsPatternEntry(entry.string)) continue;
        const path = try resolvePackageManifestPath(allocator, entry.string, package_root, null);
        if (path) |resolved| {
            defer allocator.free(resolved);
            try writePackagePromptCommandsFromPath(io, allocator, w, emitted, resolved, source, scope, package_root, filter_entries);
        }
    }
    return true;
}

fn writePackageSkillCommandsFromManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    package_root: []const u8,
    source: []const u8,
    scope: []const u8,
    filter_entries: ?[]const std.json.Value,
) !bool {
    const package_json = try std.fs.path.join(allocator, &.{ package_root, "package.json" });
    defer allocator.free(package_json);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, package_json, allocator, .limited(max_resource_bytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const pi_value = parsed.value.object.get("pi") orelse return false;
    if (pi_value != .object) return false;
    const skills = pi_value.object.get("skills") orelse return true;
    if (skills != .array) return true;

    for (skills.array.items) |entry| {
        if (entry != .string) continue;
        if (isSettingsPatternEntry(entry.string)) continue;
        const path = try resolvePackageManifestPath(allocator, entry.string, package_root, null);
        if (path) |resolved| {
            defer allocator.free(resolved);
            try writePackageSkillCommandsFromPath(io, allocator, w, emitted, resolved, source, scope, package_root, true, filter_entries);
        }
    }
    return true;
}

fn writePackagePromptCommandsFromPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    path: []const u8,
    source: []const u8,
    scope: []const u8,
    package_root: []const u8,
    filter_entries: ?[]const std.json.Value,
) anyerror!void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };

    switch (stat.kind) {
        .directory => {
            var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
            defer dir.close(io);

            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (std.mem.startsWith(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "node_modules")) continue;
                const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
                defer allocator.free(child_path);
                if (entry.kind == .directory or entry.kind == .sym_link) {
                    try writePackagePromptCommandsFromPath(io, allocator, w, emitted, child_path, source, scope, package_root, filter_entries);
                    continue;
                }
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
                if (!isEnabledByPackageFilter(child_path, package_root, filter_entries, false)) continue;
                try writePackagePromptCommandFromFile(io, allocator, w, emitted, child_path, source, scope, package_root);
            }
        },
        .file, .sym_link => {
            if (!std.mem.endsWith(u8, path, ".md")) return;
            if (!isEnabledByPackageFilter(path, package_root, filter_entries, false)) return;
            try writePackagePromptCommandFromFile(io, allocator, w, emitted, path, source, scope, package_root);
        },
        else => {},
    }
}

fn writePackageSkillCommandsFromPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    path: []const u8,
    source: []const u8,
    scope: []const u8,
    package_root: []const u8,
    include_root_files: bool,
    filter_entries: ?[]const std.json.Value,
) anyerror!void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };

    switch (stat.kind) {
        .directory => {
            const root_skill = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{path});
            defer allocator.free(root_skill);
            if (std.Io.Dir.cwd().statFile(io, root_skill, .{})) |root_stat| {
                if (root_stat.kind == .file or root_stat.kind == .sym_link) {
                    if (!isEnabledByPackageFilter(root_skill, package_root, filter_entries, true)) return;
                    try writePackageSkillCommandFromFile(io, allocator, w, emitted, root_skill, source, scope, package_root);
                    return;
                }
            } else |_| {}

            var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
            defer dir.close(io);

            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind == .directory or entry.kind == .sym_link) {
                    if (std.mem.startsWith(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "node_modules")) continue;
                    const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
                    defer allocator.free(child_path);
                    try writePackageSkillCommandsFromPath(io, allocator, w, emitted, child_path, source, scope, package_root, false, filter_entries);
                    continue;
                }
                if (!include_root_files) continue;
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (!std.mem.endsWith(u8, entry.name, ".md") or std.mem.eql(u8, entry.name, "SKILL.md")) continue;
                const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
                defer allocator.free(child_path);
                if (!isEnabledByPackageFilter(child_path, package_root, filter_entries, true)) continue;
                try writePackageSkillCommandFromFile(io, allocator, w, emitted, child_path, source, scope, package_root);
            }
        },
        .file, .sym_link => {
            if (!std.mem.endsWith(u8, path, ".md")) return;
            if (!isEnabledByPackageFilter(path, package_root, filter_entries, true)) return;
            try writePackageSkillCommandFromFile(io, allocator, w, emitted, path, source, scope, package_root);
        },
        else => {},
    }
}

fn writePackagePromptCommandFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    path: []const u8,
    source: []const u8,
    scope: []const u8,
    package_root: []const u8,
) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_resource_bytes)) catch return;
    defer allocator.free(content);

    const parsed = parsePrompt(content);
    const basename = std.fs.path.basename(path);
    const name = if (std.mem.endsWith(u8, basename, ".md")) basename[0 .. basename.len - ".md".len] else basename;
    if (emitted.* != 0) try w.writeByte(',');
    try writeCommandHead(w, name, parsed.description, "prompt");
    try writeSourceInfoWithOrigin(w, path, source, scope, "package", package_root);
    try w.writeByte('}');
    emitted.* += 1;
}

fn writePackageSkillCommandFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    path: []const u8,
    source: []const u8,
    scope: []const u8,
    package_root: []const u8,
) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_resource_bytes)) catch return;
    defer allocator.free(content);

    const parsed = parseFrontmatter(content);
    const description = parsed.value("description") orelse return;
    const skill_dir = std.fs.path.dirname(path) orelse package_root;
    const fallback = std.fs.path.basename(skill_dir);
    const raw_name = parsed.value("name") orelse fallback;

    if (emitted.* != 0) try w.writeByte(',');
    try w.writeAll("{\"name\":\"skill:");
    try writeJsonStringContents(w, raw_name);
    try w.writeAll("\",\"description\":");
    try writeJsonString(w, description);
    try w.writeAll(",\"source\":\"skill\",\"sourceInfo\":");
    try writeSourceInfoWithOrigin(w, path, source, scope, "package", package_root);
    try w.writeByte('}');
    emitted.* += 1;
}

fn writePromptCommandsFromSettingsPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    path: []const u8,
    scope: []const u8,
    source_base_dir: []const u8,
    pattern_base_dir: []const u8,
    entries: []const std.json.Value,
) anyerror!void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };

    switch (stat.kind) {
        .directory => try writePromptCommandsFromSettingsDir(io, allocator, w, emitted, path, scope, source_base_dir, pattern_base_dir, entries),
        .file, .sym_link => {
            if (!std.mem.endsWith(u8, path, ".md")) return;
            if (!isEnabledBySettingsPatterns(path, pattern_base_dir, entries, false)) return;
            const base_dir = std.fs.path.dirname(path) orelse source_base_dir;
            try writePromptCommandFromFile(io, allocator, w, emitted, path, scope, base_dir);
        },
        else => {},
    }
}

fn writePromptCommandsFromSettingsDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    dir_path: []const u8,
    scope: []const u8,
    source_base_dir: []const u8,
    pattern_base_dir: []const u8,
    entries: []const std.json.Value,
) anyerror!void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "node_modules")) continue;
        const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(child_path);

        if (entry.kind == .directory or entry.kind == .sym_link) {
            try writePromptCommandsFromSettingsPath(io, allocator, w, emitted, child_path, scope, source_base_dir, pattern_base_dir, entries);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (!isEnabledBySettingsPatterns(child_path, pattern_base_dir, entries, false)) continue;
        try writePromptCommandFromFile(io, allocator, w, emitted, child_path, scope, source_base_dir);
    }
}

fn writeSkillCommandsFromSettingsPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    path: []const u8,
    scope: []const u8,
    include_root_files: bool,
    pattern_base_dir: []const u8,
    entries: []const std.json.Value,
) anyerror!void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };

    switch (stat.kind) {
        .directory => try writeSkillCommandsFromSettingsDir(io, allocator, w, emitted, path, scope, include_root_files, pattern_base_dir, entries),
        .file, .sym_link => {
            if (!std.mem.endsWith(u8, path, ".md")) return;
            if (!isEnabledBySettingsPatterns(path, pattern_base_dir, entries, true)) return;
            const base_dir = std.fs.path.dirname(path) orelse ".";
            try writeSkillCommandFromFile(io, allocator, w, emitted, path, scope, base_dir);
        },
        else => {},
    }
}

fn writeSkillCommandsFromSettingsDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    dir_path: []const u8,
    scope: []const u8,
    include_root_files: bool,
    pattern_base_dir: []const u8,
    entries: []const std.json.Value,
) anyerror!void {
    const root_skill = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{dir_path});
    defer allocator.free(root_skill);
    if (std.Io.Dir.cwd().statFile(io, root_skill, .{})) |stat| {
        if (stat.kind == .file or stat.kind == .sym_link) {
            if (isEnabledBySettingsPatterns(root_skill, pattern_base_dir, entries, true)) {
                try writeSkillCommandFromFile(io, allocator, w, emitted, root_skill, scope, dir_path);
            }
            return;
        }
    } else |_| {}

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory or entry.kind == .sym_link) {
            if (std.mem.startsWith(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "node_modules")) continue;
            const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(child_path);
            try writeSkillCommandsFromSettingsPath(io, allocator, w, emitted, child_path, scope, false, pattern_base_dir, entries);
            continue;
        }

        if (!include_root_files) continue;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md") or std.mem.eql(u8, entry.name, "SKILL.md")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(path);
        if (!isEnabledBySettingsPatterns(path, pattern_base_dir, entries, true)) continue;
        try writeSkillCommandFromFile(io, allocator, w, emitted, path, scope, dir_path);
    }
}

fn writeAncestorAgentsSkillCommands(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    home: ?[]const u8,
) !void {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch return;
    var current: []const u8 = cwd_buf[0..cwd_len];
    const git_root = findGitRepoRoot(io, current);

    while (true) {
        const agents_skills = try std.fs.path.join(allocator, &.{ current, ".agents", "skills" });
        defer allocator.free(agents_skills);
        if (!isUserAgentsSkills(home, agents_skills)) {
            try writeSkillCommandsFromPath(io, allocator, w, emitted, agents_skills, "project", false);
        }

        if (git_root) |root| {
            if (std.mem.eql(u8, current, root)) break;
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
}

fn findGitRepoRoot(io: std.Io, start_dir: []const u8) ?[]const u8 {
    var current = start_dir;
    while (true) {
        var git_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var fixed = std.Io.Writer.fixed(&git_path_buf);
        fixed.print("{s}/.git", .{current}) catch return null;
        const git_path = fixed.buffered();
        if (std.Io.Dir.cwd().statFile(io, git_path, .{})) |_| {
            return current;
        } else |_| {}

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return null;
}

fn getBoolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn resolveSettingsPath(
    allocator: std.mem.Allocator,
    raw_path: []const u8,
    base_dir: []const u8,
    home: ?[]const u8,
) !?[]u8 {
    var path = std.mem.trim(u8, raw_path, " \t\r\n");
    if (path.len == 0) return null;

    if (isSettingsPatternEntry(path)) return null;
    if (hasGlobPattern(path)) return null;

    if (std.mem.eql(u8, path, "~")) {
        const home_dir = home orelse return null;
        return try allocator.dupe(u8, home_dir);
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        const home_dir = home orelse return null;
        return try std.fs.path.join(allocator, &.{ home_dir, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) {
        return try allocator.dupe(u8, path);
    }
    return try std.fs.path.join(allocator, &.{ base_dir, path });
}

fn resolveLocalPackagePath(
    allocator: std.mem.Allocator,
    raw_source: []const u8,
    base_dir: []const u8,
    home: ?[]const u8,
) !?[]u8 {
    const source = std.mem.trim(u8, raw_source, " \t\r\n");
    if (source.len == 0 or isNonLocalPackageSource(source)) return null;
    return resolvePackageManifestPath(allocator, source, base_dir, home);
}

fn resolvePackageManifestPath(
    allocator: std.mem.Allocator,
    raw_path: []const u8,
    base_dir: []const u8,
    home: ?[]const u8,
) !?[]u8 {
    var path = std.mem.trim(u8, raw_path, " \t\r\n");
    if (path.len == 0) return null;
    if (isSettingsPatternEntry(path)) return null;
    if (hasGlobPattern(path)) return null;

    if (std.mem.eql(u8, path, "~")) {
        const home_dir = home orelse return null;
        return try allocator.dupe(u8, home_dir);
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        const home_dir = home orelse return null;
        return try std.fs.path.join(allocator, &.{ home_dir, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) {
        return try allocator.dupe(u8, path);
    }
    return try std.fs.path.join(allocator, &.{ base_dir, path });
}

fn isNonLocalPackageSource(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "npm:") or
        std.mem.startsWith(u8, source, "git:") or
        std.mem.startsWith(u8, source, "github:") or
        std.mem.startsWith(u8, source, "http:") or
        std.mem.startsWith(u8, source, "https:") or
        std.mem.startsWith(u8, source, "ssh:");
}

fn isSettingsPatternEntry(value: []const u8) bool {
    if (value.len == 0) return false;
    return value[0] == '!' or value[0] == '+' or value[0] == '-';
}

fn isEnabledBySettingsPatterns(path: []const u8, base_dir: []const u8, entries: []const std.json.Value, is_skill: bool) bool {
    return isEnabledByPatternEntries(path, base_dir, entries, is_skill, false);
}

fn isEnabledByPackageFilter(path: []const u8, package_root: []const u8, filter_entries: ?[]const std.json.Value, is_skill: bool) bool {
    const entries = filter_entries orelse return true;
    return isEnabledByPatternEntries(path, package_root, entries, is_skill, true);
}

fn isEnabledByPatternEntries(
    path: []const u8,
    base_dir: []const u8,
    entries: []const std.json.Value,
    is_skill: bool,
    plain_entries_are_includes: bool,
) bool {
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
            force_include_match = force_include_match or matchesExactSettingsPattern(path, raw[1..], base_dir, is_skill);
            continue;
        }
        if (raw[0] == '-') {
            force_exclude_match = force_exclude_match or matchesExactSettingsPattern(path, raw[1..], base_dir, is_skill);
            continue;
        }
        if (raw[0] == '!') {
            exclude_match = exclude_match or matchesSettingsPattern(path, raw[1..], base_dir, is_skill);
            continue;
        }
        if (plain_entries_are_includes or hasGlobPattern(raw)) {
            include_count += 1;
            include_match = include_match or matchesSettingsPattern(path, raw, base_dir, is_skill);
        }
    }

    var enabled = if (include_count == 0) true else include_match;
    if (exclude_match) enabled = false;
    if (force_include_match) enabled = true;
    if (force_exclude_match) enabled = false;
    return enabled;
}

fn matchesSettingsPattern(path: []const u8, raw_pattern: []const u8, base_dir: []const u8, is_skill: bool) bool {
    const pattern = normalizeSettingsPattern(raw_pattern);
    if (pattern.len == 0) return false;
    if (wildcardMatch(pattern, path)) return true;
    if (pathRelativeToBase(path, base_dir)) |relative| {
        if (wildcardMatch(pattern, relative)) return true;
    }
    if (wildcardMatch(pattern, std.fs.path.basename(path))) return true;

    if (is_skill) {
        const parent = std.fs.path.dirname(path) orelse return false;
        if (wildcardMatch(pattern, parent)) return true;
        if (pathRelativeToBase(parent, base_dir)) |relative_parent| {
            if (wildcardMatch(pattern, relative_parent)) return true;
        }
        if (wildcardMatch(pattern, std.fs.path.basename(parent))) return true;
    }
    return false;
}

fn matchesExactSettingsPattern(path: []const u8, raw_pattern: []const u8, base_dir: []const u8, is_skill: bool) bool {
    const pattern = normalizeSettingsPattern(raw_pattern);
    if (pattern.len == 0) return false;
    if (std.mem.eql(u8, pattern, path)) return true;
    if (pathRelativeToBase(path, base_dir)) |relative| {
        if (std.mem.eql(u8, pattern, relative)) return true;
    }

    if (is_skill) {
        const parent = std.fs.path.dirname(path) orelse return false;
        if (std.mem.eql(u8, pattern, parent)) return true;
        if (pathRelativeToBase(parent, base_dir)) |relative_parent| {
            if (std.mem.eql(u8, pattern, relative_parent)) return true;
        }
    }
    return false;
}

fn normalizeSettingsPattern(pattern: []const u8) []const u8 {
    var normalized = std.mem.trim(u8, pattern, " \t\r\n");
    if (std.mem.startsWith(u8, normalized, "./") or std.mem.startsWith(u8, normalized, ".\\")) {
        normalized = normalized[2..];
    }
    return normalized;
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

fn isUserAgentsSkills(home: ?[]const u8, path: []const u8) bool {
    const home_dir = home orelse return false;
    var expected_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&expected_buf);
    fixed.print("{s}/.agents/skills", .{home_dir}) catch return false;
    return std.mem.eql(u8, path, fixed.buffered());
}

fn writePromptCommandsForPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    paths: []const []const u8,
    scope: []const u8,
) !void {
    for (paths) |path| {
        try writePromptCommandsFromPath(io, allocator, w, emitted, path, scope);
    }
}

fn writeSkillCommandsForPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    paths: []const []const u8,
    scope: []const u8,
    include_root_files: bool,
) !void {
    for (paths) |path| {
        try writeSkillCommandsFromPath(io, allocator, w, emitted, path, scope, include_root_files);
    }
}

fn writePromptCommandsFromPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    path: []const u8,
    scope: []const u8,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };

    switch (stat.kind) {
        .directory => try writePromptCommandsFromDir(io, allocator, w, emitted, path, scope, path),
        .file, .sym_link => {
            if (!std.mem.endsWith(u8, path, ".md")) return;
            const base_dir = std.fs.path.dirname(path) orelse ".";
            try writePromptCommandFromFile(io, allocator, w, emitted, path, scope, base_dir);
        },
        else => {},
    }
}

fn writePromptCommandsFromDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    dir_path: []const u8,
    scope: []const u8,
    base_dir: []const u8,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(path);
        try writePromptCommandFromFile(io, allocator, w, emitted, path, scope, base_dir);
    }
}

fn writePromptCommandFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    path: []const u8,
    scope: []const u8,
    base_dir: []const u8,
) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_resource_bytes)) catch return;
    defer allocator.free(content);

    const parsed = parsePrompt(content);
    const basename = std.fs.path.basename(path);
    const name = if (std.mem.endsWith(u8, basename, ".md")) basename[0 .. basename.len - ".md".len] else basename;
    if (emitted.* != 0) try w.writeByte(',');
    try writeCommandHead(w, name, parsed.description, "prompt");
    try writeSourceInfo(w, path, scope, base_dir);
    try w.writeByte('}');
    emitted.* += 1;
}

fn writeSkillCommandsFromPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    path: []const u8,
    scope: []const u8,
    include_root_files: bool,
) anyerror!void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };

    switch (stat.kind) {
        .directory => try writeSkillCommandsFromDir(io, allocator, w, emitted, path, scope, include_root_files),
        .file, .sym_link => {
            if (!std.mem.endsWith(u8, path, ".md")) return;
            const base_dir = std.fs.path.dirname(path) orelse ".";
            try writeSkillCommandFromFile(io, allocator, w, emitted, path, scope, base_dir);
        },
        else => {},
    }
}

fn writeSkillCommandsFromDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    dir_path: []const u8,
    scope: []const u8,
    include_root_files: bool,
) anyerror!void {
    const root_skill = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{dir_path});
    defer allocator.free(root_skill);
    if (std.Io.Dir.cwd().statFile(io, root_skill, .{})) |stat| {
        if (stat.kind == .file or stat.kind == .sym_link) {
            try writeSkillCommandFromFile(io, allocator, w, emitted, root_skill, scope, dir_path);
            return;
        }
    } else |_| {}

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory or entry.kind == .sym_link) {
            if (std.mem.startsWith(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "node_modules")) continue;
            const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(child_path);
            try writeSkillCommandsFromPath(io, allocator, w, emitted, child_path, scope, false);
            continue;
        }

        if (!include_root_files) continue;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md") or std.mem.eql(u8, entry.name, "SKILL.md")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(path);
        try writeSkillCommandFromFile(io, allocator, w, emitted, path, scope, dir_path);
    }
}

fn writeSkillCommandFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    emitted: *usize,
    path: []const u8,
    scope: []const u8,
    base_dir: []const u8,
) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_resource_bytes)) catch return;
    defer allocator.free(content);

    const parsed = parseFrontmatter(content);
    const description = parsed.value("description") orelse return;
    const skill_dir = std.fs.path.dirname(path) orelse base_dir;
    const fallback = std.fs.path.basename(skill_dir);
    const raw_name = parsed.value("name") orelse fallback;

    if (emitted.* != 0) try w.writeByte(',');
    try w.writeAll("{\"name\":\"skill:");
    try writeJsonStringContents(w, raw_name);
    try w.writeAll("\",\"description\":");
    try writeJsonString(w, description);
    try w.writeAll(",\"source\":\"skill\",\"sourceInfo\":");
    try writeSourceInfo(w, path, scope, skill_dir);
    try w.writeByte('}');
    emitted.* += 1;
}

const PromptParts = struct {
    description: []const u8,
};

fn parsePrompt(content: []const u8) PromptParts {
    const parsed = parseFrontmatter(content);
    if (parsed.value("description")) |description| return .{ .description = description };

    var lines = std.mem.splitScalar(u8, parsed.body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, stripTrailingCarriageReturn(raw_line), " \t");
        if (line.len == 0) continue;
        return .{ .description = line[0..@min(line.len, 60)] };
    }
    return .{ .description = "" };
}

const Frontmatter = struct {
    header: []const u8,
    body: []const u8,

    fn value(self: Frontmatter, key: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, self.header, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, stripTrailingCarriageReturn(raw_line), " \t");
            if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const found_key = std.mem.trim(u8, line[0..colon], " \t");
            if (!std.mem.eql(u8, found_key, key)) continue;
            var value_text = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (value_text.len >= 2) {
                const first = value_text[0];
                const last = value_text[value_text.len - 1];
                if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
                    value_text = value_text[1 .. value_text.len - 1];
                }
            }
            return value_text;
        }
        return null;
    }
};

fn parseFrontmatter(content: []const u8) Frontmatter {
    if (std.mem.startsWith(u8, content, "---\n")) {
        if (std.mem.indexOf(u8, content[4..], "\n---")) |relative_end| {
            const end = 4 + relative_end;
            var body_start = end + "\n---".len;
            if (body_start < content.len and content[body_start] == '\r') body_start += 1;
            if (body_start < content.len and content[body_start] == '\n') body_start += 1;
            return .{ .header = content[4..end], .body = content[body_start..] };
        }
    }
    return .{ .header = "", .body = content };
}

const SlashInvocation = struct {
    name: []const u8,
    args: []const u8,
};

fn parseSlashInvocation(text: []const u8) ?SlashInvocation {
    if (text.len < 2 or text[0] != '/') return null;
    const rest = text[1..];
    var index: usize = 0;
    while (index < rest.len and !isAsciiWhitespace(rest[index])) index += 1;
    const name = rest[0..index];
    if (name.len == 0) return null;
    while (index < rest.len and isAsciiWhitespace(rest[index])) index += 1;
    const args = rest[index..];
    return .{ .name = name, .args = args };
}

fn isAsciiWhitespace(char: u8) bool {
    return switch (char) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

fn objectString(value: std.json.Value, field_name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(field_name) orelse return null;
    return if (field == .string) field.string else null;
}

fn expandPromptTemplateFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    args_text: []const u8,
) ![]u8 {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_resource_bytes));
    defer allocator.free(content);
    const frontmatter = parseFrontmatter(content);
    const args = try parseTemplateArgs(allocator, args_text);
    defer freeStringList(allocator, args);
    return substituteTemplateArgs(allocator, frontmatter.body, args);
}

fn expandSkillFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    base_dir: []const u8,
    command_name: []const u8,
    args_text: []const u8,
) ![]u8 {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_resource_bytes));
    defer allocator.free(content);
    const frontmatter = parseFrontmatter(content);
    const skill_name = if (std.mem.startsWith(u8, command_name, "skill:")) command_name["skill:".len..] else command_name;
    const body = std.mem.trim(u8, frontmatter.body, " \t\r\n");
    // Upstream _expandSkillCommand trims the args (text.slice(spaceIndex+1).trim())
    // before appending, so trailing whitespace after the skill name is dropped.
    const args = std.mem.trim(u8, args_text, " \t\r\n");
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("<skill name=\"{s}\" location=\"{s}\">\nReferences are relative to {s}.\n\n{s}\n</skill>", .{
        skill_name,
        path,
        base_dir,
        body,
    });
    if (args.len > 0) try out.writer.print("\n\n{s}", .{args});
    return out.toOwnedSlice();
}

/// Parse command arguments respecting quoted strings (bash-style).
/// Mirrors upstream parseCommandArgs (prompt-templates.ts) exactly:
/// - single/double quotes toggle quoting; the quote characters are stripped
/// - whitespace (JS `\s` ASCII subset) splits args only when the current token
///   is non-empty, so empty quotes (e.g. `''`) yield no argument
/// - backslashes are NOT escape characters; they are literal token bytes
fn parseTemplateArgs(allocator: std.mem.Allocator, args_text: []const u8) ![][]u8 {
    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |value| allocator.free(value);
        args.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var quote: ?u8 = null;
    for (args_text) |char| {
        if (quote) |quote_char| {
            if (char == quote_char) {
                quote = null;
            } else {
                try current.append(allocator, char);
            }
        } else if (char == '"' or char == '\'') {
            quote = char;
        } else if (std.ascii.isWhitespace(char)) {
            if (current.items.len > 0) {
                try appendTemplateArg(allocator, &args, current.items);
                current.clearRetainingCapacity();
            }
        } else {
            try current.append(allocator, char);
        }
    }
    if (current.items.len > 0) {
        try appendTemplateArg(allocator, &args, current.items);
        current.clearRetainingCapacity();
    }
    return args.toOwnedSlice(allocator);
}

fn appendTemplateArg(allocator: std.mem.Allocator, args: *std.ArrayList([]u8), value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try args.append(allocator, owned);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    if (values.len > 0) allocator.free(values);
}

/// Substitute argument placeholders in template content.
/// Mirrors upstream substituteArgs (prompt-templates.ts):
/// - $1, $2, ... positional args (1-indexed; out-of-range yields "")
/// - ${@:start} / ${@:start:length} bash-style slices (1-indexed; 0 treated as 1)
/// - $ARGUMENTS and $@ expand to all parsed args joined by a single space
///
/// Upstream joins the PARSED args (`args.join(" ")`), so quote characters are
/// dropped and internal whitespace runs collapse to single spaces — it never
/// re-emits the raw invocation text. Substitution runs once over the template
/// only; inserted argument values are not re-scanned for placeholders.
fn substituteTemplateArgs(
    allocator: std.mem.Allocator,
    content: []const u8,
    args: []const []u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < content.len) {
        if (content[index] != '$') {
            try out.writer.writeByte(content[index]);
            index += 1;
            continue;
        }
        if (index + "$ARGUMENTS".len <= content.len and std.mem.eql(u8, content[index .. index + "$ARGUMENTS".len], "$ARGUMENTS")) {
            try appendJoinedArgs(&out.writer, args, 0, std.math.maxInt(usize));
            index += "$ARGUMENTS".len;
            continue;
        }
        if (index + 2 <= content.len and content[index + 1] == '@') {
            try appendJoinedArgs(&out.writer, args, 0, std.math.maxInt(usize));
            index += 2;
            continue;
        }
        if (parseSlicePlaceholder(content[index..])) |placeholder| {
            try appendJoinedArgs(&out.writer, args, placeholder.start, placeholder.end);
            index += placeholder.len;
            continue;
        }
        if (index + 1 < content.len and std.ascii.isDigit(content[index + 1])) {
            var end = index + 1;
            while (end < content.len and std.ascii.isDigit(content[end])) end += 1;
            const raw_number = std.fmt.parseUnsigned(usize, content[index + 1 .. end], 10) catch 0;
            if (raw_number > 0 and raw_number <= args.len) try out.writer.writeAll(args[raw_number - 1]);
            index = end;
            continue;
        }
        try out.writer.writeByte(content[index]);
        index += 1;
    }
    return out.toOwnedSlice();
}

const SlicePlaceholder = struct {
    start: usize,
    end: usize,
    len: usize,
};

fn parseSlicePlaceholder(text: []const u8) ?SlicePlaceholder {
    if (!std.mem.startsWith(u8, text, "${@:")) return null;
    var index: usize = "${@:".len;
    const start_begin = index;
    while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
    if (index == start_begin) return null;
    const raw_start = std.fmt.parseUnsigned(usize, text[start_begin..index], 10) catch return null;
    var length: ?usize = null;
    if (index < text.len and text[index] == ':') {
        index += 1;
        const length_begin = index;
        while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
        if (index == length_begin) return null;
        length = std.fmt.parseUnsigned(usize, text[length_begin..index], 10) catch return null;
    }
    if (index >= text.len or text[index] != '}') return null;
    const start = if (raw_start == 0) 0 else raw_start - 1;
    const end = if (length) |value| std.math.add(usize, start, value) catch std.math.maxInt(usize) else std.math.maxInt(usize);
    return .{
        .start = start,
        .end = end,
        .len = index + 1,
    };
}

fn appendJoinedArgs(w: *std.Io.Writer, args: []const []u8, start: usize, raw_end: usize) !void {
    if (start >= args.len) return;
    const end = @min(raw_end, args.len);
    for (args[start..end], 0..) |arg, index| {
        if (index != 0) try w.writeByte(' ');
        try w.writeAll(arg);
    }
}

fn writeCommandHead(w: *std.Io.Writer, name: []const u8, description: []const u8, source: []const u8) !void {
    try w.writeAll("{\"name\":");
    try writeJsonString(w, name);
    try w.writeAll(",\"description\":");
    try writeJsonString(w, description);
    try w.writeAll(",\"source\":");
    try writeJsonString(w, source);
    try w.writeAll(",\"sourceInfo\":");
}

fn writeSourceInfo(w: *std.Io.Writer, path: []const u8, scope: []const u8, base_dir: []const u8) !void {
    return writeSourceInfoWithOrigin(w, path, "local", scope, "top-level", base_dir);
}

fn writeSourceInfoWithOrigin(
    w: *std.Io.Writer,
    path: []const u8,
    source: []const u8,
    scope: []const u8,
    origin: []const u8,
    base_dir: []const u8,
) !void {
    try w.writeAll("{\"path\":");
    try writeJsonString(w, path);
    try w.writeAll(",\"source\":");
    try writeJsonString(w, source);
    try w.writeAll(",\"scope\":");
    try writeJsonString(w, scope);
    try w.writeAll(",\"origin\":");
    try writeJsonString(w, origin);
    try w.writeAll(",\"baseDir\":");
    try writeJsonString(w, base_dir);
    try w.writeByte('}');
}

fn stripTrailingCarriageReturn(value: []const u8) []const u8 {
    if (value.len > 0 and value[value.len - 1] == '\r') return value[0 .. value.len - 1];
    return value;
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    try writeJsonStringContents(w, value);
    try w.writeByte('"');
}

fn writeJsonStringContents(w: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789abcdef";
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
}

test "frontmatter parser extracts command metadata" {
    const parsed = parseFrontmatter(
        \\---
        \\name: brave-search
        \\description: Web search via Brave API
        \\---
        \\Body
    );
    try std.testing.expectEqualStrings("brave-search", parsed.value("name").?);
    try std.testing.expectEqualStrings("Web search via Brave API", parsed.value("description").?);
}

// Mirrors expandPromptTemplateFile's arg pipeline: parse the raw invocation
// args, then substitute placeholders in `content`. Lets tests pin behavior
// against upstream parseCommandArgs/substituteArgs without touching the fs.
fn substituteForTest(allocator: std.mem.Allocator, content: []const u8, args_text: []const u8) ![]u8 {
    const args = try parseTemplateArgs(allocator, args_text);
    defer freeStringList(allocator, args);
    return substituteTemplateArgs(allocator, content, args);
}

test "parseTemplateArgs matches upstream parseCommandArgs (no escapes, quote stripping)" {
    const allocator = std.testing.allocator;

    // Backslash is a literal byte upstream (parseCommandArgs has no escape case).
    {
        const args = try parseTemplateArgs(allocator, "a\\ b");
        defer freeStringList(allocator, args);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("a\\", args[0]);
        try std.testing.expectEqualStrings("b", args[1]);
    }

    // Quotes are stripped; whitespace inside quotes is preserved.
    {
        const args = try parseTemplateArgs(allocator, "\"a b\"  'c d'");
        defer freeStringList(allocator, args);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("a b", args[0]);
        try std.testing.expectEqualStrings("c d", args[1]);
    }

    // Empty quotes produce no argument (upstream pushes only when current!="").
    {
        const args = try parseTemplateArgs(allocator, "x '' y");
        defer freeStringList(allocator, args);
        try std.testing.expectEqual(@as(usize, 2), args.len);
        try std.testing.expectEqualStrings("x", args[0]);
        try std.testing.expectEqualStrings("y", args[1]);
    }
}

test "substituteTemplateArgs joins parsed args with single space for \\$@ and \\$ARGUMENTS" {
    const allocator = std.testing.allocator;

    // $@ / $ARGUMENTS collapse internal whitespace and drop quotes (args.join(" ")).
    {
        const out = try substituteForTest(allocator, "[$@]", "\"a  b\"   c");
        defer allocator.free(out);
        try std.testing.expectEqualStrings("[a  b c]", out);
    }
    {
        const out = try substituteForTest(allocator, "<$ARGUMENTS>", "one   two");
        defer allocator.free(out);
        try std.testing.expectEqualStrings("<one two>", out);
    }
}

test "substituteTemplateArgs positional and slice placeholders" {
    const allocator = std.testing.allocator;

    {
        const out = try substituteForTest(allocator, "$1-$2-$3", "alpha beta");
        defer allocator.free(out);
        // $3 is out of range -> empty, matching args[index] ?? "".
        try std.testing.expectEqualStrings("alpha-beta-", out);
    }
    {
        // $0 is out of range upstream (parseInt("0")-1 = -1).
        const out = try substituteForTest(allocator, "[$0]", "alpha");
        defer allocator.free(out);
        try std.testing.expectEqualStrings("[]", out);
    }
    {
        // ${@:2} -> args from 2nd onward; ${@:2:1} -> one arg starting at 2nd.
        const out = try substituteForTest(allocator, "${@:2}|${@:2:1}", "a b c d");
        defer allocator.free(out);
        try std.testing.expectEqualStrings("b c d|b", out);
    }
    {
        // ${@:0} behaves like ${@:1} (bash convention: start clamps to first).
        const out = try substituteForTest(allocator, "${@:0}", "a b");
        defer allocator.free(out);
        try std.testing.expectEqualStrings("a b", out);
    }
}

test "substituteTemplateArgs does not re-substitute inserted argument values" {
    const allocator = std.testing.allocator;
    // Arg value contains "$2"; it must be emitted literally, not expanded.
    const out = try substituteForTest(allocator, "$1 then $2", "$2 second");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("$2 then second", out);
}

test "reloadCommandsJson re-discovers prompts added after the first call" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // Use a cwd-relative temp prompts dir (mirrors the repo's zig-out fixture
    // convention) so reload picks up files exactly like the real CLI does.
    const dir = "zig-out/pi-zig-reload-test-prompts";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    // Reload with only this (empty) dir as an additional prompt path: the new
    // command must be absent before the file exists.
    const options = Options{
        .additional_prompt_paths = &.{dir},
        .no_skills = true,
        .no_prompt_templates = true,
    };

    const before = try reloadCommandsJson(io, allocator, options);
    defer allocator.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "\"name\":\"reload-probe\"") == null);

    // Add a prompt template, then reload again on demand.
    const prompt_path = dir ++ "/reload-probe.md";
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = prompt_path,
        .data = "---\ndescription: freshly added\n---\nBody for $1\n",
    });

    const after = try reloadCommandsJson(io, allocator, options);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"name\":\"reload-probe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"source\":\"prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"description\":\"freshly added\"") != null);

    // Round-trip the other direction: removing the file and reloading drops it,
    // proving there is no stale in-memory cache.
    try std.Io.Dir.cwd().deleteFile(io, prompt_path);
    const after_remove = try reloadCommandsJson(io, allocator, options);
    defer allocator.free(after_remove);
    try std.testing.expect(std.mem.indexOf(u8, after_remove, "\"name\":\"reload-probe\"") == null);
}

test "writeCommandsDataJson dedups colliding prompt names keeping the first (highest precedence)" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const dir_a = "zig-out/pi-zig-dedup-test-a";
    const dir_b = "zig-out/pi-zig-dedup-test-b";
    for ([_][]const u8{ dir_a, dir_b }) |dir| {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir_a) catch {};
        std.Io.Dir.cwd().deleteTree(io, dir_b) catch {};
    }

    // Same prompt name "dup" in two paths with distinct descriptions.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_a ++ "/dup.md",
        .data = "---\ndescription: winner from a\n---\nBody A\n",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_b ++ "/dup.md",
        .data = "---\ndescription: loser from b\n---\nBody B\n",
    });

    // dir_a is listed first, so its "dup" must win and the duplicate is dropped.
    const paths = [_][]const u8{ dir_a, dir_b };
    const json = try reloadCommandsJson(io, allocator, .{
        .additional_prompt_paths = &paths,
        .no_skills = true,
        .no_prompt_templates = true,
    });
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const list = parsed.value.object.get("commands").?.array.items;

    var dup_count: usize = 0;
    var winning_description: []const u8 = "";
    for (list) |entry| {
        const name = objectString(entry, "name") orelse continue;
        if (!std.mem.eql(u8, name, "dup")) continue;
        dup_count += 1;
        winning_description = objectString(entry, "description") orelse "";
    }
    try std.testing.expectEqual(@as(usize, 1), dup_count);
    try std.testing.expectEqualStrings("winner from a", winning_description);
}

test "writeCommandsDataJson emits an upstream-shaped collision diagnostic for a shadowed duplicate" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const dir_a = "zig-out/pi-zig-collision-test-a";
    const dir_b = "zig-out/pi-zig-collision-test-b";
    for ([_][]const u8{ dir_a, dir_b }) |dir| {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir_a) catch {};
        std.Io.Dir.cwd().deleteTree(io, dir_b) catch {};
    }

    // Same prompt name "dup" in two paths; dir_a is listed first so it wins.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_a ++ "/dup.md",
        .data = "---\ndescription: winner from a\n---\nBody A\n",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_b ++ "/dup.md",
        .data = "---\ndescription: loser from b\n---\nBody B\n",
    });

    const paths = [_][]const u8{ dir_a, dir_b };
    const json = try reloadCommandsJson(io, allocator, .{
        .additional_prompt_paths = &paths,
        .no_skills = true,
        .no_prompt_templates = true,
    });
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    // Winner is unchanged: exactly one "dup" command, from dir_a.
    const list = parsed.value.object.get("commands").?.array.items;
    var dup_count: usize = 0;
    for (list) |entry| {
        if (std.mem.eql(u8, objectString(entry, "name") orelse "", "dup")) dup_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), dup_count);

    // Exactly one collision diagnostic, matching upstream dedupePrompts shape.
    const diagnostics = parsed.value.object.get("diagnostics").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    const diag = diagnostics[0];
    try std.testing.expectEqualStrings("collision", objectString(diag, "type").?);
    try std.testing.expectEqualStrings("name \"/dup\" collision", objectString(diag, "message").?);
    // path is the loser path (dir_b), exactly as upstream `path: prompt.filePath`.
    try std.testing.expect(std.mem.indexOf(u8, objectString(diag, "path").?, dir_b) != null);

    const collision = diag.object.get("collision").?;
    try std.testing.expectEqualStrings("prompt", objectString(collision, "resourceType").?);
    try std.testing.expectEqualStrings("dup", objectString(collision, "name").?);
    try std.testing.expect(std.mem.indexOf(u8, objectString(collision, "winnerPath").?, dir_a) != null);
    try std.testing.expect(std.mem.indexOf(u8, objectString(collision, "loserPath").?, dir_b) != null);
}

test "writeCommandsDataJson emits a skill collision diagnostic with the bare skill name" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const dir_a = "zig-out/pi-zig-collision-skill-a";
    const dir_b = "zig-out/pi-zig-collision-skill-b";
    for ([_][]const u8{ dir_a, dir_b }) |dir| {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir_a) catch {};
        std.Io.Dir.cwd().deleteTree(io, dir_b) catch {};
    }

    // Two SKILL.md files declaring the same skill name "dupskill".
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_a ++ "/SKILL.md",
        .data = "---\nname: dupskill\ndescription: winner skill\n---\nBody A\n",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_b ++ "/SKILL.md",
        .data = "---\nname: dupskill\ndescription: loser skill\n---\nBody B\n",
    });

    const paths = [_][]const u8{ dir_a, dir_b };
    const json = try reloadCommandsJson(io, allocator, .{
        .additional_skill_paths = &paths,
        .no_skills = true,
        .no_prompt_templates = true,
    });
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const diagnostics = parsed.value.object.get("diagnostics").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    const diag = diagnostics[0];
    try std.testing.expectEqualStrings("collision", objectString(diag, "type").?);
    // Skill messages use the bare name with no leading slash (upstream skills.ts).
    try std.testing.expectEqualStrings("name \"dupskill\" collision", objectString(diag, "message").?);
    const collision = diag.object.get("collision").?;
    try std.testing.expectEqualStrings("skill", objectString(collision, "resourceType").?);
    try std.testing.expectEqualStrings("dupskill", objectString(collision, "name").?);
}

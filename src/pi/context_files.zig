const std = @import("std");

const max_context_file_bytes = 1024 * 1024;
const candidates = [_][]const u8{ "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD" };

pub const Options = struct {
    no_context_files: bool = false,
};

const CliOptions = struct {
    help: bool = false,
    no_context_files: bool = false,
    invalid_option: ?[]const u8 = null,
};

pub const TextFile = struct {
    path: []u8,
    content: []u8,
    scope: []const u8,

    fn deinit(self: TextFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

pub const Discovery = struct {
    allocator: std.mem.Allocator,
    cwd: []u8,
    agent_dir: []u8,
    context_files: std.ArrayList(TextFile),
    system_prompt: ?TextFile = null,
    append_system_prompt: ?TextFile = null,

    pub fn deinit(self: *Discovery) void {
        allocatorFreeOptional(self.allocator, self.system_prompt);
        allocatorFreeOptional(self.allocator, self.append_system_prompt);
        for (self.context_files.items) |file| file.deinit(self.allocator);
        self.context_files.deinit(self.allocator);
        self.allocator.free(self.cwd);
        self.allocator.free(self.agent_dir);
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !bool {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "context-files")) return false;
    const options = parseCliOptions(args[1..]);

    if (options.help) {
        try writeHelp(io);
        return true;
    }
    if (options.invalid_option) |option| {
        try writeStderr(io, "Unknown option ");
        try writeStderr(io, option);
        try writeStderr(io, " for \"context-files\".\n");
        try writeStderr(io, "Use \"pi-zig context-files --help\".\n");
        std.process.exit(1);
    }

    var discovery = try discover(io, allocator, env, .{ .no_context_files = options.no_context_files });
    defer discovery.deinit();

    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try writeDiscoveryJson(w, &discovery, options.no_context_files);
    try w.writeByte('\n');
    try w.flush();
    return true;
}

pub fn discover(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, options: Options) !Discovery {
    const cwd = try currentPathOwned(io, allocator);
    errdefer allocator.free(cwd);
    const agent_dir = try resolvedAgentDir(allocator, env, cwd);
    errdefer allocator.free(agent_dir);

    var discovery = Discovery{
        .allocator = allocator,
        .cwd = cwd,
        .agent_dir = agent_dir,
        .context_files = .empty,
    };
    errdefer discovery.deinit();

    if (!options.no_context_files) {
        try discoverContextFiles(io, allocator, &discovery);
    }

    discovery.system_prompt = try loadFirstPromptFile(io, allocator, cwd, agent_dir, "SYSTEM.md", "system");
    discovery.append_system_prompt = try loadFirstPromptFile(io, allocator, cwd, agent_dir, "APPEND_SYSTEM.md", "appendSystem");

    return discovery;
}

fn discoverContextFiles(io: std.Io, allocator: std.mem.Allocator, discovery: *Discovery) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    if (try loadContextFileFromDir(io, allocator, discovery.agent_dir, "user")) |global_context| {
        try discovery.context_files.append(allocator, global_context);
        try seen.put(global_context.path, {});
    }

    var ancestors: std.ArrayList(TextFile) = .empty;
    defer {
        for (ancestors.items) |file| file.deinit(allocator);
        ancestors.deinit(allocator);
    }

    var current_dir = try allocator.dupe(u8, discovery.cwd);
    defer allocator.free(current_dir);

    while (true) {
        if (try loadContextFileFromDir(io, allocator, current_dir, "project")) |context_file| {
            if (seen.contains(context_file.path)) {
                context_file.deinit(allocator);
            } else {
                try seen.put(context_file.path, {});
                try ancestors.append(allocator, context_file);
            }
        }

        const parent = parentDir(current_dir) orelse break;
        const next_dir = try allocator.dupe(u8, parent);
        allocator.free(current_dir);
        current_dir = next_dir;
    }

    var index = ancestors.items.len;
    while (index > 0) {
        index -= 1;
        try discovery.context_files.append(allocator, try cloneTextFile(allocator, ancestors.items[index]));
    }
}

fn loadContextFileFromDir(io: std.Io, allocator: std.mem.Allocator, dir: []const u8, scope: []const u8) !?TextFile {
    for (candidates) |filename| {
        const path = try std.fs.path.join(allocator, &.{ dir, filename });
        defer allocator.free(path);
        if (try readOptionalFile(io, allocator, path, scope)) |file| return file;
    }
    return null;
}

fn loadFirstPromptFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    agent_dir: []const u8,
    filename: []const u8,
    scope: []const u8,
) !?TextFile {
    const project_path = try std.fs.path.join(allocator, &.{ cwd, ".pi", filename });
    defer allocator.free(project_path);
    if (try readOptionalFile(io, allocator, project_path, scope)) |file| return file;

    const global_path = try std.fs.path.join(allocator, &.{ agent_dir, filename });
    defer allocator.free(global_path);
    return readOptionalFile(io, allocator, global_path, scope);
}

fn readOptionalFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, scope: []const u8) !?TextFile {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_context_file_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    errdefer allocator.free(bytes);
    return .{
        .path = try allocator.dupe(u8, path),
        .content = bytes,
        .scope = scope,
    };
}

fn cloneTextFile(allocator: std.mem.Allocator, file: TextFile) !TextFile {
    return .{
        .path = try allocator.dupe(u8, file.path),
        .content = try allocator.dupe(u8, file.content),
        .scope = file.scope,
    };
}

fn parseCliOptions(args: []const []const u8) CliOptions {
    var options = CliOptions{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--no-context-files") or std.mem.eql(u8, arg, "-nc")) {
            options.no_context_files = true;
        } else {
            options.invalid_option = options.invalid_option orelse arg;
        }
    }
    return options;
}

fn writeDiscoveryJson(w: *std.Io.Writer, discovery: *const Discovery, no_context_files: bool) !void {
    try w.writeAll("{\"cwd\":");
    try writeJsonString(w, discovery.cwd);
    try w.writeAll(",\"agentDir\":");
    try writeJsonString(w, discovery.agent_dir);
    try w.writeAll(",\"contextFilesEnabled\":");
    try w.writeAll(if (no_context_files) "false" else "true");
    try w.writeAll(",\"contextFiles\":[");
    for (discovery.context_files.items, 0..) |file, i| {
        if (i != 0) try w.writeByte(',');
        try writeTextFileJson(w, file);
    }
    try w.writeAll("],\"systemPrompt\":");
    if (discovery.system_prompt) |file| {
        try writeTextFileJson(w, file);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"appendSystemPrompt\":");
    if (discovery.append_system_prompt) |file| {
        try writeTextFileJson(w, file);
    } else {
        try w.writeAll("null");
    }
    try w.writeByte('}');
}

fn writeTextFileJson(w: *std.Io.Writer, file: TextFile) !void {
    try w.writeAll("{\"path\":");
    try writeJsonString(w, file.path);
    try w.writeAll(",\"scope\":");
    try writeJsonString(w, file.scope);
    try w.writeAll(",\"content\":");
    try writeJsonString(w, file.content);
    try w.writeByte('}');
}

fn resolvedAgentDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, cwd: []const u8) ![]u8 {
    if (env.get("PI_CODING_AGENT_DIR")) |value| {
        return resolvePathWithBase(allocator, env, cwd, value);
    }
    const home = env.get("HOME") orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ home, ".pi", "agent" });
    defer allocator.free(joined);
    return resolvePathWithBase(allocator, env, cwd, joined);
}

fn resolvePathWithBase(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, base_dir: []const u8, raw_path: []const u8) ![]u8 {
    const expanded = try expandMaybeTilde(allocator, env, raw_path);
    defer allocator.free(expanded);
    if (std.fs.path.isAbsolute(expanded)) return std.fs.path.resolve(allocator, &.{expanded});
    return std.fs.path.resolve(allocator, &.{ base_dir, expanded });
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

fn currentPathOwned(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(io, &buf);
    return std.fs.path.resolve(allocator, &.{buf[0..len]});
}

fn parentDir(path: []const u8) ?[]const u8 {
    const parent = std.fs.path.dirname(path) orelse return null;
    if (std.mem.eql(u8, parent, path)) return null;
    return parent;
}

fn allocatorFreeOptional(allocator: std.mem.Allocator, value: ?TextFile) void {
    if (value) |file| file.deinit(allocator);
}

fn writeHelp(io: std.Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  pi-zig context-files [--no-context-files]
        \\
        \\Discover upstream AGENTS.md/CLAUDE.md context files plus .pi/SYSTEM.md and
        \\APPEND_SYSTEM.md prompt files.
        \\
        \\Options:
        \\  --no-context-files, -nc   Skip AGENTS.md and CLAUDE.md discovery
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

test "context file parent traversal stops at filesystem root" {
    try std.testing.expect(parentDir("/") == null);
    try std.testing.expectEqualStrings("/tmp", parentDir("/tmp/pi").?);
}

test "loadContextFileFromDir prefers AGENTS.md over CLAUDE.md (upstream candidate order)" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const dir = "zig-out/pi-zig-ctx-candidates";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    // Both present -> AGENTS.md wins (it is first in the candidate list).
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/AGENTS.md", .data = "agents wins" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/CLAUDE.md", .data = "claude loses" });
    {
        const file = (try loadContextFileFromDir(io, allocator, dir, "project")).?;
        defer file.deinit(allocator);
        try std.testing.expectEqualStrings("agents wins", file.content);
        try std.testing.expect(std.mem.endsWith(u8, file.path, "/AGENTS.md"));
    }

    // Only CLAUDE.md present -> it is discovered.
    try std.Io.Dir.cwd().deleteFile(io, dir ++ "/AGENTS.md");
    {
        const file = (try loadContextFileFromDir(io, allocator, dir, "project")).?;
        defer file.deinit(allocator);
        try std.testing.expectEqualStrings("claude loses", file.content);
    }

    // None present -> null.
    try std.Io.Dir.cwd().deleteFile(io, dir ++ "/CLAUDE.md");
    try std.testing.expect((try loadContextFileFromDir(io, allocator, dir, "project")) == null);
}

test "loadFirstPromptFile resolves project .pi/SYSTEM.md before agent dir" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const cwd = "zig-out/pi-zig-prompt-precedence-cwd";
    const agent_dir = "zig-out/pi-zig-prompt-precedence-agent";
    std.Io.Dir.cwd().deleteTree(io, cwd) catch {};
    std.Io.Dir.cwd().deleteTree(io, agent_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, agent_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, cwd ++ "/.pi");
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);

    // Both define SYSTEM.md -> the project copy under .pi/ wins.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cwd ++ "/.pi/SYSTEM.md", .data = "project system" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = agent_dir ++ "/SYSTEM.md", .data = "agent system" });
    {
        const file = (try loadFirstPromptFile(io, allocator, cwd, agent_dir, "SYSTEM.md", "system")).?;
        defer file.deinit(allocator);
        try std.testing.expectEqualStrings("project system", file.content);
    }

    // Remove the project copy -> falls back to the agent dir copy.
    try std.Io.Dir.cwd().deleteFile(io, cwd ++ "/.pi/SYSTEM.md");
    {
        const file = (try loadFirstPromptFile(io, allocator, cwd, agent_dir, "SYSTEM.md", "system")).?;
        defer file.deinit(allocator);
        try std.testing.expectEqualStrings("agent system", file.content);
    }
}

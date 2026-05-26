const std = @import("std");

const default_find_limit = 1000;
const max_edit_file_bytes = 4 * 1024 * 1024;

pub const ShellResult = struct {
    output: []u8,
    exit_code: ?u8,
    cancelled: bool = false,
    truncated: bool = false,
    full_output_path: ?[]const u8 = null,
};

pub fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

pub fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

pub fn listDir(io: std.Io, path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try w.print("{s}\t{s}\n", .{ kindLabel(entry.kind), entry.name });
    }
    try w.flush();
}

pub fn findFiles(io: std.Io, allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, limit: usize) !void {
    const effective_limit = if (limit == 0) default_find_limit else limit;

    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;

    var matched: usize = 0;
    var limit_reached = false;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and shouldSkipFindDir(entry.basename)) {
            walker.leave(io);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!matchesGlob(pattern, entry.path)) continue;

        if (matched >= effective_limit) {
            limit_reached = true;
            break;
        }
        try writePosixPath(w, entry.path);
        try w.writeByte('\n');
        matched += 1;
    }

    if (matched == 0) {
        try w.writeAll("No files found matching pattern\n");
    } else if (limit_reached) {
        try w.print("\n[{d} results limit reached. Increase the limit or refine pattern]\n", .{effective_limit});
    }
    try w.flush();
}

pub fn grepFile(io: std.Io, allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, max_bytes: usize) !void {
    const bytes = try readFile(io, allocator, path, max_bytes);
    defer allocator.free(bytes);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (std.mem.indexOf(u8, line, pattern) != null) {
            try w.print("{d}:{s}\n", .{ line_no, line });
        }
    }
    try w.flush();
}

pub fn editFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, old_text: []const u8, new_text: []const u8) !void {
    if (old_text.len == 0) return error.EmptyEditTarget;

    const bytes = try readFile(io, allocator, path, max_edit_file_bytes);
    defer allocator.free(bytes);

    const matches = std.mem.count(u8, bytes, old_text);
    if (matches == 0) return error.EditTargetMissing;
    if (matches > 1) return error.EditTargetNotUnique;

    const replaced = try std.mem.replaceOwned(u8, allocator, bytes, old_text, new_text);
    defer allocator.free(replaced);

    try writeFile(io, path, replaced);

    var buf: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.print("Successfully replaced 1 block in {s}.\n", .{path});
    try w.flush();
}

pub fn runShell(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !void {
    const shell_result = try runShellCapture(io, allocator, command);
    defer allocator.free(shell_result.output);

    if (shell_result.output.len > 0) {
        try std.Io.File.stdout().writeStreamingAll(io, shell_result.output);
    }
    if (shell_result.exit_code == null or shell_result.exit_code.? != 0) return error.CommandFailed;
}

pub fn runShellCapture(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !ShellResult {
    const argv = [_][]const u8{ "sh", "-lc", command };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const output = try allocator.alloc(u8, result.stdout.len + result.stderr.len);
    @memcpy(output[0..result.stdout.len], result.stdout);
    @memcpy(output[result.stdout.len..], result.stderr);

    return .{
        .output = output,
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => null,
        },
    };
}

fn kindLabel(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .block_device => "block",
        .character_device => "char",
        .directory => "dir",
        .named_pipe => "pipe",
        .sym_link => "link",
        .file => "file",
        .unix_domain_socket => "socket",
        .whiteout => "whiteout",
        .door => "door",
        .event_port => "event_port",
        .unknown => "unknown",
    };
}

fn shouldSkipFindDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "dist");
}

fn matchesGlob(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return false;
    if (hasSlash(pattern)) {
        if (wildcardMatch(pattern, path)) return true;

        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] == '/' and i + 1 < path.len and wildcardMatch(pattern, path[i + 1 ..])) {
                return true;
            }
        }
        return false;
    }
    return wildcardMatch(pattern, basename(path));
}

fn hasSlash(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, '/') != null or std.mem.indexOfScalar(u8, value, '\\') != null;
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, path, '\\')) |idx| return path[idx + 1 ..];
    return path;
}

fn wildcardMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var star_match: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            while (p < pattern.len and pattern[p] == '*') p += 1;
            if (p == pattern.len) return true;
            star = p - 1;
            star_match = t;
        } else if (star) |star_index| {
            p = star_index + 1;
            star_match += 1;
            t = star_match;
        } else {
            return false;
        }
    }

    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn writePosixPath(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        try w.writeByte(if (byte == '\\') '/' else byte);
    }
}

test "glob matching supports basename and path suffix patterns" {
    try std.testing.expect(matchesGlob("*.zig", "src/pi/tools.zig"));
    try std.testing.expect(matchesGlob("src/*.tsx", "frontend/src/main.tsx"));
    try std.testing.expect(!matchesGlob("*.md", "src/main.zig"));
}

test "wildcard matching is deterministic" {
    try std.testing.expect(wildcardMatch("src/**/*.zig", "src/pi/tools.zig"));
    try std.testing.expect(wildcardMatch("README.*", "README.md"));
    try std.testing.expect(!wildcardMatch("README.?", "README.md"));
}

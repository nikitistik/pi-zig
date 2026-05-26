const std = @import("std");

const default_find_limit = 1000;
const default_ls_limit = 500;
const default_grep_limit = 100;
const default_read_max_lines = 2000;
const default_read_max_bytes = 50 * 1024;
const grep_max_line_chars = 500;
const max_read_file_bytes = 16 * 1024 * 1024;
const max_edit_file_bytes = 4 * 1024 * 1024;

pub const ShellResult = struct {
    output: []u8,
    exit_code: ?u8,
    cancelled: bool = false,
    truncated: bool = false,
    full_output_path: ?[]const u8 = null,
};

pub const GrepOptions = struct {
    glob: ?[]const u8 = null,
    ignore_case: bool = false,
    literal: bool = false,
    context: usize = 0,
    limit: usize = default_grep_limit,
};

pub fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

pub fn readFileForTool(io: std.Io, allocator: std.mem.Allocator, path: []const u8, offset: ?usize, limit: ?usize) !void {
    const bytes = try readFile(io, allocator, path, max_read_file_bytes);
    defer allocator.free(bytes);

    const total_lines = countReadLines(bytes);
    const start_line = if (offset) |value| if (value == 0) 0 else value - 1 else 0;
    if (start_line >= total_lines) return error.OffsetBeyondEnd;

    var selected_out: std.Io.Writer.Allocating = .init(allocator);
    defer selected_out.deinit();
    try writeLineWindow(&selected_out.writer, bytes, start_line, limit);
    const selected = selected_out.written();

    const truncation = try truncateHead(allocator, selected, default_read_max_lines, default_read_max_bytes);
    defer allocator.free(truncation.content);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;

    if (truncation.first_line_exceeds_limit) {
        try w.print("[Line {d} is ", .{start_line + 1});
        try writeSize(w, bytesForLine(bytes, start_line));
        try w.writeAll(", exceeds ");
        try writeSize(w, default_read_max_bytes);
        try w.print(" limit. Use bash: sed -n '{d}p' {s} | head -c {d}]\n", .{ start_line + 1, path, default_read_max_bytes });
        try w.flush();
        return;
    }

    try w.writeAll(truncation.content);
    if (truncation.truncated) {
        const end_line = start_line + truncation.output_lines;
        const next_offset = end_line + 1;
        if (truncation.truncated_by == .lines) {
            try w.print("\n\n[Showing lines {d}-{d} of {d}. Use offset={d} to continue.]", .{ start_line + 1, end_line, total_lines, next_offset });
        } else {
            try w.print("\n\n[Showing lines {d}-{d} of {d} (", .{ start_line + 1, end_line, total_lines });
            try writeSize(w, default_read_max_bytes);
            try w.print(" limit). Use offset={d} to continue.]", .{next_offset});
        }
    } else if (limit) |line_limit| {
        if (start_line + line_limit < total_lines) {
            const remaining = total_lines - (start_line + line_limit);
            const next_offset = start_line + line_limit + 1;
            try w.print("\n\n[{d} more lines in file. Use offset={d} to continue.]", .{ remaining, next_offset });
        }
    }
    try w.flush();
}

pub fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

const ListEntry = struct {
    name: []u8,
    is_dir: bool,
};

pub fn listDir(io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) !void {
    const effective_limit = if (limit == 0) default_ls_limit else limit;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var entries: std.ArrayList(ListEntry) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .is_dir = entry.kind == .directory,
        });
    }
    std.mem.sort(ListEntry, entries.items, {}, lessThanListEntry);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;

    if (entries.items.len == 0) {
        try w.writeAll("(empty directory)\n");
        try w.flush();
        return;
    }

    const shown = @min(effective_limit, entries.items.len);
    for (entries.items[0..shown]) |entry| {
        try w.writeAll(entry.name);
        if (entry.is_dir) try w.writeByte('/');
        try w.writeByte('\n');
    }
    if (shown < entries.items.len) {
        try w.print("\n[{d} entries limit reached. Use limit={d} for more]\n", .{ effective_limit, effective_limit * 2 });
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

pub fn grep(io: std.Io, allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, options: GrepOptions) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    const is_dir = stat.kind == .directory;
    const run_cwd = if (is_dir) path else std.fs.path.dirname(path) orelse ".";
    const target = if (is_dir) "." else std.fs.path.basename(path);
    const effective_limit = if (options.limit == 0) default_grep_limit else options.limit;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "rg",
        "--line-number",
        "--color=never",
        "--hidden",
        "--with-filename",
        "--no-heading",
    });
    var context_buf: [32]u8 = undefined;
    if (options.context > 0) {
        var fixed = std.Io.Writer.fixed(&context_buf);
        try fixed.print("{d}", .{options.context});
        try argv.appendSlice(allocator, &.{ "--context", fixed.buffered() });
    }
    if (options.ignore_case) try argv.append(allocator, "--ignore-case");
    if (options.literal) try argv.append(allocator, "--fixed-strings");
    if (options.glob) |glob| try argv.appendSlice(allocator, &.{ "--glob", glob });
    try argv.appendSlice(allocator, &.{ "--", pattern, target });

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = run_cwd },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const code = switch (result.term) {
        .exited => |value| value,
        else => return error.CommandFailed,
    };
    if (code != 0 and code != 1) {
        if (result.stderr.len > 0) try std.Io.File.stderr().writeStreamingAll(io, result.stderr);
        return error.CommandFailed;
    }
    if (result.stdout.len == 0) {
        try std.Io.File.stdout().writeStreamingAll(io, "No matches found\n");
        return;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var match_count: usize = 0;
    var limit_reached = false;
    var lines_truncated = false;
    var emitted_lines: usize = 0;

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_line| {
        var line = stripTrailingCarriageReturn(raw_line);
        if (line.len == 0 or std.mem.eql(u8, line, "--")) continue;
        if (std.mem.startsWith(u8, line, "./")) line = line[2..];

        const info = grepLineInfo(line);
        if (info) |line_info| {
            if (line_info.is_match) {
                if (match_count >= effective_limit) {
                    limit_reached = true;
                    break;
                }
                match_count += 1;
            }
        }

        if (emitted_lines != 0) try out.writer.writeByte('\n');
        if (info) |line_info| {
            try out.writer.writeAll(line[0..line_info.text_start]);
            const text = line[line_info.text_start..];
            if (text.len > grep_max_line_chars) {
                try out.writer.writeAll(text[0..grep_max_line_chars]);
                try out.writer.writeAll("... [truncated]");
                lines_truncated = true;
            } else {
                try out.writer.writeAll(text);
            }
        } else {
            try out.writer.writeAll(line);
        }
        emitted_lines += 1;
    }

    if (match_count == 0) {
        try std.Io.File.stdout().writeStreamingAll(io, "No matches found\n");
        return;
    }

    const truncation = try truncateHead(allocator, out.written(), std.math.maxInt(usize), default_read_max_bytes);
    defer allocator.free(truncation.content);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll(truncation.content);

    var notice_count: usize = 0;
    if (limit_reached or truncation.truncated or lines_truncated) {
        try w.writeAll("\n\n[");
        if (limit_reached) {
            try w.print("{d} matches limit reached. Use limit={d} for more, or refine pattern", .{ effective_limit, effective_limit * 2 });
            notice_count += 1;
        }
        if (truncation.truncated) {
            if (notice_count != 0) try w.writeAll(". ");
            try writeSize(w, default_read_max_bytes);
            try w.writeAll(" limit reached");
            notice_count += 1;
        }
        if (lines_truncated) {
            if (notice_count != 0) try w.writeAll(". ");
            try w.print("Some lines truncated to {d} chars. Use read tool to see full lines", .{grep_max_line_chars});
        }
        try w.writeAll("]");
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

fn lessThanListEntry(_: void, left: ListEntry, right: ListEntry) bool {
    if (lessThanAsciiIgnoreCase(left.name, right.name)) return true;
    if (lessThanAsciiIgnoreCase(right.name, left.name)) return false;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn lessThanAsciiIgnoreCase(left: []const u8, right: []const u8) bool {
    var index: usize = 0;
    while (index < left.len and index < right.len) : (index += 1) {
        const a = std.ascii.toLower(left[index]);
        const b = std.ascii.toLower(right[index]);
        if (a < b) return true;
        if (a > b) return false;
    }
    return left.len < right.len;
}

const TruncatedBy = enum {
    none,
    lines,
    bytes,
};

const Truncation = struct {
    content: []u8,
    truncated: bool,
    truncated_by: TruncatedBy,
    output_lines: usize,
    first_line_exceeds_limit: bool = false,
};

const GrepLineInfo = struct {
    text_start: usize,
    is_match: bool,
};

fn grepLineInfo(line: []const u8) ?GrepLineInfo {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const separator = line[index];
        if (separator != ':' and separator != '-') continue;
        var digit_index = index + 1;
        if (digit_index >= line.len or !std.ascii.isDigit(line[digit_index])) continue;
        while (digit_index < line.len and std.ascii.isDigit(line[digit_index])) : (digit_index += 1) {}
        if (digit_index < line.len and line[digit_index] == separator) {
            return .{
                .text_start = digit_index + 1,
                .is_match = separator == ':',
            };
        }
    }
    return null;
}

fn truncateHead(allocator: std.mem.Allocator, content: []const u8, max_lines: usize, max_bytes: usize) !Truncation {
    const total_lines = countOutputLines(content);
    if (total_lines <= max_lines and content.len <= max_bytes) {
        return .{
            .content = try allocator.dupe(u8, content),
            .truncated = false,
            .truncated_by = .none,
            .output_lines = total_lines,
        };
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var iter = std.mem.splitScalar(u8, content, '\n');
    var output_lines: usize = 0;
    var truncated_by: TruncatedBy = .lines;
    while (iter.next()) |line| {
        if (output_lines >= max_lines) {
            truncated_by = .lines;
            break;
        }
        const separator_len: usize = if (output_lines == 0) 0 else 1;
        if (line.len + separator_len > max_bytes - out.written().len) {
            if (output_lines == 0) {
                out.deinit();
                return .{
                    .content = try allocator.dupe(u8, ""),
                    .truncated = true,
                    .truncated_by = .bytes,
                    .output_lines = 0,
                    .first_line_exceeds_limit = true,
                };
            }
            truncated_by = .bytes;
            break;
        }
        if (output_lines != 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(line);
        output_lines += 1;
    }

    return .{
        .content = try out.toOwnedSlice(),
        .truncated = true,
        .truncated_by = truncated_by,
        .output_lines = output_lines,
    };
}

fn writeLineWindow(w: *std.Io.Writer, content: []const u8, start_line: usize, limit: ?usize) !void {
    var iter = std.mem.splitScalar(u8, content, '\n');
    var line_index: usize = 0;
    var emitted: usize = 0;
    while (iter.next()) |line| : (line_index += 1) {
        if (line_index < start_line) continue;
        if (limit) |max_lines| if (emitted >= max_lines) break;
        if (emitted != 0) try w.writeByte('\n');
        try w.writeAll(line);
        emitted += 1;
    }
}

fn countReadLines(content: []const u8) usize {
    if (content.len == 0) return 1;
    return std.mem.count(u8, content, "\n") + 1;
}

fn countOutputLines(content: []const u8) usize {
    if (content.len == 0) return 0;
    return std.mem.count(u8, content, "\n") + 1;
}

fn bytesForLine(content: []const u8, target_line: usize) usize {
    var iter = std.mem.splitScalar(u8, content, '\n');
    var line_index: usize = 0;
    while (iter.next()) |line| : (line_index += 1) {
        if (line_index == target_line) return line.len;
    }
    return 0;
}

fn writeSize(w: *std.Io.Writer, bytes: usize) !void {
    if (bytes < 1024) {
        try w.print("{d}B", .{bytes});
    } else if (bytes < 1024 * 1024) {
        const tenths = (bytes * 10) / 1024;
        try w.print("{d}.{d}KB", .{ tenths / 10, tenths % 10 });
    } else {
        const tenths = (bytes * 10) / (1024 * 1024);
        try w.print("{d}.{d}MB", .{ tenths / 10, tenths % 10 });
    }
}

fn stripTrailingCarriageReturn(value: []const u8) []const u8 {
    if (value.len > 0 and value[value.len - 1] == '\r') return value[0 .. value.len - 1];
    return value;
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

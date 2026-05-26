const std = @import("std");
const builtin = @import("builtin");

const default_find_limit = 1000;
const default_ls_limit = 500;
const default_grep_limit = 100;
const default_read_max_lines = 2000;
const default_read_max_bytes = 50 * 1024;
const default_bash_max_lines = 2000;
const default_bash_max_bytes = 50 * 1024;
const default_bash_update_throttle_ms = 100;
const default_bash_update_min_bytes = 4096;
const max_bash_capture_bytes = 8 * 1024 * 1024;
const bash_full_output_path = "zig-out/pi-zig-bash-full-output.log";
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

pub const ShellUpdate = struct {
    output: []const u8,
    truncated: bool = false,
    full_output_path: ?[]const u8 = null,
    truncation: ?ShellTruncationDetails = null,
};

pub const ShellUpdateCallback = *const fn (ctx: *anyopaque, update: ShellUpdate) anyerror!void;
pub const ShellCancellationCallback = *const fn (ctx: *anyopaque) bool;

pub const ShellTruncatedBy = enum {
    lines,
    bytes,
};

pub const ShellTruncationDetails = struct {
    truncated_by: ?ShellTruncatedBy = null,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    last_line_partial: bool = false,
    first_line_exceeds_limit: bool = false,
    max_lines: usize = default_bash_max_lines,
    max_bytes: usize = default_bash_max_bytes,
};

pub const ShellCaptureOptions = struct {
    update_context: ?*anyopaque = null,
    on_update: ?ShellUpdateCallback = null,
    update_throttle_ms: i64 = default_bash_update_throttle_ms,
    update_min_bytes: usize = default_bash_update_min_bytes,
    timeout_ms: ?i64 = null,
    cancellation_context: ?*anyopaque = null,
    should_cancel: ?ShellCancellationCallback = null,
    cancellation_poll_ms: i64 = 100,
    shell_path: ?[]const u8 = null,
    command_prefix: ?[]const u8 = null,
};

pub const GrepOptions = struct {
    glob: ?[]const u8 = null,
    ignore_case: bool = false,
    literal: bool = false,
    context: usize = 0,
    limit: usize = default_grep_limit,
};

pub const EditReplacement = struct {
    old_text: []const u8,
    new_text: []const u8,
};

pub fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

pub fn readFileForTool(io: std.Io, allocator: std.mem.Allocator, path: []const u8, offset: ?usize, limit: ?usize) !void {
    const text = try readFileForToolText(io, allocator, path, offset, limit);
    defer allocator.free(text);
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

pub fn readFileForToolText(io: std.Io, allocator: std.mem.Allocator, path: []const u8, offset: ?usize, limit: ?usize) ![]u8 {
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

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    if (truncation.first_line_exceeds_limit) {
        try w.print("[Line {d} is ", .{start_line + 1});
        try writeSize(w, bytesForLine(bytes, start_line));
        try w.writeAll(", exceeds ");
        try writeSize(w, default_read_max_bytes);
        try w.print(" limit. Use bash: sed -n '{d}p' {s} | head -c {d}]\n", .{ start_line + 1, path, default_read_max_bytes });
        return out.toOwnedSlice();
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
    return out.toOwnedSlice();
}

pub fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

pub fn writeFileForTool(io: std.Io, path: []const u8, content: []const u8) !void {
    try writeFile(io, path, content);

    var buf: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.print("Successfully wrote {d} bytes to {s}\n", .{ content.len, path });
    try w.flush();
}

pub fn writeFileForToolText(io: std.Io, allocator: std.mem.Allocator, path: []const u8, content: []const u8) ![]u8 {
    try writeFile(io, path, content);
    return std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to {s}", .{ content.len, path });
}

const ListEntry = struct {
    name: []u8,
    is_dir: bool,
};

const FindEntry = struct {
    path: []u8,
    is_dir: bool,
};

const FindIgnoreRule = struct {
    base: []u8,
    pattern: []u8,
    negated: bool,
    dir_only: bool,
    anchored: bool,
    has_slash: bool,
    sequence: usize,
};

pub fn listDir(io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) !void {
    const text = try listDirText(io, allocator, path, limit);
    defer allocator.free(text);
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

pub fn listDirText(io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
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

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    if (entries.items.len == 0) {
        try w.writeAll("(empty directory)");
        return out.toOwnedSlice();
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
    return out.toOwnedSlice();
}

pub fn findFiles(io: std.Io, allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, limit: usize) !void {
    const text = try findFilesText(io, allocator, pattern, path, limit);
    defer allocator.free(text);
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

pub fn findFilesText(io: std.Io, allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, limit: usize) ![]u8 {
    const effective_limit = if (limit == 0) default_find_limit else limit;

    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var ignore_rules = try loadFindIgnoreRules(io, allocator, path);
    defer deinitFindIgnoreRules(allocator, &ignore_rules);

    var entries: std.ArrayList(FindEntry) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    var limit_reached = false;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and shouldSkipFindDir(entry.basename)) {
            walker.leave(io);
            continue;
        }
        const is_dir = entry.kind == .directory;
        if (isFindIgnored(ignore_rules.items, entry.path, is_dir)) {
            if (is_dir) walker.leave(io);
            continue;
        }
        if (entry.kind != .file and entry.kind != .directory) continue;
        if (!matchesGlob(pattern, entry.path)) continue;

        if (entries.items.len >= effective_limit) {
            limit_reached = true;
            break;
        }
        try entries.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .is_dir = entry.kind == .directory,
        });
    }
    if (entries.items.len >= effective_limit) limit_reached = true;

    if (entries.items.len == 0) {
        return allocator.dupe(u8, "No files found matching pattern");
    }

    std.mem.sort(FindEntry, entries.items, {}, lessThanFindEntry);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (entries.items, 0..) |entry, index| {
        if (index != 0) try out.writer.writeByte('\n');
        try writePosixPath(&out.writer, entry.path);
        if (entry.is_dir) try out.writer.writeByte('/');
    }

    const truncation = try truncateHead(allocator, out.written(), std.math.maxInt(usize), default_read_max_bytes);
    defer allocator.free(truncation.content);

    var final_out: std.Io.Writer.Allocating = .init(allocator);
    errdefer final_out.deinit();
    const w = &final_out.writer;
    try w.writeAll(truncation.content);
    if (limit_reached or truncation.truncated) {
        var notice_count: usize = 0;
        try w.writeAll("\n\n[");
        if (limit_reached) {
            try w.print("{d} results limit reached. Use limit={d} for more, or refine pattern", .{ effective_limit, effective_limit * 2 });
            notice_count += 1;
        }
        if (truncation.truncated) {
            if (notice_count != 0) try w.writeAll(". ");
            try writeSize(w, default_read_max_bytes);
            try w.writeAll(" limit reached");
        }
        try w.writeByte(']');
    }
    return final_out.toOwnedSlice();
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
    const text = try grepText(io, allocator, pattern, path, options);
    defer allocator.free(text);
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

pub fn grepText(io: std.Io, allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, options: GrepOptions) ![]u8 {
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
        return allocator.dupe(u8, "No matches found");
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
        return allocator.dupe(u8, "No matches found");
    }

    const truncation = try truncateHead(allocator, out.written(), std.math.maxInt(usize), default_read_max_bytes);
    defer allocator.free(truncation.content);

    var final_out: std.Io.Writer.Allocating = .init(allocator);
    errdefer final_out.deinit();
    const w = &final_out.writer;
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
    return final_out.toOwnedSlice();
}

pub fn editFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, old_text: []const u8, new_text: []const u8) !void {
    const edits = [_]EditReplacement{.{
        .old_text = old_text,
        .new_text = new_text,
    }};
    return editFileMany(io, allocator, path, edits[0..]);
}

pub fn editFileMany(io: std.Io, allocator: std.mem.Allocator, path: []const u8, edits: []const EditReplacement) !void {
    const text = try editFileManyText(io, allocator, path, edits);
    defer allocator.free(text);
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

pub fn editFileManyText(io: std.Io, allocator: std.mem.Allocator, path: []const u8, edits: []const EditReplacement) ![]u8 {
    if (edits.len == 0) return error.EmptyEditTarget;

    const bytes = try readFile(io, allocator, path, max_edit_file_bytes);
    defer allocator.free(bytes);

    const stripped = stripUtf8Bom(bytes);
    const line_ending = detectLineEnding(stripped.text);
    const normalized_content = try normalizeToLfAlloc(allocator, stripped.text);
    defer allocator.free(normalized_content);

    var normalized_edits: std.ArrayList(NormalizedEdit) = .empty;
    defer {
        for (normalized_edits.items) |edit| {
            allocator.free(edit.old_text);
            allocator.free(edit.new_text);
        }
        normalized_edits.deinit(allocator);
    }

    for (edits, 0..) |edit, index| {
        const normalized_old = try normalizeToLfAlloc(allocator, edit.old_text);
        errdefer allocator.free(normalized_old);
        const normalized_new = try normalizeToLfAlloc(allocator, edit.new_text);
        errdefer allocator.free(normalized_new);
        try normalized_edits.append(allocator, .{
            .old_text = normalized_old,
            .new_text = normalized_new,
            .edit_index = index,
        });
    }

    var matched_edits: std.ArrayList(MatchedEdit) = .empty;
    defer matched_edits.deinit(allocator);

    for (normalized_edits.items) |edit| {
        if (edit.old_text.len == 0) return error.EmptyEditTarget;
        const occurrences = findOccurrences(normalized_content, edit.old_text);
        if (occurrences.count == 0) return error.EditTargetMissing;
        if (occurrences.count > 1) return error.EditTargetNotUnique;
        try matched_edits.append(allocator, .{
            .edit_index = edit.edit_index,
            .match_index = occurrences.first.?,
            .match_len = edit.old_text.len,
            .new_text = edit.new_text,
        });
    }

    std.mem.sort(MatchedEdit, matched_edits.items, {}, lessThanMatchedEdit);
    for (matched_edits.items[1..], 1..) |current, index| {
        const previous = matched_edits.items[index - 1];
        if (previous.match_index + previous.match_len > current.match_index) return error.EditTargetOverlap;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var cursor: usize = 0;
    for (matched_edits.items) |edit| {
        try out.writer.writeAll(normalized_content[cursor..edit.match_index]);
        try out.writer.writeAll(edit.new_text);
        cursor = edit.match_index + edit.match_len;
    }
    try out.writer.writeAll(normalized_content[cursor..]);
    const new_content = out.written();

    if (std.mem.eql(u8, normalized_content, new_content)) return error.EditNoChange;

    var final_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer final_writer.deinit();
    try final_writer.writer.writeAll(stripped.bom);
    try writeRestoredLineEndings(&final_writer.writer, new_content, line_ending);
    const final_content = try final_writer.toOwnedSlice();
    defer allocator.free(final_content);

    try writeFile(io, path, final_content);

    return std.fmt.allocPrint(allocator, "Successfully replaced {d} block(s) in {s}.", .{ edits.len, path });
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
    const shell_path = try resolveShellPath(io, null);
    const merged_command = try stderrMergedShellCommand(allocator, command);
    defer merged_command.deinit(allocator);
    const argv = [_][]const u8{ shell_path, "-c", merged_command.command };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(max_bash_capture_bytes),
        .stderr_limit = .limited(max_bash_capture_bytes),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const raw_output = try combineShellOutput(allocator, result.stdout, result.stderr);
    defer allocator.free(raw_output);

    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    const formatted = try formatShellOutput(allocator, io, raw_output, exit_code);
    errdefer allocator.free(formatted.output);

    return .{
        .output = formatted.output,
        .exit_code = exit_code,
        .truncated = formatted.truncated,
        .full_output_path = formatted.full_output_path,
    };
}

pub fn runShellCaptureWithUpdates(
    io: std.Io,
    allocator: std.mem.Allocator,
    command: []const u8,
    options: ShellCaptureOptions,
) !ShellResult {
    const resolved_command = try prefixedShellCommand(allocator, command, options.command_prefix);
    defer resolved_command.deinit(allocator);
    const merged_command = try stderrMergedShellCommand(allocator, resolved_command.command);
    defer merged_command.deinit(allocator);
    const shell_path = try resolveShellPath(io, options.shell_path);
    const argv = [_][]const u8{ shell_path, "-c", merged_command.command };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = shellProcessGroupId(),
        .create_no_window = true,
    });
    defer child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    var last_update_len: usize = 0;
    var last_update_ms: ?i64 = null;
    var dirty = false;
    var timed_out = false;
    var cancelled_by_request = false;
    const started_ms = nowMilliseconds(io);

    while (true) {
        if (shouldCancelShell(options)) {
            cancelled_by_request = true;
            killShellChildTree(io, &child);
            break;
        }
        if (shellTimedOut(io, started_ms, options.timeout_ms)) {
            timed_out = true;
            killShellChildTree(io, &child);
            break;
        }

        multi_reader.fill(64, shellReadTimeout(io, started_ms, options)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => continue,
            else => |e| return e,
        };

        if (stdout_reader.buffered().len > max_bash_capture_bytes) return error.StreamTooLong;
        if (stderr_reader.buffered().len > max_bash_capture_bytes) return error.StreamTooLong;

        dirty = true;
        const stdout = stdout_reader.buffered();
        const stderr = stderr_reader.buffered();
        if (shouldEmitShellUpdate(io, stdout.len + stderr.len, last_update_len, last_update_ms, options)) {
            try emitShellUpdateSnapshot(io, allocator, stdout, stderr, options);
            last_update_len = stdout.len + stderr.len;
            last_update_ms = nowMilliseconds(io);
            dirty = false;
        }
    }

    try multi_reader.checkAnyError();
    const term = if (timed_out or cancelled_by_request) null else try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    defer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    defer allocator.free(stderr_slice);

    if (dirty and stdout_slice.len + stderr_slice.len > 0 and stdout_slice.len + stderr_slice.len != last_update_len) {
        try emitShellUpdateSnapshot(io, allocator, stdout_slice, stderr_slice, options);
    }

    const raw_output = try combineShellOutput(allocator, stdout_slice, stderr_slice);
    defer allocator.free(raw_output);

    const exit_code: ?u8 = if (term) |child_term| switch (child_term) {
        .exited => |code| code,
        else => null,
    } else null;
    const status_message = if (timed_out)
        try timeoutStatusMessage(allocator, options.timeout_ms.?)
    else if (cancelled_by_request)
        try allocator.dupe(u8, "Command cancelled")
    else
        null;
    defer if (status_message) |message| allocator.free(message);
    const formatted = if (status_message) |message|
        try formatShellOutputWithStatus(allocator, io, raw_output, exit_code, message, "")
    else
        try formatShellOutput(allocator, io, raw_output, exit_code);
    errdefer allocator.free(formatted.output);

    return .{
        .output = formatted.output,
        .exit_code = exit_code,
        .cancelled = timed_out or cancelled_by_request,
        .truncated = formatted.truncated,
        .full_output_path = formatted.full_output_path,
    };
}

fn lessThanListEntry(_: void, left: ListEntry, right: ListEntry) bool {
    if (lessThanAsciiIgnoreCase(left.name, right.name)) return true;
    if (lessThanAsciiIgnoreCase(right.name, left.name)) return false;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn lessThanFindEntry(_: void, left: FindEntry, right: FindEntry) bool {
    return std.mem.lessThan(u8, left.path, right.path);
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
    total_lines: usize = 0,
    total_bytes: usize = 0,
    output_bytes: usize = 0,
    last_line_partial: bool = false,
    first_line_exceeds_limit: bool = false,
};

const ShellOutput = struct {
    output: []u8,
    truncated: bool,
    full_output_path: ?[]const u8 = null,
    truncation: ?ShellTruncationDetails = null,
};

const GrepLineInfo = struct {
    text_start: usize,
    is_match: bool,
};

const NormalizedEdit = struct {
    old_text: []u8,
    new_text: []u8,
    edit_index: usize,
};

const MatchedEdit = struct {
    edit_index: usize,
    match_index: usize,
    match_len: usize,
    new_text: []const u8,
};

const Occurrences = struct {
    first: ?usize,
    count: usize,
};

const Utf8BomSplit = struct {
    bom: []const u8,
    text: []const u8,
};

const LineEnding = enum {
    lf,
    crlf,
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

fn lessThanMatchedEdit(_: void, left: MatchedEdit, right: MatchedEdit) bool {
    if (left.match_index == right.match_index) return left.edit_index < right.edit_index;
    return left.match_index < right.match_index;
}

fn findOccurrences(haystack: []const u8, needle: []const u8) Occurrences {
    if (needle.len == 0) return .{ .first = null, .count = 0 };

    var first: ?usize = null;
    var count: usize = 0;
    var start: usize = 0;
    while (start <= haystack.len) {
        const rel = std.mem.indexOf(u8, haystack[start..], needle) orelse break;
        const absolute = start + rel;
        if (first == null) first = absolute;
        count += 1;
        start = absolute + needle.len;
    }
    return .{ .first = first, .count = count };
}

fn stripUtf8Bom(content: []const u8) Utf8BomSplit {
    const bom = "\xEF\xBB\xBF";
    if (std.mem.startsWith(u8, content, bom)) {
        return .{ .bom = content[0..bom.len], .text = content[bom.len..] };
    }
    return .{ .bom = content[0..0], .text = content };
}

fn detectLineEnding(content: []const u8) LineEnding {
    if (std.mem.indexOfScalar(u8, content, '\n')) |line_feed| {
        if (line_feed > 0 and content[line_feed - 1] == '\r') return .crlf;
    }
    return .lf;
}

fn normalizeToLfAlloc(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var index: usize = 0;
    while (index < content.len) : (index += 1) {
        if (content[index] == '\r') {
            if (index + 1 < content.len and content[index + 1] == '\n') index += 1;
            try out.writer.writeByte('\n');
        } else {
            try out.writer.writeByte(content[index]);
        }
    }
    return out.toOwnedSlice();
}

fn writeRestoredLineEndings(w: *std.Io.Writer, content: []const u8, line_ending: LineEnding) !void {
    for (content) |byte| {
        if (byte == '\n' and line_ending == .crlf) {
            try w.writeAll("\r\n");
        } else {
            try w.writeByte(byte);
        }
    }
}

fn formatShellOutput(allocator: std.mem.Allocator, io: std.Io, raw_output: []const u8, exit_code: ?u8) !ShellOutput {
    return formatShellOutputWithStatus(allocator, io, raw_output, exit_code, null, "(no output)");
}

fn formatShellOutputWithStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    raw_output: []const u8,
    exit_code: ?u8,
    status_message: ?[]const u8,
    empty_text: []const u8,
) !ShellOutput {
    const sanitized_output = try sanitizeShellOutput(allocator, raw_output);
    defer allocator.free(sanitized_output);

    const truncation = try truncateTail(allocator, sanitized_output, default_bash_max_lines, default_bash_max_bytes);
    defer allocator.free(truncation.content);

    if (truncation.truncated) try writeFile(io, bash_full_output_path, sanitized_output);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    if (truncation.content.len > 0) {
        try out.writer.writeAll(truncation.content);
    } else if (empty_text.len > 0 and (exit_code == null or exit_code.? == 0)) {
        try out.writer.writeAll(empty_text);
    }

    if (truncation.truncated) {
        if (out.written().len > 0) try out.writer.writeAll("\n\n");
        if (truncation.last_line_partial) {
            const last_line_size = bytesForLastLine(sanitized_output);
            try out.writer.writeAll("[Showing last ");
            try writeSize(&out.writer, truncation.output_bytes);
            try out.writer.print(" of line {d} (line is ", .{truncation.total_lines});
            try writeSize(&out.writer, last_line_size);
            try out.writer.print("). Full output: {s}]", .{bash_full_output_path});
        } else {
            const start_line = truncation.total_lines - truncation.output_lines + 1;
            const end_line = truncation.total_lines;
            if (truncation.truncated_by == .lines) {
                try out.writer.print("[Showing lines {d}-{d} of {d}. Full output: {s}]", .{ start_line, end_line, truncation.total_lines, bash_full_output_path });
            } else {
                try out.writer.print("[Showing lines {d}-{d} of {d} (", .{ start_line, end_line, truncation.total_lines });
                try writeSize(&out.writer, default_bash_max_bytes);
                try out.writer.print(" limit). Full output: {s}]", .{bash_full_output_path});
            }
        }
    }

    if (status_message) |message| {
        if (out.written().len > 0) try out.writer.writeAll("\n\n");
        try out.writer.writeAll(message);
    } else if (exit_code) |code| {
        if (code != 0) {
            if (out.written().len > 0) try out.writer.writeAll("\n\n");
            try out.writer.print("Command exited with code {d}", .{code});
        }
    } else {
        if (out.written().len > 0) try out.writer.writeAll("\n\n");
        try out.writer.writeAll("Command exited without status");
    }

    return .{
        .output = try out.toOwnedSlice(),
        .truncated = truncation.truncated,
        .full_output_path = if (truncation.truncated) bash_full_output_path else null,
        .truncation = shellTruncationDetails(truncation, default_bash_max_lines, default_bash_max_bytes),
    };
}

fn shellReadTimeout(io: std.Io, started_ms: i64, options: ShellCaptureOptions) std.Io.Timeout {
    const needs_cancel_poll = options.should_cancel != null and options.cancellation_context != null;
    if (!needs_cancel_poll and (options.timeout_ms == null or options.timeout_ms.? <= 0)) return .none;

    var wait_ms: i64 = if (needs_cancel_poll) if (options.cancellation_poll_ms <= 0) 100 else options.cancellation_poll_ms else std.math.maxInt(i64);
    if (options.timeout_ms) |timeout_ms| {
        if (timeout_ms > 0) {
            const elapsed_ms = @max(@as(i64, 0), nowMilliseconds(io) - started_ms);
            const remaining_ms = timeout_ms - elapsed_ms;
            if (remaining_ms <= 0) wait_ms = 1 else wait_ms = @min(wait_ms, remaining_ms);
        }
    }
    const duration: std.Io.Clock.Duration = .{
        .raw = .fromMilliseconds(wait_ms),
        .clock = .awake,
    };
    return .{ .duration = duration };
}

fn shellTimedOut(io: std.Io, started_ms: i64, maybe_timeout_ms: ?i64) bool {
    const timeout_ms = maybe_timeout_ms orelse return false;
    if (timeout_ms <= 0) return false;
    return nowMilliseconds(io) - started_ms >= timeout_ms;
}

fn shouldCancelShell(options: ShellCaptureOptions) bool {
    const callback = options.should_cancel orelse return false;
    const context = options.cancellation_context orelse return false;
    return callback(context);
}

fn shellProcessGroupId() ?std.posix.pid_t {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    return 0;
}

fn killShellChildTree(io: std.Io, child: *std.process.Child) void {
    terminateShellProcessGroup(child);
    child.kill(io);
}

fn terminateShellProcessGroup(child: *std.process.Child) void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const pid = child.id orelse return;
    if (pid <= 0) return;
    std.posix.kill(-pid, .TERM) catch {};
}

fn timeoutStatusMessage(allocator: std.mem.Allocator, timeout_ms: i64) ![]u8 {
    const whole_seconds = @divTrunc(timeout_ms, 1000);
    const fractional_ms = @mod(timeout_ms, 1000);
    if (fractional_ms == 0) {
        return std.fmt.allocPrint(allocator, "Command timed out after {d} seconds", .{whole_seconds});
    }
    const hundreds: u8 = @intCast(@divTrunc(fractional_ms, 100));
    const tens: u8 = @intCast(@divTrunc(@mod(fractional_ms, 100), 10));
    const ones: u8 = @intCast(@mod(fractional_ms, 10));
    const fractional_digits = [_]u8{
        '0' + hundreds,
        '0' + tens,
        '0' + ones,
    };
    return std.fmt.allocPrint(allocator, "Command timed out after {d}.{s} seconds", .{ whole_seconds, &fractional_digits });
}

fn formatShellOutputSnapshot(allocator: std.mem.Allocator, io: std.Io, raw_output: []const u8) !ShellOutput {
    const sanitized_output = try sanitizeShellOutput(allocator, raw_output);
    defer allocator.free(sanitized_output);

    const truncation = try truncateTail(allocator, sanitized_output, default_bash_max_lines, default_bash_max_bytes);
    defer allocator.free(truncation.content);

    if (truncation.truncated) try writeFile(io, bash_full_output_path, sanitized_output);

    return .{
        .output = try allocator.dupe(u8, truncation.content),
        .truncated = truncation.truncated,
        .full_output_path = if (truncation.truncated) bash_full_output_path else null,
        .truncation = shellTruncationDetails(truncation, default_bash_max_lines, default_bash_max_bytes),
    };
}

fn shellTruncationDetails(truncation: Truncation, max_lines: usize, max_bytes: usize) ?ShellTruncationDetails {
    if (!truncation.truncated) return null;
    return .{
        .truncated_by = switch (truncation.truncated_by) {
            .lines => .lines,
            .bytes => .bytes,
            .none => null,
        },
        .total_lines = truncation.total_lines,
        .total_bytes = truncation.total_bytes,
        .output_lines = truncation.output_lines,
        .output_bytes = truncation.output_bytes,
        .last_line_partial = truncation.last_line_partial,
        .first_line_exceeds_limit = truncation.first_line_exceeds_limit,
        .max_lines = max_lines,
        .max_bytes = max_bytes,
    };
}

fn combineShellOutput(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8) ![]u8 {
    const raw_output = try allocator.alloc(u8, stdout.len + stderr.len);
    @memcpy(raw_output[0..stdout.len], stdout);
    @memcpy(raw_output[stdout.len..], stderr);
    return raw_output;
}

fn sanitizeShellOutput(allocator: std.mem.Allocator, raw_output: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var index: usize = 0;
    while (index < raw_output.len) {
        const byte = raw_output[index];
        if (byte == 0x1b) {
            index = skipAnsiEscape(raw_output, index + 1);
            continue;
        }
        if (byte == 0x9b) {
            index = skipAnsiCsi(raw_output, index + 1);
            continue;
        }
        if (isUtf8InterlinearAnnotation(raw_output, index)) {
            index += 3;
            continue;
        }

        index += 1;
        if (byte == '\r') continue;
        if (byte < 0x20 and byte != '\n' and byte != '\t') continue;
        if (byte >= 0x80 and byte <= 0x9f) continue;
        try out.writer.writeByte(byte);
    }
    return out.toOwnedSlice();
}

fn skipAnsiEscape(bytes: []const u8, start: usize) usize {
    if (start >= bytes.len) return start;
    if (bytes[start] == ']') return skipAnsiOsc(bytes, start + 1);
    if (bytes[start] == '[') return skipAnsiCsi(bytes, start + 1);
    return skipAnsiCsi(bytes, start);
}

fn skipAnsiOsc(bytes: []const u8, start: usize) usize {
    var index = start;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] == 0x07) return index + 1;
        if (bytes[index] == 0x9c) return index + 1;
        if (bytes[index] == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '\\') return index + 2;
    }
    return index;
}

fn skipAnsiCsi(bytes: []const u8, start: usize) usize {
    var index = start;
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (byte >= 0x40 and byte <= 0x7e) return index + 1;
    }
    return index;
}

fn isUtf8InterlinearAnnotation(bytes: []const u8, index: usize) bool {
    if (index + 2 >= bytes.len) return false;
    return bytes[index] == 0xef and bytes[index + 1] == 0xbf and bytes[index + 2] >= 0xb9 and bytes[index + 2] <= 0xbb;
}

const ResolvedShellCommand = struct {
    command: []const u8,
    owned: bool = false,

    fn deinit(self: ResolvedShellCommand, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.command);
    }
};

fn prefixedShellCommand(allocator: std.mem.Allocator, command: []const u8, maybe_prefix: ?[]const u8) !ResolvedShellCommand {
    const prefix = std.mem.trim(u8, maybe_prefix orelse return .{ .command = command }, " \t\r\n");
    if (prefix.len == 0) return .{ .command = command };
    return .{
        .command = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ prefix, command }),
        .owned = true,
    };
}

fn stderrMergedShellCommand(allocator: std.mem.Allocator, command: []const u8) !ResolvedShellCommand {
    return .{
        .command = try std.fmt.allocPrint(allocator, "exec 2>&1\n{s}", .{command}),
        .owned = true,
    };
}

fn resolveShellPath(io: std.Io, custom_shell_path: ?[]const u8) ![]const u8 {
    if (custom_shell_path) |path| {
        try validateShellPath(io, path);
        return path;
    }

    if (comptime builtin.os.tag == .windows) return "bash.exe";
    if (absolutePathExists(io, "/bin/bash")) return "/bin/bash";
    return "sh";
}

fn validateShellPath(io: std.Io, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        if (absolutePathExists(io, path)) return;
    } else if (relativePathExists(io, path)) {
        return;
    }
    return error.ShellPathNotFound;
}

fn absolutePathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn relativePathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn emitShellUpdateSnapshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
    options: ShellCaptureOptions,
) !void {
    const callback = options.on_update orelse return;
    const context = options.update_context orelse return;

    const raw_output = try combineShellOutput(allocator, stdout, stderr);
    defer allocator.free(raw_output);
    const snapshot = try formatShellOutputSnapshot(allocator, io, raw_output);
    defer allocator.free(snapshot.output);

    try callback(context, .{
        .output = snapshot.output,
        .truncated = snapshot.truncated,
        .full_output_path = snapshot.full_output_path,
        .truncation = snapshot.truncation,
    });
}

fn shouldEmitShellUpdate(
    io: std.Io,
    output_len: usize,
    last_update_len: usize,
    last_update_ms: ?i64,
    options: ShellCaptureOptions,
) bool {
    if (output_len == 0 or options.on_update == null or options.update_context == null) return false;
    if (last_update_ms == null) return true;
    const min_bytes = if (options.update_min_bytes == 0) 1 else options.update_min_bytes;
    if (output_len >= last_update_len and output_len - last_update_len >= min_bytes) return true;
    const throttle_ms = if (options.update_throttle_ms <= 0) 1 else options.update_throttle_ms;
    return nowMilliseconds(io) - last_update_ms.? >= throttle_ms;
}

fn nowMilliseconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn truncateHead(allocator: std.mem.Allocator, content: []const u8, max_lines: usize, max_bytes: usize) !Truncation {
    const total_lines = countOutputLines(content);
    if (total_lines <= max_lines and content.len <= max_bytes) {
        return .{
            .content = try allocator.dupe(u8, content),
            .truncated = false,
            .truncated_by = .none,
            .output_lines = total_lines,
            .total_lines = total_lines,
            .total_bytes = content.len,
            .output_bytes = content.len,
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
                    .total_lines = total_lines,
                    .total_bytes = content.len,
                    .output_bytes = 0,
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
        .total_lines = total_lines,
        .total_bytes = content.len,
        .output_bytes = out.written().len,
    };
}

fn truncateTail(allocator: std.mem.Allocator, content: []const u8, max_lines: usize, max_bytes: usize) !Truncation {
    const total_lines = countLogicalLines(content);
    const total_bytes = content.len;
    if (total_lines <= max_lines and total_bytes <= max_bytes) {
        return .{
            .content = try allocator.dupe(u8, trimTrailingNewline(content)),
            .truncated = false,
            .truncated_by = .none,
            .output_lines = total_lines,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_bytes = trimTrailingNewline(content).len,
        };
    }

    const content_end = trimTrailingNewline(content).len;
    var scan_end = content_end;
    var start = content_end;
    var output_lines: usize = 0;
    var output_bytes: usize = 0;
    var truncated_by: TruncatedBy = .lines;
    var last_line_partial = false;

    while (scan_end > 0 and output_lines < max_lines) {
        var line_start = scan_end;
        while (line_start > 0 and content[line_start - 1] != '\n') : (line_start -= 1) {}
        const line_len = scan_end - line_start;
        const separator_len: usize = if (output_lines == 0) 0 else 1;
        if (output_bytes + line_len + separator_len > max_bytes) {
            truncated_by = .bytes;
            if (output_lines == 0) {
                const slice_start = if (line_len > max_bytes) scan_end - max_bytes else line_start;
                start = slice_start;
                output_bytes = scan_end - slice_start;
                output_lines = 1;
                last_line_partial = line_len > max_bytes;
            }
            break;
        }

        start = line_start;
        output_bytes += line_len + separator_len;
        output_lines += 1;
        if (line_start == 0) break;
        scan_end = line_start - 1;
    }
    if (output_lines >= max_lines and total_lines > max_lines and truncated_by != .bytes) truncated_by = .lines;

    return .{
        .content = try allocator.dupe(u8, content[start..content_end]),
        .truncated = true,
        .truncated_by = truncated_by,
        .output_lines = output_lines,
        .total_lines = total_lines,
        .total_bytes = total_bytes,
        .output_bytes = output_bytes,
        .last_line_partial = last_line_partial,
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

fn countLogicalLines(content: []const u8) usize {
    const trimmed = trimTrailingNewline(content);
    if (trimmed.len == 0) return 0;
    return std.mem.count(u8, trimmed, "\n") + 1;
}

fn trimTrailingNewline(content: []const u8) []const u8 {
    if (content.len > 0 and content[content.len - 1] == '\n') return content[0 .. content.len - 1];
    return content;
}

fn bytesForLine(content: []const u8, target_line: usize) usize {
    var iter = std.mem.splitScalar(u8, content, '\n');
    var line_index: usize = 0;
    while (iter.next()) |line| : (line_index += 1) {
        if (line_index == target_line) return line.len;
    }
    return 0;
}

fn bytesForLastLine(content: []const u8) usize {
    const trimmed = trimTrailingNewline(content);
    if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |idx| return trimmed.len - idx - 1;
    return trimmed.len;
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

fn loadFindIgnoreRules(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8) !std.ArrayList(FindIgnoreRule) {
    var rules: std.ArrayList(FindIgnoreRule) = .empty;
    errdefer deinitFindIgnoreRules(allocator, &rules);

    var dir = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var sequence: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and shouldSkipFindDir(entry.basename)) {
            walker.leave(io);
            continue;
        }
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, ".gitignore")) continue;
        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        defer allocator.free(full_path);
        const base = std.fs.path.dirname(entry.path) orelse "";
        try appendFindIgnoreFile(io, allocator, &rules, full_path, base, &sequence);
    }
    std.mem.sort(FindIgnoreRule, rules.items, {}, lessThanFindIgnoreRule);
    return rules;
}

fn appendFindIgnoreFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    rules: *std.ArrayList(FindIgnoreRule),
    file_path: []const u8,
    base: []const u8,
    sequence: *usize,
) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(128 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, stripTrailingCarriageReturn(raw_line), " \t");
        if (line.len == 0 or line[0] == '#') continue;

        var negated = false;
        if (line[0] == '!') {
            negated = true;
            line = line[1..];
        }
        if (line.len == 0) continue;

        var anchored = false;
        if (line[0] == '/') {
            anchored = true;
            line = line[1..];
        }

        var dir_only = false;
        while (line.len > 0 and line[line.len - 1] == '/') {
            dir_only = true;
            line = line[0 .. line.len - 1];
        }
        if (line.len == 0) continue;

        const owned_base = try allocator.dupe(u8, base);
        errdefer allocator.free(owned_base);
        const owned_pattern = try allocator.dupe(u8, line);
        errdefer allocator.free(owned_pattern);

        try rules.append(allocator, .{
            .base = owned_base,
            .pattern = owned_pattern,
            .negated = negated,
            .dir_only = dir_only,
            .anchored = anchored,
            .has_slash = hasSlash(line),
            .sequence = sequence.*,
        });
        sequence.* += 1;
    }
}

fn deinitFindIgnoreRules(allocator: std.mem.Allocator, rules: *std.ArrayList(FindIgnoreRule)) void {
    for (rules.items) |rule| {
        allocator.free(rule.base);
        allocator.free(rule.pattern);
    }
    rules.deinit(allocator);
}

fn lessThanFindIgnoreRule(_: void, left: FindIgnoreRule, right: FindIgnoreRule) bool {
    const left_depth = pathDepth(left.base);
    const right_depth = pathDepth(right.base);
    if (left_depth != right_depth) return left_depth < right_depth;
    return left.sequence < right.sequence;
}

fn pathDepth(path: []const u8) usize {
    if (path.len == 0) return 0;
    return std.mem.count(u8, path, "/") + 1;
}

fn isFindIgnored(rules: []const FindIgnoreRule, path: []const u8, is_dir: bool) bool {
    var ignored = false;
    for (rules) |rule| {
        const scoped = scopedIgnorePath(rule.base, path) orelse continue;
        if (!matchesIgnoreRule(rule, scoped, is_dir)) continue;
        ignored = !rule.negated;
    }
    return ignored;
}

fn scopedIgnorePath(base: []const u8, path: []const u8) ?[]const u8 {
    if (base.len == 0) return path;
    if (std.mem.eql(u8, path, base)) return "";
    if (std.mem.startsWith(u8, path, base) and path.len > base.len and path[base.len] == '/') {
        return path[base.len + 1 ..];
    }
    return null;
}

fn matchesIgnoreRule(rule: FindIgnoreRule, scoped_path: []const u8, is_dir: bool) bool {
    if (scoped_path.len == 0) return false;
    if (!rule.dir_only) return matchesIgnorePattern(rule, scoped_path);

    if (is_dir and matchesIgnorePattern(rule, scoped_path)) return true;
    var end: usize = 0;
    while (end < scoped_path.len) : (end += 1) {
        if (scoped_path[end] != '/') continue;
        if (matchesIgnorePattern(rule, scoped_path[0..end])) return true;
    }
    return false;
}

fn matchesIgnorePattern(rule: FindIgnoreRule, candidate: []const u8) bool {
    if (rule.anchored or rule.has_slash) return wildcardMatch(rule.pattern, candidate);
    return wildcardMatch(rule.pattern, basename(candidate));
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
    if (pattern.len == 0) return text.len == 0;

    if (std.mem.startsWith(u8, pattern, "**/")) {
        const rest = pattern[3..];
        if (wildcardMatch(rest, text)) return true;
        for (text, 0..) |byte, index| {
            if (byte == '/' and wildcardMatch(rest, text[index + 1 ..])) return true;
        }
        return false;
    }

    if (std.mem.startsWith(u8, pattern, "**")) {
        var rest_start: usize = 2;
        while (rest_start < pattern.len and pattern[rest_start] == '*') rest_start += 1;
        const rest = pattern[rest_start..];
        if (rest.len == 0) return true;
        var index: usize = 0;
        while (index <= text.len) : (index += 1) {
            if (wildcardMatch(rest, text[index..])) return true;
        }
        return false;
    }

    if (pattern[0] == '*') {
        var rest_start: usize = 1;
        while (rest_start < pattern.len and pattern[rest_start] == '*') rest_start += 1;
        const rest = pattern[rest_start..];
        if (rest.len == 0) return std.mem.indexOfScalar(u8, text, '/') == null;

        var index: usize = 0;
        while (index <= text.len) : (index += 1) {
            if (index > 0 and text[index - 1] == '/') break;
            if (wildcardMatch(rest, text[index..])) return true;
        }
        return false;
    }

    if (text.len == 0) return false;
    if (pattern[0] == '?' or pattern[0] == text[0]) return wildcardMatch(pattern[1..], text[1..]);
    return false;
}

fn writePosixPath(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        try w.writeByte(if (byte == '\\') '/' else byte);
    }
}

test "glob matching supports basename and path suffix patterns" {
    try std.testing.expect(matchesGlob("*.zig", "src/pi/tools.zig"));
    try std.testing.expect(matchesGlob("src/*.tsx", "frontend/src/main.tsx"));
    try std.testing.expect(matchesGlob("src/**/*.tsx", "frontend/src/main.tsx"));
    try std.testing.expect(matchesGlob("src/**/*.tsx", "frontend/src/routes/main.tsx"));
    try std.testing.expect(!matchesGlob("src/*.tsx", "frontend/src/routes/main.tsx"));
    try std.testing.expect(!matchesGlob("*.md", "src/main.zig"));
}

test "wildcard matching is deterministic" {
    try std.testing.expect(wildcardMatch("src/**/*.zig", "src/pi/tools.zig"));
    try std.testing.expect(wildcardMatch("README.*", "README.md"));
    try std.testing.expect(!wildcardMatch("README.?", "README.md"));
}

test "bash output sanitizes ansi carriage returns and control bytes" {
    const result = try runShellCapture(std.testing.io, std.testing.allocator, "printf '\\033[31mred\\033[0m\\r\\nbad\\001ok'");
    defer std.testing.allocator.free(result.output);

    try std.testing.expectEqualStrings("red\nbadok", result.output);
}

test "bash output preserves stdout stderr write order" {
    const result = try runShellCapture(std.testing.io, std.testing.allocator, "printf out; printf err >&2; printf done");
    defer std.testing.allocator.free(result.output);

    try std.testing.expectEqualStrings("outerrdone", result.output);
}

test "bash output update path preserves stdout stderr write order" {
    const result = try runShellCaptureWithUpdates(std.testing.io, std.testing.allocator, "printf out; printf err >&2; printf done", .{});
    defer std.testing.allocator.free(result.output);

    try std.testing.expectEqualStrings("outerrdone", result.output);
}

test "shell path resolution validates custom paths and prefers bash on unix" {
    try std.testing.expectError(error.ShellPathNotFound, validateShellPath(std.testing.io, "zig-out/pi-zig-missing-shell"));

    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        if (absolutePathExists(std.testing.io, "/bin/bash")) {
            try std.testing.expectEqualStrings("/bin/bash", try resolveShellPath(std.testing.io, null));
        }
    }
}

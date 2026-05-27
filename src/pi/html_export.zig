//! Session HTML export.
//!
//! Renders a session JSONL file (the upstream `~/.pi/agent/sessions/.../<id>.jsonl`
//! format) into a single self-contained HTML document.
//!
//! Upstream parity reference:
//!   upstream/pi/packages/coding-agent/src/core/export-html/index.ts (exportFromFile)
//!   upstream/pi/packages/coding-agent/src/core/export-html/template.js (renderEntry, renderToolCall)
//!
//! Upstream ships a client-side single-page app (template.js, ~74 KB) that base64-encodes
//! the session entries and renders them in the browser with marked + highlight.js. A faithful
//! Zig port renders the same *content* deterministically on the server: every supported entry
//! and message type, with identical HTML escaping (escapeHtml) and image data-URI handling.
//!
//! Content semantics mirrored from template.js `renderEntry`:
//!   - user message: text + inline images (message-image, data:<mime>;base64,<data>)
//!   - assistant message: text blocks, thinking blocks, then toolCall blocks; abort/error notes
//!   - toolResult message: not rendered standalone (attached to its tool call), matching
//!     `if (msg.role === 'toolResult') return ''`
//!   - bashExecution: `$ command`, output, cancelled/exit-code note
//!   - model_change / thinking_level_change: muted info line
//!   - compaction: "Compacted from N tokens" + summary
//!   - branch_summary: header + summary
//!   - custom_message (display only): `[customType]` + content
//!   - custom / label / session_info: not rendered in the message pane (state/metadata)

const std = @import("std");

const max_session_file_bytes = 16 * 1024 * 1024;

/// Render a parsed session file into HTML and write it to `output_path`.
/// Returns an owned copy of the resolved output path (caller frees).
pub fn exportHtmlFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    input_path: []const u8,
    requested_output_path: ?[]const u8,
) ![]u8 {
    const output_path = if (requested_output_path) |path|
        try allocator.dupe(u8, path)
    else
        try defaultExportPath(allocator, input_path);
    errdefer allocator.free(output_path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .limited(max_session_file_bytes));
    defer allocator.free(bytes);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderSessionHtml(allocator, &out.writer, bytes, input_path);

    try ensureParentDir(io, output_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = out.written() });
    return output_path;
}

/// Render session JSONL `bytes` into an HTML document written to `w`.
/// `source_label` is shown in the header (typically the session file path).
///
/// Mirrors upstream `exportFromFile` -> `generateHtml` -> client render: parse entries
/// (skipping malformed lines), require a valid `session` header, then render every entry.
pub fn renderSessionHtml(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    bytes: []const u8,
    source_label: []const u8,
) !void {
    // Parse all entries. Matches upstream loadEntriesFromFile: skip malformed/blank lines,
    // require the first non-blank line to be a `session` header with a string id.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var entries: std.ArrayList(std.json.Value) = .empty;
    var header: ?std.json.ObjectMap = null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var saw_header = false;
    while (lines.next()) |raw_line| {
        const line = stripTrailingCarriageReturn(raw_line);
        if (std.mem.trim(u8, line, " \t").len == 0) continue;

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (parsed != .object) continue;
        const object = parsed.object;
        const entry_type = getStringField(object, "type") orelse continue;

        if (!saw_header) {
            if (!std.mem.eql(u8, entry_type, "session")) return error.InvalidSessionHeader;
            if (getStringField(object, "id") == null) return error.InvalidSessionHeader;
            header = object;
            saw_header = true;
            continue;
        }
        try entries.append(arena, parsed);
    }
    if (!saw_header) return error.InvalidSessionHeader;

    // Index tool results by toolCallId so assistant tool calls can render their result inline,
    // matching template.js findToolResult().
    var tool_results = std.StringHashMap(std.json.ObjectMap).init(arena);
    for (entries.items) |entry| {
        const object = entry.object;
        const entry_type = getStringField(object, "type") orelse continue;
        if (!std.mem.eql(u8, entry_type, "message")) continue;
        const message = object.get("message") orelse continue;
        if (message != .object) continue;
        const role = getStringField(message.object, "role") orelse continue;
        if (!std.mem.eql(u8, role, "toolResult") and !std.mem.eql(u8, role, "tool")) continue;
        if (getStringField(message.object, "toolCallId")) |call_id| {
            try tool_results.put(call_id, message.object);
        }
    }

    try writeDocumentHead(w);
    try writeHeader(w, header, source_label, entries.items);

    try w.writeAll("<main id=\"messages\">");
    for (entries.items) |entry| {
        try renderEntry(w, entry.object, &tool_results);
    }
    try w.writeAll("</main>");
    try w.writeAll("</body></html>\n");
}

fn writeDocumentHead(w: *std.Io.Writer) !void {
    // Title intentionally contains "pi-zig session" for downstream smoke assertions.
    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">");
    try w.writeAll("<title>pi-zig session</title>");
    try w.writeAll("<style>");
    try w.writeAll(style_css);
    try w.writeAll("</style></head><body>");
}

fn writeHeader(
    w: *std.Io.Writer,
    header: ?std.json.ObjectMap,
    source_label: []const u8,
    entries: []const std.json.Value,
) !void {
    var stats = Stats{};
    computeStats(entries, &stats);

    try w.writeAll("<header class=\"session-header\"><h1>pi-zig session: ");
    if (header) |h| {
        try writeHtmlEscaped(w, getStringField(h, "id") orelse "unknown");
    } else {
        try w.writeAll("unknown");
    }
    try w.writeAll("</h1>");

    try w.writeAll("<div class=\"info\"><span class=\"label\">Session file:</span> ");
    try writeHtmlEscaped(w, source_label);
    try w.writeAll("</div>");

    if (header) |h| {
        if (getStringField(h, "cwd")) |cwd| {
            try w.writeAll("<div class=\"info\"><span class=\"label\">cwd:</span> ");
            try writeHtmlEscaped(w, cwd);
            try w.writeAll("</div>");
        }
        if (getStringField(h, "parentSession")) |parent| {
            try w.writeAll("<div class=\"info\"><span class=\"label\">Forked from:</span> ");
            try writeHtmlEscaped(w, parent);
            try w.writeAll("</div>");
        }
    }

    try w.writeAll("<div class=\"info\"><span class=\"label\">Messages:</span> ");
    try w.print("{d} user, {d} assistant, {d} tool calls, {d} tool results", .{
        stats.user_messages,
        stats.assistant_messages,
        stats.tool_calls,
        stats.tool_results,
    });
    if (stats.compactions > 0) try w.print(", {d} compaction", .{stats.compactions});
    if (stats.branch_summaries > 0) try w.print(", {d} branch summary", .{stats.branch_summaries});
    try w.writeAll("</div></header>");
}

const Stats = struct {
    user_messages: usize = 0,
    assistant_messages: usize = 0,
    tool_calls: usize = 0,
    tool_results: usize = 0,
    compactions: usize = 0,
    branch_summaries: usize = 0,
};

fn computeStats(entries: []const std.json.Value, stats: *Stats) void {
    for (entries) |entry| {
        const object = entry.object;
        const entry_type = getStringField(object, "type") orelse continue;
        if (std.mem.eql(u8, entry_type, "message")) {
            const message = object.get("message") orelse continue;
            if (message != .object) continue;
            const role = getStringField(message.object, "role") orelse continue;
            if (std.mem.eql(u8, role, "user")) {
                stats.user_messages += 1;
            } else if (std.mem.eql(u8, role, "assistant")) {
                stats.assistant_messages += 1;
                stats.tool_calls += countAssistantToolCalls(message.object);
            } else if (std.mem.eql(u8, role, "toolResult") or std.mem.eql(u8, role, "tool")) {
                stats.tool_results += 1;
            }
        } else if (std.mem.eql(u8, entry_type, "compaction")) {
            stats.compactions += 1;
        } else if (std.mem.eql(u8, entry_type, "branch_summary")) {
            stats.branch_summaries += 1;
        }
    }
}

/// Render a single session entry. Mirrors template.js renderEntry() content semantics.
fn renderEntry(
    w: *std.Io.Writer,
    object: std.json.ObjectMap,
    tool_results: *std.StringHashMap(std.json.ObjectMap),
) !void {
    const entry_type = getStringField(object, "type") orelse return;
    const entry_id = getStringField(object, "id") orelse "";

    if (std.mem.eql(u8, entry_type, "message")) {
        const message = object.get("message") orelse return;
        if (message != .object) return;
        const role = getStringField(message.object, "role") orelse return;

        if (std.mem.eql(u8, role, "user")) {
            try w.writeAll("<article class=\"message user\" id=\"entry-");
            try writeHtmlEscaped(w, entry_id);
            try w.writeAll("\"><div class=\"role\">user</div>");
            try renderUserContent(w, message.object);
            try w.writeAll("</article>");
            return;
        }
        if (std.mem.eql(u8, role, "assistant")) {
            try w.writeAll("<article class=\"message assistant\" id=\"entry-");
            try writeHtmlEscaped(w, entry_id);
            try w.writeAll("\"><div class=\"role\">assistant</div>");
            try renderAssistantContent(w, message.object, tool_results);
            try w.writeAll("</article>");
            return;
        }
        if (std.mem.eql(u8, role, "bashExecution")) {
            try renderBashExecution(w, message.object, entry_id);
            return;
        }
        // toolResult: rendered inline with its tool call (template.js returns '' here).
        return;
    }

    if (std.mem.eql(u8, entry_type, "model_change")) {
        try w.writeAll("<div class=\"info-entry\">Switched to model: <span class=\"model-name\">");
        try writeHtmlEscaped(w, getStringField(object, "provider") orelse "");
        try w.writeByte('/');
        try writeHtmlEscaped(w, getStringField(object, "modelId") orelse "");
        try w.writeAll("</span></div>");
        return;
    }

    if (std.mem.eql(u8, entry_type, "thinking_level_change")) {
        try w.writeAll("<div class=\"info-entry\">Thinking level: <span class=\"model-name\">");
        try writeHtmlEscaped(w, getStringField(object, "thinkingLevel") orelse "");
        try w.writeAll("</span></div>");
        return;
    }

    if (std.mem.eql(u8, entry_type, "compaction")) {
        const tokens_before = getIntegerField(object, "tokensBefore") orelse 0;
        try w.writeAll("<div class=\"compaction\" id=\"entry-");
        try writeHtmlEscaped(w, entry_id);
        try w.writeAll("\"><div class=\"compaction-label\">[compaction]</div><div class=\"compaction-content\"><strong>Compacted from ");
        try w.print("{d}", .{tokens_before});
        try w.writeAll(" tokens</strong>\n\n<pre>");
        try writeHtmlEscaped(w, getStringField(object, "summary") orelse "");
        try w.writeAll("</pre></div></div>");
        return;
    }

    if (std.mem.eql(u8, entry_type, "branch_summary")) {
        try w.writeAll("<div class=\"branch-summary\" id=\"entry-");
        try writeHtmlEscaped(w, entry_id);
        try w.writeAll("\"><div class=\"branch-summary-header\">Branch Summary</div><pre>");
        try writeHtmlEscaped(w, getStringField(object, "summary") orelse "");
        try w.writeAll("</pre></div>");
        return;
    }

    if (std.mem.eql(u8, entry_type, "custom_message")) {
        // template.js renders custom_message only when display === true.
        const display = object.get("display");
        const shown = display != null and display.? == .bool and display.?.bool;
        if (!shown) return;
        try w.writeAll("<div class=\"hook-message\" id=\"entry-");
        try writeHtmlEscaped(w, entry_id);
        try w.writeAll("\"><div class=\"hook-type\">[");
        try writeHtmlEscaped(w, getStringField(object, "customType") orelse "");
        try w.writeAll("]</div>");
        try renderTextOrContentArray(w, object.get("content"));
        try w.writeAll("</div>");
        return;
    }

    // custom / label / session_info: state and metadata, not rendered in the message pane.
}

/// Render user message content: inline images then text. Mirrors template.js user branch.
fn renderUserContent(w: *std.Io.Writer, message: std.json.ObjectMap) !void {
    const content = message.get("content") orelse return;
    switch (content) {
        .string => |text| {
            if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
            try w.writeAll("<pre class=\"text\">");
            try writeHtmlEscaped(w, text);
            try w.writeAll("</pre>");
        },
        .array => |array| {
            try renderImages(w, array.items);
            try renderTextBlocks(w, array.items);
        },
        else => {},
    }
}

/// Render assistant content: text, thinking, then tool calls, then abort/error notes.
fn renderAssistantContent(
    w: *std.Io.Writer,
    message: std.json.ObjectMap,
    tool_results: *std.StringHashMap(std.json.ObjectMap),
) !void {
    const content = message.get("content") orelse return;
    if (content == .string) {
        if (std.mem.trim(u8, content.string, " \t\r\n").len != 0) {
            try w.writeAll("<pre class=\"text\">");
            try writeHtmlEscaped(w, content.string);
            try w.writeAll("</pre>");
        }
    } else if (content == .array) {
        // text + thinking first (template.js renders these before tool calls)
        for (content.array.items) |item| {
            if (item != .object) continue;
            const block_type = getStringField(item.object, "type") orelse continue;
            if (std.mem.eql(u8, block_type, "text")) {
                const text = getStringField(item.object, "text") orelse continue;
                if (std.mem.trim(u8, text, " \t\r\n").len == 0) continue;
                try w.writeAll("<pre class=\"text\">");
                try writeHtmlEscaped(w, text);
                try w.writeAll("</pre>");
            } else if (std.mem.eql(u8, block_type, "thinking")) {
                const thinking = getStringField(item.object, "thinking") orelse continue;
                if (std.mem.trim(u8, thinking, " \t\r\n").len == 0) continue;
                try w.writeAll("<div class=\"thinking-block\"><pre class=\"thinking-text\">");
                try writeHtmlEscaped(w, thinking);
                try w.writeAll("</pre></div>");
            }
        }
        // then tool calls
        for (content.array.items) |item| {
            if (item != .object) continue;
            const block_type = getStringField(item.object, "type") orelse continue;
            if (std.mem.eql(u8, block_type, "toolCall")) {
                try renderToolCall(w, item.object, tool_results);
            }
        }
    }

    // abort/error notes (template.js stopReason handling)
    if (getStringField(message, "stopReason")) |stop_reason| {
        if (std.mem.eql(u8, stop_reason, "aborted")) {
            try w.writeAll("<div class=\"error-text\">Aborted</div>");
        } else if (std.mem.eql(u8, stop_reason, "error")) {
            try w.writeAll("<div class=\"error-text\">Error: ");
            try writeHtmlEscaped(w, getStringField(message, "errorMessage") orelse "Unknown error");
            try w.writeAll("</div>");
        }
    }
}

/// Render a tool call block with its matched result inline. Mirrors template.js renderToolCall().
/// Standard tools (bash/read/write/edit/ls) get a structured header; others fall back to a JSON
/// argument dump, matching the upstream default branch.
fn renderToolCall(
    w: *std.Io.Writer,
    call: std.json.ObjectMap,
    tool_results: *std.StringHashMap(std.json.ObjectMap),
) !void {
    const name = getStringField(call, "name") orelse "tool";
    const call_id = getStringField(call, "id") orelse "";
    const result: ?std.json.ObjectMap = if (call_id.len > 0) tool_results.get(call_id) else null;

    const is_error = blk: {
        if (result) |r| {
            const e = r.get("isError");
            break :blk e != null and e.? == .bool and e.?.bool;
        }
        break :blk false;
    };
    const status_class = if (result == null) "pending" else if (is_error) "error" else "success";

    try w.writeAll("<div class=\"tool-execution ");
    try w.writeAll(status_class);
    try w.writeAll("\" id=\"tool-call-");
    try writeHtmlEscaped(w, call_id);
    try w.writeAll("\">");

    const args: ?std.json.ObjectMap = blk: {
        const a = call.get("arguments") orelse break :blk null;
        break :blk if (a == .object) a.object else null;
    };

    if (std.mem.eql(u8, name, "bash")) {
        try w.writeAll("<div class=\"tool-command\">$ ");
        try writeHtmlEscaped(w, argString(args, "command") orelse "...");
        try w.writeAll("</div>");
        try renderToolResultText(w, result);
    } else if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "write") or
        std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "ls"))
    {
        try w.writeAll("<div class=\"tool-header\"><span class=\"tool-name\">");
        try writeHtmlEscaped(w, name);
        try w.writeAll("</span> <span class=\"tool-path\">");
        const path_arg = argString(args, "file_path") orelse argString(args, "path");
        try writeHtmlEscaped(w, path_arg orelse "");
        try w.writeAll("</span></div>");
        try renderToolResultImages(w, result);
        try renderToolResultText(w, result);
    } else {
        // Default: dump JSON arguments, matching upstream fallback.
        try w.writeAll("<div class=\"tool-header\"><span class=\"tool-name\">");
        try writeHtmlEscaped(w, name);
        try w.writeAll("</span></div>");
        if (call.get("arguments")) |a| {
            try w.writeAll("<div class=\"tool-output\"><pre>");
            try writeJsonValueEscaped(w, a);
            try w.writeAll("</pre></div>");
        }
        try renderToolResultText(w, result);
    }

    try w.writeAll("</div>");
}

/// Append the text blocks of a tool result's content as preformatted output.
/// Mirrors template.js getResultText() + formatExpandableOutput().
fn renderToolResultText(w: *std.Io.Writer, result: ?std.json.ObjectMap) !void {
    const r = result orelse return;
    const content = r.get("content") orelse return;
    switch (content) {
        .string => |text| {
            if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
            try w.writeAll("<div class=\"tool-output\"><pre>");
            try writeHtmlEscaped(w, text);
            try w.writeAll("</pre></div>");
        },
        .array => |array| {
            var any = false;
            for (array.items) |item| {
                if (item != .object) continue;
                const block_type = getStringField(item.object, "type") orelse continue;
                if (!std.mem.eql(u8, block_type, "text")) continue;
                const text = getStringField(item.object, "text") orelse continue;
                if (!any) {
                    try w.writeAll("<div class=\"tool-output\"><pre>");
                    any = true;
                } else {
                    try w.writeByte('\n');
                }
                try writeHtmlEscaped(w, text);
            }
            if (any) try w.writeAll("</pre></div>");
        },
        else => {},
    }
}

fn renderToolResultImages(w: *std.Io.Writer, result: ?std.json.ObjectMap) !void {
    const r = result orelse return;
    const content = r.get("content") orelse return;
    if (content != .array) return;
    try renderImagesClass(w, content.array.items, "tool-images", "tool-image");
}

fn renderBashExecution(w: *std.Io.Writer, message: std.json.ObjectMap, entry_id: []const u8) !void {
    const cancelled = blk: {
        const c = message.get("cancelled");
        break :blk c != null and c.? == .bool and c.?.bool;
    };
    const exit_code: ?i64 = getIntegerField(message, "exitCode");
    const is_error = cancelled or (exit_code != null and exit_code.? != 0);

    try w.writeAll("<div class=\"tool-execution ");
    try w.writeAll(if (is_error) "error" else "success");
    try w.writeAll("\" id=\"entry-");
    try writeHtmlEscaped(w, entry_id);
    try w.writeAll("\"><div class=\"tool-command\">$ ");
    try writeHtmlEscaped(w, getStringField(message, "command") orelse "");
    try w.writeAll("</div>");

    if (getStringField(message, "output")) |output| {
        if (output.len > 0) {
            try w.writeAll("<div class=\"tool-output\"><pre>");
            try writeHtmlEscaped(w, output);
            try w.writeAll("</pre></div>");
        }
    }
    if (cancelled) {
        try w.writeAll("<div class=\"note warning\">(cancelled)</div>");
    } else if (exit_code != null and exit_code.? != 0) {
        try w.writeAll("<div class=\"note error\">(exit ");
        try w.print("{d}", .{exit_code.?});
        try w.writeAll(")</div>");
    }
    try w.writeAll("</div>");
}

fn renderTextOrContentArray(w: *std.Io.Writer, content: ?std.json.Value) !void {
    const value = content orelse return;
    switch (value) {
        .string => |text| {
            try w.writeAll("<pre class=\"text\">");
            try writeHtmlEscaped(w, text);
            try w.writeAll("</pre>");
        },
        .array => |array| {
            try renderImages(w, array.items);
            try renderTextBlocks(w, array.items);
        },
        else => {},
    }
}

fn renderTextBlocks(w: *std.Io.Writer, items: []const std.json.Value) !void {
    var any = false;
    for (items) |item| {
        if (item != .object) continue;
        const block_type = getStringField(item.object, "type") orelse continue;
        if (!std.mem.eql(u8, block_type, "text")) continue;
        const text = getStringField(item.object, "text") orelse continue;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) continue;
        if (!any) {
            try w.writeAll("<pre class=\"text\">");
            any = true;
        } else {
            try w.writeByte('\n');
        }
        try writeHtmlEscaped(w, text);
    }
    if (any) try w.writeAll("</pre>");
}

fn renderImages(w: *std.Io.Writer, items: []const std.json.Value) !void {
    try renderImagesClass(w, items, "message-images", "message-image");
}

fn renderImagesClass(
    w: *std.Io.Writer,
    items: []const std.json.Value,
    container_class: []const u8,
    image_class: []const u8,
) !void {
    var any = false;
    for (items) |item| {
        if (item != .object) continue;
        const block_type = getStringField(item.object, "type") orelse continue;
        if (!std.mem.eql(u8, block_type, "image")) continue;
        if (!any) {
            try w.writeAll("<div class=\"");
            try w.writeAll(container_class);
            try w.writeAll("\">");
            any = true;
        }
        // data:<mimeType>;base64,<data> — matches template.js image rendering.
        try w.writeAll("<img class=\"");
        try w.writeAll(image_class);
        try w.writeAll("\" src=\"data:");
        try writeHtmlEscaped(w, getStringField(item.object, "mimeType") orelse "image/png");
        try w.writeAll(";base64,");
        try writeHtmlEscaped(w, getStringField(item.object, "data") orelse "");
        try w.writeAll("\" alt=\"\" />");
    }
    if (any) try w.writeAll("</div>");
}

fn argString(args: ?std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const object = args orelse return null;
    return getStringField(object, name);
}

fn countAssistantToolCalls(object: std.json.ObjectMap) usize {
    const content = object.get("content") orelse return 0;
    if (content != .array) return 0;
    var count: usize = 0;
    for (content.array.items) |item| {
        if (item != .object) continue;
        const block_type = getStringField(item.object, "type") orelse continue;
        if (std.mem.eql(u8, block_type, "toolCall")) count += 1;
    }
    return count;
}

fn defaultExportPath(allocator: std.mem.Allocator, input_path: []const u8) ![]u8 {
    var base = std.fs.path.basename(input_path);
    if (std.mem.endsWith(u8, base, ".jsonl")) {
        base = base[0 .. base.len - ".jsonl".len];
    }
    return std.fmt.allocPrint(allocator, "pi-zig-session-{s}.html", .{base});
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn stripTrailingCarriageReturn(value: []const u8) []const u8 {
    if (value.len > 0 and value[value.len - 1] == '\r') return value[0 .. value.len - 1];
    return value;
}

fn getStringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const field = object.get(name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn getIntegerField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const field = object.get(name) orelse return null;
    return switch (field) {
        .integer => |value| value,
        .float => |value| @intFromFloat(value),
        else => null,
    };
}

/// Escape text for HTML body/attribute context. Matches template.js escapeHtml() exactly:
/// & < > " ' replaced with their entities.
fn writeHtmlEscaped(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(byte),
        }
    }
}

/// Serialize a JSON value compactly and HTML-escape it (for tool argument dumps).
fn writeJsonValueEscaped(w: *std.Io.Writer, value: std.json.Value) !void {
    var buffer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer buffer.deinit();
    std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &buffer.writer) catch {
        return;
    };
    try writeHtmlEscaped(w, buffer.written());
}

const style_css =
    "body{font-family:system-ui,-apple-system,sans-serif;margin:0;padding:0;background:#181820;color:#e8e8ec;line-height:1.5}" ++
    ".session-header{padding:20px 32px;background:#1e1e24;border-bottom:1px solid #33333c}" ++
    ".session-header h1{margin:0 0 8px;font-size:18px}" ++
    ".session-header .info{font-size:13px;color:#a0a0aa;margin:2px 0}" ++
    ".session-header .label{color:#7a7a85}" ++
    "#messages{max-width:900px;margin:0 auto;padding:24px 32px}" ++
    ".message{border:1px solid #33333c;border-radius:8px;padding:12px 16px;margin:12px 0;background:#1e1e24}" ++
    ".message.user{background:#23252e}" ++
    ".message .role{font-weight:600;font-size:12px;text-transform:uppercase;color:#8a8a95;margin-bottom:6px}" ++
    "pre{white-space:pre-wrap;word-break:break-word;margin:0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px}" ++
    "pre.text{font-family:inherit;font-size:14px}" ++
    ".thinking-block{border-left:3px solid #55556a;padding-left:10px;margin:8px 0;color:#9a9aa5;font-style:italic}" ++
    ".tool-execution{border:1px solid #33333c;border-radius:6px;margin:8px 0;padding:8px 10px;background:#16161c}" ++
    ".tool-execution.error{border-color:#a04040}" ++
    ".tool-execution.success{border-color:#3a5a3a}" ++
    ".tool-command{font-family:ui-monospace,monospace;font-size:13px;color:#c8c8d0}" ++
    ".tool-header .tool-name{font-weight:600;color:#7aa0d0}" ++
    ".tool-header .tool-path{color:#a0a0aa}" ++
    ".tool-output{margin-top:6px;color:#b8b8c0}" ++
    ".note.warning{color:#d0a040}.note.error{color:#d06060}" ++
    ".error-text{color:#d06060;margin-top:6px}" ++
    ".info-entry{font-size:13px;color:#8a8a95;margin:8px 0;text-align:center}.model-name{color:#7aa0d0}" ++
    ".compaction,.branch-summary,.hook-message{border:1px dashed #55556a;border-radius:6px;padding:10px 12px;margin:12px 0;background:#1a1a22}" ++
    ".compaction-label,.branch-summary-header,.hook-type{font-weight:600;color:#9a9aaa;margin-bottom:6px}" ++
    ".message-images,.tool-images{display:flex;flex-wrap:wrap;gap:8px;margin:6px 0}" ++
    ".message-image,.tool-image{max-width:320px;max-height:320px;border:1px solid #33333c;border-radius:4px}";

test "renders header, user/assistant text and stats" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"sess-1\",\"timestamp\":\"t\",\"cwd\":\"/proj\"}\n" ++
        "{\"type\":\"message\",\"id\":\"m-1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"user\",\"content\":\"hello <world>\"}}\n" ++
        "{\"type\":\"message\",\"id\":\"m-2\",\"parentId\":\"m-1\",\"timestamp\":\"t\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hi & bye\"}]}}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "session.jsonl");
    const html = out.written();

    try std.testing.expect(std.mem.indexOf(u8, html, "pi-zig session: sess-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hello &lt;world&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hi &amp; bye") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "1 user, 1 assistant") != null);
    // The HTML escaping must not leak a raw < from message content.
    try std.testing.expect(std.mem.indexOf(u8, html, "hello <world>") == null);
}

test "renders tool call with matched result and skips standalone tool result" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\".\"}\n" ++
        "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"call_1\",\"name\":\"bash\",\"arguments\":{\"command\":\"echo hi\"}}]}}\n" ++
        "{\"type\":\"message\",\"id\":\"t1\",\"parentId\":\"a1\",\"timestamp\":\"t\",\"message\":{\"role\":\"toolResult\",\"toolCallId\":\"call_1\",\"toolName\":\"bash\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"isError\":false}}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "s.jsonl");
    const html = out.written();

    try std.testing.expect(std.mem.indexOf(u8, html, "$ echo hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "tool-call-call_1") != null);
    // result text rendered inline within the tool execution
    try std.testing.expect(std.mem.indexOf(u8, html, "tool-output") != null);
    // standalone tool result entry is NOT rendered as its own article
    try std.testing.expect(std.mem.indexOf(u8, html, "entry-t1") == null);
}

test "renders image as data uri, compaction, branch summary and custom_message display" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\".\"}\n" ++
        "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"data\":\"AAAB\",\"mimeType\":\"image/png\"},{\"type\":\"text\",\"text\":\"look\"}]}}\n" ++
        "{\"type\":\"compaction\",\"id\":\"c1\",\"parentId\":\"u1\",\"timestamp\":\"t\",\"summary\":\"did stuff\",\"firstKeptEntryId\":\"u1\",\"tokensBefore\":1234}\n" ++
        "{\"type\":\"branch_summary\",\"id\":\"b1\",\"parentId\":\"u1\",\"timestamp\":\"t\",\"fromId\":\"u1\",\"summary\":\"branch ctx\"}\n" ++
        "{\"type\":\"custom_message\",\"id\":\"cm1\",\"parentId\":\"b1\",\"timestamp\":\"t\",\"customType\":\"ext\",\"content\":\"injected\",\"display\":true}\n" ++
        "{\"type\":\"custom_message\",\"id\":\"cm2\",\"parentId\":\"cm1\",\"timestamp\":\"t\",\"customType\":\"ext\",\"content\":\"hidden\",\"display\":false}\n" ++
        "{\"type\":\"custom\",\"id\":\"x1\",\"parentId\":\"cm2\",\"timestamp\":\"t\",\"customType\":\"state\",\"data\":{\"k\":1}}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "s.jsonl");
    const html = out.written();

    try std.testing.expect(std.mem.indexOf(u8, html, "data:image/png;base64,AAAB") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Compacted from 1234 tokens") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "did stuff") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Branch Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "branch ctx") != null);
    // display:true custom_message is shown, display:false is hidden
    try std.testing.expect(std.mem.indexOf(u8, html, "injected") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hidden") == null);
    // custom (state) entry is not rendered in the message pane
    try std.testing.expect(std.mem.indexOf(u8, html, "entry-x1") == null);
}

test "rejects file without session header" {
    const bad =
        "{\"type\":\"message\",\"id\":\"m-1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"user\",\"content\":\"x\"}}\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidSessionHeader, renderSessionHtml(std.testing.allocator, &out.writer, bad, "bad.jsonl"));
}

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

    // Interactive-SPA-style layout: a sidebar navigation tree on the left and the
    // rendered message stream on the right. Both are server-rendered and deterministic;
    // a tiny inline script provides client-side text filtering (see search_script).
    try w.writeAll("<div id=\"app\">");

    try writeSidebar(w, entries.items);

    try w.writeAll("<main id=\"content\">");
    try writeHeader(w, header, source_label, entries.items);
    try w.writeAll("<div id=\"messages\">");
    for (entries.items) |entry| {
        try renderEntry(w, entry.object, &tool_results);
    }
    try w.writeAll("</div>"); // #messages
    try w.writeAll("</main>"); // #content

    try w.writeAll("</div>"); // #app

    try w.writeAll("<script>");
    try w.writeAll(search_script);
    try w.writeAll("</script>");
    try w.writeAll("</body></html>\n");
}

/// Render the left-hand sidebar navigation tree. Mirrors the *content* of upstream
/// template.js `renderTree()` + `getTreeNodeDisplayHtml()`: one node per visible entry,
/// with a role-prefixed, truncated/normalized label. Each node is an in-page anchor link
/// pointing at the entry's `id="entry-..."` / `id="tool-call-..."` element. The search box
/// and its script filter both the sidebar nodes and the rendered message entries.
fn writeSidebar(
    w: *std.Io.Writer,
    entries: []const std.json.Value,
) !void {
    try w.writeAll("<nav id=\"sidebar\" aria-label=\"Session navigation\">");
    try w.writeAll("<div class=\"sidebar-header\">");
    try w.writeAll("<div class=\"sidebar-title\">Session tree</div>");
    try w.writeAll("<input type=\"text\" class=\"sidebar-search\" id=\"tree-search\" placeholder=\"Search messages…\" aria-label=\"Search messages\">");
    try w.writeAll("</div>");
    try w.writeAll("<div class=\"tree-container\" id=\"tree-container\">");

    var count: usize = 0;
    for (entries) |entry| {
        if (try writeSidebarNode(w, entry.object)) count += 1;
    }

    try w.writeAll("</div>"); // .tree-container
    try w.writeAll("<div class=\"tree-status\" id=\"tree-status\">");
    try w.print("{d} entries", .{count});
    try w.writeAll("</div>");
    try w.writeAll("</nav>");
}

/// Render a single sidebar node as an anchor link, or return false if the entry has no
/// corresponding rendered element to link to (e.g. standalone tool results, custom/state
/// metadata, hidden custom_message). Mirrors the entry-visibility rules in renderEntry().
fn writeSidebarNode(
    w: *std.Io.Writer,
    object: std.json.ObjectMap,
) !bool {
    const entry_type = getStringField(object, "type") orelse return false;
    const entry_id = getStringField(object, "id") orelse "";

    // Determine the anchor target (the id of the rendered element) and a role class.
    // All rendered entries use the `entry-<id>` anchor prefix.
    const anchor: []const u8 = "entry-";
    var role_class: []const u8 = "tree-role-other";
    var prefix: []const u8 = "";

    if (std.mem.eql(u8, entry_type, "message")) {
        const message = object.get("message") orelse return false;
        if (message != .object) return false;
        const role = getStringField(message.object, "role") orelse return false;

        if (std.mem.eql(u8, role, "user")) {
            role_class = "tree-role-user";
            prefix = "user: ";
        } else if (std.mem.eql(u8, role, "assistant")) {
            role_class = "tree-role-assistant";
            prefix = "assistant: ";
        } else if (std.mem.eql(u8, role, "bashExecution")) {
            role_class = "tree-role-tool";
            prefix = "$ ";
        } else {
            // toolResult / tool: rendered inline with its tool call, no own anchor.
            return false;
        }
    } else if (std.mem.eql(u8, entry_type, "compaction")) {
        role_class = "tree-compaction";
        prefix = "compaction: ";
    } else if (std.mem.eql(u8, entry_type, "branch_summary")) {
        role_class = "tree-branch-summary";
        prefix = "branch summary: ";
    } else if (std.mem.eql(u8, entry_type, "custom_message")) {
        const display = object.get("display");
        const shown = display != null and display.? == .bool and display.?.bool;
        if (!shown) return false;
        role_class = "tree-custom";
        prefix = "[custom]: ";
    } else {
        // custom / label / session_info / model_change / thinking_level_change:
        // not rendered with an anchor id in the message pane.
        return false;
    }

    try w.writeAll("<a class=\"tree-node\" href=\"#");
    try w.writeAll(anchor);
    try writeHtmlEscaped(w, entry_id);
    try w.writeAll("\"><span class=\"tree-marker\">•</span><span class=\"tree-content ");
    try w.writeAll(role_class);
    try w.writeAll("\"><span class=\"tree-prefix\">");
    try writeHtmlEscaped(w, prefix);
    try w.writeAll("</span>");
    try writeSidebarLabel(w, entry_type, object);
    try w.writeAll("</span></a>");
    return true;
}

/// Write the truncated, single-line label text for a sidebar node. Mirrors the content
/// extraction in upstream getTreeNodeDisplayHtml() (normalize whitespace, truncate).
fn writeSidebarLabel(
    w: *std.Io.Writer,
    entry_type: []const u8,
    object: std.json.ObjectMap,
) !void {
    if (std.mem.eql(u8, entry_type, "message")) {
        const message = (object.get("message") orelse return).object;
        const text = extractFirstText(message.get("content"));
        try writeTruncatedNormalized(w, text);
        return;
    }
    if (std.mem.eql(u8, entry_type, "compaction")) {
        try writeTruncatedNormalized(w, getStringField(object, "summary") orelse "");
        return;
    }
    if (std.mem.eql(u8, entry_type, "branch_summary")) {
        try writeTruncatedNormalized(w, getStringField(object, "summary") orelse "");
        return;
    }
    if (std.mem.eql(u8, entry_type, "custom_message")) {
        try writeTruncatedNormalized(w, extractFirstText(object.get("content")));
        return;
    }
}

/// Extract a display string from a message/content value: the raw string, or the first
/// text block of a content array, else empty. Mirrors upstream extractContent() for the
/// label use-case (we only need leading text, not concatenated blocks).
fn extractFirstText(content: ?std.json.Value) []const u8 {
    const value = content orelse return "";
    switch (value) {
        .string => |text| return text,
        .array => |array| {
            for (array.items) |item| {
                if (item != .object) continue;
                const block_type = getStringField(item.object, "type") orelse continue;
                if (!std.mem.eql(u8, block_type, "text")) continue;
                return getStringField(item.object, "text") orelse continue;
            }
            return "";
        },
        else => return "",
    }
}

const sidebar_label_max = 64;

/// Write text with newlines/tabs collapsed to single spaces, leading/trailing whitespace
/// trimmed, and truncated to `sidebar_label_max` bytes with an ellipsis. HTML-escaped.
/// Mirrors upstream normalize() + truncate().
fn writeTruncatedNormalized(w: *std.Io.Writer, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var written: usize = 0;
    var prev_space = false;
    for (trimmed) |byte| {
        if (written >= sidebar_label_max) {
            try w.writeAll("…");
            return;
        }
        const is_space = byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
        if (is_space) {
            if (prev_space) continue;
            prev_space = true;
            try writeHtmlEscaped(w, " ");
        } else {
            prev_space = false;
            switch (byte) {
                '&' => try w.writeAll("&amp;"),
                '<' => try w.writeAll("&lt;"),
                '>' => try w.writeAll("&gt;"),
                '"' => try w.writeAll("&quot;"),
                '\'' => try w.writeAll("&#39;"),
                else => try w.writeByte(byte),
            }
        }
        written += 1;
    }
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
            try writeTimestamp(w, object);
            try renderUserContent(w, message.object);
            try w.writeAll("</article>");
            return;
        }
        if (std.mem.eql(u8, role, "assistant")) {
            try w.writeAll("<article class=\"message assistant\" id=\"entry-");
            try writeHtmlEscaped(w, entry_id);
            try w.writeAll("\"><div class=\"role\">assistant</div>");
            try writeTimestamp(w, object);
            try renderAssistantContent(w, message.object, tool_results);
            try w.writeAll("</article>");
            return;
        }
        if (std.mem.eql(u8, role, "bashExecution")) {
            try renderBashExecution(w, message.object, object, entry_id);
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
        try w.writeAll("\"><div class=\"compaction-label\">[compaction]</div>");
        try writeTimestamp(w, object);
        try w.writeAll("<div class=\"compaction-content\"><strong>Compacted from ");
        try w.print("{d}", .{tokens_before});
        try w.writeAll(" tokens</strong>\n\n<pre>");
        try writeHtmlEscaped(w, getStringField(object, "summary") orelse "");
        try w.writeAll("</pre></div></div>");
        return;
    }

    if (std.mem.eql(u8, entry_type, "branch_summary")) {
        try w.writeAll("<div class=\"branch-summary\" id=\"entry-");
        try writeHtmlEscaped(w, entry_id);
        try w.writeAll("\"><div class=\"branch-summary-header\">Branch Summary</div>");
        try writeTimestamp(w, object);
        try w.writeAll("<pre>");
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
        try writeTimestamp(w, object);
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
            try writeMessageText(w, text);
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
        try writeMessageText(w, content.string);
    } else if (content == .array) {
        // text + thinking first (template.js renders these before tool calls)
        for (content.array.items) |item| {
            if (item != .object) continue;
            const block_type = getStringField(item.object, "type") orelse continue;
            if (std.mem.eql(u8, block_type, "text")) {
                const text = getStringField(item.object, "text") orelse continue;
                try writeMessageText(w, text);
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

fn renderBashExecution(
    w: *std.Io.Writer,
    message: std.json.ObjectMap,
    object: std.json.ObjectMap,
    entry_id: []const u8,
) !void {
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
    try w.writeAll("\">");
    try writeTimestamp(w, object);
    try w.writeAll("<div class=\"tool-command\">$ ");
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
            try writeMessageText(w, text);
        },
        .array => |array| {
            try renderImages(w, array.items);
            try renderTextBlocks(w, array.items);
        },
        else => {},
    }
}

/// Render a block of message text, splitting out fenced code blocks. Prose runs are
/// emitted as `<pre class="text">` with INLINE MARKDOWN rendered (bold/italic/links/
/// inline-code); fenced regions (```lang ... ```) are emitted as
/// `<pre class="code-block"><code class="lang-<lang>">...</code></pre>` with a language
/// class hook and LIGHTWEIGHT, self-contained syntax tokenization (keyword/string/
/// comment/number class spans — no external deps, no CDN, no highlight.js). All text
/// is HTML-escaped through the shared helpers before any markup is added (no XSS).
fn writeMessageText(w: *std.Io.Writer, text: []const u8) !void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;

    var rest = text;
    while (rest.len > 0) {
        // Find the next fence opener at the start of a line.
        const fence = findFenceOpen(rest) orelse {
            try writeProse(w, rest);
            return;
        };
        // Emit any prose before the fence.
        if (fence.start > 0) try writeProse(w, rest[0..fence.start]);

        // The fence body begins after the opening fence line.
        const body = rest[fence.body_start..];
        // Find the closing fence (a line that is exactly ``` possibly with trailing ws).
        if (findFenceClose(body)) |close| {
            try writeCodeBlock(w, fence.lang, body[0..close.code_end]);
            rest = body[close.next_start..];
        } else {
            // Unterminated fence: render the remainder as a code block to end of input.
            try writeCodeBlock(w, fence.lang, body);
            return;
        }
    }
}

const FenceOpen = struct {
    start: usize, // index in slice where the fence line begins
    body_start: usize, // index where code body begins (after the opening line + newline)
    lang: []const u8, // language identifier after the opening ```
};

/// Locate the next line that starts with ``` (ignoring leading spaces). Returns the fence
/// position, the start of the code body, and the trimmed language hint.
fn findFenceOpen(text: []const u8) ?FenceOpen {
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_line_end = i == text.len or text[i] == '\n';
        if (!at_line_end) continue;
        const line = text[line_start..i];
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            const lang = std.mem.trim(u8, trimmed[3..], " \t\r");
            const body_start = if (i == text.len) text.len else i + 1;
            return .{ .start = line_start, .body_start = body_start, .lang = lang };
        }
        line_start = i + 1;
    }
    return null;
}

const FenceClose = struct {
    code_end: usize, // index in body where code content ends (before the closing line)
    next_start: usize, // index in body to resume scanning after the closing fence
};

/// Locate the closing ``` line within a fence body.
fn findFenceClose(body: []const u8) ?FenceClose {
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_line_end = i == body.len or body[i] == '\n';
        if (!at_line_end) continue;
        const line = body[line_start..i];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "```")) {
            // code content ends at the newline before this line (drop the trailing \n)
            const code_end = if (line_start == 0) 0 else line_start - 1;
            const next_start = if (i == body.len) body.len else i + 1;
            return .{ .code_end = code_end, .next_start = next_start };
        }
        line_start = i + 1;
    }
    return null;
}

/// Emit a prose run as `<pre class="text">` with inline markdown rendered
/// (skipping all-whitespace runs). The text keeps its original whitespace/newlines
/// (it sits in a `<pre>`); inline spans are layered on top.
fn writeProse(w: *std.Io.Writer, text: []const u8) !void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
    try w.writeAll("<pre class=\"text\">");
    try writeInlineMarkdown(w, text);
    try w.writeAll("</pre>");
}

/// Render inline markdown within a prose run. Supported, in scanning order:
///   - inline code:  `code`            -> <code class="inline-code">code</code>
///   - links:        [text](url)       -> <a href="url" ...>text</a> (url sanitized)
///   - bold:         **x** or __x__    -> <strong>x</strong>
///   - italic:       *x* or _x_        -> <em>x</em>
/// Everything is HTML-escaped via writeHtmlEscaped. Unterminated/!matching markers
/// are emitted as literal (escaped) text, so malformed markdown never corrupts the
/// document. Inline code spans are NOT re-parsed for other markdown (verbatim).
fn writeInlineMarkdown(w: *std.Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '`' => {
                // Inline code: run to the next backtick on the same prose run.
                if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close| {
                    try w.writeAll("<code class=\"inline-code\">");
                    try writeHtmlEscaped(w, text[i + 1 .. close]);
                    try w.writeAll("</code>");
                    i = close + 1;
                    continue;
                }
            },
            '[' => {
                // Link: [label](url). Both parts must be present and well-formed.
                if (parseInlineLink(text[i..])) |link| {
                    try w.writeAll("<a href=\"");
                    try writeSafeUrl(w, link.url);
                    try w.writeAll("\" rel=\"nofollow noopener\">");
                    // Labels may themselves contain inline markdown (excluding links).
                    try writeInlineEmphasis(w, link.label);
                    try w.writeAll("</a>");
                    i += link.consumed;
                    continue;
                }
            },
            '*', '_' => {
                if (parseEmphasis(text[i..], c)) |emph| {
                    try w.writeAll(if (emph.strong) "<strong>" else "<em>");
                    // Inner text may contain inline code / nested emphasis of the other kind.
                    try writeInlineEmphasis(w, emph.inner);
                    try w.writeAll(if (emph.strong) "</strong>" else "</em>");
                    i += emph.consumed;
                    continue;
                }
            },
            else => {},
        }
        try writeHtmlEscapedByte(w, c);
        i += 1;
    }
}

/// Like writeInlineMarkdown but for emphasis/code only (no links) — used for the
/// inner text of links and emphasis runs to avoid pathological nesting recursion
/// while still rendering bold/italic/code inside them.
fn writeInlineEmphasis(w: *std.Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '`' => {
                if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close| {
                    try w.writeAll("<code class=\"inline-code\">");
                    try writeHtmlEscaped(w, text[i + 1 .. close]);
                    try w.writeAll("</code>");
                    i = close + 1;
                    continue;
                }
            },
            '*', '_' => {
                if (parseEmphasis(text[i..], c)) |emph| {
                    try w.writeAll(if (emph.strong) "<strong>" else "<em>");
                    try writeHtmlEscaped(w, emph.inner);
                    try w.writeAll(if (emph.strong) "</strong>" else "</em>");
                    i += emph.consumed;
                    continue;
                }
            },
            else => {},
        }
        try writeHtmlEscapedByte(w, c);
        i += 1;
    }
}

const InlineLink = struct { label: []const u8, url: []const u8, consumed: usize };

/// Parse a `[label](url)` link at the start of `slice`. Returns null when the shape
/// is incomplete. Labels may not contain `]` and urls may not contain `)` or
/// whitespace (keeps the parser simple and avoids ambiguity).
fn parseInlineLink(slice: []const u8) ?InlineLink {
    if (slice.len == 0 or slice[0] != '[') return null;
    const label_end = std.mem.indexOfScalarPos(u8, slice, 1, ']') orelse return null;
    if (label_end + 1 >= slice.len or slice[label_end + 1] != '(') return null;
    const url_start = label_end + 2;
    const url_end = std.mem.indexOfScalarPos(u8, slice, url_start, ')') orelse return null;
    const url = slice[url_start..url_end];
    if (url.len == 0) return null;
    for (url) |b| if (b == ' ' or b == '\t' or b == '\n' or b == '\r') return null;
    return .{ .label = slice[1..label_end], .url = url, .consumed = url_end + 1 };
}

const Emphasis = struct { inner: []const u8, strong: bool, consumed: usize };

/// Parse a bold (`**`/`__`) or italic (`*`/`_`) run starting at `slice[0] == marker`.
/// Returns null when there is no matching closer or the run would be empty.
fn parseEmphasis(slice: []const u8, marker: u8) ?Emphasis {
    if (slice.len < 2 or slice[0] != marker) return null;
    const strong = slice[1] == marker;
    const open_len: usize = if (strong) 2 else 1;
    if (slice.len <= open_len) return null;
    // Find the matching closing run of the same marker/length.
    var i: usize = open_len;
    while (i < slice.len) : (i += 1) {
        if (slice[i] != marker) continue;
        if (strong) {
            if (i + 1 < slice.len and slice[i + 1] == marker) {
                if (i == open_len) return null; // empty
                return .{ .inner = slice[open_len..i], .strong = true, .consumed = i + 2 };
            }
        } else {
            if (i == open_len) return null; // empty
            return .{ .inner = slice[open_len..i], .strong = false, .consumed = i + 1 };
        }
    }
    return null;
}

/// Write a URL into an href attribute, blocking dangerous schemes. Only http(s),
/// mailto, relative, and anchor URLs survive; anything else (e.g. javascript:,
/// data:) is replaced with "#". The value is HTML-escaped for attribute context.
fn writeSafeUrl(w: *std.Io.Writer, url: []const u8) !void {
    if (isSafeUrl(url)) {
        try writeHtmlEscaped(w, url);
    } else {
        try w.writeByte('#');
    }
}

fn isSafeUrl(url: []const u8) bool {
    // Find a scheme (chars up to a ':'). If none before the first '/', '?', '#',
    // it's a relative/anchor URL and is safe.
    var i: usize = 0;
    while (i < url.len) : (i += 1) {
        const c = url[i];
        if (c == ':') {
            const scheme = url[0..i];
            return asciiEqlIgnoreCase(scheme, "http") or
                asciiEqlIgnoreCase(scheme, "https") or
                asciiEqlIgnoreCase(scheme, "mailto");
        }
        // A path/query/fragment separator before any ':' means no scheme → relative.
        if (c == '/' or c == '?' or c == '#') return true;
    }
    return true; // no ':' at all → relative
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Emit a fenced code block with a language class hook and lightweight syntax
/// tokenization. The content is split into comment/string/keyword class spans;
/// operators, identifiers, numbers, and whitespace stay as bare HTML-escaped text.
/// This deliberately leaves multi-character operator/number runs (e.g. `1 < 2`)
/// contiguous so the escaped source remains readable and self-evident.
fn writeCodeBlock(w: *std.Io.Writer, lang: []const u8, code: []const u8) !void {
    try w.writeAll("<pre class=\"code-block\"><code class=\"hljs lang-");
    // Language hint goes into a class; restrict to a safe identifier charset.
    try writeLangClass(w, lang);
    try w.writeAll("\">");
    try writeHighlightedCode(w, lang, code);
    try w.writeAll("</code></pre>");
}

/// Tokenize `code` into class spans. The grammar is intentionally tiny and language
/// agnostic (a reasonable default for the common C-family / shell / script langs):
///   - line comments:  // ... and # ...   -> <span class="tok-cmt">
///   - block comments:  /* ... */          -> <span class="tok-cmt">
///   - strings:  "...", '...', `...`        -> <span class="tok-str"> (with escapes)
///   - keywords (a fixed cross-language set) -> <span class="tok-kw">
/// All other bytes (operators, identifiers, numbers, whitespace) are written as
/// bare HTML-escaped text. Strings honor backslash escapes so a `\"` does not end
/// the span. Everything is escaped; spans cannot break out of the document.
fn writeHighlightedCode(w: *std.Io.Writer, lang: []const u8, code: []const u8) !void {
    const hash_is_comment = langUsesHashComments(lang);
    var i: usize = 0;
    while (i < code.len) {
        const c = code[i];

        // Block comment /* ... */
        if (c == '/' and i + 1 < code.len and code[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, code, i + 2, "*/");
            const stop = if (end) |e| e + 2 else code.len;
            try w.writeAll("<span class=\"tok-cmt\">");
            try writeHtmlEscaped(w, code[i..stop]);
            try w.writeAll("</span>");
            i = stop;
            continue;
        }
        // Line comment // ...
        if (c == '/' and i + 1 < code.len and code[i + 1] == '/') {
            const nl = std.mem.indexOfScalarPos(u8, code, i, '\n') orelse code.len;
            try w.writeAll("<span class=\"tok-cmt\">");
            try writeHtmlEscaped(w, code[i..nl]);
            try w.writeAll("</span>");
            i = nl;
            continue;
        }
        // Hash comment # ... (shell/python/ruby/etc), only for those languages.
        if (c == '#' and hash_is_comment) {
            const nl = std.mem.indexOfScalarPos(u8, code, i, '\n') orelse code.len;
            try w.writeAll("<span class=\"tok-cmt\">");
            try writeHtmlEscaped(w, code[i..nl]);
            try w.writeAll("</span>");
            i = nl;
            continue;
        }
        // String literals: ", ', or ` delimited (single-line for ' and "; ` may span lines).
        if (c == '"' or c == '\'' or c == '`') {
            const end = scanStringLiteral(code, i, c);
            try w.writeAll("<span class=\"tok-str\">");
            try writeHtmlEscaped(w, code[i..end]);
            try w.writeAll("</span>");
            i = end;
            continue;
        }
        // Identifier / keyword run.
        if (isIdentStart(c)) {
            var j = i + 1;
            while (j < code.len and isIdentPart(code[j])) : (j += 1) {}
            const word = code[i..j];
            if (isCodeKeyword(word)) {
                try w.writeAll("<span class=\"tok-kw\">");
                try writeHtmlEscaped(w, word);
                try w.writeAll("</span>");
            } else {
                try writeHtmlEscaped(w, word);
            }
            i = j;
            continue;
        }
        // Bare byte (operator / number / whitespace / punctuation): escaped, no span.
        try writeHtmlEscapedByte(w, c);
        i += 1;
    }
}

/// Return the index just past a string literal starting at `start` (the opening
/// quote `quote`). Honors backslash escapes. `"`/`'` stop at end-of-line if the
/// string is unterminated; backtick template strings may span lines.
fn scanStringLiteral(code: []const u8, start: usize, quote: u8) usize {
    var i = start + 1;
    while (i < code.len) : (i += 1) {
        const c = code[i];
        if (c == '\\') {
            i += 1; // skip the escaped char
            continue;
        }
        if (c == quote) return i + 1;
        if (c == '\n' and quote != '`') return i; // unterminated single-line string
    }
    return code.len;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn langUsesHashComments(lang: []const u8) bool {
    const hash_langs = [_][]const u8{ "sh", "bash", "zsh", "shell", "python", "py", "ruby", "rb", "yaml", "yml", "toml", "perl", "r", "makefile", "dockerfile" };
    for (hash_langs) |candidate| {
        if (asciiEqlIgnoreCase(lang, candidate)) return true;
    }
    return false;
}

/// A cross-language keyword set covering the common script/C-family tokens. This is
/// a heuristic default (we do not select a per-language grammar); matching is exact
/// and case-sensitive, so identifiers that merely contain a keyword are unaffected.
fn isCodeKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        // JS/TS
        "const",      "let",        "var",       "function", "return",  "if",      "else",    "for",
        "while",      "do",         "switch",    "case",     "break",   "continue", "new",    "class",
        "extends",    "import",     "export",    "from",     "default", "async",   "await",   "yield",
        "typeof",     "instanceof", "in",        "of",       "this",    "super",   "null",    "undefined",
        "true",       "false",      "void",      "delete",   "try",     "catch",   "finally", "throw",
        // Common across languages
        "def",        "elif",       "lambda",    "pass",     "with",    "as",      "and",     "or",
        "not",        "fn",         "let",       "mut",      "pub",     "use",     "struct",  "enum",
        "impl",       "trait",      "match",     "type",     "interface", "public", "private", "static",
        "int",        "float",      "bool",      "string",   "package", "func",    "go",      "defer",
        "select",     "chan",       "map",       "range",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

/// Escape a single byte for HTML body context (shared semantics with
/// writeHtmlEscaped). Used by the inline-markdown / tokenizer byte loops.
fn writeHtmlEscapedByte(w: *std.Io.Writer, byte: u8) !void {
    switch (byte) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(byte),
    }
}

/// Write a sanitized language class fragment: only [A-Za-z0-9_+-.] survive, so an attacker
/// cannot break out of the class attribute even though writeHtmlEscaped already neutralizes
/// quotes. Empty/odd languages collapse to "plain".
fn writeLangClass(w: *std.Io.Writer, lang: []const u8) !void {
    var any = false;
    for (lang) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '+', '-', '.' => {
                try w.writeByte(byte);
                any = true;
            },
            else => {},
        }
    }
    if (!any) try w.writeAll("plain");
}

fn renderTextBlocks(w: *std.Io.Writer, items: []const std.json.Value) !void {
    for (items) |item| {
        if (item != .object) continue;
        const block_type = getStringField(item.object, "type") orelse continue;
        if (!std.mem.eql(u8, block_type, "text")) continue;
        const text = getStringField(item.object, "text") orelse continue;
        // Route through writeMessageText so fenced code blocks render as code-block hooks,
        // matching the assistant text path.
        try writeMessageText(w, text);
    }
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

/// Render the per-entry timestamp as a visible `.message-timestamp` element. Mirrors
/// upstream template.js renderEntry(): every entry carries a top-level `timestamp` string.
///
/// Upstream uses `new Date(ts).toLocaleTimeString(...)` which is locale/timezone dependent
/// and therefore non-deterministic; for a deterministic server-rendered export we show the
/// `HH:MM:SS` slice of an ISO-8601 timestamp when present, otherwise the raw value verbatim.
/// All output is HTML-escaped. Emits nothing when the entry has no `timestamp`.
fn writeTimestamp(w: *std.Io.Writer, object: std.json.ObjectMap) !void {
    const ts = getStringField(object, "timestamp") orelse return;
    if (ts.len == 0) return;
    try w.writeAll("<div class=\"message-timestamp\">");
    try writeHtmlEscaped(w, formatTimestamp(ts));
    try w.writeAll("</div>");
}

/// Extract a deterministic `HH:MM:SS` clock slice from an ISO-8601 timestamp
/// (e.g. "2026-05-28T13:45:09.123Z" -> "13:45:09"). Falls back to the raw string for any
/// other shape so non-ISO timestamps still render. No timezone conversion is performed.
fn formatTimestamp(ts: []const u8) []const u8 {
    const t_index = std.mem.indexOfScalar(u8, ts, 'T') orelse return ts;
    const after_t = ts[t_index + 1 ..];
    // Expect at least "HH:MM:SS".
    if (after_t.len < 8) return ts;
    if (after_t[2] != ':' or after_t[5] != ':') return ts;
    return after_t[0..8];
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

// Dark theme. Colors mirror the upstream export palette family (text/muted/dim/accent +
// derived page/card/info backgrounds) but are hard-coded here rather than generated from a
// theme name, since this server-side port does not load the upstream theme registry.
const style_css =
    ":root{--text:#e8e8ec;--muted:#a0a0aa;--dim:#33333c;--accent:#7aa0d0;--body-bg:#181820;--container-bg:#1e1e24;--info-bg:#23252e;--user-bg:#23252e;--code-bg:#101015;--ok:#3a5a3a;--err:#a04040;--sidebar-width:300px}" ++
    "*{box-sizing:border-box}" ++
    "body{font-family:system-ui,-apple-system,sans-serif;margin:0;padding:0;background:var(--body-bg);color:var(--text);line-height:1.5}" ++
    "#app{display:flex;min-height:100vh;align-items:stretch}" ++
    "#sidebar{width:var(--sidebar-width);min-width:var(--sidebar-width);flex-shrink:0;background:var(--container-bg);border-right:1px solid var(--dim);position:sticky;top:0;height:100vh;display:flex;flex-direction:column;overflow:hidden}" ++
    "#sidebar .sidebar-header{padding:12px;border-bottom:1px solid var(--dim);flex-shrink:0}" ++
    "#sidebar .sidebar-title{font-size:12px;text-transform:uppercase;color:var(--muted);margin-bottom:8px;letter-spacing:.05em}" ++
    "#sidebar .sidebar-search{width:100%;padding:5px 8px;font:inherit;font-size:12px;background:var(--body-bg);color:var(--text);border:1px solid var(--dim);border-radius:4px}" ++
    "#sidebar .sidebar-search:focus{outline:none;border-color:var(--accent)}" ++
    "#sidebar .tree-container{flex:1;overflow-y:auto;padding:6px 0}" ++
    "#sidebar .tree-node{display:flex;gap:6px;align-items:baseline;padding:3px 12px;font-size:12px;color:var(--muted);text-decoration:none;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}" ++
    "#sidebar .tree-node:hover{background:var(--info-bg);color:var(--text)}" ++
    "#sidebar .tree-node.tree-hidden{display:none}" ++
    "#sidebar .tree-marker{color:var(--accent);flex-shrink:0}" ++
    "#sidebar .tree-content{overflow:hidden;text-overflow:ellipsis}" ++
    "#sidebar .tree-prefix{color:var(--accent);font-weight:600}" ++
    ".tree-role-user .tree-prefix{color:#7aa0d0}.tree-role-assistant .tree-prefix{color:#7ac0a0}.tree-role-tool .tree-prefix{color:#c0a070}" ++
    ".tree-compaction .tree-prefix,.tree-branch-summary .tree-prefix,.tree-custom .tree-prefix{color:#b08ad0}" ++
    "#sidebar .tree-status{padding:8px 12px;border-top:1px solid var(--dim);font-size:11px;color:var(--muted);flex-shrink:0}" ++
    "#content{flex:1;min-width:0}" ++
    ".session-header{padding:20px 32px;background:var(--container-bg);border-bottom:1px solid var(--dim)}" ++
    ".session-header h1{margin:0 0 8px;font-size:18px}" ++
    ".session-header .info{font-size:13px;color:var(--muted);margin:2px 0}" ++
    ".session-header .label{color:#7a7a85}" ++
    "#messages{max-width:900px;margin:0 auto;padding:24px 32px}" ++
    ".message{border:1px solid var(--dim);border-radius:8px;padding:12px 16px;margin:12px 0;background:var(--container-bg)}" ++
    ".message.user{background:var(--user-bg)}" ++
    ".message .role{font-weight:600;font-size:12px;text-transform:uppercase;color:#8a8a95;margin-bottom:6px}" ++
    ".message-timestamp{font-size:11px;color:var(--dim);opacity:.85;margin-bottom:6px;font-family:ui-monospace,Menlo,monospace}" ++
    "pre{white-space:pre-wrap;word-break:break-word;margin:0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px}" ++
    "pre.text{font-family:inherit;font-size:14px;margin:4px 0}" ++
    "pre.code-block{background:var(--code-bg);border:1px solid var(--dim);border-radius:6px;padding:10px 12px;margin:8px 0;overflow-x:auto}" ++
    "pre.code-block code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px;white-space:pre;color:#d8d8e0}" ++
    // Lightweight, self-contained syntax token colors (no external highlight theme).
    ".tok-kw{color:#c08adf}.tok-str{color:#9ccc7a}.tok-cmt{color:#6f7080;font-style:italic}.tok-num{color:#d8a06a}" ++
    // Inline markdown rendered inside prose runs.
    "pre.text strong{font-weight:700;color:#f0f0f4}pre.text em{font-style:italic}" ++
    "code.inline-code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.92em;background:var(--code-bg);border:1px solid var(--dim);border-radius:4px;padding:0 4px}" ++
    "pre.text a,#content a{color:var(--accent);text-decoration:underline}" ++
    ".thinking-block{border-left:3px solid #55556a;padding-left:10px;margin:8px 0;color:#9a9aa5;font-style:italic}" ++
    ".tool-execution{border:1px solid var(--dim);border-radius:6px;margin:8px 0;padding:8px 10px;background:#16161c}" ++
    ".tool-execution.error{border-color:var(--err)}" ++
    ".tool-execution.success{border-color:var(--ok)}" ++
    ".tool-command{font-family:ui-monospace,monospace;font-size:13px;color:#c8c8d0}" ++
    ".tool-header .tool-name{font-weight:600;color:var(--accent)}" ++
    ".tool-header .tool-path{color:var(--muted)}" ++
    ".tool-output{margin-top:6px;color:#b8b8c0}" ++
    ".note.warning{color:#d0a040}.note.error{color:#d06060}" ++
    ".error-text{color:#d06060;margin-top:6px}" ++
    ".info-entry{font-size:13px;color:#8a8a95;margin:8px 0;text-align:center}.model-name{color:var(--accent)}" ++
    ".compaction,.branch-summary,.hook-message{border:1px dashed #55556a;border-radius:6px;padding:10px 12px;margin:12px 0;background:#1a1a22}" ++
    ".compaction-label,.branch-summary-header,.hook-type{font-weight:600;color:#9a9aaa;margin-bottom:6px}" ++
    ".message-images,.tool-images{display:flex;flex-wrap:wrap;gap:8px;margin:6px 0}" ++
    ".message-image,.tool-image{max-width:320px;max-height:320px;border:1px solid #33333c;border-radius:4px}" ++
    ".message.search-hidden,.tool-execution.search-hidden,.compaction.search-hidden,.branch-summary.search-hidden,.hook-message.search-hidden{display:none}";

// Inline, dependency-free client-side text filter. Mirrors the *intent* of upstream
// template.js #tree-search: typing in the sidebar search box hides message entries and
// sidebar nodes whose text does not contain the (case-insensitive) query. Fully
// self-contained vanilla JS; no external scripts, no CDNs. Approximate vs upstream: a
// plain substring filter, not the upstream tree-aware filter modes (Default/No-tools/etc.).
const search_script =
    "(function(){" ++
    "var box=document.getElementById('tree-search');" ++
    "if(!box)return;" ++
    "var messages=document.getElementById('messages');" ++
    "var entries=messages?Array.prototype.slice.call(messages.children):[];" ++
    "var nodes=Array.prototype.slice.call(document.querySelectorAll('#tree-container .tree-node'));" ++
    "var status=document.getElementById('tree-status');" ++
    "var total=nodes.length;" ++
    "function apply(){" ++
    "var q=box.value.toLowerCase().trim();" ++
    "var shown=0;" ++
    "entries.forEach(function(el){" ++
    "var hit=!q||(el.textContent||'').toLowerCase().indexOf(q)!==-1;" ++
    "el.classList.toggle('search-hidden',!hit);" ++
    "});" ++
    "nodes.forEach(function(el){" ++
    "var hit=!q||(el.textContent||'').toLowerCase().indexOf(q)!==-1;" ++
    "el.classList.toggle('tree-hidden',!hit);" ++
    "if(hit)shown++;" ++
    "});" ++
    "if(status)status.textContent=shown+' / '+total+' entries';" ++
    "}" ++
    "box.addEventListener('input',apply);" ++
    "})();";

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
        // display:false content uses a distinctive marker so the "not rendered" assertion
        // can't collide with CSS/script class names like "search-hidden"/"tree-hidden".
        "{\"type\":\"custom_message\",\"id\":\"cm2\",\"parentId\":\"cm1\",\"timestamp\":\"t\",\"customType\":\"ext\",\"content\":\"suppressedmarker\",\"display\":false}\n" ++
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
    try std.testing.expect(std.mem.indexOf(u8, html, "suppressedmarker") == null);
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

test "renders per-entry timestamps formatted from ISO-8601" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"2026-05-28T09:00:00.000Z\",\"cwd\":\".\"}\n" ++
        "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"timestamp\":\"2026-05-28T13:45:09.123Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n" ++
        "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":\"u1\",\"timestamp\":\"raw-stamp\",\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "s.jsonl");
    const html = out.written();

    // ISO timestamp is rendered as a deterministic HH:MM:SS clock slice (no TZ conversion).
    try std.testing.expect(std.mem.indexOf(u8, html, "<div class=\"message-timestamp\">13:45:09</div>") != null);
    // A non-ISO timestamp falls back to the raw value verbatim.
    try std.testing.expect(std.mem.indexOf(u8, html, "<div class=\"message-timestamp\">raw-stamp</div>") != null);
}

test "renders sidebar nav with anchor links to entries" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\".\"}\n" ++
        "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"user\",\"content\":\"first question\"}}\n" ++
        "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":\"u1\",\"timestamp\":\"t\",\"message\":{\"role\":\"assistant\",\"content\":\"an answer here\"}}\n" ++
        "{\"type\":\"compaction\",\"id\":\"c1\",\"parentId\":\"a1\",\"timestamp\":\"t\",\"summary\":\"squashed\",\"tokensBefore\":10}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "s.jsonl");
    const html = out.written();

    // Sidebar container and a node linking to each rendered entry by anchor.
    try std.testing.expect(std.mem.indexOf(u8, html, "<nav id=\"sidebar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"tree-container\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<a class=\"tree-node\" href=\"#entry-u1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<a class=\"tree-node\" href=\"#entry-a1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<a class=\"tree-node\" href=\"#entry-c1\"") != null);
    // Sidebar labels carry truncated/normalized message text.
    try std.testing.expect(std.mem.indexOf(u8, html, "first question") != null);
    // Entry count reflects the three anchored entries (user, assistant, compaction).
    try std.testing.expect(std.mem.indexOf(u8, html, "3 entries") != null);
}

test "embeds self-contained client-side search box and script" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\".\"}\n" ++
        "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "s.jsonl");
    const html = out.written();

    // Search input exists and an inline script wires it up (no external script src).
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"tree-search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "getElementById('tree-search')") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "addEventListener('input'") != null);
    // No external resource references anywhere in the document.
    try std.testing.expect(std.mem.indexOf(u8, html, "src=\"http") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script src=") == null);
}

test "renders fenced code blocks with language class hooks" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\".\"}\n" ++
        "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"assistant\",\"content\":\"before\\n```zig\\nconst x = 1 < 2;\\n```\\nafter\"}}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "s.jsonl");
    const html = out.written();

    // Prose around the fence stays in text blocks; the fence becomes a code-block with a
    // language class hook. Its contents are HTML-escaped and lightly tokenized: the `const`
    // keyword is wrapped in a class span while the `1 < 2` operator run stays bare/escaped.
    try std.testing.expect(std.mem.indexOf(u8, html, "<pre class=\"code-block\"><code class=\"hljs lang-zig\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"tok-kw\">const</span>") != null);
    // The escaped operator text remains contiguous (the tokenizer leaves operators bare).
    try std.testing.expect(std.mem.indexOf(u8, html, "1 &lt; 2;") != null);
    // No raw '<' leaks from the code content.
    try std.testing.expect(std.mem.indexOf(u8, html, "1 < 2;") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "after") != null);
    // In the rendered message body the fence markers are consumed (not emitted as a
    // prose <pre> containing literal backticks). The sidebar label may still echo the raw
    // first line of message text, so we scope this to the message pane.
    const messages_start = std.mem.indexOf(u8, html, "<div id=\"messages\">").?;
    const body = html[messages_start..];
    try std.testing.expect(std.mem.indexOf(u8, body, "```") == null);
}

test "renders inline markdown: bold, italic, inline code, and links" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\".\"}\n" ++
        "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"assistant\",\"content\":\"Use **bold** and *italic* with `inline()` and a [link](https://example.com/x).\"}}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "s.jsonl");
    const html = out.written();

    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>bold</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<em>italic</em>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<code class=\"inline-code\">inline()</code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<a href=\"https://example.com/x\" rel=\"nofollow noopener\">link</a>") != null);
    // The raw markdown markers are consumed in the rendered prose. The sidebar label
    // still echoes the raw first line of message text, so scope this to the body.
    const messages_start = std.mem.indexOf(u8, html, "<div id=\"messages\">").?;
    const body = html[messages_start..];
    try std.testing.expect(std.mem.indexOf(u8, body, "**bold**") == null);
}

test "inline markdown escapes content and neutralizes dangerous link schemes" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\".\"}\n" ++
        // A javascript: link and an inline-code span containing angle brackets.
        "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"assistant\",\"content\":\"danger [x](javascript:alert(1)) and `a<b>c` end\"}}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "s.jsonl");
    const html = out.written();

    // The javascript: scheme is blocked (href collapses to "#"); the literal scheme
    // must never appear inside an href.
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"#\"") != null);
    // Inline code content is HTML-escaped (no raw tag injection).
    try std.testing.expect(std.mem.indexOf(u8, html, "a&lt;b&gt;c") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<b>c") == null);
}

test "syntax tokenizer wraps strings and comments in class spans" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\".\"}\n" ++
        "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"assistant\",\"content\":\"```js\\nconst s = \\\"hi <there>\\\"; // note\\n```\"}}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "s.jsonl");
    const html = out.written();

    // String literal becomes a tok-str span with its angle brackets escaped inside.
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"tok-str\">&quot;hi &lt;there&gt;&quot;</span>") != null);
    // Line comment becomes a tok-cmt span.
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"tok-cmt\">// note</span>") != null);
    // Keyword span present.
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"tok-kw\">const</span>") != null);
    // Token CSS classes are defined in the stylesheet.
    try std.testing.expect(std.mem.indexOf(u8, html, ".tok-kw{") != null);
}

test "syntax tokenizer honors hash comments only for shell-family languages" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\".\"}\n" ++
        "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"assistant\",\"content\":\"```bash\\necho hi # comment\\n```\"}}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "s.jsonl");
    const html = out.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"tok-cmt\"># comment</span>") != null);
}

test "exposes theme color variables and app layout" {
    const session_jsonl =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\".\"}\n" ++
        "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"timestamp\":\"t\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n";

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderSessionHtml(std.testing.allocator, &out.writer, session_jsonl, "s.jsonl");
    const html = out.written();

    try std.testing.expect(std.mem.indexOf(u8, html, "--accent:") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<div id=\"app\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<main id=\"content\">") != null);
    // Title contract for downstream smoke assertions is preserved.
    try std.testing.expect(std.mem.indexOf(u8, html, "<title>pi-zig session</title>") != null);
}

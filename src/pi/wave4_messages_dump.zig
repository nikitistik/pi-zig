// SPDX-License-Identifier: MIT
// Wave 4 dump harness — emits one rendered block per upstream message family.
// Built by scripts/wave4-messages-smoke.mjs; expected stdout substrings are
// asserted by the smoke after `zig run` executes this file.
const std = @import("std");
const tui_messages = @import("tui_messages.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var out_buf: [16 * 1024]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &out_writer.interface;

    // 1) User message.
    {
        var rendered = try tui_messages.renderUserMessage(allocator, .{ .text = "please summarize /tmp/x" });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    // Divider between messages.
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\n');
    }
    // 2) Assistant message.
    {
        var rendered = try tui_messages.renderAssistantMessage(allocator, .{ .text = "I will read /tmp/x first." });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\n');
    }
    // 3) Tool execution (read tool with result).
    {
        var rendered = try tui_messages.renderToolExecution(allocator, .{
            .tool_name = "read",
            .arguments_json = "{\"path\":\"/tmp/x\"}",
            .result_text = "file contents: hello world",
            .is_error = false,
        });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\n');
    }
    // 4) Bash execution.
    {
        var rendered = try tui_messages.renderBashExecution(allocator, .{
            .command = "ls /tmp",
            .output = "a.txt\nb.txt\nc.txt",
            .exit_code = 0,
        });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\n');
    }
    // 5) Compaction summary.
    {
        var rendered = try tui_messages.renderCompactionSummary(allocator, .{
            .tokens_before = 12345,
            .summary = "Compaction body text.",
        });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\n');
    }
    // 6) Branch summary.
    {
        var rendered = try tui_messages.renderBranchSummary(allocator, .{ .summary = "Branch merged at deadbeef." });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\n');
    }
    // 7) Custom message (display:true).
    {
        var rendered = try tui_messages.renderCustomMessage(allocator, .{
            .custom_type = "diagnostic",
            .content = "lint clean across pi-zig",
        });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\n');
    }
    // 8) Skill invocation.
    {
        var rendered = try tui_messages.renderSkillInvocation(allocator, .{
            .name = "verify",
            .args = "target=ui",
        });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }

    try w.flush();
}

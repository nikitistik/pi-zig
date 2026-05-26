const std = @import("std");
const context_files = @import("context_files.zig");

const default_selected_tools = [_][]const u8{ "read", "bash", "edit", "write" };

pub const NamedText = struct {
    name: []const u8,
    text: []const u8,
};

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    file_path: []const u8,
    disable_model_invocation: bool = false,
};

pub const BuildOptions = struct {
    custom_prompt: ?[]const u8 = null,
    selected_tools: ?[]const []const u8 = null,
    tool_snippets: []const NamedText = &.{},
    prompt_guidelines: []const []const u8 = &.{},
    append_system_prompt: ?[]const u8 = null,
    cwd: []const u8,
    package_dir: []const u8,
    date: []const u8,
    context_files: []const context_files.TextFile = &.{},
    skills: []const Skill = &.{},
    include_builtin_tool_metadata: bool = false,
};

const CliOptions = struct {
    help: bool = false,
    json: bool = false,
    no_context_files: bool = false,
    no_tools: bool = false,
    custom_prompt: ?[]const u8 = null,
    append_prompts: [16][]const u8 = undefined,
    append_prompts_len: usize = 0,
    guidelines: [32][]const u8 = undefined,
    guidelines_len: usize = 0,
    tools: [16][]const u8 = undefined,
    tools_len: usize = 0,
    date: ?[]const u8 = null,
    package_dir: ?[]const u8 = null,
    invalid_option: ?[]const u8 = null,
    missing_option_value: ?[]const u8 = null,

    fn addAppend(self: *CliOptions, value: []const u8) void {
        if (self.append_prompts_len >= self.append_prompts.len) {
            self.invalid_option = self.invalid_option orelse "too many --append values";
            return;
        }
        self.append_prompts[self.append_prompts_len] = value;
        self.append_prompts_len += 1;
    }

    fn addGuideline(self: *CliOptions, value: []const u8) void {
        if (self.guidelines_len >= self.guidelines.len) {
            self.invalid_option = self.invalid_option orelse "too many --guideline values";
            return;
        }
        self.guidelines[self.guidelines_len] = value;
        self.guidelines_len += 1;
    }

    fn addTool(self: *CliOptions, value: []const u8) void {
        if (self.tools_len >= self.tools.len) {
            self.invalid_option = self.invalid_option orelse "too many --tool values";
            return;
        }
        self.tools[self.tools_len] = value;
        self.tools_len += 1;
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !bool {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "system-prompt")) return false;
    const options = parseCliOptions(args[1..]);

    if (options.help) {
        try writeHelp(io);
        return true;
    }
    if (options.invalid_option) |option| {
        try writeStderr(io, "Unknown option ");
        try writeStderr(io, option);
        try writeStderr(io, " for \"system-prompt\".\n");
        try writeStderr(io, "Use \"pi-zig system-prompt --help\".\n");
        std.process.exit(1);
    }
    if (options.missing_option_value) |option| {
        try writeStderr(io, "Missing value for ");
        try writeStderr(io, option);
        try writeStderr(io, ".\n");
        std.process.exit(1);
    }

    const cwd = try currentPathOwned(io, allocator);
    defer allocator.free(cwd);
    const package_dir = try resolvePackageDir(io, allocator, env, cwd, options.package_dir);
    defer allocator.free(package_dir);

    var date_buf: [10]u8 = undefined;
    const prompt_date = options.date orelse try currentUtcDate(io, &date_buf);

    var discovery = try context_files.discover(io, allocator, env, .{ .no_context_files = options.no_context_files });
    defer discovery.deinit();

    const append_prompt = try combineAppendPrompt(allocator, discovery.append_system_prompt, options.append_prompts[0..options.append_prompts_len]);
    defer if (append_prompt) |text| allocator.free(text);

    const selected_tools: ?[]const []const u8 = if (options.no_tools)
        &.{}
    else if (options.tools_len > 0)
        options.tools[0..options.tools_len]
    else
        null;

    const prompt = try build(allocator, .{
        .custom_prompt = options.custom_prompt orelse if (discovery.system_prompt) |file| file.content else null,
        .selected_tools = selected_tools,
        .prompt_guidelines = options.guidelines[0..options.guidelines_len],
        .append_system_prompt = append_prompt,
        .cwd = cwd,
        .package_dir = package_dir,
        .date = prompt_date,
        .context_files = discovery.context_files.items,
        .include_builtin_tool_metadata = true,
    });
    defer allocator.free(prompt);

    if (options.json) {
        var buf: [16 * 1024]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buf);
        const w = &writer.interface;
        try w.writeAll("{\"prompt\":");
        try writeJsonString(w, prompt);
        try w.writeAll(",\"contextFileCount\":");
        try w.print("{d}", .{discovery.context_files.items.len});
        try w.writeAll(",\"hasSystemPrompt\":");
        try w.writeAll(if (discovery.system_prompt != null or options.custom_prompt != null) "true" else "false");
        try w.writeAll(",\"hasAppendSystemPrompt\":");
        try w.writeAll(if (append_prompt != null) "true" else "false");
        try w.writeAll("}\n");
        try w.flush();
    } else {
        try std.Io.File.stdout().writeStreamingAll(io, prompt);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
    }
    return true;
}

pub fn build(allocator: std.mem.Allocator, options: BuildOptions) ![]u8 {
    const append_section = options.append_system_prompt orelse "";
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    if (options.custom_prompt) |custom| {
        try w.writeAll(custom);
        if (append_section.len > 0) {
            try w.writeAll("\n\n");
            try w.writeAll(append_section);
        }
        try appendProjectContext(w, options.context_files);
        if (hasReadTool(options.selected_tools) and options.skills.len > 0) {
            try appendSkills(w, options.skills);
        }
        try appendDateAndCwd(w, options.date, options.cwd);
        return out.toOwnedSlice();
    }

    const selected_tools = options.selected_tools orelse &default_selected_tools;

    try w.writeAll(
        \\You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.
        \\
        \\Available tools:
        \\
    );
    try appendToolsList(w, selected_tools, options.tool_snippets, options.include_builtin_tool_metadata);
    try w.writeAll(
        \\
        \\
        \\In addition to the tools above, you may have access to other custom tools depending on the project.
        \\
        \\
        \\Guidelines:
        \\
    );
    try appendGuidelines(w, allocator, selected_tools, options.prompt_guidelines, options.include_builtin_tool_metadata);
    try w.writeAll(
        \\
        \\
        \\Pi documentation (read only when the user asks about pi itself, its SDK, extensions, themes, skills, or TUI):
        \\- Main documentation: 
    );
    try appendPackagePath(w, options.package_dir, "README.md");
    try w.writeAll("\n- Additional docs: ");
    try appendPackagePath(w, options.package_dir, "docs");
    try w.writeAll("\n- Examples: ");
    try appendPackagePath(w, options.package_dir, "examples");
    try w.writeAll(
        \\ (extensions, custom tools, SDK)
        \\- When reading pi docs or examples, resolve docs/... under Additional docs and examples/... under Examples, not the current working directory
        \\- When asked about: extensions (docs/extensions.md, examples/extensions/), themes (docs/themes.md), skills (docs/skills.md), prompt templates (docs/prompt-templates.md), TUI components (docs/tui.md), keybindings (docs/keybindings.md), SDK integrations (docs/sdk.md), custom providers (docs/custom-provider.md), adding models (docs/models.md), pi packages (docs/packages.md)
        \\- When working on pi topics, read the docs and examples, and follow .md cross-references before implementing
        \\- Always read pi .md files completely and follow links to related docs (e.g., tui.md for TUI API details)
    );

    if (append_section.len > 0) {
        try w.writeAll("\n\n");
        try w.writeAll(append_section);
    }

    try appendProjectContext(w, options.context_files);
    if (containsTool(selected_tools, "read") and options.skills.len > 0) {
        try appendSkills(w, options.skills);
    }
    try appendDateAndCwd(w, options.date, options.cwd);
    return try out.toOwnedSlice();
}

fn appendToolsList(
    w: *std.Io.Writer,
    selected_tools: []const []const u8,
    tool_snippets: []const NamedText,
    include_builtin_metadata: bool,
) !void {
    var emitted: usize = 0;
    for (selected_tools) |tool| {
        const snippet = snippetFor(tool, tool_snippets) orelse if (include_builtin_metadata) builtinToolSnippet(tool) else null;
        if (snippet) |text| {
            if (emitted != 0) try w.writeByte('\n');
            try w.print("- {s}: {s}", .{ tool, text });
            emitted += 1;
        }
    }
    if (emitted == 0) try w.writeAll("(none)");
}

fn appendGuidelines(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    selected_tools: []const []const u8,
    prompt_guidelines: []const []const u8,
    include_builtin_metadata: bool,
) !void {
    var guidelines: std.ArrayList([]const u8) = .empty;
    defer guidelines.deinit(allocator);

    if (containsTool(selected_tools, "bash") and !containsTool(selected_tools, "grep") and !containsTool(selected_tools, "find") and !containsTool(selected_tools, "ls")) {
        try appendUniqueGuideline(allocator, &guidelines, "Use bash for file operations like ls, rg, find");
    } else if (containsTool(selected_tools, "bash") and (containsTool(selected_tools, "grep") or containsTool(selected_tools, "find") or containsTool(selected_tools, "ls"))) {
        try appendUniqueGuideline(allocator, &guidelines, "Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)");
    }

    if (include_builtin_metadata) {
        for (selected_tools) |tool| {
            if (builtinToolGuidelines(tool)) |tool_guidelines| {
                for (tool_guidelines) |guideline| try appendUniqueGuideline(allocator, &guidelines, guideline);
            }
        }
    }

    for (prompt_guidelines) |raw| {
        const normalized = std.mem.trim(u8, raw, " \t\r\n");
        if (normalized.len > 0) try appendUniqueGuideline(allocator, &guidelines, normalized);
    }

    try appendUniqueGuideline(allocator, &guidelines, "Be concise in your responses");
    try appendUniqueGuideline(allocator, &guidelines, "Show file paths clearly when working with files");

    for (guidelines.items, 0..) |guideline, i| {
        if (i != 0) try w.writeByte('\n');
        try w.writeAll("- ");
        try w.writeAll(guideline);
    }
}

fn appendUniqueGuideline(allocator: std.mem.Allocator, guidelines: *std.ArrayList([]const u8), value: []const u8) !void {
    for (guidelines.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try guidelines.append(allocator, value);
}

fn appendProjectContext(w: *std.Io.Writer, files: []const context_files.TextFile) !void {
    if (files.len == 0) return;
    try w.writeAll("\n\n<project_context>\n\n");
    try w.writeAll("Project-specific instructions and guidelines:\n\n");
    for (files) |file| {
        try w.writeAll("<project_instructions path=\"");
        try writeXmlEscaped(w, file.path);
        try w.writeAll("\">\n");
        try w.writeAll(file.content);
        try w.writeAll("\n</project_instructions>\n\n");
    }
    try w.writeAll("</project_context>\n");
}

fn appendSkills(w: *std.Io.Writer, skills: []const Skill) !void {
    var visible: usize = 0;
    for (skills) |skill| {
        if (!skill.disable_model_invocation) visible += 1;
    }
    if (visible == 0) return;

    try w.writeAll("\n\nThe following skills provide specialized instructions for specific tasks.\n");
    try w.writeAll("Use the read tool to load a skill's file when the task matches its description.\n");
    try w.writeAll("When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.\n\n");
    try w.writeAll("<available_skills>");
    for (skills) |skill| {
        if (skill.disable_model_invocation) continue;
        try w.writeAll("\n  <skill>\n    <name>");
        try writeXmlEscaped(w, skill.name);
        try w.writeAll("</name>\n    <description>");
        try writeXmlEscaped(w, skill.description);
        try w.writeAll("</description>\n    <location>");
        try writeXmlEscaped(w, skill.file_path);
        try w.writeAll("</location>\n  </skill>");
    }
    try w.writeAll("\n</available_skills>");
}

fn appendDateAndCwd(w: *std.Io.Writer, date: []const u8, cwd: []const u8) !void {
    try w.writeAll("\nCurrent date: ");
    try w.writeAll(date);
    try w.writeAll("\nCurrent working directory: ");
    try writePosixPath(w, cwd);
}

fn appendPackagePath(w: *std.Io.Writer, package_dir: []const u8, child: []const u8) !void {
    try writePosixPath(w, package_dir);
    try w.writeByte('/');
    try w.writeAll(child);
}

fn hasReadTool(selected_tools: ?[]const []const u8) bool {
    if (selected_tools) |tools| return containsTool(tools, "read");
    return true;
}

fn containsTool(selected_tools: []const []const u8, name: []const u8) bool {
    for (selected_tools) |tool| {
        if (std.mem.eql(u8, tool, name)) return true;
    }
    return false;
}

fn snippetFor(name: []const u8, snippets: []const NamedText) ?[]const u8 {
    for (snippets) |snippet| {
        if (std.mem.eql(u8, snippet.name, name)) return snippet.text;
    }
    return null;
}

fn builtinToolSnippet(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "read")) return "Read file contents";
    if (std.mem.eql(u8, name, "bash")) return "Execute bash commands (ls, grep, find, etc.)";
    if (std.mem.eql(u8, name, "edit")) return "Make precise file edits with exact text replacement, including multiple disjoint edits in one call";
    if (std.mem.eql(u8, name, "write")) return "Create or overwrite files";
    if (std.mem.eql(u8, name, "grep")) return "Search file contents for patterns (respects .gitignore)";
    if (std.mem.eql(u8, name, "find")) return "Find files by glob pattern (respects .gitignore)";
    if (std.mem.eql(u8, name, "ls")) return "List directory contents";
    return null;
}

fn builtinToolGuidelines(name: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, name, "read")) return &.{"Use read to examine files instead of cat or sed."};
    if (std.mem.eql(u8, name, "edit")) return &.{
        "Use edit for precise changes (edits[].oldText must match exactly)",
        "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls",
        "Each edits[].oldText is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits. Merge nearby changes into one edit.",
        "Keep edits[].oldText as small as possible while still being unique in the file. Do not pad with large unchanged regions.",
    };
    if (std.mem.eql(u8, name, "write")) return &.{"Use write only for new files or complete rewrites."};
    return null;
}

pub fn combineAppendPrompt(allocator: std.mem.Allocator, discovered: ?context_files.TextFile, additional: []const []const u8) !?[]u8 {
    if (discovered == null and additional.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    var emitted = false;
    if (discovered) |file| {
        try w.writeAll(file.content);
        emitted = true;
    }
    for (additional) |value| {
        if (emitted) try w.writeAll("\n\n");
        try w.writeAll(value);
        emitted = true;
    }
    return try out.toOwnedSlice();
}

fn parseCliOptions(args: []const []const u8) CliOptions {
    var options = CliOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--no-context-files") or std.mem.eql(u8, arg, "-nc")) {
            options.no_context_files = true;
        } else if (std.mem.eql(u8, arg, "--no-tools")) {
            options.no_tools = true;
        } else if (std.mem.eql(u8, arg, "--custom")) {
            if (takeValue(args, &i)) |value| {
                options.custom_prompt = value;
            } else {
                options.missing_option_value = options.missing_option_value orelse arg;
            }
        } else if (std.mem.eql(u8, arg, "--append")) {
            if (takeValue(args, &i)) |value| {
                options.addAppend(value);
            } else {
                options.missing_option_value = options.missing_option_value orelse arg;
            }
        } else if (std.mem.eql(u8, arg, "--guideline")) {
            if (takeValue(args, &i)) |value| {
                options.addGuideline(value);
            } else {
                options.missing_option_value = options.missing_option_value orelse arg;
            }
        } else if (std.mem.eql(u8, arg, "--tool")) {
            if (takeValue(args, &i)) |value| {
                options.addTool(value);
            } else {
                options.missing_option_value = options.missing_option_value orelse arg;
            }
        } else if (std.mem.eql(u8, arg, "--tools")) {
            if (takeValue(args, &i)) |value| {
                addCommaSeparatedTools(&options, value);
            } else {
                options.missing_option_value = options.missing_option_value orelse arg;
            }
        } else if (std.mem.eql(u8, arg, "--date")) {
            if (takeValue(args, &i)) |value| {
                options.date = value;
            } else {
                options.missing_option_value = options.missing_option_value orelse arg;
            }
        } else if (std.mem.eql(u8, arg, "--package-dir")) {
            if (takeValue(args, &i)) |value| {
                options.package_dir = value;
            } else {
                options.missing_option_value = options.missing_option_value orelse arg;
            }
        } else {
            options.invalid_option = options.invalid_option orelse arg;
        }
    }
    return options;
}

fn addCommaSeparatedTools(options: *CliOptions, value: []const u8) void {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len > 0) options.addTool(trimmed);
    }
}

fn takeValue(argv: []const []const u8, index: *usize) ?[]const u8 {
    if (index.* + 1 >= argv.len) return null;
    index.* += 1;
    return argv[index.*];
}

pub fn resolvePackageDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    override: ?[]const u8,
) ![]u8 {
    if (override orelse env.get("PI_PACKAGE_DIR")) |path| {
        return resolvePathWithBase(allocator, env, cwd, path);
    }

    if (try findPackageDirFromAncestor(io, allocator, cwd)) |path| return path;
    return resolvePathWithBase(allocator, env, cwd, "upstream/pi/packages/coding-agent");
}

fn findPackageDirFromAncestor(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    var current = try allocator.dupe(u8, cwd);
    defer allocator.free(current);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, "upstream", "pi", "packages", "coding-agent" });
        errdefer allocator.free(candidate);
        const package_json = try std.fs.path.join(allocator, &.{ candidate, "package.json" });
        defer allocator.free(package_json);
        if (pathExists(io, package_json)) return candidate;
        allocator.free(candidate);

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return null;
}

pub fn currentUtcDate(io: std.Io, buf: []u8) ![]const u8 {
    const timestamp = std.Io.Clock.real.now(io).toSeconds();
    const secs: u64 = if (timestamp < 0) 0 else @intCast(timestamp);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var writer = std.Io.Writer.fixed(buf);
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        @as(u8, month_day.day_index) + 1,
    });
    return writer.buffered();
}

fn currentPathOwned(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(io, &buf);
    return std.fs.path.resolve(allocator, &.{buf[0..len]});
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

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn writePosixPath(w: *std.Io.Writer, path: []const u8) !void {
    for (path) |byte| {
        try w.writeByte(if (byte == '\\') '/' else byte);
    }
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

fn writeXmlEscaped(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&apos;"),
            else => try w.writeByte(byte),
        }
    }
}

fn writeHelp(io: std.Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  pi-zig system-prompt [options]
        \\
        \\Build the upstream-shaped system prompt from tool metadata, loaded
        \\AGENTS/CLAUDE context files, and SYSTEM/APPEND_SYSTEM prompt files.
        \\
        \\Options:
        \\  --json                         Print {"prompt":...} instead of raw text
        \\  --no-context-files, -nc        Skip AGENTS.md and CLAUDE.md discovery
        \\  --tools <a,b>                  Select tool names
        \\  --tool <name>                  Add one selected tool
        \\  --no-tools                     Build with an empty tool list
        \\  --custom <text>                Replace the default prompt text
        \\  --append <text>                Append extra system prompt text
        \\  --guideline <text>             Add a prompt guideline
        \\  --date <YYYY-MM-DD>            Override current date for deterministic checks
        \\  --package-dir <path>           Override pi package docs directory
        \\
    );
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeStderr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

test "system prompt builder handles empty tools" {
    const prompt = try build(std.testing.allocator, .{
        .selected_tools = &.{},
        .cwd = "/work",
        .package_dir = "/pi",
        .date = "2026-05-26",
    });
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Available tools:\n(none)") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Show file paths clearly") != null);
}

test "system prompt builder adds context and custom prompt" {
    const files = [_]context_files.TextFile{.{
        .path = @constCast("/repo/AGENTS.md"),
        .content = @constCast("Use project rules."),
        .scope = "project",
    }};
    const prompt = try build(std.testing.allocator, .{
        .custom_prompt = "Custom base.",
        .append_system_prompt = "Append base.",
        .cwd = "/repo",
        .package_dir = "/pi",
        .date = "2026-05-26",
        .context_files = &files,
    });
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Custom base.\n\nAppend base.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<project_instructions path=\"/repo/AGENTS.md\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Use project rules.") != null);
}

test "system prompt builder deduplicates guidelines" {
    const prompt = try build(std.testing.allocator, .{
        .selected_tools = &.{ "read", "dynamic_tool" },
        .prompt_guidelines = &.{ "Use dynamic_tool for summaries.", "  Use dynamic_tool for summaries.  ", "   " },
        .cwd = "/repo",
        .package_dir = "/pi",
        .date = "2026-05-26",
    });
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, prompt, "- Use dynamic_tool for summaries."));
}

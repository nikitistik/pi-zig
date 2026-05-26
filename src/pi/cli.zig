const std = @import("std");
const types = @import("types.zig");

const MaxItems = 64;
const MaxDiagnostics = 32;

pub const Mode = enum {
    text,
    json,
    rpc,

    pub fn parse(value: []const u8) ?Mode {
        if (std.mem.eql(u8, value, "text")) return .text;
        if (std.mem.eql(u8, value, "json")) return .json;
        if (std.mem.eql(u8, value, "rpc")) return .rpc;
        return null;
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .text => "text",
            .json => "json",
            .rpc => "rpc",
        };
    }
};

pub const DiagnosticKind = enum {
    warning,
    @"error",

    pub fn label(self: DiagnosticKind) []const u8 {
        return switch (self) {
            .warning => "warning",
            .@"error" => "error",
        };
    }
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    message: []const u8,
};

pub const UnknownFlag = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

pub const ParsedArgs = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    mode: ?Mode = null,
    thinking: ?types.ThinkingLevel = null,
    continue_session: bool = false,
    resume_session: bool = false,
    help: bool = false,
    version: bool = false,
    no_session: bool = false,
    session: ?[]const u8 = null,
    fork: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    models: ?[]const u8 = null,
    tools: ?[]const u8 = null,
    no_tools: bool = false,
    no_builtin_tools: bool = false,
    print: bool = false,
    export_path: ?[]const u8 = null,
    no_extensions: bool = false,
    no_skills: bool = false,
    no_prompt_templates: bool = false,
    no_themes: bool = false,
    no_context_files: bool = false,
    list_models: bool = false,
    list_models_pattern: ?[]const u8 = null,
    offline: bool = false,
    verbose: bool = false,

    append_system_prompts: [MaxItems][]const u8 = undefined,
    append_system_prompts_len: usize = 0,
    extensions: [MaxItems][]const u8 = undefined,
    extensions_len: usize = 0,
    skills: [MaxItems][]const u8 = undefined,
    skills_len: usize = 0,
    prompt_templates: [MaxItems][]const u8 = undefined,
    prompt_templates_len: usize = 0,
    themes: [MaxItems][]const u8 = undefined,
    themes_len: usize = 0,
    messages: [MaxItems][]const u8 = undefined,
    messages_len: usize = 0,
    file_args: [MaxItems][]const u8 = undefined,
    file_args_len: usize = 0,
    unknown_flags: [MaxItems]UnknownFlag = undefined,
    unknown_flags_len: usize = 0,
    diagnostics: [MaxDiagnostics]Diagnostic = undefined,
    diagnostics_len: usize = 0,

    fn addMessage(self: *ParsedArgs, value: []const u8) void {
        addString(&self.messages, &self.messages_len, self, "too many messages", value);
    }

    fn addFileArg(self: *ParsedArgs, value: []const u8) void {
        addString(&self.file_args, &self.file_args_len, self, "too many file args", value);
    }

    fn addAppendSystemPrompt(self: *ParsedArgs, value: []const u8) void {
        addString(&self.append_system_prompts, &self.append_system_prompts_len, self, "too many append-system-prompt values", value);
    }

    fn addExtension(self: *ParsedArgs, value: []const u8) void {
        addString(&self.extensions, &self.extensions_len, self, "too many extensions", value);
    }

    fn addSkill(self: *ParsedArgs, value: []const u8) void {
        addString(&self.skills, &self.skills_len, self, "too many skills", value);
    }

    fn addPromptTemplate(self: *ParsedArgs, value: []const u8) void {
        addString(&self.prompt_templates, &self.prompt_templates_len, self, "too many prompt templates", value);
    }

    fn addTheme(self: *ParsedArgs, value: []const u8) void {
        addString(&self.themes, &self.themes_len, self, "too many themes", value);
    }

    fn addUnknownFlag(self: *ParsedArgs, name: []const u8, value: ?[]const u8) void {
        if (self.unknown_flags_len >= MaxItems) {
            self.addDiagnostic(.@"error", "too many unknown flags");
            return;
        }
        self.unknown_flags[self.unknown_flags_len] = .{ .name = name, .value = value };
        self.unknown_flags_len += 1;
    }

    fn addDiagnostic(self: *ParsedArgs, kind: DiagnosticKind, message: []const u8) void {
        if (self.diagnostics_len >= MaxDiagnostics) return;
        self.diagnostics[self.diagnostics_len] = .{ .kind = kind, .message = message };
        self.diagnostics_len += 1;
    }
};

pub fn parse(argv: []const []const u8) ParsedArgs {
    var result = ParsedArgs{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (equals(arg, "--help") or equals(arg, "-h")) {
            result.help = true;
        } else if (equals(arg, "--version") or equals(arg, "-v")) {
            result.version = true;
        } else if (equals(arg, "--mode")) {
            if (takeValue(argv, &i)) |value| {
                result.mode = Mode.parse(value);
                if (result.mode == null) result.addDiagnostic(.warning, "invalid mode");
            }
        } else if (equals(arg, "--continue") or equals(arg, "-c")) {
            result.continue_session = true;
        } else if (equals(arg, "--resume") or equals(arg, "-r")) {
            result.resume_session = true;
        } else if (equals(arg, "--provider")) {
            if (takeValue(argv, &i)) |value| result.provider = value;
        } else if (equals(arg, "--model")) {
            if (takeValue(argv, &i)) |value| result.model = value;
        } else if (equals(arg, "--api-key")) {
            if (takeValue(argv, &i)) |value| result.api_key = value;
        } else if (equals(arg, "--system-prompt")) {
            if (takeValue(argv, &i)) |value| result.system_prompt = value;
        } else if (equals(arg, "--append-system-prompt")) {
            if (takeValue(argv, &i)) |value| result.addAppendSystemPrompt(value);
        } else if (equals(arg, "--no-session")) {
            result.no_session = true;
        } else if (equals(arg, "--session")) {
            if (takeValue(argv, &i)) |value| result.session = value;
        } else if (equals(arg, "--fork")) {
            if (takeValue(argv, &i)) |value| result.fork = value;
        } else if (equals(arg, "--session-dir")) {
            if (takeValue(argv, &i)) |value| result.session_dir = value;
        } else if (equals(arg, "--models")) {
            if (takeValue(argv, &i)) |value| result.models = value;
        } else if (equals(arg, "--no-tools") or equals(arg, "-nt")) {
            result.no_tools = true;
        } else if (equals(arg, "--no-builtin-tools") or equals(arg, "-nbt")) {
            result.no_builtin_tools = true;
        } else if (equals(arg, "--tools") or equals(arg, "-t")) {
            if (takeValue(argv, &i)) |value| result.tools = value;
        } else if (equals(arg, "--thinking")) {
            if (takeValue(argv, &i)) |value| {
                result.thinking = types.ThinkingLevel.parse(value);
                if (result.thinking == null) result.addDiagnostic(.warning, "invalid thinking level");
            }
        } else if (equals(arg, "--print") or equals(arg, "-p")) {
            result.print = true;
            if (i + 1 < argv.len and isPrintInlinePrompt(argv[i + 1])) {
                i += 1;
                result.addMessage(argv[i]);
            }
        } else if (equals(arg, "--export")) {
            if (takeValue(argv, &i)) |value| result.export_path = value;
        } else if (equals(arg, "--extension") or equals(arg, "-e")) {
            if (takeValue(argv, &i)) |value| result.addExtension(value);
        } else if (equals(arg, "--no-extensions") or equals(arg, "-ne")) {
            result.no_extensions = true;
        } else if (equals(arg, "--skill")) {
            if (takeValue(argv, &i)) |value| result.addSkill(value);
        } else if (equals(arg, "--prompt-template")) {
            if (takeValue(argv, &i)) |value| result.addPromptTemplate(value);
        } else if (equals(arg, "--theme")) {
            if (takeValue(argv, &i)) |value| result.addTheme(value);
        } else if (equals(arg, "--no-skills") or equals(arg, "-ns")) {
            result.no_skills = true;
        } else if (equals(arg, "--no-prompt-templates") or equals(arg, "-np")) {
            result.no_prompt_templates = true;
        } else if (equals(arg, "--no-themes")) {
            result.no_themes = true;
        } else if (equals(arg, "--no-context-files") or equals(arg, "-nc")) {
            result.no_context_files = true;
        } else if (equals(arg, "--list-models")) {
            result.list_models = true;
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-") and !std.mem.startsWith(u8, argv[i + 1], "@")) {
                i += 1;
                result.list_models_pattern = argv[i];
            }
        } else if (equals(arg, "--verbose")) {
            result.verbose = true;
        } else if (equals(arg, "--offline")) {
            result.offline = true;
        } else if (std.mem.startsWith(u8, arg, "@")) {
            result.addFileArg(arg[1..]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                result.addUnknownFlag(arg[2..eq], arg[eq + 1 ..]);
            } else {
                const flag_name = arg[2..];
                if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-") and !std.mem.startsWith(u8, argv[i + 1], "@")) {
                    i += 1;
                    result.addUnknownFlag(flag_name, argv[i]);
                } else {
                    result.addUnknownFlag(flag_name, null);
                }
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            result.addDiagnostic(.@"error", "unknown short option");
        } else {
            result.addMessage(arg);
        }
    }
    return result;
}

pub fn writeParsedArgsJson(io: std.Io, parsed: ParsedArgs) !void {
    var buf: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;

    try w.writeAll("{");
    try writeMaybeString(w, "provider", parsed.provider);
    try w.writeAll(",");
    try writeMaybeString(w, "model", parsed.model);
    try w.writeAll(",");
    try writeMaybeString(w, "apiKey", parsed.api_key);
    try w.writeAll(",");
    try writeMaybeString(w, "systemPrompt", parsed.system_prompt);
    try w.writeAll(",");
    try writeStringArray(w, "appendSystemPrompts", parsed.append_system_prompts[0..parsed.append_system_prompts_len]);
    try w.writeAll(",");
    try writeMaybeMode(w, "mode", parsed.mode);
    try w.writeAll(",");
    try writeMaybeThinking(w, "thinking", parsed.thinking);
    try w.print(
        ",\"print\":{},\"help\":{},\"version\":{},\"continue\":{},\"resume\":{},\"noSession\":{}",
        .{ parsed.print, parsed.help, parsed.version, parsed.continue_session, parsed.resume_session, parsed.no_session },
    );
    try w.writeAll(",");
    try writeMaybeString(w, "session", parsed.session);
    try w.writeAll(",");
    try writeMaybeString(w, "fork", parsed.fork);
    try w.writeAll(",");
    try writeMaybeString(w, "sessionDir", parsed.session_dir);
    try w.writeAll(",");
    try writeMaybeString(w, "models", parsed.models);
    try w.writeAll(",");
    try writeMaybeString(w, "tools", parsed.tools);
    try w.print(
        ",\"noTools\":{},\"noBuiltinTools\":{},\"listModels\":{},\"offline\":{},\"verbose\":{},\"noContextFiles\":{}",
        .{ parsed.no_tools, parsed.no_builtin_tools, parsed.list_models, parsed.offline, parsed.verbose, parsed.no_context_files },
    );
    try w.writeAll(",");
    try writeMaybeString(w, "listModelsPattern", parsed.list_models_pattern);
    try w.writeAll(",");
    try writeMaybeString(w, "export", parsed.export_path);
    try w.writeAll(",");
    try writeStringArray(w, "extensions", parsed.extensions[0..parsed.extensions_len]);
    try w.print(
        ",\"noExtensions\":{}",
        .{parsed.no_extensions},
    );
    try w.writeAll(",");
    try writeStringArray(w, "skills", parsed.skills[0..parsed.skills_len]);
    try w.print(
        ",\"noSkills\":{}",
        .{parsed.no_skills},
    );
    try w.writeAll(",");
    try writeStringArray(w, "promptTemplates", parsed.prompt_templates[0..parsed.prompt_templates_len]);
    try w.print(
        ",\"noPromptTemplates\":{}",
        .{parsed.no_prompt_templates},
    );
    try w.writeAll(",");
    try writeStringArray(w, "themes", parsed.themes[0..parsed.themes_len]);
    try w.print(
        ",\"noThemes\":{}",
        .{parsed.no_themes},
    );
    try w.writeAll(",");
    try writeStringArray(w, "messages", parsed.messages[0..parsed.messages_len]);
    try w.writeAll(",");
    try writeStringArray(w, "fileArgs", parsed.file_args[0..parsed.file_args_len]);
    try w.writeAll(",");
    try writeDiagnostics(w, parsed.diagnostics[0..parsed.diagnostics_len]);
    try w.writeAll(",");
    try writeUnknownFlags(w, parsed.unknown_flags[0..parsed.unknown_flags_len]);
    try w.writeAll("}\n");
    try w.flush();
}

fn addString(storage: *[MaxItems][]const u8, len: *usize, parsed: *ParsedArgs, diagnostic: []const u8, value: []const u8) void {
    if (len.* >= MaxItems) {
        parsed.addDiagnostic(.@"error", diagnostic);
        return;
    }
    storage.*[len.*] = value;
    len.* += 1;
}

fn takeValue(argv: []const []const u8, index: *usize) ?[]const u8 {
    if (index.* + 1 >= argv.len) return null;
    index.* += 1;
    return argv[index.*];
}

fn isPrintInlinePrompt(value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "@")) return false;
    if (!std.mem.startsWith(u8, value, "-")) return true;
    return std.mem.startsWith(u8, value, "---");
}

fn equals(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn writeMaybeString(w: *std.Io.Writer, key: []const u8, value: ?[]const u8) !void {
    try writeJsonString(w, key);
    try w.writeAll(":");
    if (value) |actual| {
        try writeJsonString(w, actual);
    } else {
        try w.writeAll("null");
    }
}

fn writeMaybeMode(w: *std.Io.Writer, key: []const u8, value: ?Mode) !void {
    try writeJsonString(w, key);
    try w.writeAll(":");
    if (value) |actual| {
        try writeJsonString(w, actual.label());
    } else {
        try w.writeAll("null");
    }
}

fn writeMaybeThinking(w: *std.Io.Writer, key: []const u8, value: ?types.ThinkingLevel) !void {
    try writeJsonString(w, key);
    try w.writeAll(":");
    if (value) |actual| {
        try writeJsonString(w, @tagName(actual));
    } else {
        try w.writeAll("null");
    }
}

fn writeStringArray(w: *std.Io.Writer, key: []const u8, values: []const []const u8) !void {
    try writeJsonString(w, key);
    try w.writeAll(":[");
    for (values, 0..) |value, i| {
        if (i != 0) try w.writeAll(",");
        try writeJsonString(w, value);
    }
    try w.writeAll("]");
}

fn writeDiagnostics(w: *std.Io.Writer, values: []const Diagnostic) !void {
    try w.writeAll("\"diagnostics\":[");
    for (values, 0..) |value, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"type\":");
        try writeJsonString(w, value.kind.label());
        try w.writeAll(",\"message\":");
        try writeJsonString(w, value.message);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

fn writeUnknownFlags(w: *std.Io.Writer, values: []const UnknownFlag) !void {
    try w.writeAll("\"unknownFlags\":[");
    for (values, 0..) |value, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeJsonString(w, value.name);
        try w.writeAll(",\"value\":");
        if (value.value) |actual| {
            try writeJsonString(w, actual);
        } else {
            try w.writeAll("true");
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeAll("\"");
    for (value) |char| {
        switch (char) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11...12, 14...31 => {
                const hex = "0123456789abcdef";
                const escaped = [_]u8{ '\\', 'u', '0', '0', hex[char >> 4], hex[char & 15] };
                try w.writeAll(&escaped);
            },
            else => {
                const byte = [_]u8{char};
                try w.writeAll(&byte);
            },
        }
    }
    try w.writeAll("\"");
}

test "parse print prompt and provider" {
    const parsed = parse(&.{ "--provider", "openai", "--thinking", "xhigh", "-p", "say ok", "@README.md" });
    try std.testing.expectEqualStrings("openai", parsed.provider.?);
    try std.testing.expectEqual(types.ThinkingLevel.xhigh, parsed.thinking.?);
    try std.testing.expect(parsed.print);
    try std.testing.expectEqual(@as(usize, 1), parsed.messages_len);
    try std.testing.expectEqualStrings("say ok", parsed.messages[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.file_args_len);
    try std.testing.expectEqualStrings("README.md", parsed.file_args[0]);
}

test "parse list models optional pattern and unknown flags" {
    const parsed = parse(&.{ "--list-models", "sonnet", "--custom=value", "--flag", "payload" });
    try std.testing.expect(parsed.list_models);
    try std.testing.expectEqualStrings("sonnet", parsed.list_models_pattern.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.unknown_flags_len);
    try std.testing.expectEqualStrings("custom", parsed.unknown_flags[0].name);
    try std.testing.expectEqualStrings("value", parsed.unknown_flags[0].value.?);
    try std.testing.expectEqualStrings("flag", parsed.unknown_flags[1].name);
    try std.testing.expectEqualStrings("payload", parsed.unknown_flags[1].value.?);
}

test "invalid thinking level creates warning" {
    const parsed = parse(&.{ "--thinking", "maximum" });
    try std.testing.expect(parsed.thinking == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostics_len);
    try std.testing.expectEqual(DiagnosticKind.warning, parsed.diagnostics[0].kind);
}

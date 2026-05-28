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

/// The valid `--thinking` levels, in upstream order. Shared by the diagnostic
/// renderer so the "Valid values: ..." list matches upstream args.ts exactly.
pub const valid_thinking_levels = "off, minimal, low, medium, high, xhigh";

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    /// Self-contained diagnostic text. For the structured introspection path
    /// (`writeParsedArgsJson`) the fully interpolated upstream message is rendered
    /// from `template` + `detail`; `message` is the upstream text with the offending
    /// value already embedded where one was available at parse time, or the static
    /// upstream sentence otherwise.
    message: []const u8,
    /// Diagnostic template, used by the JSON renderer to produce the byte-exact
    /// upstream message (interpolating `detail`). `.literal` means emit `message`.
    template: DiagnosticTemplate = .literal,
    /// Offending value borrowed from argv (stable for the lifetime of the parse
    /// result, since argv outlives it). Null for templates that need no value.
    detail: ?[]const u8 = null,
};

/// Selects the upstream message wording for a diagnostic. Mirrors the exact strings
/// in upstream/pi/packages/coding-agent/src/cli/args.ts.
pub const DiagnosticTemplate = enum {
    /// Emit `message` verbatim.
    literal,
    /// `Invalid thinking level "<detail>". Valid values: off, minimal, low, medium, high, xhigh`
    invalid_thinking_level,
    /// `Unknown option: <detail>`
    unknown_option,
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
        self.addDiagnosticFull(kind, message, .literal, null);
    }

    /// Add a diagnostic with an upstream message template and an optional offending
    /// value (`detail`, borrowed from argv). The JSON renderer interpolates these
    /// to produce the byte-exact upstream message.
    fn addDiagnosticFull(self: *ParsedArgs, kind: DiagnosticKind, message: []const u8, template: DiagnosticTemplate, detail: ?[]const u8) void {
        if (self.diagnostics_len >= MaxDiagnostics) return;
        self.diagnostics[self.diagnostics_len] = .{ .kind = kind, .message = message, .template = template, .detail = detail };
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
        } else if (equals(arg, "--mode") and hasValue(argv, i)) {
            // Upstream silently ignores an invalid --mode value (no diagnostic).
            if (takeValue(argv, &i)) |value| {
                if (Mode.parse(value)) |mode| result.mode = mode;
            }
        } else if (equals(arg, "--continue") or equals(arg, "-c")) {
            result.continue_session = true;
        } else if (equals(arg, "--resume") or equals(arg, "-r")) {
            result.resume_session = true;
        } else if (equals(arg, "--provider") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.provider = value;
        } else if (equals(arg, "--model") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.model = value;
        } else if (equals(arg, "--api-key") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.api_key = value;
        } else if (equals(arg, "--system-prompt") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.system_prompt = value;
        } else if (equals(arg, "--append-system-prompt") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.addAppendSystemPrompt(value);
        } else if (equals(arg, "--no-session")) {
            result.no_session = true;
        } else if (equals(arg, "--session") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.session = value;
        } else if (equals(arg, "--fork") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.fork = value;
        } else if (equals(arg, "--session-dir") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.session_dir = value;
        } else if (equals(arg, "--models") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.models = value;
        } else if (equals(arg, "--no-tools") or equals(arg, "-nt")) {
            result.no_tools = true;
        } else if (equals(arg, "--no-builtin-tools") or equals(arg, "-nbt")) {
            result.no_builtin_tools = true;
        } else if ((equals(arg, "--tools") or equals(arg, "-t")) and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.tools = value;
        } else if (equals(arg, "--thinking") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| {
                result.thinking = types.ThinkingLevel.parse(value);
                // Upstream: `Invalid thinking level "<value>". Valid values: off, minimal, low, medium, high, xhigh`.
                if (result.thinking == null) result.addDiagnosticFull(.warning, "Invalid thinking level", .invalid_thinking_level, value);
            }
        } else if (equals(arg, "--print") or equals(arg, "-p")) {
            result.print = true;
            if (i + 1 < argv.len and isPrintInlinePrompt(argv[i + 1])) {
                i += 1;
                result.addMessage(argv[i]);
            }
        } else if (equals(arg, "--export") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.export_path = value;
        } else if ((equals(arg, "--extension") or equals(arg, "-e")) and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.addExtension(value);
        } else if (equals(arg, "--no-extensions") or equals(arg, "-ne")) {
            result.no_extensions = true;
        } else if (equals(arg, "--skill") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.addSkill(value);
        } else if (equals(arg, "--prompt-template") and hasValue(argv, i)) {
            if (takeValue(argv, &i)) |value| result.addPromptTemplate(value);
        } else if (equals(arg, "--theme") and hasValue(argv, i)) {
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
            // Upstream: `Unknown option: <arg>` (a hard error that aborts the run).
            result.addDiagnosticFull(.@"error", "Unknown option", .unknown_option, arg);
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

/// Mirrors upstream's `i + 1 < args.length` guard on value-taking flags.
/// When false, the flag falls through to the generic unknown-flag / unknown
/// short-option handling (matching upstream/pi/.../cli/args.ts parseArgs).
fn hasValue(argv: []const []const u8, index: usize) bool {
    return index + 1 < argv.len;
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
        // Render the fully interpolated upstream message as a single JSON string.
        try w.writeByte('"');
        try renderDiagnosticMessageEscaped(w, value);
        try w.writeByte('"');
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

/// Render a diagnostic's fully interpolated, byte-exact upstream message, escaping
/// it for a JSON string context (the surrounding quotes are written by the caller).
fn renderDiagnosticMessageEscaped(w: *std.Io.Writer, diagnostic: Diagnostic) !void {
    switch (diagnostic.template) {
        .literal => try writeJsonStringContents(w, diagnostic.message),
        .invalid_thinking_level => {
            try writeJsonStringContents(w, "Invalid thinking level \"");
            try writeJsonStringContents(w, diagnostic.detail orelse "");
            try writeJsonStringContents(w, "\". Valid values: ");
            try writeJsonStringContents(w, valid_thinking_levels);
        },
        .unknown_option => {
            try writeJsonStringContents(w, "Unknown option: ");
            try writeJsonStringContents(w, diagnostic.detail orelse "");
        },
    }
}

/// Render a diagnostic's fully interpolated, byte-exact upstream message as plain
/// text (no JSON escaping) into `w`. Public so callers that surface diagnostics in
/// a text context can match upstream wording without re-deriving it.
pub fn renderDiagnosticMessage(w: *std.Io.Writer, diagnostic: Diagnostic) !void {
    switch (diagnostic.template) {
        .literal => try w.writeAll(diagnostic.message),
        .invalid_thinking_level => {
            try w.writeAll("Invalid thinking level \"");
            try w.writeAll(diagnostic.detail orelse "");
            try w.writeAll("\". Valid values: ");
            try w.writeAll(valid_thinking_levels);
        },
        .unknown_option => {
            try w.writeAll("Unknown option: ");
            try w.writeAll(diagnostic.detail orelse "");
        },
    }
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
    try writeJsonStringContents(w, value);
    try w.writeAll("\"");
}

/// Escape `value` for a JSON string context WITHOUT the surrounding quotes, so
/// several fragments can be concatenated inside one JSON string.
fn writeJsonStringContents(w: *std.Io.Writer, value: []const u8) !void {
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
    try std.testing.expectEqual(DiagnosticTemplate.invalid_thinking_level, parsed.diagnostics[0].template);
    try std.testing.expectEqualStrings("maximum", parsed.diagnostics[0].detail.?);
}

test "diagnostic messages render exactly like upstream args.ts" {
    // Invalid --thinking value -> upstream's interpolated warning.
    {
        const parsed = parse(&.{ "--thinking", "maximum" });
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try renderDiagnosticMessage(&w, parsed.diagnostics[0]);
        try std.testing.expectEqualStrings(
            "Invalid thinking level \"maximum\". Valid values: off, minimal, low, medium, high, xhigh",
            w.buffered(),
        );
    }
    // Unknown short option -> `Unknown option: <arg>`.
    {
        const parsed = parse(&.{"-x"});
        try std.testing.expectEqual(@as(usize, 1), parsed.diagnostics_len);
        try std.testing.expectEqual(DiagnosticKind.@"error", parsed.diagnostics[0].kind);
        try std.testing.expectEqual(DiagnosticTemplate.unknown_option, parsed.diagnostics[0].template);
        var buf: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try renderDiagnosticMessage(&w, parsed.diagnostics[0]);
        try std.testing.expectEqualStrings("Unknown option: -x", w.buffered());
    }
}

test "diagnostics serialize the fully interpolated upstream message to JSON" {
    // The JSON introspection path embeds the byte-exact upstream message text.
    const parsed = parse(&.{ "--thinking", "bogus", "-z" });
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeDiagnostics(&w, parsed.diagnostics[0..parsed.diagnostics_len]);
    const json = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json, "Invalid thinking level \\\"bogus\\\". Valid values: off, minimal, low, medium, high, xhigh") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Unknown option: -z") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"error\"") != null);
}

test "value flag without value falls through to unknown flag (upstream parity)" {
    // Upstream args.ts guards value flags with `&& i + 1 < args.length`; when the
    // value is missing the flag falls through to the generic `--` handler and is
    // recorded as an unknown flag with value true (serialized as `true`).
    const parsed = parse(&.{"--provider"});
    try std.testing.expect(parsed.provider == null);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics_len);
    try std.testing.expectEqual(@as(usize, 1), parsed.unknown_flags_len);
    try std.testing.expectEqualStrings("provider", parsed.unknown_flags[0].name);
    try std.testing.expect(parsed.unknown_flags[0].value == null);

    // --export, --models, --mode behave the same way at end-of-argv.
    const export_parsed = parse(&.{"--export"});
    try std.testing.expect(export_parsed.export_path == null);
    try std.testing.expectEqual(@as(usize, 1), export_parsed.unknown_flags_len);
    try std.testing.expectEqualStrings("export", export_parsed.unknown_flags[0].name);

    const mode_parsed = parse(&.{"--mode"});
    try std.testing.expect(mode_parsed.mode == null);
    try std.testing.expectEqual(@as(usize, 1), mode_parsed.unknown_flags_len);
    try std.testing.expectEqualStrings("mode", mode_parsed.unknown_flags[0].name);
}

test "short value alias without value is an unknown short option error (upstream parity)" {
    // `-t` / `-e` at end-of-argv fall through to the single-dash branch, which
    // upstream reports as `Unknown option: -t` (an error diagnostic), not an
    // unknown long flag.
    const parsed_t = parse(&.{"-t"});
    try std.testing.expect(parsed_t.tools == null);
    try std.testing.expectEqual(@as(usize, 0), parsed_t.unknown_flags_len);
    try std.testing.expectEqual(@as(usize, 1), parsed_t.diagnostics_len);
    try std.testing.expectEqual(DiagnosticKind.@"error", parsed_t.diagnostics[0].kind);

    const parsed_e = parse(&.{"-e"});
    try std.testing.expectEqual(@as(usize, 1), parsed_e.diagnostics_len);
    try std.testing.expectEqual(DiagnosticKind.@"error", parsed_e.diagnostics[0].kind);
}

test "invalid mode value is silently ignored (upstream parity)" {
    // Upstream only assigns mode when the value is text|json|rpc; an invalid value
    // is dropped with no diagnostic (unlike --thinking which warns).
    const parsed = parse(&.{ "--mode", "bogus" });
    try std.testing.expect(parsed.mode == null);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics_len);
    try std.testing.expectEqual(@as(usize, 0), parsed.unknown_flags_len);
}

test "value flag consumes following dash-prefixed token as literal value (upstream parity)" {
    // `--provider --model x`: since a token follows, --provider greedily consumes
    // `--model` as its literal value, leaving `x` as a positional message.
    const parsed = parse(&.{ "--provider", "--model", "x" });
    try std.testing.expectEqualStrings("--model", parsed.provider.?);
    try std.testing.expect(parsed.model == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.messages_len);
    try std.testing.expectEqualStrings("x", parsed.messages[0]);
}

test "tools and models still parse when value present" {
    const parsed = parse(&.{ "--tools", "read,bash", "-e", "ext.ts", "--models", "a,b" });
    try std.testing.expectEqualStrings("read,bash", parsed.tools.?);
    try std.testing.expectEqualStrings("a,b", parsed.models.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.extensions_len);
    try std.testing.expectEqualStrings("ext.ts", parsed.extensions[0]);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics_len);
}

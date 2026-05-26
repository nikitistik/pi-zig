const std = @import("std");
const pi = @import("pi-zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return pi.cli_runtime.runTopLevel(init, &.{});

    const command = args[1];

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        return pi.cli_runtime.writeTopLevelHelp(init.io);
    }

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "version")) {
        return writeAll(init.io, pi.config.version ++ "\n");
    }

    if (try pi.package_manager.run(init.io, init.arena.allocator(), init.environ_map, args[1..])) return;
    if (try pi.themes.run(init.io, init.arena.allocator(), init.environ_map, args[1..])) return;
    if (try pi.context_files.run(init.io, init.arena.allocator(), init.environ_map, args[1..])) return;
    if (try pi.system_prompt.run(init.io, init.arena.allocator(), init.environ_map, args[1..])) return;

    if (std.mem.eql(u8, command, "status")) {
        try writeAll(init.io, "pi-zig foundation\n");
        try writeAll(init.io, "upstream: earendil-works/pi fc8a1559017f1e581cfa971aa3cef11a507a4975\n");
        try writeAll(init.io, "mode: Zig backend/runtime + Preact frontend\n");
        try writeAll(init.io, "parity: in progress; see docs/parity.md\n");
        return;
    }

    if (std.mem.eql(u8, command, "inventory")) {
        return pi.upstream.writeInventoryJson(init.io);
    }

    if (std.mem.eql(u8, command, "packages")) {
        return pi.upstream.writePackagesJson(init.io);
    }

    if (std.mem.eql(u8, command, "providers")) {
        return pi.upstream.writeProvidersJson(init.io);
    }

    if (std.mem.eql(u8, command, "models")) {
        return pi.models.writeAllJson(init.io);
    }

    if (std.mem.eql(u8, command, "models-for")) {
        if (args.len < 3) return usage(init.io);
        return pi.models.writeProviderModelsJson(init.io, args[2]);
    }

    if (std.mem.eql(u8, command, "model")) {
        if (args.len < 4) return usage(init.io);
        if (pi.models.find(args[2], args[3])) |model_entry| {
            return pi.models.writeModelJsonLine(init.io, model_entry);
        }
        return writeAll(init.io, "{\"error\":\"model not found\"}\n");
    }

    if (std.mem.eql(u8, command, "list-models")) {
        const pattern = if (args.len >= 3) args[2] else null;
        return pi.models.writeListModelsJson(init.io, pattern);
    }

    if (std.mem.eql(u8, command, "resolve-model")) {
        if (args.len < 3) return usage(init.io);
        if (std.mem.eql(u8, args[2], "--provider")) {
            if (args.len < 5) return usage(init.io);
            return pi.models.writeResolvedCliJson(init.io, args[3], args[4]);
        }
        return pi.models.writeResolvedCliJson(init.io, null, args[2]);
    }

    if (std.mem.eql(u8, command, "provider-env")) {
        if (args.len < 3) return usage(init.io);
        return pi.providers.writeProviderEnvJson(init.io, args[2]);
    }

    if (std.mem.eql(u8, command, "tools")) {
        return pi.upstream.writeToolsJson(init.io);
    }

    if (std.mem.eql(u8, command, "rpc-schema")) {
        return pi.upstream.writeRpcSchemaJson(init.io);
    }

    if (std.mem.eql(u8, command, "commands")) {
        const parsed = pi.cli.parse(args[2..]);
        return pi.commands.writeCommandsJsonWithOptions(init.io, init.gpa, commandOptionsFromParsed(init, &parsed));
    }

    if (std.mem.eql(u8, command, "rpc")) {
        const session_file = if (args.len >= 3) args[2] else pi.session.default_session_file;
        return pi.rpc.run(init.io, init.gpa, session_file, commandOptionsFromInit(init));
    }

    if (std.mem.eql(u8, command, "parity")) {
        return pi.upstream.writeParityJson(init.io);
    }

    if (std.mem.eql(u8, command, "parse-args")) {
        const parsed = pi.cli.parse(args[2..]);
        return pi.cli.writeParsedArgsJson(init.io, parsed);
    }

    if (std.mem.eql(u8, command, "tool-read")) {
        if (args.len < 3) return usage(init.io);
        const bytes = try pi.tools.readFile(init.io, init.gpa, args[2], 512 * 1024);
        defer init.gpa.free(bytes);
        return writeAll(init.io, bytes);
    }

    if (std.mem.eql(u8, command, "tool-bash")) {
        if (args.len < 3) return usage(init.io);
        return pi.tools.runShell(init.io, init.gpa, args[2]);
    }

    if (std.mem.eql(u8, command, "tool-ls")) {
        const path = if (args.len >= 3) args[2] else ".";
        return pi.tools.listDir(init.io, path);
    }

    if (std.mem.eql(u8, command, "tool-grep")) {
        if (args.len < 4) return usage(init.io);
        return pi.tools.grepFile(init.io, init.gpa, args[2], args[3], 512 * 1024);
    }

    if (std.mem.eql(u8, command, "tool-find")) {
        if (args.len < 3) return usage(init.io);
        const path = if (args.len >= 4) args[3] else ".";
        const limit = if (args.len >= 5) std.fmt.parseInt(usize, args[4], 10) catch return usage(init.io) else 1000;
        return pi.tools.findFiles(init.io, init.gpa, args[2], path, limit);
    }

    if (std.mem.eql(u8, command, "tool-write")) {
        if (args.len < 4) return usage(init.io);
        return pi.tools.writeFile(init.io, args[2], args[3]);
    }

    if (std.mem.eql(u8, command, "tool-edit")) {
        if (args.len < 5) return usage(init.io);
        return pi.tools.editFile(init.io, init.gpa, args[2], args[3], args[4]);
    }

    return pi.cli_runtime.runTopLevel(init, args[1..]);
}

fn usage(io: std.Io) !void {
    try writeAll(io,
        \\pi-zig
        \\
        \\Commands:
        \\  status
        \\  inventory
        \\  install <source> [-l]
        \\  remove <source> [-l]
        \\  uninstall <source> [-l]
        \\  list
        \\  update [source|self|pi] [--self] [--extensions] [--extension <source>] [--force]
        \\  themes [--theme <path>] [--export <name>] [--resolved <name>] [--detect]
        \\  context-files [--no-context-files]
        \\  system-prompt [--json] [--no-context-files]
        \\  packages
        \\  providers
        \\  models
        \\  models-for <provider>
        \\  model <provider> <model-id>
        \\  list-models [search]
        \\  resolve-model [--provider provider] <pattern>
        \\  provider-env <provider>
        \\  tools
        \\  rpc-schema
        \\  commands
        \\  rpc [session-file]
        \\  parity
        \\  parse-args [pi CLI args...]
        \\  tool-read <path>
        \\  tool-bash <command>
        \\  tool-ls [path]
        \\  tool-grep <pattern> <path>
        \\  tool-find <pattern> [path] [limit]
        \\  tool-write <path> <content>
        \\  tool-edit <path> <oldText> <newText>
        \\  --help, -h
        \\  --version, -v
        \\
        \\Current scope: foundation inventory and backend contract smoke only.
        \\See docs/parity.md for incomplete surfaces.
        \\
    );
}

fn writeAll(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn commandOptionsFromInit(init: std.process.Init) pi.commands.Options {
    return .{ .home = init.environ_map.get("HOME") };
}

fn commandOptionsFromParsed(init: std.process.Init, parsed: *const pi.cli.ParsedArgs) pi.commands.Options {
    return .{
        .home = init.environ_map.get("HOME"),
        .additional_skill_paths = parsed.skills[0..parsed.skills_len],
        .additional_prompt_paths = parsed.prompt_templates[0..parsed.prompt_templates_len],
        .no_skills = parsed.no_skills,
        .no_prompt_templates = parsed.no_prompt_templates,
    };
}

const std = @import("std");
const generated = @import("models.generated.zig");
const types = @import("types.zig");

pub const ModelEntry = generated.ModelEntry;
pub const all = generated.models[0..];
pub const providers = generated.provider_names[0..];
pub const upstream_model_count = generated.upstream_model_count;
pub const upstream_provider_count = generated.upstream_provider_count;

const thinking_order = [_]types.ThinkingLevel{ .off, .minimal, .low, .medium, .high, .xhigh };

/// Scratch buffer big enough to hold the longest interpolated resolver warning
/// (custom-model fallback embeds the pattern + provider names verbatim). Sized to
/// comfortably exceed any realistic CLI `--model`/`--provider` value so the
/// `bufPrint` calls below never truncate; resolution is allocation-free.
const warning_buf_len = 1024;
const WarningBuf = [warning_buf_len]u8;

const ParsedPattern = struct {
    model: ?*const ModelEntry = null,
    thinking_level: ?types.ThinkingLevel = null,
    warning: ?[]const u8 = null,
};

pub fn find(provider: []const u8, model_id: []const u8) ?*const ModelEntry {
    for (all) |*model| {
        if (std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, model_id)) return model;
    }
    return null;
}

pub fn canonicalProvider(provider: []const u8) ?[]const u8 {
    for (providers) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, provider)) return candidate;
    }
    return null;
}

pub fn findExactModelReference(reference: []const u8) ?*const ModelEntry {
    return findExactInSlice(reference, all);
}

pub fn indexOf(model: *const ModelEntry) ?usize {
    for (all, 0..) |*candidate, i| {
        if (candidate == model) return i;
    }
    return null;
}

pub fn writeResolvedCliJson(io: std.Io, cli_provider: ?[]const u8, cli_model: []const u8) !void {
    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;

    const provider = if (cli_provider) |provider_name| canonicalProvider(provider_name) orelse {
        try w.writeAll("{\"model\":null,\"thinkingLevel\":null,\"warning\":null,\"error\":\"Unknown provider ");
        try writeJsonStringContents(w, provider_name);
        try w.writeAll(". Use --list-models to see available providers/models.\",\"customModel\":false}\n");
        try w.flush();
        return;
    } else null;

    var warning_scratch: WarningBuf = undefined;
    if (resolveCli(provider, cli_model, &warning_scratch)) |resolved| {
        try w.writeAll("{\"model\":");
        try writeResolvedModelJson(w, resolved);
        try w.writeAll(",\"thinkingLevel\":");
        if (resolved.thinking_level) |level| {
            try writeJsonString(w, thinkingLevelLabel(level));
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"warning\":");
        if (resolved.warning) |warning| {
            try writeJsonString(w, warning);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"error\":null,\"customModel\":");
        try w.writeAll(if (resolved.custom_model) "true" else "false");
        try w.writeAll("}\n");
        try w.flush();
        return;
    }

    try w.writeAll("{\"model\":null,\"thinkingLevel\":null,\"warning\":null,\"error\":\"Model ");
    if (provider) |provider_name| {
        try writeJsonStringContents(w, provider_name);
        try w.writeByte('/');
    }
    try writeJsonStringContents(w, cli_model);
    try w.writeAll(" not found. Use --list-models to see available models.\",\"customModel\":false}\n");
    try w.flush();
}

pub fn writeListModelsJson(io: std.Io, pattern: ?[]const u8) !void {
    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll("{\"models\":[");
    var emitted: usize = 0;
    for (all) |*model| {
        if (pattern) |needle| {
            if (!modelMatchesSearch(model, needle)) continue;
        }
        if (emitted != 0) try w.writeByte(',');
        try writeModelJson(w, model);
        emitted += 1;
    }
    try w.writeAll("],\"count\":");
    try w.print("{d}", .{emitted});
    try w.writeAll("}\n");
    try w.flush();
}

pub fn next(model: ?*const ModelEntry) *const ModelEntry {
    if (all.len == 0) unreachable;
    const current_index = if (model) |selected| indexOf(selected) orelse 0 else 0;
    return &all[(current_index + 1) % all.len];
}

pub fn supportsThinking(model: *const ModelEntry) bool {
    return model.reasoning;
}

pub fn thinkingLevelSupported(model: *const ModelEntry, level: types.ThinkingLevel) bool {
    if (!model.reasoning) return level == .off;
    return switch (level) {
        .off => !model.thinking_off_disabled,
        .minimal => !model.thinking_minimal_disabled,
        .low => !model.thinking_low_disabled,
        .medium => !model.thinking_medium_disabled,
        .high => !model.thinking_high_disabled,
        .xhigh => model.thinking_xhigh_supported,
    };
}

pub fn clampThinkingLevel(model: *const ModelEntry, requested: types.ThinkingLevel) types.ThinkingLevel {
    if (thinkingLevelSupported(model, requested)) return requested;

    const requested_index = thinkingLevelIndex(requested);
    var forward = requested_index;
    while (forward < thinking_order.len) : (forward += 1) {
        if (thinkingLevelSupported(model, thinking_order[forward])) return thinking_order[forward];
    }

    var backward = requested_index;
    while (backward > 0) {
        backward -= 1;
        if (thinkingLevelSupported(model, thinking_order[backward])) return thinking_order[backward];
    }

    return .off;
}

pub fn nextThinkingLevel(model: ?*const ModelEntry, current: types.ThinkingLevel) ?types.ThinkingLevel {
    if (model == null) return nextLevelFromFullSet(current);
    const selected = model.?;
    if (!supportsThinking(selected)) return null;

    const current_index = thinkingLevelIndex(current);
    var offset: usize = 1;
    while (offset <= thinking_order.len) : (offset += 1) {
        const candidate = thinking_order[(current_index + offset) % thinking_order.len];
        if (thinkingLevelSupported(selected, candidate)) return candidate;
    }
    return null;
}

const ResolvedCliModel = struct {
    base_model: *const ModelEntry,
    override_id: ?[]const u8 = null,
    thinking_level: ?types.ThinkingLevel = null,
    warning: ?[]const u8 = null,
    custom_model: bool = false,
};

/// Resolve a model from CLI flags, mirroring upstream `resolveCliModel`.
/// Any interpolated warning string is written into `warning_scratch` (a caller-owned
/// buffer); the returned `warning` slice borrows from it, so the buffer must outlive
/// the result. Resolution itself performs no heap allocation.
fn resolveCli(cli_provider: ?[]const u8, cli_model: []const u8, warning_scratch: *WarningBuf) ?ResolvedCliModel {
    var provider = cli_provider;
    var pattern = cli_model;
    var inferred_provider = false;

    if (provider == null) {
        if (std.mem.indexOfScalar(u8, cli_model, '/')) |slash_index| {
            const maybe_provider = cli_model[0..slash_index];
            if (canonicalProvider(maybe_provider)) |canonical| {
                provider = canonical;
                pattern = cli_model[slash_index + 1 ..];
                inferred_provider = true;
            }
        }
    }

    if (provider == null) {
        if (findExactModelReference(cli_model)) |exact| {
            return .{ .base_model = exact };
        }
    }

    if (cli_provider != null and provider != null) {
        const canonical_prefix = provider.?;
        if (startsWithProviderPrefix(cli_model, canonical_prefix)) {
            pattern = cli_model[canonical_prefix.len + 1 ..];
        }
    }

    const parsed = if (provider) |provider_name|
        parseModelPatternInProvider(pattern, provider_name, false, warning_scratch)
    else
        parseModelPatternInSlice(pattern, all, false, warning_scratch);

    if (parsed.model) |model| {
        return .{ .base_model = model, .thinking_level = parsed.thinking_level, .warning = parsed.warning };
    }

    if (inferred_provider) {
        if (findExactModelReference(cli_model)) |exact| {
            return .{ .base_model = exact };
        }
        const fallback = parseModelPatternInSlice(cli_model, all, false, warning_scratch);
        if (fallback.model) |model| {
            return .{ .base_model = model, .thinking_level = fallback.thinking_level, .warning = fallback.warning };
        }
    }

    if (provider) |provider_name| {
        if (baseModelForCustomProviderModel(provider_name)) |base| {
            // Mirror upstream resolveCliModel's interpolated fallback warning:
            //   `Model "<pattern>" not found for provider "<provider>". Using custom model id.`
            // When the inner pattern parse already produced a warning (invalid
            // thinking level), upstream prepends it to the fallback warning.
            const fallback_warning = if (parsed.warning) |inner|
                std.fmt.bufPrint(
                    warning_scratch,
                    "{s} Model \"{s}\" not found for provider \"{s}\". Using custom model id.",
                    .{ inner, pattern, provider_name },
                ) catch null
            else
                std.fmt.bufPrint(
                    warning_scratch,
                    "Model \"{s}\" not found for provider \"{s}\". Using custom model id.",
                    .{ pattern, provider_name },
                ) catch null;
            return .{
                .base_model = base,
                .override_id = pattern,
                .warning = fallback_warning,
                .custom_model = true,
            };
        }
    }

    return null;
}

/// Result of resolving a single scope pattern (e.g. one entry of `--models`).
pub const ScopedModelResult = struct {
    model: ?*const ModelEntry = null,
    thinking_level: ?types.ThinkingLevel = null,
    warning: ?[]const u8 = null,
};

/// Resolve a single scope pattern against the full model catalog, mirroring the
/// non-glob branch of upstream `resolveModelScope` + `parseModelPattern` (scope
/// mode: `allowInvalidThinkingLevelFallback` defaults to true, so an invalid
/// `:suffix` warns and falls back to the prefix rather than failing).
///
/// `warning_scratch` backs any interpolated invalid-thinking-level warning; the
/// returned `warning` borrows from it and must not outlive the buffer. Glob
/// patterns (`*`/`?`/`[`) are intentionally NOT handled here — the upstream glob
/// branch yields a *set* of models via minimatch, which the future `--models`
/// wiring will own separately; this single-result helper covers the fuzzy/exact
/// pattern path that the resolver edge-case tests exercise.
pub fn resolveScopePattern(pattern: []const u8, warning_scratch: *WarningBuf) ScopedModelResult {
    const parsed = parseModelPatternInSlice(pattern, all, true, warning_scratch);
    return .{ .model = parsed.model, .thinking_level = parsed.thinking_level, .warning = parsed.warning };
}

fn parseModelPatternInProvider(pattern: []const u8, provider: []const u8, allow_invalid_thinking_level_fallback: bool, warning_scratch: ?*WarningBuf) ParsedPattern {
    var candidates: [512]*const ModelEntry = undefined;
    var len: usize = 0;
    for (all) |*model| {
        if (!std.mem.eql(u8, model.provider, provider)) continue;
        if (len >= candidates.len) break;
        candidates[len] = model;
        len += 1;
    }
    return parseModelPatternInPointerSlice(pattern, candidates[0..len], allow_invalid_thinking_level_fallback, warning_scratch);
}

fn parseModelPatternInSlice(pattern: []const u8, candidates: []const ModelEntry, allow_invalid_thinking_level_fallback: bool, warning_scratch: ?*WarningBuf) ParsedPattern {
    var pointers: [1024]*const ModelEntry = undefined;
    var len: usize = 0;
    for (candidates) |*model| {
        if (len >= pointers.len) break;
        pointers[len] = model;
        len += 1;
    }
    return parseModelPatternInPointerSlice(pattern, pointers[0..len], allow_invalid_thinking_level_fallback, warning_scratch);
}

/// Mirror upstream `parseModelPattern`: try the full pattern as a model, else split
/// on the last colon. A valid thinking-level suffix recurses on the prefix and
/// attaches the level; an invalid suffix either fails (strict CLI mode,
/// `allow_invalid_thinking_level_fallback=false`) or warns and recurses on the
/// prefix (scope mode). The interpolated invalid-level warning borrows from
/// `warning_scratch` when provided.
fn parseModelPatternInPointerSlice(
    pattern: []const u8,
    candidates: []const *const ModelEntry,
    allow_invalid_thinking_level_fallback: bool,
    warning_scratch: ?*WarningBuf,
) ParsedPattern {
    if (tryMatchModelInPointerSlice(pattern, candidates)) |model| {
        return .{ .model = model };
    }

    const colon_index = std.mem.lastIndexOfScalar(u8, pattern, ':') orelse return .{};
    const prefix = pattern[0..colon_index];
    const suffix = pattern[colon_index + 1 ..];

    if (types.ThinkingLevel.parse(suffix)) |level| {
        const parsed = parseModelPatternInPointerSlice(prefix, candidates, allow_invalid_thinking_level_fallback, warning_scratch);
        if (parsed.model) |_| {
            // Only attach the parsed thinking level when the inner recursion had no
            // warning, matching upstream (a warning takes precedence over a level).
            if (parsed.warning == null) {
                return .{ .model = parsed.model, .thinking_level = level };
            }
        }
        return parsed;
    }

    if (!allow_invalid_thinking_level_fallback) return .{};
    const parsed = parseModelPatternInPointerSlice(prefix, candidates, allow_invalid_thinking_level_fallback, warning_scratch);
    if (parsed.model) |_| {
        const warning = if (warning_scratch) |scratch|
            std.fmt.bufPrint(
                scratch,
                "Invalid thinking level \"{s}\" in pattern \"{s}\". Using default instead.",
                .{ suffix, pattern },
            ) catch "Invalid thinking level in model pattern. Using default instead."
        else
            "Invalid thinking level in model pattern. Using default instead.";
        return .{ .model = parsed.model, .warning = warning };
    }
    return parsed;
}

fn tryMatchModelInPointerSlice(pattern: []const u8, candidates: []const *const ModelEntry) ?*const ModelEntry {
    if (findExactInPointerSlice(pattern, candidates)) |exact| return exact;

    var best_alias: ?*const ModelEntry = null;
    var best_dated: ?*const ModelEntry = null;
    for (candidates) |model| {
        if (!containsIgnoreCase(model.id, pattern) and !containsIgnoreCase(model.name, pattern)) continue;
        if (isAlias(model.id)) {
            if (best_alias == null or compareModelIdDesc(model, best_alias.?)) best_alias = model;
        } else {
            if (best_dated == null or compareModelIdDesc(model, best_dated.?)) best_dated = model;
        }
    }

    return best_alias orelse best_dated;
}

fn findExactInSlice(reference: []const u8, candidates: []const ModelEntry) ?*const ModelEntry {
    var pointers: [1024]*const ModelEntry = undefined;
    var len: usize = 0;
    for (candidates) |*model| {
        if (len >= pointers.len) break;
        pointers[len] = model;
        len += 1;
    }
    return findExactInPointerSlice(reference, pointers[0..len]);
}

fn findExactInPointerSlice(reference: []const u8, candidates: []const *const ModelEntry) ?*const ModelEntry {
    const trimmed = std.mem.trim(u8, reference, " \t\r\n");
    if (trimmed.len == 0) return null;

    var canonical_match: ?*const ModelEntry = null;
    var canonical_count: usize = 0;
    for (candidates) |model| {
        if (modelReferenceEquals(model, trimmed)) {
            canonical_match = model;
            canonical_count += 1;
        }
    }
    if (canonical_count == 1) return canonical_match;
    if (canonical_count > 1) return null;

    if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash_index| {
        const provider = std.mem.trim(u8, trimmed[0..slash_index], " \t\r\n");
        const model_id = std.mem.trim(u8, trimmed[slash_index + 1 ..], " \t\r\n");
        if (provider.len != 0 and model_id.len != 0) {
            var provider_match: ?*const ModelEntry = null;
            var provider_count: usize = 0;
            for (candidates) |model| {
                if (std.ascii.eqlIgnoreCase(model.provider, provider) and std.ascii.eqlIgnoreCase(model.id, model_id)) {
                    provider_match = model;
                    provider_count += 1;
                }
            }
            if (provider_count == 1) return provider_match;
            if (provider_count > 1) return null;
        }
    }

    var id_match: ?*const ModelEntry = null;
    var id_count: usize = 0;
    for (candidates) |model| {
        if (std.ascii.eqlIgnoreCase(model.id, trimmed)) {
            id_match = model;
            id_count += 1;
        }
    }
    return if (id_count == 1) id_match else null;
}

fn baseModelForCustomProviderModel(provider: []const u8) ?*const ModelEntry {
    if (defaultModelForProvider(provider)) |default_id| {
        if (find(provider, default_id)) |model| return model;
    }
    for (all) |*model| {
        if (std.mem.eql(u8, model.provider, provider)) return model;
    }
    return null;
}

fn defaultModelForProvider(provider: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider, "amazon-bedrock")) return "us.anthropic.claude-opus-4-6-v1";
    if (std.mem.eql(u8, provider, "anthropic")) return "claude-opus-4-7";
    if (std.mem.eql(u8, provider, "openai")) return "gpt-5.4";
    if (std.mem.eql(u8, provider, "azure-openai-responses")) return "gpt-5.4";
    if (std.mem.eql(u8, provider, "openai-codex")) return "gpt-5.5";
    if (std.mem.eql(u8, provider, "deepseek")) return "deepseek-v4-pro";
    if (std.mem.eql(u8, provider, "google")) return "gemini-3.1-pro-preview";
    if (std.mem.eql(u8, provider, "google-vertex")) return "gemini-3.1-pro-preview";
    if (std.mem.eql(u8, provider, "github-copilot")) return "gpt-5.4";
    if (std.mem.eql(u8, provider, "openrouter")) return "moonshotai/kimi-k2.6";
    if (std.mem.eql(u8, provider, "vercel-ai-gateway")) return "zai/glm-5.1";
    if (std.mem.eql(u8, provider, "xai")) return "grok-4.20-0309-reasoning";
    if (std.mem.eql(u8, provider, "groq")) return "openai/gpt-oss-120b";
    if (std.mem.eql(u8, provider, "cerebras")) return "zai-glm-4.7";
    if (std.mem.eql(u8, provider, "zai")) return "glm-5.1";
    if (std.mem.eql(u8, provider, "mistral")) return "devstral-medium-latest";
    if (std.mem.eql(u8, provider, "minimax")) return "MiniMax-M2.7";
    if (std.mem.eql(u8, provider, "minimax-cn")) return "MiniMax-M2.7";
    if (std.mem.eql(u8, provider, "moonshotai")) return "kimi-k2.6";
    if (std.mem.eql(u8, provider, "moonshotai-cn")) return "kimi-k2.6";
    if (std.mem.eql(u8, provider, "huggingface")) return "moonshotai/Kimi-K2.6";
    if (std.mem.eql(u8, provider, "fireworks")) return "accounts/fireworks/models/kimi-k2p6";
    if (std.mem.eql(u8, provider, "together")) return "moonshotai/Kimi-K2.6";
    if (std.mem.eql(u8, provider, "opencode")) return "kimi-k2.6";
    if (std.mem.eql(u8, provider, "opencode-go")) return "kimi-k2.6";
    if (std.mem.eql(u8, provider, "kimi-coding")) return "kimi-for-coding";
    if (std.mem.eql(u8, provider, "cloudflare-workers-ai")) return "@cf/moonshotai/kimi-k2.6";
    if (std.mem.eql(u8, provider, "cloudflare-ai-gateway")) return "workers-ai/@cf/moonshotai/kimi-k2.6";
    if (std.mem.eql(u8, provider, "xiaomi")) return "mimo-v2.5-pro";
    if (std.mem.eql(u8, provider, "xiaomi-token-plan-cn")) return "mimo-v2.5-pro";
    if (std.mem.eql(u8, provider, "xiaomi-token-plan-ams")) return "mimo-v2.5-pro";
    if (std.mem.eql(u8, provider, "xiaomi-token-plan-sgp")) return "mimo-v2.5-pro";
    return null;
}

pub fn writeAllJson(io: std.Io) !void {
    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll("{\"providers\":");
    try writeProviderArrayJson(w);
    try w.writeAll(",\"totalModels\":");
    try w.print("{d}", .{all.len});
    try w.writeAll(",\"models\":[");
    try writeModelsJson(w, null);
    try w.writeAll("]}\n");
    try w.flush();
}

pub fn writeProviderModelsJson(io: std.Io, provider: []const u8) !void {
    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll("{\"provider\":");
    try writeJsonString(w, provider);
    try w.writeAll(",\"models\":[");
    try writeModelsJson(w, provider);
    try w.writeAll("]}\n");
    try w.flush();
}

pub fn writeModelJsonLine(io: std.Io, model: *const ModelEntry) !void {
    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try writeModelJson(w, model);
    try w.writeByte('\n');
    try w.flush();
}

pub fn writeRpcAvailableModelsData(w: *std.Io.Writer) !void {
    try w.writeAll("{\"models\":[");
    try writeModelsJson(w, null);
    try w.writeAll("]}");
}

pub fn writeModelJson(w: *std.Io.Writer, model: *const ModelEntry) !void {
    try writeModelJsonWithOverride(w, model, null);
}

fn writeResolvedModelJson(w: *std.Io.Writer, resolved: ResolvedCliModel) !void {
    try writeModelJsonWithOverride(w, resolved.base_model, resolved.override_id);
}

fn writeModelJsonWithOverride(w: *std.Io.Writer, model: *const ModelEntry, override_id: ?[]const u8) !void {
    const id = override_id orelse model.id;
    const name = override_id orelse model.name;
    try w.writeAll("{\"id\":");
    try writeJsonString(w, id);
    try w.writeAll(",\"name\":");
    try writeJsonString(w, name);
    try w.writeAll(",\"api\":");
    try writeJsonString(w, model.api);
    try w.writeAll(",\"provider\":");
    try writeJsonString(w, model.provider);
    try w.writeAll(",\"baseUrl\":");
    try writeJsonString(w, model.base_url);
    try w.writeAll(",\"reasoning\":");
    try w.writeAll(if (model.reasoning) "true" else "false");
    try w.writeAll(",\"input\":[");
    var input_count: usize = 0;
    if (model.input_text) {
        try w.writeAll("\"text\"");
        input_count += 1;
    }
    if (model.input_image) {
        if (input_count != 0) try w.writeByte(',');
        try w.writeAll("\"image\"");
    }
    try w.writeAll("],\"cost\":{\"input\":");
    try w.print("{d}", .{model.cost_input});
    try w.writeAll(",\"output\":");
    try w.print("{d}", .{model.cost_output});
    try w.writeAll(",\"cacheRead\":");
    try w.print("{d}", .{model.cost_cache_read});
    try w.writeAll(",\"cacheWrite\":");
    try w.print("{d}", .{model.cost_cache_write});
    try w.writeAll("},\"contextWindow\":");
    try w.print("{d}", .{model.context_window});
    try w.writeAll(",\"maxTokens\":");
    try w.print("{d}", .{model.max_tokens});
    try w.writeAll(",\"supportedThinkingLevels\":");
    try writeSupportedThinkingLevelsJson(w, model);
    try w.writeByte('}');
}

fn writeModelsJson(w: *std.Io.Writer, provider: ?[]const u8) !void {
    var emitted: usize = 0;
    for (all) |*model| {
        if (provider) |provider_name| {
            if (!std.mem.eql(u8, provider_name, model.provider)) continue;
        }
        if (emitted != 0) try w.writeByte(',');
        try writeModelJson(w, model);
        emitted += 1;
    }
}

fn writeProviderArrayJson(w: *std.Io.Writer) !void {
    try w.writeByte('[');
    for (providers, 0..) |provider, i| {
        if (i != 0) try w.writeByte(',');
        try writeJsonString(w, provider);
    }
    try w.writeByte(']');
}

fn modelMatchesSearch(model: *const ModelEntry, pattern: []const u8) bool {
    return containsIgnoreCase(model.provider, pattern) or
        containsIgnoreCase(model.id, pattern) or
        containsIgnoreCase(model.name, pattern);
}

fn writeSupportedThinkingLevelsJson(w: *std.Io.Writer, model: *const ModelEntry) !void {
    try w.writeByte('[');
    var emitted: usize = 0;
    for (thinking_order) |level| {
        if (!thinkingLevelSupported(model, level)) continue;
        if (emitted != 0) try w.writeByte(',');
        try writeJsonString(w, thinkingLevelLabel(level));
        emitted += 1;
    }
    try w.writeByte(']');
}

fn nextLevelFromFullSet(level: types.ThinkingLevel) types.ThinkingLevel {
    return switch (level) {
        .off => .minimal,
        .minimal => .low,
        .low => .medium,
        .medium => .high,
        .high => .xhigh,
        .xhigh => .off,
    };
}

fn thinkingLevelIndex(level: types.ThinkingLevel) usize {
    return switch (level) {
        .off => 0,
        .minimal => 1,
        .low => 2,
        .medium => 3,
        .high => 4,
        .xhigh => 5,
    };
}

fn thinkingLevelLabel(level: types.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn startsWithProviderPrefix(value: []const u8, provider: []const u8) bool {
    if (value.len <= provider.len or value[provider.len] != '/') return false;
    return std.ascii.eqlIgnoreCase(value[0..provider.len], provider);
}

fn modelReferenceEquals(model: *const ModelEntry, reference: []const u8) bool {
    if (reference.len != model.provider.len + 1 + model.id.len) return false;
    if (!std.ascii.eqlIgnoreCase(reference[0..model.provider.len], model.provider)) return false;
    if (reference[model.provider.len] != '/') return false;
    return std.ascii.eqlIgnoreCase(reference[model.provider.len + 1 ..], model.id);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn isAlias(id: []const u8) bool {
    if (std.mem.endsWith(u8, id, "-latest")) return true;
    if (id.len < 9) return true;
    const suffix = id[id.len - 9 ..];
    if (suffix[0] != '-') return true;
    for (suffix[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return true;
    }
    return false;
}

fn compareModelIdDesc(left: *const ModelEntry, right: *const ModelEntry) bool {
    return std.mem.order(u8, left.id, right.id) == .gt;
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

fn writeJsonStringContents(w: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789abcdef";
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
}

test "generated model catalog is anchored to upstream counts" {
    try std.testing.expectEqual(@as(usize, 924), all.len);
    try std.testing.expectEqual(@as(usize, 32), providers.len);
}

test "anthropic haiku model is available with thinking metadata" {
    const model = find("anthropic", "claude-haiku-4-5").?;
    try std.testing.expectEqualStrings("Claude Haiku 4.5 (latest)", model.name);
    try std.testing.expect(model.reasoning);
    try std.testing.expect(thinkingLevelSupported(model, .xhigh) == false);
    try std.testing.expectEqual(types.ThinkingLevel.medium, clampThinkingLevel(model, .medium));
}

test "model resolver handles provider prefixes and thinking suffixes" {
    var scratch: WarningBuf = undefined;
    const direct = resolveCli(null, "anthropic/claude-haiku-4-5", &scratch).?;
    try std.testing.expectEqualStrings("anthropic", direct.base_model.provider);
    try std.testing.expectEqualStrings("claude-haiku-4-5", direct.base_model.id);

    const fuzzy = resolveCli("anthropic", "haiku:high", &scratch).?;
    try std.testing.expectEqual(types.ThinkingLevel.high, fuzzy.thinking_level.?);
    try std.testing.expect(containsIgnoreCase(fuzzy.base_model.id, "haiku"));
}

test "model resolver builds provider-scoped custom model fallback" {
    var scratch: WarningBuf = undefined;
    const custom = resolveCli("anthropic", "custom-model", &scratch).?;
    try std.testing.expect(custom.custom_model);
    try std.testing.expectEqualStrings("custom-model", custom.override_id.?);
    try std.testing.expectEqualStrings("anthropic", custom.base_model.provider);
    // Upstream interpolates the pattern + provider into the fallback warning.
    try std.testing.expectEqualStrings(
        "Model \"custom-model\" not found for provider \"anthropic\". Using custom model id.",
        custom.warning.?,
    );
}

test "model resolver infers provider from slash and prefers provider/model split" {
    var scratch: WarningBuf = undefined;
    // "<provider>/<pattern>" with no --provider: the slash prefix is a known
    // provider, so resolution scopes to it (upstream resolveCliModel slash path).
    const inferred = resolveCli(null, "anthropic/haiku", &scratch).?;
    try std.testing.expectEqualStrings("anthropic", inferred.base_model.provider);
    try std.testing.expect(containsIgnoreCase(inferred.base_model.id, "haiku"));
    try std.testing.expect(inferred.warning == null);
}

test "model resolver strips redundant provider prefix when both provider and model given" {
    var scratch: WarningBuf = undefined;
    // --provider anthropic --model anthropic/claude-haiku-4-5: upstream strips the
    // duplicated "<provider>/" prefix rather than treating it as a custom id.
    const resolved = resolveCli("anthropic", "anthropic/claude-haiku-4-5", &scratch).?;
    try std.testing.expectEqualStrings("anthropic", resolved.base_model.provider);
    try std.testing.expectEqualStrings("claude-haiku-4-5", resolved.base_model.id);
    try std.testing.expect(!resolved.custom_model);
}

test "model resolver does not strip invalid :suffix as thinking level in strict CLI mode" {
    var scratch: WarningBuf = undefined;
    // Strict mode (allowInvalidThinkingLevelFallback=false): a model whose id ends
    // in a colon suffix that is NOT a thinking level must resolve as a raw id, not
    // get the suffix stripped. Build a synthetic candidate set to assert this
    // precisely against the documented OpenRouter ":exacto" behavior.
    const openrouter_colon = [_]ModelEntry{
        makeTestModel("openrouter", "qwen/qwen3-coder:exacto", "Qwen3 Coder Exacto"),
        makeTestModel("openai", "gpt-4o", "GPT-4o"),
    };
    // Exact match on the colon id (strict mode) keeps the suffix.
    const parsed = parseModelPatternInSlice("qwen/qwen3-coder:exacto", &openrouter_colon, false, &scratch);
    try std.testing.expectEqualStrings("qwen/qwen3-coder:exacto", parsed.model.?.id);
    try std.testing.expect(parsed.thinking_level == null);
    try std.testing.expect(parsed.warning == null);

    // A valid thinking suffix after the colon id is still parsed off in strict mode.
    const with_level = parseModelPatternInSlice("qwen/qwen3-coder:exacto:high", &openrouter_colon, false, &scratch);
    try std.testing.expectEqualStrings("qwen/qwen3-coder:exacto", with_level.model.?.id);
    try std.testing.expectEqual(types.ThinkingLevel.high, with_level.thinking_level.?);

    // An invalid suffix in strict mode fails (no model) rather than stripping it.
    const invalid_strict = parseModelPatternInSlice("gpt-4o:bogus", &openrouter_colon, false, &scratch);
    try std.testing.expect(invalid_strict.model == null);
}

test "scope-mode parseModelPattern warns and falls back on invalid thinking level" {
    var scratch: WarningBuf = undefined;
    const candidates = [_]ModelEntry{
        makeTestModel("anthropic", "claude-sonnet-4-5", "Claude Sonnet 4.5"),
        makeTestModel("openai", "gpt-4o", "GPT-4o"),
    };
    // "sonnet:random" -> matches sonnet, no thinking level, interpolated warning.
    const random = parseModelPatternInSlice("sonnet:random", &candidates, true, &scratch);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", random.model.?.id);
    try std.testing.expect(random.thinking_level == null);
    try std.testing.expectEqualStrings(
        "Invalid thinking level \"random\" in pattern \"sonnet:random\". Using default instead.",
        random.warning.?,
    );

    // "sonnet:" (empty suffix) -> not a valid level, warns, falls back to "sonnet".
    const trailing_colon = parseModelPatternInSlice("sonnet:", &candidates, true, &scratch);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", trailing_colon.model.?.id);
    try std.testing.expect(std.mem.indexOf(u8, trailing_colon.warning.?, "Invalid thinking level") != null);

    // Double-invalid suffix still resolves the model with a warning.
    const double = parseModelPatternInSlice("sonnet:high:random", &candidates, true, &scratch);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", double.model.?.id);
    try std.testing.expect(std.mem.indexOf(u8, double.warning.?, "Invalid thinking level") != null);
}

test "scope pattern resolver matches catalog models and parses thinking levels" {
    var scratch: WarningBuf = undefined;
    const haiku = resolveScopePattern("haiku:low", &scratch);
    try std.testing.expect(haiku.model != null);
    try std.testing.expect(containsIgnoreCase(haiku.model.?.id, "haiku"));
    try std.testing.expectEqual(types.ThinkingLevel.low, haiku.thinking_level.?);

    const none = resolveScopePattern("definitely-not-a-real-model-xyz", &scratch);
    try std.testing.expect(none.model == null);
}

test "tryMatchModel prefers aliases over dated versions then sorts highest" {
    // Two dated versions + one alias; the alias wins (upstream isAlias branch).
    const candidates = [_]ModelEntry{
        makeTestModel("anthropic", "claude-sonnet-4-5-20250101", "Claude Sonnet 4.5"),
        makeTestModel("anthropic", "claude-sonnet-4-5-20250929", "Claude Sonnet 4.5"),
        makeTestModel("anthropic", "claude-sonnet-4-5", "Claude Sonnet 4.5 (latest)"),
    };
    var pointers: [3]*const ModelEntry = undefined;
    for (&candidates, 0..) |*m, i| pointers[i] = m;
    const matched = tryMatchModelInPointerSlice("sonnet", &pointers).?;
    try std.testing.expectEqualStrings("claude-sonnet-4-5", matched.id);

    // With only dated versions, the highest-sorting date wins.
    var dated_only: [2]*const ModelEntry = .{ &candidates[0], &candidates[1] };
    const latest_dated = tryMatchModelInPointerSlice("sonnet", &dated_only).?;
    try std.testing.expectEqualStrings("claude-sonnet-4-5-20250929", latest_dated.id);
}

test "cycling order walks the catalog and wraps around" {
    // next() advances by one index and wraps; nextThinkingLevel cycles supported
    // levels for a reasoning model and returns null for a non-reasoning one.
    const first = &all[0];
    const second = next(first);
    try std.testing.expectEqual(@as(usize, 1), indexOf(second).?);
    const last = &all[all.len - 1];
    try std.testing.expectEqual(@as(usize, 0), indexOf(next(last)).?);

    const haiku = find("anthropic", "claude-haiku-4-5").?;
    // Haiku supports thinking but not xhigh; cycling from high must skip xhigh and
    // wrap to off (the lowest supported level), never landing on the disabled one.
    const after_high = nextThinkingLevel(haiku, .high).?;
    try std.testing.expect(after_high != .xhigh);
}

/// Build a throwaway ModelEntry for resolver unit tests. Only the fields the
/// resolver/cycling logic reads (provider, id, name) are meaningful; the rest get
/// neutral defaults so tests stay isolated from the generated catalog.
fn makeTestModel(provider: []const u8, id: []const u8, name: []const u8) ModelEntry {
    return .{
        .id = id,
        .name = name,
        .api = "anthropic-messages",
        .provider = provider,
        .base_url = "https://example.test",
        .reasoning = false,
        .input_text = true,
        .input_image = false,
        .cost_input = 0,
        .cost_output = 0,
        .cost_cache_read = 0,
        .cost_cache_write = 0,
        .context_window = 0,
        .max_tokens = 0,
        .thinking_off_disabled = false,
        .thinking_minimal_disabled = false,
        .thinking_low_disabled = false,
        .thinking_medium_disabled = false,
        .thinking_high_disabled = false,
        .thinking_xhigh_supported = false,
    };
}

const std = @import("std");

const EnvMapping = struct {
    provider: []const u8,
    keys: []const []const u8,
};

const anthropic_keys = [_][]const u8{ "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY" };
const github_copilot_keys = [_][]const u8{"COPILOT_GITHUB_TOKEN"};
const openai_keys = [_][]const u8{"OPENAI_API_KEY"};
const azure_openai_keys = [_][]const u8{"AZURE_OPENAI_API_KEY"};
const amazon_bedrock_keys = [_][]const u8{"AWS_BEARER_TOKEN_BEDROCK"};
const deepseek_keys = [_][]const u8{"DEEPSEEK_API_KEY"};
const google_keys = [_][]const u8{"GEMINI_API_KEY"};
const google_vertex_keys = [_][]const u8{"GOOGLE_CLOUD_API_KEY"};
const groq_keys = [_][]const u8{"GROQ_API_KEY"};
const cerebras_keys = [_][]const u8{"CEREBRAS_API_KEY"};
const xai_keys = [_][]const u8{"XAI_API_KEY"};
const openrouter_keys = [_][]const u8{"OPENROUTER_API_KEY"};
const gateway_keys = [_][]const u8{"AI_GATEWAY_API_KEY"};
const zai_keys = [_][]const u8{"ZAI_API_KEY"};
const mistral_keys = [_][]const u8{"MISTRAL_API_KEY"};
const minimax_keys = [_][]const u8{"MINIMAX_API_KEY"};
const minimax_cn_keys = [_][]const u8{"MINIMAX_CN_API_KEY"};
const moonshot_keys = [_][]const u8{"MOONSHOT_API_KEY"};
const huggingface_keys = [_][]const u8{"HF_TOKEN"};
const fireworks_keys = [_][]const u8{"FIREWORKS_API_KEY"};
const together_keys = [_][]const u8{"TOGETHER_API_KEY"};
const opencode_keys = [_][]const u8{"OPENCODE_API_KEY"};
const kimi_keys = [_][]const u8{"KIMI_API_KEY"};
const cloudflare_keys = [_][]const u8{"CLOUDFLARE_API_KEY"};
const xiaomi_keys = [_][]const u8{"XIAOMI_API_KEY"};
const xiaomi_cn_keys = [_][]const u8{"XIAOMI_TOKEN_PLAN_CN_API_KEY"};
const xiaomi_ams_keys = [_][]const u8{"XIAOMI_TOKEN_PLAN_AMS_API_KEY"};
const xiaomi_sgp_keys = [_][]const u8{"XIAOMI_TOKEN_PLAN_SGP_API_KEY"};

pub const env_mappings = [_]EnvMapping{
    .{ .provider = "anthropic", .keys = &anthropic_keys },
    .{ .provider = "github-copilot", .keys = &github_copilot_keys },
    .{ .provider = "openai", .keys = &openai_keys },
    .{ .provider = "azure-openai-responses", .keys = &azure_openai_keys },
    .{ .provider = "amazon-bedrock", .keys = &amazon_bedrock_keys },
    .{ .provider = "deepseek", .keys = &deepseek_keys },
    .{ .provider = "google", .keys = &google_keys },
    .{ .provider = "google-vertex", .keys = &google_vertex_keys },
    .{ .provider = "groq", .keys = &groq_keys },
    .{ .provider = "cerebras", .keys = &cerebras_keys },
    .{ .provider = "xai", .keys = &xai_keys },
    .{ .provider = "openrouter", .keys = &openrouter_keys },
    .{ .provider = "vercel-ai-gateway", .keys = &gateway_keys },
    .{ .provider = "zai", .keys = &zai_keys },
    .{ .provider = "mistral", .keys = &mistral_keys },
    .{ .provider = "minimax", .keys = &minimax_keys },
    .{ .provider = "minimax-cn", .keys = &minimax_cn_keys },
    .{ .provider = "moonshotai", .keys = &moonshot_keys },
    .{ .provider = "moonshotai-cn", .keys = &moonshot_keys },
    .{ .provider = "huggingface", .keys = &huggingface_keys },
    .{ .provider = "fireworks", .keys = &fireworks_keys },
    .{ .provider = "together", .keys = &together_keys },
    .{ .provider = "opencode", .keys = &opencode_keys },
    .{ .provider = "opencode-go", .keys = &opencode_keys },
    .{ .provider = "kimi-coding", .keys = &kimi_keys },
    .{ .provider = "cloudflare-workers-ai", .keys = &cloudflare_keys },
    .{ .provider = "cloudflare-ai-gateway", .keys = &cloudflare_keys },
    .{ .provider = "xiaomi", .keys = &xiaomi_keys },
    .{ .provider = "xiaomi-token-plan-cn", .keys = &xiaomi_cn_keys },
    .{ .provider = "xiaomi-token-plan-ams", .keys = &xiaomi_ams_keys },
    .{ .provider = "xiaomi-token-plan-sgp", .keys = &xiaomi_sgp_keys },
};

pub fn envKeysFor(provider: []const u8) ?[]const []const u8 {
    for (env_mappings) |mapping| {
        if (std.mem.eql(u8, mapping.provider, provider)) return mapping.keys;
    }
    return null;
}

pub fn writeProviderEnvJson(io: std.Io, provider: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;

    try w.print("{{\"provider\":\"{s}\",\"envKeys\":[", .{provider});
    if (envKeysFor(provider)) |keys| {
        for (keys, 0..) |key, i| {
            if (i != 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{key});
        }
    }
    try w.writeAll("]}\n");
    try w.flush();
}

test "provider env map preserves oauth precedence" {
    const keys = envKeysFor("anthropic").?;
    try std.testing.expectEqualStrings("ANTHROPIC_OAUTH_TOKEN", keys[0]);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", keys[1]);
}

test "provider env map includes OpenRouter and Groq" {
    try std.testing.expectEqualStrings("OPENROUTER_API_KEY", envKeysFor("openrouter").?[0]);
    try std.testing.expectEqualStrings("GROQ_API_KEY", envKeysFor("groq").?[0]);
}

test "provider env map includes Bedrock bearer token" {
    try std.testing.expectEqualStrings("AWS_BEARER_TOKEN_BEDROCK", envKeysFor("amazon-bedrock").?[0]);
}

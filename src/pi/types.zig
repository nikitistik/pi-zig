const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,

    pub fn parse(value: []const u8) ?ThinkingLevel {
        inline for (std.meta.fields(ThinkingLevel)) |field| {
            if (std.mem.eql(u8, field.name, value)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub const ProviderKind = enum {
    openai_responses,
    openai_completions,
    openai_codex_responses,
    anthropic,
    google,
    google_vertex,
    mistral,
    bedrock,
    github_copilot,
    openrouter_images,
    cloudflare_images,
    faux,
};

test "thinking level parser matches upstream names" {
    try std.testing.expectEqual(ThinkingLevel.off, ThinkingLevel.parse("off").?);
    try std.testing.expectEqual(ThinkingLevel.xhigh, ThinkingLevel.parse("xhigh").?);
    try std.testing.expect(ThinkingLevel.parse("maximum") == null);
}

test "role labels are stable" {
    try std.testing.expectEqualStrings("assistant", Role.assistant.label());
}


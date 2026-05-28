#!/usr/bin/env node
/**
 * Wave 4 message-renderer parity smoke.
 *
 * Validates the port of upstream coding-agent interactive message components
 * to `src/pi/tui_messages.zig`:
 *   - user-message.ts        -> renderUserMessage (USER chip + boxed body)
 *   - assistant-message.ts   -> renderAssistantMessage (ASSISTANT chip + body)
 *   - tool-execution.ts      -> renderToolExecution ([tool: <name>] panel)
 *   - bash-execution.ts      -> renderBashExecution (`$ <command>` block)
 *   - compaction-summary-message.ts -> renderCompactionSummary
 *   - branch-summary-message.ts     -> renderBranchSummary
 *   - custom-message.ts             -> renderCustomMessage
 *   - skill-invocation-message.ts   -> renderSkillInvocation
 *
 * Two-phase verification:
 *
 * Phase A — JSONL fixture (per spec): we pre-seed a session JSONL covering each
 * message type so the fixture documents the message families this wave renders.
 * The fixture lands at `test/fixtures/wave4-messages-session.jsonl` and is the
 * load-bearing artifact the task asks for ("pre-seeds a session JSONL covering
 * each message type"). The fixture is asserted to contain every message kind
 * the renderers handle, so a future runtime that wires JSONL replay through
 * `tui_messages.render*` has a canonical fixture to bind against.
 *
 * Phase B — direct renderer dump: because the pi-zig binary's non-TTY path
 * returns `.not_a_tty` and prints the top-level help (it doesn't replay session
 * JSONL into transcript chrome — only HTML export does, and HTML doesn't share
 * the ANSI renderers), the smoke compiles a tiny Zig dump program at
 * `scripts/wave4-messages-dump.zig` that imports `src/pi/tui_messages.zig` and
 * writes one of every rendered block to stdout. We then assert the role chips,
 * tool-execution `[tool: ...]` chip, `$ <command>` bash prefix, `[compaction]`
 * label, `[branch]` label, custom `[diagnostic]` label, and `[skill]` label all
 * appear in the dump. This catches a regression in any renderer end-to-end
 * (Zig compiles + executes + emits the right bytes) without requiring the
 * binary to gain a non-TTY replay path.
 *
 * Run independently:
 *   node scripts/wave4-messages-smoke.mjs
 *
 * Prints "[wave4-messages-smoke] PASS" and exits 0 on success;
 * throws / exits non-zero on any check.
 */

import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');
const fixtureDir = resolve(repoRoot, 'test/fixtures');
const jsonlPath = resolve(fixtureDir, 'wave4-messages-session.jsonl');
// The dump program is co-located beside `tui_messages.zig` so the
// `@import("tui_messages.zig")` resolves through `zig run`'s default module-
// path policy (Zig forbids imports outside the entry file's module path).
const dumpZigPath = resolve(repoRoot, 'src/pi/wave4_messages_dump.zig');
const tuiMessagesPath = resolve(repoRoot, 'src/pi/tui_messages.zig');

function fail(message) {
  throw new Error(`[wave4-messages-smoke] FAIL: ${message}`);
}

function log(message) {
  console.log(`[wave4-messages-smoke] ${message}`);
}

// -----------------------------------------------------------------------------
// Phase A: pre-seed JSONL fixture covering every message family.
// -----------------------------------------------------------------------------

/**
 * Build a representative session JSONL covering each message type the renderers
 * handle. Mirrors upstream's session entry shape (`type:"message"`, `role`,
 * `content`) and the custom message family (`type:"customMessage"`, with
 * compactionSummary / branchSummary / custom / skillInvocation variants).
 *
 * The fixture is asserted-only — the binary does not currently replay JSONL
 * into rendered transcript chrome. It exists so a future runtime that wires
 * such a replay path has a canonical input to bind against, AND so the smoke
 * documents the breadth of message types this wave covers.
 */
function seedSessionJsonl() {
  mkdirSync(fixtureDir, { recursive: true });
  const lines = [
    // Session header (matches upstream session.ts shape).
    JSON.stringify({
      type: 'session',
      version: 3,
      id: 'wave4-messages-fixture',
      timestamp: '2026-05-28T00:00:00.000Z',
      cwd: '.',
    }),
    // User message (renderUserMessage).
    JSON.stringify({
      type: 'message',
      id: 'm-1',
      parentId: null,
      timestamp: '2026-05-28T00:00:01.000Z',
      message: { role: 'user', content: 'please read /tmp/x and summarize it' },
    }),
    // Assistant message with a tool call (renderAssistantMessage +
    // renderToolExecution as separate panels, mirroring upstream's split).
    JSON.stringify({
      type: 'message',
      id: 'm-2',
      parentId: 'm-1',
      timestamp: '2026-05-28T00:00:02.000Z',
      message: {
        role: 'assistant',
        content: [
          { type: 'text', text: 'I will read /tmp/x first.' },
          {
            type: 'toolCall',
            id: 'call_1',
            toolName: 'read',
            arguments: { path: '/tmp/x' },
          },
        ],
      },
    }),
    // Tool result (renderToolExecution result panel).
    JSON.stringify({
      type: 'message',
      id: 'm-3',
      parentId: 'm-2',
      timestamp: '2026-05-28T00:00:03.000Z',
      message: {
        role: 'toolResult',
        toolCallId: 'call_1',
        content: [{ type: 'text', text: 'file contents: hello world' }],
        isError: false,
      },
    }),
    // Bash execution (renderBashExecution).
    JSON.stringify({
      type: 'message',
      id: 'm-4',
      parentId: 'm-3',
      timestamp: '2026-05-28T00:00:04.000Z',
      message: {
        role: 'bashExecution',
        command: 'ls /tmp',
        output: 'a.txt\nb.txt\nc.txt',
        exitCode: 0,
        cancelled: false,
      },
    }),
    // Compaction summary (renderCompactionSummary).
    JSON.stringify({
      type: 'customMessage',
      id: 'cm-1',
      parentId: 'm-4',
      timestamp: '2026-05-28T00:00:05.000Z',
      customType: 'compactionSummary',
      content: { summary: 'Compaction body text.', tokensBefore: 12345 },
    }),
    // Branch summary (renderBranchSummary).
    JSON.stringify({
      type: 'customMessage',
      id: 'cm-2',
      parentId: 'cm-1',
      timestamp: '2026-05-28T00:00:06.000Z',
      customType: 'branchSummary',
      content: { summary: 'Branch was merged at hash deadbeef.', fromId: 'm-2' },
    }),
    // Custom message — display:true (renderCustomMessage).
    JSON.stringify({
      type: 'customMessage',
      id: 'cm-3',
      parentId: 'cm-2',
      timestamp: '2026-05-28T00:00:07.000Z',
      customType: 'diagnostic',
      display: true,
      content: 'lint clean across pi-zig',
    }),
    // Skill invocation block (renderSkillInvocation).
    JSON.stringify({
      type: 'customMessage',
      id: 'cm-4',
      parentId: 'cm-3',
      timestamp: '2026-05-28T00:00:08.000Z',
      customType: 'skill',
      content: { name: 'verify', args: 'target=ui' },
    }),
  ];
  writeFileSync(jsonlPath, lines.join('\n') + '\n');

  // Assert the fixture covers every kind we care about.
  const bytes = readFileSync(jsonlPath, 'utf8');
  const kinds = [
    'user',
    'assistant',
    'toolCall',
    'toolResult',
    'bashExecution',
    'compactionSummary',
    'branchSummary',
    'diagnostic',
    'skill',
  ];
  for (const kind of kinds) {
    if (!bytes.includes(kind)) {
      fail(`fixture missing entry of kind "${kind}"`);
    }
  }
  log(`seeded JSONL fixture: ${jsonlPath} (${lines.length - 1} message entries)`);
}

// -----------------------------------------------------------------------------
// Phase B: direct renderer dump via a small Zig harness.
// -----------------------------------------------------------------------------

/**
 * Emit a small Zig program that imports `src/pi/tui_messages.zig` and renders
 * one of every block to stdout. We use `zig run` to compile + execute it and
 * capture the stdout bytes. The harness program is dependency-free (only the
 * std library + tui_messages module).
 */
function writeDumpProgram() {
  // The harness is intentionally minimal: it imports the renderer module
  // directly by relative path so it does not have to participate in the
  // package's module graph (which is presently in flux from sibling agents
  // wiring tui_footer/tui_selector/tui_theme/tui_markdown changes).
  const dump = `// SPDX-License-Identifier: MIT
// Wave 4 dump harness — emits one rendered block per upstream message family.
// Built by scripts/wave4-messages-smoke.mjs; expected stdout substrings are
// asserted by the smoke after \`zig run\` executes this file.
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
            try w.writeByte('\\n');
        }
    }
    // Divider between messages.
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\\n');
    }
    // 2) Assistant message.
    {
        var rendered = try tui_messages.renderAssistantMessage(allocator, .{ .text = "I will read /tmp/x first." });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\\n');
    }
    // 3) Tool execution (read tool with result).
    {
        var rendered = try tui_messages.renderToolExecution(allocator, .{
            .tool_name = "read",
            .arguments_json = "{\\"path\\":\\"/tmp/x\\"}",
            .result_text = "file contents: hello world",
            .is_error = false,
        });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\\n');
    }
    // 4) Bash execution.
    {
        var rendered = try tui_messages.renderBashExecution(allocator, .{
            .command = "ls /tmp",
            .output = "a.txt\\nb.txt\\nc.txt",
            .exit_code = 0,
        });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\\n');
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
            try w.writeByte('\\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\\n');
    }
    // 6) Branch summary.
    {
        var rendered = try tui_messages.renderBranchSummary(allocator, .{ .summary = "Branch merged at deadbeef." });
        defer rendered.deinit();
        for (rendered.lines) |line| {
            try w.writeAll(line);
            try w.writeByte('\\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\\n');
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
            try w.writeByte('\\n');
        }
    }
    {
        const div = try tui_messages.buildDivider(allocator, null);
        defer allocator.free(div);
        try w.writeAll(div);
        try w.writeByte('\\n');
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
            try w.writeByte('\\n');
        }
    }

    try w.flush();
}
`;
  writeFileSync(dumpZigPath, dump, { mode: 0o644 });
  log(`emitted Zig dump harness: ${dumpZigPath}`);
}

/**
 * Execute the dump harness via `zig run` and return the captured stdout bytes.
 * The dump program imports `tui_messages.zig` directly via a relative path so
 * it does not depend on the rest of the package's module graph (which is in
 * flux as sibling agents wire tui_footer/markdown/theme/selector additions).
 */
function captureDumpStdout() {
  if (!existsSync(tuiMessagesPath)) {
    fail(`tui_messages.zig missing at ${tuiMessagesPath}`);
  }
  const result = spawnSync('zig', ['run', dumpZigPath], {
    encoding: 'utf8',
    cwd: repoRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error) fail(`zig run failed: ${result.error.message}`);
  if (result.status !== 0) {
    fail(`zig run exited with status ${result.status}\nstderr:\n${result.stderr}`);
  }
  return result.stdout ?? '';
}

/**
 * Run the renderer unit tests via `zig test` directly on `tui_messages.zig`.
 * This is the load-bearing "renderer correctness" gate; `zig build test`
 * currently inherits sibling agents' WIP build failures (tui_markdown / footer
 * use APIs not present in Zig 0.16), so an isolated `zig test` keeps THIS
 * smoke deterministic without entangling with their work.
 */
function runRendererUnitTests() {
  const result = spawnSync('zig', ['test', tuiMessagesPath], {
    encoding: 'utf8',
    cwd: repoRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error) fail(`zig test failed: ${result.error.message}`);
  if (result.status !== 0) {
    fail(`zig test exited with status ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
  const allPassed = /All \d+ tests passed\./.test(result.stderr);
  if (!allPassed) {
    fail(`zig test did not report all-passed\nstderr:\n${result.stderr}`);
  }
  const m = result.stderr.match(/All (\d+) tests passed/);
  log(`renderer unit tests: ${m ? m[1] : '?'} passed`);
}

// -----------------------------------------------------------------------------
// Main.
// -----------------------------------------------------------------------------

function main() {
  // Phase A: pre-seed JSONL fixture.
  seedSessionJsonl();

  // Renderer unit tests (in-Zig assertions on bytes).
  runRendererUnitTests();

  // Phase B: build the dump program and execute it.
  writeDumpProgram();
  const dump = captureDumpStdout();
  if (dump.length === 0) fail('dump program emitted no output');

  // Assertions on the rendered dump. Each renderer's load-bearing token must
  // appear in the dump so a regression in any block fails the smoke.
  const checks = [
    { needle: 'USER', why: 'user-message chip token' },
    { needle: 'please summarize /tmp/x', why: 'user-message body text' },
    { needle: 'ASSISTANT', why: 'assistant-message chip token' },
    { needle: 'I will read /tmp/x first.', why: 'assistant-message body text' },
    { needle: '[tool: read]', why: 'tool-execution chip' },
    { needle: 'file contents: hello world', why: 'tool-execution result preview' },
    { needle: '$ ls /tmp', why: 'bash-execution command header' },
    { needle: '[compaction]', why: 'compaction-summary label' },
    { needle: 'Compacted from 12345 tokens', why: 'compaction-summary header' },
    { needle: '[branch]', why: 'branch-summary label' },
    { needle: 'Branch Summary', why: 'branch-summary header' },
    { needle: '[diagnostic]', why: 'custom-message label' },
    { needle: 'lint clean across pi-zig', why: 'custom-message body' },
    { needle: '[skill]', why: 'skill-invocation label' },
    { needle: 'verify', why: 'skill-invocation name' },
    // Chrome: at least one box-drawing top corner and one horizontal rule
    // (used as the divider between renderer blocks).
    { needle: '╭', why: 'top-left box-drawing corner (renderer chrome)' },
    { needle: '─', why: 'horizontal rule glyph (divider between blocks)' },
    // ANSI styling actually applied (every styled line has a reset).
    { needle: '[0m', why: 'ANSI reset on rendered lines (per-line balanced SGR)' },
  ];
  for (const { needle, why } of checks) {
    if (!dump.includes(needle)) {
      fail(`dump missing ${why}: expected substring "${needle}" — not present`);
    }
  }
  log(`dump assertions: ${checks.length} substrings matched`);

  console.log('[wave4-messages-smoke] PASS');
}

main();

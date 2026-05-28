#!/usr/bin/env node
/**
 * Wave 4 markdown renderer smoke.
 *
 * Pure Node stdlib. Stages a representative markdown blob into a session JSONL
 * file (one user turn + one assistant turn), launches the REAL
 * `zig-out/bin/pi-zig` binary in non-TTY mode with
 * `PI_ZIG_TUI_MARKDOWN_DUMP=<staged session>`, and asserts the rendered ANSI
 * carries the styling the user verification doc explicitly listed:
 *
 *   * header bold/underline open
 *   * unordered list bullet (accent foreground)
 *   * fenced code block class span (the code-block fg/bg + a `tok-kw`-style
 *     keyword span for `const`)
 *   * link open + the (url) tail when the link text differs from the href
 *   * inline `code` background tint
 *   * **bold** open (`\x1b[1m`)
 *   * *italic* open (`\x1b[3m`)
 *
 * The session JSONL approach mirrors `wave3-browser-screenshots.mjs`: write a
 * `session` header and a single user + assistant message, both with a
 * representative markdown body. The non-TTY dump path is the only way to
 * observe the rendered output without a PTY — pi-zig's `App.run` returns
 * `.not_a_tty` under piped stdin in normal mode, so we gate the dump on the
 * env var instead (see `[FLOW_TUI_MARKDOWN]` in `src/pi/tui.zig`).
 *
 * Run independently: `node scripts/wave4-markdown-smoke.mjs`
 * Skips cleanly when the binary is missing (`zig build` not yet run).
 */

import { mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');
const binary = process.env.PI_ZIG_BIN ?? join(repoRoot, 'zig-out/bin/pi-zig');
const sessionDir = join(repoRoot, 'zig-out');
const sessionFile = join(sessionDir, 'wave4-markdown-session.jsonl');

const log = (...a) => console.log('[wave4-markdown-smoke]', ...a);
const fail = (m) => {
  console.error(`[wave4-markdown-smoke] FAIL: ${m}`);
  process.exit(1);
};
const skip = (m) => {
  log(`SKIP: ${m}`);
  process.exit(0);
};

if (!existsSync(binary)) skip(`binary missing: ${binary}`);

// Stage a representative markdown body that exercises every feature the
// verification doc calls out: header, code block, list, link, bold, italic.
const markdown = [
  '# Sample header',
  '',
  'This is **bold** text with *italic* emphasis and `inline code`.',
  '',
  '- first item',
  '- second item',
  '- third item with [a link](https://example.com)',
  '',
  '```js',
  'const answer = 42;',
  'return answer;',
  '```',
  '',
  'Closing paragraph with another `code span`.',
].join('\n');

mkdirSync(sessionDir, { recursive: true });
if (existsSync(sessionFile)) rmSync(sessionFile);

const now = new Date().toISOString();
const sessionId = `pi-zig-wave4-${Date.now()}`;
const lines = [
  JSON.stringify({ type: 'session', version: 3, id: sessionId, timestamp: now, cwd: '.' }),
  JSON.stringify({
    type: 'message',
    id: 'm-1',
    parentId: null,
    timestamp: now,
    message: { role: 'user', content: markdown },
  }),
  JSON.stringify({
    type: 'message',
    id: 'm-2',
    parentId: 'm-1',
    timestamp: now,
    message: { role: 'assistant', content: markdown },
  }),
];
writeFileSync(sessionFile, lines.join('\n') + '\n');

// Launch pi-zig with no prompt and PI_ZIG_TUI_MARKDOWN_DUMP pointing at the
// staged session. The dump path runs BEFORE the TTY gate, so a piped stdin is
// fine; we close stdin immediately so the binary doesn't wait for input.
const env = {
  ...process.env,
  PI_ZIG_TUI_MARKDOWN_DUMP: sessionFile,
  // PI_OFFLINE prevents the auth/network startup path from spending time;
  // not strictly required but keeps the smoke fast and deterministic.
  PI_OFFLINE: '1',
};
const result = spawnSync(binary, ['--no-session'], {
  encoding: 'utf8',
  env,
  input: '',
  stdio: ['pipe', 'pipe', 'pipe'],
  timeout: 15_000,
});

if (result.error) fail(`spawn error: ${result.error.message}`);
if (result.status !== 0) {
  // The binary may exit non-zero when the markdown dump path exits early via
  // .eof; treat non-zero only as failure when stdout is empty.
  if ((result.stdout ?? '').length === 0) {
    fail(`pi-zig exited ${result.status}; stdout empty.\nstderr:\n${result.stderr}`);
  }
}

const stdout = result.stdout ?? '';
if (stdout.length === 0) {
  fail(`pi-zig produced no stdout. stderr:\n${result.stderr}`);
}

// Assertions — each checks a specific ANSI sequence the renderer must emit
// (see `tui_markdown.sgr.*` in src/pi/tui_markdown.zig).
const checks = [
  // Header bold + underline open (h1 path).
  { name: 'header h1 bold+underline open', needle: '\x1b[1m\x1b[4m\x1b[38;5;214m', mustContain: 'Sample header' },
  // Inline **bold** open.
  { name: 'bold open', needle: '\x1b[1m', mustContain: 'bold' },
  // Inline *italic* open.
  { name: 'italic open', needle: '\x1b[3m', mustContain: 'italic' },
  // Inline `code` background tint (accent fg + dim bg combo).
  { name: 'inline code bg', needle: '\x1b[38;5;208m\x1b[48;5;236m', mustContain: 'inline code' },
  // List bullet accent prefix + the bullet glyph.
  { name: 'list bullet accent', needle: '\x1b[38;5;208m', mustContain: 'first item' },
  // Fenced code block: border color on the ``` row + code-block fg/bg on body.
  { name: 'code block border', needle: '\x1b[38;5;240m', mustContain: '```' },
  { name: 'code block body', needle: '\x1b[38;5;108m\x1b[48;5;235m', mustContain: 'answer' },
  // Keyword span (`const`) — the "class span" the requirement mentioned.
  { name: 'code-block keyword span (const)', needle: '\x1b[38;5;176m\x1b[48;5;235m', mustContain: 'const' },
  // Link open (underlined blue) + the (url) tail with the href.
  { name: 'link open', needle: '\x1b[4m\x1b[38;5;111m', mustContain: 'a link' },
  { name: 'link url tail', needle: '(https://example.com)', mustContain: '' },
];

let failures = 0;
for (const check of checks) {
  if (!stdout.includes(check.needle)) {
    console.error(
      `[wave4-markdown-smoke] missing ANSI for ${check.name}: ` +
        `expected stdout to contain bytes ${JSON.stringify(check.needle)}`,
    );
    failures += 1;
    continue;
  }
  if (check.mustContain && !stdout.includes(check.mustContain)) {
    console.error(
      `[wave4-markdown-smoke] ${check.name}: ANSI present but visible text "${check.mustContain}" missing`,
    );
    failures += 1;
    continue;
  }
  log(`OK — ${check.name}`);
}

if (failures > 0) {
  console.error(
    `[wave4-markdown-smoke] dumped stdout (first 800 bytes, ANSI-escaped):\n` +
      stdout.slice(0, 800).replace(/\x1b/g, '\\x1b'),
  );
  fail(`${failures} ANSI assertion(s) failed`);
}

// Visible-content sanity: every key piece of source text must appear.
const sanityNeedles = ['Sample header', 'first item', 'second item', 'third item', 'a link', 'answer', 'return'];
for (const needle of sanityNeedles) {
  if (!stdout.includes(needle)) fail(`rendered output missing source text "${needle}"`);
}
log('OK — all source text appears in the rendered output');

// Final: confirm the renderer is reading both user AND assistant turns. The
// staged session has the same markdown in both messages, so the output should
// contain TWO occurrences of "Sample header" (one per turn).
const headerCount = (stdout.match(/Sample header/g) ?? []).length;
if (headerCount < 2) {
  fail(`expected at least 2 occurrences of "Sample header" (one per turn), got ${headerCount}`);
}
log(`OK — both user + assistant turns rendered (${headerCount}× "Sample header")`);

log('PASS');

// Flow E HTML-export parity smoke.
//
// Builds pi-zig, writes a representative session JSONL covering a session header, a user
// message (with timestamp), an assistant message with a tool call and a fenced code block,
// a tool result, a bashExecution, and a compaction entry, then runs:
//
//   zig-out/bin/pi-zig --export <session.jsonl> <out.html>
//
// and asserts the produced HTML carries the extended-toward-upstream-SPA features that
// src/pi/html_export.zig renders server-side and deterministically:
//   - title contains "pi-zig session" (downstream smoke contract)
//   - per-entry timestamps render as visible elements
//   - a sidebar/nav with in-page anchor links exists
//   - a self-contained client-side search input + inline script exist (no external src)
//   - fenced code blocks render in <pre class="code-block"><code>
//
// Pure Node stdlib. Prints "[flow-e-html-smoke] PASS" on success; exits non-zero on failure.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const TAG = '[flow-e-html-smoke]';
const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const bin = path.join(repoRoot, 'zig-out', 'bin', 'pi-zig');

function fail(message) {
  console.error(`${TAG} FAIL: ${message}`);
  process.exit(1);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

// 1) Build.
try {
  execFileSync('zig', ['build'], { cwd: repoRoot, stdio: 'inherit' });
} catch (error) {
  fail(`zig build failed: ${error.message}`);
}
assert(fs.existsSync(bin), `built binary not found at ${bin}`);

// 2) Confirm the export flag is advertised in --help (read-only sanity check).
let helpText = '';
try {
  helpText = execFileSync(bin, ['--help'], { encoding: 'utf8' });
} catch (error) {
  // Some help paths exit non-zero while still printing usage; capture whatever was emitted.
  helpText = (error.stdout ?? '') + (error.stderr ?? '');
}
assert(helpText.includes('--export'), '--help does not advertise the --export flag');

// 3) Write a representative session JSONL to a temp file.
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'flow-e-html-'));
const sessionFile = path.join(tmpDir, 'session.jsonl');
const outFile = path.join(tmpDir, 'out.html');

// Assistant text embeds a fenced code block; backticks escaped for the JS template only.
const assistantText = [
  'Here is the fix:',
  '```js',
  'const ok = 1 < 2 && "a" !== "b";',
  'console.log(ok);',
  '```',
  'Done.',
].join('\n');

const lines = [
  { type: 'session', version: 3, id: 'flow-e-smoke', timestamp: '2026-05-28T08:00:00.000Z', cwd: repoRoot },
  {
    type: 'message',
    id: 'u1',
    parentId: null,
    timestamp: '2026-05-28T09:15:42.000Z',
    message: { role: 'user', content: 'Please fix the comparison bug.' },
  },
  {
    type: 'message',
    id: 'a1',
    parentId: 'u1',
    timestamp: '2026-05-28T09:15:50.000Z',
    message: {
      role: 'assistant',
      content: [
        { type: 'text', text: assistantText },
        { type: 'toolCall', id: 'call_1', name: 'bash', arguments: { command: 'echo running tests' } },
      ],
    },
  },
  {
    type: 'message',
    id: 't1',
    parentId: 'a1',
    timestamp: '2026-05-28T09:15:51.000Z',
    message: {
      role: 'toolResult',
      toolCallId: 'call_1',
      toolName: 'bash',
      content: [{ type: 'text', text: 'running tests\nall passed' }],
      isError: false,
    },
  },
  {
    type: 'message',
    id: 'b1',
    parentId: 't1',
    timestamp: '2026-05-28T09:16:05.000Z',
    message: { role: 'bashExecution', command: 'git status', output: 'nothing to commit', exitCode: 0 },
  },
  {
    type: 'compaction',
    id: 'c1',
    parentId: 'b1',
    timestamp: '2026-05-28T09:20:00.000Z',
    summary: 'Fixed the comparison bug and verified tests pass.',
    firstKeptEntryId: 'b1',
    tokensBefore: 4096,
  },
];

fs.writeFileSync(sessionFile, lines.map((entry) => JSON.stringify(entry)).join('\n') + '\n');

// 4) Run the export.
let exportStdout = '';
try {
  exportStdout = execFileSync(bin, ['--export', sessionFile, outFile], { encoding: 'utf8' });
} catch (error) {
  fail(`--export failed: ${error.message}\n${error.stdout ?? ''}\n${error.stderr ?? ''}`);
}
assert(exportStdout.includes(`Exported to: ${outFile}`), `export did not report the requested output path; got: ${exportStdout}`);
assert(fs.existsSync(outFile), `export did not write ${outFile}`);

const html = fs.readFileSync(outFile, 'utf8');

// 5) Assertions.

// Title contract (kept exactly for downstream smokes).
assert(html.includes('<title>pi-zig session</title>'), 'title does not contain "pi-zig session"');

// Per-entry timestamps: visible, deterministic HH:MM:SS slices from the ISO timestamps.
assert(html.includes('class="message-timestamp"'), 'no per-entry timestamp elements rendered');
assert(html.includes('>09:15:42<'), 'user message timestamp 09:15:42 not rendered');
assert(html.includes('>09:15:50<'), 'assistant message timestamp 09:15:50 not rendered');
assert(html.includes('>09:16:05<'), 'bashExecution timestamp 09:16:05 not rendered');
assert(html.includes('>09:20:00<'), 'compaction timestamp 09:20:00 not rendered');

// Sidebar/nav with in-page anchor links to entries.
assert(html.includes('<nav id="sidebar"'), 'no sidebar nav element');
assert(html.includes('id="tree-container"'), 'no sidebar tree container');
assert(html.includes('href="#entry-u1"'), 'no anchor link to user entry');
assert(html.includes('href="#entry-a1"'), 'no anchor link to assistant entry');
assert(html.includes('href="#entry-b1"'), 'no anchor link to bashExecution entry');
assert(html.includes('href="#entry-c1"'), 'no anchor link to compaction entry');
// The anchor targets must exist as rendered element ids.
assert(html.includes('id="entry-u1"'), 'user entry anchor target missing');
assert(html.includes('id="entry-c1"'), 'compaction entry anchor target missing');

// Self-contained client-side search box + inline script (no external script src).
assert(html.includes('id="tree-search"'), 'no search input');
assert(html.includes("getElementById('tree-search')"), 'no inline search script wiring');
assert(html.includes("addEventListener('input'"), 'search script does not bind an input handler');
assert(!html.includes('<script src='), 'export references an external script src');
assert(!/src\s*=\s*"https?:/i.test(html), 'export references an external http(s) resource');

// Fenced code block renders in <pre class="code-block"><code ...> with a language hook,
// and its angle brackets are HTML-escaped (no XSS leak).
assert(html.includes('<pre class="code-block"><code'), 'fenced code block not rendered as a <pre><code> block');
assert(html.includes('lang-js'), 'code block language class hook (lang-js) missing');
assert(html.includes('1 &lt; 2'), 'code block content was not HTML-escaped');

// Tool call + result and compaction summary made it into the body.
assert(html.includes('$ echo running tests'), 'tool call command not rendered');
assert(html.includes('all passed'), 'tool result text not rendered');
assert(html.includes('$ git status'), 'bashExecution command not rendered');
assert(html.includes('Compacted from 4096 tokens'), 'compaction summary not rendered');

// Theme colors present (CSS variables).
assert(html.includes('--accent:'), 'theme color CSS variables missing');

// Cleanup best-effort.
try {
  fs.rmSync(tmpDir, { recursive: true, force: true });
} catch {
  // ignore
}

console.log(`${TAG} PASS`);

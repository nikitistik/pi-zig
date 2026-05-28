#!/usr/bin/env node
/**
 * Wave-3 standalone-CLI smoke. Drives the STAGED CLI bundle (zig-out/release-cli/)
 * — the same binary a terminal user would install on $PATH like claude-code —
 * through all four supported modes against a real fake provider:
 *
 *   1. print   (`pi-zig -p`)          → final assistant text on stdout
 *   2. json    (`pi-zig --mode json`) → newline-delimited event stream
 *   3. rpc     (`pi-zig rpc <file>`)  → NDJSON over stdin/stdout
 *   4. interactive non-TTY fallback   → explicit "needs a terminal" notice + help
 *
 * The CLI bundle (release/package-cli.sh output) contains JUST the binary,
 * README, manifest, and SHA256SUMS — no frontend, no WS bridge. This smoke
 * exercises exactly that surface to confirm the standalone CLI works without
 * the Prin7r-integration bundle's workbench.
 *
 * Pure Node stdlib; exits non-zero with a clear message on any failure.
 */

import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const cliDir = path.join(repoRoot, 'zig-out/release-cli');
const bin = path.join(cliDir, 'bin/pi-zig');

function fail(msg) { console.error(`[wave3-standalone-cli-smoke] FAIL: ${msg}`); process.exit(1); }
const log = (...a) => console.log('[wave3-standalone-cli-smoke]', ...a);

if (!fs.existsSync(bin)) fail(`CLI bundle not staged: ${bin} (run \`bash release/package-cli.sh\`)`);
if (!fs.existsSync(path.join(cliDir, 'manifest.json'))) fail(`CLI manifest missing: ${cliDir}/manifest.json`);

// --- 0. Bundle integrity ---------------------------------------------------
const manifest = JSON.parse(fs.readFileSync(path.join(cliDir, 'manifest.json'), 'utf8'));
if (manifest.schema !== 'pi-zig.release-cli.v1') fail(`manifest schema unexpected: ${manifest.schema}`);
const actualSha = crypto.createHash('sha256').update(fs.readFileSync(bin)).digest('hex');
if (actualSha !== manifest.binarySha256) {
  fail(`binary sha mismatch: manifest=${manifest.binarySha256} actual=${actualSha}`);
}
log(`bundle integrity OK (${manifest.binaryBytes} bytes, sha256 ${actualSha.slice(0, 16)}…)`);

// --- Fake OpenAI-compatible provider --------------------------------------
function startFakeProvider() {
  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      let body = {};
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch { /* */ }
      const stream = body.stream === true;
      const reply = 'standalone CLI: round-trip complete';
      if (stream) {
        const evs = [
          { choices: [{ index: 0, delta: { role: 'assistant', content: reply }, finish_reason: null }] },
          { choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] },
        ];
        let payload = '';
        for (const e of evs) payload += `data: ${JSON.stringify(e)}\n\n`;
        payload += 'data: [DONE]\n\n';
        const buf = Buffer.from(payload);
        res.writeHead(200, { 'content-type': 'text/event-stream', 'content-length': String(buf.length) });
        res.end(buf);
      } else {
        const buf = Buffer.from(JSON.stringify({
          choices: [{ index: 0, message: { role: 'assistant', content: reply }, finish_reason: 'stop' }],
        }));
        res.writeHead(200, { 'content-type': 'application/json', 'content-length': String(buf.length) });
        res.end(buf);
      }
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => {
    resolve({ baseUrl: `http://127.0.0.1:${server.address().port}/v1`, close: () => server.close() });
  }));
}

function runAsync(args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { cwd: repoRoot, env: options.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '', err = '';
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('exit', (code) => resolve({ code, stdout: out, stderr: err }));
    child.on('error', reject);
  });
}

async function main() {
  const provider = await startFakeProvider();
  const env = {
    ...process.env,
    OPENAI_API_KEY: 'fake-cli-key',
    PI_ZIG_PROVIDER_BASE_URL: provider.baseUrl,
  };

  try {
    // --- 1. print mode (`pi-zig -p`) -------------------------------------
    const printResult = await runAsync(['--no-session', '--provider', 'openai', '--model', 'gpt-4o', '-p', 'cli print mode probe'], { env });
    if (printResult.code !== 0) fail(`print mode exit ${printResult.code}\nstderr:\n${printResult.stderr}`);
    if (!printResult.stdout.includes('standalone CLI: round-trip complete')) {
      fail(`print mode did not return provider text: ${printResult.stdout.slice(0, 200)}`);
    }
    log('print mode OK');

    // --- 2. json mode (`pi-zig --mode json`) ------------------------------
    const jsonResult = await runAsync(['--mode', 'json', '--no-session', '--no-tools', '--provider', 'openai', '--model', 'gpt-4o', '-p', 'cli json mode probe'], { env });
    if (jsonResult.code !== 0) fail(`json mode exit ${jsonResult.code}\nstderr:\n${jsonResult.stderr}`);
    const events = jsonResult.stdout.trim().split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    if (!events.some((e) => e.type === 'agent_start')) fail('json mode missing agent_start');
    if (!events.some((e) => e.type === 'agent_end')) fail('json mode missing agent_end');
    if (!events.some((e) => e.type === 'message_update' || (e.type === 'message_end' && JSON.stringify(e).includes('standalone CLI')))) {
      fail(`json mode missing recovered assistant content; events: ${events.map((e) => e.type).join(',')}`);
    }
    log(`json mode OK (${events.length} events incl. agent_start/agent_end)`);

    // --- 3. rpc mode (`pi-zig rpc <file>`) ---------------------------------
    const sessionFile = path.join(repoRoot, 'zig-out/wave3-cli-session.jsonl');
    if (fs.existsSync(sessionFile)) fs.rmSync(sessionFile);
    const rpcLines = await driveRpc(['rpc', sessionFile], [
      { id: 'mod', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' },
      { id: 'pr', type: 'prompt', message: 'cli rpc mode probe' },
      { id: 'st', type: 'get_state' },
    ], env);
    const promptResp = rpcLines.find((l) => l.id === 'pr');
    if (!promptResp?.success) fail(`rpc prompt failed: ${JSON.stringify(promptResp)}`);
    if (!String(promptResp.data?.text ?? '').includes('standalone CLI: round-trip complete')) {
      fail(`rpc prompt did not return provider text: ${promptResp.data?.text}`);
    }
    const stateResp = rpcLines.find((l) => l.id === 'st');
    if (!stateResp?.success) fail('rpc get_state failed after prompt');
    log('rpc mode OK');

    // --- 4. interactive non-TTY fallback ---------------------------------
    // `pi-zig` with no prompt and piped stdin (no TTY) MUST NOT enter raw mode;
    // it prints the explicit terminal-required notice + the top-level help.
    const interactiveResult = await runAsync([], { env, /* stdio ignored = no tty */ });
    if (!interactiveResult.stderr.includes('interactive TUI requires a terminal') && !interactiveResult.stdout.includes('interactive TUI requires a terminal')) {
      fail(`interactive non-TTY fallback did not print the terminal-required notice; stderr=${interactiveResult.stderr.slice(0, 200)} stdout=${interactiveResult.stdout.slice(0, 200)}`);
    }
    log('interactive non-TTY fallback OK');

    log('PASS — standalone CLI bundle drives all four modes');
  } finally {
    provider.close();
  }
}

function driveRpc(args, commands, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { cwd: repoRoot, env, stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '', err = '';
    const lines = [];
    let pending = '';
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      out += chunk; pending += chunk;
      while (pending.includes('\n')) {
        const i = pending.indexOf('\n');
        const raw = pending.slice(0, i); pending = pending.slice(i + 1);
        if (!raw.trim()) continue;
        try { lines.push(JSON.parse(raw)); } catch { /* */ }
      }
    });
    child.stderr.on('data', (c) => (err += c));
    const timer = setTimeout(() => {
      if (!child.killed) child.kill('SIGKILL');
      reject(new Error(`rpc driver timed out\nstdout:\n${out}\nstderr:\n${err}`));
    }, 30000);
    child.on('exit', () => { clearTimeout(timer); resolve(lines); });
    child.on('error', (e) => { clearTimeout(timer); reject(e); });
    for (const cmd of commands) child.stdin.write(JSON.stringify(cmd) + '\n');
    setTimeout(() => child.stdin.end(), 2500);
  });
}

main().catch((e) => fail(e.stack ?? e.message ?? String(e)));

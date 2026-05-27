/**
 * One-command dev stack for the pi-zig workbench.
 *
 * Spawns, as child processes:
 *   1. fake-provider.mjs  — OpenAI-compatible canned provider (smoke only).
 *   2. server.mjs         — RPC bridge that spawns `pi-zig --mode rpc`, with the
 *                           fake-provider env so prompts get a real round-trip.
 *   3. vite dev server    — serves the workbench and proxies /rpc to the bridge.
 *
 * Used both for manual development and for browser-driven verification. Env:
 *   USE_FAKE_PROVIDER=1   start the fake provider and point the backend at it
 *                         (default 1; set 0 to talk to real providers via keys).
 *   VITE_PORT             default 5173
 *   BRIDGE_PORT           default 8787
 *   FAKE_PORT             default 8799
 */

import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const here = fileURLToPath(new URL('.', import.meta.url));
const repoRoot = resolve(here, '..');

const USE_FAKE = process.env.USE_FAKE_PROVIDER !== '0';
const VITE_PORT = process.env.VITE_PORT ?? '5173';
const BRIDGE_PORT = process.env.BRIDGE_PORT ?? '8787';
const FAKE_PORT = process.env.FAKE_PORT ?? '8799';

const children = [];
function start(name, command, args, env) {
  const child = spawn(command, args, { cwd: here, env: { ...process.env, ...env }, stdio: 'inherit' });
  child.on('exit', (code) => console.log(`[dev-stack] ${name} exited (${code})`));
  children.push(child);
  return child;
}

function shutdown() {
  for (const child of children) {
    if (!child.killed) child.kill('SIGTERM');
  }
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

const fakeEnv = USE_FAKE
  ? { PI_ZIG_PROVIDER_BASE_URL: `http://127.0.0.1:${FAKE_PORT}/v1`, GROQ_API_KEY: process.env.GROQ_API_KEY ?? 'fake-key' }
  : {};

if (USE_FAKE) {
  start('fake-provider', process.execPath, ['fake-provider.mjs'], { PORT: FAKE_PORT });
}

start('bridge', process.execPath, ['server.mjs'], {
  PORT: BRIDGE_PORT,
  PI_ZIG_SESSION: resolve(repoRoot, 'zig-out/frontend-bridge.jsonl'),
  // Paths are resolved by the backend, whose cwd is the repo root (set in
  // server.mjs), so these are relative to repoRoot — not to this script.
  PI_ZIG_RPC_ARGS: process.env.PI_ZIG_RPC_ARGS ?? '--skill zig-out/smoke-skills --prompt-template zig-out/smoke-prompts',
  ...fakeEnv,
});

start('vite', 'npx', ['vite', '--host', '127.0.0.1', '--port', VITE_PORT], { BRIDGE_PORT });

console.log(`[dev-stack] workbench -> http://127.0.0.1:${VITE_PORT}  (bridge :${BRIDGE_PORT}, fake provider ${USE_FAKE ? `:${FAKE_PORT}` : 'off'})`);

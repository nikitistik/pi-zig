/**
 * Dev/standalone bridge between the Preact workbench and the real Zig RPC
 * backend (`pi-zig --mode rpc --session <file>`).
 *
 * The browser cannot spawn processes, so this Node server:
 *   1. Spawns one `pi-zig --mode rpc --session <file>` child per WebSocket.
 *   2. Pipes browser WebSocket messages -> child stdin (one JSON line each).
 *   3. Pipes child stdout JSON lines -> the WebSocket.
 *   4. Optionally serves the built `dist/` for standalone (non-Vite) use.
 *
 * Environment:
 *   PI_ZIG_BIN          path to the pi-zig binary (default: ../zig-out/bin/pi-zig)
 *   PI_ZIG_SESSION      session file path (default: ../zig-out/frontend-bridge.jsonl)
 *   PI_ZIG_RPC_ARGS     extra args appended after the mode/session flags
 *   PORT                listen port (default: 8787)
 *   SERVE_STATIC        when "1", serve ./dist as a static site
 *
 * Fake provider passthrough: any env var is inherited by the child, so a smoke
 * test can set PI_ZIG_PROVIDER_BASE_URL + OPENAI_API_KEY before launching this
 * server to drive the real agent loop against a local fake completions server.
 */

import { spawn } from 'node:child_process';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

const here = fileURLToPath(new URL('.', import.meta.url));
const repoRoot = resolve(here, '..');

const PORT = Number(process.env.PORT ?? 8787);
const BIN = process.env.PI_ZIG_BIN ?? resolve(repoRoot, 'zig-out/bin/pi-zig');
const SESSION = process.env.PI_ZIG_SESSION ?? resolve(repoRoot, 'zig-out/frontend-bridge.jsonl');
const EXTRA_ARGS = (process.env.PI_ZIG_RPC_ARGS ?? '').split(' ').filter(Boolean);
const SERVE_STATIC = process.env.SERVE_STATIC === '1';
const DIST = resolve(here, 'dist');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.png': 'image/png',
};

function log(...args) {
  console.log('[pi-zig-bridge]', ...args);
}

function serveStatic(req, res) {
  if (!SERVE_STATIC) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('Not found. Start with SERVE_STATIC=1 to serve the built app.');
    return;
  }
  const urlPath = decodeURIComponent((req.url ?? '/').split('?')[0]);
  let filePath = normalize(join(DIST, urlPath === '/' ? 'index.html' : urlPath));
  if (!filePath.startsWith(DIST)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }
  if (!existsSync(filePath) || statSync(filePath).isDirectory()) {
    filePath = join(DIST, 'index.html'); // SPA fallback
  }
  if (!existsSync(filePath)) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('Build not found. Run `npm run build` first.');
    return;
  }
  res.writeHead(200, { 'content-type': MIME[extname(filePath)] ?? 'application/octet-stream' });
  createReadStream(filePath).pipe(res);
}

const httpServer = createServer(serveStatic);
const wss = new WebSocketServer({ server: httpServer, path: '/rpc' });

wss.on('connection', (ws) => {
  log(`client connected; spawning ${BIN} --mode rpc --session ${SESSION}`);
  const child = spawn(BIN, ['--mode', 'rpc', '--session', SESSION, ...EXTRA_ARGS], {
    cwd: repoRoot,
    env: process.env,
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  let stdoutBuffer = '';
  child.stdout.on('data', (chunk) => {
    stdoutBuffer += chunk.toString('utf8');
    let index;
    while ((index = stdoutBuffer.indexOf('\n')) >= 0) {
      const line = stdoutBuffer.slice(0, index);
      stdoutBuffer = stdoutBuffer.slice(index + 1);
      const trimmed = line.trim();
      if (trimmed.length === 0) continue;
      if (ws.readyState === ws.OPEN) ws.send(trimmed);
    }
  });

  child.stderr.on('data', (chunk) => log('backend stderr:', chunk.toString('utf8').trimEnd()));

  child.on('exit', (code, signal) => {
    log(`backend exited code=${code} signal=${signal}`);
    if (ws.readyState === ws.OPEN) {
      ws.send(JSON.stringify({ type: 'bridge_event', event: 'backend_exit', code, signal }));
      ws.close();
    }
  });

  child.on('error', (err) => {
    log('failed to spawn backend:', err.message);
    if (ws.readyState === ws.OPEN) {
      ws.send(JSON.stringify({ type: 'response', command: 'spawn', success: false, error: err.message }));
    }
  });

  ws.on('message', (data) => {
    const text = typeof data === 'string' ? data : data.toString('utf8');
    for (const line of text.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.length === 0) continue;
      if (!child.killed && child.stdin.writable) child.stdin.write(`${trimmed}\n`);
    }
  });

  ws.on('close', () => {
    log('client disconnected; terminating backend');
    if (!child.killed) child.kill('SIGTERM');
  });
});

httpServer.listen(PORT, '127.0.0.1', () => {
  log(`listening on http://127.0.0.1:${PORT} (ws path /rpc)`);
  log(`backend binary: ${BIN}`);
  log(`session file:   ${SESSION}`);
  if (SERVE_STATIC) log(`serving static dist: ${DIST}`);
});

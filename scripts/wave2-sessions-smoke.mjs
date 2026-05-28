// Wave 2 sessions/compaction/RPC smoke: proves three new RPC capabilities end to end
// against the real `pi-zig rpc <session>` binary over NDJSON.
//
//   1. Session-tree navigation: get_session_tree returns the id/parentId tree + leaf,
//      and navigate_tree switches the active branch by node id within the same file.
//   2. Auto-compaction trigger: with auto-compaction enabled at a forced-low threshold
//      (large reserveTokens), a compaction entry appears before the next provider
//      prompt WITHOUT an explicit `compact` command. A fake provider returns the
//      summary, proving the LLM path ran on the auto trigger.
//   3. extension_ui_request/response round-trip: an inbound extension_ui_request is
//      forwarded to the client as an event, and the client's extension_ui_response is
//      routed back as the command response.
//
// Pure Node stdlib. The fake provider + startRpc NDJSON driver mirror
// scripts/flow-e-compaction-smoke.mjs (runRpcSequential pattern).
//
// On success prints "[wave2-sessions-smoke] PASS" and exits 0; any failure throws and
// exits non-zero.

import { spawn, spawnSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const bin = path.resolve('zig-out/bin/pi-zig');
const COMPACTION_SUMMARY = 'AUTO COMPACTION SUMMARY: alpha';
const PROVIDER_KEY = 'wave2-sessions-key';

function fail(message) {
  throw new Error(`[wave2-sessions-smoke] ${message}`);
}

// --- Build the binary first (DoD: build with `zig build`). -----------------
function ensureBinary() {
  const result = spawnSync('zig', ['build'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.status !== 0) {
    fail(`zig build failed (status ${result.status})\nstdout:\n${result.stdout ?? ''}\nstderr:\n${result.stderr ?? ''}`);
  }
  if (!fs.existsSync(bin)) fail(`expected binary at ${bin} after zig build`);
}

// --- Fake OpenAI-compatible provider ---------------------------------------
// Returns the compaction summary for summarization requests (summarization system
// prompt + <conversation> tags), and a generic reply otherwise. Records requests so
// the smoke can assert the auto-compaction summarization request actually fired.
function startFakeProvider() {
  const requests = [];

  const contentText = (content) =>
    Array.isArray(content)
      ? content.filter((part) => part?.type === 'text').map((part) => part.text ?? '').join('\n')
      : String(content ?? '');

  const server = http.createServer((req, res) => {
    let rawBody = '';
    req.on('data', (chunk) => {
      rawBody += chunk;
    });
    req.on('end', () => {
      if (req.method !== 'POST' || req.url !== '/v1/chat/completions') {
        res.writeHead(404, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'not found', url: req.url }));
        return;
      }
      if (req.headers.authorization !== `Bearer ${PROVIDER_KEY}`) {
        res.writeHead(401, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing auth' }));
        return;
      }
      let body;
      try {
        body = JSON.parse(rawBody);
      } catch (error) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'invalid json body', message: error.message }));
        return;
      }

      const system = contentText(body.messages?.find((message) => message.role === 'system')?.content);
      const userMessages = (body.messages ?? [])
        .filter((message) => message.role === 'user')
        .map((message) => contentText(message.content));
      const lastUser = userMessages.at(-1) ?? '';
      const isCompaction =
        system.includes('context summarization assistant') && lastUser.includes('<conversation>');

      requests.push({ isCompaction, stream: body.stream === true, userMessages });

      const replyText = isCompaction ? COMPACTION_SUMMARY : `assistant reply #${requests.length}`;

      if (body.stream === true) {
        res.writeHead(200, {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          connection: 'close',
        });
        res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: replyText } }] })}\n\n`);
        res.end('data: [DONE]\n\n');
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ choices: [{ message: { content: replyText } }] }));
    });
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        baseUrl: `http://127.0.0.1:${port}/v1`,
        requests,
        stop: () => new Promise((done) => server.close(done)),
      });
    });
  });
}

// --- NDJSON RPC driver (adapted from flow-e-compaction-smoke.mjs) -----------
// Sends commands sequentially over stdin, parses NDJSON responses/events from stdout,
// and resolves waiters by predicate. A command with an `id` is awaited until a
// response line with that id arrives; arbitrary events (e.g. extension_ui_request)
// can be awaited via waitForLine and answered with sendRaw.
function startRpc(sessionFile, env) {
  const child = spawn(bin, ['rpc', sessionFile], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  let pending = '';
  const lines = [];
  const waiters = [];

  function failWaiters(error) {
    while (waiters.length > 0) {
      const waiter = waiters.shift();
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
  }
  function resolveWaiters(line) {
    for (let index = 0; index < waiters.length; ) {
      const waiter = waiters[index];
      if (waiter.predicate(line)) {
        waiters.splice(index, 1);
        clearTimeout(waiter.timeout);
        waiter.resolve(line);
      } else {
        index += 1;
      }
    }
  }

  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
    pending += chunk;
    while (pending.includes('\n')) {
      const newline = pending.indexOf('\n');
      const rawLine = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      if (rawLine.trim().length === 0) continue;
      try {
        const line = JSON.parse(rawLine);
        lines.push(line);
        resolveWaiters(line);
      } catch (error) {
        failWaiters(new Error(`failed to parse RPC JSON line: ${rawLine}\n${error.message}`));
      }
    }
  });
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
  });

  const exitPromise = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`RPC run timed out\nstdout:\n${stdout}\nstderr:\n${stderr}`));
    }, 30000);
    child.once('error', (error) => {
      clearTimeout(timeout);
      failWaiters(error);
      reject(error);
    });
    child.once('exit', (code, signal) => {
      clearTimeout(timeout);
      if (code !== 0 && code !== null) {
        const error = new Error(`RPC run exited with ${code ?? signal}\nstdout:\n${stdout}\nstderr:\n${stderr}`);
        failWaiters(error);
        reject(error);
        return;
      }
      resolve();
    });
  });

  function waitForLine(predicate, timeoutMs = 15000) {
    const existing = lines.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        const index = waiters.findIndex((waiter) => waiter.reject === reject);
        if (index !== -1) waiters.splice(index, 1);
        reject(new Error(`timed out waiting for RPC line\nstdout:\n${stdout}\nstderr:\n${stderr}`));
      }, timeoutMs);
      waiters.push({ predicate, resolve, reject, timeout });
    });
  }

  function sendRaw(command) {
    child.stdin.write(`${JSON.stringify(command)}\n`);
  }

  async function send(command) {
    sendRaw(command);
    if (command.id) return waitForLine((line) => line.id === command.id);
    return null;
  }

  async function close() {
    child.stdin.end();
    await exitPromise;
    return { stdout, stderr, lines };
  }

  return { send, sendRaw, waitForLine, close, get lines() { return lines; } };
}

async function main() {
  ensureBinary();

  const provider = await startFakeProvider();
  const cleanAgentDir = path.resolve('zig-out/pi-zig-wave2-sessions-agent');
  fs.rmSync(cleanAgentDir, { recursive: true, force: true });
  fs.mkdirSync(cleanAgentDir, { recursive: true });

  const env = {
    ...process.env,
    PI_CODING_AGENT_DIR: cleanAgentDir,
    OPENAI_API_KEY: PROVIDER_KEY,
    PI_ZIG_PROVIDER_BASE_URL: provider.baseUrl,
  };
  delete env.ANTHROPIC_API_KEY;
  delete env.ANTHROPIC_OAUTH_TOKEN;

  try {
    // ===================================================================
    // Phase 1: session-tree query + branch switch.
    // ===================================================================
    {
      const sessionFile = path.resolve('zig-out/pi-zig-wave2-tree-smoke.jsonl');
      fs.rmSync(sessionFile, { force: true });
      const rpc = startRpc(sessionFile, env);

      const modelResp = await rpc.send({ id: 'set-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
      if (modelResp.success !== true) fail(`set_model failed: ${JSON.stringify(modelResp)}`);

      const p1 = await rpc.send({ id: 'p1', type: 'prompt', message: 'root question' });
      if (p1.success !== true) fail(`first prompt failed: ${JSON.stringify(p1)}`);
      const p2 = await rpc.send({ id: 'p2', type: 'prompt', message: 'second question' });
      if (p2.success !== true) fail(`second prompt failed: ${JSON.stringify(p2)}`);

      // (1a) get_session_tree returns the id/parentId structure + current leaf.
      const treeResp = await rpc.send({ id: 'tree-1', type: 'get_session_tree' });
      if (treeResp.success !== true) fail(`get_session_tree failed: ${JSON.stringify(treeResp)}`);
      const nodes = treeResp.data?.nodes ?? [];
      if (nodes.length < 4) fail(`expected >=4 tree nodes (2 user + 2 assistant), got: ${JSON.stringify(nodes)}`);
      const roots = nodes.filter((n) => n.parentId === null);
      if (roots.length !== 1) fail(`expected exactly one root node, got: ${JSON.stringify(roots)}`);
      // Every non-root node must reference an existing parent (well-formed tree).
      const ids = new Set(nodes.map((n) => n.id));
      for (const node of nodes) {
        if (node.parentId !== null && !ids.has(node.parentId)) {
          fail(`tree node ${node.id} references missing parent ${node.parentId}`);
        }
      }
      const leafId = treeResp.data?.leafId;
      if (!leafId || !ids.has(leafId)) fail(`tree leafId missing or unknown: ${JSON.stringify(treeResp.data)}`);
      const firstUser = nodes.find((n) => n.role === 'user' && n.preview === 'root question');
      if (!firstUser) fail(`tree missing the first user node preview: ${JSON.stringify(nodes)}`);

      // (1b) navigate_tree switches the active branch to the first user message.
      const navResp = await rpc.send({ id: 'nav-1', type: 'navigate_tree', targetId: firstUser.id });
      if (navResp.success !== true) fail(`navigate_tree failed: ${JSON.stringify(navResp)}`);
      if (navResp.data?.newLeafId !== firstUser.id) {
        fail(`navigate_tree did not move the leaf to ${firstUser.id}: ${JSON.stringify(navResp.data)}`);
      }

      // After navigation the active branch is pruned to the leaf->root path: only the
      // first user message remains visible (the second turn is on an abandoned branch).
      const msgsResp = await rpc.send({ id: 'msgs-1', type: 'get_messages' });
      const messages = msgsResp.data?.messages ?? [];
      const contents = messages.map((m) => m.content);
      if (!contents.includes('root question')) {
        fail(`navigated branch lost the root message: ${JSON.stringify(contents)}`);
      }
      if (contents.includes('second question')) {
        fail(`navigated branch should not include the abandoned second turn: ${JSON.stringify(contents)}`);
      }

      // navigate_tree to an unknown node is an error.
      const badNav = await rpc.send({ id: 'nav-bad', type: 'navigate_tree', targetId: 'does-not-exist' });
      if (badNav.success !== false) fail(`navigate_tree to unknown id should fail: ${JSON.stringify(badNav)}`);

      // The leaf move stayed in the same file (no fork/clone sibling).
      const stateResp = await rpc.send({ id: 'state-1', type: 'get_state' });
      if (path.resolve(stateResp.data?.sessionFile ?? '') !== sessionFile) {
        fail(`navigate_tree must stay in the same file, got: ${stateResp.data?.sessionFile}`);
      }

      await rpc.close();
    }

    // ===================================================================
    // Phase 2: auto-compaction fires before the next prompt at a low threshold.
    // ===================================================================
    {
      const sessionFile = path.resolve('zig-out/pi-zig-wave2-autocompact-smoke.jsonl');
      fs.rmSync(sessionFile, { force: true });
      const rpc = startRpc(sessionFile, env);

      const modelResp = await rpc.send({ id: 'set-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
      if (modelResp.success !== true) fail(`set_model failed: ${JSON.stringify(modelResp)}`);

      // Enable auto-compaction with a reserve as large as the context window so the
      // threshold (contextWindow - reserve) is 0 and ANY accumulated context triggers.
      const ctxWindow = modelResp.data?.contextWindow ?? 128000;
      const acResp = await rpc.send({
        id: 'auto-compact',
        type: 'set_auto_compaction',
        enabled: true,
        reserveTokens: ctxWindow,
      });
      if (acResp.success !== true) fail(`set_auto_compaction failed: ${JSON.stringify(acResp)}`);

      // Build some history so the pre-prompt threshold check has context to compact.
      const p1 = await rpc.send({ id: 'p1', type: 'prompt', message: 'remember the alpha plan' });
      if (p1.success !== true) fail(`first prompt failed: ${JSON.stringify(p1)}`);

      const compactionsBefore = provider.requests.filter((r) => r.isCompaction).length;

      // The NEXT prompt must auto-compact first (no explicit `compact` command sent).
      const p2 = await rpc.send({ id: 'p2', type: 'prompt', message: 'and the beta follow-up' });
      if (p2.success !== true) fail(`second prompt failed: ${JSON.stringify(p2)}`);

      // (2a) A summarization request must have fired on the auto path.
      const compactionsAfter = provider.requests.filter((r) => r.isCompaction).length;
      if (compactionsAfter <= compactionsBefore) {
        fail(`auto-compaction did not issue a summarization request (before=${compactionsBefore}, after=${compactionsAfter})`);
      }

      // (2b) A compaction entry must be present without an explicit `compact` command.
      const msgsResp = await rpc.send({ id: 'msgs', type: 'get_messages' });
      const messages = msgsResp.data?.messages ?? [];
      const compaction = messages.find((m) => m.role === 'compactionSummary');
      if (!compaction) {
        fail(`no compactionSummary entry after auto-compaction: ${JSON.stringify(messages)}`);
      }
      if (!String(compaction.summary ?? '').includes(COMPACTION_SUMMARY)) {
        fail(`auto-compaction summary is not the LLM output: ${JSON.stringify(compaction)}`);
      }

      // (2c) get_state echoes the configured reserveTokens.
      const stateResp = await rpc.send({ id: 'state', type: 'get_state' });
      if (stateResp.data?.autoCompactionEnabled !== true) {
        fail(`autoCompactionEnabled not reflected in state: ${JSON.stringify(stateResp.data)}`);
      }
      if (stateResp.data?.autoCompactionReserveTokens !== ctxWindow) {
        fail(`autoCompactionReserveTokens not reflected in state: ${JSON.stringify(stateResp.data)}`);
      }

      await rpc.close();
    }

    // ===================================================================
    // Phase 3: extension_ui_request/response round-trip.
    // ===================================================================
    {
      const sessionFile = path.resolve('zig-out/pi-zig-wave2-extui-smoke.jsonl');
      fs.rmSync(sessionFile, { force: true });
      const rpc = startRpc(sessionFile, env);

      // (3a) Blocking dialog (select): the server forwards the request as an event,
      // we answer with extension_ui_response, and the routed value comes back.
      rpc.sendRaw({
        type: 'extension_ui_request',
        id: 'ui-select-1',
        method: 'select',
        title: 'Pick a color',
        options: ['Red', 'Green', 'Blue'],
      });
      const requestEvent = await rpc.waitForLine(
        (line) => line.type === 'extension_ui_request' && line.id === 'ui-select-1',
      );
      if (requestEvent.method !== 'select') fail(`forwarded event lost its method: ${JSON.stringify(requestEvent)}`);
      if (!Array.isArray(requestEvent.options) || requestEvent.options[1] !== 'Green') {
        fail(`forwarded event lost its options: ${JSON.stringify(requestEvent)}`);
      }

      // Answer the dialog; the command response must carry the routed value.
      rpc.sendRaw({ type: 'extension_ui_response', id: 'ui-select-1', value: 'Green' });
      const selectResp = await rpc.waitForLine(
        (line) => line.type === 'response' && line.id === 'ui-select-1',
      );
      if (selectResp.success !== true) fail(`extension_ui select response not success: ${JSON.stringify(selectResp)}`);
      if (selectResp.data?.value !== 'Green') {
        fail(`extension_ui select did not route the chosen value: ${JSON.stringify(selectResp)}`);
      }
      if (selectResp.data?.cancelled !== false) {
        fail(`extension_ui select should not be cancelled: ${JSON.stringify(selectResp)}`);
      }

      // (3b) Confirm dialog routes a boolean.
      rpc.sendRaw({ type: 'extension_ui_request', id: 'ui-confirm-1', method: 'confirm', title: 'Sure?', message: 'really' });
      await rpc.waitForLine((line) => line.type === 'extension_ui_request' && line.id === 'ui-confirm-1');
      rpc.sendRaw({ type: 'extension_ui_response', id: 'ui-confirm-1', confirmed: true });
      const confirmResp = await rpc.waitForLine((line) => line.type === 'response' && line.id === 'ui-confirm-1');
      if (confirmResp.data?.confirmed !== true) {
        fail(`extension_ui confirm did not route the boolean: ${JSON.stringify(confirmResp)}`);
      }

      // (3c) Cancelled dialog routes cancelled:true.
      rpc.sendRaw({ type: 'extension_ui_request', id: 'ui-input-1', method: 'input', title: 'Name?' });
      await rpc.waitForLine((line) => line.type === 'extension_ui_request' && line.id === 'ui-input-1');
      rpc.sendRaw({ type: 'extension_ui_response', id: 'ui-input-1', cancelled: true });
      const inputResp = await rpc.waitForLine((line) => line.type === 'response' && line.id === 'ui-input-1');
      if (inputResp.data?.cancelled !== true) {
        fail(`extension_ui input cancel did not route cancelled:true: ${JSON.stringify(inputResp)}`);
      }

      // (3d) Fire-and-forget (notify): event emitted, immediate ack, no response wait.
      rpc.sendRaw({ type: 'extension_ui_request', id: 'ui-notify-1', method: 'notify', message: 'hello', notifyType: 'info' });
      const notifyEvent = await rpc.waitForLine(
        (line) => line.type === 'extension_ui_request' && line.id === 'ui-notify-1',
      );
      if (notifyEvent.message !== 'hello' || notifyEvent.notifyType !== 'info') {
        fail(`notify event lost its params: ${JSON.stringify(notifyEvent)}`);
      }
      const notifyResp = await rpc.waitForLine((line) => line.type === 'response' && line.id === 'ui-notify-1');
      if (notifyResp.data?.delivered !== true) {
        fail(`notify (fire-and-forget) was not acknowledged: ${JSON.stringify(notifyResp)}`);
      }

      // The session still works for normal commands after the UI round-trips.
      const stateResp = await rpc.send({ id: 'state', type: 'get_state' });
      if (stateResp.success !== true) fail(`get_state after extension UI failed: ${JSON.stringify(stateResp)}`);

      await rpc.close();
    }
  } finally {
    await provider.stop();
  }

  console.log('[wave2-sessions-smoke] PASS');
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});

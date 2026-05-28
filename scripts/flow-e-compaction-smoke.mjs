// Flow E compaction smoke: proves LLM-driven compaction does a provider call,
// persists the returned summary, survives RPC reload, and is injected into the
// next provider prompt.
//
// Pure Node stdlib. Mirrors scripts/verify-basic.mjs:
//   - a fake OpenAI-compatible provider over node:http (dual-mode: streaming and
//     non-streaming chat/completions),
//   - an NDJSON RPC driver for `pi-zig rpc <session>` adapted from runRpcSequential.
//
// On success prints "[flow-e-compaction-smoke] PASS" and exits 0; any failure
// throws and exits non-zero.

import { spawn, spawnSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const bin = path.resolve('zig-out/bin/pi-zig');
const COMPACTION_SUMMARY = 'LLM COMPACTION SUMMARY: alpha';
const PROVIDER_KEY = 'flow-e-compaction-key';

function fail(message) {
  throw new Error(`[flow-e-compaction-smoke] ${message}`);
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
// Records every chat/completions request so the smoke can assert that a
// compaction summarization request was issued and that the follow-up prompt
// carried the persisted summary forward.
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
      // A compaction summarization request uses the summarization system prompt
      // and serializes the conversation inside <conversation> tags.
      const isCompaction =
        system.includes('context summarization assistant') && lastUser.includes('<conversation>');

      requests.push({
        isCompaction,
        stream: body.stream === true,
        system,
        userMessages,
        toolCount: body.tools?.length ?? 0,
      });

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

// --- NDJSON RPC driver (adapted from verify-basic.mjs runRpcSequential) -----
// Sends commands sequentially over stdin, parses NDJSON responses from stdout,
// and resolves waiters by predicate. Each command with an `id` is awaited until
// a response line with that id arrives.
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

  async function send(command) {
    child.stdin.write(`${JSON.stringify(command)}\n`);
    if (command.id) return waitForLine((line) => line.id === command.id);
    return null;
  }

  async function close() {
    child.stdin.end();
    await exitPromise;
    return { stdout, stderr, lines };
  }

  return { send, waitForLine, close, get lines() { return lines; } };
}

async function main() {
  ensureBinary();

  const sessionFile = path.resolve('zig-out/pi-zig-flow-e-compaction-smoke.jsonl');
  const reloadSessionFile = sessionFile; // reload the same session file via a fresh rpc child
  fs.rmSync(sessionFile, { force: true });

  const provider = await startFakeProvider();
  const cleanAgentDir = path.resolve('zig-out/pi-zig-flow-e-compaction-agent');
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
    // ---- Phase 1: build history, then compact via the provider. -----------
    const rpc = startRpc(sessionFile, env);
    const modelResp = await rpc.send({ id: 'set-model', type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
    if (modelResp.success !== true) fail(`set_model failed: ${JSON.stringify(modelResp)}`);

    const prompt1 = await rpc.send({ id: 'prompt-1', type: 'prompt', message: 'remember the alpha plan' });
    if (prompt1.success !== true) fail(`first prompt failed: ${JSON.stringify(prompt1)}`);
    const prompt2 = await rpc.send({ id: 'prompt-2', type: 'prompt', message: 'and the beta follow-up' });
    if (prompt2.success !== true) fail(`second prompt failed: ${JSON.stringify(prompt2)}`);

    const compactResp = await rpc.send({ id: 'compact-1', type: 'compact' });
    if (compactResp.success !== true) fail(`compact failed: ${JSON.stringify(compactResp)}`);

    // (3) The compact response summary must be the LLM-produced string, proving
    // the provider path ran (not the static "Local summary of N" fallback).
    const compactSummary = compactResp.data?.summary ?? '';
    if (!compactSummary.includes(COMPACTION_SUMMARY)) {
      fail(`compact summary did not contain LLM output. got: ${JSON.stringify(compactResp.data)}`);
    }
    if (compactSummary.includes('Local summary of')) {
      fail(`compact summary used the static fallback path: ${compactSummary}`);
    }
    if (compactResp.data?.details?.local !== false) {
      fail(`compact details should mark local:false for an LLM summary: ${JSON.stringify(compactResp.data?.details)}`);
    }

    await rpc.close();

    // The fake provider must have received a dedicated summarization request.
    const compactionRequests = provider.requests.filter((request) => request.isCompaction);
    if (compactionRequests.length !== 1) {
      fail(`expected exactly one compaction provider call, saw ${compactionRequests.length}: ${JSON.stringify(provider.requests)}`);
    }
    const compactionRequest = compactionRequests[0];
    if (compactionRequest.toolCount !== 0) {
      fail(`compaction request should disable tools, saw ${compactionRequest.toolCount}`);
    }
    // The serialized conversation must carry the prior turns forward.
    const compactionConversation = compactionRequest.userMessages.join('\n');
    if (!compactionConversation.includes('remember the alpha plan') || !compactionConversation.includes('and the beta follow-up')) {
      fail(`compaction prompt missing prior turns: ${compactionConversation}`);
    }

    // ---- Phase 2: reload the persisted session in a fresh rpc child. ------
    const reloadRpc = startRpc(reloadSessionFile, env);
    const messagesResp = await reloadRpc.send({ id: 'messages-after-reload', type: 'get_messages' });
    const messages = messagesResp.data?.messages ?? [];
    const compactionMessage = messages.find((message) => message.role === 'compactionSummary');
    if (!compactionMessage) {
      fail(`no compactionSummary message after reload: ${JSON.stringify(messages)}`);
    }
    // (4) The persisted compaction summary must survive reload as the LLM text.
    if (!String(compactionMessage.summary ?? '').includes(COMPACTION_SUMMARY)) {
      fail(`reloaded compactionSummary lost the LLM text: ${JSON.stringify(compactionMessage)}`);
    }

    const requestCountBeforeFollowUp = provider.requests.length;

    // ---- Phase 3: follow-up prompt must inject the compaction summary. ----
    const followUp = await reloadRpc.send({ id: 'prompt-follow-up', type: 'prompt', message: 'continue from where we left off' });
    if (followUp.success !== true) fail(`follow-up prompt failed: ${JSON.stringify(followUp)}`);

    await reloadRpc.close();

    const followUpRequests = provider.requests.slice(requestCountBeforeFollowUp).filter((request) => !request.isCompaction);
    if (followUpRequests.length === 0) {
      fail('follow-up prompt did not reach the provider');
    }
    // (5) The follow-up provider request history must include the compaction
    // summary text, proving next-prompt injection of the persisted summary.
    const injected = followUpRequests.some((request) =>
      request.userMessages.some((message) => message.includes(COMPACTION_SUMMARY)),
    );
    if (!injected) {
      fail(`follow-up request did not include the compaction summary. requests: ${JSON.stringify(followUpRequests, null, 2)}`);
    }
  } finally {
    await provider.stop();
  }

  console.log('[flow-e-compaction-smoke] PASS');
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});

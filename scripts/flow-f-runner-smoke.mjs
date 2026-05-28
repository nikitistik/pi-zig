// Flow F extensions-runner smoke: proves the long-lived Node extension runner
// keeps module-local state ACROSS two separate RPC command invocations in the
// same `pi-zig rpc <session>` process.
//
// Mechanism: a temp extension registers a `counter` tool that increments a
// MODULE-LEVEL variable on each execution and returns the current count. A fake
// OpenAI-compatible provider emits a `counter` tool call on every prompt and
// then echoes the tool result. The real Zig agent executes the extension tool
// via the session's persistent runner. Two SEPARATE `prompt` commands in the
// same session must observe count 1 then 2 — previously each command spawned a
// fresh Node process and would have reset the counter to 1 every time.
//
// Control: a second, fresh `pi-zig rpc` child (new persistent process) must
// reset to 1 — proving the persistence is real and process-scoped.
//
// Pure Node stdlib. Builds with `zig build` first (DoD). Prints
// "[flow-f-runner-smoke] PASS" and exits 0 on success; throws / non-zero exit
// on any failure.

import { spawn, spawnSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const bin = path.resolve('zig-out/bin/pi-zig');
const PROVIDER_KEY = 'flow-f-runner-key';
const workDir = path.resolve('zig-out/flow-f-runner-smoke');
const extensionPath = path.join(workDir, 'counter-extension.mjs');

function fail(message) {
  throw new Error(`[flow-f-runner-smoke] ${message}`);
}

// --- Build the binary first (DoD: build with `zig build`). -----------------
function ensureBinary() {
  const result = spawnSync('zig', ['build'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.status !== 0) {
    fail(`zig build failed (status ${result.status})\nstdout:\n${result.stdout ?? ''}\nstderr:\n${result.stderr ?? ''}`);
  }
  if (!fs.existsSync(bin)) fail(`expected binary at ${bin} after zig build`);
}

// A temp extension with a MODULE-LEVEL counter incremented on each tool call.
// If the runner process is reused across commands, the count keeps climbing; a
// fresh process resets it to 0 (so the first call returns 1).
function writeExtension() {
  fs.mkdirSync(workDir, { recursive: true });
  fs.writeFileSync(
    extensionPath,
    [
      'let count = 0;',
      'export default function(pi) {',
      '  pi.registerTool({',
      '    name: "counter",',
      '    description: "Increment a module-level counter and return the count",',
      '    parameters: { type: "object", properties: {}, additionalProperties: false },',
      '    execute: async () => {',
      '      count++;',
      '      return { content: [{ type: "text", text: String(count) }], isError: false };',
      '    }',
      '  });',
      '}',
      '',
    ].join('\n'),
  );
}

// --- Fake OpenAI-compatible provider ---------------------------------------
// On a prompt, emit a `counter` tool call. After the tool result comes back,
// echo it as `counter is: <n>`. Supports streaming and non-streaming requests.
function startFakeProvider() {
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
      let body = {};
      try {
        body = JSON.parse(rawBody || '{}');
      } catch {
        /* ignore */
      }
      const stream = body.stream === true;
      const messages = Array.isArray(body.messages) ? body.messages : [];
      const last = messages[messages.length - 1];

      // Decide per-turn from the MOST RECENT message (history accumulates across
      // prompts in a reused session, so counting tool messages would misfire on
      // later turns): a user prompt at the tail => emit a `counter` tool call;
      // a tool result at the tail => echo it. Each separate prompt therefore
      // triggers a fresh extension tool execution.
      if (last && last.role === 'tool') {
        const out = contentText(last.content).trim();
        reply(res, stream, `counter is: ${out}`);
        return;
      }

      // Turn start: ask the agent to run the extension `counter` tool. Unique ids
      // keep tool-call correlation clean across turns.
      const toolCallId = `call_counter_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
      if (stream) {
        writeStream(res, [
          {
            choices: [
              {
                delta: {
                  tool_calls: [
                    { index: 0, id: toolCallId, type: 'function', function: { name: 'counter', arguments: '{}' } },
                  ],
                },
              },
            ],
          },
          { choices: [{ delta: {}, finish_reason: 'tool_calls' }] },
        ]);
      } else {
        writeJson(res, {
          id: 'fake',
          object: 'chat.completion',
          choices: [
            {
              index: 0,
              message: {
                role: 'assistant',
                content: null,
                tool_calls: [{ id: toolCallId, type: 'function', function: { name: 'counter', arguments: '{}' } }],
              },
              finish_reason: 'tool_calls',
            },
          ],
        });
      }
    });
  });

  return new Promise((resolveServer) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolveServer({ server, baseUrl: `http://127.0.0.1:${port}/v1` });
    });
  });

  function reply(res, stream, text) {
    if (stream) {
      writeStream(res, [
        { choices: [{ index: 0, delta: { role: 'assistant', content: text }, finish_reason: null }] },
        { choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] },
      ]);
    } else {
      writeJson(res, {
        id: 'fake',
        object: 'chat.completion',
        choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }],
        usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
      });
    }
  }
  function writeJson(res, obj) {
    const buf = Buffer.from(JSON.stringify(obj), 'utf8');
    res.writeHead(200, { 'content-type': 'application/json', 'content-length': String(buf.length) });
    res.end(buf);
  }
  function writeStream(res, events) {
    let payload = '';
    for (const e of events) payload += `data: ${JSON.stringify(e)}\n\n`;
    payload += 'data: [DONE]\n\n';
    const buf = Buffer.from(payload, 'utf8');
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      'content-length': String(buf.length),
    });
    res.end(buf);
  }
}

// --- NDJSON RPC driver for a real `pi-zig rpc <session> --extension <path>` --
class RpcChild {
  constructor(env, sessionFile) {
    // Use the `--mode rpc` entry point: it is the one that parses `--extension`
    // and discovers extension paths for the runtime. (The positional `rpc`
    // subcommand is a stripped-down entry that does not load extensions.)
    this.child = spawn(bin, ['--mode', 'rpc', '--session', sessionFile, '--extension', extensionPath], {
      env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.buffer = '';
    this.lines = [];
    this.waiters = [];
    this.stderr = '';
    this.seq = 0;
    this.child.stdout.setEncoding('utf8');
    this.child.stderr.setEncoding('utf8');
    this.child.stdout.on('data', (chunk) => this._onData(chunk));
    this.child.stderr.on('data', (chunk) => {
      this.stderr += chunk;
    });
  }

  _onData(chunk) {
    this.buffer += chunk;
    let idx;
    while ((idx = this.buffer.indexOf('\n')) >= 0) {
      const raw = this.buffer.slice(0, idx);
      this.buffer = this.buffer.slice(idx + 1);
      if (raw.trim().length === 0) continue;
      let parsed;
      try {
        parsed = JSON.parse(raw);
      } catch {
        continue;
      }
      this.lines.push(parsed);
      for (let i = 0; i < this.waiters.length; ) {
        if (this.waiters[i].predicate(parsed)) {
          const w = this.waiters.splice(i, 1)[0];
          clearTimeout(w.timer);
          w.resolve(parsed);
        } else {
          i += 1;
        }
      }
    }
  }

  send(command) {
    const id = command.id ?? `c-${++this.seq}`;
    this.child.stdin.write(`${JSON.stringify({ ...command, id })}\n`);
    return id;
  }

  waitFor(predicate, timeoutMs, label) {
    const existing = this.lines.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolveWait, rejectWait) => {
      const timer = setTimeout(() => {
        const i = this.waiters.findIndex((w) => w.timer === timer);
        if (i !== -1) this.waiters.splice(i, 1);
        rejectWait(new Error(`timed out waiting for ${label}\nstderr:\n${this.stderr}`));
      }, timeoutMs);
      this.waiters.push({ predicate, resolve: resolveWait, timer });
    });
  }

  async call(command, timeoutMs = 20000) {
    const id = this.send(command);
    return this.waitFor((l) => l.type === 'response' && l.id === id, timeoutMs, `response for ${command.type}`);
  }

  close() {
    this.child.stdin.end();
    return new Promise((resolveClose) => {
      const timer = setTimeout(() => {
        if (!this.child.killed) this.child.kill('SIGKILL');
        resolveClose();
      }, 3000);
      this.child.once('exit', () => {
        clearTimeout(timer);
        resolveClose();
      });
    });
  }
}

function freshSession(name) {
  const file = path.join(workDir, name);
  try {
    if (fs.existsSync(file)) fs.rmSync(file);
  } catch {
    /* ignore */
  }
  return file;
}

// Drive one prompt and return the trimmed counter value the provider echoed.
async function promptCounter(child, message) {
  const resp = await child.call({ type: 'prompt', message });
  if (!resp.success) fail(`prompt failed: ${resp.error ?? JSON.stringify(resp)}`);
  const text = String(resp.data?.text ?? '');
  const match = text.match(/counter is:\s*(\d+)/);
  if (!match) fail(`prompt did not echo a counter value: ${JSON.stringify(resp.data)}`);
  // Sanity: an extension tool result must have flowed through the agent loop.
  const toolResults = resp.data?.toolResults ?? [];
  if (!Array.isArray(toolResults) || toolResults.length === 0) {
    fail(`prompt carried no extension toolResults: ${JSON.stringify(resp.data)}`);
  }
  return Number(match[1]);
}

async function main() {
  ensureBinary();
  writeExtension();

  const provider = await startFakeProvider();
  const env = {
    ...process.env,
    OPENAI_API_KEY: PROVIDER_KEY,
    PI_ZIG_PROVIDER_BASE_URL: provider.baseUrl,
  };

  // --- Persistent path: two SEPARATE commands, one session/process. ---------
  const sessionFile = freshSession('persistent-session.jsonl');
  const child = new RpcChild(env, sessionFile);
  try {
    const modelResp = await child.call({ type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
    if (!modelResp.success) fail('set_model failed');

    const first = await promptCounter(child, 'flow-f first invocation');
    if (first !== 1) fail(`expected first counter to be 1, got ${first}`);
    console.log('[flow-f-runner-smoke] command 1: module counter = 1');

    const second = await promptCounter(child, 'flow-f second invocation');
    if (second !== 2) {
      fail(
        `module-local state did NOT survive across separate commands: expected 2, got ${second} ` +
          '(a fresh-process-per-command runner would reset to 1)',
      );
    }
    console.log('[flow-f-runner-smoke] command 2 (same session): module counter = 2 -> state persisted');
  } finally {
    await child.close();
  }

  // --- Control: a fresh rpc child resets module state to 1. ------------------
  const controlSession = freshSession('control-session.jsonl');
  const control = new RpcChild(env, controlSession);
  try {
    const modelResp = await control.call({ type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
    if (!modelResp.success) fail('control set_model failed');
    const controlFirst = await promptCounter(control, 'flow-f control invocation');
    if (controlFirst !== 1) {
      fail(`control: a fresh rpc process should reset the counter to 1, got ${controlFirst}`);
    }
    console.log('[flow-f-runner-smoke] control (fresh rpc process): module counter = 1 -> reset confirmed');
  } finally {
    await control.close();
  }

  provider.server.close();
  console.log('[flow-f-runner-smoke] PASS');
}

main().catch((err) => {
  console.error(err.message ?? String(err));
  process.exitCode = 1;
});

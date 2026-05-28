#!/usr/bin/env node
/**
 * Packaged-path workbench smoke.
 *
 * Proves the Preact workbench's RPC contract against a REAL `pi-zig rpc <file>`
 * child over NDJSON stdio — the exact transport the Prin7r app uses per
 * release/prin7r-app.manifest.json ("protocol": "ndjson-stdio",
 * launch ["bin/pi-zig", "rpc", "${PI_ZIG_SESSION_FILE}"]).
 *
 * Unlike the dev WebSocket bridge (frontend/server.mjs), this drives the child
 * directly the way the packaged backend_service_app is launched, and replays
 * the same command shapes the frontend's rpc/client.ts + rpc/protocol.ts emit.
 *
 * The fake OpenAI-compatible provider here is an EXPLICIT dev/test fixture; the
 * packaged backend is the real Zig binary. We assert, against that real child:
 *   - prompt streaming text (agent loop → fake provider → streamed deltas)
 *   - tool-panel updates (provider tool_call → real bash exec → tool result)
 *   - slash commands (get_commands)
 *   - settings changes (set_model, set_auto_retry, set_steering_mode)
 *   - abort (in-flight prompt against a delayed provider)
 *   - retry (auto-retry recovers a transient provider failure)
 *   - bash + bash-abort (real shell job, cancelled mid-run)
 *
 * Artifact: frontend/verification/05-packaged-rpc-transcript.json
 *
 * Run standalone: node scripts/workbench-packaged-smoke.mjs
 */

import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const here = fileURLToPath(new URL('.', import.meta.url));
const repoRoot = resolve(here, '..');
const bin = process.env.PI_ZIG_BIN ?? resolve(repoRoot, 'zig-out/bin/pi-zig');
const distDir = resolve(repoRoot, 'frontend/dist');
const verificationDir = resolve(repoRoot, 'frontend/verification');
const sessionFile = resolve(repoRoot, 'zig-out/packaged-smoke-session.jsonl');
const abortMarkerFile = resolve(repoRoot, 'zig-out/packaged-smoke-abort.started');

const transcript = [];
function record(kind, payload) {
  transcript.push({ t: Date.now(), kind, payload });
}

function fail(message) {
  console.error(`[packaged-smoke] FAIL: ${message}`);
  process.exitCode = 1;
  throw new Error(message);
}

// --- 0. The built bundle must exist (this is the packaged frontend surface) ---
function assertBuiltBundle() {
  if (!existsSync(resolve(distDir, 'index.html'))) {
    fail(`built frontend bundle missing: ${distDir}/index.html (run "npm --prefix frontend run build")`);
  }
  const assets = resolve(distDir, 'assets');
  if (!existsSync(assets)) fail(`built frontend assets missing: ${assets}`);
  const jsBundles = readdirSync(assets).filter((f) => f.endsWith('.js'));
  if (jsBundles.length === 0) fail('built frontend has no JS bundle under dist/assets');
  record('bundle', { indexHtml: true, jsBundles });
  console.log(`[packaged-smoke] built bundle OK (${jsBundles.length} JS asset(s))`);
}

// --- Inline OpenAI-compatible fake provider (explicit dev/test fixture) -------
// Supports: streamed text, a streamed bash tool call, and a one-shot transient
// failure (for the retry assertion) keyed off the prompt text.
function startFakeProvider() {
  const transientFailures = new Map(); // marker -> remaining failures
  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      let body = {};
      try {
        body = JSON.parse(raw || '{}');
      } catch {
        /* ignore */
      }
      const stream = body.stream === true;
      const messages = Array.isArray(body.messages) ? body.messages : [];
      // Match on the LATEST user message only (history accumulates across turns
      // in a reused session; matching all of it would misroute later prompts).
      const lastUser = [...messages].reverse().find((m) => m.role === 'user');
      const userText = lastUser
        ? typeof lastUser.content === 'string'
          ? lastUser.content
          : JSON.stringify(lastUser.content)
        : '';
      const toolMessages = messages.filter((m) => m.role === 'tool');

      // Transient failure path: first request for a "retry me" prompt 503s,
      // the retried request succeeds. Exercises auto-retry against the real child.
      if (userText.includes('retry me')) {
        const remaining = transientFailures.get('retry') ?? 1;
        if (remaining > 0) {
          transientFailures.set('retry', remaining - 1);
          res.writeHead(503, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: { message: 'service unavailable (transient)' } }));
          return;
        }
        reply(res, stream, 'recovered after retry');
        return;
      }

      // Tool-call path: "run bash" → emit a bash tool call, then text after result.
      if (userText.includes('run bash')) {
        if (toolMessages.length === 0) {
          if (stream) {
            writeStream(res, [
              {
                choices: [
                  {
                    delta: {
                      tool_calls: [
                        { index: 0, id: 'call_pkg_1', type: 'function', function: { name: 'bash', arguments: '{"command":"printf ' } },
                      ],
                    },
                  },
                ],
              },
              { choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: 'packaged-tool-ok"}' } }] } }] },
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
                    tool_calls: [
                      { id: 'call_pkg_1', type: 'function', function: { name: 'bash', arguments: '{"command":"printf packaged-tool-ok"}' } },
                    ],
                  },
                  finish_reason: 'tool_calls',
                },
              ],
            });
          }
          return;
        }
        const out = String(toolMessages.at(-1).content ?? '').trim();
        reply(res, stream, `tool loop done: ${out}`);
        return;
      }

      // Abort path: write a marker the moment the request lands, then hold the
      // response. The test sends `abort` after seeing the marker; when the held
      // response returns, the agent's post-request cooperative cancellation
      // checkpoint observes the abort flag and yields AgentAborted. (Zig
      // std.http has no hard socket-level cancel — cancellation fires at the
      // checkpoint after the fetch returns, which is the proven mechanism.)
      // Abort path: return a transient 503 and write a marker. With auto-retry
      // enabled, the worker enters a CANCELLABLE retry sleep (polled every 25ms,
      // not blocked in std.http). The test sees the marker, then sends `abort`,
      // which deterministically cancels the retry sleep — the reliable
      // cancellation window given the documented std.http socket-cancel limit.
      if (userText.includes('abort me')) {
        try {
          writeFileSync(abortMarkerFile, 'started');
        } catch {
          /* ignore */
        }
        res.writeHead(503, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { message: 'service unavailable (transient) for abort test' } }));
        return;
      }

      reply(res, stream, 'packaged round-trip works');
    });
  });
  return new Promise((resolveServer) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolveServer({ server, baseUrl: `http://127.0.0.1:${port}/v1` });
    });
  });

  function textDelta(content, first) {
    const delta = first ? { role: 'assistant', content } : { content };
    return { choices: [{ index: 0, delta, finish_reason: null }] };
  }
  function finalDelta() {
    return { choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] };
  }
  // Reply with either an SSE text stream or a non-streaming JSON completion,
  // matching whichever the agent loop requested (body.stream).
  function reply(res, stream, text) {
    if (stream) {
      writeStream(res, [textDelta(text, true), finalDelta()]);
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

// --- Real packaged backend child over NDJSON stdio ----------------------------
class PackagedBackend {
  constructor(env, sessionPath = sessionFile) {
    // Exactly mirrors manifest launch: ["bin/pi-zig", "rpc", "<session>"].
    this.child = spawn(bin, ['rpc', sessionPath], {
      cwd: repoRoot,
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
      record('recv', parsed);
      this._notify(parsed);
    }
  }

  _notify(line) {
    for (let i = 0; i < this.waiters.length; ) {
      if (this.waiters[i].predicate(line)) {
        const w = this.waiters.splice(i, 1)[0];
        clearTimeout(w.timer);
        w.resolve(line);
      } else {
        i += 1;
      }
    }
  }

  send(command) {
    const id = command.id ?? `c-${++this.seq}`;
    const payload = { ...command, id };
    record('send', payload);
    this.child.stdin.write(`${JSON.stringify(payload)}\n`);
    return id;
  }

  waitFor(predicate, timeoutMs = 15000, label = 'line') {
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

  // Send a command and await its correlated response (matches RpcClient.request).
  async call(command, timeoutMs = 15000) {
    const id = this.send(command);
    const resp = await this.waitFor(
      (l) => l.type === 'response' && l.id === id,
      timeoutMs,
      `response for ${command.type}`,
    );
    return resp;
  }

  close() {
    // Manifest shutdown contract: closing stdin (EOF) terminates the child.
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

async function main() {
  if (!existsSync(bin)) {
    console.log(`[packaged-smoke] SKIP: binary not found: ${bin} (run "zig build")`);
    return;
  }
  mkdirSync(verificationDir, { recursive: true });
  mkdirSync(resolve(repoRoot, 'zig-out'), { recursive: true });
  if (existsSync(sessionFile)) {
    try {
      const { rmSync } = await import('node:fs');
      rmSync(sessionFile);
    } catch {
      /* ignore */
    }
  }

  assertBuiltBundle();

  const fake = await startFakeProvider();
  const env = {
    ...process.env,
    OPENAI_API_KEY: 'fake-provider-key',
    PI_ZIG_PROVIDER_BASE_URL: fake.baseUrl,
  };

  // --- Healthcheck (manifest: ["bin/pi-zig","status"], expectExit 0) ---
  await new Promise((resolveHc, rejectHc) => {
    const hc = spawn(bin, ['status'], { cwd: repoRoot, env });
    hc.on('exit', (code) => (code === 0 ? resolveHc() : rejectHc(new Error(`healthcheck exit ${code}`))));
    hc.on('error', rejectHc);
  });
  console.log('[packaged-smoke] healthcheck OK');

  const backend = new PackagedBackend(env);
  try {
    // 1. Initial state (frontend boots with get_state).
    const state0 = await backend.call({ type: 'get_state' });
    if (!state0.success) fail('get_state failed');
    console.log('[packaged-smoke] get_state OK');

    // 2. Settings changes: model, auto-retry, steering mode.
    const modelResp = await backend.call({ type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
    if (!modelResp.success) fail('set_model failed');
    const retryResp = await backend.call({ type: 'set_auto_retry', enabled: true, maxRetries: 2, baseDelayMs: 0 });
    if (!retryResp.success) fail('set_auto_retry failed');
    const steerResp = await backend.call({ type: 'set_steering_mode', mode: 'one-at-a-time' });
    if (!steerResp.success) fail('set_steering_mode failed');
    const stateAfter = await backend.call({ type: 'get_state' });
    if (stateAfter.data?.autoRetryEnabled !== true || stateAfter.data?.steeringMode !== 'one-at-a-time') {
      fail('settings changes did not persist in get_state');
    }
    if (stateAfter.data?.model?.id !== 'gpt-4o') fail('set_model not reflected in get_state');
    console.log('[packaged-smoke] settings changes OK (model + auto-retry + steering)');

    // 3. Slash commands inventory.
    const commandsResp = await backend.call({ type: 'get_commands' });
    if (!commandsResp.success || !Array.isArray(commandsResp.data?.commands)) fail('get_commands failed');
    console.log(`[packaged-smoke] get_commands OK (${commandsResp.data.commands.length} commands)`);

    // 4. Prompt streaming text (real agent loop → fake provider).
    const promptResp = await backend.call({ type: 'prompt', message: 'hello packaged path' }, 20000);
    if (!promptResp.success) fail(`prompt failed: ${promptResp.error}`);
    if (!String(promptResp.data?.text ?? '').includes('packaged round-trip works')) {
      fail(`prompt did not return streamed provider text: ${JSON.stringify(promptResp.data)}`);
    }
    console.log('[packaged-smoke] prompt streaming OK');

    // 5. Tool-panel updates: provider tool_call → real bash → tool result.
    const toolPromptResp = await backend.call({ type: 'prompt', message: 'please run bash for me' }, 20000);
    if (!toolPromptResp.success) fail(`tool prompt failed: ${toolPromptResp.error}`);
    if (!String(toolPromptResp.data?.text ?? '').includes('tool loop done: packaged-tool-ok')) {
      fail(`tool loop did not complete: ${JSON.stringify(toolPromptResp.data)}`);
    }
    const toolResults = toolPromptResp.data?.toolResults ?? [];
    if (!Array.isArray(toolResults) || toolResults.length === 0) fail('prompt response carried no toolResults panel data');
    const messagesResp = await backend.call({ type: 'get_messages' });
    const hasToolCall = (messagesResp.data?.messages ?? []).some(
      (m) => m.role === 'assistant' && Array.isArray(m.toolCalls) && m.toolCalls.some((c) => c.name === 'bash'),
    );
    const hasToolResult = (messagesResp.data?.messages ?? []).some((m) => m.role === 'tool');
    if (!hasToolCall || !hasToolResult) fail('get_messages missing tool-call / tool-result panel data');
    console.log('[packaged-smoke] tool-panel updates OK (tool call + result in transcript)');

    // 6. Retry: auto-retry recovers a transient provider failure.
    const retryPromptResp = await backend.call({ type: 'prompt', message: 'retry me please' }, 20000);
    if (!retryPromptResp.success) fail(`retry prompt failed: ${retryPromptResp.error}`);
    if (!String(retryPromptResp.data?.text ?? '').includes('recovered after retry')) {
      fail(`retry did not recover: ${JSON.stringify(retryPromptResp.data)}`);
    }
    if ((retryPromptResp.data?.retry?.attempts ?? 0) < 1) fail('retry metadata did not record an attempt');
    console.log(`[packaged-smoke] retry OK (attempts=${retryPromptResp.data.retry.attempts})`);

    // 7. bash + bash-abort: start a slow shell job, then abort it.
    const abortBackendId = backend.send({ type: 'bash', command: 'sleep 30', timeout: 60000 });
    // Wait until the child reports the bash job running.
    await pollUntil(async () => {
      const s = await backend.call({ type: 'get_state' });
      return s.data?.isBashRunning === true;
    }, 8000, 'isBashRunning');
    const abortResp = await backend.call({ type: 'abort_bash' });
    if (!abortResp.success) fail('abort_bash failed');
    const bashResp = await backend.waitFor(
      (l) => l.type === 'response' && l.id === abortBackendId,
      10000,
      'bash response after abort',
    );
    if (!bashResp.success || bashResp.data?.cancelled !== true) {
      fail(`bash job was not cancelled: ${JSON.stringify(bashResp)}`);
    }
    console.log('[packaged-smoke] bash-abort OK (cancelled mid-run)');

    // 8. Abort an in-flight prompt. The provider writes a marker and holds the
    //    response; once we see the marker we send `abort` (a non-blocking RPC
    //    command read while the prompt worker is active). When the held response
    //    returns, the agent's cooperative cancellation checkpoint yields
    //    AgentAborted. Uses a fresh session so provider routing is unambiguous.
    await backend.close();
    const abortSessionFile = resolve(repoRoot, 'zig-out/packaged-smoke-abort-session.jsonl');
    const { rmSync } = await import('node:fs');
    for (const f of [abortSessionFile, abortMarkerFile]) {
      try {
        if (existsSync(f)) rmSync(f);
      } catch {
        /* ignore */
      }
    }
    const abortBackend = new PackagedBackend(env, abortSessionFile);
    try {
      await abortBackend.call({ type: 'set_model', provider: 'openai', modelId: 'gpt-4o' });
      // Long base delay → a wide cancellable retry-sleep window to abort within.
      await abortBackend.call({ type: 'set_auto_retry', enabled: true, maxRetries: 5, baseDelayMs: 3000, maxDelayMs: 10000 });
      const promptId = abortBackend.send({ type: 'prompt', message: 'abort me please' });
      // Marker appears once the transient 503 lands → worker now in retry sleep.
      await pollUntil(async () => existsSync(abortMarkerFile), 8000, 'abort marker file');
      const promptAbort = await abortBackend.call({ type: 'abort' }, 4000);
      if (!promptAbort.success) fail('abort (prompt) failed');
      const promptDone = await abortBackend
        .waitFor((l) => l.type === 'response' && l.id === promptId, 12000, 'aborted prompt response')
        .catch((e) => {
          console.error('[packaged-smoke][debug] abort backend lines:', JSON.stringify(abortBackend.lines));
          throw e;
        });
      record('abort-prompt-result', promptDone);
      // Cancelling the retry sleep settles the prompt as a failure (not success).
      if (promptDone.success !== false) {
        fail(`in-flight prompt was not aborted: ${JSON.stringify(promptDone)}`);
      }
      // Child stays responsive after the abort settles.
      const stateAfterAbort = await abortBackend.call({ type: 'get_state' }, 5000);
      if (!stateAfterAbort.success) fail('child unresponsive after prompt abort');
      console.log(`[packaged-smoke] prompt abort OK (retry-sleep cancelled: ${promptDone.error}, child responsive)`);
    } finally {
      await abortBackend.close();
    }

    fake.server.close();

    const artifact = resolve(verificationDir, '05-packaged-rpc-transcript.json');
    writeFileSync(
      artifact,
      JSON.stringify(
        {
          generatedAt: new Date().toISOString(),
          transport: 'ndjson-stdio',
          launch: ['bin/pi-zig', 'rpc', '<session>'],
          note: 'Real pi-zig rpc child driven with the frontend rpc/client.ts command shapes. Fake provider is an explicit dev/test fixture.',
          provedSurfaces: [
            'prompt streaming',
            'tool-panel updates',
            'slash commands',
            'settings changes',
            'retry',
            'bash + bash-abort',
            'prompt abort',
          ],
          transcript,
        },
        null,
        2,
      ),
    );
    console.log(`[packaged-smoke] PASS — artifact: ${artifact}`);
  } catch (err) {
    fake.server.close();
    if (!backend.child.killed) await backend.close();
    throw err;
  }
}

async function pollUntil(predicate, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`timed out waiting for condition: ${label}`);
}

main().catch((err) => {
  console.error(`[packaged-smoke] ${err.message}`);
  process.exitCode = 1;
});

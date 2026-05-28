#!/usr/bin/env node
// Flow C: Agent Runtime Remaining Provider Parity smoke.
//
// Standalone Node.js stdlib smoke (no npm deps) that exercises three runtime-parity surfaces
// against the real `zig-out/bin/pi-zig` binary using a fake provider over node:http:
//
//   1. Google/Vertex `thoughtSignature` persistence survives an RPC session reload round-trip.
//      A fake Google `:streamGenerateContent` provider returns a functionCall with a
//      thoughtSignature; the agent persists the assistant tool-call message; switch_session
//      reloads the JSONL file and get_messages must still report the thoughtSignature.
//
//   2. Cross-mode retry parity: a 200 SSE stream that ends before `data: [DONE]` is classified
//      as ProviderStreamIncomplete and must be auto-retried in top-level JSON mode (mirroring the
//      RPC retry classifier), recovering on the second attempt. Non-retryable client errors (4xx)
//      must NOT be retried.
//
//   3. images.autoResize threading: an oversized image read via the `read` tool is omitted with a
//      resize note when images.autoResize=true (default), and passes through at original size with
//      no resize note (image content part retained) when images.autoResize=false.
//
// Mirrors scripts/verify-basic.mjs helpers (startFakeProviderServer, runRpcSequential). Exits
// non-zero on any failure; prints "[flow-c-smoke] PASS" on success.

import { execFileSync, spawn } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const bin = path.resolve('zig-out/bin/pi-zig');
const workDir = path.resolve('zig-out/flow-c-smoke');

function fail(message) {
  console.error(`[flow-c-smoke] FAIL: ${message}`);
  process.exit(1);
}

function ensureBinary() {
  // Build the project so the smoke is runnable standalone. Surface build output on failure so a
  // broken tree is obvious rather than silently using a stale binary.
  try {
    execFileSync('zig', ['build'], { stdio: ['ignore', 'inherit', 'inherit'] });
  } catch (error) {
    fail(`zig build failed: ${error.message}`);
  }
  if (!fs.existsSync(bin)) {
    fail(`binary not found at ${bin} after zig build`);
  }
}

function jsonLines(text) {
  return text
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

// Run the binary and return stdout, throwing on non-zero exit.
function run(args, options = {}) {
  return execFileSync(bin, args, { encoding: 'utf8', ...options });
}

// Run the binary expecting a non-zero exit; return { status, stdout, stderr }.
function runFail(args, options = {}) {
  try {
    const stdout = execFileSync(bin, args, { encoding: 'utf8', ...options });
    throw new Error(`expected command to fail but it succeeded: ${args.join(' ')}\n${stdout}`);
  } catch (error) {
    if (error.status === undefined) throw error;
    return { status: error.status, stdout: error.stdout ?? '', stderr: error.stderr ?? '' };
  }
}

// Async variants of run/runFail. These MUST be used for any binary invocation that talks to the
// in-process fake provider: a synchronous execFileSync blocks the Node event loop, which starves
// the in-process http server and deadlocks the provider round-trip. spawn keeps the loop free.
function runAsync(args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { cwd: options.cwd, env: options.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolve(stdout);
      else reject(Object.assign(new Error(`command failed (exit ${code}): ${args.join(' ')}\n${stderr}`), { status: code, stdout, stderr }));
    });
  });
}

function runFailAsync(args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { cwd: options.cwd, env: options.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) reject(new Error(`expected command to fail but it succeeded: ${args.join(' ')}\n${stdout}`));
      else resolve({ status: code, stdout, stderr });
    });
  });
}

// Drive `pi-zig rpc <session>` over NDJSON stdin/stdout, correlating responses by command id.
// Mirrors verify-basic.mjs runRpcSequential.
async function runRpcSequential(args, commands, options = {}) {
  const child = spawn(bin, args, {
    cwd: options.cwd,
    env: options.env,
    stdio: ['pipe', 'pipe', 'pipe']
  });
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
    for (let index = 0; index < waiters.length;) {
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
  function waitForLine(predicate, timeoutMs = options.timeoutMs ?? 15000) {
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
    }, options.exitTimeoutMs ?? 40000);
    child.once('error', (error) => {
      clearTimeout(timeout);
      failWaiters(error);
      reject(error);
    });
    child.once('exit', (code, signal) => {
      clearTimeout(timeout);
      if (code !== 0) {
        const error = new Error(`RPC run exited with ${code ?? signal}\nstdout:\n${stdout}\nstderr:\n${stderr}`);
        failWaiters(error);
        reject(error);
        return;
      }
      resolve();
    });
  });
  try {
    for (const command of commands) {
      child.stdin.write(`${JSON.stringify(command)}\n`);
      if (command.id) await waitForLine((line) => line.id === command.id);
    }
    child.stdin.end();
    await exitPromise;
  } catch (error) {
    child.kill('SIGKILL');
    throw error;
  }
  return { stdout, stderr, lines };
}

// Fake provider HTTP server covering an OpenAI chat/completions endpoint and a Google
// streamGenerateContent endpoint. Behavior is keyed off the user prompt text so a single server
// drives all three sub-smokes. Per-prompt request counts let the first attempt fail (transient)
// and later attempts recover, mirroring verify-basic.mjs.
function startFakeProvider() {
  const requestCounts = new Map();

  const readBody = (req) =>
    new Promise((resolve) => {
      let raw = '';
      req.on('data', (chunk) => {
        raw += chunk;
      });
      req.on('end', () => resolve(raw));
    });

  const server = http.createServer(async (req, res) => {
    const requestUrl = new URL(req.url, 'http://127.0.0.1');
    const rawBody = await readBody(req);

    // --- Google native streamGenerateContent (thoughtSignature reload) ---------------------
    // RPC mode posts to the non-streaming `:generateContent` endpoint (JSON response); top-level
    // JSON/print streaming posts to `:streamGenerateContent?alt=sse` (SSE response). Handle both so
    // the same fixture works regardless of mode.
    const isGoogleStream = requestUrl.pathname.endsWith(':streamGenerateContent');
    const isGoogle =
      req.method === 'POST' &&
      requestUrl.pathname.includes('/models/') &&
      (isGoogleStream || requestUrl.pathname.endsWith(':generateContent'));
    if (isGoogle) {
      if (req.headers['x-goog-api-key'] !== 'fake-google-key') {
        res.writeHead(401, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'missing google auth', headers: req.headers }));
        return;
      }
      const body = JSON.parse(rawBody);
      const googlePartText = (part) =>
        part?.text ?? part?.functionResponse?.response?.output ?? part?.functionResponse?.response?.error ?? '';
      const googleContentText = (content) =>
        Array.isArray(content?.parts) ? content.parts.map(googlePartText).join('\n') : '';
      const userText =
        body.contents?.filter((content) => content.role === 'user').map(googleContentText).join('\n') ?? '';
      const functionResponses =
        body.contents?.flatMap((content) =>
          Array.isArray(content.parts) ? content.parts.filter((part) => part?.functionResponse) : []
        ) ?? [];
      const hasBashTool =
        body.tools?.some((tool) =>
          tool?.functionDeclarations?.some((decl) => decl?.name === 'bash' && decl?.parametersJsonSchema?.type === 'object')
        ) ?? false;
      // Emit candidates either as a single non-streaming JSON body or as SSE events depending on the
      // endpoint the client used.
      const writeGoogleCandidates = (candidatePayloads) => {
        if (isGoogleStream) {
          res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'close' });
          for (const candidates of candidatePayloads) {
            res.write('data: ' + JSON.stringify({ candidates }) + '\n\n');
          }
          res.end();
          return;
        }
        // Non-streaming generateContent: collapse to a single JSON body with all candidate parts.
        const parts = candidatePayloads.flatMap((candidates) => candidates[0]?.content?.parts ?? []);
        const finishReason =
          candidatePayloads.map((candidates) => candidates[0]?.finishReason).filter(Boolean).at(-1) ?? 'STOP';
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ candidates: [{ content: { parts }, finishReason }] }));
      };
      if (userText.includes('flow-c thought signature persistence')) {
        if (!body.systemInstruction?.parts?.some((part) => part.text) || !hasBashTool) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'google request shape mismatch', body, pathname: requestUrl.pathname }));
          return;
        }
        if (functionResponses.length === 0) {
          // First turn: emit a private thought + a functionCall carrying a thoughtSignature.
          writeGoogleCandidates([
            [
              {
                content: {
                  parts: [
                    { text: 'flow-c private thought', thought: true },
                    {
                      functionCall: { id: 'call_flow_c_google_1', name: 'bash', args: { command: 'printf flow-c-google-ok' } },
                      thoughtSignature: 'Zmxvdy1jLXNpZw=='
                    }
                  ]
                },
                finishReason: 'STOP'
              }
            ]
          ]);
          return;
        }
        // Second turn: the persisted thoughtSignature must be replayed back on the assistant turn.
        const assistantFunctionCalls =
          body.contents?.flatMap((content) =>
            Array.isArray(content.parts) ? content.parts.filter((part) => part?.functionCall) : []
          ) ?? [];
        if (
          !assistantFunctionCalls.some(
            (part) => part.functionCall?.name === 'bash' && part.thoughtSignature === 'Zmxvdy1jLXNpZw=='
          )
        ) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'thoughtSignature was not replayed', contents: body.contents }));
          return;
        }
        writeGoogleCandidates([
          [{ content: { parts: [{ text: 'flow-c google ' }] } }],
          [{ content: { parts: [{ text: 'tool complete: flow-c-google-ok' }] }, finishReason: 'STOP' }]
        ]);
        return;
      }
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'unknown google request', body }));
      return;
    }

    // --- OpenAI chat/completions (retry parity + image autoResize) -------------------------
    if (req.method !== 'POST' || requestUrl.pathname !== '/v1/chat/completions') {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'not found', pathname: requestUrl.pathname }));
      return;
    }
    if (req.headers.authorization !== 'Bearer fake-openai-key') {
      res.writeHead(401, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'missing openai auth', headers: req.headers }));
      return;
    }
    const body = JSON.parse(rawBody);
    const userText =
      body.messages
        ?.filter((message) => message.role === 'user')
        .map((message) =>
          typeof message.content === 'string'
            ? message.content
            : Array.isArray(message.content)
              ? message.content.map((part) => part?.text ?? '').join('\n')
              : ''
        )
        .join('\n') ?? '';
    const writeStreamEvents = (events) => {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'close' });
      for (const event of events) {
        res.write('data: ' + JSON.stringify(event) + '\n\n');
      }
      res.end('data: [DONE]\n\n');
    };

    // ProviderStreamIncomplete retry: first attempt opens a 200 SSE response and ends WITHOUT the
    // terminal `data: [DONE]` line (the Zig client maps reader-EOF-without-DONE to
    // ProviderStreamIncomplete). No content delta is emitted first so the turn stays "clean" and is
    // eligible for auto-retry (mid-stream output cannot be cleanly retried). The second attempt
    // completes normally.
    if (userText.includes('flow-c incomplete stream retry')) {
      const count = (requestCounts.get(userText) ?? 0) + 1;
      requestCounts.set(userText, count);
      if (count === 1) {
        res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'close' });
        // Intentionally end WITHOUT any `data:` line and WITHOUT `data: [DONE]`.
        res.end();
        return;
      }
      writeStreamEvents([{ choices: [{ delta: { content: 'flow-c incomplete stream recovered' } }] }]);
      return;
    }

    // Non-retryable client error: a 4xx must surface without any auto-retry.
    if (userText.includes('flow-c client error no retry')) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'flow-c non-transient client failure' }));
      return;
    }

    // Image autoResize: the model issues a single `read` tool call on the oversized image path,
    // then on the follow-up turn returns a short final text. The read-tool result is where the
    // autoResize behavior is observable.
    if (userText.includes('flow-c read oversized image')) {
      const toolMessages = body.messages?.filter((message) => message.role === 'tool') ?? [];
      if (toolMessages.length === 0) {
        const readPath = userText.split('::path::')[1]?.trim();
        if (!readPath) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'missing image path in prompt', userText }));
          return;
        }
        writeStreamEvents([
          {
            choices: [
              {
                delta: {
                  tool_calls: [
                    {
                      index: 0,
                      id: 'call_flow_c_read_1',
                      type: 'function',
                      function: { name: 'read', arguments: JSON.stringify({ path: readPath }) }
                    }
                  ]
                }
              }
            ]
          }
        ]);
        return;
      }
      writeStreamEvents([{ choices: [{ delta: { content: 'flow-c image read complete' } }] }]);
      return;
    }

    res.writeHead(400, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'unknown openai request', userText }));
  });

  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      resolve({
        baseUrl: `http://127.0.0.1:${address.port}/v1`,
        stop() {
          server.close();
        }
      });
    });
  });
}

function freshAgentDir(name, settings) {
  const dir = path.join(workDir, name);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  if (settings !== undefined) {
    fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify(settings));
  }
  return dir;
}

async function partThoughtSignatureReload(provider) {
  const agentDir = freshAgentDir('thought-signature-agent');
  const sessionFile = path.join(workDir, 'thought-signature-session.jsonl');
  fs.rmSync(sessionFile, { force: true });

  const env = {
    ...process.env,
    PI_CODING_AGENT_DIR: agentDir,
    GEMINI_API_KEY: 'fake-google-key',
    PI_ZIG_PROVIDER_BASE_URL: provider.baseUrl
  };
  delete env.ANTHROPIC_API_KEY;
  delete env.ANTHROPIC_OAUTH_TOKEN;

  const { lines } = await runRpcSequential(['rpc', sessionFile], [
    { id: 'tsig-model', type: 'set_model', provider: 'google', modelId: 'gemini-2.5-flash' },
    { id: 'tsig-prompt', type: 'prompt', message: 'flow-c thought signature persistence' },
    { id: 'tsig-pre-messages', type: 'get_messages' },
    // Reload the same JSONL file from disk, then re-read messages: the thoughtSignature must
    // survive the persistence + reload round-trip.
    { id: 'tsig-reload', type: 'switch_session', sessionPath: sessionFile },
    { id: 'tsig-post-messages', type: 'get_messages' }
  ], { env });

  const findToolCallSignature = (messagesLine) => {
    const messages = messagesLine?.data?.messages ?? [];
    for (const message of messages) {
      if (message.role !== 'assistant' || !Array.isArray(message.toolCalls)) continue;
      const call = message.toolCalls.find((tc) => tc.id === 'call_flow_c_google_1');
      if (call) return call.thoughtSignature;
    }
    return undefined;
  };

  const modelLine = lines.find((line) => line.id === 'tsig-model');
  if (!modelLine?.success) {
    fail(`set_model google/gemini-2.5-flash failed: ${JSON.stringify(modelLine)}`);
  }
  const promptLine = lines.find((line) => line.id === 'tsig-prompt');
  if (!promptLine?.success) {
    fail(`google tool-call prompt failed: ${JSON.stringify(promptLine)}`);
  }

  const preSignature = findToolCallSignature(lines.find((line) => line.id === 'tsig-pre-messages'));
  if (preSignature !== 'Zmxvdy1jLXNpZw==') {
    fail(`thoughtSignature not persisted before reload (got ${JSON.stringify(preSignature)})`);
  }

  const reloadLine = lines.find((line) => line.id === 'tsig-reload');
  if (!reloadLine?.success) {
    fail(`switch_session reload failed: ${JSON.stringify(reloadLine)}`);
  }

  const postSignature = findToolCallSignature(lines.find((line) => line.id === 'tsig-post-messages'));
  if (postSignature !== 'Zmxvdy1jLXNpZw==') {
    fail(`thoughtSignature did not survive reload round-trip (got ${JSON.stringify(postSignature)})`);
  }

  // The persisted JSONL on disk must also carry the signature (proves it is written, not just
  // held in memory).
  const persisted = fs.readFileSync(sessionFile, 'utf8');
  if (!persisted.includes('Zmxvdy1jLXNpZw==')) {
    fail('persisted session JSONL does not contain the thoughtSignature');
  }

  console.log('[flow-c-smoke] thoughtSignature reload round-trip: OK');
}

async function partRetryParity(provider) {
  const retryEnv = {
    ...process.env,
    PI_CODING_AGENT_DIR: freshAgentDir('retry-agent', { retry: { enabled: true, maxRetries: 2, baseDelayMs: 0 } }),
    OPENAI_API_KEY: 'fake-openai-key',
    PI_ZIG_PROVIDER_BASE_URL: provider.baseUrl
  };

  // ProviderStreamIncomplete must be retried in top-level JSON mode and recover.
  const incompleteLines = jsonLines(
    await runAsync(
      ['--mode', 'json', '--no-session', '--no-tools', '--provider', 'openai', '--model', 'gpt-4o', '-p', 'flow-c incomplete stream retry'],
      { env: retryEnv }
    )
  );
  const contentText = (message) =>
    Array.isArray(message?.content) ? message.content.map((part) => part?.text ?? '').join('') : '';
  const retryStart = incompleteLines.find((line) => line.type === 'auto_retry_start');
  const recovered = incompleteLines.some(
    (line) => line.type === 'message_update' && line.assistantMessageEvent?.delta === 'flow-c incomplete stream recovered'
  );
  // The first message_end reports the incomplete-stream error; the recovered turn is the last one.
  const finalMessageEnd = incompleteLines.filter((line) => line.type === 'message_end').at(-1);
  const retryEnd = incompleteLines.find((line) => line.type === 'auto_retry_end' && line.success === true);
  if (!retryStart) {
    fail('JSON-mode incomplete stream did not emit auto_retry_start');
  }
  if (retryStart.errorMessage !== 'ProviderStreamIncomplete') {
    fail(`JSON-mode retry classified the wrong error (got ${JSON.stringify(retryStart.errorMessage)})`);
  }
  if (!recovered) {
    fail('JSON-mode incomplete stream did not recover on retry');
  }
  if (!retryEnd) {
    fail('JSON-mode incomplete stream did not emit a successful auto_retry_end');
  }
  if (!finalMessageEnd || contentText(finalMessageEnd.message) !== 'flow-c incomplete stream recovered') {
    fail(`JSON-mode recovered message_end did not contain the recovered text (got ${JSON.stringify(finalMessageEnd?.message?.content)})`);
  }
  console.log('[flow-c-smoke] JSON-mode ProviderStreamIncomplete retry + recovery: OK');

  // A non-transient 4xx client error must NOT be retried.
  const clientErrorEnv = {
    ...process.env,
    PI_CODING_AGENT_DIR: freshAgentDir('retry-client-agent', { retry: { enabled: true, maxRetries: 2, baseDelayMs: 0 } }),
    OPENAI_API_KEY: 'fake-openai-key',
    PI_ZIG_PROVIDER_BASE_URL: provider.baseUrl
  };
  const clientErrorResult = await runFailAsync(
    ['--mode', 'json', '--no-session', '--no-tools', '--provider', 'openai', '--model', 'gpt-4o', '-p', 'flow-c client error no retry'],
    { env: clientErrorEnv }
  );
  const clientErrorLines = jsonLines(clientErrorResult.stdout);
  if (clientErrorLines.some((line) => line.type === 'auto_retry_start' || line.type === 'auto_retry_end')) {
    fail('non-transient client error was retried in JSON mode');
  }
  const clientMessageEnd = clientErrorLines.find((line) => line.type === 'message_end');
  if (clientMessageEnd?.message?.errorMessage !== 'ProviderClientError') {
    fail(`client error did not surface as ProviderClientError (got ${JSON.stringify(clientMessageEnd?.message?.errorMessage)})`);
  }
  console.log('[flow-c-smoke] JSON-mode non-transient client error stays non-retryable: OK');
}

function writeOversizedPng(filePath) {
  // 4.5MB+ payload with a valid PNG signature + IHDR so mime detection recognizes it as image/png
  // while staying above the read-tool's encoded-size gate.
  const size = Math.ceil((9 * 1024 * 1024) / 2) + 1024;
  const buffer = Buffer.alloc(size, 0x41);
  const header = Buffer.from([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52
  ]);
  header.copy(buffer, 0);
  fs.writeFileSync(filePath, buffer);
}

async function readToolEvents(provider, autoResize) {
  const label = autoResize ? 'autoResize-true' : 'autoResize-false';
  const agentDir = freshAgentDir(`image-${label}-agent`, { images: { autoResize } });
  const imagePath = path.join(workDir, `oversized-${label}.png`);
  writeOversizedPng(imagePath);

  const env = {
    ...process.env,
    PI_CODING_AGENT_DIR: agentDir,
    OPENAI_API_KEY: 'fake-openai-key',
    PI_ZIG_PROVIDER_BASE_URL: provider.baseUrl
  };
  const lines = jsonLines(
    await runAsync(
      [
        '--mode', 'json',
        '--no-session',
        '--provider', 'openai',
        '--model', 'gpt-4o',
        '-p', `flow-c read oversized image ::path::${imagePath}`
      ],
      { env }
    )
  );
  const readEnd = lines.find(
    (line) => line.type === 'tool_execution_end' && line.toolName === 'read' && line.toolCallId === 'call_flow_c_read_1'
  );
  if (!readEnd) {
    fail(`${label}: read tool did not run (no tool_execution_end)`);
  }
  return readEnd;
}

async function partImageAutoResize(provider) {
  const resizeNote = 'Image omitted: could not be resized below the inline image size limit.';

  // autoResize=true (default behavior): oversized image is omitted with the resize note and no
  // image content part is sent.
  const resizeOnEnd = await readToolEvents(provider, true);
  const resizeOnJson = JSON.stringify(resizeOnEnd.result);
  if (!resizeOnJson.includes(resizeNote)) {
    fail(`autoResize=true: expected resize-omitted note in read result, got ${resizeOnJson}`);
  }
  if (resizeOnJson.includes('"type":"image"')) {
    fail('autoResize=true: oversized image content part should have been omitted');
  }
  console.log('[flow-c-smoke] images.autoResize=true omits oversized image with resize note: OK');

  // autoResize=false: oversized image passes through at original size, no resize note, image
  // content part retained.
  const resizeOffEnd = await readToolEvents(provider, false);
  const resizeOffJson = JSON.stringify(resizeOffEnd.result);
  if (resizeOffJson.includes(resizeNote)) {
    fail(`autoResize=false: resize-omitted note should be absent, got ${resizeOffJson}`);
  }
  if (!resizeOffJson.includes('"type":"image"')) {
    fail(`autoResize=false: expected image content part to pass through, got ${resizeOffJson}`);
  }
  console.log('[flow-c-smoke] images.autoResize=false passes oversized image through with no resize note: OK');
}

async function main() {
  ensureBinary();
  fs.mkdirSync(workDir, { recursive: true });
  const provider = await startFakeProvider();
  try {
    await partThoughtSignatureReload(provider);
    await partRetryParity(provider);
    await partImageAutoResize(provider);
  } finally {
    provider.stop();
  }
  console.log('[flow-c-smoke] PASS');
}

main().catch((error) => {
  fail(error.stack ?? error.message ?? String(error));
});

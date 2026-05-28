// Wave 2 TUI / print-completeness smoke.
//
// The interactive TUI itself drives a raw-mode terminal and cannot run headless, so this smoke
// covers the CLI-observable surface of the wave (the App-level palette/model-selector/session-
// callback logic is covered by unit tests in src/pi/tui.zig). It asserts, against the REAL
// `zig-out/bin/pi-zig` binary, three things:
//
//   1. Model fallback/default selection (cli_runtime applyDefaultModelSelection): a `--provider`
//      with no `--model` resolves a real catalog model and reaches the provider instead of the
//      inert "Provider execution is not implemented" foundation response.
//   2. JSON-mode abort lifecycle parity (cli_runtime SIGINT -> should_cancel -> AgentAborted):
//      interrupting a `--mode json` streaming run emits the upstream abort lifecycle
//      (stopReason "aborted" / "Request was aborted" / agent_end), mirroring the RPC abort events.
//   3. Non-TTY interactive fallback: launching with no prompt and a non-TTY stdin prints the
//      "requires a terminal" notice and falls back to help (unchanged contract).
//
// Pure Node stdlib. Run `zig build` first (done here for DoD). The fake provider runs in its OWN
// child process (like verify-basic) so synchronous pi-zig runs never starve its event loop.
// Prints "[wave2-tui-smoke] PASS" and exits 0 on success; throws / non-zero exit on any failure.

import { spawn, spawnSync } from 'node:child_process';
import path from 'node:path';

const bin = path.resolve('zig-out/bin/pi-zig');

function fail(message) {
  throw new Error(`[wave2-tui-smoke] ${message}`);
}

function ensureBinary() {
  const result = spawnSync('zig', ['build'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.status !== 0) {
    fail(`zig build failed (status ${result.status})\nstdout:\n${result.stdout ?? ''}\nstderr:\n${result.stderr ?? ''}`);
  }
}

function jsonLines(text) {
  return text
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

// --- Fake OpenAI-compatible provider (runs as its own child process) ------
// /v1/chat/completions, Bearer auth. Two behaviors keyed off the prompt text:
//   * default: stream a short SSE completion that echoes the model id from the request body
//     (proves the Zig client sent a concrete, resolved model).
//   * "HANG_FOR_ABORT": stream one delta then drip SSE keepalive comment lines forever, so the Zig
//     stream loop keeps re-checking cancellation and a SIGINT aborts promptly.
const providerSource = `
import http from 'node:http';
const server = http.createServer((req, res) => {
  let raw = '';
  req.on('data', (c) => { raw += c; });
  req.on('end', () => {
    if (req.method !== 'POST' || !req.url.endsWith('/chat/completions')) {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'not found', url: req.url }));
      return;
    }
    if (req.headers.authorization !== 'Bearer fake-wave2-key') {
      res.writeHead(401, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'missing auth' }));
      return;
    }
    let body = {};
    try { body = JSON.parse(raw || '{}'); } catch {}
    const model = String(body.model ?? '');
    const userText = Array.isArray(body.messages)
      ? body.messages.filter((m) => m.role === 'user')
          .map((m) => Array.isArray(m.content) ? m.content.map((p) => p.text ?? '').join('') : String(m.content ?? ''))
          .join('\\n')
      : '';
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'close' });
    if (userText.includes('HANG_FOR_ABORT')) {
      // One real delta so the assistant turn starts, then drip keepalives so the Zig stream loop
      // keeps re-checking cancellation; a SIGINT then aborts promptly.
      res.write('data: ' + JSON.stringify({ choices: [{ index: 0, delta: { role: 'assistant', content: 'partial ' }, finish_reason: null }] }) + '\\n\\n');
      const interval = setInterval(() => {
        try { res.write(': keepalive\\n\\n'); } catch { clearInterval(interval); }
      }, 80);
      res.on('close', () => clearInterval(interval));
      return;
    }
    res.write('data: ' + JSON.stringify({ choices: [{ index: 0, delta: { role: 'assistant', content: 'resolved-model=' + model }, finish_reason: null }] }) + '\\n\\n');
    res.write('data: ' + JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }) + '\\n\\n');
    res.end('data: [DONE]\\n\\n');
  });
});
server.listen(0, '127.0.0.1', () => {
  process.stdout.write('http://127.0.0.1:' + server.address().port + '/v1\\n');
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
`;

function startFakeProvider() {
  const child = spawn(process.execPath, ['--input-type=module', '-e', providerSource], {
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  return new Promise((resolve, reject) => {
    let text = '';
    child.stdout.on('data', (chunk) => {
      text += chunk.toString('utf8');
      const newline = text.indexOf('\n');
      if (newline >= 0) {
        resolve({
          baseUrl: text.slice(0, newline).trim(),
          stop() {
            child.kill('SIGTERM');
          },
        });
      }
    });
    child.once('error', reject);
    child.once('exit', (code) => {
      if (code !== 0 && code !== null) reject(new Error(`[wave2-tui-smoke] fake provider exited early with ${code}`));
    });
  });
}

// Run the binary to completion synchronously (safe: the provider is a separate process).
function runCapture(args, env) {
  const result = spawnSync(bin, args, { encoding: 'utf8', env, stdio: ['pipe', 'pipe', 'pipe'] });
  return { status: result.status, stdout: result.stdout ?? '', stderr: result.stderr ?? '', signal: result.signal };
}

// Run the binary, send SIGINT once a JSON line satisfies `readyPredicate`, then collect output.
function runUntilSigint(args, env, readyPredicate, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { env, stdio: ['pipe', 'pipe', 'pipe'] });
    // Close stdin immediately: in print mode pi-zig reads piped stdin to EOF (readPipedStdin),
    // so an open stdin pipe would block it before the provider call ever runs.
    child.stdin.end();
    let stdout = '';
    let stderr = '';
    let interrupted = false;
    let buffer = '';

    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        /* ignore */
      }
      reject(new Error(`[wave2-tui-smoke] timed out waiting for abort lifecycle\nstdout:\n${stdout}\nstderr:\n${stderr}`));
    }, timeoutMs);

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      buffer += chunk;
      let idx;
      while ((idx = buffer.indexOf('\n')) >= 0) {
        const raw = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 1);
        if (raw.trim().length === 0) continue;
        if (!interrupted && readyPredicate(raw)) {
          interrupted = true;
          setTimeout(() => {
            try {
              child.kill('SIGINT');
            } catch {
              /* ignore */
            }
          }, 50);
        }
      }
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('exit', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr, interrupted });
    });
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

async function main() {
  ensureBinary();

  const provider = await startFakeProvider();
  const env = {
    ...process.env,
    OPENAI_API_KEY: 'fake-wave2-key',
    PI_ZIG_PROVIDER_BASE_URL: provider.baseUrl,
    PI_OFFLINE: '1',
  };

  try {
    // --- 1. Model default/fallback selection ---------------------------------
    // --provider openai with NO --model must resolve a real catalog model and reach the provider.
    const defaultModel = runCapture(
      ['--mode', 'json', '--no-session', '--no-tools', '--provider', 'openai', '-p', 'wave2 default model selection'],
      env,
    );
    const defaultLines = jsonLines(defaultModel.stdout);
    const echoed = defaultLines.find(
      (line) => line.type === 'message_update' && /resolved-model=/.test(JSON.stringify(line)),
    );
    if (!echoed) {
      fail(
        'default model selection did not reach the provider with a resolved model ' +
          `(status ${defaultModel.status}, signal ${defaultModel.signal})\nstdout:\n${defaultModel.stdout}\nstderr:\n${defaultModel.stderr}`,
      );
    }
    const echoedModel = JSON.stringify(echoed).match(/resolved-model=([^"\\]+)/)?.[1] ?? '';
    if (!echoedModel || echoedModel === 'undefined' || echoedModel.length === 0) {
      fail(`provider received an empty/unset model id (echoed: "${echoedModel}")`);
    }
    if (!defaultLines.some((line) => line.type === 'agent_end')) {
      fail('default model selection run did not complete with an agent_end event');
    }
    // Negative control: an UNKNOWN provider with no catalog entries must NOT resolve a model and
    // instead falls back to the inert foundation text (proving selection is provider-scoped).
    const unknownProvider = runCapture(
      ['--no-session', '--provider', 'definitely-not-a-real-provider', '-p', 'wave2 unknown provider'],
      env,
    );
    if (!/Provider execution is not implemented/.test(unknownProvider.stdout)) {
      fail(
        'unknown provider unexpectedly resolved a model instead of the foundation response ' +
          `(stdout:\n${unknownProvider.stdout})`,
      );
    }
    console.log(`[wave2-tui-smoke] model default selection: provider reached with resolved model "${echoedModel}"`);

    // --- 2. JSON-mode abort lifecycle parity ---------------------------------
    // Stream a hanging run, SIGINT after the first delta, assert the abort lifecycle events.
    const abort = await runUntilSigint(
      ['--mode', 'json', '--no-session', '--no-tools', '--provider', 'openai', '--model', 'gpt-5.4', '-p', 'HANG_FOR_ABORT please'],
      env,
      (rawLine) => {
        try {
          const obj = JSON.parse(rawLine);
          return obj.type === 'message_update' || (obj.type === 'message_start' && obj.message?.role === 'assistant');
        } catch {
          return false;
        }
      },
    );
    if (!abort.interrupted) {
      fail(`abort run never reached a streaming state to interrupt\nstdout:\n${abort.stdout}\nstderr:\n${abort.stderr}`);
    }
    const abortLines = jsonLines(abort.stdout);
    const abortedMessageEnd = abortLines.find(
      (line) => line.type === 'message_end' && line.message?.stopReason === 'aborted',
    );
    const abortedTurnEnd = abortLines.find(
      (line) => line.type === 'turn_end' && line.message?.stopReason === 'aborted',
    );
    const abortedAgentEnd = abortLines.find(
      (line) => line.type === 'agent_end' && line.messages?.at(-1)?.stopReason === 'aborted',
    );
    if (!abortedMessageEnd || !abortedTurnEnd || !abortedAgentEnd) {
      fail(
        'JSON abort run did not emit the upstream "aborted" lifecycle ' +
          `(message_end/turn_end/agent_end with stopReason "aborted").\nlines:\n${abort.stdout}\nstderr:\n${abort.stderr}`,
      );
    }
    if (abortedTurnEnd.message?.errorMessage !== 'Request was aborted') {
      fail(`JSON abort turn_end errorMessage was "${abortedTurnEnd.message?.errorMessage}", expected "Request was aborted"`);
    }
    if (!Array.isArray(abortedTurnEnd.toolResults) || abortedTurnEnd.toolResults.length !== 0) {
      fail('JSON abort turn_end did not carry an empty toolResults array (upstream shape)');
    }
    console.log('[wave2-tui-smoke] JSON abort lifecycle: emitted aborted message_end/turn_end/agent_end with "Request was aborted"');

    // --- 3. Non-TTY interactive fallback -------------------------------------
    // No prompt + non-TTY stdin (spawnSync pipes stdin) -> the interactive loop reports not_a_tty,
    // prints the terminal-required notice on stderr, and falls back to help.
    const interactive = runCapture(['--no-session'], env);
    if (!/requires a terminal/.test(interactive.stderr)) {
      fail(
        'non-TTY interactive fallback did not print the terminal-required notice ' +
          `(stderr:\n${interactive.stderr}\nstdout:\n${interactive.stdout})`,
      );
    }
    if (!/pi-zig - Zig \+ Preact port/.test(interactive.stdout)) {
      fail(`non-TTY interactive fallback did not fall back to help (stdout:\n${interactive.stdout})`);
    }
    console.log('[wave2-tui-smoke] non-TTY interactive fallback: printed terminal notice and help');
  } finally {
    provider.stop();
  }

  console.log('[wave2-tui-smoke] PASS');
}

main().catch((err) => {
  console.error(err.message ?? String(err));
  process.exitCode = 1;
});

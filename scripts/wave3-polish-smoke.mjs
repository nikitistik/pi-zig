#!/usr/bin/env node
// Wave 3 polish smoke: closes the final parity sub-items for pi-zig.
//
// Pure Node.js stdlib (no npm deps). Drives the real `zig-out/bin/pi-zig`
// binary against fake servers / throwaway temp directories to confirm three
// behaviors end-to-end:
//
//   1. Azure OpenAI Responses reasoning-effort (Transports).
//      Drives `--mode rpc` set_model + prompt against a fake Azure /responses
//      endpoint and asserts the request body carries `reasoning.effort` for a
//      reasoning-capable model (o3-mini -> "none", mirroring upstream
//      azure-openai-responses.ts buildParams) and OMITS `reasoning` entirely for
//      a non-reasoning model (gpt-4o-mini). This is the same path the wave2
//      transports smoke exercises, so the non-reasoning case also guards that
//      smoke against regression.
//
//   2. Prompt/skill collision diagnostics (Skills/templates).
//      Runs the `commands` subcommand against a temp fixture with a deliberate
//      same-name collision (project vs user) and asserts the deduped command
//      list still has exactly one winner (project) AND a `collision` diagnostic
//      is emitted for the shadowed duplicate, matching upstream
//      resource-loader dedupePrompts / skills.ts shape.
//
//   3. Theme collision diagnostics (Skills/templates).
//      Runs the `themes` subcommand with two same-named custom themes and
//      asserts one winner plus a `collision` diagnostic, matching upstream
//      resource-loader dedupeThemes.
//
// Usage: node scripts/wave3-polish-smoke.mjs
// Prints "[wave3-polish-smoke] PASS" and exits 0 on success.

import { spawn, spawnSync, execFileSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert';

const TAG = '[wave3-polish-smoke]';
const repoRoot = process.cwd();
const bin = path.resolve('zig-out/bin/pi-zig');

function fail(message, extra) {
  console.error(`${TAG} FAIL: ${message}`);
  if (extra) console.error(extra);
  process.exit(1);
}

function info(message) {
  console.log(`${TAG} ${message}`);
}

// --- 0. Build the pi-zig binary. ---------------------------------------------
{
  const build = spawnSync('zig', ['build'], { encoding: 'utf8', cwd: repoRoot });
  if (build.status !== 0) {
    fail('zig build failed', `${build.stdout ?? ''}\n${build.stderr ?? ''}`);
  }
}
if (!fs.existsSync(bin)) {
  fail(`built binary not found at ${bin}`);
}

// Run a subcommand from `cwd` with an isolated HOME / PI_CODING_AGENT_DIR and
// return parsed JSON stdout.
function runJson(args, { cwd, home, agentDir }) {
  const env = { ...process.env };
  if (home !== undefined) env.HOME = home;
  if (agentDir !== undefined) env.PI_CODING_AGENT_DIR = agentDir;
  else delete env.PI_CODING_AGENT_DIR;
  const stdout = execFileSync(bin, args, { cwd, env, encoding: 'utf8' });
  try {
    return JSON.parse(stdout);
  } catch (error) {
    fail(`could not parse JSON from \`${args.join(' ')}\`: ${error.message}\n${stdout}`);
    return undefined;
  }
}

// Drive one RPC turn against a fake Azure /responses endpoint and return the
// request body the binary sent. set_model validates the model id against the
// catalog, so `modelId` must be a real azure-openai-responses model.
async function runAzureTurn(modelId, deploymentName) {
  let capturedBody = null;
  let sawResponses = false;

  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const url = new URL(req.url, 'http://127.0.0.1');
      const isResponses =
        req.method === 'POST' &&
        url.pathname.includes('/deployments/') &&
        url.pathname.endsWith('/responses');
      if (!isResponses) {
        res.writeHead(404, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'not found', method: req.method, url: req.url }));
        return;
      }
      sawResponses = true;
      try {
        capturedBody = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      } catch {
        capturedBody = null;
      }
      // Serve whichever shape the agent asked for (streaming SSE or JSON body).
      if (capturedBody && capturedBody.stream === true) {
        res.writeHead(200, { 'content-type': 'text/event-stream', connection: 'close' });
        res.write(`data: ${JSON.stringify({ type: 'response.output_text.delta', delta: 'ok' })}\n\n`);
        res.write('data: [DONE]\n\n');
        res.end();
      } else {
        res.writeHead(200, { 'content-type': 'application/json', connection: 'close' });
        res.end(
          JSON.stringify({
            id: 'resp-wave3',
            output: [
              { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'ok' }] }
            ]
          })
        );
      }
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  const baseUrl = `http://127.0.0.1:${port}/openai/v1`;

  const cleanAgentDir = path.resolve(`zig-out/pi-zig-wave3-azure-${modelId}`);
  fs.mkdirSync(cleanAgentDir, { recursive: true });
  const sessionFile = path.join(cleanAgentDir, 'session.jsonl');
  fs.rmSync(sessionFile, { force: true });

  const env = { ...process.env, PI_CODING_AGENT_DIR: cleanAgentDir };
  delete env.ANTHROPIC_API_KEY;
  delete env.ANTHROPIC_OAUTH_TOKEN;
  env.AZURE_OPENAI_API_KEY = 'azure-test-key';
  env.AZURE_OPENAI_BASE_URL = baseUrl;
  env.AZURE_OPENAI_DEPLOYMENT_NAME_MAP = `${modelId}=${deploymentName}`;
  env.AZURE_OPENAI_API_VERSION = '2025-04-01-preview';

  await new Promise((resolve, reject) => {
    const child = spawn(bin, ['--mode', 'rpc', '--session', sessionFile], { env });
    let stdout = '';
    let stderr = '';
    let pending = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGKILL');
      reject(new Error(`RPC run timed out\nstdout:\n${stdout}\nstderr:\n${stderr}`));
    }, 30000);

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      pending += chunk;
      while (pending.includes('\n')) {
        const newline = pending.indexOf('\n');
        const rawLine = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        if (rawLine.trim().length === 0) continue;
        let line;
        try {
          line = JSON.parse(rawLine);
        } catch {
          continue;
        }
        if (line.id === 'm' && line.type === 'response' && !line.success) {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          child.kill('SIGKILL');
          reject(new Error(`set_model failed: ${JSON.stringify(line)}`));
          return;
        }
        if (line.id === 'p' && line.type === 'response') {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          child.stdin.end();
          child.kill('SIGKILL');
          resolve();
          return;
        }
      }
    });
    child.once('error', (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });

    child.stdin.write(
      `${JSON.stringify({ id: 'm', type: 'set_model', provider: 'azure-openai-responses', modelId })}\n`
    );
    setTimeout(() => {
      child.stdin.write(`${JSON.stringify({ id: 'p', type: 'prompt', message: 'wave3 azure smoke' })}\n`);
    }, 400);
  }).catch((error) => {
    server.close();
    fail(`pi-zig RPC (azure ${modelId}) run failed`, error.message);
  });
  server.close();

  if (!sawResponses) fail(`fake Azure endpoint never received a /responses request for ${modelId}`);
  if (capturedBody === null) fail(`fake Azure endpoint captured no request body for ${modelId}`);
  return capturedBody;
}

// --- 1. Azure reasoning-effort emission. -------------------------------------
async function testAzureReasoningEffort() {
  // o3-mini is a reasoning-capable azure-openai-responses model with no
  // thinkingLevelMap.off override, so upstream buildParams emits
  // reasoning = { effort: "none" } on the default (no explicit reasoningEffort)
  // path. pi-zig must mirror that.
  const reasoningBody = await runAzureTurn('o3-mini', 'prod-o3');
  assert.strictEqual(reasoningBody.model, 'prod-o3', 'deployment name must be applied');
  assert.ok(
    reasoningBody.reasoning && typeof reasoningBody.reasoning === 'object',
    `reasoning model must carry a reasoning object, got ${JSON.stringify(reasoningBody.reasoning)}`
  );
  assert.strictEqual(
    reasoningBody.reasoning.effort,
    'none',
    `reasoning.effort must be "none", got ${JSON.stringify(reasoningBody.reasoning)}`
  );
  // The default path never sets `include` (only the explicit reasoningEffort/
  // reasoningSummary branch does upstream).
  assert.strictEqual(
    reasoningBody.include,
    undefined,
    'default reasoning path must not set include'
  );
  info('Azure reasoning-effort emitted for reasoning model (o3-mini -> effort "none") OK');

  // gpt-4o-mini is NOT a reasoning model: the request must omit `reasoning`
  // entirely (this is the exact model the wave2 transports smoke drives).
  const nonReasoningBody = await runAzureTurn('gpt-4o-mini', 'prod-deployment');
  assert.strictEqual(nonReasoningBody.model, 'prod-deployment', 'deployment name must be applied');
  assert.strictEqual(
    nonReasoningBody.reasoning,
    undefined,
    `non-reasoning model must omit reasoning, got ${JSON.stringify(nonReasoningBody.reasoning)}`
  );
  info('Azure reasoning-effort omitted for non-reasoning model (gpt-4o-mini) OK');
}

// --- 2. Prompt collision diagnostics via the `commands` subcommand. ----------
function testCommandCollisionDiagnostics(root) {
  const cwd = path.join(root, 'commands', 'proj');
  const home = path.join(root, 'commands', 'home');
  const agentDir = path.join(home, '.pi', 'agent');
  fs.mkdirSync(path.join(cwd, '.pi', 'prompts'), { recursive: true });
  fs.mkdirSync(path.join(agentDir, 'prompts'), { recursive: true });

  // Same prompt name "hello" in project and user scopes. Project (rank 0) wins
  // the dedup; the user copy is the shadowed loser that must produce a
  // collision diagnostic.
  fs.writeFileSync(
    path.join(cwd, '.pi', 'prompts', 'hello.md'),
    '---\ndescription: project hello\n---\nProject body\n'
  );
  fs.writeFileSync(
    path.join(agentDir, 'prompts', 'hello.md'),
    '---\ndescription: user hello\n---\nUser body\n'
  );

  const data = runJson(['commands'], { cwd, home, agentDir });

  // Winner unchanged: exactly one "hello" command, and it is the project copy.
  const hello = data.commands.filter((command) => command.name === 'hello');
  assert.strictEqual(hello.length, 1, 'collision must dedup to exactly one "hello" command');
  assert.strictEqual(hello[0].description, 'project hello', 'project copy must win the collision');

  // A `diagnostics` array is present and contains the collision for "hello".
  assert.ok(Array.isArray(data.diagnostics), 'commands output must carry a diagnostics array');
  const collisions = data.diagnostics.filter(
    (d) => d.type === 'collision' && d.collision && d.collision.name === 'hello'
  );
  assert.strictEqual(collisions.length, 1, `expected one collision diagnostic, got ${JSON.stringify(data.diagnostics)}`);
  const diag = collisions[0];
  assert.strictEqual(diag.message, 'name "/hello" collision', `unexpected message: ${diag.message}`);
  assert.strictEqual(diag.collision.resourceType, 'prompt', 'resourceType must be prompt');
  // winnerPath is the project copy (a cwd-relative `.pi/prompts/hello.md`);
  // loserPath is the user copy (an absolute path under the agent dir). The
  // diagnostic path equals the loser path (upstream `path: prompt.filePath`).
  assert.ok(
    diag.collision.winnerPath.includes(path.join('.pi', 'prompts', 'hello.md')),
    `winnerPath must be the project hello.md: ${diag.collision.winnerPath}`
  );
  assert.ok(
    !diag.collision.winnerPath.includes('agent'),
    `winnerPath must be the project (not user) copy: ${diag.collision.winnerPath}`
  );
  assert.ok(diag.collision.loserPath.includes('agent'), `loserPath must be the user copy: ${diag.collision.loserPath}`);
  assert.strictEqual(diag.path, diag.collision.loserPath, 'diagnostic path must equal the loser path');

  info('commands collision diagnostic emitted (prompt, winner unchanged) OK');
}

// --- 3. Theme collision diagnostics via the `themes` subcommand. -------------
function testThemeCollisionDiagnostics(root) {
  const REQUIRED_THEME_COLORS = [
    'accent', 'border', 'borderAccent', 'borderMuted', 'success', 'error', 'warning', 'muted',
    'dim', 'text', 'thinkingText', 'selectedBg', 'userMessageBg', 'userMessageText', 'customMessageBg',
    'customMessageText', 'customMessageLabel', 'toolPendingBg', 'toolSuccessBg', 'toolErrorBg', 'toolTitle',
    'toolOutput', 'mdHeading', 'mdLink', 'mdLinkUrl', 'mdCode', 'mdCodeBlock', 'mdCodeBlockBorder', 'mdQuote',
    'mdQuoteBorder', 'mdHr', 'mdListBullet', 'toolDiffAdded', 'toolDiffRemoved', 'toolDiffContext', 'syntaxComment',
    'syntaxKeyword', 'syntaxFunction', 'syntaxVariable', 'syntaxString', 'syntaxNumber', 'syntaxType', 'syntaxOperator',
    'syntaxPunctuation', 'thinkingOff', 'thinkingMinimal', 'thinkingLow', 'thinkingMedium', 'thinkingHigh', 'thinkingXhigh',
    'bashMode'
  ];
  const minimalThemeJson = (name) => {
    const colors = {};
    for (const key of REQUIRED_THEME_COLORS) colors[key] = '#000000';
    return JSON.stringify({ name, colors });
  };

  const cwd = path.join(root, 'themes', 'proj');
  const agentDir = path.join(root, 'themes', 'agent');
  const dirA = path.join(root, 'themes', 'a');
  const dirB = path.join(root, 'themes', 'b');
  for (const dir of [cwd, agentDir, dirA, dirB]) fs.mkdirSync(dir, { recursive: true });

  // Two custom themes that both declare the name "twin"; dirA is passed first so
  // it wins and dirB is the shadowed loser.
  fs.writeFileSync(path.join(dirA, 'twin.json'), minimalThemeJson('twin'));
  fs.writeFileSync(path.join(dirB, 'twin.json'), minimalThemeJson('twin'));

  const data = runJson(['themes', '--theme', dirA, '--theme', dirB], { cwd, home: agentDir, agentDir });

  // Winner unchanged: exactly one "twin" theme entry, sourced from dirA.
  const twins = data.themes.filter((theme) => theme.name === 'twin');
  assert.strictEqual(twins.length, 1, 'theme collision must dedup to exactly one "twin"');
  assert.ok(twins[0].path.includes(path.join('a', 'twin.json')), `winning twin must be from dirA: ${twins[0].path}`);

  assert.ok(Array.isArray(data.diagnostics), 'themes output must carry a diagnostics array');
  const collisions = data.diagnostics.filter(
    (d) => d.type === 'collision' && d.collision && d.collision.name === 'twin'
  );
  assert.strictEqual(collisions.length, 1, `expected one theme collision diagnostic, got ${JSON.stringify(data.diagnostics)}`);
  const diag = collisions[0];
  assert.strictEqual(diag.message, 'name "twin" collision', `unexpected message: ${diag.message}`);
  assert.strictEqual(diag.collision.resourceType, 'theme', 'resourceType must be theme');
  assert.ok(diag.collision.winnerPath.includes(path.join('a', 'twin.json')), `winnerPath must be dirA: ${diag.collision.winnerPath}`);
  assert.ok(diag.collision.loserPath.includes(path.join('b', 'twin.json')), `loserPath must be dirB: ${diag.collision.loserPath}`);

  info('themes collision diagnostic emitted (theme, winner unchanged) OK');
}

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'wave3-polish-'));
try {
  await testAzureReasoningEffort();
  testCommandCollisionDiagnostics(tmpRoot);
  testThemeCollisionDiagnostics(tmpRoot);
} finally {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
}

info('PASS');

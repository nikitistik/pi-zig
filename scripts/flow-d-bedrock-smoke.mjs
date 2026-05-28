#!/usr/bin/env node
// Flow D smoke: Amazon Bedrock AWS Signature Version 4 (SigV4) request signing.
//
// Drives the real pi-zig binary (via `--mode rpc`, set_model + prompt) against a
// fake Bedrock ConverseStream endpoint and proves that, when only IAM
// credentials are present in the environment (no AWS_BEARER_TOKEN_BEDROCK), the
// binary signs the request with SigV4 instead of sending a bearer token. It
// asserts the wire-level Authorization header shape (algorithm, credential
// scope, signed-headers list) without ever asserting on secret values.
//
// The RPC transport is used (rather than `-p` print mode) because it is the
// stable driver verify-basic.mjs uses for provider-backed turns.
//
// NO live AWS endpoint is exercised: the request is served by a local node:http
// server that returns a minimal valid binary event-stream so the agent turn
// completes.
//
// Usage: node scripts/flow-d-bedrock-smoke.mjs
// Prints "[flow-d-bedrock-smoke] PASS" and exits 0 on success; non-zero on
// failure.

import { spawn, spawnSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const TAG = '[flow-d-bedrock-smoke]';
const bin = path.resolve('zig-out/bin/pi-zig');
const region = 'us-west-2';
const model = 'amazon.nova-2-lite-v1:0';
const expectedText = 'flow-d sigv4 ok';

function fail(message, extra) {
  console.error(`${TAG} FAIL: ${message}`);
  if (extra) console.error(extra);
  process.exit(1);
}

// --- AWS event-stream framing (mirrors verify-basic.mjs bedrockEventFrame) ----
function eventStreamU32(value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32BE(value);
  return buffer;
}
function eventStreamHeaderString(name, value) {
  const nameBuffer = Buffer.from(name);
  const valueBuffer = Buffer.from(value);
  return Buffer.concat([
    Buffer.from([nameBuffer.length]),
    nameBuffer,
    Buffer.from([7]),
    Buffer.from([valueBuffer.length >> 8, valueBuffer.length & 0xff]),
    valueBuffer
  ]);
}
function bedrockEventFrame(eventType, payload) {
  const headers = Buffer.concat([
    eventStreamHeaderString(':message-type', 'event'),
    eventStreamHeaderString(':event-type', eventType),
    eventStreamHeaderString(':content-type', 'application/json')
  ]);
  const body = Buffer.from(JSON.stringify(payload));
  const total = 12 + headers.length + body.length + 4;
  return Buffer.concat([
    eventStreamU32(total),
    eventStreamU32(headers.length),
    eventStreamU32(0),
    headers,
    body,
    eventStreamU32(0)
  ]);
}

// 1. Build first.
{
  const build = spawnSync('zig', ['build'], { encoding: 'utf8' });
  if (build.status !== 0) {
    fail('zig build failed', `${build.stdout ?? ''}\n${build.stderr ?? ''}`);
  }
}
if (!fs.existsSync(bin)) {
  fail(`built binary not found at ${bin}`);
}

// Capture the request the binary makes so we can inspect the SigV4 headers.
let capturedHeaders = null;
let capturedPath = null;
let sawConverseStream = false;

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const requestUrl = new URL(req.url, 'http://127.0.0.1');
    const isConverseStream = req.method === 'POST' &&
      requestUrl.pathname.includes('/model/') &&
      requestUrl.pathname.endsWith('/converse-stream');
    if (!isConverseStream) {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'not found', method: req.method, url: req.url }));
      return;
    }
    sawConverseStream = true;
    capturedHeaders = { ...req.headers };
    capturedPath = requestUrl.pathname;

    // A real Bedrock endpoint requires a signed request. We do not validate the
    // signature cryptographically (no secret round-trip), but we require a
    // well-formed SigV4 Authorization header before serving a response.
    const authorization = req.headers.authorization ?? '';
    if (!authorization.startsWith('AWS4-HMAC-SHA256 ')) {
      res.writeHead(403, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'expected SigV4 authorization', headers: req.headers }));
      return;
    }

    res.writeHead(200, {
      'content-type': 'application/vnd.amazon.eventstream',
      connection: 'close'
    });
    const events = [
      ['messageStart', { messageStart: { role: 'assistant' } }],
      ['contentBlockDelta', { contentBlockDelta: { contentBlockIndex: 0, delta: { text: expectedText } } }],
      ['contentBlockStop', { contentBlockStop: { contentBlockIndex: 0 } }],
      ['messageStop', { messageStop: { stopReason: 'end_turn' } }]
    ];
    for (const [eventType, payload] of events) {
      res.write(bedrockEventFrame(eventType, payload));
    }
    res.end();
  });
});

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const { port } = server.address();
const baseUrl = `http://127.0.0.1:${port}`;

// Isolated agent dir + session so no on-disk auth credentials leak in.
const cleanAgentDir = path.resolve('zig-out/pi-zig-flow-d-bedrock-smoke');
fs.mkdirSync(cleanAgentDir, { recursive: true });
const sessionFile = path.join(cleanAgentDir, 'session.jsonl');
fs.rmSync(sessionFile, { force: true });

const env = { ...process.env, PI_CODING_AGENT_DIR: cleanAgentDir };
// Force the SigV4 path: IAM credentials present, NO bearer token / profile.
delete env.AWS_BEARER_TOKEN_BEDROCK;
delete env.AWS_PROFILE;
delete env.AWS_SESSION_TOKEN;
delete env.ANTHROPIC_API_KEY;
delete env.ANTHROPIC_OAUTH_TOKEN;
env.AWS_ACCESS_KEY_ID = 'AKIAIOSFODNN7EXAMPLE';
env.AWS_SECRET_ACCESS_KEY = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY';
env.AWS_REGION = region;
env.PI_ZIG_PROVIDER_BASE_URL = baseUrl;

// --- Drive the RPC transport (set_model then prompt) --------------------------
const promptResult = await new Promise((resolve, reject) => {
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
  child.stderr.on('data', (chunk) => { stderr += chunk; });
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
        resolve({ line, stdout, stderr });
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

  child.stdin.write(`${JSON.stringify({ id: 'm', type: 'set_model', provider: 'amazon-bedrock', modelId: model })}\n`);
  // Give set_model a beat to land before prompting (matches verify-basic timing).
  setTimeout(() => {
    child.stdin.write(`${JSON.stringify({ id: 'p', type: 'prompt', message: 'flow-d sigv4 smoke prompt' })}\n`);
  }, 400);
}).catch((error) => {
  server.close();
  fail('pi-zig RPC run failed', error.message);
});
server.close();

// --- Assertions ---------------------------------------------------------------
if (!sawConverseStream || !capturedHeaders) {
  fail('fake Bedrock endpoint never received a ConverseStream request');
}

const authorization = capturedHeaders.authorization ?? '';
if (!authorization.startsWith('AWS4-HMAC-SHA256 ')) {
  fail('Authorization header was not AWS SigV4', `authorization prefix: ${authorization.slice(0, 24)}`);
}

// Credential scope must target the bedrock service in the configured region.
const credentialMatch = authorization.match(/Credential=([^,]+)/);
if (!credentialMatch) {
  fail('Authorization header missing Credential component', authorization);
}
const credential = credentialMatch[1];
const credentialParts = credential.split('/');
// "<accessKeyId>/<date>/<region>/bedrock/aws4_request"
if (
  credentialParts.length !== 5 ||
  credentialParts[2] !== region ||
  credentialParts[3] !== 'bedrock' ||
  credentialParts[4] !== 'aws4_request' ||
  !/^\d{8}$/.test(credentialParts[1])
) {
  fail('Credential scope structure unexpected', `credential=${credential}`);
}

// SignedHeaders must list the deterministic subset we control, including host.
const signedHeadersMatch = authorization.match(/SignedHeaders=([^,]+)/);
if (!signedHeadersMatch) {
  fail('Authorization header missing SignedHeaders component', authorization);
}
const signedHeaders = signedHeadersMatch[1].split(';');
for (const required of ['content-type', 'host', 'x-amz-content-sha256', 'x-amz-date']) {
  if (!signedHeaders.includes(required)) {
    fail(`SignedHeaders missing ${required}`, `signedHeaders=${signedHeadersMatch[1]}`);
  }
}

// Signature must be present and 64 lowercase hex chars.
const signatureMatch = authorization.match(/Signature=([0-9a-f]+)$/);
if (!signatureMatch || signatureMatch[1].length !== 64) {
  fail('Signature was not 64 lowercase hex characters');
}

// The signed amz headers must accompany the request on the wire.
if (!capturedHeaders['x-amz-date'] || !/^\d{8}T\d{6}Z$/.test(capturedHeaders['x-amz-date'])) {
  fail('x-amz-date header missing or malformed', `x-amz-date=${capturedHeaders['x-amz-date']}`);
}
if (!capturedHeaders['x-amz-content-sha256'] || !/^[0-9a-f]{64}$/.test(capturedHeaders['x-amz-content-sha256'])) {
  fail('x-amz-content-sha256 header missing or malformed');
}
// No session token was configured, so the security-token header must be absent.
if (capturedHeaders['x-amz-security-token']) {
  fail('unexpected x-amz-security-token header without AWS_SESSION_TOKEN');
}

// The encoded model id must appear in the request path (proves routing).
if (!capturedPath || !capturedPath.includes('/model/') || !capturedPath.endsWith('/converse-stream')) {
  fail('request path did not target the ConverseStream model resource', `path=${capturedPath}`);
}

// The agent turn must have completed with the streamed assistant text.
if (!promptResult || !promptResult.line || promptResult.line.success !== true) {
  fail('RPC prompt did not succeed', JSON.stringify(promptResult?.line));
}
if (promptResult.line.data?.text !== expectedText) {
  fail('agent did not return the expected Bedrock assistant text', JSON.stringify(promptResult.line));
}

console.log(`${TAG} captured Authorization prefix: ${authorization.slice(0, 16)}`);
console.log(`${TAG} credential scope: ${credentialParts.slice(2).join('/')}`);
console.log(`${TAG} signed headers: ${signedHeadersMatch[1]}`);
console.log(`${TAG} streamed text: ${JSON.stringify(promptResult.line.data.text)}`);
console.log(`${TAG} PASS`);
process.exit(0);

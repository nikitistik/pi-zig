#!/usr/bin/env node
// Wave 2 transports smoke: OpenRouter image generation + Azure OpenAI Responses
// deployment routing + system-tool image resize.
//
// This exercises the provider-registry/transport work in src/pi/ai_client.zig
// END-TO-END over real HTTP, against fake node:http servers that assert the
// wire-level request shape and return canned responses. Nothing live is hit.
//
// Because image generation and resize are library functions (not CLI/RPC
// commands), this script compiles a tiny standalone Zig harness that imports the
// `pi-zig` module and calls ai_client.runImageGeneration / resizeImageWithSystemTool
// directly. The Azure deployment-routing path IS wired into the RPC transport
// (provider "azure-openai-responses"), so it is driven through the real pi-zig
// binary via `--mode rpc` (set_model + prompt), exactly like the other flow
// smokes.
//
// Coverage:
//   1. OpenRouter images: assert the request body (model, user message with
//      text + image_url parts, stream:false, modalities) and that a data-URL
//      image response round-trips into a parsed image content part.
//   2. Azure Responses: assert the request hits
//      /openai/v1/deployments/<deployment>/responses?api-version=<version> with
//      the deployment-name map applied, then complete the SSE turn.
//   3. Resize: re-encode a PNG via a system tool (sips/magick/convert). Skips
//      cleanly (documented divergence) when no such tool exists.
//
// Usage: node scripts/wave2-transports-smoke.mjs
// Prints "[wave2-transports-smoke] PASS" and exits 0 on success.

import { spawn, spawnSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert';

const TAG = '[wave2-transports-smoke]';
const repoRoot = process.cwd();
const bin = path.resolve('zig-out/bin/pi-zig');
// A minimal valid 1x1 PNG (matches the unit-test fixture in ai_client.zig).
const tinyPngBase64 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
// A second tiny PNG the fake OpenRouter server returns as a generated image.
const generatedPngBase64 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

function fail(message, extra) {
  console.error(`${TAG} FAIL: ${message}`);
  if (extra) console.error(extra);
  process.exit(1);
}

function info(message) {
  console.log(`${TAG} ${message}`);
}

// --- 0. Build the pi-zig binary (the Azure path drives it via RPC). ----------
{
  const build = spawnSync('zig', ['build'], { encoding: 'utf8', cwd: repoRoot });
  if (build.status !== 0) {
    fail('zig build failed', `${build.stdout ?? ''}\n${build.stderr ?? ''}`);
  }
}
if (!fs.existsSync(bin)) {
  fail(`built binary not found at ${bin}`);
}

// --- 1. Compile the standalone harness that calls ai_client directly. --------
const harnessDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wave2-harness-'));
const harnessSrc = path.join(harnessDir, 'wave2_harness.zig');
const harnessBin = path.join(harnessDir, 'wave2_harness');
fs.writeFileSync(harnessSrc, harnessZig());
{
  const compile = spawnSync(
    'zig',
    [
      'build-exe',
      '--dep',
      'pi-zig',
      `-Mroot=${harnessSrc}`,
      // Relative to repoRoot (cwd) so the module resolves against the source tree.
      '-Mpi-zig=src/pi/index.zig',
      `-femit-bin=${harnessBin}`
    ],
    { encoding: 'utf8', cwd: repoRoot }
  );
  if (compile.status !== 0) {
    fail('failed to compile wave2 harness', `${compile.stdout ?? ''}\n${compile.stderr ?? ''}`);
  }
}

// MUST be async (spawn, not spawnSync): the fake HTTP servers run in this same
// Node process, so a synchronous spawn would block the event loop and deadlock
// the server's request handler against the harness's outbound request.
function runHarness(mode, env, timeoutMs = 30000) {
  return new Promise((resolve) => {
    const child = spawn(harnessBin, [mode], {
      cwd: repoRoot,
      env: { ...process.env, ...env }
    });
    let stdout = '';
    let stderr = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGKILL');
      fail(`harness '${mode}' timed out`, `stdout:\n${stdout}\nstderr:\n${stderr}`);
    }, timeoutMs);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.once('error', (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fail(`harness '${mode}' failed to run`, error.message);
    });
    child.once('close', (status) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const lastLine = stdout.trim().split('\n').filter(Boolean).pop() ?? '';
      let parsed;
      try {
        parsed = JSON.parse(lastLine);
      } catch {
        fail(`harness '${mode}' did not emit JSON`, `stdout:\n${stdout}\nstderr:\n${stderr}`);
      }
      resolve({ parsed, status, stderr });
    });
  });
}

// --- 2. OpenRouter image-generation round-trip. ------------------------------
async function testImageGeneration() {
  let capturedBody = null;
  let capturedPath = null;
  let capturedAuth = null;
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      capturedPath = req.url;
      capturedAuth = req.headers.authorization ?? null;
      try {
        capturedBody = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      } catch {
        capturedBody = null;
      }
      if (req.method !== 'POST' || !req.url.endsWith('/chat/completions')) {
        res.writeHead(404, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'not found', method: req.method, url: req.url }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json', connection: 'close' });
      res.end(
        JSON.stringify({
          id: 'gen-wave2-001',
          choices: [
            {
              message: {
                role: 'assistant',
                content: 'here is your generated image',
                images: [
                  { image_url: { url: `data:image/png;base64,${generatedPngBase64}` } },
                  // A non-data URL that must be skipped by the parser.
                  { image_url: 'https://example.com/should-be-ignored.png' }
                ]
              }
            }
          ]
        })
      );
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  const baseUrl = `http://127.0.0.1:${port}/api/v1`;

  const { parsed, status, stderr } = await runHarness('image-gen', {
    PI_ZIG_IMAGES_BASE_URL: baseUrl,
    WAVE2_PROVIDER: 'openrouter',
    WAVE2_MODEL: 'google/gemini-2.5-flash-image',
    WAVE2_API_KEY: 'or-test-key',
    WAVE2_PROMPT: 'draw a red square',
    WAVE2_IMAGE_DATA: tinyPngBase64,
    WAVE2_IMAGE_MIME: 'image/png',
    WAVE2_INCLUDE_TEXT: '1'
  });
  server.close();

  if (status !== 0 || !parsed.ok) {
    fail('image-generation harness reported failure', `${JSON.stringify(parsed)}\nstderr:\n${stderr}`);
  }

  // --- Request shape assertions (the load-bearing part). ---
  if (capturedBody === null) fail('fake OpenRouter server captured no request body');
  assert.strictEqual(capturedPath, '/api/v1/chat/completions', 'unexpected request path');
  assert.strictEqual(capturedAuth, 'Bearer or-test-key', 'unexpected Authorization header');
  assert.strictEqual(capturedBody.model, 'google/gemini-2.5-flash-image', 'wrong model in request');
  assert.strictEqual(capturedBody.stream, false, 'expected stream:false');
  assert.deepStrictEqual(
    capturedBody.modalities,
    ['image', 'text'],
    'expected modalities [image,text] when include_text is set'
  );
  assert.strictEqual(Array.isArray(capturedBody.messages), true, 'messages must be an array');
  assert.strictEqual(capturedBody.messages.length, 1, 'expected one user message');
  const userMessage = capturedBody.messages[0];
  assert.strictEqual(userMessage.role, 'user', 'message role must be user');
  assert.strictEqual(Array.isArray(userMessage.content), true, 'user content must be an array of parts');
  const textPart = userMessage.content.find((p) => p.type === 'text');
  const imagePart = userMessage.content.find((p) => p.type === 'image_url');
  assert.ok(textPart && textPart.text === 'draw a red square', 'missing text content part');
  assert.ok(
    imagePart && imagePart.image_url && imagePart.image_url.url === `data:image/png;base64,${tinyPngBase64}`,
    'missing/malformed image_url content part'
  );

  // --- Response parse assertions. ---
  assert.strictEqual(parsed.responseId, 'gen-wave2-001', 'response id not parsed');
  const parts = parsed.parts;
  assert.strictEqual(Array.isArray(parts), true, 'parsed parts must be an array');
  const parsedText = parts.find((p) => p.type === 'text');
  const parsedImage = parts.find((p) => p.type === 'image');
  assert.ok(parsedText && parsedText.text === 'here is your generated image', 'text part not parsed');
  assert.ok(parsedImage && parsedImage.mimeType === 'image/png', 'image part not parsed');
  assert.strictEqual(parsedImage.data, generatedPngBase64, 'image base64 payload mismatch');
  // The https:// url must NOT produce a content part.
  assert.strictEqual(parts.filter((p) => p.type === 'image').length, 1, 'non-data-url image should be skipped');

  info('image-generation round-trip OK (request shape + data-url parse verified)');
}

// --- 3. Azure OpenAI Responses deployment routing (via RPC binary). ----------
async function testAzureDeploymentRouting() {
  let capturedPath = null;
  let capturedApiKeyHeader = null;
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
      capturedPath = req.url;
      capturedApiKeyHeader = req.headers['api-key'] ?? null;
      try {
        capturedBody = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      } catch {
        capturedBody = null;
      }
      // Respond in whichever shape the request asked for. The agent runtime may
      // drive either the streaming (stream:true -> SSE) or non-streaming
      // (stream:false -> JSON Responses body) Azure path; both are served by the
      // same ai_client deployment-routing code, so the smoke supports both.
      if (capturedBody && capturedBody.stream === true) {
        res.writeHead(200, { 'content-type': 'text/event-stream', connection: 'close' });
        const events = [
          { type: 'response.output_text.delta', delta: 'azure ' },
          { type: 'response.output_text.delta', delta: 'wave2 ok' }
        ];
        for (const event of events) {
          res.write(`data: ${JSON.stringify(event)}\n\n`);
        }
        res.write('data: [DONE]\n\n');
        res.end();
      } else {
        res.writeHead(200, { 'content-type': 'application/json', connection: 'close' });
        res.end(
          JSON.stringify({
            id: 'resp-wave2-azure',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [{ type: 'output_text', text: 'azure wave2 ok' }]
              }
            ]
          })
        );
      }
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  const baseUrl = `http://127.0.0.1:${port}/openai/v1`;

  const cleanAgentDir = path.resolve('zig-out/pi-zig-wave2-azure-smoke');
  fs.mkdirSync(cleanAgentDir, { recursive: true });
  const sessionFile = path.join(cleanAgentDir, 'session.jsonl');
  fs.rmSync(sessionFile, { force: true });

  const env = { ...process.env, PI_CODING_AGENT_DIR: cleanAgentDir };
  delete env.ANTHROPIC_API_KEY;
  delete env.ANTHROPIC_OAUTH_TOKEN;
  env.AZURE_OPENAI_API_KEY = 'azure-test-key';
  env.AZURE_OPENAI_BASE_URL = baseUrl;
  // Map a real catalog model id to a custom Azure deployment name. set_model
  // validates the model id against the catalog, so we use gpt-4o-mini (a real
  // azure-openai-responses model) and assert it is rewritten to the deployment.
  env.AZURE_OPENAI_DEPLOYMENT_NAME_MAP = 'gpt-4o-mini=prod-deployment';
  env.AZURE_OPENAI_API_VERSION = '2025-04-01-preview';

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

    child.stdin.write(
      `${JSON.stringify({ id: 'm', type: 'set_model', provider: 'azure-openai-responses', modelId: 'gpt-4o-mini' })}\n`
    );
    setTimeout(() => {
      child.stdin.write(`${JSON.stringify({ id: 'p', type: 'prompt', message: 'wave2 azure smoke prompt' })}\n`);
    }, 400);
  }).catch((error) => {
    server.close();
    fail('pi-zig RPC (azure) run failed', error.message);
  });
  server.close();

  if (!sawResponses) fail('fake Azure endpoint never received a /responses request');

  // --- The load-bearing assertions: deployment name + api-version in the URL. ---
  assert.strictEqual(
    capturedPath,
    '/openai/v1/deployments/prod-deployment/responses?api-version=2025-04-01-preview',
    `unexpected Azure request path: ${capturedPath}`
  );
  assert.strictEqual(capturedApiKeyHeader, 'azure-test-key', 'expected api-key header on Azure request');
  if (capturedBody === null) fail('fake Azure endpoint captured no request body');
  // The wire model must be the resolved deployment name, not the catalog model id.
  assert.strictEqual(capturedBody.model, 'prod-deployment', 'Azure request model must be the deployment name');
  assert.strictEqual(Array.isArray(capturedBody.input), true, 'Azure Responses request must carry an input array');
  // The agent picks streaming vs non-streaming; both are valid Azure Responses
  // requests. Assert the field is present and boolean rather than fixing a mode.
  assert.strictEqual(typeof capturedBody.stream, 'boolean', 'Azure Responses request must carry a stream flag');

  info('Azure deployment routing OK (deployment-name URL + api-version query verified)');
}

// --- 4. System-tool image resize (skips cleanly when no tool is present). ----
async function testResize() {
  const { parsed, status, stderr } = await runHarness('resize', {
    WAVE2_IMAGE_DATA: tinyPngBase64,
    WAVE2_IMAGE_MIME: 'image/png',
    WAVE2_MAX_DIM: '64'
  });
  if (parsed.skip) {
    info(`resize skipped: ${parsed.reason} (no sips/magick/convert available — documented divergence)`);
    return;
  }
  if (status !== 0 || !parsed.ok) {
    fail('resize harness reported failure', `${JSON.stringify(parsed)}\nstderr:\n${stderr}`);
  }
  assert.ok(['sips', 'magick', 'convert'].includes(parsed.tool), `unexpected resize tool: ${parsed.tool}`);
  assert.strictEqual(parsed.mimeType, 'image/png', 'resize must preserve mime type');
  assert.ok(parsed.dataLen > 0, 'resized image base64 must be non-empty');
  // The output must be valid base64 (re-decodable).
  const decoded = Buffer.from(parsed.data, 'base64');
  assert.ok(decoded.length > 0, 'resized image must decode to non-empty bytes');
  info(`resize round-trip OK via '${parsed.tool}' (re-encoded ${parsed.dataLen} base64 bytes)`);
}

try {
  await testImageGeneration();
  await testAzureDeploymentRouting();
  await testResize();
} finally {
  fs.rmSync(harnessDir, { recursive: true, force: true });
}

console.log(`${TAG} PASS`);
process.exit(0);

// =============================================================================
// Standalone Zig harness source. Imports the pi-zig module and calls the
// ai_client image-generation + resize entry points directly, so the smoke can
// exercise them over real HTTP / real subprocesses without a CLI surface.
// Defined as a hoisted function so it is reachable from the top of the file.
// =============================================================================
function harnessZig() {
  return String.raw`
const std = @import("std");
const pi = @import("pi-zig");
const ai_client = pi.ai_client;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const env = init.environ_map;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return emitError(io, "missing mode argument");
    const mode = args[1];

    if (std.mem.eql(u8, mode, "image-gen")) {
        return runImageGen(io, gpa, env);
    }
    if (std.mem.eql(u8, mode, "resize")) {
        return runResize(io, gpa, env);
    }
    return emitError(io, "unknown mode");
}

fn envOr(env: *std.process.Environ.Map, key: []const u8, fallback: []const u8) []const u8 {
    return env.get(key) orelse fallback;
}

fn runImageGen(io: std.Io, gpa: std.mem.Allocator, env: *std.process.Environ.Map) !void {
    const provider = envOr(env, "WAVE2_PROVIDER", "openrouter");
    const model = envOr(env, "WAVE2_MODEL", "google/gemini-2.5-flash-image");
    const api_key = envOr(env, "WAVE2_API_KEY", "test-key");
    const prompt = envOr(env, "WAVE2_PROMPT", "draw something");
    const include_text = std.mem.eql(u8, envOr(env, "WAVE2_INCLUDE_TEXT", "0"), "1");

    var input: std.ArrayList(ai_client.ChatContentPart) = .empty;
    defer input.deinit(gpa);
    try input.append(gpa, .{ .text = prompt });
    if (env.get("WAVE2_IMAGE_DATA")) |data| {
        try input.append(gpa, .{ .image = .{
            .mime_type = envOr(env, "WAVE2_IMAGE_MIME", "image/png"),
            .data = data,
        } });
    }

    var result = ai_client.runImageGeneration(io, gpa, env, .{
        .provider = provider,
        .model = model,
        .api_key = api_key,
        .input = input.items,
        .include_text = include_text,
    }) catch |err| {
        return emitError(io, @errorName(err));
    };
    defer result.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"ok\":true,\"responseId\":");
    if (result.response_id) |id| {
        try std.json.Stringify.encodeJsonString(id, .{}, w);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"parts\":[");
    for (result.output, 0..) |part, index| {
        if (index != 0) try w.writeByte(',');
        switch (part) {
            .text => |text| {
                try w.writeAll("{\"type\":\"text\",\"text\":");
                try std.json.Stringify.encodeJsonString(text, .{}, w);
                try w.writeByte('}');
            },
            .image => |image| {
                try w.writeAll("{\"type\":\"image\",\"mimeType\":");
                try std.json.Stringify.encodeJsonString(image.mime_type, .{}, w);
                try w.writeAll(",\"data\":");
                try std.json.Stringify.encodeJsonString(image.data, .{}, w);
                try w.writeByte('}');
            },
        }
    }
    try w.writeAll("]}");
    try writeLine(io, out.written());
}

fn runResize(io: std.Io, gpa: std.mem.Allocator, env: *std.process.Environ.Map) !void {
    const data = env.get("WAVE2_IMAGE_DATA") orelse return emitError(io, "missing WAVE2_IMAGE_DATA");
    const mime = envOr(env, "WAVE2_IMAGE_MIME", "image/png");
    const max_dim_str = envOr(env, "WAVE2_MAX_DIM", "512");
    const max_dim = std.fmt.parseInt(u32, max_dim_str, 10) catch 512;

    var resized = ai_client.resizeImageWithSystemTool(io, gpa, env, .{
        .mime_type = mime,
        .data = data,
    }, max_dim) catch |err| {
        if (err == error.ResizeToolUnavailable) {
            try writeLine(io, "{\"ok\":false,\"skip\":true,\"reason\":\"resize-tool-unavailable\"}");
            return;
        }
        return emitError(io, @errorName(err));
    };
    defer resized.deinit(gpa);

    const tool_name = switch (resized.tool) {
        .sips => "sips",
        .magick => "magick",
        .convert => "convert",
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"ok\":true,\"tool\":\"");
    try w.writeAll(tool_name);
    try w.writeAll("\",\"mimeType\":");
    try std.json.Stringify.encodeJsonString(resized.image.mime_type, .{}, w);
    try w.print(",\"dataLen\":{d},\"data\":", .{resized.image.data.len});
    try std.json.Stringify.encodeJsonString(resized.image.data, .{}, w);
    try w.writeByte('}');
    try writeLine(io, out.written());
}

fn emitError(io: std.Io, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll("{\"ok\":false,\"error\":");
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    try w.writeAll("}\n");
    try w.flush();
}

fn writeLine(io: std.Io, line: []const u8) !void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll(line);
    try w.writeByte('\n');
    try w.flush();
}
`;
}

#!/usr/bin/env node
/**
 * Wave 2 long-tail parity smoke (pure Node stdlib).
 *
 * Drives the REAL pi-zig binary to verify the wave-2 closures that are
 * CLI-observable, and stands up a fake OAuth2 token endpoint (node:http) to
 * exercise the service_account ADC JWT-bearer mint end to end. No live cloud
 * endpoint is contacted and no real credential is used: the RSA key is generated
 * in-process with node:crypto and the token exchange is redirected to the local
 * fake server via PI_ZIG_OAUTH_TOKEN_URL.
 *
 * Coverage:
 *   1. Model resolver edge cases (`resolve-model` / `list-models`):
 *      - provider/model slash inference
 *      - fuzzy pattern + `:thinking` suffix
 *      - colon-in-id models are matched verbatim, NOT stripped as a thinking
 *        level (the OpenRouter ":exacto" behavior, here via a real ":0" id)
 *      - colon-in-id + a trailing valid thinking level still parses the level
 *      - provider-scoped custom-model fallback with the interpolated upstream
 *        warning
 *      - unknown provider error text
 *   2. HTML export markdown + syntax highlight via `--export`:
 *      - inline markdown (bold/italic/inline-code/links) rendered as real tags
 *      - dangerous link schemes neutralized (no javascript: href)
 *      - fenced code blocks tokenized into class spans, content HTML-escaped
 *      - `<title>pi-zig session</title>` preserved; no external script/CDN
 *   3. service_account ADC mint against a fake token endpoint:
 *      - the real binary signs an RS256 JWT assertion with a generated SA key,
 *        POSTs the RFC 7523 jwt-bearer grant, and returns the minted token
 *      - the fake server VERIFIES the JWT signature with node:crypto against the
 *        SA public key and checks the claim set (iss/aud/scope/exp)
 *   4. NFKC fuzzy folding is NOT directly CLI-observable (the fuzzy matcher backs
 *      the interactive TUI palette and the edit-tool fuzzy fallback, neither of
 *      which is a one-shot CLI command); it is covered by unit tests in
 *      src/pi/tui_fuzzy.zig and src/pi/tools.zig. This is asserted as a documented
 *      note, not a runtime check.
 *
 * Run standalone: node scripts/wave2-misc-smoke.mjs
 * Requires the binary: build first with `zig build`.
 */

import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { generateKeyPairSync, createVerify } from 'node:crypto';
import { existsSync, mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import { tmpdir } from 'node:os';

const TAG = '[wave2-misc-smoke]';
const here = fileURLToPath(new URL('.', import.meta.url));
const repoRoot = resolve(here, '..');
const bin = process.env.PI_ZIG_BIN ?? resolve(repoRoot, 'zig-out/bin/pi-zig');

const MINTED_TOKEN = 'ya29.wave2-service-account-token';

function fail(message) {
  console.error(`${TAG} FAIL: ${message}`);
  process.exitCode = 1;
  throw new Error(message);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

/** Run the binary synchronously and return { stdout, stderr, status }. */
function runSync(args, extraEnv = {}) {
  const result = spawnSync(bin, args, {
    cwd: repoRoot,
    env: { ...process.env, ...extraEnv },
    encoding: 'utf8',
  });
  if (result.error) fail(`spawn failed for ${args.join(' ')}: ${result.error.message}`);
  return { stdout: result.stdout ?? '', stderr: result.stderr ?? '', status: result.status };
}

function parseJson(label, text) {
  try {
    return JSON.parse(text.trim());
  } catch (err) {
    fail(`${label}: output is not JSON: ${JSON.stringify(text)} (${err.message})`);
    return null;
  }
}

// ---------------------------------------------------------------------------
// 1. Model resolver edge cases
// ---------------------------------------------------------------------------
function testModelResolver() {
  // provider/model slash inference (no --provider).
  {
    const r = parseJson('resolve slash', runSync(['resolve-model', 'anthropic/claude-haiku-4-5']).stdout);
    assert(r.error === null, `slash inference should not error: ${r.error}`);
    assert(r.model && r.model.provider === 'anthropic', 'slash inference should pick the anthropic provider');
    assert(r.model.id === 'claude-haiku-4-5', `slash inference id wrong: ${r.model && r.model.id}`);
  }

  // fuzzy pattern + :thinking suffix within an explicit provider.
  {
    const r = parseJson('resolve fuzzy', runSync(['resolve-model', '--provider', 'anthropic', 'haiku:high']).stdout);
    assert(r.error === null, `fuzzy resolve should not error: ${r.error}`);
    assert(r.model && /haiku/i.test(r.model.id), `fuzzy resolve should match a haiku model: ${r.model && r.model.id}`);
    assert(r.thinkingLevel === 'high', `fuzzy resolve should parse the high thinking level: ${r.thinkingLevel}`);
  }

  // A colon-in-id model is matched verbatim in strict CLI mode (the ":0" suffix
  // must NOT be stripped as a thinking level). This is the OpenRouter ":exacto"
  // behavior, exercised against a real Bedrock ":0" model id.
  let colonModelId = null;
  {
    const models = parseJson('models', runSync(['models']).stdout);
    const withColon = models.models.find(
      (m) => m.provider === 'amazon-bedrock' && /:\d+$/.test(m.id) && m.id.includes('nova'),
    );
    assert(withColon, 'expected at least one amazon-bedrock model with a ":N" id in the catalog');
    colonModelId = withColon.id;

    const r = parseJson('resolve colon id', runSync(['resolve-model', '--provider', 'amazon-bedrock', colonModelId]).stdout);
    assert(r.error === null, `colon-id resolve should not error: ${r.error}`);
    assert(r.model && r.model.id === colonModelId, `colon-id must match verbatim: got ${r.model && r.model.id}, want ${colonModelId}`);
    assert(r.thinkingLevel === null, `colon-id must not have its ":N" stripped as a thinking level: ${r.thinkingLevel}`);
    assert(r.customModel === false, 'colon-id should resolve to a real model, not a custom fallback');
  }

  // colon-in-id + a trailing VALID thinking level still parses the level off.
  {
    const r = parseJson(
      'resolve colon id + thinking',
      runSync(['resolve-model', '--provider', 'amazon-bedrock', `${colonModelId}:high`]).stdout,
    );
    assert(r.model && r.model.id === colonModelId, `colon-id+thinking model wrong: ${r.model && r.model.id}`);
    assert(r.thinkingLevel === 'high', `colon-id+thinking should parse high: ${r.thinkingLevel}`);
  }

  // provider-scoped custom-model fallback with the interpolated upstream warning.
  {
    const r = parseJson(
      'resolve custom fallback',
      runSync(['resolve-model', '--provider', 'anthropic', 'totally-made-up-model-xyz']).stdout,
    );
    assert(r.customModel === true, 'custom fallback should set customModel:true');
    assert(r.model && r.model.id === 'totally-made-up-model-xyz', `custom fallback should echo the id: ${r.model && r.model.id}`);
    assert(
      r.warning === 'Model "totally-made-up-model-xyz" not found for provider "anthropic". Using custom model id.',
      `custom fallback warning not interpolated like upstream: ${JSON.stringify(r.warning)}`,
    );
  }

  // unknown provider error text matches upstream.
  {
    const r = parseJson('resolve unknown provider', runSync(['resolve-model', '--provider', 'definitely-not-a-provider', 'x']).stdout);
    assert(r.model === null, 'unknown provider should not resolve a model');
    assert(
      typeof r.error === 'string' && r.error.startsWith('Unknown provider definitely-not-a-provider.'),
      `unknown provider error text wrong: ${JSON.stringify(r.error)}`,
    );
  }

  // list-models substring search still narrows the catalog.
  {
    const r = parseJson('list-models haiku', runSync(['list-models', 'haiku']).stdout);
    assert(typeof r.count === 'number' && r.count > 0, 'list-models haiku should return at least one model');
    assert(r.models.every((m) => /haiku/i.test(`${m.provider}/${m.id}/${m.name}`)), 'list-models results must all match the pattern');
  }

  console.log(`${TAG} model resolver edge cases OK`);
}

// ---------------------------------------------------------------------------
// 2. HTML export markdown + syntax highlight
// ---------------------------------------------------------------------------
function testHtmlExport(sandbox) {
  const sessionFile = join(sandbox, 'wave2-session.jsonl');
  const outFile = join(sandbox, 'wave2-out.html');

  const assistantText = [
    'Use **bold**, *italic*, `inline()` and a [docs link](https://example.com/x).',
    'Danger: [evil](javascript:alert(1)).',
    '```js',
    'const s = "hi <there>"; // greet, 1 < 2',
    '```',
    'Done.',
  ].join('\n');

  const lines = [
    { type: 'session', version: 3, id: 'wave2-smoke', timestamp: '2026-05-28T08:00:00.000Z', cwd: repoRoot },
    {
      type: 'message',
      id: 'a1',
      parentId: null,
      timestamp: '2026-05-28T09:00:00.000Z',
      message: { role: 'assistant', content: [{ type: 'text', text: assistantText }] },
    },
  ];
  writeFileSync(sessionFile, lines.map((e) => JSON.stringify(e)).join('\n') + '\n');

  const run = runSync(['--export', sessionFile, outFile]);
  assert(run.status === 0, `--export exited non-zero (${run.status}); stderr: ${run.stderr}`);
  assert(existsSync(outFile), `--export did not write ${outFile}`);
  const html = readFileSync(outFile, 'utf8');

  // Title contract preserved.
  assert(html.includes('<title>pi-zig session</title>'), 'title does not contain "pi-zig session"');

  // Inline markdown rendered as real tags.
  assert(html.includes('<strong>bold</strong>'), 'bold markdown not rendered');
  assert(html.includes('<em>italic</em>'), 'italic markdown not rendered');
  assert(html.includes('<code class="inline-code">inline()</code>'), 'inline code not rendered');
  assert(
    html.includes('<a href="https://example.com/x" rel="nofollow noopener">docs link</a>'),
    'markdown link not rendered as a safe anchor',
  );

  // Dangerous scheme neutralized.
  assert(!html.includes('href="javascript:'), 'javascript: link scheme leaked into an href');

  // Fenced code block tokenized: keyword/string/comment class spans, content escaped.
  assert(html.includes('<pre class="code-block"><code'), 'fenced code block not rendered as <pre><code>');
  assert(html.includes('lang-js'), 'code block language class hook (lang-js) missing');
  assert(html.includes('<span class="tok-kw">const</span>'), 'keyword token span missing');
  assert(html.includes('<span class="tok-str">'), 'string token span missing');
  assert(html.includes('<span class="tok-cmt">'), 'comment token span missing');
  // The operator run stays bare and HTML-escaped (no raw "<").
  assert(html.includes('1 &lt; 2'), 'code operator text was not contiguous/escaped');
  assert(!html.includes('hi <there>'), 'code string content leaked a raw "<"');
  // Token color CSS is inlined (self-contained, no external theme).
  assert(html.includes('.tok-kw{'), 'token CSS classes missing from the stylesheet');

  // Fully self-contained: no external script/style references.
  assert(!html.includes('<script src='), 'export references an external script src');
  assert(!/src\s*=\s*"https?:/i.test(html), 'export references an external http(s) resource');

  console.log(`${TAG} HTML export markdown + syntax highlight OK`);
}

// ---------------------------------------------------------------------------
// 3. service_account ADC mint against a fake token endpoint
// ---------------------------------------------------------------------------
function startFakeTokenServer(publicKeyPem, expectedClientEmail) {
  let lastRequest = null;
  let requestCount = 0;
  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      requestCount += 1;
      const body = Buffer.concat(chunks).toString('utf8');
      const params = new URLSearchParams(body);
      const grantType = params.get('grant_type');
      const assertion = params.get('assertion');
      let jwtValid = false;
      let claims = null;
      try {
        const [headerB64, claimsB64, sigB64] = (assertion ?? '').split('.');
        if (headerB64 && claimsB64 && sigB64) {
          const signingInput = `${headerB64}.${claimsB64}`;
          const signature = Buffer.from(sigB64, 'base64url');
          const verifier = createVerify('RSA-SHA256');
          verifier.update(signingInput);
          jwtValid = verifier.verify(publicKeyPem, signature);
          claims = JSON.parse(Buffer.from(claimsB64, 'base64url').toString('utf8'));
        }
      } catch {
        jwtValid = false;
      }
      lastRequest = { method: req.method, grantType, assertion, jwtValid, claims, body, expectedClientEmail };

      const payload = Buffer.from(
        JSON.stringify({ access_token: MINTED_TOKEN, expires_in: 3600, token_type: 'Bearer' }),
        'utf8',
      );
      res.writeHead(200, {
        'content-type': 'application/json',
        'content-length': String(payload.length),
        connection: 'close',
      });
      res.end(payload);
    });
  });
  return new Promise((resolveServer) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolveServer({
        server,
        tokenUrl: `http://127.0.0.1:${port}/token`,
        getLastRequest: () => lastRequest,
        getRequestCount: () => requestCount,
      });
    });
  });
}

function runResolveAsync(provider, extraEnv, { timeoutMs = 15000 } = {}) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(bin, ['auth', 'resolve', provider, '--json'], {
      cwd: repoRoot,
      env: { ...process.env, ...extraEnv },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (c) => (stdout += c));
    child.stderr.on('data', (c) => (stderr += c));
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      rejectRun(new Error(`auth resolve ${provider} timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    child.on('error', (err) => {
      clearTimeout(timer);
      rejectRun(err);
    });
    child.on('exit', (status) => {
      clearTimeout(timer);
      resolveRun({ stdout, stderr, status });
    });
  });
}

async function testServiceAccountMint(sandbox) {
  // Generate a throwaway RSA keypair (no real credential involved).
  const { privateKey, publicKey } = generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });

  const clientEmail = 'wave2-smoke@pi-zig.iam.gserviceaccount.com';
  const gcloudDir = join(sandbox, 'gcloud-sa');
  mkdirSync(gcloudDir, { recursive: true });
  const adcPath = join(gcloudDir, 'service_account_adc.json');
  writeFileSync(
    adcPath,
    JSON.stringify({
      type: 'service_account',
      client_email: clientEmail,
      private_key: privateKey,
      token_uri: 'https://oauth2.googleapis.com/token',
      project_id: 'pi-zig-smoke',
    }),
  );

  const fake = await startFakeTokenServer(publicKey, clientEmail);
  try {
    const baseEnv = {
      HOME: join(sandbox, 'home-sa'),
      PI_CODING_AGENT_DIR: join(sandbox, 'agent-sa'),
      GOOGLE_APPLICATION_CREDENTIALS: adcPath,
      GOOGLE_CLOUD_ACCESS_TOKEN: undefined,
      GOOGLE_CLOUD_PROJECT: undefined,
      GCLOUD_PROJECT: undefined,
      GOOGLE_CLOUD_LOCATION: undefined,
      CLOUDSDK_CONFIG: undefined,
      PI_ZIG_OAUTH_TOKEN_URL: fake.tokenUrl,
    };
    mkdirSync(baseEnv.HOME, { recursive: true });
    mkdirSync(baseEnv.PI_CODING_AGENT_DIR, { recursive: true });

    const minted = await runResolveAsync('google-vertex', baseEnv);
    assert(minted.status === 0, `service_account mint exited non-zero (${minted.status}); stderr: ${minted.stderr}`);
    const mintedJson = parseJson('service_account mint', minted.stdout);
    assert(mintedJson.resolved === true, `service_account mint did not resolve: ${minted.stdout}`);
    assert(mintedJson.value === MINTED_TOKEN, `service_account mint returned wrong token: ${JSON.stringify(mintedJson.value)}`);

    const req = fake.getLastRequest();
    assert(req, 'fake token endpoint was never contacted during service_account mint');
    assert(req.method === 'POST', `token exchange used ${req.method}, expected POST`);
    assert(
      req.grantType === 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      `service_account grant_type wrong: ${req.grantType}`,
    );
    // The fake server verified the RS256 signature with the SA public key.
    assert(req.jwtValid === true, 'service_account JWT signature did not verify against the public key');
    assert(req.claims && req.claims.iss === clientEmail, `JWT iss claim wrong: ${req.claims && req.claims.iss}`);
    assert(
      req.claims.aud === 'https://oauth2.googleapis.com/token',
      `JWT aud claim wrong: ${req.claims && req.claims.aud}`,
    );
    assert(
      req.claims.scope === 'https://www.googleapis.com/auth/cloud-platform',
      `JWT scope claim wrong: ${req.claims && req.claims.scope}`,
    );
    assert(
      Number.isInteger(req.claims.iat) && Number.isInteger(req.claims.exp) && req.claims.exp > req.claims.iat,
      'JWT iat/exp claims are missing or non-monotonic',
    );
    console.log(`${TAG} service_account ADC mint OK (RS256 JWT signature verified by fake server)`);

    // Absent-credentials safety: no ADC + no env -> resolve:false, exit 0, no token request.
    const countBefore = fake.getRequestCount();
    const absent = await runResolveAsync('google-vertex', {
      HOME: join(sandbox, 'empty-home'),
      PI_CODING_AGENT_DIR: join(sandbox, 'empty-agent'),
      GOOGLE_APPLICATION_CREDENTIALS: undefined,
      GOOGLE_CLOUD_ACCESS_TOKEN: undefined,
      GOOGLE_CLOUD_PROJECT: undefined,
      GCLOUD_PROJECT: undefined,
      GOOGLE_CLOUD_LOCATION: undefined,
      CLOUDSDK_CONFIG: undefined,
      PI_ZIG_OAUTH_TOKEN_URL: fake.tokenUrl,
    });
    mkdirSync(join(sandbox, 'empty-home'), { recursive: true });
    mkdirSync(join(sandbox, 'empty-agent'), { recursive: true });
    assert(absent.status === 0, `absent-credentials case exited non-zero (${absent.status}); must skip cleanly`);
    const absentJson = parseJson('absent service_account', absent.stdout);
    assert(absentJson.resolved === false && absentJson.value === null, `absent case should resolve false/null: ${absent.stdout}`);
    assert(fake.getRequestCount() === countBefore, 'absent-credentials case unexpectedly contacted the token endpoint');
    console.log(`${TAG} absent-credentials case OK (resolved:false, exit 0, no token request)`);
  } finally {
    fake.server.close();
  }
}

// ---------------------------------------------------------------------------
async function main() {
  if (!existsSync(bin)) {
    console.log(`${TAG} SKIP: binary not found: ${bin} (run "zig build")`);
    return;
  }

  const sandbox = mkdtempSync(join(tmpdir(), 'pi-zig-wave2-'));
  try {
    testModelResolver();
    testHtmlExport(sandbox);
    await testServiceAccountMint(sandbox);

    // NFKC fuzzy folding: documented as unit-tested (not CLI-observable).
    console.log(
      `${TAG} NFKC fuzzy folding: covered by unit tests (src/pi/tui_fuzzy.zig, src/pi/tools.zig); not a one-shot CLI surface, skipped at runtime by design`,
    );

    console.log(`${TAG} PASS`);
  } finally {
    try {
      rmSync(sandbox, { recursive: true, force: true });
    } catch {
      /* ignore cleanup failures */
    }
  }
}

main().catch((err) => {
  console.error(`${TAG} ${err.message}`);
  process.exitCode = 1;
});

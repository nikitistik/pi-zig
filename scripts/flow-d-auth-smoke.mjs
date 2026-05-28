#!/usr/bin/env node
/**
 * Flow D auth smoke: Google Vertex Application Default Credentials (ADC).
 *
 * Proves that `pi-zig auth resolve google-vertex --json` performs the ADC
 * authorized_user refresh_token exchange and returns the minted ya29.* bearer,
 * driving the REAL Zig binary against a fake OAuth2 token endpoint.
 *
 * The token exchange is redirected to a local node:http server via
 * PI_ZIG_OAUTH_TOKEN_URL (the same override auth.zig reuses from its existing
 * OAuth refresh path), so NO live Google endpoint is contacted and no real
 * secrets are involved. The ADC file is a throwaway authorized_user document
 * written to a temp dir.
 *
 * Asserts:
 *   1. Mint path: with a temp ADC file + fake token server, the resolved value
 *      is exactly the minted "ya29.fake-vertex-token", and the fake server
 *      received the documented grant_type=refresh_token form-encoded request.
 *   2. Absent path: with no ADC file / no Google env, the command reports
 *      resolved:false and exits 0 (skips cleanly, never crashes). This satisfies
 *      the task rule that live/credential paths never fail CI when creds absent.
 *   3. Service-account divergence: an ADC service_account key is NOT faked — the
 *      command reports it unsupported and resolves to false without crashing.
 *
 * Run standalone: node scripts/flow-d-auth-smoke.mjs
 * Requires the binary: build first with `zig build`.
 */

import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import { tmpdir } from 'node:os';

const here = fileURLToPath(new URL('.', import.meta.url));
const repoRoot = resolve(here, '..');
const bin = process.env.PI_ZIG_BIN ?? resolve(repoRoot, 'zig-out/bin/pi-zig');

const MINTED_TOKEN = 'ya29.fake-vertex-token';

function fail(message) {
  console.error(`[flow-d-auth-smoke] FAIL: ${message}`);
  process.exitCode = 1;
  throw new Error(message);
}

// Fake Google OAuth2 token endpoint. CRITICAL: it must send an explicit
// content-length (and we add connection:close for good measure) so the Zig
// std.http client — which requests `accept-encoding: identity` — knows the
// response body is complete. Omitting content-length makes the client block.
function startFakeTokenServer() {
  let lastRequest = null;
  let requestCount = 0;
  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      requestCount += 1;
      lastRequest = {
        method: req.method,
        url: req.url,
        contentType: req.headers['content-type'] ?? null,
        accept: req.headers.accept ?? null,
        body: Buffer.concat(chunks).toString('utf8'),
      };
      const buf = Buffer.from(
        JSON.stringify({
          access_token: MINTED_TOKEN,
          expires_in: 3600,
          scope: 'https://www.googleapis.com/auth/cloud-platform',
          token_type: 'Bearer',
        }),
        'utf8',
      );
      res.writeHead(200, {
        'content-type': 'application/json',
        'content-length': String(buf.length),
        connection: 'close',
      });
      res.end(buf);
    });
  });
  return new Promise((resolveServer) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolveServer({
        server,
        port,
        tokenUrl: `http://127.0.0.1:${port}/token`,
        getLastRequest: () => lastRequest,
        getRequestCount: () => requestCount,
      });
    });
  });
}

// Run `pi-zig auth resolve <provider> --json` and return { stdout, stderr, code }.
// A hard timeout guards against the client blocking on a misbehaving endpoint.
function runResolve(provider, extraEnv, { timeoutMs = 15000 } = {}) {
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
    child.stdout.on('data', (c) => {
      stdout += c;
    });
    child.stderr.on('data', (c) => {
      stderr += c;
    });
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      rejectRun(new Error(`auth resolve ${provider} timed out after ${timeoutMs}ms (token exchange blocked?)`));
    }, timeoutMs);
    child.on('error', (err) => {
      clearTimeout(timer);
      rejectRun(err);
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      resolveRun({ stdout, stderr, code });
    });
  });
}

function parseResolveJson(stdout) {
  const trimmed = stdout.trim();
  try {
    return JSON.parse(trimmed);
  } catch (err) {
    fail(`could not parse resolve output as JSON: ${JSON.stringify(trimmed)} (${err.message})`);
    return null;
  }
}

async function main() {
  if (!existsSync(bin)) {
    console.log(`[flow-d-auth-smoke] SKIP: binary not found: ${bin} (run "zig build")`);
    return;
  }

  // Isolated sandbox: temp HOME + agent dir so we never touch the developer's
  // real ~/.pi/agent/auth.json or ~/.config/gcloud credentials.
  const sandbox = mkdtempSync(join(tmpdir(), 'pi-zig-flow-d-'));
  const sandboxHome = join(sandbox, 'home');
  const agentDir = join(sandbox, 'agent');
  const gcloudDir = join(sandbox, 'gcloud');
  mkdirSync(sandboxHome, { recursive: true });
  mkdirSync(agentDir, { recursive: true });
  mkdirSync(gcloudDir, { recursive: true });

  // Base env shared by every case: empty agent dir + a HOME with NO gcloud ADC,
  // and explicitly cleared Google ambient vars so each case controls its own auth.
  const baseEnv = {
    HOME: sandboxHome,
    PI_CODING_AGENT_DIR: agentDir,
    GOOGLE_APPLICATION_CREDENTIALS: undefined,
    GOOGLE_CLOUD_ACCESS_TOKEN: undefined,
    GOOGLE_CLOUD_PROJECT: undefined,
    GCLOUD_PROJECT: undefined,
    GOOGLE_CLOUD_LOCATION: undefined,
    GOOGLE_CLOUD_API_KEY: undefined,
    CLOUDSDK_CONFIG: undefined,
    PI_ZIG_OAUTH_TOKEN_URL: undefined,
  };

  const fake = await startFakeTokenServer();
  try {
    // --- Case 1: mint a Vertex access token from an authorized_user ADC file ---
    const adcPath = join(gcloudDir, 'application_default_credentials.json');
    writeFileSync(
      adcPath,
      JSON.stringify({
        client_id: '764086051850-flowdsmoke.apps.googleusercontent.com',
        client_secret: 'flow-d-smoke-secret',
        refresh_token: '1//flow-d-smoke-refresh',
        type: 'authorized_user',
      }),
    );

    const minted = await runResolve('google-vertex', {
      ...baseEnv,
      GOOGLE_APPLICATION_CREDENTIALS: adcPath,
      PI_ZIG_OAUTH_TOKEN_URL: fake.tokenUrl,
    });
    if (minted.code !== 0) fail(`mint case exited non-zero (${minted.code}); stderr: ${minted.stderr}`);
    const mintedJson = parseResolveJson(minted.stdout);
    if (mintedJson.resolved !== true) fail(`mint case did not resolve: ${minted.stdout}`);
    if (mintedJson.value !== MINTED_TOKEN) {
      fail(`mint case returned wrong token (expected minted ya29.* bearer): ${JSON.stringify(mintedJson.value)}`);
    }
    // Verify the fake token endpoint received the documented refresh_token grant.
    const req = fake.getLastRequest();
    if (!req) fail('fake token endpoint was never contacted during mint case');
    if (req.method !== 'POST') fail(`token exchange used ${req.method}, expected POST`);
    if ((req.contentType ?? '').indexOf('application/x-www-form-urlencoded') === -1) {
      fail(`token exchange content-type was ${req.contentType}, expected form-urlencoded`);
    }
    for (const field of ['grant_type=refresh_token', 'client_id=', 'client_secret=', 'refresh_token=']) {
      if (req.body.indexOf(field) === -1) fail(`token exchange body missing "${field}": ${req.body}`);
    }
    // The refresh_token from the ADC file must be the one forwarded to the endpoint.
    if (req.body.indexOf('refresh_token=1//flow-d-smoke-refresh') === -1) {
      fail('token exchange did not forward the ADC refresh_token');
    }
    console.log('[flow-d-auth-smoke] mint case OK (ADC refresh_token -> ya29.* bearer; request shape verified)');

    // --- Case 2: absent credentials must skip cleanly (exit 0, resolved:false) ---
    // No ADC file, no Google env, fake server still up but should NOT be hit.
    const countBeforeAbsent = fake.getRequestCount();
    const absent = await runResolve('google-vertex', {
      ...baseEnv,
      // Point the override at the fake server too, to prove that absent an ADC
      // file we never even attempt an exchange.
      PI_ZIG_OAUTH_TOKEN_URL: fake.tokenUrl,
    });
    if (absent.code !== 0) {
      fail(`absent-credentials case exited non-zero (${absent.code}); must skip cleanly. stderr: ${absent.stderr}`);
    }
    const absentJson = parseResolveJson(absent.stdout);
    if (absentJson.resolved !== false || absentJson.value !== null) {
      fail(`absent-credentials case should resolve to false/null: ${absent.stdout}`);
    }
    if (fake.getRequestCount() !== countBeforeAbsent) {
      fail('absent-credentials case unexpectedly contacted the token endpoint');
    }
    console.log('[flow-d-auth-smoke] absent-credentials case OK (resolved:false, exit 0, no token request)');

    // --- Case 3: service_account ADC is reported unsupported, never faked ----
    const svcPath = join(gcloudDir, 'service_account_adc.json');
    writeFileSync(
      svcPath,
      JSON.stringify({
        type: 'service_account',
        client_email: 'svc@flow-d-smoke.iam.gserviceaccount.com',
        private_key: '-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n',
        token_uri: 'https://oauth2.googleapis.com/token',
      }),
    );
    const countBeforeSvc = fake.getRequestCount();
    const svc = await runResolve('google-vertex', {
      ...baseEnv,
      GOOGLE_APPLICATION_CREDENTIALS: svcPath,
      PI_ZIG_OAUTH_TOKEN_URL: fake.tokenUrl,
    });
    if (svc.code !== 0) fail(`service_account case exited non-zero (${svc.code}); stderr: ${svc.stderr}`);
    const svcJson = parseResolveJson(svc.stdout);
    if (svcJson.resolved !== false || svcJson.value !== null) {
      fail(`service_account case must not fake a token (expected false/null): ${svc.stdout}`);
    }
    if (fake.getRequestCount() !== countBeforeSvc) {
      fail('service_account case unexpectedly contacted the token endpoint');
    }
    if (svcJson.value === MINTED_TOKEN) fail('service_account case must never return a minted token');
    console.log('[flow-d-auth-smoke] service_account case OK (reported unsupported, not faked)');

    console.log('[flow-d-auth-smoke] PASS');
  } finally {
    fake.server.close();
    try {
      rmSync(sandbox, { recursive: true, force: true });
    } catch {
      /* ignore cleanup failures */
    }
  }
}

main().catch((err) => {
  console.error(`[flow-d-auth-smoke] ${err.message}`);
  process.exitCode = 1;
});

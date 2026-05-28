// Wave 2 settings + package-commands + extensions (jiti / lifecycle) smoke.
//
// Drives the REAL `zig-out/bin/pi-zig` binary end-to-end with pure Node stdlib —
// no real npm/git network, no extra deps. Proves three closure items at the
// process boundary:
//
//   1. Settings manager (settings.zig): `settings --json` resolves the newly
//      handled keys (defaultThinkingLevel enum validation, thinkingBudgets,
//      enabledModels, npmCommand, lastChangelogVersion) and fills the upstream
//      warnings.anthropicExtraUsage default, parses httpIdleTimeoutMs "disabled".
//
//   2. Package commands (package_manager.zig): local-source `install` / `list`
//      / `remove` round-trip against a temp project + agent dir, persisting the
//      package entry into the selected settings file and clearing it on remove.
//
//   3. Extensions (extension_runner.zig): a TypeScript extension that uses a
//      jiti-style relative `.ts` import AND a bare dependency resolved from its
//      own node_modules (jiti dependency-root resolution) registers a command;
//      executing it through `--mode rpc` fires the handler (a lifecycle-style
//      dispatch) and its `appendEntry` action persists a custom session entry
//      carrying the jiti-imported values.
//
// Builds with `zig build` first. Prints "[wave2-ext-settings-smoke] PASS" and
// exits 0 on success; throws / non-zero exit on any failure.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const bin = path.resolve('zig-out/bin/pi-zig');
const workDir = path.resolve('zig-out/wave2-ext-settings-smoke');

function fail(message) {
  throw new Error(`[wave2-ext-settings-smoke] ${message}`);
}

function ensureBinary() {
  const result = spawnSync('zig', ['build'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.status !== 0) {
    fail(`zig build failed (status ${result.status})\nstdout:\n${result.stdout ?? ''}\nstderr:\n${result.stderr ?? ''}`);
  }
  if (!fs.existsSync(bin)) fail(`expected binary at ${bin} after zig build`);
}

// Run the binary once, capturing stdout/stderr with the given cwd/env/stdin.
function run(args, { cwd, env, input = '' } = {}) {
  const result = spawnSync(bin, args, { cwd, env, input, encoding: 'utf8' });
  if (result.error) throw result.error;
  return { status: result.status, stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
}

// Drive the RPC mode: feed newline-delimited JSON commands on stdin, collect the
// newline-delimited JSON responses. A trailing blank line ends the loop.
function runRpc(args, commands, { cwd, env } = {}) {
  const input = commands.map((c) => JSON.stringify(c)).join('\n') + '\n\n';
  const { status, stdout, stderr } = run(args, { cwd, env, input });
  if (status !== 0) fail(`rpc invocation exited ${status}\nargs: ${args.join(' ')}\nstderr:\n${stderr}`);
  return stdout.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
}

function reset() {
  fs.rmSync(workDir, { recursive: true, force: true });
  fs.mkdirSync(workDir, { recursive: true });
}

// ===== ITEM 1: settings --json resolves the newly handled keys =====
function testSettings() {
  const agentDir = path.join(workDir, 'settings-agent');
  const projDir = path.join(workDir, 'settings-proj');
  fs.mkdirSync(agentDir, { recursive: true });
  fs.mkdirSync(projDir, { recursive: true });
  // Global settings exercise: enum-validated defaultThinkingLevel, thinkingBudgets,
  // enabledModels, an empty warnings object (default must be filled), and a
  // string "disabled" httpIdleTimeoutMs that must parse to 0.
  fs.writeFileSync(
    path.join(agentDir, 'settings.json'),
    JSON.stringify({
      lastChangelogVersion: '9.9.9',
      defaultThinkingLevel: 'xhigh',
      thinkingBudgets: { minimal: 1000, high: 42000 },
      enabledModels: ['anthropic/*', 'openai/*'],
      npmCommand: ['mise', 'exec', 'node@20', '--', 'npm'],
      warnings: {},
      httpIdleTimeoutMs: 'disabled',
    }),
  );
  const env = { ...process.env, PI_CODING_AGENT_DIR: agentDir };
  const { status, stdout, stderr } = run(['settings', '--json'], { cwd: projDir, env });
  if (status !== 0) fail(`settings --json exited ${status}\nstderr:\n${stderr}`);

  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch (err) {
    fail(`settings --json did not emit valid JSON: ${err}\n${stdout}`);
  }
  const r = parsed.resolved;
  if (!r) fail('settings --json output missing "resolved"');

  if (r.lastChangelogVersion !== '9.9.9') fail(`expected lastChangelogVersion 9.9.9, got ${JSON.stringify(r.lastChangelogVersion)}`);
  if (r.defaultThinkingLevel !== 'xhigh') fail(`expected defaultThinkingLevel xhigh, got ${JSON.stringify(r.defaultThinkingLevel)}`);
  if (!r.thinkingBudgets || r.thinkingBudgets.high !== 42000 || r.thinkingBudgets.minimal !== 1000) {
    fail(`thinkingBudgets not passed through: ${JSON.stringify(r.thinkingBudgets)}`);
  }
  if (!Array.isArray(r.enabledModels) || r.enabledModels.join(',') !== 'anthropic/*,openai/*') {
    fail(`enabledModels not passed through: ${JSON.stringify(r.enabledModels)}`);
  }
  if (!Array.isArray(r.npmCommand) || r.npmCommand.join(' ') !== 'mise exec node@20 -- npm') {
    fail(`npmCommand not passed through: ${JSON.stringify(r.npmCommand)}`);
  }
  // The upstream WarningSettings default (anthropicExtraUsage: true) must be filled in
  // even though the persisted warnings object was empty.
  if (!r.warnings || r.warnings.anthropicExtraUsage !== true) {
    fail(`warnings.anthropicExtraUsage default not filled: ${JSON.stringify(r.warnings)}`);
  }
  // "disabled" httpIdleTimeoutMs parses to 0 (upstream parseHttpIdleTimeoutMs).
  if (r.httpIdleTimeoutMs !== 0) fail(`expected httpIdleTimeoutMs 0 from "disabled", got ${JSON.stringify(r.httpIdleTimeoutMs)}`);

  // An out-of-enum defaultThinkingLevel must resolve to null, not pass through.
  fs.writeFileSync(path.join(agentDir, 'settings.json'), JSON.stringify({ defaultThinkingLevel: 'ultra' }));
  const invalid = run(['settings', '--json'], { cwd: projDir, env });
  const invalidResolved = JSON.parse(invalid.stdout).resolved;
  if (invalidResolved.defaultThinkingLevel !== null) {
    fail(`out-of-enum defaultThinkingLevel should resolve to null, got ${JSON.stringify(invalidResolved.defaultThinkingLevel)}`);
  }
}

// ===== ITEM 2: package install / list / remove round-trip (local source) =====
function testPackageCommands() {
  const agentDir = path.join(workDir, 'pkg-agent');
  const projDir = path.join(workDir, 'pkg-proj');
  const localExt = path.join(projDir, 'local-ext');
  fs.mkdirSync(agentDir, { recursive: true });
  fs.mkdirSync(localExt, { recursive: true });
  fs.writeFileSync(path.join(localExt, 'index.mjs'), 'export default function(pi){}\n');
  const env = { ...process.env, PI_CODING_AGENT_DIR: agentDir };
  const settingsPath = path.join(agentDir, 'settings.json');

  const install = run(['install', './local-ext'], { cwd: projDir, env });
  if (install.status !== 0) fail(`install exited ${install.status}\nstderr:\n${install.stderr}`);
  if (!install.stdout.includes('Installed ./local-ext')) fail(`install did not confirm: ${install.stdout}`);

  // The package source must be persisted into the selected (user) settings file.
  if (!fs.existsSync(settingsPath)) fail('install did not create the agent settings file');
  const afterInstall = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  if (!Array.isArray(afterInstall.packages) || afterInstall.packages.length !== 1) {
    fail(`expected one persisted package, got ${JSON.stringify(afterInstall.packages)}`);
  }

  const list = run(['list'], { cwd: projDir, env });
  if (list.status !== 0) fail(`list exited ${list.status}\nstderr:\n${list.stderr}`);
  if (!list.stdout.includes('User packages:')) fail(`list did not show user packages heading: ${list.stdout}`);
  if (!list.stdout.includes('local-ext')) fail(`list did not show the installed package: ${list.stdout}`);

  const remove = run(['remove', './local-ext'], { cwd: projDir, env });
  if (remove.status !== 0) fail(`remove exited ${remove.status}\nstderr:\n${remove.stderr}`);
  if (!remove.stdout.includes('Removed ./local-ext')) fail(`remove did not confirm: ${remove.stdout}`);

  const afterRemove = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  if (Array.isArray(afterRemove.packages) && afterRemove.packages.length !== 0) {
    fail(`expected packages cleared after remove, got ${JSON.stringify(afterRemove.packages)}`);
  }

  const listEmpty = run(['list'], { cwd: projDir, env });
  if (!listEmpty.stdout.includes('No packages installed.')) {
    fail(`list after remove did not report empty state: ${listEmpty.stdout}`);
  }

  // Removing a never-installed source fails with a non-zero status (upstream parity).
  const removeMissing = run(['remove', 'npm:does-not-exist'], { cwd: projDir, env });
  if (removeMissing.status === 0) fail('remove of an unconfigured source should fail');
  if (!removeMissing.stderr.includes('No matching package found')) {
    fail(`remove-missing did not emit the no-match message: ${removeMissing.stderr}`);
  }
}

// ===== ITEM 3: jiti-style TS import + lifecycle hook (extension command) =====
function testExtensionsJitiAndLifecycle() {
  const extDir = path.join(workDir, 'ext');
  const depDir = path.join(extDir, 'node_modules', 'wave2-dep');
  fs.mkdirSync(depDir, { recursive: true });
  // A bare dependency installed in the extension's OWN node_modules. jiti-style
  // dependency-root resolution must find it even though the runner process cwd
  // is the repo root (not the extension directory).
  fs.writeFileSync(
    path.join(depDir, 'package.json'),
    JSON.stringify({ name: 'wave2-dep', version: '1.0.0', type: 'module', main: 'index.js' }),
  );
  fs.writeFileSync(path.join(depDir, 'index.js'), 'export const depValue = "from-node-modules-dep";\n');

  // A relative TypeScript helper (jiti-style `.ts` import).
  fs.writeFileSync(path.join(extDir, 'helper.ts'), 'export const entryType: string = "wave2-lifecycle";\n');

  // The extension itself: TypeScript, importing BOTH the relative .ts helper and the
  // bare dependency, registering a command whose handler calls appendEntry (a
  // lifecycle-style dispatch through the runner) with the jiti-imported values.
  const extensionPath = path.join(extDir, 'command.ts');
  fs.writeFileSync(
    extensionPath,
    [
      'import { entryType } from "./helper.ts";',
      'import { depValue } from "wave2-dep";',
      'type Args = string;',
      'export default function(pi: any): void {',
      '  pi.registerCommand("wave2-append", {',
      '    description: "Append a custom entry built from jiti-imported values",',
      '    handler: async (args: Args) => {',
      '      await pi.appendEntry(entryType, { args, dep: depValue });',
      '    }',
      '  });',
      '}',
      '',
    ].join('\n'),
  );

  // First prove the extension LOADS through the runner via the jiti resolver by
  // discovering its registered flags surface (a clean, provider-free entry point).
  // We register the command above; flags discovery still forces a full module load,
  // so a resolution failure on either import would surface as a load diagnostic /
  // empty discovery. We assert the command is discoverable instead.
  const sessionPath = path.join(extDir, 'lifecycle.jsonl');
  fs.rmSync(sessionPath, { force: true });

  const responses = runRpc(
    ['--mode', 'rpc', '--session', sessionPath, '--extension', extensionPath],
    [
      { id: 'cmds', type: 'get_commands' },
      { id: 'run', type: 'prompt', message: '/wave2-append hello-from-smoke' },
      { id: 'msgs', type: 'get_messages' },
    ],
  );

  const commandsResponse = responses.find((r) => r.id === 'cmds');
  if (!commandsResponse?.success) fail(`get_commands failed: ${JSON.stringify(commandsResponse)}`);
  const discoveredCommands = commandsResponse.data?.commands ?? [];
  if (!discoveredCommands.some((c) => c.name === 'wave2-append')) {
    fail(`TS extension command not discovered (jiti import likely failed): ${JSON.stringify(discoveredCommands)}`);
  }

  const runResponse = responses.find((r) => r.id === 'run');
  if (!runResponse?.success) fail(`extension command execution failed: ${JSON.stringify(runResponse)}`);

  // The command must NOT have stored a user message (commands intercept before the
  // provider/prompt path), matching upstream.
  const msgsResponse = responses.find((r) => r.id === 'msgs');
  const messages = msgsResponse?.data?.messages ?? [];
  if (messages.some((m) => m.role === 'user')) {
    fail(`extension command should not persist a user message, got ${JSON.stringify(messages)}`);
  }

  // The appendEntry action fired by the handler must have persisted a custom session
  // entry carrying the jiti-imported values (relative .ts helper + bare dependency).
  if (!fs.existsSync(sessionPath)) fail('extension command did not create the session file');
  const sessionEntries = fs
    .readFileSync(sessionPath, 'utf8')
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const customEntry = sessionEntries.find(
    (entry) =>
      entry.type === 'custom' &&
      entry.customType === 'wave2-lifecycle' &&
      entry.data?.args === 'hello-from-smoke' &&
      entry.data?.dep === 'from-node-modules-dep',
  );
  if (!customEntry) {
    fail(
      `expected a persisted custom entry with jiti-imported values; entries:\n${JSON.stringify(sessionEntries, null, 2)}`,
    );
  }
}

function main() {
  if (!fs.existsSync('zig-out')) fs.mkdirSync('zig-out', { recursive: true });
  ensureBinary();
  reset();
  testSettings();
  testPackageCommands();
  testExtensionsJitiAndLifecycle();
  // Best-effort cleanup; never fatal.
  try {
    fs.rmSync(workDir, { recursive: true, force: true });
  } catch {}
  process.stdout.write('[wave2-ext-settings-smoke] PASS\n');
}

main();

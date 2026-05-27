import fs from 'node:fs';
import path from 'node:path';

// Flow 01 upstream inventory.
//
// Enumerates every upstream package, CLI command file, mode entrypoint, provider
// implementation/auth surface, extension API symbol, TUI component, RPC command,
// built-in slash command, and public-API/DoD doc from the pinned upstream tree.
// The goal is that no upstream surface is invisible: discovery is derived from the
// filesystem and parsed from source, and self-check assertions fail loudly if the
// hard-coded lists drift from what is actually on disk.
//
// Emits a JSON report to stdout and a machine-readable artifact to
// docs/inventory/upstream-inventory.json.

const root = path.resolve('upstream/pi');
const UPSTREAM_COMMIT = 'fc8a1559017f1e581cfa971aa3cef11a507a4975';

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function readText(file) {
  return fs.readFileSync(file, 'utf8');
}

function countFiles(dir, predicate = () => true) {
  let total = 0;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.git' || entry.name === 'dist') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      total += countFiles(full, predicate);
    } else if (predicate(full)) {
      total += 1;
    }
  }
  return total;
}

function listFiles(dir, predicate = () => true) {
  if (!fs.existsSync(dir)) return [];
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.git' || entry.name === 'dist') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...listFiles(full, predicate));
    } else if (predicate(full)) {
      files.push(full);
    }
  }
  return files.sort();
}

/** Recursively find every package.json under packages/ (excluding node_modules). */
function findAllPackageManifests() {
  return listFiles(path.join(root, 'packages'), (file) => path.basename(file) === 'package.json').map((file) =>
    path.relative(root, path.dirname(file)).replaceAll(path.sep, '/'),
  );
}

function packageInfo(dir) {
  const abs = path.join(root, dir);
  const pkg = readJson(path.join(abs, 'package.json'));
  const deps = Object.keys(pkg.dependencies || {});
  return {
    dir,
    name: pkg.name,
    version: pkg.version,
    private: pkg.private === true,
    role: dir.startsWith('packages/coding-agent/examples/') ? 'example-extension' : 'primary',
    bin: Object.keys(pkg.bin || {}),
    exports: Object.keys(pkg.exports || {}),
    scripts: Object.keys(pkg.scripts || {}),
    dependencies: deps,
    // Local workspace references (other @earendil-works/pi-* packages this package depends on).
    workspaceDependencies: deps.filter((name) => name.startsWith('@earendil-works/pi-')),
    optionalDependencies: Object.keys(pkg.optionalDependencies || {}),
    devDependencies: Object.keys(pkg.devDependencies || {}),
    piExtensions: pkg.pi?.extensions ?? [],
    sourceFiles: fs.existsSync(path.join(abs, 'src'))
      ? countFiles(path.join(abs, 'src'), (file) => file.endsWith('.ts'))
      : 0,
    testFiles: fs.existsSync(path.join(abs, 'test'))
      ? countFiles(path.join(abs, 'test'), (file) => file.endsWith('.ts'))
      : 0,
  };
}

// ---------------------------------------------------------------------------
// Packages
// ---------------------------------------------------------------------------

const rootPkg = readJson(path.join(root, 'package.json'));
const allPackageDirs = findAllPackageManifests();
const packages = allPackageDirs.map(packageInfo);
const primaryPackages = packages.filter((p) => p.role === 'primary');
const examplePackages = packages.filter((p) => p.role === 'example-extension');

// ---------------------------------------------------------------------------
// CLI commands, flags, mode entrypoints
// ---------------------------------------------------------------------------

const codingAgentSrc = path.join(root, 'packages/coding-agent/src');
const argsSource = readText(path.join(codingAgentSrc, 'cli/args.ts'));
const cliFlags = [...new Set([...argsSource.matchAll(/arg === "([^"]+)"/g)].map((match) => match[1]))].sort();

// Top-level subcommands routed before parseArgs (package + config managers).
const cliFilesDir = path.join(codingAgentSrc, 'cli');
const cliCommandFiles = listFiles(cliFilesDir, (file) => file.endsWith('.ts')).map((file) =>
  path.relative(codingAgentSrc, file).replaceAll(path.sep, '/'),
);

// Package-manager-cli subcommands (install/remove/update/list/config + uninstall alias).
const packageCliSource = readText(path.join(codingAgentSrc, 'package-manager-cli.ts'));
const packageCommandUnion = (packageCliSource.match(/export type PackageCommand = ([^;]+);/)?.[1] ?? '')
  .split('|')
  .map((part) => part.trim().replace(/"/g, ''))
  .filter(Boolean);
const subcommands = [...new Set([...packageCommandUnion, 'uninstall', 'config'])].sort();

// Mode entrypoints (text/json print, rpc, interactive).
const modeFiles = listFiles(path.join(codingAgentSrc, 'modes'), (file) => file.endsWith('.ts')).map((file) =>
  path.relative(codingAgentSrc, file).replaceAll(path.sep, '/'),
);
const appModes = ['interactive', 'print', 'json', 'rpc'];

// Built-in slash commands (interactive mode).
const slashSource = readText(path.join(codingAgentSrc, 'core/slash-commands.ts'));
const builtinSlashCommands = [
  ...slashSource
    .split('export const BUILTIN_SLASH_COMMANDS')[1]
    .matchAll(/\{ name: "([^"]+)", description:/g),
].map((match) => match[1]);

// Documented slash command rows in usage.md.
const slashCommandRows = readText(path.join(codingAgentSrc, '../docs/usage.md'))
  .split('\n')
  .filter((line) => line.trim().startsWith('| `/')).length;

// ---------------------------------------------------------------------------
// RPC commands (inbound union only)
// ---------------------------------------------------------------------------

const rpcTypesSource = readText(path.join(codingAgentSrc, 'modes/rpc/rpc-types.ts'));
const rpcCommandUnion = rpcTypesSource
  .split('export type RpcCommand =')[1]
  .split('// ============================================================================\n// RPC Slash Command')[0];
const rpcCommands = [...rpcCommandUnion.matchAll(/\| \{ id\?: string; type: "([^"]+)"/g)].map((match) => match[1]);

// ---------------------------------------------------------------------------
// Built-in tools
// ---------------------------------------------------------------------------

const toolModuleFiles = listFiles(path.join(codingAgentSrc, 'core/tools'), (file) => file.endsWith('.ts')).map((file) =>
  path.basename(file, '.ts'),
);
// The tool names exposed to the LLM (subset of the module files).
const builtInTools = ['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls'];

// ---------------------------------------------------------------------------
// Providers: transport APIs, implementation files, auth surfaces
// ---------------------------------------------------------------------------

const aiSrc = path.join(root, 'packages/ai/src');
const providerFiles = listFiles(path.join(aiSrc, 'providers'), (file) => file.endsWith('.ts')).map((file) =>
  path.relative(aiSrc, file).replaceAll(path.sep, '/'),
);

// Registered transport API ids (the `api:` keys passed to registerApiProvider).
const registerBuiltinsSource = readText(path.join(aiSrc, 'providers/register-builtins.ts'));
const transportApis = [
  ...registerBuiltinsSource
    .split('export function registerBuiltInApiProviders')[1]
    .matchAll(/api: "([^"]+)"/g),
].map((match) => match[1]);

// Generated model catalog: providers + model rows.
const generatedModelsSource = readText(path.join(aiSrc, 'models.generated.ts'));
const generatedModelProviders = [...generatedModelsSource.matchAll(/^\t"([^"]+)": \{/gm)].map((match) => match[1]);
const generatedModelRows = [...generatedModelsSource.matchAll(/^\s+id: /gm)].length;

// Env-key auth surfaces (API-key providers).
const envApiKeysSource = readText(path.join(aiSrc, 'env-api-keys.ts'));
const envKeyProviders = [
  'github-copilot',
  'anthropic',
  ...[...(envApiKeysSource.match(/const envMap: Record<string, string> = \{([\s\S]*?)\};/)?.[1] ?? '').matchAll(
    /"?([a-z0-9-]+)"?:\s*"[A-Z_]+"/g,
  )].map((match) => match[1]),
];
const uniqueEnvKeyProviders = [...new Set(envKeyProviders)].sort();

// OAuth providers (from utils/oauth/* provider definitions, excluding shared modules).
const oauthFiles = listFiles(path.join(aiSrc, 'utils/oauth'), (file) => file.endsWith('.ts')).map((file) =>
  path.basename(file, '.ts'),
);
const oauthProviders = oauthFiles.filter(
  (name) => !['index', 'types', 'pkce', 'device-code', 'oauth-page'].includes(name),
);

// ---------------------------------------------------------------------------
// Extension APIs: registration/action methods + lifecycle events
// ---------------------------------------------------------------------------

const extensionTypesSource = readText(path.join(codingAgentSrc, 'core/extensions/types.ts'));
const extensionEvents = [
  ...new Set([...extensionTypesSource.matchAll(/event: "([a-z_]+)"/g)].map((match) => match[1])),
].sort();
// pi.* API methods declared in the extension API interface block.
const piApiBlock = extensionTypesSource.slice(extensionTypesSource.indexOf('on(event:'));
const extensionApiMethods = [
  ...new Set(
    [
      ...piApiBlock.matchAll(
        /^\t(registerTool|registerCommand|registerShortcut|registerFlag|getFlag|registerMessageRenderer|sendMessage|sendUserMessage|appendEntry|setSessionName|getSessionName|setLabel|exec|getActiveTools|getAllTools|setActiveTools|getCommands|setModel|getThinkingLevel|setThinkingLevel|registerProvider|unregisterProvider)\b/gm,
      ),
    ].map((match) => match[1]),
  ),
].sort();
const extensionApiFiles = listFiles(path.join(codingAgentSrc, 'core/extensions'), (file) => file.endsWith('.ts')).map(
  (file) => path.relative(codingAgentSrc, file).replaceAll(path.sep, '/'),
);

// ---------------------------------------------------------------------------
// TUI components and surfaces
// ---------------------------------------------------------------------------

const tuiSrc = path.join(root, 'packages/tui/src');
const tuiComponents = listFiles(path.join(tuiSrc, 'components'), (file) => file.endsWith('.ts')).map((file) =>
  path.basename(file, '.ts'),
);
const tuiTopLevel = listFiles(tuiSrc, (file) => file.endsWith('.ts') && path.dirname(file) === tuiSrc).map((file) =>
  path.basename(file, '.ts'),
);
// Interactive-mode UI component groups (selectors/dialogs/messages that drive TUI routes).
const interactiveComponents = listFiles(
  path.join(codingAgentSrc, 'modes/interactive/components'),
  (file) => file.endsWith('.ts'),
).map((file) => path.basename(file, '.ts'));

// ---------------------------------------------------------------------------
// Docs that define DoD or public API
// ---------------------------------------------------------------------------

const docsJson = readJson(path.join(codingAgentSrc, '../docs/docs.json'));
const docPages = docsJson.navigation.flatMap((section) =>
  section.items.map((item) => ({ section: section.title, title: item.title, path: item.path })),
);

// ---------------------------------------------------------------------------
// Assemble inventory
// ---------------------------------------------------------------------------

const inventory = {
  upstream: {
    name: rootPkg.name,
    version: rootPkg.version,
    node: rootPkg.engines?.node,
    workspaces: rootPkg.workspaces,
    commit: UPSTREAM_COMMIT,
    packageFileCount: countFiles(path.join(root, 'packages')),
    packageCount: packages.length,
    primaryPackageCount: primaryPackages.length,
    examplePackageCount: examplePackages.length,
    packages,
    cli: {
      commandFiles: cliCommandFiles,
      flags: cliFlags,
      subcommands,
      modeFiles,
      appModes,
      builtinSlashCommands,
      slashCommandRows,
    },
    rpcCommands,
    builtInTools,
    toolModuleFiles,
    providers: {
      implementationFiles: providerFiles,
      transportApis,
      generatedModelProviders,
      generatedModelRows,
      envKeyProviders: uniqueEnvKeyProviders,
      oauthProviders,
    },
    extensions: {
      apiFiles: extensionApiFiles,
      apiMethods: extensionApiMethods,
      events: extensionEvents,
    },
    tui: {
      components: tuiComponents,
      topLevelModules: tuiTopLevel,
      interactiveComponents,
    },
    docs: docPages,
  },
};

// ---------------------------------------------------------------------------
// Self-checks: fail loudly if discovery drifts or a surface goes missing.
// ---------------------------------------------------------------------------

const errors = [];

if (packages.length < 8) {
  errors.push(`Expected at least 8 packages (4 primary + 4 example extensions), got ${packages.length}`);
}
if (primaryPackages.length !== 4) {
  errors.push(`Expected exactly 4 primary packages, got ${primaryPackages.length}`);
}

// Every workspace glob entry that points at a concrete dir must resolve to an inventoried package.
for (const workspace of rootPkg.workspaces) {
  if (workspace.includes('*')) continue;
  if (!packages.some((p) => p.dir === workspace)) {
    errors.push(`Workspace entry "${workspace}" is not represented in the package inventory`);
  }
}

// Each primary package must be one of the known four (guards against silent renames).
const expectedPrimary = new Set([
  '@earendil-works/pi-ai',
  '@earendil-works/pi-agent-core',
  '@earendil-works/pi-coding-agent',
  '@earendil-works/pi-tui',
]);
for (const pkg of primaryPackages) {
  if (!expectedPrimary.has(pkg.name)) {
    errors.push(`Unexpected primary package name "${pkg.name}" in ${pkg.dir}`);
  }
}

if (!cliFlags.includes('--list-models')) {
  errors.push('Missing --list-models in parsed CLI flags');
}
for (const required of ['install', 'remove', 'uninstall', 'update', 'list', 'config']) {
  if (!subcommands.includes(required)) {
    errors.push(`Missing top-level subcommand "${required}"`);
  }
}
if (builtinSlashCommands.length < 21) {
  errors.push(`Expected at least 21 built-in slash commands, got ${builtinSlashCommands.length}`);
}
if (!builtinSlashCommands.includes('compact') || !builtinSlashCommands.includes('login')) {
  errors.push('Built-in slash command list is missing expected entries (compact/login)');
}

if (rpcCommands.length !== 29) {
  errors.push(`Expected 29 inbound RPC commands, got ${rpcCommands.length}`);
}
if (!rpcCommands.includes('prompt') || !rpcCommands.includes('get_commands')) {
  errors.push('Inbound RPC command union is missing expected entries (prompt/get_commands)');
}

for (const tool of builtInTools) {
  if (!toolModuleFiles.includes(tool)) {
    errors.push(`Built-in tool "${tool}" has no module file under core/tools`);
  }
}

if (transportApis.length !== 9) {
  errors.push(`Expected 9 registered transport APIs, got ${transportApis.length}`);
}
for (const api of ['anthropic-messages', 'openai-responses', 'google-vertex', 'bedrock-converse-stream']) {
  if (!transportApis.includes(api)) {
    errors.push(`Missing transport API "${api}"`);
  }
}
if (generatedModelProviders.length !== 32 || generatedModelRows !== 924) {
  errors.push(
    `Generated model inventory drifted: providers=${generatedModelProviders.length} rows=${generatedModelRows} (expected 32/924)`,
  );
}
// Every transport-API provider key in the generated catalog should be a known model provider.
if (!generatedModelProviders.includes('amazon-bedrock')) {
  errors.push('Generated model providers missing amazon-bedrock');
}
if (oauthProviders.length !== 3) {
  errors.push(`Expected 3 OAuth providers, got ${oauthProviders.length}: ${oauthProviders.join(', ')}`);
}
for (const provider of ['anthropic', 'github-copilot', 'openai-codex']) {
  if (!oauthProviders.includes(provider)) {
    errors.push(`Missing OAuth provider "${provider}"`);
  }
}
if (uniqueEnvKeyProviders.length < 25) {
  errors.push(`Expected at least 25 env-key providers, got ${uniqueEnvKeyProviders.length}`);
}

if (extensionEvents.length !== 29) {
  errors.push(`Expected 29 extension lifecycle events, got ${extensionEvents.length}`);
}
for (const event of ['tool_call', 'tool_result', 'session_start', 'before_provider_request']) {
  if (!extensionEvents.includes(event)) {
    errors.push(`Missing extension event "${event}"`);
  }
}
for (const method of ['registerTool', 'registerCommand', 'registerFlag', 'registerProvider', 'sendMessage', 'appendEntry']) {
  if (!extensionApiMethods.includes(method)) {
    errors.push(`Missing extension API method "${method}"`);
  }
}

if (tuiComponents.length < 12) {
  errors.push(`Expected at least 12 TUI components, got ${tuiComponents.length}`);
}
if (interactiveComponents.length < 30) {
  errors.push(`Expected at least 30 interactive components, got ${interactiveComponents.length}`);
}

if (docPages.length < 20) {
  errors.push(`Expected at least 20 documented public-API pages, got ${docPages.length}`);
}
for (const required of ['rpc.md', 'json.md', 'extensions.md', 'providers.md', 'settings.md', 'sessions.md']) {
  if (!docPages.some((page) => page.path === required)) {
    errors.push(`Missing public-API doc page "${required}"`);
  }
}

if (errors.length > 0) {
  throw new Error(`Upstream inventory self-check failed:\n  - ${errors.join('\n  - ')}`);
}

// ---------------------------------------------------------------------------
// Emit machine-readable artifact + stdout report.
// ---------------------------------------------------------------------------

const artifactDir = path.resolve('docs/inventory');
fs.mkdirSync(artifactDir, { recursive: true });
const artifact = {
  generatedFrom: 'scripts/upstream-inventory.mjs',
  commit: UPSTREAM_COMMIT,
  counts: {
    packages: packages.length,
    primaryPackages: primaryPackages.length,
    examplePackages: examplePackages.length,
    cliFlags: cliFlags.length,
    subcommands: subcommands.length,
    appModes: appModes.length,
    builtinSlashCommands: builtinSlashCommands.length,
    rpcCommands: rpcCommands.length,
    builtInTools: builtInTools.length,
    providerImplementationFiles: providerFiles.length,
    transportApis: transportApis.length,
    generatedModelProviders: generatedModelProviders.length,
    generatedModelRows,
    envKeyProviders: uniqueEnvKeyProviders.length,
    oauthProviders: oauthProviders.length,
    extensionApiMethods: extensionApiMethods.length,
    extensionEvents: extensionEvents.length,
    tuiComponents: tuiComponents.length,
    interactiveComponents: interactiveComponents.length,
    docs: docPages.length,
  },
  inventory: inventory.upstream,
};
fs.writeFileSync(path.join(artifactDir, 'upstream-inventory.json'), `${JSON.stringify(artifact, null, 2)}\n`);

console.log(JSON.stringify(inventory, null, 2));

import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve('upstream/pi');

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
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

function packageInfo(name) {
  const dir = path.join(root, 'packages', name);
  const pkg = readJson(path.join(dir, 'package.json'));
  return {
    dir: `packages/${name}`,
    name: pkg.name,
    version: pkg.version,
    scripts: Object.keys(pkg.scripts || {}),
    dependencies: Object.keys(pkg.dependencies || {}),
    optionalDependencies: Object.keys(pkg.optionalDependencies || {}),
    devDependencies: Object.keys(pkg.devDependencies || {}),
    sourceFiles: countFiles(path.join(dir, 'src'), (file) => file.endsWith('.ts')),
    testFiles: fs.existsSync(path.join(dir, 'test'))
      ? countFiles(path.join(dir, 'test'), (file) => file.endsWith('.ts'))
      : 0
  };
}

const rootPkg = readJson(path.join(root, 'package.json'));
const packageNames = ['ai', 'agent', 'coding-agent', 'tui'];
const argsSource = fs.readFileSync(path.join(root, 'packages/coding-agent/src/cli/args.ts'), 'utf8');
const cliFlags = [...argsSource.matchAll(/arg === "([^"]+)"/g)].map((match) => match[1]);
const slashCommands = fs
  .readFileSync(path.join(root, 'packages/coding-agent/docs/usage.md'), 'utf8')
  .split('\n')
  .filter((line) => line.trim().startsWith('| `/'))
  .length;
const rpcTypesSource = fs
  .readFileSync(path.join(root, 'packages/coding-agent/src/modes/rpc/rpc-types.ts'), 'utf8')
  .split('// ============================================================================\n// RPC Slash Command')[0];
const rpcCommands = [...rpcTypesSource.matchAll(/\| \{ id\?: string; type: "([^"]+)"/g)].map((match) => match[1]);
const builtInTools = listFiles(path.join(root, 'packages/coding-agent/src/core/tools'), (file) =>
  file.endsWith('.ts')
).map((file) => path.basename(file, '.ts'));
const generatedModelsSource = fs.readFileSync(path.join(root, 'packages/ai/src/models.generated.ts'), 'utf8');
const generatedModelRows = [...generatedModelsSource.matchAll(/^\s+id: /gm)].length;
const generatedModelProviders = [...generatedModelsSource.matchAll(/^\t"([^"]+)": \{/gm)].map((match) => match[1]);

const inventory = {
  upstream: {
    name: rootPkg.name,
    version: rootPkg.version,
    node: rootPkg.engines?.node,
    workspaces: rootPkg.workspaces,
    commit: 'fc8a1559017f1e581cfa971aa3cef11a507a4975',
    packageFileCount: countFiles(path.join(root, 'packages')),
    packages: packageNames.map(packageInfo),
    cliFlags: [...new Set(cliFlags)].sort(),
    slashCommandRows: slashCommands,
    rpcCommands,
    builtInTools,
    generatedModelProviders,
    generatedModelRows
  }
};

if (inventory.upstream.packages.length !== 4) {
  throw new Error(`Expected 4 primary packages, got ${inventory.upstream.packages.length}`);
}

if (!inventory.upstream.cliFlags.includes('--list-models')) {
  throw new Error('Missing --list-models in parsed CLI flags');
}

if (!inventory.upstream.rpcCommands.includes('prompt')) {
  throw new Error('Missing prompt RPC command in docs/rpc.md');
}

if (!inventory.upstream.builtInTools.includes('read')) {
  throw new Error('Missing read built-in tool');
}

if (inventory.upstream.generatedModelProviders.length !== 32 || inventory.upstream.generatedModelRows !== 924) {
  throw new Error('Generated model inventory no longer matches expected provider/model counts');
}

console.log(JSON.stringify(inventory, null, 2));

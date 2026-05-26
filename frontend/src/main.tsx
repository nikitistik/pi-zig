import { render } from 'preact';
import './styles.css';

type Status = 'foundation' | 'in_progress' | 'verified' | 'not_started';

type PackageRow = {
  name: string;
  dir: string;
  role: string;
  sourceFiles: number;
  testFiles: number;
};

type ParityRow = {
  area: string;
  status: Status;
  target: string;
};

const packages: PackageRow[] = [
  {
    name: '@earendil-works/pi-ai',
    dir: 'packages/ai',
    role: 'LLM providers, images, OAuth, streaming',
    sourceFiles: 53,
    testFiles: 76
  },
  {
    name: '@earendil-works/pi-agent-core',
    dir: 'packages/agent',
    role: 'Agent loop, harness, sessions, hooks',
    sourceFiles: 25,
    testFiles: 20
  },
  {
    name: '@earendil-works/pi-coding-agent',
    dir: 'packages/coding-agent',
    role: 'CLI, TUI, RPC, tools, resources',
    sourceFiles: 145,
    testFiles: 133
  },
  {
    name: '@earendil-works/pi-tui',
    dir: 'packages/tui',
    role: 'Terminal renderer, editor, keybindings',
    sourceFiles: 26,
    testFiles: 28
  }
];

const parity: ParityRow[] = [
  { area: 'Package map', status: 'foundation', target: '4 upstream packages represented' },
  { area: 'CLI and commands', status: 'in_progress', target: '46 flags plus top-level --list-models, -p, --mode json/rpc foundations' },
  { area: 'Package commands', status: 'in_progress', target: 'Local/npm/git install/list/remove plus extension update; self-update missing' },
  { area: 'Settings manager', status: 'in_progress', target: 'Global/project read, migrations, merge defaults, scoped writes, invalid JSON safety' },
  { area: 'Print and JSON modes', status: 'foundation', target: 'Top-level prompt acceptance, session persistence, JSONL event skeleton' },
  { area: 'RPC protocol', status: 'in_progress', target: '29 RpcCommand inputs, bash/compact/retry/commands/session controls started' },
  { area: 'Providers', status: 'in_progress', target: 'Provider list and env-key map started' },
  { area: 'Auth storage', status: 'foundation', target: 'auth.json API keys, env fallback, OAuth token read; login/refresh missing' },
  { area: 'Models', status: 'in_progress', target: '924 generated upstream models, fuzzy resolver, thinking suffixes' },
  { area: 'Built-in tools', status: 'in_progress', target: 'read, bash, ls, grep, find, write, edit, RPC bash smokes' },
  { area: 'Sessions', status: 'in_progress', target: 'Durable JSONL resume, stats, names, compact, fork, clone' },
  { area: 'Resources', status: 'in_progress', target: 'Prompt/skill commands, themes, context files, system prompt assembly' },
  { area: 'TUI renderer', status: 'not_started', target: 'Differential terminal rendering and editor' },
  { area: 'Prin7r injection', status: 'not_started', target: 'Backend plus Preact app surface' }
];

const commands = [
  'zig build run -- status',
  'zig build run -- inventory',
  'zig build run -- packages',
  'zig build run -- models',
  'zig build run -- models-for anthropic',
  'zig build run -- model anthropic claude-haiku-4-5',
  'zig build run -- list-models haiku',
  'zig build run -- --list-models haiku',
  'zig build run -- resolve-model --provider anthropic haiku:high',
  'zig build run -- resolve-model openai/gpt-4o',
  'zig build run -- rpc-schema',
  'zig build run -- list',
  'zig build run -- install --help',
  'zig build run -- install npm:example-package',
  'zig build run -- install git:github.com/user/repo --local',
  'zig build run -- update --extensions',
  'zig build run -- auth list --json',
  'zig build run -- auth providers --json',
  'zig build run -- auth status openai --json',
  'zig build run -- auth set-api-key openai OPENAI_API_KEY',
  'zig build run -- auth resolve openai --json',
  'zig build run -- settings --json',
  'zig build run -- settings get resolved.compaction.enabled',
  'zig build run -- settings set-model openai gpt-4o',
  'printf \'{"type":"get_available_models"}\\n{"type":"set_model","provider":"anthropic","modelId":"claude-haiku-4-5"}\\n{"type":"get_state"}\\n\' | zig-out/bin/pi-zig rpc zig-out/pi-zig-session.jsonl',
  'printf \'{"type":"get_state"}\\n\' | zig-out/bin/pi-zig rpc zig-out/pi-zig-session.jsonl',
  'printf \'{"type":"get_session_stats"}\\n\' | zig-out/bin/pi-zig rpc zig-out/pi-zig-session.jsonl',
  'printf \'{"type":"prompt","message":"compact me"}\\n{"type":"set_auto_compaction","enabled":true}\\n{"type":"compact","customInstructions":"focus"}\\n{"type":"abort_retry"}\\n\' | zig-out/bin/pi-zig rpc zig-out/pi-zig-compact-session.jsonl',
  'printf \'{"type":"bash","command":"printf rpc-bash"}\\n{"type":"get_messages"}\\n\' | zig-out/bin/pi-zig rpc zig-out/pi-zig-session.jsonl',
  'printf \'{"type":"switch_session","sessionPath":"zig-out/pi-zig-session.jsonl"}\\n{"type":"get_state"}\\n\' | zig-out/bin/pi-zig rpc zig-out/pi-zig-switch-driver.jsonl',
  'printf \'{"type":"prompt","message":"first"}\\n{"type":"prompt","message":"second"}\\n{"type":"fork","entryId":"m-2"}\\n\' | zig-out/bin/pi-zig rpc zig-out/pi-zig-fork-source.jsonl',
  'printf \'{"type":"prompt","message":"clone me"}\\n{"type":"clone"}\\n{"type":"get_state"}\\n\' | zig-out/bin/pi-zig rpc zig-out/pi-zig-clone-source.jsonl',
  'zig build run -- provider-env anthropic',
  'zig build run -- commands',
  'zig build run -- commands --skill explicit/skills --prompt-template explicit/prompts',
  'zig build run -- themes',
  'zig build run -- themes --export dark',
  'COLORFGBG="0;7;15" zig build run -- themes --detect',
  'zig build run -- themes --resolved light',
  'zig build run -- context-files --no-context-files',
  'zig build run -- system-prompt --date 2026-05-26 --json --no-context-files',
  'npm run test # verifies auth storage, settings-manager migrations, package filters, local packages, context files, system prompt assembly, and ancestor .agents discovery',
  'printf \'{"type":"get_commands"}\\n\' | zig-out/bin/pi-zig rpc zig-out/pi-zig-session.jsonl',
  'printf \'{"type":"get_commands"}\\n\' | zig-out/bin/pi-zig --mode rpc --session zig-out/pi-zig-session.jsonl --skill explicit/skills --prompt-template explicit/prompts',
  'zig-out/bin/pi-zig -p "hello top-level print"',
  'zig-out/bin/pi-zig --mode json --session zig-out/pi-zig-json-session.jsonl -p "hello json"',
  'printf \'{"type":"get_state"}\\n\' | zig-out/bin/pi-zig --mode rpc --session zig-out/pi-zig-rpc-mode-session.jsonl',
  'zig build run -- parse-args --provider openai -p ok',
  'zig build run -- tool-read README.md',
  'zig build run -- tool-grep pi-zig README.md',
  'zig build run -- tool-find README.md . 20',
  'zig build run -- tool-write zig-out/pi-zig-tool-edit-smoke.txt "alpha beta"',
  'zig build run -- tool-edit zig-out/pi-zig-tool-edit-smoke.txt beta gamma',
  'npm run test'
];

function statusLabel(status: Status) {
  return status.replace('_', ' ');
}

function App() {
  const completed = parity.filter((row) => row.status === 'verified').length;
  const active = parity.filter((row) => row.status === 'foundation' || row.status === 'in_progress').length;
  const totalSource = packages.reduce((sum, row) => sum + row.sourceFiles, 0);
  const totalTests = packages.reduce((sum, row) => sum + row.testFiles, 0);
  const totalModels = 924;

  return (
    <main class="shell">
      <header class="topbar">
        <div>
          <p class="eyebrow">earendil-works/pi parity port</p>
          <h1>pi-zig</h1>
        </div>
        <div class="commit">
          <span>upstream</span>
          <strong>fc8a155</strong>
        </div>
      </header>

      <section class="metrics" aria-label="Port metrics">
        <div>
          <span>{packages.length}</span>
          <p>packages</p>
        </div>
        <div>
          <span>{totalSource}</span>
          <p>source files</p>
        </div>
        <div>
          <span>{totalTests}</span>
          <p>test files</p>
        </div>
        <div>
          <span>{totalModels}</span>
          <p>models</p>
        </div>
        <div>
          <span>{active}/{parity.length}</span>
          <p>started areas</p>
        </div>
        <div>
          <span>{completed}</span>
          <p>verified areas</p>
        </div>
      </section>

      <div class="workspace-grid">
        <section class="panel wide" aria-label="Package inventory">
          <div class="section-head">
            <h2>Package Inventory</h2>
            <span>source of truth: upstream/pi</span>
          </div>
          <div class="table">
            <div class="table-row table-header">
              <span>Package</span>
              <span>Role</span>
              <span>Source</span>
              <span>Tests</span>
            </div>
            {packages.map((pkg) => (
              <div class="table-row" key={pkg.name}>
                <span>
                  <strong>{pkg.name}</strong>
                  <small>{pkg.dir}</small>
                </span>
                <span>{pkg.role}</span>
                <span class="num">{pkg.sourceFiles}</span>
                <span class="num">{pkg.testFiles}</span>
              </div>
            ))}
          </div>
        </section>

        <section class="panel" aria-label="Backend commands">
          <div class="section-head">
            <h2>Backend Commands</h2>
            <span>local smokes</span>
          </div>
          <div class="command-list">
            {commands.map((command) => (
              <code key={command}>{command}</code>
            ))}
          </div>
        </section>

        <section class="panel wide" aria-label="Parity status">
          <div class="section-head">
            <h2>Parity Status</h2>
            <span>docs/parity.md</span>
          </div>
          <div class="parity-list">
            {parity.map((row) => (
              <article class="parity-row" data-status={row.status} key={row.area}>
                <div>
                  <h3>{row.area}</h3>
                  <p>{row.target}</p>
                </div>
                <span>{statusLabel(row.status)}</span>
              </article>
            ))}
          </div>
        </section>
      </div>
    </main>
  );
}

render(<App />, document.getElementById('app')!);

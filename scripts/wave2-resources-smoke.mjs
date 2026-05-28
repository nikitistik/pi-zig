#!/usr/bin/env node
// Wave 2: Resources (skills / prompt templates / themes / context files) smoke.
//
// Standalone Node.js stdlib smoke (no npm deps) that drives the real
// `zig-out/bin/pi-zig` binary against throwaway temp directories to confirm
// resource discovery, upstream precedence/dedup ordering, and on-demand reload
// round-trips for the resource-loader surfaces owned by this wave:
//
//   1. `commands` — prompt templates + skills discovery. Asserts:
//        - project and user prompt/skill directories are discovered,
//        - a project resource WINS a name collision with a same-named user
//          resource and the duplicate is dropped (matches upstream
//          resourcePrecedenceRank + first-wins dedup),
//        - skills are namespaced as `skill:<name>`,
//        - RELOAD round-trip: a prompt added after the first invocation appears
//          on a second invocation, and disappears again when removed (stateless
//          re-discovery == upstream resourceLoader.reload semantics),
//        - `--no-prompt-templates` / `--no-skills` suppress discovery.
//
//   2. `themes` — theme discovery. Asserts:
//        - built-in `dark`/`light` are always present and are NOT overridable by
//          a custom theme of the same name (built-ins resolve first upstream),
//        - a uniquely-named custom theme passed via `--theme` is discovered,
//        - `--resolved <name>` resolves the built-in for a shadowed name,
//        - RELOAD round-trip: a theme file added between invocations appears.
//
//   3. `context-files` — AGENTS/CLAUDE + SYSTEM/APPEND discovery. Asserts:
//        - AGENTS.md is preferred over CLAUDE.md (upstream candidate order),
//        - project `.pi/SYSTEM.md` wins over the agent-dir SYSTEM.md,
//        - RELOAD round-trip: a CLAUDE.md added later is discovered.
//
// Exits non-zero on any failure; prints "[wave2-resources-smoke] PASS" on success.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const bin = path.resolve('zig-out/bin/pi-zig');

function fail(message) {
  console.error(`[wave2-resources-smoke] FAIL: ${message}`);
  process.exit(1);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

function ensureBinary() {
  try {
    execFileSync('zig', ['build'], { stdio: ['ignore', 'inherit', 'inherit'] });
  } catch (error) {
    fail(`zig build failed: ${error.message}`);
  }
  if (!fs.existsSync(bin)) {
    fail(`binary not found at ${bin} after zig build`);
  }
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

const REQUIRED_THEME_COLORS = [
  'accent', 'border', 'borderAccent', 'borderMuted', 'success', 'error', 'warning', 'muted',
  'dim', 'text', 'thinkingText', 'selectedBg', 'userMessageBg', 'userMessageText', 'customMessageBg',
  'customMessageText', 'customMessageLabel', 'toolPendingBg', 'toolSuccessBg', 'toolErrorBg', 'toolTitle',
  'toolOutput', 'mdHeading', 'mdLink', 'mdLinkUrl', 'mdCode', 'mdCodeBlock', 'mdCodeBlockBorder', 'mdQuote',
  'mdQuoteBorder', 'mdHr', 'mdListBullet', 'toolDiffAdded', 'toolDiffRemoved', 'toolDiffContext', 'syntaxComment',
  'syntaxKeyword', 'syntaxFunction', 'syntaxVariable', 'syntaxString', 'syntaxNumber', 'syntaxType', 'syntaxOperator',
  'syntaxPunctuation', 'thinkingOff', 'thinkingMinimal', 'thinkingLow', 'thinkingMedium', 'thinkingHigh', 'thinkingXhigh',
  'bashMode',
];

function minimalThemeJson(name) {
  const colors = {};
  for (const key of REQUIRED_THEME_COLORS) colors[key] = '#000000';
  return JSON.stringify({ name, colors });
}

function commandByName(data, name) {
  return data.commands.filter((command) => command.name === name);
}

function themeSource(data, name) {
  const entry = data.themes.find((theme) => theme.name === name);
  return entry ? entry.source : undefined;
}

function testCommands(root) {
  const cwd = path.join(root, 'commands', 'proj');
  const home = path.join(root, 'commands', 'home');
  const agentDir = path.join(home, '.pi', 'agent');
  fs.mkdirSync(path.join(cwd, '.pi', 'prompts'), { recursive: true });
  fs.mkdirSync(path.join(agentDir, 'prompts'), { recursive: true });
  fs.mkdirSync(path.join(agentDir, 'skills', 'demoskill'), { recursive: true });

  // Same prompt name in project and user scopes: project must win + dedup to one.
  fs.writeFileSync(
    path.join(cwd, '.pi', 'prompts', 'hello.md'),
    '---\ndescription: project hello\n---\nProject body $1\n',
  );
  fs.writeFileSync(
    path.join(agentDir, 'prompts', 'hello.md'),
    '---\ndescription: user hello\n---\nUser body\n',
  );
  // A user-only prompt and a user skill.
  fs.writeFileSync(
    path.join(agentDir, 'prompts', 'useronly.md'),
    '---\ndescription: user only\n---\nUser only body\n',
  );
  fs.writeFileSync(
    path.join(agentDir, 'skills', 'demoskill', 'SKILL.md'),
    '---\nname: demoskill\ndescription: a demo skill\n---\nSkill body\n',
  );

  const first = runJson(['commands'], { cwd, home, agentDir });
  const hello = commandByName(first, 'hello');
  assert(hello.length === 1, `expected exactly one /hello after dedup, got ${hello.length}`);
  assert(hello[0].description === 'project hello', `expected project /hello to win, got "${hello[0].description}"`);
  assert(hello[0].sourceInfo.scope === 'project', `expected /hello scope project, got ${hello[0].sourceInfo.scope}`);
  assert(commandByName(first, 'useronly').length === 1, 'expected user-only prompt /useronly to be discovered');
  assert(
    first.commands.some((command) => command.name === 'skill:demoskill' && command.source === 'skill'),
    'expected /skill:demoskill to be discovered',
  );
  assert(!first.commands.some((command) => command.name === 'reloadprobe'), 'reloadprobe must be absent before it is created');

  // Reload round-trip: add a new prompt, re-run, it appears.
  fs.writeFileSync(
    path.join(cwd, '.pi', 'prompts', 'reloadprobe.md'),
    '---\ndescription: reload added\n---\nReload body\n',
  );
  const reloaded = runJson(['commands'], { cwd, home, agentDir });
  const probe = commandByName(reloaded, 'reloadprobe');
  assert(probe.length === 1, 'reloadprobe must appear after reload');
  assert(probe[0].description === 'reload added', `reloadprobe description mismatch: ${probe[0].description}`);

  // ...and disappears when removed (no stale cache).
  fs.rmSync(path.join(cwd, '.pi', 'prompts', 'reloadprobe.md'));
  const afterRemove = runJson(['commands'], { cwd, home, agentDir });
  assert(!afterRemove.commands.some((command) => command.name === 'reloadprobe'), 'reloadprobe must disappear after removal + reload');

  // Suppression flags.
  const noPrompts = runJson(['commands', '--no-prompt-templates'], { cwd, home, agentDir });
  assert(commandByName(noPrompts, 'hello').length === 0, '--no-prompt-templates must drop prompt commands');
  assert(
    noPrompts.commands.some((command) => command.name === 'skill:demoskill'),
    '--no-prompt-templates must keep skills',
  );
  const noSkills = runJson(['commands', '--no-skills'], { cwd, home, agentDir });
  assert(!noSkills.commands.some((command) => command.name === 'skill:demoskill'), '--no-skills must drop skills');
  assert(commandByName(noSkills, 'hello').length === 1, '--no-skills must keep prompts');

  console.log('[wave2-resources-smoke] commands: discovery + project>user dedup + reload round-trip OK');
}

function testThemes(root) {
  const cwd = path.join(root, 'themes', 'proj');
  const agentDir = path.join(root, 'themes', 'agent');
  const customDir = path.join(root, 'themes', 'custom');
  fs.mkdirSync(path.join(cwd, '.pi'), { recursive: true });
  fs.mkdirSync(agentDir, { recursive: true });
  fs.mkdirSync(customDir, { recursive: true });

  // A custom theme that tries to shadow built-in "dark", plus a unique theme.
  fs.writeFileSync(path.join(customDir, 'dark.json'), minimalThemeJson('dark'));
  fs.writeFileSync(path.join(customDir, 'ocean.json'), minimalThemeJson('ocean'));

  const first = runJson(['themes', '--theme', customDir], { cwd, home: agentDir, agentDir });
  assert(themeSource(first, 'dark') === 'builtin', `built-in dark must win over custom, got ${themeSource(first, 'dark')}`);
  assert(themeSource(first, 'light') === 'builtin', 'built-in light must be present');
  assert(themeSource(first, 'ocean') === 'temporary', `custom ocean must be discovered, got ${themeSource(first, 'ocean')}`);

  // Resolution of a shadowed name returns the built-in (must succeed and name back as dark).
  const resolved = runJson(['themes', '--theme', customDir, '--resolved', 'dark'], { cwd, home: agentDir, agentDir });
  assert(resolved.name === 'dark', `--resolved dark must resolve, got name ${resolved.name}`);
  assert(typeof resolved.colors === 'object' && resolved.colors.text, '--resolved dark must include resolved colors');

  // Reload round-trip: a project theme added between calls appears.
  const projectThemes = path.join(cwd, '.pi', 'themes');
  fs.mkdirSync(projectThemes, { recursive: true });
  const before = runJson(['themes'], { cwd, home: agentDir, agentDir });
  assert(themeSource(before, 'sunrise') === undefined, 'sunrise must be absent before it is created');
  fs.writeFileSync(path.join(projectThemes, 'sunrise.json'), minimalThemeJson('sunrise'));
  const after = runJson(['themes'], { cwd, home: agentDir, agentDir });
  assert(themeSource(after, 'sunrise') === 'project', `sunrise must appear as project theme after reload, got ${themeSource(after, 'sunrise')}`);

  console.log('[wave2-resources-smoke] themes: built-in precedence + custom discovery + reload round-trip OK');
}

function testContextFiles(root) {
  const cwd = path.join(root, 'context', 'proj');
  const agentDir = path.join(root, 'context', 'agent');
  fs.mkdirSync(path.join(cwd, '.pi'), { recursive: true });
  fs.mkdirSync(agentDir, { recursive: true });

  // AGENTS.md must beat CLAUDE.md in the same dir; project SYSTEM.md beats agent SYSTEM.md.
  fs.writeFileSync(path.join(cwd, 'AGENTS.md'), 'project agents context');
  fs.writeFileSync(path.join(cwd, 'CLAUDE.md'), 'project claude context');
  fs.writeFileSync(path.join(cwd, '.pi', 'SYSTEM.md'), 'project system prompt');
  fs.writeFileSync(path.join(agentDir, 'SYSTEM.md'), 'agent system prompt');

  const first = runJson(['context-files'], { cwd, home: agentDir, agentDir });
  const names = first.contextFiles.map((file) => path.basename(file.path));
  assert(names.includes('AGENTS.md'), `AGENTS.md must be discovered, got ${JSON.stringify(names)}`);
  assert(!names.includes('CLAUDE.md'), 'CLAUDE.md must not be picked when AGENTS.md exists in the same dir');
  assert(first.systemPrompt && path.basename(first.systemPrompt.path) === 'SYSTEM.md', 'project SYSTEM.md must be discovered');
  assert(first.systemPrompt.content === 'project system prompt', `project SYSTEM.md must win, got "${first.systemPrompt && first.systemPrompt.content}"`);

  // Reload round-trip from a nested cwd. Compare by content (paths are
  // symlink-canonicalized by the binary, e.g. /var -> /private/var on macOS,
  // so absolute-path equality is unreliable).
  const sub = path.join(cwd, 'nested');
  fs.mkdirSync(sub, { recursive: true });
  const beforeNested = runJson(['context-files'], { cwd: sub, home: agentDir, agentDir });
  assert(
    !beforeNested.contextFiles.some((file) => file.content === 'nested claude context'),
    'nested CLAUDE.md must be absent before it is created',
  );
  fs.writeFileSync(path.join(sub, 'CLAUDE.md'), 'nested claude context');
  const afterNested = runJson(['context-files'], { cwd: sub, home: agentDir, agentDir });
  const nestedContents = afterNested.contextFiles.map((file) => file.content);
  assert(nestedContents.includes('nested claude context'), 'nested CLAUDE.md must be discovered after reload');
  // The ancestor AGENTS.md (from the project root) must remain discovered, and
  // ancestor context is ordered before the nearer (cwd) file.
  assert(nestedContents.includes('project agents context'), 'ancestor AGENTS.md must remain discovered from a nested cwd');
  assert(
    nestedContents.indexOf('project agents context') < nestedContents.indexOf('nested claude context'),
    'ancestor context must be ordered before the nearer cwd context file',
  );

  console.log('[wave2-resources-smoke] context-files: candidate priority + SYSTEM precedence + reload round-trip OK');
}

function main() {
  ensureBinary();
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pi-zig-wave2-'));
  try {
    testCommands(root);
    testThemes(root);
    testContextFiles(root);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
  console.log('[wave2-resources-smoke] PASS');
}

main();

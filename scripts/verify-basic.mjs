import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const bin = path.resolve('zig-out/bin/pi-zig');

function run(args, input, options = {}) {
  return execFileSync(bin, args, { encoding: 'utf8', input, ...options });
}

function runFail(args, input, options = {}) {
  try {
    const stdout = execFileSync(bin, args, { encoding: 'utf8', input, ...options });
    throw new Error(`expected command to fail but it succeeded: ${args.join(' ')}\n${stdout}`);
  } catch (error) {
    if (error.status === undefined) throw error;
    return {
      status: error.status,
      stdout: error.stdout ?? '',
      stderr: error.stderr ?? ''
    };
  }
}

const status = run(['status']);
if (!status.includes('pi-zig foundation')) {
  throw new Error('status smoke did not identify pi-zig foundation');
}

const packages = JSON.parse(run(['packages']));
if (packages.packages.length !== 4) {
  throw new Error(`expected 4 packages, got ${packages.packages.length}`);
}

const rpc = JSON.parse(run(['rpc-schema']));
if (
  !rpc.commands.includes('prompt') ||
  !rpc.commands.includes('get_state') ||
  !rpc.commands.includes('get_available_models')
) {
  throw new Error('rpc-schema smoke missing core commands');
}
if (rpc.commands.length !== 29 || rpc.commands.includes('select') || !rpc.commands.includes('get_messages')) {
  throw new Error('rpc-schema smoke does not match authoritative RpcCommand union');
}

const emptyCommands = JSON.parse(run(['commands']));
if (!Array.isArray(emptyCommands.commands)) {
  throw new Error('commands smoke did not return command array');
}

const commandsFixtureRoot = path.resolve('zig-out/pi-zig-commands-fixture');
const commandsFixtureHome = path.join(commandsFixtureRoot, 'home');
const commandsFixtureEnv = { ...process.env, HOME: commandsFixtureHome };
fs.rmSync(commandsFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.git'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/agent/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/agent/skills/brave-search'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/skills/project-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-plus-prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-skills/project-settings-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-skills/project-disabled-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-skills/project-reincluded-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-skills/project-force-off-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-skills/utility-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.pi/settings-plus-skills/project-plus-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, '.agents/skills/ancestor-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-manifest/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-manifest/skills/project-package-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-convention/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-convention/skills/project-convention-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-filtered/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-filtered/skills/project-filter-keep-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-filtered/skills/project-filter-drop-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-disabled/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'packages/project-disabled/skills/project-package-disabled-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'workspace/nested'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'explicit/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureRoot, 'explicit/skills/ship-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/skills/global-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-plus-prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-settings-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-disabled-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-reincluded-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-force-off-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/settings-plus-skills/global-plus-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/packages/global-manifest/prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.pi/agent/packages/global-manifest/skills/global-package-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, 'settings-home-prompts'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, 'settings-home-skills/home-settings-skill'), { recursive: true });
fs.mkdirSync(path.join(commandsFixtureHome, '.agents/skills/external-skill'), { recursive: true });
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings.json'),
  JSON.stringify({
    prompts: [
      'settings-prompts',
      'project-*.md',
      '!project-excluded.md',
      '!project-reincluded.md',
      '+settings-prompts/project-reincluded.md',
      '-settings-prompts/project-force-off.md'
    ],
    skills: [
      'settings-skills',
      'project-*-skill',
      '!project-disabled-skill',
      '!project-reincluded-skill',
      '+settings-skills/project-reincluded-skill',
      '-settings-skills/project-force-off-skill'
    ],
    packages: [
      '../packages/project-manifest',
      '../packages/project-convention',
      { source: '../packages/project-filtered', prompts: ['project-filter-keep.md'], skills: ['project-filter-keep-skill'] },
      { source: '../packages/project-disabled', prompts: [], skills: [] }
    ],
    enableSkillCommands: true
  })
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings.json'),
  JSON.stringify({
    prompts: [
      'settings-prompts',
      '~/settings-home-prompts',
      '!global-disabled.md',
      '!global-reincluded.md',
      '+settings-prompts/global-reincluded.md',
      '-settings-prompts/global-force-off.md'
    ],
    skills: [
      'settings-skills',
      '~/settings-home-skills',
      '!global-disabled-skill',
      '!global-reincluded-skill',
      '+settings-skills/global-reincluded-skill',
      '-settings-skills/global-force-off-skill'
    ],
    packages: ['packages/global-manifest'],
    enableSkillCommands: true
  })
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/agent/prompts/fix-tests.md'),
  ['---', 'description: Fix failing tests', 'argument-hint: test command', '---', 'Run the tests and fix failures.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/prompts/review-code.md'),
  ['---', 'description: Review code changes', '---', 'Review code for bugs.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-prompts/project-settings.md'),
  ['---', 'description: Project settings prompt', '---', 'Prompt from .pi/settings.json.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-prompts/project-excluded.md'),
  ['---', 'description: Project excluded prompt', '---', 'Prompt excluded by ! setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-prompts/project-reincluded.md'),
  ['---', 'description: Project reincluded prompt', '---', 'Prompt re-enabled by + exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-prompts/project-force-off.md'),
  ['---', 'description: Project force-off prompt', '---', 'Prompt disabled by - exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-prompts/skip-settings.md'),
  ['---', 'description: Project skipped by include glob', '---', 'Prompt not matched by include glob.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-plus-prompts/project-plus.md'),
  ['---', 'description: Project plus prompt should not load as a source', '---', 'A + entry is a filter, not a source.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/agent/skills/brave-search/SKILL.md'),
  ['---', 'name: brave-search', 'description: Web search via Brave API', '---', 'Use Brave Search.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/skills/project-skill/SKILL.md'),
  ['---', 'name: project-skill', 'description: Project skill command', '---', 'Use the project skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-skills/project-settings-skill/SKILL.md'),
  ['---', 'name: project-settings-skill', 'description: Project settings skill command', '---', 'Use the project settings skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-skills/project-disabled-skill/SKILL.md'),
  ['---', 'name: project-disabled-skill', 'description: Project disabled skill command', '---', 'Disabled by ! setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-skills/project-reincluded-skill/SKILL.md'),
  ['---', 'name: project-reincluded-skill', 'description: Project reincluded skill command', '---', 'Re-enabled by + exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-skills/project-force-off-skill/SKILL.md'),
  ['---', 'name: project-force-off-skill', 'description: Project force-off skill command', '---', 'Disabled by - exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-skills/utility-skill/SKILL.md'),
  ['---', 'name: utility-skill', 'description: Utility skill excluded by include glob', '---', 'Not matched by include glob.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.pi/settings-plus-skills/project-plus-skill/SKILL.md'),
  ['---', 'name: project-plus-skill', 'description: Project plus skill should not load as a source', '---', 'A + entry is a filter, not a source.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, '.agents/skills/ancestor-skill/SKILL.md'),
  ['---', 'name: ancestor-skill', 'description: Ancestor agents skill command', '---', 'Use the ancestor skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-manifest/package.json'),
  JSON.stringify({
    name: 'project-manifest-package',
    pi: {
      prompts: ['prompts/project-package-review.md'],
      skills: ['skills/project-package-skill']
    }
  })
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-manifest/prompts/project-package-review.md'),
  ['---', 'description: Project package prompt', '---', 'Prompt from project package manifest.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-manifest/skills/project-package-skill/SKILL.md'),
  ['---', 'name: project-package-skill', 'description: Project package skill command', '---', 'Use the project package skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-convention/package.json'),
  JSON.stringify({ name: 'project-convention-package' })
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-convention/prompts/project-convention-prompt.md'),
  ['---', 'description: Project convention package prompt', '---', 'Prompt from package prompts directory.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-convention/skills/project-convention-skill/SKILL.md'),
  ['---', 'name: project-convention-skill', 'description: Project convention package skill command', '---', 'Use the project convention package skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-filtered/prompts/project-filter-keep.md'),
  ['---', 'description: Project filtered package prompt', '---', 'Prompt kept by package filter.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-filtered/prompts/project-filter-drop.md'),
  ['---', 'description: Project filtered package prompt should be disabled', '---', 'Prompt dropped by package filter.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-filtered/skills/project-filter-keep-skill/SKILL.md'),
  ['---', 'name: project-filter-keep-skill', 'description: Project filtered package skill command', '---', 'Use the filtered package skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-filtered/skills/project-filter-drop-skill/SKILL.md'),
  ['---', 'name: project-filter-drop-skill', 'description: Project filtered package skill should be disabled', '---', 'Dropped by package filter.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-disabled/prompts/project-disabled-prompt.md'),
  ['---', 'description: Project disabled package prompt', '---', 'Disabled by empty package prompt filter.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'packages/project-disabled/skills/project-package-disabled-skill/SKILL.md'),
  ['---', 'name: project-package-disabled-skill', 'description: Project disabled package skill', '---', 'Disabled by empty package skill filter.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'explicit/prompts/ship.md'),
  ['---', 'description: Ship a release', '---', 'Prepare release notes.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureRoot, 'explicit/skills/ship-skill/SKILL.md'),
  ['---', 'name: ship-skill', 'description: Temporary release skill', '---', 'Use the release skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/prompts/global-review.md'),
  ['---', 'description: Global review prompt', '---', 'Review globally.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-prompts/global-settings.md'),
  ['---', 'description: Global settings prompt', '---', 'Prompt from global settings.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-prompts/global-disabled.md'),
  ['---', 'description: Global disabled prompt', '---', 'Prompt disabled by ! setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-prompts/global-reincluded.md'),
  ['---', 'description: Global reincluded prompt', '---', 'Prompt re-enabled by + setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-prompts/global-force-off.md'),
  ['---', 'description: Global force-off prompt', '---', 'Prompt disabled by - exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-plus-prompts/global-plus.md'),
  ['---', 'description: Global plus prompt should not load as a source', '---', 'A + entry is a filter, not a source.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, 'settings-home-prompts/home-settings.md'),
  ['---', 'description: Home-expanded settings prompt', '---', 'Prompt from ~/ setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/skills/global-skill/SKILL.md'),
  ['---', 'name: global-skill', 'description: Global skill command', '---', 'Use the global skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-settings-skill/SKILL.md'),
  ['---', 'name: global-settings-skill', 'description: Global settings skill command', '---', 'Use the global settings skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-disabled-skill/SKILL.md'),
  ['---', 'name: global-disabled-skill', 'description: Global disabled skill command', '---', 'Disabled by ! setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-reincluded-skill/SKILL.md'),
  ['---', 'name: global-reincluded-skill', 'description: Global reincluded skill command', '---', 'Re-enabled by + exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-skills/global-force-off-skill/SKILL.md'),
  ['---', 'name: global-force-off-skill', 'description: Global force-off skill command', '---', 'Disabled by - exact setting.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/settings-plus-skills/global-plus-skill/SKILL.md'),
  ['---', 'name: global-plus-skill', 'description: Global plus skill should not load as a source', '---', 'A + entry is a filter, not a source.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, 'settings-home-skills/home-settings-skill/SKILL.md'),
  ['---', 'name: home-settings-skill', 'description: Home-expanded settings skill command', '---', 'Use the home-expanded skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/packages/global-manifest/package.json'),
  JSON.stringify({
    name: 'global-manifest-package',
    pi: {
      prompts: ['prompts/global-package-review.md'],
      skills: ['skills/global-package-skill']
    }
  })
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/packages/global-manifest/prompts/global-package-review.md'),
  ['---', 'description: Global package prompt', '---', 'Prompt from global package manifest.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.pi/agent/packages/global-manifest/skills/global-package-skill/SKILL.md'),
  ['---', 'name: global-package-skill', 'description: Global package skill command', '---', 'Use the global package skill.'].join('\n')
);
fs.writeFileSync(
  path.join(commandsFixtureHome, '.agents/skills/external-skill/SKILL.md'),
  ['---', 'name: external-skill', 'description: External agents skill command', '---', 'Use the external skill.'].join('\n')
);
const fixtureCommands = JSON.parse(run(
  ['commands', '--skill', 'explicit/skills', '--prompt-template', 'explicit/prompts'],
  undefined,
  { cwd: commandsFixtureRoot, env: commandsFixtureEnv }
));
if (
  !fixtureCommands.commands.some((command) =>
    command.name === 'fix-tests' &&
    command.description === 'Fix failing tests' &&
    command.source === 'prompt' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'review-code' &&
    command.description === 'Review code changes' &&
    command.sourceInfo?.baseDir?.endsWith('.pi/prompts')
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'global-review' &&
    command.source === 'prompt' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'project-settings' &&
    command.description === 'Project settings prompt' &&
    command.sourceInfo?.baseDir?.endsWith('.pi/settings-prompts')
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'project-reincluded' &&
    command.description === 'Project reincluded prompt' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'global-settings' &&
    command.description === 'Global settings prompt' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'global-reincluded' &&
    command.description === 'Global reincluded prompt' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'home-settings' &&
    command.description === 'Home-expanded settings prompt' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'project-package-review' &&
    command.description === 'Project package prompt' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-manifest' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'project-convention-prompt' &&
    command.description === 'Project convention package prompt' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-convention'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'project-filter-keep' &&
    command.description === 'Project filtered package prompt' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-filtered' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'global-package-review' &&
    command.description === 'Global package prompt' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === 'packages/global-manifest' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'ship' &&
    command.source === 'prompt' &&
    command.sourceInfo?.scope === 'temporary'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:brave-search' &&
    command.description === 'Web search via Brave API' &&
    command.source === 'skill' &&
    command.sourceInfo?.baseDir?.endsWith('.pi/agent/skills/brave-search')
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-skill' &&
    command.description === 'Project skill command' &&
    command.sourceInfo?.baseDir?.endsWith('.pi/skills/project-skill')
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:global-skill' &&
    command.description === 'Global skill command' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-settings-skill' &&
    command.description === 'Project settings skill command' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-reincluded-skill' &&
    command.description === 'Project reincluded skill command' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:global-settings-skill' &&
    command.description === 'Global settings skill command' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:global-reincluded-skill' &&
    command.description === 'Global reincluded skill command' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:home-settings-skill' &&
    command.description === 'Home-expanded settings skill command' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-package-skill' &&
    command.description === 'Project package skill command' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-manifest' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-convention-skill' &&
    command.description === 'Project convention package skill command' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-convention'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:project-filter-keep-skill' &&
    command.description === 'Project filtered package skill command' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === '../packages/project-filtered' &&
    command.sourceInfo?.scope === 'project'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:global-package-skill' &&
    command.description === 'Global package skill command' &&
    command.sourceInfo?.origin === 'package' &&
    command.sourceInfo?.source === 'packages/global-manifest' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:external-skill' &&
    command.description === 'External agents skill command' &&
    command.sourceInfo?.scope === 'user'
  ) ||
  !fixtureCommands.commands.some((command) =>
    command.name === 'skill:ship-skill' &&
    command.description === 'Temporary release skill' &&
    command.sourceInfo?.scope === 'temporary'
  )
) {
  throw new Error('commands smoke did not discover project, user, and explicit prompt/skill commands');
}
const unexpectedFixtureCommandNames = new Set([
  'project-excluded',
  'project-force-off',
  'skip-settings',
  'project-plus',
  'project-filter-drop',
  'project-disabled-prompt',
  'global-disabled',
  'global-force-off',
  'global-plus',
  'skill:project-disabled-skill',
  'skill:project-force-off-skill',
  'skill:utility-skill',
  'skill:project-plus-skill',
  'skill:project-filter-drop-skill',
  'skill:project-package-disabled-skill',
  'skill:global-disabled-skill',
  'skill:global-force-off-skill',
  'skill:global-plus-skill'
]);
const unexpectedFixtureCommand = fixtureCommands.commands.find((command) => unexpectedFixtureCommandNames.has(command.name));
if (unexpectedFixtureCommand) {
  throw new Error(`commands smoke returned disabled or pattern-only command ${unexpectedFixtureCommand.name}`);
}
const nestedFixtureCommands = JSON.parse(run(
  ['commands'],
  undefined,
  { cwd: path.join(commandsFixtureRoot, 'workspace/nested'), env: commandsFixtureEnv }
));
if (
  !nestedFixtureCommands.commands.some((command) =>
    command.name === 'skill:ancestor-skill' &&
    command.description === 'Ancestor agents skill command' &&
    command.sourceInfo?.scope === 'project'
  )
) {
  throw new Error('commands smoke did not discover ancestor .agents/skills from nested cwd');
}
const fixtureRpcCommandsOutput = run(
  ['--mode', 'rpc', '--session', 'zig-out/pi-zig-rpc-commands.jsonl', '--skill', 'explicit/skills', '--prompt-template', 'explicit/prompts'],
  `${JSON.stringify({ id: 'cmds', type: 'get_commands' })}\n`,
  { cwd: commandsFixtureRoot, env: commandsFixtureEnv }
);
const fixtureRpcCommands = fixtureRpcCommandsOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const rpcCommandsResponse = fixtureRpcCommands.find((response) => response.id === 'cmds');
if (
  !rpcCommandsResponse?.success ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'fix-tests' && command.source === 'prompt') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'global-review' && command.sourceInfo?.scope === 'user') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'project-settings' && command.sourceInfo?.scope === 'project') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'project-reincluded' && command.sourceInfo?.scope === 'project') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'home-settings' && command.sourceInfo?.scope === 'user') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'project-package-review' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'project-filter-keep' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'global-package-review' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'ship' && command.sourceInfo?.scope === 'temporary') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:brave-search' && command.source === 'skill') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:project-settings-skill' && command.sourceInfo?.scope === 'project') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:project-reincluded-skill' && command.sourceInfo?.scope === 'project') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:project-package-skill' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:project-filter-keep-skill' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:global-package-skill' && command.sourceInfo?.origin === 'package') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:home-settings-skill' && command.sourceInfo?.scope === 'user') ||
  !rpcCommandsResponse.data.commands.some((command) => command.name === 'skill:ship-skill' && command.sourceInfo?.scope === 'temporary')
) {
  throw new Error('rpc get_commands smoke did not return project, user, and explicit prompt/skill commands');
}
const unexpectedRpcCommand = rpcCommandsResponse.data.commands.find((command) => unexpectedFixtureCommandNames.has(command.name));
if (unexpectedRpcCommand) {
  throw new Error(`rpc get_commands smoke returned disabled or pattern-only command ${unexpectedRpcCommand.name}`);
}

const packageCommandRoot = path.resolve('zig-out/pi-zig-package-command-fixture');
const packageCommandHome = path.join(packageCommandRoot, 'home');
const packageCommandProject = path.join(packageCommandRoot, 'project');
const packageCommandGlobalPackage = path.join(packageCommandProject, 'packages/global-local');
const packageCommandProjectPackage = path.join(packageCommandProject, 'packages/project-local');
const packageCommandFakeBin = path.join(packageCommandRoot, 'fake-bin');
const packageCommandRecord = path.join(packageCommandRoot, 'commands.jsonl');
const packageCommandEnv = {
  ...process.env,
  HOME: packageCommandHome,
  PATH: `${packageCommandFakeBin}${path.delimiter}${process.env.PATH ?? ''}`,
  PI_ZIG_FAKE_COMMAND_RECORD: packageCommandRecord
};
fs.rmSync(packageCommandRoot, { recursive: true, force: true });
fs.mkdirSync(packageCommandGlobalPackage, { recursive: true });
fs.mkdirSync(packageCommandProjectPackage, { recursive: true });
fs.mkdirSync(packageCommandFakeBin, { recursive: true });
fs.writeFileSync(
  path.join(packageCommandFakeBin, 'npm'),
  `#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.PI_ZIG_FAKE_COMMAND_RECORD, JSON.stringify({ command: 'npm', args, cwd: process.cwd() }) + '\\n');
function optionValue(name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}
function packageName(spec) {
  const start = spec.startsWith('@') ? 1 : 0;
  const at = spec.lastIndexOf('@');
  return at > start ? spec.slice(0, at) : spec;
}
const root = optionValue('--prefix') || optionValue('--cwd') || process.cwd();
if (args[0] === 'install') {
  fs.mkdirSync(path.join(root, 'node_modules'), { recursive: true });
  for (const spec of args.slice(1)) {
    if (spec.startsWith('--')) break;
    const name = packageName(spec);
    if (!name) continue;
    const packageDir = path.join(root, 'node_modules', ...name.split('/'));
    fs.mkdirSync(packageDir, { recursive: true });
    fs.writeFileSync(path.join(packageDir, 'package.json'), JSON.stringify({ name, version: spec.includes('@latest') ? 'latest' : '1.0.0' }));
  }
  process.exit(0);
}
if (args[0] === 'uninstall') {
  const name = args[1];
  if (name) fs.rmSync(path.join(root, 'node_modules', ...name.split('/')), { recursive: true, force: true });
  process.exit(0);
}
process.exit(0);
`
);
fs.chmodSync(path.join(packageCommandFakeBin, 'npm'), 0o755);
fs.writeFileSync(
  path.join(packageCommandFakeBin, 'git'),
  `#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.PI_ZIG_FAKE_COMMAND_RECORD, JSON.stringify({ command: 'git', args, cwd: process.cwd() }) + '\\n');
if (args[0] === 'clone') {
  const target = args[2];
  fs.mkdirSync(path.join(target, '.git'), { recursive: true });
  fs.writeFileSync(path.join(target, 'extension.js'), 'fake git extension');
}
process.exit(0);
`
);
fs.chmodSync(path.join(packageCommandFakeBin, 'git'), 0o755);
if (!run(['list'], undefined, { cwd: packageCommandProject, env: packageCommandEnv }).includes('No packages installed.')) {
  throw new Error('package list smoke did not report an empty package set');
}
const packageInstallHelp = run(['install', '--help'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (!packageInstallHelp.includes('pi-zig install <source> [-l]')) {
  throw new Error('package install help smoke did not print usage');
}
run(['install', './packages/global-local'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['install', './packages/project-local', '--local'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
const globalPackageSettingsPath = path.join(packageCommandHome, '.pi/agent/settings.json');
const projectPackageSettingsPath = path.join(packageCommandProject, '.pi/settings.json');
const globalPackageSettings = JSON.parse(fs.readFileSync(globalPackageSettingsPath, 'utf8'));
const projectPackageSettings = JSON.parse(fs.readFileSync(projectPackageSettingsPath, 'utf8'));
if (
  path.resolve(path.dirname(globalPackageSettingsPath), globalPackageSettings.packages?.[0] ?? '') !== packageCommandGlobalPackage ||
  path.resolve(path.dirname(projectPackageSettingsPath), projectPackageSettings.packages?.[0] ?? '') !== packageCommandProjectPackage
) {
  throw new Error('package install smoke did not persist local package paths relative to the selected settings file');
}
const packageList = run(['list'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (
  !packageList.includes('User packages:') ||
  !packageList.includes('Project packages:') ||
  !packageList.includes(packageCommandGlobalPackage) ||
  !packageList.includes(packageCommandProjectPackage)
) {
  throw new Error('package list smoke did not show user and project local packages with installed paths');
}
run(['remove', `${packageCommandGlobalPackage}/`], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['uninstall', './packages/project-local', '-l'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (
  (JSON.parse(fs.readFileSync(globalPackageSettingsPath, 'utf8')).packages ?? []).length !== 0 ||
  (JSON.parse(fs.readFileSync(projectPackageSettingsPath, 'utf8')).packages ?? []).length !== 0
) {
  throw new Error('package remove smoke did not clear matching user and project packages');
}

run(['install', 'npm:fake-extension'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['install', 'git:github.com/example/fake-extension', '--local'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
const npmInstallPath = path.join(packageCommandHome, '.pi/agent/npm/node_modules/fake-extension/package.json');
const gitInstallPath = path.join(packageCommandProject, '.pi/git/github.com/example/fake-extension/extension.js');
if (!fs.existsSync(npmInstallPath) || !fs.existsSync(gitInstallPath)) {
  throw new Error('package npm/git install smoke did not create managed install paths');
}
const packageManagedList = run(['list'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (
  !packageManagedList.includes(path.join(packageCommandHome, '.pi/agent/npm/node_modules/fake-extension')) ||
  !packageManagedList.includes(path.join(packageCommandProject, '.pi/git/github.com/example/fake-extension'))
) {
  throw new Error('package list smoke did not show managed npm and git install paths');
}
run(['update', '--extension', 'git:github.com/example/fake-extension'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['update', '--extensions'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
const packageCommandRecords = fs.readFileSync(packageCommandRecord, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
if (
  !packageCommandRecords.some((record) => record.command === 'npm' && record.args.includes('fake-extension@latest')) ||
  !packageCommandRecords.some((record) => record.command === 'git' && record.args[0] === 'fetch') ||
  !packageCommandRecords.some((record) => record.command === 'git' && record.args[0] === 'reset')
) {
  throw new Error('package update smoke did not run managed npm latest and git reconciliation commands');
}
run(['remove', 'npm:fake-extension'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
run(['remove', 'git:github.com/example/fake-extension', '--local'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (fs.existsSync(npmInstallPath) || fs.existsSync(gitInstallPath)) {
  throw new Error('package remove smoke did not remove managed npm and git installs');
}
const packageSelfUpdateFailure = runFail(['update', '--self', '--force'], undefined, { cwd: packageCommandProject, env: packageCommandEnv });
if (packageSelfUpdateFailure.status === 0 || !packageSelfUpdateFailure.stderr.includes('self-update is not implemented yet')) {
  throw new Error('package self-update smoke did not fail visibly for the unimplemented self updater');
}

const authFixtureRoot = path.resolve('zig-out/pi-zig-auth-fixture');
const authFixtureHome = path.join(authFixtureRoot, 'home');
const authFixtureEnv = {
  ...process.env,
  HOME: authFixtureHome,
  OPENAI_API_KEY: 'env-openai-key'
};
fs.rmSync(authFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(authFixtureHome, { recursive: true });
const emptyAuthList = JSON.parse(run(['auth', 'list', '--json'], undefined, { env: authFixtureEnv }));
if (emptyAuthList.providers.length !== 0) {
  throw new Error('auth list smoke did not start with an empty auth store');
}
const authProviders = JSON.parse(run(['auth', 'providers', '--json'], undefined, { env: authFixtureEnv }));
if (
  !authProviders.providers.some((provider) => provider.id === 'anthropic') ||
  !authProviders.providers.some((provider) => provider.id === 'github-copilot') ||
  !authProviders.providers.some((provider) => provider.id === 'openai-codex')
) {
  throw new Error('auth providers smoke did not expose upstream built-in OAuth providers');
}
const envOpenAiStatus = JSON.parse(run(['auth', 'status', 'openai', '--json'], undefined, { env: authFixtureEnv }));
if (envOpenAiStatus.hasAuth !== true || envOpenAiStatus.source !== 'environment' || envOpenAiStatus.label !== 'OPENAI_API_KEY') {
  throw new Error('auth status smoke did not report provider environment fallback');
}
run(['auth', 'set-api-key', 'openai', '!printf command-openai-key'], undefined, { env: authFixtureEnv });
const storedOpenAiStatus = JSON.parse(run(['auth', 'status', 'openai', '--json'], undefined, { env: authFixtureEnv }));
if (storedOpenAiStatus.configured !== true || storedOpenAiStatus.source !== 'stored' || storedOpenAiStatus.type !== 'api_key') {
  throw new Error('auth status smoke did not report stored API key credential');
}
const resolvedOpenAi = JSON.parse(run(['auth', 'resolve', 'openai', '--json'], undefined, { env: authFixtureEnv }));
if (resolvedOpenAi.value !== 'command-openai-key') {
  throw new Error('auth resolve smoke did not execute ! command API key');
}
run(['auth', 'set-api-key', 'groq', 'GROQ_API_KEY'], undefined, { env: { ...authFixtureEnv, GROQ_API_KEY: 'env-groq-key' } });
const resolvedGroq = JSON.parse(run(['auth', 'resolve', 'groq', '--json'], undefined, { env: { ...authFixtureEnv, GROQ_API_KEY: 'env-groq-key' } }));
if (resolvedGroq.value !== 'env-groq-key') {
  throw new Error('auth resolve smoke did not resolve stored env-var API key');
}
run(['auth', 'set-oauth', 'openai-codex', 'oauth-access', 'oauth-refresh', '4102444800000'], undefined, { env: authFixtureEnv });
const oauthOpenAiCodex = JSON.parse(run(['auth', 'resolve', 'openai-codex', '--json'], undefined, { env: authFixtureEnv }));
if (oauthOpenAiCodex.value !== 'oauth-access') {
  throw new Error('auth resolve smoke did not return unexpired OAuth access token');
}
run(['auth', 'set-oauth', 'anthropic', 'expired-access', 'expired-refresh', '1'], undefined, { env: authFixtureEnv });
const expiredAnthropic = run(['auth', 'resolve', 'anthropic', '--json'], undefined, { env: authFixtureEnv });
if (!expiredAnthropic.includes('"resolved":false') || !expiredAnthropic.includes('"value":null')) {
  throw new Error('auth resolve smoke did not fail visibly for expired OAuth refresh gap');
}
run(['auth', 'remove', 'openai'], undefined, { env: authFixtureEnv });
const postRemoveAuthStatus = JSON.parse(run(['auth', 'status', 'openai', '--json'], undefined, { env: authFixtureEnv }));
if (postRemoveAuthStatus.source !== 'environment' || postRemoveAuthStatus.configured !== false) {
  throw new Error('auth remove smoke did not remove stored credential and reveal env fallback');
}

const extensionsFixtureRoot = path.resolve('zig-out/pi-zig-extensions-fixture');
const extensionsFixtureHome = path.join(extensionsFixtureRoot, 'home');
const extensionsFixtureProject = path.join(extensionsFixtureRoot, 'project');
const extensionsFixtureEnv = { ...process.env, HOME: extensionsFixtureHome };
fs.rmSync(extensionsFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(extensionsFixtureProject, '.pi/extensions/prefer-index'), { recursive: true });
fs.mkdirSync(path.join(extensionsFixtureProject, '.pi/extensions/manifest/src'), { recursive: true });
fs.mkdirSync(path.join(extensionsFixtureProject, 'packages/ext-package'), { recursive: true });
fs.mkdirSync(path.join(extensionsFixtureProject, 'packages/disabled-package/extensions'), { recursive: true });
fs.mkdirSync(path.join(extensionsFixtureProject, 'explicit-package'), { recursive: true });
fs.mkdirSync(path.join(extensionsFixtureHome, '.pi/agent/extensions'), { recursive: true });
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/direct.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/drop.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/prefer-index/index.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/prefer-index/index.js'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/manifest/src/main.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/extensions/manifest/package.json'), JSON.stringify({ pi: { extensions: ['./src/main.ts', './missing.ts'] } }));
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/settings-ext.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, '.pi/settings.json'), JSON.stringify({
  extensions: ['./settings-ext.ts', '!drop.ts'],
  packages: [
    { source: '../packages/ext-package', extensions: ['entry.ts'] },
    { source: '../packages/disabled-package', extensions: [] }
  ]
}, null, 2));
fs.writeFileSync(path.join(extensionsFixtureProject, 'packages/ext-package/package.json'), JSON.stringify({ pi: { extensions: ['./entry.ts'] } }));
fs.writeFileSync(path.join(extensionsFixtureProject, 'packages/ext-package/entry.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, 'packages/disabled-package/extensions/disabled.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureProject, 'explicit-package/package.json'), JSON.stringify({ pi: { extensions: ['./custom.ts'] } }));
fs.writeFileSync(path.join(extensionsFixtureProject, 'explicit-package/custom.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureHome, '.pi/agent/global-settings.ts'), 'export default function(){}');
fs.writeFileSync(path.join(extensionsFixtureHome, '.pi/agent/settings.json'), JSON.stringify({ extensions: ['./global-settings.ts'] }, null, 2));
fs.writeFileSync(path.join(extensionsFixtureHome, '.pi/agent/extensions/global.ts'), 'export default function(){}');
const extensions = JSON.parse(run(
  ['extensions', '--json', '--extension', './explicit-package'],
  undefined,
  { cwd: extensionsFixtureProject, env: extensionsFixtureEnv }
)).extensions;
function extensionEntry(suffix, predicate = () => true) {
  return extensions.find((entry) => entry.path.endsWith(suffix) && predicate(entry));
}
if (
  !extensionEntry('/.pi/settings-ext.ts', (entry) => entry.sourceInfo.source === 'local' && entry.sourceInfo.scope === 'project') ||
  !extensionEntry('/.pi/extensions/direct.ts', (entry) => entry.enabled === true && entry.sourceInfo.source === 'auto') ||
  !extensionEntry('/.pi/extensions/drop.ts', (entry) => entry.enabled === false) ||
  !extensionEntry('/.pi/extensions/prefer-index/index.ts') ||
  extensionEntry('/.pi/extensions/prefer-index/index.js') ||
  !extensionEntry('/.pi/extensions/manifest/src/main.ts') ||
  !extensionEntry('/.pi/agent/global-settings.ts', (entry) => entry.sourceInfo.source === 'local' && entry.sourceInfo.scope === 'user') ||
  !extensionEntry('/.pi/agent/extensions/global.ts', (entry) => entry.sourceInfo.source === 'auto' && entry.sourceInfo.scope === 'user') ||
  !extensionEntry('/packages/ext-package/entry.ts', (entry) => entry.sourceInfo.origin === 'package') ||
  !extensionEntry('/packages/disabled-package/extensions/disabled.ts', (entry) => entry.enabled === false) ||
  !extensionEntry('/explicit-package/custom.ts', (entry) => entry.sourceInfo.source === 'cli' && entry.sourceInfo.scope === 'temporary')
) {
  throw new Error('extensions smoke did not match upstream discovery order, manifests, settings, package filters, and explicit paths');
}
const explicitOnlyExtensions = JSON.parse(run(
  ['extensions', '--json', '--no-extensions', '--extension', './explicit-package'],
  undefined,
  { cwd: extensionsFixtureProject, env: extensionsFixtureEnv }
)).extensions;
if (explicitOnlyExtensions.length !== 1 || !explicitOnlyExtensions[0].path.endsWith('/explicit-package/custom.ts')) {
  throw new Error('extensions --no-extensions smoke did not keep explicit extension paths only');
}

const settingsFixtureRoot = path.resolve('zig-out/pi-zig-settings-fixture');
const settingsFixtureHome = path.join(settingsFixtureRoot, 'home');
const settingsFixtureProject = path.join(settingsFixtureRoot, 'project');
const settingsFixtureNoPiProject = path.join(settingsFixtureRoot, 'no-pi-project');
const settingsFixtureEnv = { ...process.env, HOME: settingsFixtureHome };
fs.rmSync(settingsFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(settingsFixtureHome, '.pi/agent'), { recursive: true });
fs.mkdirSync(path.join(settingsFixtureProject, '.pi'), { recursive: true });
fs.mkdirSync(settingsFixtureNoPiProject, { recursive: true });
fs.writeFileSync(
  path.join(settingsFixtureHome, '.pi/agent/settings.json'),
  JSON.stringify({
    queueMode: 'all',
    websockets: false,
    skills: {
      enableSkillCommands: false,
      customDirectories: ['legacy-skills']
    },
    retry: {
      maxDelayMs: 1234,
      maxRetries: 4
    },
    compaction: {
      reserveTokens: 111
    },
    enabledModels: ['claude-opus-4-5', 'gpt-5.2-codex'],
    httpIdleTimeoutMs: 'disabled',
    sessionDir: '~/sessions'
  }, null, 2)
);
fs.writeFileSync(
  path.join(settingsFixtureProject, '.pi/settings.json'),
  JSON.stringify({
    websockets: true,
    theme: 'dark',
    compaction: {
      keepRecentTokens: 222
    },
    branchSummary: {
      skipPrompt: true
    }
  }, null, 2)
);
const settingsReport = JSON.parse(run(['settings', '--json'], undefined, { cwd: settingsFixtureProject, env: settingsFixtureEnv }));
if (
  settingsReport.globalSettings.queueMode !== undefined ||
  settingsReport.globalSettings.websockets !== undefined ||
  settingsReport.globalSettings.steeringMode !== 'all' ||
  settingsReport.globalSettings.transport !== 'sse' ||
  settingsReport.globalSettings.enableSkillCommands !== false ||
  settingsReport.globalSettings.skills?.[0] !== 'legacy-skills' ||
  settingsReport.globalSettings.retry?.maxDelayMs !== undefined ||
  settingsReport.globalSettings.retry?.provider?.maxRetryDelayMs !== 1234 ||
  settingsReport.settings.transport !== 'websocket' ||
  settingsReport.settings.compaction?.reserveTokens !== 111 ||
  settingsReport.settings.compaction?.keepRecentTokens !== 222 ||
  settingsReport.resolved.followUpMode !== 'one-at-a-time' ||
  settingsReport.resolved.compaction?.enabled !== true ||
  settingsReport.resolved.retry?.maxRetries !== 4 ||
  settingsReport.resolved.retry?.baseDelayMs !== 2000 ||
  settingsReport.resolved.retry?.provider?.maxRetryDelayMs !== 1234 ||
  settingsReport.resolved.branchSummary?.skipPrompt !== true ||
  settingsReport.resolved.httpIdleTimeoutMs !== 0 ||
  settingsReport.resolved.sessionDir !== path.join(settingsFixtureHome, 'sessions') ||
  settingsReport.resolved.enableSkillCommands !== false
) {
  throw new Error('settings smoke did not migrate, merge, and resolve upstream settings defaults');
}
const settingsGet = JSON.parse(run(['settings', 'get', 'resolved.compaction.keepRecentTokens'], undefined, {
  cwd: settingsFixtureProject,
  env: settingsFixtureEnv
}));
if (settingsGet !== 222) {
  throw new Error('settings get smoke did not read a resolved dotted value');
}
run(['settings', 'set-model', 'openai', 'gpt-4o'], undefined, { cwd: settingsFixtureProject, env: settingsFixtureEnv });
const settingsGlobalAfterModel = JSON.parse(fs.readFileSync(path.join(settingsFixtureHome, '.pi/agent/settings.json'), 'utf8'));
if (
  settingsGlobalAfterModel.defaultProvider !== 'openai' ||
  settingsGlobalAfterModel.defaultModel !== 'gpt-4o' ||
  settingsGlobalAfterModel.enabledModels?.[1] !== 'gpt-5.2-codex'
) {
  throw new Error('settings set-model smoke did not preserve unrelated global settings');
}
run(['settings', 'set', 'theme', 'light', '--local'], undefined, { cwd: settingsFixtureProject, env: settingsFixtureEnv });
const settingsProjectAfterTheme = JSON.parse(fs.readFileSync(path.join(settingsFixtureProject, '.pi/settings.json'), 'utf8'));
if (settingsProjectAfterTheme.theme !== 'light' || settingsProjectAfterTheme.compaction?.keepRecentTokens !== 222) {
  throw new Error('settings set --local smoke did not preserve unrelated project settings');
}
run(['settings', '--json'], undefined, { cwd: settingsFixtureNoPiProject, env: settingsFixtureEnv });
if (fs.existsSync(path.join(settingsFixtureNoPiProject, '.pi'))) {
  throw new Error('settings read smoke created a project .pi directory');
}
const invalidSettingsHome = path.join(settingsFixtureRoot, 'invalid-home');
fs.mkdirSync(path.join(invalidSettingsHome, '.pi/agent'), { recursive: true });
fs.writeFileSync(path.join(invalidSettingsHome, '.pi/agent/settings.json'), '{ invalid json');
const invalidRead = JSON.parse(run(['settings', '--json'], undefined, {
  cwd: settingsFixtureProject,
  env: { ...process.env, HOME: invalidSettingsHome }
}));
if (!invalidRead.errors.some((error) => error.scope === 'global')) {
  throw new Error('settings invalid-read smoke did not report a global load error');
}
const invalidWrite = runFail(['settings', 'set', 'theme', 'dark'], undefined, {
  cwd: settingsFixtureProject,
  env: { ...process.env, HOME: invalidSettingsHome }
});
if (invalidWrite.status === 0 || !invalidWrite.stderr.includes('Refusing to overwrite invalid settings file')) {
  throw new Error('settings invalid-write smoke did not refuse to overwrite invalid JSON');
}

const themeFixtureRoot = path.resolve('zig-out/pi-zig-theme-fixture');
const themeFixtureHome = path.join(themeFixtureRoot, 'home');
const themeFixtureEnv = { ...process.env, HOME: themeFixtureHome };
fs.rmSync(themeFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(themeFixtureRoot, '.pi/themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureRoot, '.pi/settings-themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureHome, '.pi/agent/themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureRoot, 'explicit-themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureRoot, 'packages/theme-convention/themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureRoot, 'packages/theme-manifest/themes'), { recursive: true });
fs.mkdirSync(path.join(themeFixtureRoot, 'packages/theme-disabled/themes'), { recursive: true });
const darkTheme = JSON.parse(fs.readFileSync('src/pi/themes/dark.json', 'utf8'));
const userNamedTheme = { ...darkTheme, name: 'bar' };
const settingsNamedTheme = { ...darkTheme, name: 'settings-theme' };
const explicitTheme = { ...darkTheme, name: 'explicit-theme' };
const packageNiceTheme = { ...darkTheme, name: 'package-nice' };
const packageUglyTheme = { ...darkTheme, name: 'package-ugly' };
const packageManifestTheme = { ...darkTheme, name: 'package-manifest' };
const packageDropTheme = { ...darkTheme, name: 'package-drop' };
const packageDisabledTheme = { ...darkTheme, name: 'package-disabled' };
const recursiveExportTheme = {
  ...darkTheme,
  name: 'custom-export-recursive',
  vars: {
    ...(darkTheme.vars ?? {}),
    deepPageBg: '#abcdef',
    pageBgAlias: 'deepPageBg',
    cardBgAnsi: 24
  },
  export: {
    pageBg: 'pageBgAlias',
    cardBg: 'cardBgAnsi',
    infoBg: ''
  }
};
fs.writeFileSync(path.join(themeFixtureHome, '.pi/agent/themes/foo.json'), JSON.stringify(userNamedTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, '.pi/settings-themes/settings.json'), JSON.stringify(settingsNamedTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, '.pi/themes/custom-export-recursive.json'), JSON.stringify(recursiveExportTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, 'explicit-themes/explicit.json'), JSON.stringify(explicitTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, 'packages/theme-convention/themes/nice.json'), JSON.stringify(packageNiceTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, 'packages/theme-convention/themes/ugly.json'), JSON.stringify(packageUglyTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, 'packages/theme-manifest/themes/manifest.json'), JSON.stringify(packageManifestTheme, null, 2));
fs.writeFileSync(path.join(themeFixtureRoot, 'packages/theme-manifest/themes/drop.json'), JSON.stringify(packageDropTheme, null, 2));
fs.writeFileSync(
  path.join(themeFixtureRoot, 'packages/theme-manifest/package.json'),
  JSON.stringify({ name: 'theme-manifest', pi: { themes: ['themes/*.json', '!themes/drop.json'] } }, null, 2)
);
fs.writeFileSync(path.join(themeFixtureRoot, 'packages/theme-disabled/themes/disabled.json'), JSON.stringify(packageDisabledTheme, null, 2));
fs.writeFileSync(
  path.join(themeFixtureRoot, '.pi/settings.json'),
  JSON.stringify({
    themes: ['settings-themes'],
    packages: [
      { source: '../packages/theme-convention', themes: ['!ugly.json'] },
      '../packages/theme-manifest',
      { source: '../packages/theme-disabled', themes: [] }
    ]
  }, null, 2)
);
const themes = JSON.parse(run(['themes', '--theme', 'explicit-themes'], undefined, { cwd: themeFixtureRoot, env: themeFixtureEnv }));
if (
  !themes.themes.some((theme) => theme.name === 'dark' && theme.source === 'builtin') ||
  !themes.themes.some((theme) => theme.name === 'bar' && theme.source === 'user') ||
  themes.themes.some((theme) => theme.name === 'foo') ||
  !themes.themes.some((theme) => theme.name === 'settings-theme' && theme.source === 'project') ||
  !themes.themes.some((theme) => theme.name === 'package-nice' && theme.source === 'package') ||
  themes.themes.some((theme) => theme.name === 'package-ugly') ||
  !themes.themes.some((theme) => theme.name === 'package-manifest' && theme.source === 'package') ||
  themes.themes.some((theme) => theme.name === 'package-drop') ||
  themes.themes.some((theme) => theme.name === 'package-disabled') ||
  !themes.themes.some((theme) => theme.name === 'explicit-theme' && theme.source === 'temporary')
) {
  throw new Error('themes smoke did not discover builtin, content-named custom, settings, package, and temporary themes with filters');
}
const noThemes = JSON.parse(run(['themes', '--no-themes'], undefined, { cwd: themeFixtureRoot, env: themeFixtureEnv }));
if (noThemes.themes.some((theme) => theme.name === 'bar' || theme.name === 'settings-theme')) {
  throw new Error('themes --no-themes smoke did not suppress user/project theme discovery');
}
const themeExport = JSON.parse(run(['themes', '--export', 'custom-export-recursive'], undefined, { cwd: themeFixtureRoot, env: themeFixtureEnv }));
if (
  themeExport.export.pageBg !== '#abcdef' ||
  themeExport.export.cardBg !== '#005f87' ||
  Object.prototype.hasOwnProperty.call(themeExport.export, 'infoBg')
) {
  throw new Error('themes export smoke did not resolve recursive variables, ANSI colors, and empty values');
}
const resolvedLight = JSON.parse(run(['themes', '--resolved', 'light'], undefined, { cwd: themeFixtureRoot, env: themeFixtureEnv }));
if (resolvedLight.colors.accent !== '#5a8080' || resolvedLight.colors.text !== '#1f2328') {
  throw new Error('themes resolved smoke did not expose built-in light colors as hex values');
}
const detectedLight = JSON.parse(run(['themes', '--detect'], undefined, {
  cwd: themeFixtureRoot,
  env: { ...themeFixtureEnv, COLORFGBG: '0;7;15' }
}));
const detectedDark = JSON.parse(run(['themes', '--detect'], undefined, {
  cwd: themeFixtureRoot,
  env: { ...themeFixtureEnv, COLORFGBG: '15;0' }
}));
if (detectedLight.theme !== 'light' || detectedLight.source !== 'COLORFGBG' || detectedDark.theme !== 'dark') {
  throw new Error('themes detect smoke did not classify COLORFGBG background colors');
}

const contextFixtureRoot = path.resolve('zig-out/pi-zig-context-fixture');
const contextFixtureHome = path.join(contextFixtureRoot, 'home');
const contextFixtureChild = path.join(contextFixtureRoot, 'workspace/parent/child');
const contextFixtureEnv = { ...process.env, HOME: contextFixtureHome };
fs.rmSync(contextFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(contextFixtureHome, '.pi/agent'), { recursive: true });
fs.mkdirSync(path.join(contextFixtureChild, '.pi'), { recursive: true });
fs.mkdirSync(path.join(contextFixtureRoot, 'workspace'), { recursive: true });
fs.writeFileSync(path.join(contextFixtureHome, '.pi/agent/AGENTS.md'), '# Global Agent\n\nUse global instructions.');
fs.writeFileSync(path.join(contextFixtureHome, '.pi/agent/CLAUDE.md'), '# Global Claude\n\nThis should lose to AGENTS.');
fs.writeFileSync(path.join(contextFixtureHome, '.pi/agent/SYSTEM.md'), 'Global system prompt.');
fs.writeFileSync(path.join(contextFixtureHome, '.pi/agent/APPEND_SYSTEM.md'), 'Global append prompt.');
fs.writeFileSync(path.join(contextFixtureRoot, 'AGENTS.md'), '# Fixture Root\n\nUse root project instructions.');
fs.writeFileSync(path.join(contextFixtureRoot, 'workspace/CLAUDE.md'), '# Workspace Claude\n\nUse workspace instructions.');
fs.writeFileSync(path.join(contextFixtureChild, 'AGENTS.md'), '# Child Agent\n\nUse child instructions.');
fs.writeFileSync(path.join(contextFixtureChild, 'CLAUDE.md'), '# Child Claude\n\nThis should lose to AGENTS.');
fs.writeFileSync(path.join(contextFixtureChild, '.pi/SYSTEM.md'), 'Project system prompt.');
fs.writeFileSync(path.join(contextFixtureChild, '.pi/APPEND_SYSTEM.md'), 'Project append prompt.');
const contextFiles = JSON.parse(run(['context-files'], undefined, { cwd: contextFixtureChild, env: contextFixtureEnv }));
if (
  contextFiles.contextFilesEnabled !== true ||
  contextFiles.contextFiles.length !== 4 ||
  !contextFiles.contextFiles[0].path.endsWith('home/.pi/agent/AGENTS.md') ||
  !contextFiles.contextFiles[1].path.endsWith('pi-zig-context-fixture/AGENTS.md') ||
  !contextFiles.contextFiles[2].path.endsWith('workspace/CLAUDE.md') ||
  !contextFiles.contextFiles[3].path.endsWith('workspace/parent/child/AGENTS.md') ||
  contextFiles.contextFiles.some((file) => file.content.includes('should lose to AGENTS')) ||
  contextFiles.systemPrompt?.content !== 'Project system prompt.' ||
  !contextFiles.systemPrompt?.path.endsWith('workspace/parent/child/.pi/SYSTEM.md') ||
  contextFiles.appendSystemPrompt?.content !== 'Project append prompt.'
) {
  throw new Error('context-files smoke did not match upstream AGENTS/CLAUDE ordering and project system prompt discovery');
}
const noContextFiles = JSON.parse(run(['context-files', '--no-context-files'], undefined, { cwd: contextFixtureChild, env: contextFixtureEnv }));
if (
  noContextFiles.contextFilesEnabled !== false ||
  noContextFiles.contextFiles.length !== 0 ||
  noContextFiles.systemPrompt?.content !== 'Project system prompt.' ||
  noContextFiles.appendSystemPrompt?.content !== 'Project append prompt.'
) {
  throw new Error('context-files --no-context-files smoke suppressed system prompt discovery or kept context files');
}
const contextFallbackCwd = path.join(contextFixtureRoot, 'fallback-project');
fs.mkdirSync(contextFallbackCwd, { recursive: true });
const contextFallback = JSON.parse(run(['context-files', '--no-context-files'], undefined, { cwd: contextFallbackCwd, env: contextFixtureEnv }));
if (
  contextFallback.systemPrompt?.content !== 'Global system prompt.' ||
  !contextFallback.systemPrompt?.path.endsWith('home/.pi/agent/SYSTEM.md') ||
  contextFallback.appendSystemPrompt?.content !== 'Global append prompt.'
) {
  throw new Error('context-files smoke did not fall back to global system prompt files');
}
const upstreamCodingAgentPackageDir = path.resolve('upstream/pi/packages/coding-agent');
const systemPrompt = JSON.parse(run(
  [
    'system-prompt',
    '--json',
    '--date',
    '2026-05-26',
    '--package-dir',
    upstreamCodingAgentPackageDir,
    '--guideline',
    'Use dynamic_tool for summaries.',
    '--guideline',
    '  Use dynamic_tool for summaries.  '
  ],
  undefined,
  { cwd: contextFixtureChild, env: contextFixtureEnv }
));
if (
  systemPrompt.contextFileCount !== 4 ||
  systemPrompt.hasSystemPrompt !== true ||
  systemPrompt.hasAppendSystemPrompt !== true ||
  !systemPrompt.prompt.startsWith('Project system prompt.\n\nProject append prompt.') ||
  !systemPrompt.prompt.includes('<project_context>') ||
  !systemPrompt.prompt.includes('home/.pi/agent/AGENTS.md') ||
  !systemPrompt.prompt.includes('Use root project instructions.') ||
  !systemPrompt.prompt.includes('Use workspace instructions.') ||
  !systemPrompt.prompt.includes('Use child instructions.') ||
  systemPrompt.prompt.includes('should lose to AGENTS') ||
  !systemPrompt.prompt.includes('Current date: 2026-05-26') ||
  !systemPrompt.prompt.includes(`Current working directory: ${contextFixtureChild}`)
) {
  throw new Error('system-prompt smoke did not assemble custom system prompt, append text, context files, date, and cwd');
}
const defaultSystemPrompt = JSON.parse(run(
  ['system-prompt', '--json', '--date', '2026-05-26', '--package-dir', upstreamCodingAgentPackageDir, '--no-context-files', '--no-tools'],
  undefined,
  { cwd: contextFallbackCwd, env: { ...contextFixtureEnv, PI_CODING_AGENT_DIR: path.join(contextFixtureRoot, 'empty-agent') } }
));
if (
  !defaultSystemPrompt.prompt.includes('Available tools:\n(none)') ||
  !defaultSystemPrompt.prompt.includes(`Main documentation: ${upstreamCodingAgentPackageDir}/README.md`) ||
  !defaultSystemPrompt.prompt.includes('Show file paths clearly when working with files') ||
  !defaultSystemPrompt.prompt.includes('Current date: 2026-05-26') ||
  defaultSystemPrompt.contextFileCount !== 0 ||
  defaultSystemPrompt.hasSystemPrompt !== false
) {
  throw new Error('system-prompt default smoke did not match upstream empty-tools/default-docs behavior');
}
const guidelineSystemPrompt = JSON.parse(run(
  [
    'system-prompt',
    '--json',
    '--date',
    '2026-05-26',
    '--package-dir',
    upstreamCodingAgentPackageDir,
    '--no-context-files',
    '--tools',
    'read,dynamic_tool',
    '--guideline',
    'Use dynamic_tool for summaries.',
    '--guideline',
    '  Use dynamic_tool for summaries.  '
  ],
  undefined,
  { cwd: contextFallbackCwd, env: { ...contextFixtureEnv, PI_CODING_AGENT_DIR: path.join(contextFixtureRoot, 'empty-agent') } }
));
if (
  !guidelineSystemPrompt.prompt.includes('- read: Read file contents') ||
  guidelineSystemPrompt.prompt.includes('dynamic_tool:') ||
  (guidelineSystemPrompt.prompt.match(/- Use dynamic_tool for summaries\./g) ?? []).length !== 1
) {
  throw new Error('system-prompt guideline smoke did not include read metadata, omit unsnippeted custom tools, and dedupe guidelines');
}

const anthropicEnv = JSON.parse(run(['provider-env', 'anthropic']));
if (!anthropicEnv.envKeys.includes('ANTHROPIC_OAUTH_TOKEN') || !anthropicEnv.envKeys.includes('ANTHROPIC_API_KEY')) {
  throw new Error('provider-env smoke missing anthropic env keys');
}

const providers = JSON.parse(run(['providers']));
if (providers.providers.length !== 32 || !providers.providers.includes('anthropic') || !providers.providers.includes('openai')) {
  throw new Error('providers smoke did not expose full upstream model provider list');
}

const modelCatalog = JSON.parse(run(['models']));
if (
  modelCatalog.totalModels !== 924 ||
  modelCatalog.providers.length !== 32 ||
  !modelCatalog.models.some((model) => model.provider === 'anthropic' && model.id === 'claude-haiku-4-5')
) {
  throw new Error('models smoke did not expose full upstream generated catalog');
}

const anthropicModels = JSON.parse(run(['models-for', 'anthropic']));
if (!anthropicModels.models.some((model) => model.id === 'claude-haiku-4-5')) {
  throw new Error('models-for smoke did not include anthropic claude-haiku-4-5');
}

const haiku = JSON.parse(run(['model', 'anthropic', 'claude-haiku-4-5']));
if (
  haiku.provider !== 'anthropic' ||
  haiku.id !== 'claude-haiku-4-5' ||
  haiku.name !== 'Claude Haiku 4.5 (latest)' ||
  haiku.api !== 'anthropic-messages' ||
  haiku.reasoning !== true ||
  haiku.contextWindow !== 200000 ||
  !haiku.input.includes('image')
) {
  throw new Error('model smoke did not return expected upstream model metadata');
}

const listedHaiku = JSON.parse(run(['list-models', 'haiku']));
if (listedHaiku.count < 10 || !listedHaiku.models.some((model) => model.provider === 'anthropic' && model.id === 'claude-haiku-4-5')) {
  throw new Error('list-models smoke did not fuzzy-search model provider/id/name');
}

const topLevelListedHaiku = JSON.parse(run(['--list-models', 'haiku']));
if (
  topLevelListedHaiku.count !== listedHaiku.count ||
  !topLevelListedHaiku.models.some((model) => model.provider === 'anthropic' && model.id === 'claude-haiku-4-5')
) {
  throw new Error('top-level --list-models smoke did not route through upstream-style CLI parsing');
}

const resolvedProviderModel = JSON.parse(run(['resolve-model', 'openai/gpt-4o']));
if (
  resolvedProviderModel.error !== null ||
  resolvedProviderModel.model?.provider !== 'openai' ||
  resolvedProviderModel.model?.id !== 'gpt-4o'
) {
  throw new Error('resolve-model smoke did not resolve provider/model syntax');
}

const resolvedThinking = JSON.parse(run(['resolve-model', '--provider', 'anthropic', 'haiku:high']));
if (
  resolvedThinking.error !== null ||
  resolvedThinking.thinkingLevel !== 'high' ||
  resolvedThinking.model?.provider !== 'anthropic' ||
  !resolvedThinking.model?.id.includes('haiku')
) {
  throw new Error('resolve-model smoke did not parse fuzzy model plus thinking suffix');
}

const customModel = JSON.parse(run(['resolve-model', '--provider', 'anthropic', 'custom-claude']));
if (
  customModel.error !== null ||
  customModel.customModel !== true ||
  customModel.model?.provider !== 'anthropic' ||
  customModel.model?.id !== 'custom-claude'
) {
  throw new Error('resolve-model smoke did not build provider-scoped custom model fallback');
}

const tools = JSON.parse(run(['tools']));
if (!tools.builtins.includes('read') || !tools.builtins.includes('bash')) {
  throw new Error('tools smoke missing built-ins');
}

const parsedArgs = JSON.parse(run(['parse-args', '--provider', 'openai', '--thinking', 'xhigh', '-p', 'say ok', '@README.md']));
if (
  parsedArgs.provider !== 'openai' ||
  parsedArgs.thinking !== 'xhigh' ||
  parsedArgs.print !== true ||
  parsedArgs.messages[0] !== 'say ok' ||
  parsedArgs.fileArgs[0] !== 'README.md'
) {
  throw new Error('parse-args smoke did not match upstream-style parsing');
}

const topLevelPrint = run(['-p', 'hello top-level print']);
if (
  !topLevelPrint.includes('pi-zig print-mode foundation accepted 1 prompt input(s)') ||
  !topLevelPrint.includes('Prompt:\nhello top-level print')
) {
  throw new Error('top-level print mode smoke did not accept an inline prompt');
}

const topLevelJsonSessionFile = 'zig-out/pi-zig-top-level-json-smoke.jsonl';
fs.rmSync(topLevelJsonSessionFile, { force: true });
const topLevelJsonLines = run(['--mode', 'json', '--session', topLevelJsonSessionFile, '-p', 'hello json mode'])
  .trim()
  .split('\n')
  .filter(Boolean)
  .map((line) => JSON.parse(line));
if (
  topLevelJsonLines[0]?.type !== 'session' ||
  !topLevelJsonLines.some((line) => line.type === 'agent_start') ||
  !topLevelJsonLines.some((line) => line.type === 'turn_end' && line.toolResults?.length === 0) ||
  !topLevelJsonLines.some((line) => line.type === 'message_end' && line.message?.content?.[0]?.text?.includes('hello json mode'))
) {
  throw new Error('top-level --mode json smoke did not emit upstream-shaped JSON event lines');
}
const topLevelJsonSession = fs.readFileSync(topLevelJsonSessionFile, 'utf8');
if (!topLevelJsonSession.includes('"role":"user","content":"hello json mode"') || !topLevelJsonSession.includes('"role":"assistant"')) {
  throw new Error('top-level --mode json smoke did not persist user and assistant foundation messages');
}

const topLevelRpcSessionFile = 'zig-out/pi-zig-top-level-rpc-smoke.jsonl';
fs.rmSync(topLevelRpcSessionFile, { force: true });
const topLevelRpcOutput = run(
  ['--mode', 'rpc', '--session', topLevelRpcSessionFile],
  `${JSON.stringify({ id: 'top-rpc', type: 'get_state' })}\n`
);
const topLevelRpcResponse = topLevelRpcOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))[0];
if (
  topLevelRpcResponse?.id !== 'top-rpc' ||
  topLevelRpcResponse?.command !== 'get_state' ||
  topLevelRpcResponse?.data?.sessionFile !== topLevelRpcSessionFile
) {
  throw new Error('top-level --mode rpc smoke did not route to RPC runtime with --session');
}

const readme = run(['tool-read', 'README.md']);
if (!readme.includes('Zig + Preact porting workspace')) {
  throw new Error('tool-read smoke did not return README content');
}

const bash = run(['tool-bash', 'printf pi-zig-tool-bash']);
if (bash !== 'pi-zig-tool-bash') {
  throw new Error(`tool-bash smoke returned unexpected output: ${JSON.stringify(bash)}`);
}

const ls = run(['tool-ls', '.']);
if (!ls.includes('README.md')) {
  throw new Error('tool-ls smoke did not list README.md');
}

const grep = run(['tool-grep', 'Zig + Preact', 'README.md']);
if (!grep.includes('Zig + Preact porting workspace')) {
  throw new Error('tool-grep smoke did not find README line');
}

const find = run(['tool-find', 'README.md', '.', '20']);
if (!find.split('\n').includes('README.md')) {
  throw new Error('tool-find smoke did not find README.md');
}

run(['tool-write', 'zig-out/pi-zig-tool-write-smoke.txt', 'pi-zig write smoke']);
const written = run(['tool-read', 'zig-out/pi-zig-tool-write-smoke.txt']);
if (written !== 'pi-zig write smoke') {
  throw new Error('tool-write smoke did not round-trip content');
}

run(['tool-write', 'zig-out/pi-zig-tool-edit-smoke.txt', 'alpha beta']);
const edit = run(['tool-edit', 'zig-out/pi-zig-tool-edit-smoke.txt', 'beta', 'gamma']);
if (!edit.includes('Successfully replaced 1 block')) {
  throw new Error('tool-edit smoke did not report success');
}
const edited = run(['tool-read', 'zig-out/pi-zig-tool-edit-smoke.txt']);
if (edited !== 'alpha gamma') {
  throw new Error('tool-edit smoke did not update content');
}

const rpcSessionFile = 'zig-out/pi-zig-rpc-smoke.jsonl';
const rpcExportFile = 'zig-out/pi-zig-rpc-smoke.html';
fs.rmSync(rpcSessionFile, { force: true });
fs.rmSync(rpcExportFile, { force: true });
const rpcOutput = run(
  ['rpc', rpcSessionFile],
  [
    JSON.stringify({ id: 'state-1', type: 'get_state' }),
    JSON.stringify({ id: 'models-1', type: 'get_available_models' }),
    JSON.stringify({ id: 'set-model-1', type: 'set_model', provider: 'anthropic', modelId: 'claude-haiku-4-5' }),
    JSON.stringify({ id: 'prompt-1', type: 'prompt', message: 'hello rpc' }),
    JSON.stringify({ id: 'bash-1', type: 'bash', command: 'printf rpc-bash' }),
    JSON.stringify({ id: 'name-1', type: 'set_session_name', name: 'smoke session' }),
    JSON.stringify({ id: 'auto-compact-1', type: 'set_auto_compaction', enabled: true }),
    JSON.stringify({ id: 'auto-retry-1', type: 'set_auto_retry', enabled: true }),
    JSON.stringify({ id: 'compact-1', type: 'compact', customInstructions: 'focus smoke' }),
    JSON.stringify({ id: 'abort-retry-1', type: 'abort_retry' }),
    JSON.stringify({ id: 'messages-1', type: 'get_messages' }),
    JSON.stringify({ id: 'stats-1', type: 'get_session_stats' }),
    JSON.stringify({ id: 'forks-1', type: 'get_fork_messages' }),
    JSON.stringify({ id: 'export-1', type: 'export_html', outputPath: rpcExportFile }),
    JSON.stringify({ id: 'state-2', type: 'get_state' }),
    ''
  ].join('\n')
);
const rpcResponses = rpcOutput
  .trim()
  .split('\n')
  .filter(Boolean)
  .map((line) => JSON.parse(line));
const promptResponse = rpcResponses.find((response) => response.id === 'prompt-1');
if (!promptResponse?.success) {
  throw new Error('rpc prompt smoke was not accepted');
}
const rpcModelsResponse = rpcResponses.find((response) => response.id === 'models-1');
if (
  rpcModelsResponse?.data?.models?.length !== 924 ||
  !rpcModelsResponse?.data?.models?.some((model) => model.provider === 'anthropic' && model.id === 'claude-haiku-4-5')
) {
  throw new Error('rpc get_available_models smoke did not return generated catalog');
}
const rpcSetModelResponse = rpcResponses.find((response) => response.id === 'set-model-1');
if (
  !rpcSetModelResponse?.success ||
  rpcSetModelResponse?.data?.provider !== 'anthropic' ||
  rpcSetModelResponse?.data?.id !== 'claude-haiku-4-5'
) {
  throw new Error('rpc set_model smoke did not return selected model');
}
const messagesResponse = rpcResponses.find((response) => response.id === 'messages-1');
if (messagesResponse?.data?.messages?.[0]?.content !== 'hello rpc') {
  throw new Error('rpc get_messages smoke did not return accepted prompt');
}
const bashResponse = rpcResponses.find((response) => response.id === 'bash-1');
if (
  !bashResponse?.success ||
  bashResponse?.data?.output !== 'rpc-bash' ||
  bashResponse?.data?.exitCode !== 0 ||
  bashResponse?.data?.cancelled !== false ||
  bashResponse?.data?.truncated !== false
) {
  throw new Error('rpc bash smoke did not return upstream-shaped BashResult');
}
const compactResponse = rpcResponses.find((response) => response.id === 'compact-1');
if (
  !compactResponse?.success ||
  !compactResponse?.data?.summary?.includes('hello rpc') ||
  compactResponse?.data?.firstKeptEntryId !== 'm-2' ||
  compactResponse?.data?.details?.local !== true ||
  compactResponse?.data?.details?.customInstructions !== 'focus smoke'
) {
  throw new Error('rpc compact smoke did not return upstream-shaped local compaction result');
}
if (
  !rpcResponses.find((response) => response.id === 'auto-compact-1')?.success ||
  !rpcResponses.find((response) => response.id === 'auto-retry-1')?.success ||
  !rpcResponses.find((response) => response.id === 'abort-retry-1')?.success
) {
  throw new Error('rpc auto compaction/retry controls did not return success');
}
if (
  messagesResponse?.data?.messages?.[1]?.role !== 'bashExecution' ||
  messagesResponse?.data?.messages?.[1]?.command !== 'printf rpc-bash' ||
  messagesResponse?.data?.messages?.[1]?.output !== 'rpc-bash'
) {
  throw new Error('rpc get_messages smoke did not include bashExecution message');
}
const statsResponse = rpcResponses.find((response) => response.id === 'stats-1');
if (
  statsResponse?.data?.sessionFile !== rpcSessionFile ||
  statsResponse?.data?.userMessages !== 1 ||
  statsResponse?.data?.totalMessages !== 2
) {
  throw new Error('rpc get_session_stats smoke did not return durable stats');
}
const forkResponse = rpcResponses.find((response) => response.id === 'forks-1');
if (forkResponse?.data?.messages?.[0]?.text !== 'hello rpc' || !forkResponse?.data?.messages?.[0]?.entryId) {
  throw new Error('rpc get_fork_messages smoke did not return user entry text/id');
}
const exportResponse = rpcResponses.find((response) => response.id === 'export-1');
if (exportResponse?.data?.path !== rpcExportFile) {
  throw new Error('rpc export_html smoke did not return requested path');
}
const secondState = rpcResponses.find((response) => response.id === 'state-2');
if (
  secondState?.data?.messageCount !== 2 ||
  secondState?.data?.sessionName !== 'smoke session' ||
  secondState?.data?.sessionFile !== rpcSessionFile ||
  secondState?.data?.autoCompactionEnabled !== true ||
  secondState?.data?.model?.provider !== 'anthropic' ||
  secondState?.data?.model?.id !== 'claude-haiku-4-5'
) {
  throw new Error('rpc get_state smoke did not return updated state');
}
const jsonl = fs.readFileSync(rpcSessionFile, 'utf8');
if (
  !jsonl.includes('"type":"session"') ||
  !jsonl.includes('"type":"message"') ||
  !jsonl.includes('"hello rpc"') ||
  !jsonl.includes('"type":"model_change"') ||
  !jsonl.includes('"type":"compaction"') ||
  !jsonl.includes('"customInstructions":"focus smoke"') ||
  !jsonl.includes('"modelId":"claude-haiku-4-5"') ||
  !jsonl.includes('"role":"bashExecution"') ||
  !jsonl.includes('"rpc-bash"')
) {
  throw new Error('rpc durable JSONL file does not contain session header, prompt, and bashExecution message');
}
const exportedHtml = fs.readFileSync(rpcExportFile, 'utf8');
if (!exportedHtml.includes('pi-zig session') || !exportedHtml.includes('hello rpc') || !exportedHtml.includes('rpc-bash')) {
  throw new Error('rpc HTML export did not include session content');
}

const resumeOutput = run(
  ['rpc', rpcSessionFile],
  [
    JSON.stringify({ id: 'resume-state', type: 'get_state' }),
    JSON.stringify({ id: 'resume-messages', type: 'get_messages' }),
    JSON.stringify({ id: 'resume-stats', type: 'get_session_stats' }),
    ''
  ].join('\n')
);
const resumeResponses = resumeOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const resumeState = resumeResponses.find((response) => response.id === 'resume-state');
if (resumeState?.data?.messageCount !== 2 || resumeState?.data?.sessionName !== 'smoke session') {
  throw new Error('rpc resume smoke did not load message count and session name from JSONL');
}
if (resumeState?.data?.model?.provider !== 'anthropic' || resumeState?.data?.model?.id !== 'claude-haiku-4-5') {
  throw new Error('rpc resume smoke did not load model_change from JSONL');
}
const resumeMessages = resumeResponses.find((response) => response.id === 'resume-messages');
if (
  resumeMessages?.data?.messages?.[0]?.content !== 'hello rpc' ||
  resumeMessages?.data?.messages?.[1]?.role !== 'bashExecution' ||
  resumeMessages?.data?.messages?.[1]?.output !== 'rpc-bash'
) {
  throw new Error('rpc resume smoke did not reconstruct messages from JSONL');
}
const resumeStats = resumeResponses.find((response) => response.id === 'resume-stats');
if (resumeStats?.data?.userMessages !== 1 || resumeStats?.data?.totalMessages !== 2) {
  throw new Error('rpc resume smoke did not reconstruct durable stats');
}

const switchDriverFile = 'zig-out/pi-zig-rpc-switch-driver.jsonl';
const switchSessionFile = 'zig-out/pi-zig-rpc-switch-target.jsonl';
fs.rmSync(switchDriverFile, { force: true });
fs.writeFileSync(
  switchSessionFile,
  [
    JSON.stringify({ type: 'session', version: 3, id: 'switch-session', timestamp: '2026-05-26T00:00:00.000Z', cwd: '.' }),
    JSON.stringify({ type: 'message', id: 'a1b2c3d4', parentId: null, timestamp: '2026-05-26T00:00:01.000Z', message: { role: 'user', content: 'loaded user' } }),
    JSON.stringify({ type: 'message', id: 'b2c3d4e5', parentId: 'a1b2c3d4', timestamp: '2026-05-26T00:00:02.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'hello from assistant' }], provider: 'faux', model: 'fixture', usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: 'stop' } }),
    JSON.stringify({ type: 'session_info', id: 'c3d4e5f6', parentId: 'b2c3d4e5', timestamp: '2026-05-26T00:00:03.000Z', name: 'loaded fixture' }),
    ''
  ].join('\n')
);
const switchOutput = run(
  ['rpc', switchDriverFile],
  [
    JSON.stringify({ id: 'switch', type: 'switch_session', sessionPath: switchSessionFile }),
    JSON.stringify({ id: 'switch-state', type: 'get_state' }),
    JSON.stringify({ id: 'switch-assistant', type: 'get_last_assistant_text' }),
    JSON.stringify({ id: 'cycle-model', type: 'cycle_model' }),
    ''
  ].join('\n')
);
const switchResponses = switchOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
if (!switchResponses.find((response) => response.id === 'switch')?.success) {
  throw new Error('rpc switch_session smoke failed');
}
const switchState = switchResponses.find((response) => response.id === 'switch-state');
if (
  switchState?.data?.sessionFile !== switchSessionFile ||
  switchState?.data?.sessionId !== 'switch-session' ||
  switchState?.data?.messageCount !== 2 ||
  switchState?.data?.sessionName !== 'loaded fixture'
) {
  throw new Error('rpc switch_session smoke did not load target session state');
}
const assistantText = switchResponses.find((response) => response.id === 'switch-assistant');
if (assistantText?.data?.text !== 'hello from assistant') {
  throw new Error('rpc get_last_assistant_text smoke did not read loaded assistant text');
}
const cycleModel = switchResponses.find((response) => response.id === 'cycle-model');
if (!cycleModel?.success || !cycleModel?.data?.model?.id || cycleModel?.data?.isScoped !== false) {
  throw new Error('rpc cycle_model smoke did not return an upstream-shaped cycle result');
}

const forkSessionFile = 'zig-out/pi-zig-rpc-fork-source.jsonl';
fs.rmSync(forkSessionFile, { force: true });
fs.rmSync(`${forkSessionFile}.fork-2.jsonl`, { force: true });
const forkOutput = run(
  ['rpc', forkSessionFile],
  [
    JSON.stringify({ id: 'fork-prompt-1', type: 'prompt', message: 'first fork prompt' }),
    JSON.stringify({ id: 'fork-prompt-2', type: 'prompt', message: 'second fork prompt' }),
    JSON.stringify({ id: 'fork-list', type: 'get_fork_messages' }),
    JSON.stringify({ id: 'fork-run', type: 'fork', entryId: 'm-2' }),
    JSON.stringify({ id: 'fork-state', type: 'get_state' }),
    ''
  ].join('\n')
);
const forkResponses = forkOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
const forkList = forkResponses.find((response) => response.id === 'fork-list');
if (
  forkList?.data?.messages?.length !== 2 ||
  forkList?.data?.messages?.[1]?.entryId !== 'm-2' ||
  forkList?.data?.messages?.[1]?.text !== 'second fork prompt'
) {
  throw new Error('rpc get_fork_messages smoke did not expose forkable user messages');
}
const forkRun = forkResponses.find((response) => response.id === 'fork-run');
if (!forkRun?.success || forkRun?.data?.text !== 'second fork prompt' || forkRun?.data?.cancelled !== false) {
  throw new Error('rpc fork smoke did not return selected text and cancellation state');
}
const forkState = forkResponses.find((response) => response.id === 'fork-state');
if (
  forkState?.data?.sessionFile !== `${forkSessionFile}.fork-2.jsonl` ||
  forkState?.data?.messageCount !== 1
) {
  throw new Error('rpc fork smoke did not rebind to a durable sibling session with prefix history');
}
const forkJsonl = fs.readFileSync(`${forkSessionFile}.fork-2.jsonl`, 'utf8');
if (!forkJsonl.includes(`"parentSession":"${forkSessionFile}"`) || forkJsonl.includes('second fork prompt')) {
  throw new Error('rpc fork JSONL did not record parent session or incorrectly copied selected prompt');
}

const cloneSessionFile = 'zig-out/pi-zig-rpc-clone-source.jsonl';
fs.rmSync(cloneSessionFile, { force: true });
fs.rmSync(`${cloneSessionFile}.clone-2.jsonl`, { force: true });
const cloneOutput = run(
  ['rpc', cloneSessionFile],
  [
    JSON.stringify({ id: 'clone-prompt', type: 'prompt', message: 'clone me' }),
    JSON.stringify({ id: 'clone-run', type: 'clone' }),
    JSON.stringify({ id: 'clone-state', type: 'get_state' }),
    ''
  ].join('\n')
);
const cloneResponses = cloneOutput.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
if (!cloneResponses.find((response) => response.id === 'clone-run')?.success) {
  throw new Error('rpc clone smoke failed');
}
const cloneState = cloneResponses.find((response) => response.id === 'clone-state');
if (
  cloneState?.data?.sessionFile !== `${cloneSessionFile}.clone-2.jsonl` ||
  cloneState?.data?.messageCount !== 1
) {
  throw new Error('rpc clone smoke did not rebind to a copied sibling session');
}
const cloneJsonl = fs.readFileSync(`${cloneSessionFile}.clone-2.jsonl`, 'utf8');
if (!cloneJsonl.includes(`"parentSession":"${cloneSessionFile}"`) || !cloneJsonl.includes('clone me')) {
  throw new Error('rpc clone JSONL did not record parent session and copied prompt');
}

console.log('basic pi-zig smokes passed');

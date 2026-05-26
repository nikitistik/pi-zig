import fs from 'node:fs';
import path from 'node:path';

const upstreamArgs = fs.readFileSync(path.resolve('upstream/pi/packages/coding-agent/src/cli/args.ts'), 'utf8');
const zigCli = fs.readFileSync(path.resolve('src/pi/cli.zig'), 'utf8');
const zigTypes = fs.readFileSync(path.resolve('src/pi/types.zig'), 'utf8');

const upstreamFlags = [...upstreamArgs.matchAll(/arg === "([^"]+)"/g)].map((match) => match[1]);
const uniqueFlags = [...new Set(upstreamFlags)].sort();
const missing = uniqueFlags.filter((flag) => !zigCli.includes(`"${flag}"`));

if (missing.length > 0) {
  throw new Error(`Zig CLI parser is missing upstream flags: ${missing.join(', ')}`);
}

const thinkingLevels = [...upstreamArgs.matchAll(/"([^"]+)"/g)]
  .map((match) => match[1])
  .filter((value) => ['off', 'minimal', 'low', 'medium', 'high', 'xhigh'].includes(value));
const zigSource = `${zigCli}\n${zigTypes}`;
const missingThinking = [...new Set(thinkingLevels)].filter((level) => !zigSource.includes(level));

if (missingThinking.length > 0) {
  throw new Error(`Zig CLI parser is missing thinking levels: ${missingThinking.join(', ')}`);
}

console.log(`cli parity guard passed: ${uniqueFlags.length} flags represented`);

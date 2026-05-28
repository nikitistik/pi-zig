// Wave 3 TUI / CLI parity smoke.
//
// Pure Node stdlib. Drives the REAL `zig-out/bin/pi-zig` binary to assert the CLI-observable
// surface of this wave's two parity closures:
//
//   1. CLI diagnostic text path (cli_runtime.writeDiagnostics -> cli.renderDiagnosticMessage):
//      the text/stderr diagnostic line is now byte-exact with upstream main.ts
//      (`${type === "error" ? "Error" : "Warning"}: ${message}`), with the message FULLY
//      INTERPOLATED. Previously this path printed the raw static `.message` template
//      ("Invalid thinking level" / "Unknown option") with no offending value. We assert:
//        * an invalid `--thinking` value emits the warning with the offending value AND the
//          valid-values list, and the run still proceeds (warning, not fatal);
//        * an unknown option emits the error with the offending arg interpolated and the run
//          aborts (exit 1, upstream parity).
//
//   2. TUI `/compact` LLM parity: NOT CLI-observable. The interactive TUI requires a real TTY
//      (App.run returns `.not_a_tty` under piped stdin), so `/compact` cannot be exercised
//      headlessly through the binary. Its App-level logic — provider-backed summarization over
//      the in-memory conversation (auth path), local message-count fallback (no-auth path),
//      persistence, and empty/failed-runner handling — is covered by unit tests in src/pi/tui.zig
//      ("runCommand compact uses the LLM runner and persists when authenticated", "... falls back
//      to the local summary when no LLM runner is wired", "... empty conversation uses the local
//      summary", "... surfaces an error when the LLM runner fails", "buildCompactionPromptText
//      serializes the in-memory conversation ...", "executePrompt records user and assistant
//      turns ..."). This smoke asserts the non-TTY fallback contract is intact instead.
//
// Prints "[wave3-tui-cli-smoke] PASS" and exits 0 on success; throws / non-zero exit on failure.

import { spawnSync } from 'node:child_process';
import path from 'node:path';

const bin = path.resolve('zig-out/bin/pi-zig');

function fail(message) {
  throw new Error(`[wave3-tui-cli-smoke] ${message}`);
}

function ensureBinary() {
  const result = spawnSync('zig', ['build'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.status !== 0) {
    fail(`zig build failed (status ${result.status})\nstdout:\n${result.stdout ?? ''}\nstderr:\n${result.stderr ?? ''}`);
  }
}

// Run the binary to completion. stdin is closed immediately: in print/interactive modes pi-zig
// reads piped stdin to EOF, so an open pipe would block before diagnostics matter.
function runCapture(args, env) {
  const result = spawnSync(bin, args, { encoding: 'utf8', env, input: '', stdio: ['pipe', 'pipe', 'pipe'] });
  return { status: result.status, stdout: result.stdout ?? '', stderr: result.stderr ?? '', signal: result.signal };
}

function main() {
  ensureBinary();

  const env = { ...process.env, PI_OFFLINE: '1' };

  // --- 1a. Invalid --thinking value: interpolated WARNING, run proceeds --------------------
  // The exact upstream line: `Warning: Invalid thinking level "<value>". Valid values: <list>`.
  // No provider/model is configured, so after the warning the run falls to the inert foundation
  // response (exit 0); the warning is non-fatal, matching upstream (only `error` diagnostics exit 1).
  const expectedThinking =
    'Warning: Invalid thinking level "maximum". Valid values: off, minimal, low, medium, high, xhigh';
  const thinking = runCapture(['--no-session', '--thinking', 'maximum', '-p', 'wave3 thinking diagnostic'], env);
  if (!thinking.stderr.includes(expectedThinking)) {
    fail(
      'invalid --thinking value did not emit the byte-exact interpolated upstream warning.\n' +
        `expected stderr to contain:\n${expectedThinking}\nactual stderr:\n${thinking.stderr}`,
    );
  }
  // Guard against regression to the raw static template (no interpolated value/list).
  if (/Warning: Invalid thinking level\s*(\n|$)/.test(thinking.stderr)) {
    fail(`--thinking diagnostic printed the raw static template instead of the interpolated message:\n${thinking.stderr}`);
  }
  if (thinking.status !== 0) {
    fail(`invalid --thinking value should be a non-fatal warning (exit 0), got exit ${thinking.status}\nstderr:\n${thinking.stderr}`);
  }
  console.log(`[wave3-tui-cli-smoke] diagnostic (warning): ${expectedThinking}`);

  // --- 1b. Unknown option: interpolated ERROR, run aborts ----------------------------------
  // The exact upstream line: `Error: Unknown option: <arg>`. An error diagnostic aborts (exit 1).
  const expectedUnknown = 'Error: Unknown option: -x';
  const unknown = runCapture(['-x'], env);
  if (!unknown.stderr.includes(expectedUnknown)) {
    fail(
      'unknown option did not emit the byte-exact interpolated upstream error.\n' +
        `expected stderr to contain:\n${expectedUnknown}\nactual stderr:\n${unknown.stderr}`,
    );
  }
  if (/Error: Unknown option\s*(\n|$)/.test(unknown.stderr)) {
    fail(`unknown-option diagnostic printed the raw static template instead of the interpolated message:\n${unknown.stderr}`);
  }
  if (unknown.status === 0) {
    fail(`unknown option should abort with a non-zero exit (upstream exits 1), got exit 0\nstderr:\n${unknown.stderr}`);
  }
  console.log(`[wave3-tui-cli-smoke] diagnostic (error): ${expectedUnknown} (exit ${unknown.status})`);

  // --- 2. TUI /compact: non-TTY fallback contract ------------------------------------------
  // /compact's provider/no-auth logic is unit-tested at the App level (see header). The TUI needs a
  // real TTY, so here we only confirm the non-interactive contract still holds: no prompt + piped
  // (non-TTY) stdin -> "requires a terminal" notice on stderr + help fallback on stdout.
  const interactive = runCapture(['--no-session'], env);
  if (!/requires a terminal/.test(interactive.stderr)) {
    fail(
      'non-TTY interactive fallback did not print the terminal-required notice ' +
        `(stderr:\n${interactive.stderr}\nstdout:\n${interactive.stdout})`,
    );
  }
  if (!/pi-zig - Zig \+ Preact port/.test(interactive.stdout)) {
    fail(`non-TTY interactive fallback did not fall back to help (stdout:\n${interactive.stdout})`);
  }
  console.log('[wave3-tui-cli-smoke] /compact is App-level unit-tested (TUI requires a TTY); non-TTY fallback contract intact');

  console.log('[wave3-tui-cli-smoke] PASS');
}

try {
  main();
} catch (err) {
  console.error(err.message ?? String(err));
  process.exitCode = 1;
}

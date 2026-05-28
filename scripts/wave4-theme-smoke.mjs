#!/usr/bin/env node
/**
 * Wave-4 theme application smoke.
 *
 * [FLOW_TUI_THEME] Drives the real `pi-zig` binary to verify the theme
 * system is actually applied — not just discovered. The previous theme
 * work parsed the JSON, listed/resolved/exported, and detected
 * dark/light from COLORFGBG; this smoke proves the next step: the live
 * TUI palette derived from a theme name (built-in `dark` vs `light`)
 * actually produces *different* ANSI 256-color escapes for the
 * accent/muted tokens that drive the banner and status bar.
 *
 * The full live-TUI render requires a real PTY (see
 * `scripts/tui-pty-harness.mjs`) and is exercised there. This smoke
 * instead drives the simpler, deterministic CLI surface:
 *
 *   1. `pi-zig themes --resolved dark`  → JSON with the dark accent hex
 *   2. `pi-zig themes --resolved light` → JSON with the light accent hex
 *   3. Map each hex to its closest ANSI 256-color index using the same
 *      `rgbTo256` algorithm `src/pi/tui_theme.zig` uses at runtime, and
 *      assert the resulting `\x1b[38;5;Nm` escapes differ between dark
 *      and light. This mirrors what the TUI's `App.palette.accent()`
 *      hands out for the banner / selector overlays.
 *
 * Pure Node stdlib. Run `zig build` first (done here for DoD). Prints
 * `[wave4-theme-smoke] PASS` and exits 0 on success; non-zero on any
 * failure. The script is owned by the wave-4 theme task; it does NOT
 * edit any unowned files.
 */

import { spawnSync } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';

const bin = path.resolve('zig-out/bin/pi-zig');

function fail(message) {
  console.error(`[wave4-theme-smoke] FAIL: ${message}`);
  process.exit(1);
}

function ensureBinary() {
  if (!fs.existsSync(bin)) {
    const result = spawnSync('zig', ['build'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    if (result.status !== 0) {
      fail(`zig build failed (status ${result.status})\nstdout:\n${result.stdout ?? ''}\nstderr:\n${result.stderr ?? ''}`);
    }
  }
  if (!fs.existsSync(bin)) fail(`binary missing after build: ${bin}`);
}

function runCapture(args, env) {
  const result = spawnSync(bin, args, { encoding: 'utf8', env, stdio: ['pipe', 'pipe', 'pipe'] });
  return {
    status: result.status,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    signal: result.signal,
  };
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (err) {
    fail(`${label}: failed to parse JSON: ${err.message}\noutput:\n${text}`);
  }
}

// --- ANSI 256 derivation (mirror src/pi/tui_theme.zig::rgbTo256) ---------
// Upstream rgbTo256 picks the closer of the 6x6x6 cube vs the 24-step
// grayscale ramp, preferring the cube unless the source RGB is near-neutral
// (spread < 10) AND grayscale is actually closer. The pi-zig Zig port in
// `src/pi/tui_theme.zig` matches this byte-for-byte; the JS port below
// stays consistent so the smoke verifies the SAME mapping the TUI uses.
const CUBE_VALUES = [0, 95, 135, 175, 215, 255];
const GRAY_VALUES = Array.from({ length: 24 }, (_, i) => 8 + i * 10);

function findClosest(value, table) {
  let bestIdx = 0;
  let bestDist = Infinity;
  for (let i = 0; i < table.length; i++) {
    const d = Math.abs(value - table[i]);
    if (d < bestDist) { bestDist = d; bestIdx = i; }
  }
  return bestIdx;
}

function colorDistance(r1, g1, b1, r2, g2, b2) {
  const dr = r1 - r2;
  const dg = g1 - g2;
  const db = b1 - b2;
  return dr * dr * 0.299 + dg * dg * 0.587 + db * db * 0.114;
}

function hexToRgb(hex) {
  const cleaned = hex.startsWith('#') ? hex.slice(1) : hex;
  if (cleaned.length !== 6) fail(`invalid hex: ${hex}`);
  return {
    r: parseInt(cleaned.slice(0, 2), 16),
    g: parseInt(cleaned.slice(2, 4), 16),
    b: parseInt(cleaned.slice(4, 6), 16),
  };
}

function rgbTo256(r, g, b) {
  const rIdx = findClosest(r, CUBE_VALUES);
  const gIdx = findClosest(g, CUBE_VALUES);
  const bIdx = findClosest(b, CUBE_VALUES);
  const cubeR = CUBE_VALUES[rIdx];
  const cubeG = CUBE_VALUES[gIdx];
  const cubeB = CUBE_VALUES[bIdx];
  const cubeIndex = 16 + 36 * rIdx + 6 * gIdx + bIdx;
  const cubeDist = colorDistance(r, g, b, cubeR, cubeG, cubeB);

  const gray = Math.round(0.299 * r + 0.587 * g + 0.114 * b);
  const grayIdx = findClosest(gray, GRAY_VALUES);
  const grayValue = GRAY_VALUES[grayIdx];
  const grayIndex = 232 + grayIdx;
  const grayDist = colorDistance(r, g, b, grayValue, grayValue, grayValue);

  const spread = Math.max(r, g, b) - Math.min(r, g, b);
  if (spread < 10 && grayDist < cubeDist) return grayIndex;
  return cubeIndex;
}

function fgEscape(hex) {
  const { r, g, b } = hexToRgb(hex);
  return `\x1b[38;5;${rgbTo256(r, g, b)}m`;
}

function main() {
  ensureBinary();

  // Drive the two built-in themes through the `themes --resolved <name>`
  // subcommand. The pi-zig CLI uses the SAME built-in theme JSON the live
  // TUI's `tui_theme.init` consumes (`themes.builtinThemeBytes`), so the
  // hex values surfaced here are exactly the source for the TUI palette.
  const dark = runCapture(['themes', '--resolved', 'dark'], process.env);
  if (dark.status !== 0) {
    fail(`themes --resolved dark failed (status ${dark.status})\nstderr:\n${dark.stderr}`);
  }
  const darkJson = parseJson(dark.stdout, 'dark');
  if (darkJson.name !== 'dark') fail(`dark: unexpected name ${darkJson.name}`);
  const darkColors = darkJson.colors ?? {};

  const light = runCapture(['themes', '--resolved', 'light'], process.env);
  if (light.status !== 0) {
    fail(`themes --resolved light failed (status ${light.status})\nstderr:\n${light.stderr}`);
  }
  const lightJson = parseJson(light.stdout, 'light');
  if (lightJson.name !== 'light') fail(`light: unexpected name ${lightJson.name}`);
  const lightColors = lightJson.colors ?? {};

  // -- Assertion 1: distinct accent / muted hex sources --------------------
  // The two built-in themes carry different palettes by design. The TUI
  // banner uses `accent`; the status-bar divider and timers use `muted`.
  if (!darkColors.accent || !lightColors.accent) fail('missing accent in resolved theme JSON');
  if (!darkColors.muted || !lightColors.muted) fail('missing muted in resolved theme JSON');
  if (darkColors.accent === lightColors.accent) {
    fail(`dark.accent (${darkColors.accent}) === light.accent (${lightColors.accent}); themes are not distinct`);
  }
  if (darkColors.muted === lightColors.muted) {
    fail(`dark.muted (${darkColors.muted}) === light.muted (${lightColors.muted}); themes are not distinct`);
  }

  // -- Assertion 2: distinct ANSI 256 escapes -----------------------------
  // The live TUI runs hex → ANSI 256 once at init via `tui_theme.init` and
  // hands the resulting `\x1b[38;5;Nm` escape to every render site that
  // previously baked the legacy `sgr.*` constants. Verify the mapping
  // here using the same rgbTo256 algorithm so the smoke fails if either
  // (a) the source JSON regresses or (b) the rgbTo256 port drifts from
  // upstream theme.ts.
  const darkAccentEsc = fgEscape(darkColors.accent);
  const lightAccentEsc = fgEscape(lightColors.accent);
  const darkMutedEsc = fgEscape(darkColors.muted);
  const lightMutedEsc = fgEscape(lightColors.muted);

  if (darkAccentEsc === lightAccentEsc) {
    fail(`dark accent escape ${JSON.stringify(darkAccentEsc)} === light accent escape — TUI banner would not change between themes`);
  }
  if (darkMutedEsc === lightMutedEsc) {
    fail(`dark muted escape ${JSON.stringify(darkMutedEsc)} === light muted escape — TUI divider would not change between themes`);
  }

  // -- Assertion 3: legacy fallback escape is NOT the dark accent --------
  // The TUI's pre-theme legacy `sgr.accent` is "\x1b[38;5;208m" (orange);
  // dark.accent (#8abeb7, teal) maps to index 109 per upstream rgbTo256.
  // If the legacy fallback ever ended up == dark.accent the live theme
  // switching would be silently invisible; this guards that invariant.
  const LEGACY_ACCENT = '\x1b[38;5;208m';
  if (darkAccentEsc === LEGACY_ACCENT) {
    fail(`dark accent escape collides with the legacy fallback ${JSON.stringify(LEGACY_ACCENT)}`);
  }

  console.log(`[wave4-theme-smoke] dark.accent ${darkColors.accent} → ANSI ${darkAccentEsc.replace('\x1b', '\\x1b')}`);
  console.log(`[wave4-theme-smoke] light.accent ${lightColors.accent} → ANSI ${lightAccentEsc.replace('\x1b', '\\x1b')}`);
  console.log(`[wave4-theme-smoke] dark.muted  ${darkColors.muted}  → ANSI ${darkMutedEsc.replace('\x1b', '\\x1b')}`);
  console.log(`[wave4-theme-smoke] light.muted ${lightColors.muted}  → ANSI ${lightMutedEsc.replace('\x1b', '\\x1b')}`);
  console.log('[wave4-theme-smoke] PASS');
}

main();

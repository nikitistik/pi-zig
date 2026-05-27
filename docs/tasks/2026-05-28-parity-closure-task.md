# Task: Pi-zig Parity Closure After 12-Agent Wave

Date: 2026-05-28
Branch: `codex/pi-zig-progress`
Starting commit: `bbccd39`
Current verified estimate: about 72% weighted parity

## Context

The 12-agent parity wave landed and the canonical local gates pass on the
current checkout:

- `npm run test`
- `npm --prefix frontend run build`
- `git diff --check`

The current result is an honest partial, not a 100% port. The next controller
must keep the same rule: do not mark a surface complete unless the implementation
is covered by a current command, unit test, smoke test, pty transcript, browser
screenshot, or explicit external-credential note.

Audit correction from 2026-05-28: the implementation is greener than the stale
surface map in two places. Interactive/TUI is now `in_progress`, not
`not_started`, because the renderer foundation, editor/key modules, entrypoint,
and non-TTY fallback exist. OAuth refresh is also `in_progress` for Anthropic,
GitHub Copilot, and OpenAI Codex because fake-token-server refresh/persistence
smokes exist. The missing OAuth work is live validation plus login/ADC/SigV4
coverage, not the refresh request-shape foundation.

Audit caution: Flow 07 should not be described as having full long-lived runner
state. Current docs still identify one Node process per hook/command invocation
as a remaining gap.

## Objective

Close the highest-risk remaining parity gaps and produce a new evidence-backed
parity estimate. The priority order is:

1. TUI live-interaction verification and controls.
2. Preact workbench live NDJSON wiring in the packaged path.
3. Runtime/auth gaps that affect real provider parity.
4. Sessions/compaction and extension runner parity.
5. Prin7r injection only after controller authorization.

## Flow A: TUI Live Harness And Controls

Source of truth:

- Upstream: `upstream/pi/packages/tui/src/*`
- Upstream: `upstream/pi/modes/interactive/*`
- Local: `src/pi/tui*.zig`
- Local: `src/pi/cli_runtime.zig`

Implement:

- Add an automated pty-driven TUI harness under `scripts/` or a focused test
  fixture that can launch `zig-out/bin/pi-zig` in interactive mode.
- Capture deterministic transcripts for prompt entry, submit, streaming text,
  tool panels, permission prompt decisions, abort, and quit.
- Wire missing command palette, model selector, session/fork/compact/export
  controls where local RPC/session APIs already exist.
- Keep non-TTY behavior unchanged: CI/piped input must still print the
  explicit non-interactive notice and top-level help.

Definition of done:

- New automated TUI verification is included in `npm run test` or documented as
  a separate command if it needs pty-only execution.
- Harness artifacts prove at least one full prompt lifecycle and one abort path.
- `docs/parity.md` TUI rows are updated with exact coverage.
- `npm run test` passes.

## Flow B: Workbench Live NDJSON Packaged Path

Source of truth:

- Local frontend: `frontend/src/`
- Local backend transport: `src/pi/rpc.zig`, `src/pi/cli_runtime.zig`
- Packaging: `release/package.sh`, `release/prin7r-app.manifest.json`

Implement:

- Replace any packaged-path fake-provider assumption with a real child process
  launch of `pi-zig --mode rpc` over NDJSON stdio.
- Keep the dev fake provider available only as an explicit dev/test fixture.
- Prove prompt streaming, tool panel updates, slash commands, settings changes,
  abort, retry, and bash-abort from the built frontend bundle.
- Add a packaged smoke that exercises the same RPC protocol the Prin7r app will
  use.

Definition of done:

- `npm --prefix frontend run build` passes.
- A scripted smoke drives the built frontend or packaged transport against the
  real `pi-zig --mode rpc` child.
- `frontend/verification/` contains fresh screenshots or equivalent artifacts
  for the live path.
- `docs/parity.md` and `docs/12-agent-wave-status.md` distinguish dev fake
  transport from packaged live transport.

## Flow C: Agent Runtime Remaining Provider Parity

Source of truth:

- Upstream: `upstream/pi/packages/agent/src/*`
- Upstream: `upstream/pi/packages/coding-agent/src/core/*`
- Local: `src/pi/agent.zig`, `src/pi/ai_client.zig`, `src/pi/session.zig`

Implement:

- Thread Google/Vertex text and thinking-block `thoughtSignature` persistence
  through provider result parsing, `agent.OwnedMessage`, RPC stored messages,
  and JSONL session persistence.
- Add cross-mode retry parity for `ProviderStreamIncomplete` in JSON/print paths
  where RPC already has retry state.
- Thread `images.autoResize=false` into read-tool and provider image handling.
- Keep the documented Zig `std.http` limitation for hard socket-level
  cancellation. Do not claim impossible socket abort parity.

Definition of done:

- Unit tests cover `thoughtSignature` persistence through reload.
- `scripts/verify-basic.mjs` covers JSON/print retry on incomplete stream.
- Image auto-resize setting has a smoke with both true and false behavior.
- Runtime estimate is updated only after the tests pass.

## Flow D: Auth, Bedrock, And Vertex

Source of truth:

- Upstream: `upstream/pi/packages/ai/src/providers/*`
- Upstream: `upstream/pi/packages/ai/src/utils/oauth/*`
- Local: `src/pi/auth.zig`, `src/pi/ai_client.zig`, `src/pi/providers.zig`

Implement:

- Add Vertex ADC parsing and access-token minting from
  `application_default_credentials.json`, with a fake token endpoint smoke.
- Add Bedrock SigV4/profile/session-token auth where feasible from local
  credentials; if exact upstream relies on SDK-only behavior, document the
  divergence and implement the equivalent request signer.
- Add live OAuth refresh checks behind explicit environment-variable gates.
  These must skip visibly when credentials are absent.

Definition of done:

- Fake-token-server tests prove ADC and OAuth refresh request shapes.
- Bedrock SigV4 tests assert canonical request/signature inputs without printing
  secrets.
- Live tests are opt-in and never fail CI when credentials are absent.

## Flow E: Sessions, Compaction, And HTML Export

Source of truth:

- Upstream: `upstream/pi/core/export-html/*`
- Upstream: compaction/session code under `upstream/pi/packages/*`
- Local: `src/pi/session.zig`, `src/pi/html_export.zig`, `src/pi/rpc.zig`

Implement:

- Add LLM-driven compaction runtime instead of relying only on the existing
  static summary/context path.
- Preserve compaction summaries through RPC reload and follow-up provider
  prompts.
- Extend HTML export toward upstream SPA parity: sidebar tree, search metadata,
  markdown/syntax-highlight, theme colors, and timestamps.

Definition of done:

- Compaction smoke proves provider call, persisted summary, and next-prompt
  history injection.
- HTML export fixtures cover markdown, code blocks, timestamps, theme colors,
  images, tool calls, thinking blocks, and compaction summaries.

## Flow F: Extensions Runner And Lifecycle

Source of truth:

- Upstream: `upstream/pi/core/extensions/*`
- Local: `src/pi/extensions.zig`, `src/pi/extension_runner.zig`

Implement:

- Keep one long-lived Node runner per session or per extension set so module
  state persists across separate RPC command invocations.
- Drive lifecycle events that are currently only inventoried:
  `resources_discover`, provider request/response hooks, session events,
  agent/turn/message events, model/thinking selection events, and user bash.
- Bridge interactive/TUI UI methods into the TUI harness once Flow A has a
  stable event loop.

Definition of done:

- A smoke proves module-local state survives two separate commands in the same
  session.
- Lifecycle event ordering is tested against at least one prompt with a tool
  call and one session switch/fork/compact event.
- Headless mode still fails visibly or no-ops only where upstream requires UI.

## Flow G: Prin7r Integration

Source of truth:

- Local pi-zig: `release/`, `patches/prin7r-pi-zig-integration/`
- Target later: `/Users/keer/projects/prin7r-openwork-zero_native`

Implement only after controller authorization:

- Finalize the patch package against the then-current Prin7r app registry.
- Inject the pi-zig app as a backend-service/integrated app without touching
  Dockerfiles in place.
- Rebuild the correct Prin7r macOS app bundle and inspect it.

Definition of done:

- Patch package still contains exactly the required patch files and no secrets.
- Prin7r bundle is rebuilt from the correct checkout.
- The app launches the pi-zig backend and renders the live workbench path.
- Screenshots or browser/app inspection artifacts are recorded.

## Global Verification

Run these before any completion claim:

```bash
npm run test
npm --prefix frontend run build
git diff --check
```

Run these when their scopes are touched:

```bash
node scripts/upstream-inventory.mjs
node scripts/check-cli-parity.mjs
node scripts/generate-model-catalog.mjs --check
node scripts/verify-basic.mjs
```

For UI work, add pty transcripts and screenshots. For cloud-provider work, use
fake servers first and make live tests opt-in with explicit skip output when
credentials are absent.

## Reporting Requirements

The final report for this task must include:

- Current commit hash and branch.
- Commands run and pass/fail result.
- Exact files changed.
- Updated weighted parity estimate with a table.
- Remaining gaps by flow.
- A clear statement when a claim is fake-server verified, live-credential
  verified, pty verified, browser verified, or only code-reviewed.

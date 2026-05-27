# Pi-Zig 12-Agent Implementation Wave

This document is the controller prompt and execution plan for the next large
parallel push toward a 100% functionality port of `earendil-works/pi`.

It assumes the controller agent starts from this repository:

- Worktree: `/Users/keer/projects/pi-zig`
- Branch: `codex/pi-zig-progress`
- Upstream source: `/Users/keer/projects/pi-zig/upstream/pi`
- Target: Zig backend/runtime plus Preact frontend, with later injection into
  `/Users/keer/projects/prin7r-openwork-zero_native`

The controller must spawn 12 subagents in parallel, one per flow below.
Each subagent gets a disjoint primary ownership area, a precise DoD, and
required verification commands. The controller owns integration, conflict
resolution, final test runs, parity ledger updates, and commits.

## Controller Contract

The controller is not a passive dispatcher.

The controller must:

- Read this whole document first.
- Run a fresh baseline status check before spawning workers.
- Spawn exactly 12 workers, one per flow.
- Give each worker its flow section verbatim.
- Tell every worker that other agents are editing the repo at the same time.
- Tell every worker not to revert files outside its ownership.
- Keep the critical path local when an integration decision blocks all flows.
- Require workers to edit files directly in their forked workspaces.
- Require workers to list changed files and verification evidence.
- Review every returned patch before merging or copying it.
- Reject source-only work that has no test or smoke proof.
- Keep `docs/parity.md` current after each accepted slice.
- Keep commits small enough to audit.

The controller must not:

- Redefine the goal as a subset of upstream.
- Count a feature as done because an API compiles.
- Hide fallbacks, silent truncation, or degraded behavior.
- Commit failing full-suite state unless explicitly marking a known blocker.
- Revert unrelated user or worker changes.
- Let two workers own the same primary file set without explicit sequencing.

## Baseline Commands

Run these before spawning workers:

```sh
pwd
git status --short --branch
git log --oneline -5
zig build test
node --check scripts/verify-basic.mjs
npm run test
```

If `npm run test` is already failing, capture the exact failure and decide:

- If failure is unrelated to this wave, create a blocker note in
  `docs/12-agent-wave-status.md`.
- If failure is caused by current uncommitted work, fix it before spawning.
- If the failure points to one flow, give that worker the failing evidence.

## Shared Source Of Truth

All workers must compare against upstream. Do not guess behavior from memory.

Use these upstream roots:

- `upstream/pi/packages/coding-agent/src`
- `upstream/pi/packages/coding-agent/docs`
- `upstream/pi/packages/agent/src`
- `upstream/pi/packages/ai/src`
- `upstream/pi/packages/tui/src`
- `upstream/pi/packages/sdk/src`

Use these local roots:

- `src/pi`
- `scripts/verify-basic.mjs`
- `docs/parity.md`
- `frontend`
- `build.zig`
- `build.zig.zon`

Every behavioral claim must cite:

- an upstream file path and line or symbol,
- the local file path changed,
- the verification command that proves it.

## Global Definition Of Done

A flow is done only when all of these are true:

- Upstream behavior has been inventoried for the flow.
- Local implementation matches upstream semantics, including edge cases.
- Public API shape is documented or tested.
- Negative cases are tested when upstream rejects or errors.
- Existing tests still pass for the touched area.
- `docs/parity.md` is updated for the accepted delta.
- No unrelated files are modified.
- No worker has left generated junk in the worktree.
- The controller can explain exactly what remains.

Minimum verification for any accepted flow:

```sh
zig fmt <changed-zig-files>
zig build test
node --check scripts/verify-basic.mjs
```

Full integration verification before final commit:

```sh
zig build
zig build test
npm --prefix frontend run build
node scripts/verify-basic.mjs
npm run test
git diff --check
```

## Worker Output Format

Each worker must finish with:

```md
## Summary
- What changed.
- What upstream behavior was matched.

## Files Changed
- path
- path

## Verification
- command: result
- command: result

## Remaining Risk
- Concrete gap, or "none known".

## Controller Notes
- Merge ordering constraints.
- Conflicts expected with other flows.
```

## Merge Discipline

The controller should merge in this order when possible:

1. Pure docs and inventory.
2. Tests and fixtures that currently fail.
3. Leaf modules with no public API changes.
4. Shared structs/types.
5. Runtime integration.
6. Frontend integration.
7. Parity ledger updates.

If two workers changed the same file:

- Inspect both diffs.
- Preserve both behavioral intentions when compatible.
- Ask no one to "start over" unless the diff is unsalvageable.
- Run the narrowest tests for that file before the full suite.

## Progress Target

Current ledger should be treated as approximately:

| Area | Starting Estimate | Target After Wave |
|---|---:|---:|
| Monorepo package map | 35% | 100% |
| CLI parser/help | 72% | 100% |
| Package commands | 58% | 100% |
| Settings manager | 69% | 100% |
| Print mode | 67% | 100% |
| JSON mode | 74% | 100% |
| RPC mode | 92% | 100% |
| Agent runtime/harness/tool loop | 98% | 100% |
| Provider registry/transports | 54% | 100% |
| Models registry | 62% | 100% |
| OAuth/auth storage | 33% | 100% |
| Built-in tools | 77% | 100% |
| Sessions | 70% | 100% |
| Compaction | 45% | 100% |
| Extensions | 66% | 100% |
| Skills/templates/themes/context | 59% | 100% |
| TUI renderer | 0% | 100% |
| HTML export | 32% | 100% |
| Preact workbench | 25% | 100% |
| Prin7r integration | 0% | 100% |

The target is intentionally aggressive. If a flow cannot finish, it must leave
a failing or skipped test fixture and a concrete remaining-work checklist.

---

# Flow 01: Upstream Inventory And Parity Ledger

## Mission

Make the inventory complete enough that no remaining upstream package, command,
runtime API, provider, or UI surface is invisible.

## Primary Ownership

- `docs/upstream-inventory.md`
- `docs/parity.md`
- `scripts/upstream-inventory.mjs`
- new docs under `docs/inventory/`

## Do Not Own

- Runtime behavior files under `src/pi`
- Frontend implementation under `frontend`
- Test harness changes outside inventory assertions

## Upstream Context

Inspect:

- `upstream/pi/package.json`
- `upstream/pi/packages/*/package.json`
- `upstream/pi/packages/coding-agent/src/cli`
- `upstream/pi/packages/coding-agent/src/core`
- `upstream/pi/packages/ai/src/providers`
- `upstream/pi/packages/tui/src`

## Implementation Tasks

- Extend `scripts/upstream-inventory.mjs` to enumerate every package.
- Capture package dependencies and local workspace references.
- Capture CLI command files and mode entrypoints.
- Capture provider implementation files and auth surfaces.
- Capture extension APIs by exported type or symbol.
- Capture TUI components and commands.
- Capture docs that define DoD or public API.
- Produce a machine-readable inventory artifact if useful.
- Update `docs/upstream-inventory.md` with all packages.
- Update `docs/parity.md` with missing rows if inventory exposes gaps.

## DoD

- Every upstream package has a row.
- Every CLI command is mapped to local status.
- Every provider is mapped to local transport/auth status.
- Every extension API is mapped to local status.
- Every TUI route/component group is mapped to local status.
- Every unknown is explicitly marked, not omitted.
- `docs/parity.md` percentages are recalculated from a visible weighting.

## Verification

Run:

```sh
node scripts/upstream-inventory.mjs
zig build test
node --check scripts/verify-basic.mjs
```

Add a smoke assertion if the inventory script can silently miss packages.

## Completion Evidence

Worker must report:

- package count upstream,
- local mapped count,
- unmapped count,
- parity rows added or changed.

---

# Flow 02: CLI Parser, Help, And Entry Points

## Mission

Close all top-level CLI parsing, aliases, help text, default model behavior,
interactive entrypoint dispatch, and mode selection parity.

## Primary Ownership

- `src/main.zig`
- `src/pi/cli.zig`
- `src/pi/cli_runtime.zig`
- CLI-focused tests in `scripts/verify-basic.mjs`

## Do Not Own

- Provider transport internals.
- TUI renderer implementation.
- Package manager internals except command routing.

## Upstream Context

Inspect:

- `upstream/pi/packages/coding-agent/src/cli/args.ts`
- `upstream/pi/packages/coding-agent/src/cli/index.ts`
- `upstream/pi/packages/coding-agent/src/cli/commands`
- `upstream/pi/packages/coding-agent/docs/cli.md`

## Implementation Tasks

- Inventory every upstream flag and alias.
- Implement missing parse fields in `cli.ParsedArgs`.
- Match default mode selection.
- Match prompt argument handling.
- Match `-p`, stdin, and positional prompt precedence.
- Match `--help` and command-specific help.
- Match unknown flag behavior.
- Match interactive entrypoint dispatch enough to call TUI once Flow 10 lands.
- Add visible errors for unported interactive behavior until Flow 10 wires it.
- Ensure JSON mode and RPC mode do not inherit print-only defaults incorrectly.
- Ensure extension unknown-long-flag pass-through remains intact.

## DoD

- `pi-zig --help` has equivalent command/flag coverage.
- Every upstream flag is supported or fails with a documented parity error.
- Aliases behave like upstream.
- Default provider/model selection is delegated to model resolver, not hardcoded.
- Interactive command dispatch is structurally ready for the TUI flow.
- Tests cover common flags, edge flags, invalid combos, and help output.

## Verification

Run:

```sh
zig build test
zig build run -- --help
zig build run -- parse-args -p hello
node scripts/verify-basic.mjs
```

Add verify-basic cases for:

- flag aliases,
- stdin prompt,
- invalid mixed modes,
- help text for at least three subcommands.

## Completion Evidence

Worker must report:

- number of upstream flags inventoried,
- number implemented,
- number intentionally blocked,
- new tests added.

---

# Flow 03: Package Manager, Settings, And Update Flows

## Mission

Reach upstream parity for package install/remove/list/update, settings merge,
self-update detection, path semantics, lock behavior, and platform edge cases.

## Primary Ownership

- `src/pi/package_manager.zig`
- `src/pi/settings.zig`
- package/update tests in `scripts/verify-basic.mjs`
- package docs in `docs/parity.md`

## Do Not Own

- Provider auth storage.
- Extension runtime execution after package discovery.
- Frontend package UI.

## Upstream Context

Inspect:

- `upstream/pi/packages/coding-agent/src/core/package-manager*`
- `upstream/pi/packages/coding-agent/src/cli/package-manager-cli.ts`
- `upstream/pi/packages/coding-agent/src/core/settings-manager.ts`
- `upstream/pi/packages/coding-agent/docs/packages.md`
- `upstream/pi/packages/coding-agent/docs/settings.md`

## Implementation Tasks

- Complete npm, git, and local package install semantics.
- Complete remove/uninstall aliases and suggestions.
- Complete `update`, `update --extensions`, and `update --self`.
- Match package lock files if upstream uses them.
- Match path normalization and `~` expansion.
- Match local/global/project settings precedence.
- Match migration of legacy settings fields.
- Implement Windows path edge behavior where portable.
- Add safe errors where OS-specific behavior cannot run on macOS.
- Ensure package discovery feeds commands, prompts, skills, themes, extensions.

## DoD

- Package manager commands produce upstream-shaped output.
- Settings writes preserve unrelated keys.
- Invalid JSON errors are visible and do not rewrite files.
- Update flows are tested with fake npm/git fixtures.
- Self-update detects managed vs unmanaged installs.
- Package discovery is verified through resource consumers.

## Verification

Run:

```sh
zig build test
node scripts/verify-basic.mjs
zig-out/bin/pi-zig install --help
zig-out/bin/pi-zig settings --json
```

Add tests for:

- package object filters,
- pinned git refs,
- npm version checks,
- lock or update metadata,
- settings migration.

## Completion Evidence

Worker must report:

- package source types covered,
- update flows covered,
- settings migrations covered,
- remaining OS-only gaps.

---

# Flow 04: Provider Registry, Native Transports, And OAuth

## Mission

Close provider registry and auth parity for all upstream providers, including
native transport request shapes, environment variables, OAuth login/refresh,
Bedrock auth, Google Vertex ADC, and failure classification.

## Primary Ownership

- `src/pi/providers.zig`
- `src/pi/ai_client.zig`
- `src/pi/auth.zig`
- provider tests in `scripts/verify-basic.mjs`

## Do Not Own

- Model catalog generation except provider-model linkage.
- Agent loop behavior except provider options needed by transports.
- UI auth flows.

## Upstream Context

Inspect:

- `upstream/pi/packages/ai/src/providers`
- `upstream/pi/packages/ai/src/oauth.ts`
- `upstream/pi/packages/ai/src/auth-storage.ts`
- `upstream/pi/packages/ai/src/env-api-keys.ts`
- provider-specific tests under `upstream/pi/packages/ai/test`

## Implementation Tasks

- Inventory every upstream provider id.
- Map env var resolution for every provider.
- Implement missing native transports.
- Complete Google Vertex ADC, OAuth, and refresh semantics.
- Complete Anthropic OAuth where upstream supports it.
- Complete Bedrock SigV4/profile/session token behavior.
- Complete Mistral, OpenAI, OpenAI Responses, Google, Vertex request shapes.
- Complete provider error body parsing and retry classification.
- Ensure streaming and non-streaming variants share auth semantics.
- Add fake-provider tests for every provider route.
- Add auth storage tests with expired and refreshed credentials.

## DoD

- `provider-env <provider>` is upstream-equivalent.
- `auth status`, `auth resolve`, and stored credentials match upstream shape.
- Native provider transports do not route through a generic shim when upstream
  uses provider-specific shape.
- OAuth refresh works or fails with exact visible parity gap.
- Fake provider asserts headers, URL, body, stream framing, and tool result body.

## Verification

Run:

```sh
zig build test
node scripts/verify-basic.mjs
zig-out/bin/pi-zig providers
zig-out/bin/pi-zig provider-env google
zig-out/bin/pi-zig auth list --json
```

Add narrow provider smokes before running the full test harness.

## Completion Evidence

Worker must report:

- provider ids implemented,
- auth paths implemented,
- provider routes tested,
- remaining credentials that require real cloud integration.

---

# Flow 05: Models Registry And Resolver

## Mission

Match upstream model registry, default model selection, model cycling, aliases,
thinking variants, capability metadata, and provider compatibility rules.

## Primary Ownership

- `scripts/generate-model-catalog.mjs`
- `src/pi/models.generated.zig`
- `src/pi/models.zig`
- model tests in `scripts/verify-basic.mjs`

## Do Not Own

- Provider HTTP transports.
- CLI parser except model flag consumption.
- Frontend model UI beyond generated metadata contract.

## Upstream Context

Inspect:

- `upstream/pi/packages/ai/src/models*.ts`
- `upstream/pi/packages/coding-agent/src/core/model-resolver.ts`
- upstream tests for model aliases and cycling.

## Implementation Tasks

- Regenerate model catalog from upstream source.
- Preserve upstream provider ids and aliases.
- Preserve image/tool/thinking capability flags.
- Implement default model logic exactly.
- Implement model resolution by alias, provider, and shorthand.
- Implement thinking-level cycle order.
- Implement `get_available_models`, `set_model`, and `cycle_model` parity.
- Ensure non-vision downgrades use current model capabilities.
- Ensure provider-specific default models are not stale hardcodes.

## DoD

- Generated catalog is deterministic.
- Every upstream model has local metadata or documented exclusion.
- Alias resolution matches upstream.
- Cycling matches upstream.
- Image-capability checks use generated metadata.
- Tests cover provider-specific aliases and thinking variants.

## Verification

Run:

```sh
node scripts/generate-model-catalog.mjs
zig build test
zig build run -- models
zig build run -- list-models haiku
zig build run -- resolve-model --provider anthropic haiku:high
node scripts/verify-basic.mjs
```

## Completion Evidence

Worker must report:

- upstream model count,
- local model count,
- alias count,
- capability fields covered.

---

# Flow 06: Agent Runtime, Harness, Retry, Abort, And Images

## Mission

Close the last runtime/harness gaps: upstream assistant-session retry semantics,
abort event streaming, hard cancellation limits, image resize/generation worker
parity, thinking block persistence, and direct TUI/user-bash hooks.

## Primary Ownership

- `src/pi/agent.zig`
- `src/pi/rpc.zig`
- `src/pi/ai_client.zig`
- `src/pi/session.zig`
- runtime sections of `scripts/verify-basic.mjs`

## Do Not Own

- Provider auth internals except options needed by runtime.
- TUI rendering.
- Extension runner internals except callback hooks.

## Upstream Context

Inspect:

- `upstream/pi/packages/agent/src/agent-loop.ts`
- `upstream/pi/packages/coding-agent/src/core/agent-session.ts`
- `upstream/pi/packages/coding-agent/src/core/messages.ts`
- `upstream/pi/packages/coding-agent/src/core/retry*`
- image processing or generation worker sources.

## Implementation Tasks

- Inventory all upstream agent loop events.
- Implement missing abort event stream semantics.
- Complete assistant-session retry integration beyond final errors.
- Complete thinking/text block signature persistence for Google/Vertex.
- Complete image resize behavior for direct user and tool images.
- Complete image generation worker behavior if upstream exposes it.
- Ensure cancellation reaches provider stream readers wherever Zig permits.
- Document hard socket cancellation limits if `std.http` cannot interrupt.
- Wire direct TUI/user-bash timeout contracts for Flow 10.
- Add tests for event ordering, retry state, and persisted assistant errors.

## DoD

- Runtime event sequence matches upstream for success, tool call, error, retry,
  abort, and cancellation.
- Provider history rebuild preserves every supported message part.
- Retry metadata and state match upstream.
- Image resize/generation behavior is tested.
- Any impossible hard-cancel behavior is documented and isolated.

## Verification

Run:

```sh
zig build test
node scripts/verify-basic.mjs
npm run test
```

Add fake-provider cases for:

- retry while active,
- abort during stream,
- thinking signature replay,
- image resize or generation.

## Completion Evidence

Worker must report:

- event types covered,
- retry cases covered,
- image cases covered,
- known Zig runtime limitations.

---

# Flow 07: Extensions Full Runner, Lifecycle, Flags, UI, And Jiti

## Mission

Implement full upstream extension behavior: `jiti` loading, aliasing, dependency
roots, lifecycle events, flags validation/help, UI contexts, command contexts,
conflict diagnostics, and long-lived runner state.

## Primary Ownership

- `src/pi/extensions.zig`
- `src/pi/extension_runner.zig`
- extension parts of `src/pi/cli_runtime.zig`
- extension tests in `scripts/verify-basic.mjs`

## Do Not Own

- Package discovery internals except extension package inputs.
- Agent loop internals except hook interfaces.
- TUI rendering except extension context contracts.

## Upstream Context

Inspect:

- `upstream/pi/packages/coding-agent/src/core/extensions`
- `upstream/pi/packages/coding-agent/docs/extensions.md`
- `upstream/pi/packages/coding-agent/examples/extensions`
- upstream extension tests.

## Implementation Tasks

- Inventory extension API surface from upstream types.
- Implement `jiti`-compatible loading or a tested equivalent.
- Support TS, CJS, ESM, package exports, and dependency roots.
- Keep runner state long-lived where upstream does.
- Implement extension lifecycle events.
- Implement flag validation, defaults, descriptions, and help surfacing.
- Implement command context actions for interactive/TUI use.
- Implement richer UI methods and headless fallback behavior.
- Implement conflict diagnostics for tools, commands, flags, hooks.
- Ensure extension discovery integrates with package manager output.
- Add examples-based smoke fixtures.

## DoD

- All documented extension APIs are implemented or explicitly blocked.
- Runner supports upstream examples.
- Long-lived state is observable in a test.
- Flags appear in help and validate invalid values.
- UI contexts behave in headless, JSON, RPC, and future TUI modes.
- Duplicate/conflict behavior matches upstream.

## Verification

Run:

```sh
zig build test
node scripts/verify-basic.mjs
zig-out/bin/pi-zig extensions --json
```

Add extension fixture tests for:

- package dependency import,
- TypeScript path,
- lifecycle event,
- command context,
- flag validation,
- long-lived state.

## Completion Evidence

Worker must report:

- extension APIs implemented,
- examples that pass,
- conflict cases tested,
- lifecycle events tested.

---

# Flow 08: Built-In Tools And Shell/File Semantics

## Mission

Close built-in tool parity for `bash`, `read`, `write`, `edit`, `ls`, `grep`,
`find`, plus any upstream tools not yet represented.

## Primary Ownership

- `src/pi/tools.zig`
- tool tests in `scripts/verify-basic.mjs`
- tool-related agent tests

## Do Not Own

- Provider serialization except tool result shapes.
- TUI display of tool output.
- Package manager file operations.

## Upstream Context

Inspect:

- `upstream/pi/packages/coding-agent/src/core/tools`
- upstream tests for bash, edit, grep, read, and file tools.
- docs for tool permissions and outputs.

## Implementation Tasks

- Inventory every upstream built-in tool.
- Match tool schemas exactly.
- Match shell command prefix and shell path behavior.
- Complete Windows Git Bash discovery behavior.
- Complete timeout, cancellation, stdout/stderr, truncation, and artifacts.
- Complete read offsets, binary handling, image handling, and notices.
- Complete edit multi-replacement semantics and errors.
- Complete grep/find ignore rules and output limits.
- Add permission gate integration points for TUI/headless.
- Ensure JSON/RPC tool result payloads preserve `isError`, `terminate`, and
  structured content parts.

## DoD

- Tool schemas match upstream.
- Provider tool calls execute and return upstream-shaped results.
- Negative edge cases are tested.
- Platform-specific behavior is tested by pure parser/unit tests where the host
  OS cannot exercise it.
- No tool silently truncates without upstream-shaped notice/artifact.

## Verification

Run:

```sh
zig build test
node scripts/verify-basic.mjs
zig-out/bin/pi-zig tool-read <fixture>
zig-out/bin/pi-zig tool-bash 'printf ok'
```

Add tests for:

- permission denied,
- missing shell,
- long output,
- binary read,
- edit overlap,
- Windows path parser.

## Completion Evidence

Worker must report:

- tools inventoried,
- schemas matched,
- edge cases tested,
- platform-only gaps.

---

# Flow 09: Sessions, Compaction, Fork/Clone, And HTML Export

## Mission

Reach upstream parity for durable sessions, context rebuild, compaction,
fork/clone/switch semantics, stats, export HTML, and session tree behavior.

## Primary Ownership

- `src/pi/session.zig`
- session portions of `src/pi/rpc.zig`
- `src/pi/html_export.zig` if present or new export module
- session tests in `scripts/verify-basic.mjs`

## Do Not Own

- Agent loop provider behavior except history rebuild contracts.
- Frontend session browser.
- TUI session UI.

## Upstream Context

Inspect:

- `upstream/pi/packages/coding-agent/src/core/session-manager.ts`
- `upstream/pi/packages/coding-agent/src/core/messages.ts`
- `upstream/pi/packages/coding-agent/src/core/compaction`
- `upstream/pi/packages/coding-agent/src/core/export-html`
- session docs.

## Implementation Tasks

- Inventory upstream JSONL entry types.
- Match message id, parent id, leaf, fork, clone, and switch semantics.
- Match session search and prefix resolution.
- Match `get_messages`, `get_state`, stats, fork messages.
- Implement compaction using LLM flow where upstream does.
- Preserve compaction summaries in provider history rebuild.
- Match custom entries and hidden entries behavior.
- Complete HTML export rendering and escaping.
- Add export assets/style parity if upstream provides it.
- Ensure image/tool/custom messages render correctly.

## DoD

- Session JSONL format is upstream-compatible.
- Fork/clone/switch work across reload.
- Compaction changes provider history exactly like upstream.
- HTML export renders all supported message types.
- Tests cover reload after every entry type.

## Verification

Run:

```sh
zig build test
node scripts/verify-basic.mjs
zig-out/bin/pi-zig --export <test-session>
```

Add tests for:

- multi-branch session tree,
- compaction with kept messages,
- custom entry reload,
- HTML image/tool render.

## Completion Evidence

Worker must report:

- JSONL entry types covered,
- fork/clone cases covered,
- compaction cases covered,
- HTML render cases covered.

---

# Flow 10: TUI Renderer And Interactive Mode

## Mission

Implement the upstream interactive/TUI experience in Zig plus Preact where
needed, including prompt input, command palette, tool display, permissions,
abort controls, bash controls, model controls, session controls, and extension
UI contexts.

## Primary Ownership

- new `src/pi/tui*` modules
- interactive entrypoints in `src/pi/cli_runtime.zig`
- Preact/TUI bridge files if used
- TUI tests or browser/computer-use smoke docs

## Do Not Own

- Provider transports.
- Core agent loop except UI callbacks.
- Standalone web workbench except shared components.

## Upstream Context

Inspect:

- `upstream/pi/packages/tui/src`
- interactive mode docs.
- command and keyboard shortcut docs.
- permission UI code.

## Implementation Tasks

- Inventory TUI components and state model.
- Choose implementation path: terminal renderer, Preact bridge, or hybrid.
- Implement interactive boot and shutdown.
- Implement prompt composer and history.
- Implement streaming assistant text updates.
- Implement tool call panels and live updates.
- Implement permission dialogs.
- Implement abort and abort-bash actions.
- Implement model selector and command palette.
- Implement session/fork/compact/export controls.
- Implement extension UI context bridge.
- Add snapshot or computer-use verification artifacts.

## DoD

- `pi-zig` without `-p` enters a usable interactive surface.
- Core keyboard commands work.
- Streaming/tool updates are visible.
- Permission prompts block and resume correctly.
- Abort and bash abort work.
- TUI can run a provider-backed fake-provider conversation.
- TUI can execute an extension command and registered tool.

## Verification

Run:

```sh
zig build
zig build test
node scripts/verify-basic.mjs
```

Also run a manual/computer-use smoke:

- launch interactive mode,
- type a prompt,
- accept or deny a tool permission,
- run a slash command,
- abort a running bash command,
- capture screenshot or terminal transcript.

## Completion Evidence

Worker must report:

- UI surfaces implemented,
- keyboard controls implemented,
- transcript or screenshot path,
- remaining visual defects.

---

# Flow 11: Preact Workbench And Standalone App

## Mission

Build the Preact frontend/workbench that can operate as a standalone app and
later embed into Prin7r, while using the real Zig/RPC backend contracts.

## Primary Ownership

- `frontend`
- frontend build/test files
- RPC client bindings if generated
- workbench docs

## Do Not Own

- Core RPC protocol implementation in Zig unless adding typed endpoints.
- Prin7r injection patch files.
- TUI renderer.

## Upstream Context

Inspect:

- upstream TUI behavior for feature parity.
- local RPC protocol in `src/pi/rpc.zig`.
- existing `frontend` structure.
- `vercel-labs/zero-native` if this repo uses it as a build option.

## Implementation Tasks

- Inventory current frontend.
- Define typed RPC client contract.
- Implement session list and active session view.
- Implement prompt composer and streaming output.
- Implement tool call panels.
- Implement slash command browser.
- Implement settings/model/provider controls.
- Implement extension command/tool visibility.
- Implement compaction/export/session controls.
- Implement image attachment input and preview.
- Implement error, retry, abort, and bash abort controls.
- Build with restrained work-focused UI.
- Avoid landing-page or marketing shell.

## DoD

- `npm --prefix frontend run build` passes.
- Workbench can start against local `pi-zig --mode rpc`.
- User can send prompt, see streaming response, run slash command, and inspect
  session history.
- Image attachment reaches backend.
- Abort controls work.
- Empty/loading/error states are implemented.
- Visual layout is usable on desktop and mobile widths.

## Verification

Run:

```sh
npm --prefix frontend run build
zig build
zig-out/bin/pi-zig --mode rpc --session zig-out/frontend-smoke.jsonl
```

Use browser/computer-use verification:

- open the frontend dev server,
- connect to RPC backend,
- send fake-provider prompt,
- attach an image,
- run command,
- capture screenshots.

## Completion Evidence

Worker must report:

- dev server URL used,
- screenshot paths,
- build output,
- backend smoke result.

---

# Flow 12: Prin7r Integration And Release Packaging

## Mission

Prepare pi-zig to be injected into
`/Users/keer/projects/prin7r-openwork-zero_native` as a frontend and backend
capability, without violating that repo's patch packaging rules.

## Primary Ownership

- release/package scripts in this repo
- `docs/prin7r-integration.md`
- patch package files under this repo if needed
- integration manifests

## Do Not Own

- Direct edits to `/Users/keer/projects/prin7r-openwork-zero_native` unless the
  controller explicitly moves to the integration phase.
- Dockerfile in-place edits in Prin7r.
- Prin7r unrelated UI behavior.

## Prin7r Rules

When the integration phase begins, obey that repo's instructions:

- Dockerfile changes must be delivered as patch packages under `patches/`.
- Each patch package must contain `README.md` and `apply.*`.
- Do not do direct string replacements in Dockerfile.
- For Prin7r UI work, rebuild the correct app bundle and inspect it.
- Do not add hidden fallbacks or silent truncation.

## Implementation Tasks

- Define pi-zig release artifacts.
- Define backend launch command and RPC lifecycle.
- Define frontend embedding shape.
- Define app manifest for Prin7r.
- Define settings/env var handoff.
- Define session storage path handoff.
- Define auth/key preflight without duplicating secrets.
- Define package/update path.
- Create integration docs and patch skeletons if appropriate.
- Add local packaging smoke.
- Add a no-op dry-run integration check if safe.

## DoD

- A fresh checkout can build a pi-zig binary and frontend bundle.
- Release artifact paths are documented.
- Prin7r integration steps are patch-packaged, not ad hoc.
- Backend and frontend can be started together locally.
- Required keys are referenced by path, not copied.
- Failure modes are visible.

## Verification

Run:

```sh
zig build
npm --prefix frontend run build
```

If integration patch packages are created, run their dry-run mode.

When actual Prin7r injection is requested later:

```sh
cd /Users/keer/projects/prin7r-openwork-zero_native
git status --short --branch
```

Then follow that repo's build and app-bundle verification rules.

## Completion Evidence

Worker must report:

- artifact paths,
- patch package paths,
- dry-run output,
- exact remaining manual Prin7r step if any.

---

# Controller Integration Checklist

Use this after workers return.

## Per-Worker Review

For each worker:

- Read its summary.
- Inspect `git diff -- <changed-files>`.
- Confirm it stayed in ownership.
- Confirm it cited upstream files.
- Run narrow verification.
- Reject missing tests unless the change is docs-only.
- Update `docs/12-agent-wave-status.md`.

## Cross-Flow Review

Check these high-conflict areas:

- `src/pi/cli_runtime.zig`
- `src/pi/rpc.zig`
- `src/pi/ai_client.zig`
- `src/pi/session.zig`
- `scripts/verify-basic.mjs`
- `docs/parity.md`

For each conflict:

- Identify which flow owns the behavior.
- Preserve tests from both sides.
- Prefer shared helper functions over duplicated logic only when local style
  already supports it.
- Avoid unrelated refactors.

## Required Final Verification

The controller must run:

```sh
zig fmt src/pi/*.zig
zig build
zig build test
npm --prefix frontend run build
node --check scripts/verify-basic.mjs
node scripts/verify-basic.mjs
npm run test
git diff --check
```

If any command fails:

- fix it if it is in-scope,
- otherwise create `docs/12-agent-wave-status.md` with exact blocker,
- do not claim 100% completion.

## Required Final Artifacts

Before final commit:

- `docs/parity.md` updated.
- `docs/upstream-inventory.md` updated if inventory changed.
- `docs/12-agent-wave-status.md` present if anything remains.
- Screenshots/transcripts saved for TUI/frontend work.
- No temporary smoke files outside ignored `zig-out/`.

## Commit Policy

Preferred commit sequence:

1. Inventory/docs updates.
2. Core runtime/provider/session slices.
3. Extension/tool/package slices.
4. TUI/frontend/integration slices.
5. Final ledger and status checkpoint.

Each commit message should name the flow, for example:

```txt
Complete provider auth parity
Wire extension lifecycle runner parity
Add TUI interactive harness
Prepare Prin7r integration package
```

## Final Report Template

The controller final answer should include:

```md
Implemented:
- Flow number and short summary.

Verified:
- command: pass
- command: pass

Still left:
- concrete item, or "none known".

Commits:
- hash message

Current estimate:
- total weighted percent
- verified-green percent
```

Do not report "100%" unless the full suite and manual/browser/TUI verification
support it.


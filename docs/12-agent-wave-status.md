# 12-Agent Implementation Wave — Status

Controller status report for the wave defined in `docs/12-agent-implementation-wave.md`.

- Branch: `codex/pi-zig-progress`
- Upstream pin: `fc8a1559017f1e581cfa971aa3cef11a507a4975`
- Outcome: **honest partial** — all 12 flows landed and merged green, weighted parity
  ~59% → ~72% (`docs/parity.md`). The aggressive 100% target was **not** reached;
  concrete remaining work is listed per flow below. Do not mark 100%.

## Verification (all green)

| Gate | Result |
|---|---|
| `zig build` | pass |
| `zig build test` | pass — 210/210 unit tests |
| `npm --prefix frontend run build` | pass |
| `node --check scripts/verify-basic.mjs` | pass |
| `node scripts/verify-basic.mjs` | pass (all flow smoke blocks) |
| `npm run test` (zig test + inventory + cli-parity + model-catalog --check + build + smokes) | pass |
| `git diff --check` | clean |

## Execution notes (for the record)

- **API socket overload at 12-way concurrency.** The first launch of 12 simultaneous
  worktree-isolated agents caused three (F06, F10, F12) to die mid-run with
  `socket connection was closed unexpectedly`, producing little or no work. They were
  re-run at low concurrency and succeeded. Lesson: cap concurrent heavy agents (~3-4),
  not 12, on this infrastructure.
- **Silent agent deaths.** F10 and F11 did substantial work but their agent processes
  died without emitting a completion report (output frozen 1-3h). Their work was
  recovered intact from the worktrees and committed.
- **Integration fixes the controller applied** (committed in `b71624f`):
  - Latent buffer-aliasing bug in `detectImageMimeTypeForFile` (read into the reader's
    own buffer corrupted reads that fill the 4100-byte sniff buffer). F08's small-PNG
    tests never triggered it; F06's 4.5 MB fixtures did. Fixed with a separate buffer.
  - F06's oversized-image fixtures (Zig + smoke) were extension-era all-`0x41` bytes;
    F08 switched detection to magic bytes (upstream-correct), so they were given real
    PNG headers.
  - `scripts/verify-basic.mjs`: the `merge=union` driver dropped closing braces where
    flow blocks stacked; the file was reconciled deterministically and a shared image
    fixture made a real PNG before the read-tool downgrade smoke.

## Per-flow remaining work

### Flow 01 — Inventory & parity ledger — DONE
- `src/pi/upstream.zig` runtime mirror still covers only a subset of the inventory.

### Flow 02 — CLI parser/help — ~95%
- Diagnostic message *text* differs from upstream (kind/control-flow match); embedding
  the offending arg requires touching the shared `Diagnostic` model.
- Piped stdin capped at 10 MiB; upstream unbounded.

### Flow 03 — Package manager / settings — in progress
- Legacy global npm root fallback (`npm root -g` / pnpm global list) not ported.
- `markPathIgnoredByCloudSync` (Dropbox/iCloud xattr hint) not ported.
- `GIT_TERMINAL_PROMPT=0` not injected into git clone/fetch.
- Windows native-dependency quarantine missing.

### Flow 04 — Providers / OAuth — in progress
- Live cloud token refresh unexercised (no creds); shapes match upstream.
- Bedrock SigV4-from-IAM (keys/profile/session-token) not implemented (AWS-SDK-only upstream).
- Vertex ADC `application_default_credentials.json` → access-token minting not implemented.

### Flow 05 — Models registry — verified
- Auth-filtered model cycling (`_cycleAvailableModel` over `getAvailable()`) lives in the
  runtime layer, not the stateless CLI catalog; catalog/resolver are at parity.

### Flow 06 — Agent runtime — ~99%
- **Hard socket-level cancellation** while blocked inside Zig `std.http` is impossible
  (no abort API); cooperative cancellation is in place. Documented, isolated.
- Google/Vertex **text & thinking-block `thoughtSignature` persistence** not implemented
  (function-call signatures are); needs a message-level field threaded through
  `ChatCompletionResult` → `agent.OwnedMessage` → `rpc.StoredMessage` → session JSONL.
- Image **generation** worker not wired into the coding-agent runtime (upstream exposes
  it only as a standalone `ai.generateImages()` API); image **resize** gate is done.
- `images.autoResize=false` per-session setting not yet threaded into the read tool.
- JSON/print-mode retry classifier could also retry `ProviderStreamIncomplete` for full
  cross-mode parity (RPC path done).

### Flow 07 — Extensions — ~80%
- One Node process per hook/command invocation, so module state does not persist across
  *separate* RPC command invocations (upstream keeps one process per session).
- `before_provider_request` / `after_provider_response` / `resources_discover` and richer
  session-replacement events defined but not yet driven from Zig.
- Interactive/TUI-only UI methods (`ctx.ui.custom`, `setWidget`, …) remain headless no-ops.

### Flow 08 — Built-in tools — ~88%
- Unicode **NFKC** fuzzy folding for edits (fullwidth punctuation/alphanumerics, combining
  marks) not implemented (Zig std lacks NFKC tables); targeted smart-punctuation is covered.
- Schemas emit `additionalProperties:false` on all 7 tools vs upstream only on `edit`
  (behaviorally inert under `strict:false`) — left as-is, flagged for decision.

### Flow 09 — Sessions / compaction / HTML export — in progress
- HTML export renders equivalent static content; upstream's interactive SPA (sidebar tree,
  search, markdown via marked, syntax highlight), theme colors, timestamps not ported.
- Compaction uses the existing `buildSessionContext` summary path; full LLM-driven
  compaction runtime is the larger remaining piece (weight kept at 50%).

### Flow 10 — TUI renderer — ~40% (from 0%)
- Terminal renderer + non-TTY fallback + interactive entrypoint exist; **live-interaction
  parity is proven only via dev-time pty transcripts, not automated tests.**
- Command palette, model selector, session/fork/compact/export controls, and the extension
  UI-context bridge are not yet at parity.

### Flow 11 — Preact workbench — ~65% (from 25%)
- SPA does not yet send **live NDJSON** to the backend child in the packaged path (renders
  against the dev fake-provider/RPC bridge); mobile-width polish pending.

### Flow 12 — Prin7r integration — foundation (from 0%)
- Real Prin7r-side apply is **dry-run-only** until the controller authorizes the integration
  phase; the installer stub must be finalized against Prin7r's then-current app registry.
- Host-triple-only release binary (cross/Linux-container build is a follow-up patch package).
- Live SPA↔backend wiring + rebuilt-and-inspected Prin7r app bundle pending.

## Required next steps to approach 100%

Detailed controller task: `docs/tasks/2026-05-28-parity-closure-task.md`.

1. Flow 10: automated TUI interaction harness (pty-driven) + remaining controls/bridge.
2. Flow 11: wire the SPA to a live backend child over NDJSON in the packaged path.
3. Flow 06: Google/Vertex thinking-signature persistence; cross-mode retry parity.
4. Flow 09: LLM-driven compaction runtime; HTML export SPA/markdown parity.
5. Flow 04: live OAuth refresh validation; Bedrock SigV4 + Vertex ADC (need cloud creds).
6. Flow 12: controller-authorized Prin7r injection, then build + inspect the app bundle.

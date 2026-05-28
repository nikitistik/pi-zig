#!/usr/bin/env node
/**
 * Create the pi-zig-parity pipeline + 10 epic tasks (A-J) + ~95 subtasks in
 * nulltickets (http://127.0.0.1:7700), each carrying Context / Definition of
 * Done / Requirements / Dependencies, then dump a JSON snapshot to
 * docs/research/MASTER-GAPS.json and a human-readable docs/research/MASTER-GAPS.md.
 *
 * Tasks are keyed to this project via metadata.project_path = /Users/keer/projects/pi-zig
 * so the Prin7r workspace can filter them when this folder is opened.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const API = 'http://127.0.0.1:7700';
const PROJECT_PATH = repoRoot;
const PROJECT_ID = 'pi-zig';

const log = (...a) => console.log('[parity-tickets]', ...a);
const fail = (m) => { console.error('[parity-tickets] FAIL:', m); process.exit(1); };

async function http(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { 'content-type': 'application/json' },
    body: body == null ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (res.status >= 300) fail(`${method} ${path} -> ${res.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}

// Cursor-paginate `/tasks?pipeline_id=...` until exhausted.
async function listAllPipelineTasks(pipelineId) {
  const out = [];
  let cursor = '';
  while (true) {
    const q = `pipeline_id=${encodeURIComponent(pipelineId)}&limit=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`;
    const resp = await http('GET', `/tasks?${q}`);
    const items = resp?.items ?? [];
    for (const t of items) out.push(t);
    cursor = resp?.next_cursor || '';
    if (!cursor || items.length === 0) break;
  }
  return out;
}

// ─── Pipeline definition (linear with blocked/cancelled escape hatches) ──────
const pipelineDef = {
  initial: 'backlog',
  states: {
    backlog:     { agent_role: 'pi-zig-parity-worker', description: 'Ready to be claimed.' },
    in_progress: { agent_role: 'pi-zig-parity-worker', description: 'Active implementation.' },
    review:      { agent_role: 'pi-zig-parity-reviewer', description: 'Awaiting verification.' },
    blocked:     { agent_role: 'pi-zig-parity-worker', description: 'Waiting on a dependency or external input.' },
    done:        { terminal: true, description: 'Implemented + tested + verified vs upstream.' },
    cancelled:   { terminal: true, description: 'Out of scope or superseded.' },
  },
  transitions: [
    { from: 'backlog',     to: 'in_progress', trigger: 'start' },
    { from: 'in_progress', to: 'review',      trigger: 'submit' },
    { from: 'review',      to: 'done',        trigger: 'approve' },
    { from: 'review',      to: 'in_progress', trigger: 'changes_requested' },
    { from: 'in_progress', to: 'blocked',     trigger: 'block' },
    { from: 'blocked',     to: 'in_progress', trigger: 'unblock' },
    { from: 'backlog',     to: 'cancelled',   trigger: 'cancel' },
    { from: 'in_progress', to: 'cancelled',   trigger: 'cancel' },
    { from: 'review',      to: 'cancelled',   trigger: 'cancel' },
    { from: 'blocked',     to: 'cancelled',   trigger: 'cancel' },
  ],
};

// ─── Epics (A-J) — the 10 categories ─────────────────────────────────────────
const epics = [
  { id: 'A', title: 'A — Agent-session runtime',     gap: 'docs/research/gap-01-agent-session.md',          parity: '25-30%' },
  { id: 'B', title: 'B — Auth / HTTP / Settings',    gap: 'docs/research/gap-02-auth-http-settings.md',     parity: '45%' },
  { id: 'C', title: 'C — Messages / Compaction',     gap: 'docs/research/gap-03-messages-compaction.md',    parity: '47%' },
  { id: 'D', title: 'D — Modes / CLI / Main',        gap: 'docs/research/gap-05-modes-cli-main.md',         parity: '63%' },
  { id: 'E', title: 'E — Interactive TUI',           gap: 'docs/research/gap-06-interactive-tui.md',        parity: '10%' },
  { id: 'F', title: 'F — Agent package library',     gap: 'docs/research/gap-07-agent-package.md',          parity: '55%' },
  { id: 'G', title: 'G — AI providers',              gap: 'docs/research/gap-08-ai-providers.md',           parity: '40-50%' },
  { id: 'H', title: 'H — AI core',                   gap: 'docs/research/gap-09-ai-core.md',                parity: '43%' },
  { id: 'I', title: 'I — Tools / Extensions / Resources', gap: 'docs/research/gap-04-tools-extensions-resources.md', parity: '47%' },
  { id: 'J', title: 'J — TUI primitives',            gap: 'docs/research/gap-10-tui-primitives.md',         parity: '20%' },
];

// ─── Subtasks — one entry per actionable upstream surface ───────────────────
// Each subtask has: code, epic, title, context, dod, requirements (array), upstream,
// pizig (where it should land), depends (array of subtask codes), priority,
// complexity ('Low'|'Medium'|'High').
const subtasks = [
  // ──── A: Agent-session runtime ────────────────────────────────────────────
  { code: 'A1',  epic: 'A', title: 'Port event-bus.ts → event_bus.zig',
    context: 'Upstream packages/coding-agent/src/core/event-bus.ts (33 LoC) provides a typed pub/sub bus used by every emitted lifecycle event. pi-zig has NO equivalent module.',
    dod: 'New src/pi/event_bus.zig with subscribe/publish + per-event handler lists; unit tests cover ordering, multiple subscribers, removal mid-dispatch; wired into agent.zig + rpc.zig.',
    requirements: ['No stubs', 'Type-safe per-event payload', 'Re-entrant dispatch supported', 'Zig 0.16 idioms'],
    upstream: 'packages/coding-agent/src/core/event-bus.ts:1-33', pizig: 'NEW src/pi/event_bus.zig',
    depends: [], priority: 90, complexity: 'Low' },
  { code: 'A2',  epic: 'A', title: 'Port telemetry.ts → telemetry.zig',
    context: 'Upstream telemetry.ts (13 LoC) exports a minimal telemetry sink interface that other modules call. pi-zig has no equivalent.',
    dod: 'src/pi/telemetry.zig with structured event emission; optional OTLP forwarding path stubbed cleanly (skip without endpoint); unit tests.',
    requirements: ['Honest skip when no endpoint', 'No PII'],
    upstream: 'packages/coding-agent/src/core/telemetry.ts:1-13', pizig: 'NEW src/pi/telemetry.zig',
    depends: ['A1'], priority: 60, complexity: 'Low' },
  { code: 'A3',  epic: 'A', title: 'Port timings.ts → timings.zig',
    context: 'Upstream timings.ts (31 LoC) records spans + durations for prompt/turn/tool execution. pi-zig has no equivalent.',
    dod: 'src/pi/timings.zig with start/stop span API; emitted into event_bus; unit tests cover nested spans.',
    requirements: ['Monotonic clock', 'Nested span support'],
    upstream: 'packages/coding-agent/src/core/timings.ts:1-31', pizig: 'NEW src/pi/timings.zig',
    depends: ['A1'], priority: 60, complexity: 'Low' },
  { code: 'A4',  epic: 'A', title: 'Port exec.ts → exec.zig',
    context: 'Upstream exec.ts (107 LoC) is the cross-platform process exec helper used by tools and the agent harness. pi-zig calls std.process.run directly in scattered sites.',
    dod: 'src/pi/exec.zig with consolidated exec API (env, cwd, stdin, timeout, signal); callers refactored where it removes duplication.',
    requirements: ['Cooperative cancellation', 'stdout+stderr capture'],
    upstream: 'packages/coding-agent/src/core/exec.ts:1-107', pizig: 'NEW src/pi/exec.zig',
    depends: [], priority: 70, complexity: 'Medium' },
  { code: 'A5',  epic: 'A', title: 'Full FooterDataProvider (watcher + worktrees + reftable + extension statuses + provider badge)',
    context: 'Upstream footer-data-provider.ts (354 LoC) feeds the live footer: git branch with reftable + worktree awareness, watched extension health badges, provider/model + thinking-level + token usage + cost. pi-zig\'s current `resolveGitBranch` (tui.zig) is a one-shot stub that runs `git symbolic-ref` once.',
    dod: 'src/pi/footer_data.zig that exposes a FooterData struct mirroring upstream\'s fields; fs.watch on .git/HEAD + worktrees + extension manifests; subscriber API for tui_footer.zig; unit tests + smoke driving a real worktree switch.',
    requirements: ['fs.watch / poll fallback', 'Reactive update', 'Per-token costs from Usage'],
    upstream: 'packages/coding-agent/src/core/footer-data-provider.ts:1-354', pizig: 'NEW src/pi/footer_data.zig',
    depends: ['A1', 'H1'], priority: 80, complexity: 'High' },
  { code: 'A6',  epic: 'A', title: 'Wire all missing AgentSessionEvent dispatches',
    context: 'Upstream emits 29+ AgentSessionEvents; pi-zig advertises them in upstream.zig but DOES NOT actually dispatch ~17 of them (session_before_compact, session_compact, session_before_tree, session_tree, session_before_fork, session_before_switch, queue_update, compaction_start/end, session_info_changed, thinking_level_changed, model_select, thinking_level_select, message_update, tool_execution_*, before_agent_start, resources_discover, context, input).',
    dod: 'Each missing event has a concrete dispatch site in rpc.zig/agent.zig with the upstream payload shape; extensions receive them via the existing FLOW_J seam; per-event smoke proves the extension handler observes the event.',
    requirements: ['No fire-and-forget where upstream chains values (must honor returned transforms)', 'Test each event independently'],
    upstream: 'packages/coding-agent/src/core/agent-session.ts (event emit sites)', pizig: 'src/pi/rpc.zig + src/pi/agent.zig FLOW_J regions',
    depends: ['A1', 'I3'], priority: 95, complexity: 'High' },
  { code: 'A7',  epic: 'A', title: 'importFromJsonl / exportToJsonl / reload',
    context: 'Upstream session-manager exposes importFromJsonl, exportToJsonl, reload(); none exist in pi-zig.',
    dod: 'src/pi/session.zig gains the three functions with byte-exact JSONL round-trip; unit tests cover empty/malformed/header-only sessions.',
    requirements: ['Round-trip equality', 'Atomic file replace'],
    upstream: 'packages/coding-agent/src/core/session-manager.ts', pizig: 'src/pi/session.zig',
    depends: [], priority: 70, complexity: 'Medium' },
  { code: 'A8',  epic: 'A', title: 'createAgentSessionServices / FromServices / Runtime factory pattern',
    context: 'Upstream uses a 3-layer factory: createAgentSessionServices (wire services), createAgentSessionFromServices (compose), createAgentSessionRuntime (drive). pi-zig builds Runtime once at process start; cannot tear down and rebuild mid-process.',
    dod: 'Refactor agent.zig + rpc.zig so a Runtime can be (re)constructed from a Services struct; in-process swap supported; unit test exercises two sequential lifetimes.',
    requirements: ['No leaks on swap', 'Outstanding work cancelled cleanly'],
    upstream: 'packages/coding-agent/src/core/agent-session-services.ts + agent-session-runtime.ts', pizig: 'src/pi/agent.zig + src/pi/rpc.zig',
    depends: ['A1'], priority: 50, complexity: 'High' },
  { code: 'A9',  epic: 'A', title: 'getAttributionHeaders (OpenRouter / Cloudflare / opencode)',
    context: 'Upstream attaches HTTP attribution headers (HTTP-Referer, X-Title, opencode session id) on provider requests. pi-zig sends none.',
    dod: 'ai_client.zig adds attribution-header construction gated by provider id; smoke asserts headers on outgoing requests.',
    requirements: ['No PII', 'Per-provider exact header names'],
    upstream: 'packages/ai/src/providers/* (search getAttributionHeaders)', pizig: 'src/pi/ai_client.zig',
    depends: [], priority: 60, complexity: 'Low' },
  { code: 'A10', epic: 'A', title: 'excludeFromContext (!! prefix), scoped-models cycling, setRebindSession, withSession, nextTurn custom messages, before_agent_start system-prompt override, dynamic image filtering',
    context: 'Cluster of session-control features missing entirely. excludeFromContext lets a user message with `!!` prefix run a bash without entering the LLM context; scoped-models cycles a curated subset; setRebindSession swaps the bound session; withSession() wraps a callback in a session; before_agent_start hook can replace the system prompt per turn; blockImages dynamically strips images from outgoing messages.',
    dod: 'Each sub-feature has a code path + unit test + integration smoke; documented in docs/parity.md per-feature row.',
    requirements: ['No silent failures', 'Per-feature smoke against fake provider'],
    upstream: 'packages/coding-agent/src/core/agent-session.ts', pizig: 'src/pi/rpc.zig + src/pi/agent.zig',
    depends: ['A6'], priority: 70, complexity: 'High' },

  // ──── B: Auth / HTTP / Settings ───────────────────────────────────────────
  { code: 'B1', epic: 'B', title: 'AuthStorage class abstraction + runtime --api-key override + models.json fallback',
    context: 'Upstream AuthStorage class exposes get/set/list with runtime --api-key override and models.json fallback for custom providers. pi-zig\'s auth.zig has flat function helpers and only 3 of 6 upstream source arms in status output; no runtime --api-key override.',
    dod: 'src/pi/auth_storage.zig with full AuthStorage API + `--api-key` override + models.json fallback resolver; status output covers all 6 source arms; unit tests for each source.',
    requirements: ['Thread-safe', 'No secrets in logs'],
    upstream: 'packages/coding-agent/src/core/auth-storage.ts', pizig: 'NEW src/pi/auth_storage.zig',
    depends: [], priority: 85, complexity: 'High' },
  { code: 'B2', epic: 'B', title: 'Interactive OAuth login: PKCE + device-code + local callback HTTP server',
    context: 'pi-zig\'s interactive login (auth.zig:1431-1447) always returns InteractiveLoginUnavailable. Upstream supports PKCE for Anthropic, device-code for OpenAI Codex + GitHub Copilot, local callback HTTP server, manual-paste fallback.',
    dod: 'src/pi/auth_login.zig with PKCE generator, callback server, device-code polling for each of the 3 OAuth providers; live-cred opt-in smokes (skip cleanly without creds); never print secrets.',
    requirements: ['No secrets logged', 'Browser open via std.process'],
    upstream: 'packages/ai/src/utils/oauth/* + packages/coding-agent/src/core/auth-guidance.ts', pizig: 'NEW src/pi/auth_login.zig',
    depends: ['B1'], priority: 80, complexity: 'High' },
  { code: 'B3', epic: 'B', title: 'Cross-process file lock for auth.json + chmod 0o600',
    context: 'Concurrent pi-zig instances can clobber freshly minted OAuth tokens. Upstream uses flock. pi-zig has none. File mode is default (group-readable on most setups).',
    dod: 'auth.json reads/writes wrapped in OS-appropriate advisory lock; chmod 0o600 on write; unit test triggers two concurrent writes and verifies last-writer-wins atomic.',
    requirements: ['Lock timeout configurable', 'macOS + Linux'],
    upstream: 'packages/coding-agent/src/core/auth-storage.ts (writeAuthStorage)', pizig: 'src/pi/auth.zig',
    depends: ['B1'], priority: 90, complexity: 'Medium' },
  { code: 'B4', epic: 'B', title: 'configureHttpDispatcher with runtime httpIdleTimeoutMs effect',
    context: 'pi-zig parses httpIdleTimeoutMs from settings and shows it but it has ZERO runtime effect on actual HTTP traffic. Upstream\'s http-dispatcher applies it.',
    dod: 'src/pi/http_dispatcher.zig that wraps std.http.Client with idle-timeout enforcement; setting changes propagate live; smoke proves a slow server times out at the configured value.',
    requirements: ['Configurable per-request override', 'Honor "disabled" → 0'],
    upstream: 'packages/coding-agent/src/core/http-dispatcher.ts', pizig: 'NEW src/pi/http_dispatcher.zig',
    depends: [], priority: 75, complexity: 'Medium' },
  { code: 'B5', epic: 'B', title: 'session-cwd.ts: persist cwd into session header, missing-cwd check',
    context: 'Upstream session-cwd.ts persists project cwd into the session JSONL header and exposes a missing-cwd check. pi-zig writes `"cwd":"."` (hardcoded) so the precondition is destroyed.',
    dod: 'Session header carries the real absolute cwd; missing-cwd check refuses to load when target cwd is gone; unit + smoke.',
    requirements: ['Absolute path', 'Symlink-stable'],
    upstream: 'packages/coding-agent/src/core/session-cwd.ts', pizig: 'src/pi/session.zig',
    depends: [], priority: 80, complexity: 'Low' },
  { code: 'B6', epic: 'B', title: 'output-guard.ts: stdout takeover + ENOBUFS-retry backpressure pump',
    context: 'Upstream output-guard.ts owns the stdout takeover for JSON/RPC modes and applies ENOBUFS-retry backpressure on writes. pi-zig has no such layer.',
    dod: 'src/pi/output_guard.zig with write pump + ENOBUFS retry + flush guarantees; rpc.zig and JSON mode routed through it; unit test with a fake non-blocking pipe.',
    requirements: ['No write reordering', 'EOF safe'],
    upstream: 'packages/coding-agent/src/core/output-guard.ts', pizig: 'NEW src/pi/output_guard.zig',
    depends: [], priority: 75, complexity: 'Medium' },
  { code: 'B7', epic: 'B', title: 'auth-guidance.ts: 4 shared formatter functions',
    context: 'Upstream auth-guidance.ts exports 4 shared formatter functions used in CLI error messages. Absent in pi-zig.',
    dod: 'Helper functions ported with byte-exact strings; reused from auth + cli_runtime error paths; unit tests pin the exact strings.',
    requirements: ['Byte-exact upstream strings'],
    upstream: 'packages/coding-agent/src/core/auth-guidance.ts', pizig: 'src/pi/auth.zig',
    depends: ['B1'], priority: 50, complexity: 'Low' },
  { code: 'B8', epic: 'B', title: 'diagnostics.ts schemas: ResourceCollision + ResourceDiagnostic',
    context: 'Upstream diagnostics.ts defines two TypeBox schemas (ResourceCollision, ResourceDiagnostic) consumed by commands/themes. pi-zig emits a similar JSON but has no type/schema.',
    dod: 'src/pi/diagnostics.zig with the two structs + JSON serialization; commands.zig and themes.zig use them.',
    requirements: ['Schema matches upstream field names'],
    upstream: 'packages/coding-agent/src/core/diagnostics.ts', pizig: 'NEW src/pi/diagnostics.zig',
    depends: [], priority: 60, complexity: 'Low' },
  { code: 'B9', epic: 'B', title: 'resolveConfigValue cache + resolveHeaders helper',
    context: 'Upstream caches `!cmd` shell-resolved values; pi-zig re-runs the shell exec on every call. Upstream has a separate resolveHeaders that expands `!cmd` per-header.',
    dod: 'auth.zig adds a cache (TTL configurable) + resolveHeaders helper; unit test ensures cache hit on repeated read.',
    requirements: ['TTL semantics', 'No stale tokens'],
    upstream: 'packages/coding-agent/src/core/resolve-config-value.ts', pizig: 'src/pi/auth.zig',
    depends: [], priority: 55, complexity: 'Low' },
  { code: 'B10', epic: 'B', title: 'Settings write-path per-field validation + clamping',
    context: 'Settings READ-path validates but WRITE-path doesn\'t. Bad values land in settings.json silently.',
    dod: 'Each write path validates + clamps per upstream rules; bad input rejected with diagnostic; unit tests per field.',
    requirements: ['Match upstream error strings'],
    upstream: 'packages/coding-agent/src/core/settings-manager.ts', pizig: 'src/pi/settings.zig',
    depends: [], priority: 50, complexity: 'Medium' },

  // ──── C: Messages / Compaction ────────────────────────────────────────────
  { code: 'C1', epic: 'C', title: 'Compaction: findCutPoint + keepRecentTokens + split-turn',
    context: 'Upstream compaction preserves a "recent window" and can split a turn boundary. pi-zig compacts the entire ring (no recent window) and never splits a turn.',
    dod: 'src/pi/compaction.zig with findCutPoint / keepRecentTokens / split-turn helpers; rpc.zig FLOW_E uses them; unit tests cover token-budget edge cases.',
    requirements: ['Match upstream cut semantics byte-for-byte', 'Token budget from Usage'],
    upstream: 'packages/coding-agent/src/core/compaction/', pizig: 'NEW src/pi/compaction.zig',
    depends: ['H1', 'C3'], priority: 85, complexity: 'High' },
  { code: 'C2', epic: 'C', title: 'UPDATE_SUMMARIZATION_PROMPT + TURN_PREFIX_SUMMARIZATION_PROMPT',
    context: 'Two summarization prompt constants used when re-summarizing on top of an existing compaction or prefixing a turn. Absent in pi-zig.',
    dod: 'Constants ported byte-exact; used by FLOW_E compaction code path.',
    requirements: ['Byte-exact'],
    upstream: 'packages/coding-agent/src/core/compaction/', pizig: 'src/pi/rpc.zig FLOW_E',
    depends: ['C1'], priority: 70, complexity: 'Low' },
  { code: 'C3', epic: 'C', title: 'estimateContextTokens from Usage',
    context: 'pi-zig estimates tokens by chars/4. Upstream uses provider-reported Usage. Requires Usage in ChatCompletionResult.',
    dod: 'ChatCompletionResult carries Usage; compaction trigger reads it; unit tests check overflow trigger fires when usage exceeds budget.',
    requirements: ['Per-provider usage parse'],
    upstream: 'packages/coding-agent/src/core/compaction/', pizig: 'src/pi/ai_client.zig + src/pi/rpc.zig',
    depends: ['H1'], priority: 80, complexity: 'Medium' },
  { code: 'C4', epic: 'C', title: 'Fix firstKeptEntryId semantic (currently OPPOSITE of upstream)',
    context: 'pi-zig sets firstKeptEntryId = messages[0].entryId() — the FIRST message. Upstream sets it to the first KEPT message after compaction (typically the last one before the cut). Reload misbehaves.',
    dod: 'Semantic corrected; reload tests pass; round-trip exercises pre/post-compaction state.',
    requirements: ['Reload-stable'],
    upstream: 'packages/coding-agent/src/core/compaction/', pizig: 'src/pi/rpc.zig FLOW_E',
    depends: ['C1'], priority: 95, complexity: 'Low' },
  { code: 'C5', epic: 'C', title: 'parseStoredRole / loadSessionEntries: recognize branchSummary',
    context: 'Upstream stores branch_summary as a role-tagged entry; on reload pi-zig\'s parseStoredRole DOES NOT recognize the branchSummary role, so branch_summary entries don\'t re-inject into in-memory context.',
    dod: 'parseStoredRole supports branchSummary; loadSessionEntries loads them; re-injects on reload; round-trip test.',
    requirements: ['Round-trip stable'],
    upstream: 'packages/coding-agent/src/core/messages.ts', pizig: 'src/pi/rpc.zig',
    depends: [], priority: 85, complexity: 'Low' },
  { code: 'C6', epic: 'C', title: 'BRANCH_SUMMARY_PREFIX/SUFFIX constants + BranchSummaryDetails {readFiles, modifiedFiles, replaceInstructions, BRANCH_SUMMARY_PREAMBLE}',
    context: 'Upstream wraps branch_summary entries in PREFIX/SUFFIX and carries file-ops details. Absent in pi-zig.',
    dod: 'Constants + struct ported; FLOW_G writes them; unit tests assert the on-disk JSONL shape.',
    requirements: ['Byte-exact'],
    upstream: 'packages/coding-agent/src/core/messages.ts + compaction/', pizig: 'src/pi/rpc.zig FLOW_G',
    depends: ['C5'], priority: 75, complexity: 'Medium' },
  { code: 'C7', epic: 'C', title: 'Wire remaining 9 of 21 builtin slash commands',
    context: 'tui.zig:runCommand reports "recognized but not yet wired" for ~9 of 21 slash commands. The user demanded no stubs.',
    dod: 'Each remaining command is fully implemented (real handler, not "not yet wired"); per-command App-level unit test; smoke proves CLI-observable behavior where applicable.',
    requirements: ['No "not yet wired" lines remain in tui.zig'],
    upstream: 'packages/coding-agent/src/core/slash-commands.ts', pizig: 'src/pi/tui.zig + src/pi/cli_runtime.zig',
    depends: [], priority: 90, complexity: 'High' },
  { code: 'C8', epic: 'C', title: 'KeybindingsManager: 43 ids + keybindings.json loader + KEYBINDING_NAME_MIGRATIONS + Windows special cases',
    context: 'pi-zig covers ~12 of 43 upstream AppKeybindings ids; no keybindings.json loader, no migrations, no Windows differences.',
    dod: 'src/pi/keybindings.zig (new) with full id list + JSON loader + migrations table + Windows variants; unit tests per id.',
    requirements: ['Migration table byte-exact'],
    upstream: 'packages/coding-agent/src/core/keybindings.ts', pizig: 'NEW src/pi/keybindings.zig',
    depends: [], priority: 75, complexity: 'High' },
  { code: 'C9', epic: 'C', title: 'SessionManager: list / listAll / inMemory / continueRecent / createBranchedSession',
    context: 'Upstream surfaces 5 session-level operations missing in pi-zig.',
    dod: 'Each function ported; unit tests + smoke; CLI `--resume` picker (D6) consumes list output.',
    requirements: ['mtime-sorted', 'Cross-cwd safe'],
    upstream: 'packages/coding-agent/src/core/session-manager.ts', pizig: 'src/pi/session.zig',
    depends: [], priority: 80, complexity: 'Medium' },
  { code: 'C10', epic: 'C', title: 'LabelEntry: appendLabelChange + getLabel',
    context: 'Upstream session JSONL supports LabelEntry rows; pi-zig has no such entry type.',
    dod: 'session.zig writes/reads LabelEntry; appendLabelChange/getLabel; round-trip test.',
    requirements: ['JSONL schema matches upstream'],
    upstream: 'packages/coding-agent/src/core/session-manager.ts', pizig: 'src/pi/session.zig',
    depends: [], priority: 50, complexity: 'Low' },
  { code: 'C11', epic: 'C', title: 'Fix hardcoded session-header cwd="." and timestamp="local-foundation"',
    context: 'session.zig:108 writes `"cwd":"."`; timestamp is a placeholder string. Upstream writes the real absolute cwd + ISO timestamp.',
    dod: 'Real cwd + ISO timestamp; backward-load is tolerant of legacy values; smoke verifies fresh session header.',
    requirements: ['ISO 8601 timestamp', 'Absolute cwd'],
    upstream: 'packages/coding-agent/src/core/session-manager.ts + session-cwd.ts', pizig: 'src/pi/session.zig',
    depends: ['B5'], priority: 75, complexity: 'Low' },
  { code: 'C12', epic: 'C', title: 'Multi-version session loading (v1→v2, v2→v3 migrations)',
    context: 'pi-zig rejects any session whose header is not version:3. Upstream migrates v1→v2 and v2→v3 on load.',
    dod: 'Migration functions ported; reload of legacy session works; round-trip test per migration.',
    requirements: ['Lossless'],
    upstream: 'packages/coding-agent/src/core/session-manager.ts', pizig: 'src/pi/session.zig',
    depends: ['C11'], priority: 55, complexity: 'Medium' },
  { code: 'C13', epic: 'C', title: 'excludeFromContext (!! prefix) modeled in messages',
    context: 'A user message starting with `!!` runs a bash but is NOT entered into the LLM context. Not modeled in pi-zig\'s messages.',
    dod: 'Message type carries excludeFromContext flag; provider history skips them; smoke shows the bash ran and the assistant didn\'t see the message.',
    requirements: ['Flag persisted'],
    upstream: 'packages/coding-agent/src/core/messages.ts', pizig: 'src/pi/session.zig + src/pi/rpc.zig',
    depends: [], priority: 60, complexity: 'Medium' },
  { code: 'C14', epic: 'C', title: 'CustomMessage.details + image-block content persisted',
    context: 'CustomMessage.details (free-form JSON) and image-block content are NOT persisted by pi-zig\'s appendCustomMessage.',
    dod: 'JSONL carries details + image parts; reload restores them; unit test round-trip.',
    requirements: ['Schema matches upstream'],
    upstream: 'packages/coding-agent/src/core/messages.ts', pizig: 'src/pi/session.zig',
    depends: [], priority: 55, complexity: 'Low' },
  { code: 'C15', epic: 'C', title: 'Source-info: SourceScope / SourceOrigin / SourceInfo + createSourceInfo / createSyntheticSourceInfo',
    context: 'Upstream models source-info as 3 typed scopes + factory functions. pi-zig only serializes JSON via writeSourceInfoWithOrigin; no types/factories.',
    dod: 'src/pi/source_info.zig with the 3 types + factory functions; commands.zig consumes them; unit tests.',
    requirements: ['Type-safe'],
    upstream: 'packages/coding-agent/src/core/source-info.ts', pizig: 'NEW src/pi/source_info.zig',
    depends: [], priority: 45, complexity: 'Low' },

  // ──── D: Modes / CLI / Main ───────────────────────────────────────────────
  { code: 'D1', epic: 'D', title: 'Migrations: 5 missing (auth-to-json, sessions-from-agent-root, commands-to-prompts, tools-to-bin, keybindings-config-file)',
    context: 'Upstream migrations.ts runs 5 one-shot migrations on first launch. pi-zig has 0% of this.',
    dod: 'src/pi/migrations.zig with all 5 migrations; idempotent; runs on cli_runtime entrypoint; unit tests verify each migration\'s before/after on a temp dir.',
    requirements: ['Idempotent', 'Atomic'],
    upstream: 'packages/coding-agent/src/migrations.ts', pizig: 'NEW src/pi/migrations.zig',
    depends: [], priority: 75, complexity: 'Medium' },
  { code: 'D2', epic: 'D', title: 'RpcClient programmatic API',
    context: 'Upstream exports an RpcClient class for embedders (Node/TS callers). pi-zig has no equivalent — consumers must speak JSONL directly.',
    dod: 'src/pi/rpc_client.zig (Zig embedder API) + a frontend client wrapper if needed; smoke drives it.',
    requirements: ['Type-safe wrappers per command'],
    upstream: 'packages/coding-agent/src/modes/rpc/rpc-client.ts', pizig: 'NEW src/pi/rpc_client.zig',
    depends: [], priority: 50, complexity: 'Medium' },
  { code: 'D3', epic: 'D', title: 'utils/ closures: clipboard, image-resize, syntax-highlight, version-check, tools-manager, Windows self-update quarantine, changelog parser',
    context: 'pi-zig\'s utils coverage is ~30%; 7 specific helpers missing.',
    dod: 'Each helper has a Zig port (or honest shell-out for image-resize); per-helper unit test.',
    requirements: ['No PII', 'Cross-platform'],
    upstream: 'packages/coding-agent/src/utils/*', pizig: 'src/pi/cli_runtime.zig + new utils modules',
    depends: [], priority: 65, complexity: 'High' },
  { code: 'D4', epic: 'D', title: 'cli/ closures: selectConfig, selectSession, listModels text rendering, image-resize processFileArguments',
    context: 'pi-zig\'s cli/ coverage is ~40%.',
    dod: 'Each function ported; smoke verifies CLI-observable text output.',
    requirements: ['Byte-exact upstream output where applicable'],
    upstream: 'packages/coding-agent/src/cli/*', pizig: 'src/pi/cli.zig + src/pi/cli_runtime.zig',
    depends: [], priority: 60, complexity: 'Medium' },
  { code: 'D5', epic: 'D', title: '`pi config` TUI',
    context: 'Upstream `pi config` opens a TUI for resource enable/disable. pi-zig has no such command.',
    dod: 'New subcommand `pi-zig config` opens a TUI dialog (via tui_selector) to toggle resources; persisted to settings.',
    requirements: ['Live reflect to settings.json'],
    upstream: 'packages/coding-agent/src/cli/config-selector.ts', pizig: 'src/pi/cli_runtime.zig + new tui module',
    depends: ['E1'], priority: 60, complexity: 'High' },
  { code: 'D6', epic: 'D', title: '`--resume` session picker UI',
    context: 'pi-zig opens the newest session directly. Upstream offers a picker UI.',
    dod: 'TUI picker built on tui_selector; smoke drives selection by index.',
    requirements: ['Sorted mtime', 'Cross-cwd'],
    upstream: 'packages/coding-agent/src/cli/session-selector', pizig: 'src/pi/cli_runtime.zig',
    depends: ['E1', 'C9'], priority: 60, complexity: 'Medium' },
  { code: 'D7', epic: 'D', title: '`--session` cross-project global prompt',
    context: 'Upstream supports a cross-project session prompt. pi-zig is project-local.',
    dod: '--session can target any cwd; safety: refuse if cwd missing; unit test.',
    requirements: ['Refuse missing cwd'],
    upstream: 'packages/coding-agent/src/cli/args.ts', pizig: 'src/pi/cli_runtime.zig',
    depends: ['B5'], priority: 45, complexity: 'Low' },
  { code: 'D8', epic: 'D', title: '`--api-key` without `--model` diagnostic',
    context: 'Upstream emits a specific error when --api-key is supplied without --model. pi-zig silently ignores.',
    dod: 'Exact upstream diagnostic emitted; unit test pins the string.',
    requirements: ['Byte-exact'],
    upstream: 'packages/coding-agent/src/cli/args.ts', pizig: 'src/pi/cli.zig',
    depends: [], priority: 40, complexity: 'Low' },
  { code: 'D9', epic: 'D', title: '`queue_update` RPC event',
    context: 'Upstream emits queue_update events whenever steering/follow-up queue changes. pi-zig requires clients to poll.',
    dod: 'rpc.zig emits queue_update on every change; smoke asserts events flow.',
    requirements: ['Wire shape matches upstream'],
    upstream: 'packages/coding-agent/src/modes/rpc/rpc-mode.ts', pizig: 'src/pi/rpc.zig',
    depends: ['A6'], priority: 70, complexity: 'Low' },
  { code: 'D10', epic: 'D', title: 'Multi-message print mode (loop)',
    context: 'Upstream `for (const message of messages) await session.prompt(message)`; pi-zig folds multiple messages into one.',
    dod: 'Print-mode loops per-message; smoke proves N messages produce N assistant turns.',
    requirements: ['Order preserved'],
    upstream: 'packages/coding-agent/src/modes/print-mode.ts', pizig: 'src/pi/cli_runtime.zig',
    depends: [], priority: 55, complexity: 'Low' },
  { code: 'D11', epic: 'D', title: '`--list-models` text rendering',
    context: 'pi-zig emits JSON only; upstream has a tabular text mode (default).',
    dod: 'Default text rendering; --json keeps JSON output; unit test.',
    requirements: ['Match upstream column layout'],
    upstream: 'packages/coding-agent/src/cli/list-models.ts', pizig: 'src/pi/cli_runtime.zig',
    depends: [], priority: 35, complexity: 'Low' },

  // ──── E: Interactive TUI ──────────────────────────────────────────────────
  { code: 'E1', epic: 'E', title: 'Wire orphan tui_markdown / tui_footer / tui_messages / tui_theme / tui_selector into tui.zig + index.zig',
    context: 'These modules exist with passing unit tests but are NOT imported by tui.zig and NOT exported from src/pi/index.zig — dead code. The live binary never paints them.',
    dod: 'tui.zig:buildScreen routes user/assistant/tool/bash entries through tui_messages; transcript text routes through tui_markdown; bottom strip uses tui_footer; theme palette derived via tui_theme; overlay selectors use tui_selector; pty harness + browser screenshots show the live difference.',
    requirements: ['No dead modules', 'Each integration has at least one smoke assertion that the new render reaches stdout'],
    upstream: 'packages/coding-agent/src/modes/interactive/components/* + packages/tui/src/components/markdown.ts', pizig: 'src/pi/tui.zig + src/pi/index.zig',
    depends: [], priority: 100, complexity: 'Medium' },
  { code: 'E2', epic: 'E', title: 'Port 24 missing interactive components',
    context: '24 of 35 upstream components have NO equivalent: login-dialog, oauth-selector, session-selector, session-selector-search, tree-selector, settings-selector, scoped-models-selector, extension-editor, extension-input, extension-selector, config-selector, custom-editor, theme-selector, thinking-selector, show-images-selector, user-message-selector, dynamic-border, bordered-loader, custom-message, branch-summary-message, compaction-summary-message, skill-invocation-message, tool-execution, image.',
    dod: 'Each component has a Zig module + unit tests + integration smoke proving live render.',
    requirements: ['Box-drawing matches upstream square corners (not arc)'],
    upstream: 'packages/coding-agent/src/modes/interactive/components/*', pizig: 'NEW src/pi/tui_components/*.zig',
    depends: ['E1', 'J4'], priority: 95, complexity: 'High' },
  { code: 'E3', epic: 'E', title: 'Theme: full 49-token palette, truecolor, file watcher, COLORFGBG/OSC 11 detection, theme reload, markdown/syntax themes, /theme builtin',
    context: 'pi-zig consumes 6 of 49 upstream theme tokens; no truecolor; no watcher; no COLORFGBG/OSC 11 detection; /theme not even in builtin_commands.',
    dod: 'tui_theme.zig consumes all 49 tokens, truecolor support, file watcher reloads, COLORFGBG/OSC 11 read at startup, /theme command opens a theme selector; per-token unit tests.',
    requirements: ['Truecolor + 256-color fallback'],
    upstream: 'packages/coding-agent/src/modes/interactive/theme/theme.ts', pizig: 'src/pi/tui_theme.zig',
    depends: ['E1'], priority: 80, complexity: 'High' },
  { code: 'E4', epic: 'E', title: 'InteractiveMode controller: port remaining ~125 of 150 methods',
    context: 'Upstream\'s InteractiveMode (5564 LoC) has ~150 methods. pi-zig has ≤25. Missing entire subsystems: extension UI, message queueing/steering/follow-up, double-key timing, compaction/retry state, event-driven handleEvent (15-arm switch).',
    dod: 'Each missing subsystem ported with App-level unit tests + integration smoke; documented per-method coverage.',
    requirements: ['Behaviorally faithful'],
    upstream: 'packages/coding-agent/src/modes/interactive/interactive-mode.ts', pizig: 'src/pi/tui.zig + src/pi/cli_runtime.zig',
    depends: ['E1', 'E2', 'A6'], priority: 90, complexity: 'High' },
  { code: 'E5', epic: 'E', title: 'Animated spinner (replace static "[working...]")',
    context: 'pi-zig shows "[working... press Esc to abort]" static. Upstream animates a spinner.',
    dod: 'Spinner cycles per render; smoke captures multiple frames.',
    requirements: ['Frame-rate stable'],
    upstream: 'packages/coding-agent/src/modes/interactive/components/bordered-loader.ts + loader.ts', pizig: 'src/pi/tui.zig',
    depends: ['E1'], priority: 55, complexity: 'Low' },
  { code: 'E6', epic: 'E', title: 'Terminal-width dynamic dividers',
    context: 'Dividers are hardcoded 80 cells. Upstream scales to terminal width.',
    dod: 'Read columns via TIOCGWINSZ; divider auto-fits; SIGWINCH triggers reflow.',
    requirements: ['SIGWINCH handler'],
    upstream: 'packages/tui/src/terminal.ts', pizig: 'src/pi/tui.zig + src/pi/tui_terminal.zig',
    depends: ['E1', 'J6'], priority: 55, complexity: 'Medium' },
  { code: 'E7', epic: 'E', title: 'OSC 133 zone codes + OSC 9;4 progress',
    context: 'Modern terminals (iTerm2, WezTerm, kitty) honor OSC 133 (semantic prompt zones) and OSC 9;4 (progress bar). Both absent.',
    dod: 'Emit OSC 133 around prompt/output zones; OSC 9;4 progress around active tool runs; smoke captures escape sequences in stdout.',
    requirements: ['No terminal harm without support'],
    upstream: 'packages/tui/src/terminal.ts', pizig: 'src/pi/tui.zig',
    depends: ['E1'], priority: 45, complexity: 'Low' },
  { code: 'E8', epic: 'E', title: 'Earendil-announcement / armin / daxnuts easter eggs',
    context: 'Three small visual easter-eggs present upstream; absent in pi-zig.',
    dod: 'Each rendered when triggered; smoke proves activation paths.',
    requirements: ['Opt-in only'],
    upstream: 'packages/coding-agent/src/modes/interactive/components/{earendil-announcement,armin,daxnuts}.ts', pizig: 'src/pi/tui.zig',
    depends: ['E1'], priority: 20, complexity: 'Low' },
  { code: 'E9', epic: 'E', title: 'Switch box-drawing arc corners ╭╮╰╯ → square ┌┐└┘ (or expose as theme)',
    context: 'pi-zig uses arc corners; upstream uses square. Visual divergence.',
    dod: 'Default is square (matching upstream); theme can override.',
    requirements: ['No regression in unit tests asserting specific glyphs'],
    upstream: 'packages/coding-agent/src/modes/interactive/components/*', pizig: 'src/pi/tui_messages.zig + tui_footer.zig',
    depends: ['E1'], priority: 40, complexity: 'Low' },
  { code: 'E10', epic: 'E', title: 'Update Available banner with real version-check HTTP probe',
    context: 'Currently gated on PI_ZIG_NEW_VERSION env; no real version check.',
    dod: 'Background HTTP probe of pi.dev/api/latest-version (configurable); banner shows when newer is available; cached for N hours.',
    requirements: ['No blocking startup', 'Honor PI_OFFLINE'],
    upstream: 'packages/coding-agent/src/modes/interactive/components/footer.ts', pizig: 'src/pi/tui_footer.zig',
    depends: ['E1'], priority: 50, complexity: 'Medium' },

  // ──── F: Agent package library ────────────────────────────────────────────
  { code: 'F1', epic: 'F', title: 'Embeddable Agent / AgentHarness classes',
    context: 'Upstream exports Agent + AgentHarness classes for library consumers. pi-zig\'s code is process-coupled.',
    dod: 'src/pi/agent_harness.zig provides a stable embedder API; sample embedder demo; unit tests.',
    requirements: ['No global state'],
    upstream: 'packages/agent/src/agent.ts + agent-harness.ts', pizig: 'NEW src/pi/agent_harness.zig',
    depends: ['A8'], priority: 60, complexity: 'High' },
  { code: 'F2', epic: 'F', title: 'Pluggable StreamFn',
    context: 'Provider is hardcoded in ai_client.zig. Upstream allows a StreamFn override.',
    dod: 'agent.zig accepts a stream callback; existing providers wrap it; unit test with a fake StreamFn.',
    requirements: ['Cancellation propagated'],
    upstream: 'packages/agent/src/agent.ts', pizig: 'src/pi/agent.zig',
    depends: [], priority: 55, complexity: 'Medium' },
  { code: 'F3', epic: 'F', title: 'Parallel tool execution + executionMode',
    context: 'Upstream supports parallel tool execution per-turn. pi-zig is sequential.',
    dod: 'agent.zig executes independent tool calls in parallel when executionMode=parallel; per-tool isolation; unit test counts wall-clock vs serial.',
    requirements: ['No tool cross-talk', 'Cancellation per-tool'],
    upstream: 'packages/agent/src/agent.ts', pizig: 'src/pi/agent.zig',
    depends: ['F2'], priority: 65, complexity: 'High' },
  { code: 'F4', epic: 'F', title: 'transformContext / convertToLlm callbacks',
    context: 'Upstream hooks to transform context + convert to LLM format. pi-zig has no such seam.',
    dod: 'Hooks added to RunOptions; unit tests cover transform + convert.',
    requirements: ['Type-safe'],
    upstream: 'packages/agent/src/agent.ts', pizig: 'src/pi/agent.zig',
    depends: [], priority: 50, complexity: 'Medium' },
  { code: 'F5', epic: 'F', title: 'ExecutionEnv abstraction',
    context: 'Upstream tools call through an ExecutionEnv; pi-zig calls std.fs / std.process directly. Hard to mock.',
    dod: 'ExecutionEnv interface added; tools refactored to call it; mock-env tests.',
    requirements: ['Backwards-compat default'],
    upstream: 'packages/agent/src/exec-env.ts', pizig: 'src/pi/tools.zig + src/pi/agent.zig',
    depends: [], priority: 55, complexity: 'High' },
  { code: 'F6', epic: 'F', title: 'Result<T,E> model + stable error-code classes',
    context: 'Upstream uses a Result pattern with classified errors; pi-zig uses Zig error union with coarse names.',
    dod: 'Wrap public APIs in Result-equivalent; map upstream error codes 1:1; consumer-friendly.',
    requirements: ['Error mapping table'],
    upstream: 'packages/agent/src/result.ts', pizig: 'src/pi/agent.zig + src/pi/rpc.zig',
    depends: [], priority: 45, complexity: 'Medium' },
  { code: 'F7', epic: 'F', title: 'streamProxy',
    context: 'Upstream\'s streamProxy multiplexes provider streams; absent in pi-zig.',
    dod: 'streamProxy ported; smoke proves dual-consumer scenario.',
    requirements: ['Backpressure-safe'],
    upstream: 'packages/agent/src/stream-proxy.ts', pizig: 'src/pi/agent.zig',
    depends: ['F2'], priority: 35, complexity: 'Medium' },
  { code: 'F8', epic: 'F', title: 'In-memory session backend',
    context: 'Upstream supports an in-memory session backend for tests/ephemeral runs.',
    dod: 'src/pi/session_repo.zig with an InMemory backend selectable via RunOptions; unit test exercises both backends.',
    requirements: ['No disk writes when in-memory'],
    upstream: 'packages/agent/src/in-memory-session.ts', pizig: 'src/pi/session.zig',
    depends: [], priority: 45, complexity: 'Medium' },
  { code: 'F9', epic: 'F', title: 'JsonlSessionRepo class + cwd-indexed dirs + encodeCwd',
    context: 'Upstream organizes session JSONLs in cwd-indexed dirs via encodeCwd helper. pi-zig uses a single sessions dir.',
    dod: 'JsonlSessionRepo with cwd-encoded subdirs; encodeCwd helper byte-exact; smoke verifies dir layout.',
    requirements: ['Byte-exact encodeCwd'],
    upstream: 'packages/agent/src/jsonl-session-repo.ts', pizig: 'NEW src/pi/session_repo.zig',
    depends: ['F8'], priority: 60, complexity: 'Medium' },
  { code: 'F10', epic: 'F', title: 'UUID v7',
    context: 'Upstream uses UUID v7 for run ids; pi-zig uses ad-hoc ids.',
    dod: 'src/pi/uuid.zig with v7 generator; unit tests verify time-ordered uniqueness.',
    requirements: ['RFC9562 v7'],
    upstream: 'packages/agent/src/uuid.ts', pizig: 'NEW src/pi/uuid.zig',
    depends: [], priority: 50, complexity: 'Low' },
  { code: 'F11', epic: 'F', title: 'Outer follow-up replay (single agent loop drains batches)',
    context: 'RPC currently re-invokes runPrompt per drained batch. Upstream\'s agent loop drains internally.',
    dod: 'agent.zig loops over queue; rpc.zig dispatches once; unit test exercises multi-batch drain.',
    requirements: ['Cancellation semantics preserved'],
    upstream: 'packages/agent/src/agent.ts', pizig: 'src/pi/agent.zig + src/pi/rpc.zig',
    depends: [], priority: 60, complexity: 'High' },
  { code: 'F12', epic: 'F', title: 'prepareNextTurn: replace context/messages/tools/thinkingLevel',
    context: 'pi-zig can swap only system_prompt/provider/model/api_key. Upstream\'s hook can replace context/messages/tools/thinkingLevel.',
    dod: 'Hook signature extended; unit tests cover each replacement field.',
    requirements: ['Backwards-compat default'],
    upstream: 'packages/agent/src/agent.ts', pizig: 'src/pi/agent.zig',
    depends: ['F4'], priority: 55, complexity: 'Medium' },
  { code: 'F13', epic: 'F', title: 'Tool hook fields: signal / args(validated) / context / details',
    context: 'Before/after tool hooks miss the upstream-shaped fields (validated args, cancellation signal, ambient context, run details).',
    dod: 'Hook signature extended; each field test-asserted; extensions can read all four.',
    requirements: ['ABI-stable'],
    upstream: 'packages/agent/src/agent.ts', pizig: 'src/pi/agent.zig + src/pi/extension_runner.zig',
    depends: [], priority: 65, complexity: 'Medium' },
  { code: 'F14', epic: 'F', title: 'agentLoopContinue + listener-signal propagation',
    context: 'Upstream\'s agentLoopContinue lets a hook abort or chain; signal propagates to listeners.',
    dod: 'Function + signal wired; unit test triggers continue/abort from a hook.',
    requirements: ['Signal-safe'],
    upstream: 'packages/agent/src/agent.ts', pizig: 'src/pi/agent.zig',
    depends: ['F13'], priority: 45, complexity: 'Medium' },
  { code: 'F15', epic: 'F', title: 'File-ops tracking (readFiles / modifiedFiles summary blocks)',
    context: 'Tool runs that touch files surface readFiles/modifiedFiles in turn summaries upstream; absent in pi-zig.',
    dod: 'tools.zig records file ops; agent.zig surfaces them in turn summary; smoke shows the lists.',
    requirements: ['No false positives'],
    upstream: 'packages/agent/src/tool-ops.ts', pizig: 'src/pi/tools.zig + src/pi/agent.zig',
    depends: [], priority: 55, complexity: 'Medium' },
  { code: 'F16', epic: 'F', title: 'BUG: bash full-output path collides on concurrent runs',
    context: 'tools.zig writes shell full-output to fixed zig-out/pi-zig-bash-full-output.log. Two concurrent bash tools clobber each other.',
    dod: 'Per-run temp file via ExecutionEnv.createTempFile; concurrent-run test passes.',
    requirements: ['Cleanup on success and failure'],
    upstream: 'packages/agent/src/exec-env.ts (createTempFile)', pizig: 'src/pi/tools.zig',
    depends: ['F5'], priority: 95, complexity: 'Low' },
  { code: 'F17', epic: 'F', title: 'getEntriesToFork "at" mode',
    context: 'Upstream supports forking AT a specific entry; pi-zig\'s fork is "from leaf" only.',
    dod: 'API supports both modes; smoke proves each.',
    requirements: ['Round-trip stable'],
    upstream: 'packages/agent/src/session-fork.ts', pizig: 'src/pi/session.zig',
    depends: [], priority: 40, complexity: 'Low' },

  // ──── G: AI providers ─────────────────────────────────────────────────────
  { code: 'G1', epic: 'G', title: 'Codex Responses transport (entirely missing)',
    context: 'Catalog lists openai-codex-responses models; dispatcher routes them through chat/completions — INCOMPATIBLE shape. No SSE, no responses_websockets=2026-02-06, no chatgpt-account-id header, no retry-after-ms, no plan-aware errors, no session connection cache, no previous_response_id delta-context.',
    dod: 'ai_client.zig dispatches openai-codex-responses to chatgpt.com/backend-api/codex/responses with SSE + all required headers + retry-after parsing + previous_response_id chaining; smoke proves end-to-end.',
    requirements: ['No secrets logged', 'Fake server smoke'],
    upstream: 'packages/ai/src/providers/openai-codex-responses.ts', pizig: 'src/pi/ai_client.zig',
    depends: [], priority: 95, complexity: 'High' },
  { code: 'G2', epic: 'G', title: 'detectCompat 14-field per-provider compat (20+ providers)',
    context: 'pi-zig sends one fixed shape with tool_choice:"auto". Upstream\'s detectCompat (line 1070, openai-completions.ts) has 14 fields covering 20+ providers (Cerebras, x.ai, Together, chutes.ai, DeepSeek, z.ai, Moonshot, Cloudflare Workers AI/AI Gateway, GitHub Copilot, OpenRouter, Vercel AI Gateway, Anthropic-via-OpenRouter).',
    dod: 'detectCompat ported with all 14 fields + 20+ providers; smoke tests per provider hit a fake server with the right shape.',
    requirements: ['Match upstream regex byte-for-byte'],
    upstream: 'packages/ai/src/providers/openai-completions.ts:detectCompat', pizig: 'src/pi/ai_client.zig',
    depends: [], priority: 90, complexity: 'High' },
  { code: 'G3', epic: 'G', title: 'Interactive OAuth login (PKCE + callback + device-code)',
    context: 'Refresh works for all 3 providers; login requires manual `auth set-oauth <…>`. No PKCE, no callback server, no device-code, no manual-paste race.',
    dod: '`pi-zig auth login <provider>` runs the full PKCE/device-code flow; live cred opt-in; never prints secrets; fake-endpoint smoke.',
    requirements: ['No secrets logged', 'Cross-platform browser launch'],
    upstream: 'packages/ai/src/utils/oauth/*', pizig: 'src/pi/auth.zig + src/pi/auth_login.zig',
    depends: ['B2'], priority: 85, complexity: 'High' },
  { code: 'G4', epic: 'G', title: 'Anthropic Messages depth: cache_control / thinking / OAuth tool-name remap / eager_input_streaming / redacted_thinking / x-session-affinity / dynamic max_tokens',
    context: 'pi-zig\'s Anthropic transport is shallow: max_tokens hardcoded 4096; no cache_control ephemeral blocks; no thinking/output_config.effort; no OAuth tool-name remap (16 canonical names); no eager_input_streaming; no redacted_thinking round-trip; no aborted-thinking-signature downgrade; no x-session-affinity.',
    dod: 'Each feature wired with smoke + unit; OAuth tool-name remap table byte-exact.',
    requirements: ['No regression in fake-server smoke'],
    upstream: 'packages/ai/src/providers/anthropic.ts', pizig: 'src/pi/ai_client.zig',
    depends: [], priority: 85, complexity: 'High' },
  { code: 'G5', epic: 'G', title: 'Bedrock depth: cache points / reasoningContent.signature / additionalModelRequestFields / requestMetadata / GovCloud strip / exception-name map / ~/.aws/credentials profile / IMDS chain',
    context: 'SigV4 signer verified vs AWS get-vanilla; missing all the cache and reasoning features.',
    dod: 'Each feature ported with unit test; profile + IMDS chain end-to-end smoke.',
    requirements: ['No live AWS contact'],
    upstream: 'packages/ai/src/providers/amazon-bedrock.ts', pizig: 'src/pi/ai_client.zig + src/pi/auth.zig',
    depends: [], priority: 75, complexity: 'High' },
  { code: 'G6', epic: 'G', title: 'Missing helpers: transform-messages.ts / cloudflare.ts / github-copilot-headers.ts / openai-prompt-cache.ts / simple-options.ts (reasoning plumbing)',
    context: 'Several cross-provider helpers absent; their consumers degrade silently.',
    dod: 'Each helper ported with unit tests + consumed by providers that need it.',
    requirements: ['Match upstream functions byte-for-byte'],
    upstream: 'packages/ai/src/providers/*.ts shared helpers', pizig: 'src/pi/ai_client.zig',
    depends: [], priority: 70, complexity: 'Medium' },
  { code: 'G7', epic: 'G', title: 'Wire 15+ unwired OpenAI-compatible providers in endpointForProvider',
    context: 'Only 7 providers wired in endpointForProvider; 15+ in the catalog have no endpoint mapping → 404 on use.',
    dod: 'Each catalog provider has a mapped endpoint; smoke per provider against a fake server.',
    requirements: ['Per-provider auth header'],
    upstream: 'packages/ai/src/providers/*.ts', pizig: 'src/pi/ai_client.zig',
    depends: [], priority: 80, complexity: 'Medium' },

  // ──── H: AI core ──────────────────────────────────────────────────────────
  { code: 'H1', epic: 'H', title: 'Usage tracking in ChatCompletionResult + calculateCost',
    context: 'No Usage struct anywhere; no per-token cost calculation. Compaction triggers can\'t use real tokens; footer can\'t show cost.',
    dod: 'ChatCompletionResult carries Usage {prompt_tokens, completion_tokens, cache_read, cache_write}; calculateCost computes from model costs; unit tests cover each provider\'s usage parse.',
    requirements: ['Per-provider usage parse exact'],
    upstream: 'packages/ai/src/usage.ts + per-provider parsing', pizig: 'src/pi/ai_client.zig + NEW src/pi/usage.zig',
    depends: [], priority: 90, complexity: 'High' },
  { code: 'H2', epic: 'H', title: 'api-registry: provider registration + custom-provider extension API landing',
    context: 'Provider dispatch is a hardcoded switch in streamChatTurnData. Extension API pi.registerProvider has nowhere to land.',
    dod: 'src/pi/api_registry.zig with a registry; built-in providers register at startup; extensions can dynamically register; smoke proves a custom-provider extension dispatches.',
    requirements: ['No global state hazards'],
    upstream: 'packages/ai/src/api-registry.ts', pizig: 'NEW src/pi/api_registry.zig',
    depends: [], priority: 85, complexity: 'High' },
  { code: 'H3', epic: 'H', title: 'AssistantMessageEventStream + 13-arm typed event union',
    context: 'pi-zig uses scattered callbacks. Upstream has a typed 13-arm event union streamed during a turn.',
    dod: 'src/pi/assistant_event_stream.zig with the union; agent.zig emits via it; CLI/RPC consumers re-emit.',
    requirements: ['Backwards-compat with callbacks'],
    upstream: 'packages/ai/src/assistant-event-stream.ts', pizig: 'NEW src/pi/assistant_event_stream.zig',
    depends: [], priority: 70, complexity: 'High' },
  { code: 'H4', epic: 'H', title: 'utils/json-parse.ts: repair + streaming-JSON tolerance',
    context: 'Provider responses occasionally have malformed JSON or interleaved control sequences. Upstream repairs; pi-zig errors out.',
    dod: 'src/pi/json_parse.zig with repair + partial-token tolerance; unit tests cover common malformations.',
    requirements: ['No false repairs of structurally bad input'],
    upstream: 'packages/ai/src/utils/json-parse.ts', pizig: 'NEW src/pi/json_parse.zig',
    depends: [], priority: 65, complexity: 'Medium' },
  { code: 'H5', epic: 'H', title: 'utils/node-http-proxy.ts: HTTP_PROXY / HTTPS_PROXY / no_proxy',
    context: 'pi-zig ignores all proxy env vars.',
    dod: 'src/pi/http_proxy.zig parses env, wires std.http.Client proxy; smoke verifies routing through a fake proxy.',
    requirements: ['no_proxy honored'],
    upstream: 'packages/ai/src/utils/node-http-proxy.ts', pizig: 'NEW src/pi/http_proxy.zig',
    depends: ['B4'], priority: 75, complexity: 'Medium' },
  { code: 'H6', epic: 'H', title: 'utils/sanitize-unicode.ts, diagnostics.ts, validation.ts, typebox-helpers.ts, hash.ts',
    context: 'Five shared utilities absent. Some are nice-to-have (diagnostics, validation); sanitize-unicode is load-bearing (prevents homograph attacks in CLI output).',
    dod: 'Each ported with unit tests.',
    requirements: ['Hash impl uses std.crypto'],
    upstream: 'packages/ai/src/utils/*.ts', pizig: 'src/pi/ai_client.zig + new utility modules',
    depends: [], priority: 55, complexity: 'Medium' },
  { code: 'H7', epic: 'H', title: 'Image-models catalog (not just inline openrouter)',
    context: 'Only one image provider is inline-wired; upstream has a catalog.',
    dod: 'Image-models catalog generator; multiple image providers; smoke per provider.',
    requirements: ['Provider parity'],
    upstream: 'packages/ai/src/models/images.ts', pizig: 'src/pi/ai_client.zig + src/pi/models.zig',
    depends: [], priority: 55, complexity: 'Medium' },
  { code: 'H8', epic: 'H', title: 'Compat overrides on ModelEntry (OpenAICompletionsCompat / OpenAIResponsesCompat / AnthropicMessagesCompat)',
    context: 'ModelEntry has no per-model compat overrides upstream; pi-zig has none either, but consumers depend on it for openRouterRouting/vercelGatewayRouting.',
    dod: 'ModelEntry gains an optional compat struct; per-provider serializers read it; smoke per override.',
    requirements: ['Backwards-compat default'],
    upstream: 'packages/ai/src/models/*.ts', pizig: 'src/pi/models.zig + src/pi/ai_client.zig',
    depends: [], priority: 60, complexity: 'Medium' },

  // ──── I: Tools / Extensions / Resources ───────────────────────────────────
  { code: 'I1', epic: 'I', title: 'pi.* API: 14 missing methods',
    context: 'Extension API surface is 8/22 wired. Missing: registerShortcut, registerMessageRenderer, registerProvider, unregisterProvider, setSessionName, getSessionName, setLabel, exec, getActiveTools, getAllTools, setActiveTools, getCommands, setModel, getThinkingLevel, setThinkingLevel.',
    dod: 'Each method wired in extension_runner.zig; pi.* shim exposes them; per-method smoke runs an extension calling the method and asserts the effect.',
    requirements: ['Type-safe', 'Async-safe'],
    upstream: 'packages/coding-agent/src/core/extensions/*', pizig: 'src/pi/extension_runner.zig',
    depends: ['A6', 'H2'], priority: 90, complexity: 'High' },
  { code: 'I2', epic: 'I', title: 'Dispatch 17 currently-unfired lifecycle events',
    context: 'Events context / before_agent_start / model_select / thinking_level_select / input / session_before_* / session_compact / session_shutdown / tool_execution_start/update/end / message_update / resources_discover are NEVER dispatched in production code.',
    dod: 'Each event has a dispatch site; per-event smoke asserts the extension handler observes it.',
    requirements: ['Match upstream emission order'],
    upstream: 'packages/coding-agent/src/core/extensions/*', pizig: 'src/pi/rpc.zig + src/pi/agent.zig',
    depends: ['A6'], priority: 90, complexity: 'High' },
  { code: 'I3', epic: 'I', title: 'Honor return values of 9 fire-and-forget lifecycle events',
    context: 'session_start / before_provider_request / after_provider_response / agent_start/end / turn_start/end / message_start/end / user_bash fire but DISCARD return values. RuntimeLifecycleEmitContext.emit explicitly drops them (rpc.zig:3834-3842).',
    dod: 'Each event\'s return value is applied per upstream semantics (transform-chain or short-circuit); per-event smoke proves the effect.',
    requirements: ['Backwards-compat with extensions that return undefined'],
    upstream: 'packages/coding-agent/src/core/extensions/*', pizig: 'src/pi/rpc.zig + src/pi/extension_runner.zig',
    depends: ['A6'], priority: 90, complexity: 'High' },
  { code: 'I4', epic: 'I', title: 'Provider display names: 28-entry map',
    context: 'pi-zig surfaces raw provider ids (google-vertex) instead of display names (Google Vertex AI).',
    dod: 'src/pi/provider_display.zig with the 28-entry map; commands/themes/RPC use it; smoke asserts UI shows display names.',
    requirements: ['Map matches upstream byte-for-byte'],
    upstream: 'packages/coding-agent/src/core/provider-display-names.ts', pizig: 'NEW src/pi/provider_display.zig',
    depends: [], priority: 45, complexity: 'Low' },
  { code: 'I5', epic: 'I', title: 'Models.json: ~/.pi/models.json loading + schema validation + applyModelOverride + mergeCompat + per-model headers',
    context: 'Custom model registry: users put models in ~/.pi/models.json and pi-zig should load + validate + merge. None of this exists.',
    dod: 'src/pi/custom_models.zig loads + validates + merges; openRouterRouting / vercelGatewayRouting helpers; per-model headers passed to ai_client; smoke uses a temp models.json.',
    requirements: ['Schema validation strict'],
    upstream: 'packages/coding-agent/src/core/model-registry.ts + model-resolver.ts', pizig: 'NEW src/pi/custom_models.zig',
    depends: ['H8'], priority: 65, complexity: 'High' },
  { code: 'I6', epic: 'I', title: 'HTML export: marked.min.js + highlight.min.js vendored + ansi-to-html + ToolHtmlRenderer + 5-mode sidebar filter + branch-tree sidebar',
    context: 'Server-side rendering works; the interactive SPA chrome is absent.',
    dod: 'Vendor marked + highlight at build (in repo); ansi-to-html.zig converter; ToolHtmlRenderer interface; 5-mode filter UI; branch-tree sidebar with active-path markers; smoke loads the HTML in headless Chrome and asserts each element.',
    requirements: ['Self-contained (no CDN)'],
    upstream: 'packages/coding-agent/src/core/export-html/*', pizig: 'src/pi/html_export.zig',
    depends: [], priority: 60, complexity: 'High' },
  { code: 'I7', epic: 'I', title: 'Built-in tool *Operations seams + withFileMutationQueue + BashSpawnHook + image auto-resize + macOS read-path fallbacks + edit-tool diff/patch/firstChangedLine + prepareArguments legacy migration',
    context: 'Tool execution is at parity; the customization seams + macOS fallbacks + ANSI-to-HTML + image worker are absent.',
    dod: 'Each seam implemented; macOS read-path variant fallback table ported; edit-tool result carries details.diff + patch + firstChangedLine; smoke proves each seam.',
    requirements: ['Backwards-compat'],
    upstream: 'packages/coding-agent/src/core/tools/*', pizig: 'src/pi/tools.zig',
    depends: ['F5'], priority: 70, complexity: 'High' },

  // ──── J: TUI primitives ───────────────────────────────────────────────────
  { code: 'J1', epic: 'J', title: 'keys.ts: Kitty + modifyOtherKeys + non-Latin-layout + Apple-Terminal + Windows-Terminal CSI-u (~900 LoC)',
    context: 'pi-zig\'s tui_keys.zig handles legacy non-Kitty sequences; misses Kitty key protocol, modifyOtherKeys, non-Latin keyboard layouts, Apple Terminal CSI-u quirks, Windows Terminal CSI-u.',
    dod: 'tui_keys.zig fully ported; per-protocol unit tests; pty harness covers a Kitty terminal handshake.',
    requirements: ['No misclassification of legacy sequences'],
    upstream: 'packages/tui/src/keys.ts', pizig: 'src/pi/tui_keys.zig',
    depends: [], priority: 80, complexity: 'High' },
  { code: 'J2', epic: 'J', title: 'utils.ts: visible-width / ANSI-aware wrap / grapheme segmentation (~1100 LoC)',
    context: 'pi-zig is byte-based throughout. Emoji, accented Latin, combining marks all break.',
    dod: 'src/pi/tui_text.zig with width / wrap / grapheme APIs based on Unicode UCD tables; unit tests for emoji + combining marks + accented Latin + ZWJ.',
    requirements: ['Width 0 for combining marks', 'Width 2 for wide chars'],
    upstream: 'packages/tui/src/utils.ts', pizig: 'NEW src/pi/tui_text.zig',
    depends: [], priority: 90, complexity: 'High' },
  { code: 'J3', epic: 'J', title: 'terminal-image.ts + components/image.ts (~580 LoC)',
    context: 'Zero image support. No kitty graphics, no iTerm2 inline images, no SIXEL.',
    dod: 'tui_image.zig with kitty + iTerm2 image protocols; smoke renders a tiny PNG and detects the escape.',
    requirements: ['Detect protocol support'],
    upstream: 'packages/tui/src/terminal-image.ts + components/image.ts', pizig: 'NEW src/pi/tui_image.zig',
    depends: [], priority: 65, complexity: 'High' },
  { code: 'J4', epic: 'J', title: 'Components: input / settings-list / box / loader / cancellable-loader / text / spacer / truncated-text',
    context: '8 small but load-bearing layout components entirely missing.',
    dod: 'Each component has a Zig module + unit tests; used by tui_messages and tui_footer.',
    requirements: ['Style-token aware'],
    upstream: 'packages/tui/src/components/{input,settings-list,box,loader,cancellable-loader,text,spacer,truncated-text}.ts', pizig: 'NEW src/pi/tui_components/*.zig',
    depends: ['J2'], priority: 75, complexity: 'High' },
  { code: 'J5', epic: 'J', title: 'tui.ts: overlay compositor + IME CURSOR_MARKER + viewport + synchronized output + Kitty image lifecycle',
    context: 'pi-zig\'s differential renderer doesn\'t composite overlays, has no IME cursor marker, no viewport math, no \\x1b[?2026h/l synchronized output, no Kitty image lifecycle.',
    dod: 'tui.zig / tui_render.zig extended; each feature has a per-feature snapshot test.',
    requirements: ['No flicker'],
    upstream: 'packages/tui/src/tui.ts', pizig: 'src/pi/tui.zig + src/pi/tui_render.zig',
    depends: [], priority: 80, complexity: 'High' },
  { code: 'J6', epic: 'J', title: 'terminal.ts: bracketed paste / Kitty probe / drain / setTitle / setProgress / SIGWINCH / Windows console mode',
    context: 'tui_terminal.zig has the basics; missing 7 specific behaviors.',
    dod: 'Each ported with smoke (where observable in stdout) or unit test.',
    requirements: ['Cross-platform'],
    upstream: 'packages/tui/src/terminal.ts', pizig: 'src/pi/tui_terminal.zig',
    depends: [], priority: 70, complexity: 'Medium' },
  { code: 'J7', epic: 'J', title: 'autocomplete.ts: @-path completion + fd-based fuzzy file walk',
    context: 'No autocomplete in the composer. Upstream has @<partial-path> file fuzzy.',
    dod: 'tui_autocomplete.zig with fd-based walk + fuzzy match; integrated into editor; unit + smoke.',
    requirements: ['Ignore .gitignore'],
    upstream: 'packages/tui/src/autocomplete.ts', pizig: 'NEW src/pi/tui_autocomplete.zig',
    depends: [], priority: 60, complexity: 'High' },
  { code: 'J8', epic: 'J', title: 'stdin-buffer.ts: OSC/APC/DCS accumulator + bracketed-paste + 10ms partial-sequence flush + WezTerm escape fixup',
    context: 'pi-zig reads stdin raw and parses each chunk synchronously. Long OSC/APC/DCS sequences can be split across reads and get mis-parsed.',
    dod: 'tui_stdin_buffer.zig accumulates partial sequences with a 10ms flush; bracketed-paste assembly; smoke pipes a split OSC sequence and asserts correct assembly.',
    requirements: ['No loss on partial reads'],
    upstream: 'packages/tui/src/stdin-buffer.ts', pizig: 'NEW src/pi/tui_stdin_buffer.zig',
    depends: ['J1'], priority: 75, complexity: 'High' },
  { code: 'J9', epic: 'J', title: 'Editor: paste-marker system + visual-line nav + sticky preferred column + grapheme-aware cursor + jumpToChar + pageScroll + multi-level undo + autocomplete UI + bordered render',
    context: 'tui_editor.zig has byte-based logic. Missing 9 specific editor features.',
    dod: 'Each feature added with unit tests + at least one pty smoke step.',
    requirements: ['Undo depth ≥ 100'],
    upstream: 'packages/tui/src/components/editor.ts', pizig: 'src/pi/tui_editor.zig',
    depends: ['J2', 'J7'], priority: 75, complexity: 'High' },
];

// ─── Sanity check ────────────────────────────────────────────────────────────
function check() {
  const codes = new Set();
  for (const t of subtasks) {
    if (codes.has(t.code)) fail(`duplicate task code: ${t.code}`);
    codes.add(t.code);
  }
  for (const t of subtasks) {
    for (const d of t.depends) if (!codes.has(d)) fail(`task ${t.code} depends on unknown ${d}`);
  }
  for (const e of epics) {
    if (!subtasks.some((t) => t.epic === e.id)) fail(`epic ${e.id} has no subtasks`);
  }
}

// ─── Build a description block with Context / DoD / Requirements / Dependencies / Upstream / Target ───
function buildDescription(t, epic) {
  const reqs = t.requirements.map((r, i) => `  ${i + 1}. ${r}`).join('\n');
  const deps = t.depends.length ? t.depends.join(', ') : '(none)';
  return `**Epic:** ${epic.title}
**Slice parity (upstream report):** ${epic.parity}
**Complexity:** ${t.complexity}

## Context
${t.context}

## Definition of Done
${t.dod}

## Requirements
${reqs}

## Dependencies (task codes)
${deps}

## Upstream source
\`${t.upstream}\`

## pi-zig target
\`${t.pizig}\`

## Gap report
${epic.gap}

This task is one item in the pi-zig parity master inventory. Implement the upstream method's full behavioral spec — no stubs, no "not yet wired" placeholders, no simulations. Add a per-method unit test asserting the upstream behavior, and at least one integration smoke under \`scripts/wave5-${epic.id.toLowerCase()}-smoke.mjs\` driving the real binary against a fake provider where applicable. Run \`zig build test\` and the smoke; honestly report any item not at upstream parity with reason.`;
}

// ─── Main flow ───────────────────────────────────────────────────────────────
async function main() {
  check();

  // 1. Reuse or create the pipeline.
  const pipelines = await http('GET', '/pipelines');
  let pipeline = (pipelines || []).find((p) => p.name === 'pi-zig-parity');
  if (!pipeline) {
    log('creating pipeline pi-zig-parity');
    pipeline = await http('POST', '/pipelines', { name: 'pi-zig-parity', definition: pipelineDef });
  } else {
    log(`reusing pipeline ${pipeline.id}`);
  }
  const pipelineId = pipeline.id;

  // 2. Discover already-created epics (idempotent) + bulk-create the missing ones.
  // Response shape is {ids:[...]} preserving request order; map by index.
  const epicMeta = (e) => ({
    project: PROJECT_ID,
    project_path: PROJECT_PATH,
    kind: 'epic',
    epic_id: e.id,
    gap_report: e.gap,
    estimated_slice_parity: e.parity,
  });
  const epicIdByCode = {};
  const existingTasks = await listAllPipelineTasks(pipelineId);
  for (const t of existingTasks) {
    if (t.metadata?.kind === 'epic' && t.metadata?.epic_id) {
      epicIdByCode[t.metadata.epic_id] = t.id;
    }
  }
  const epicsToCreate = epics.filter((e) => !epicIdByCode[e.id]);
  if (epicsToCreate.length) {
    const epicReq = epicsToCreate.map((e) => ({
      pipeline_id: pipelineId,
      title: `[${e.id}] ${e.title}`,
      description: `**Epic** for pi-zig parity slice ${e.id}.\n\n**Estimated slice parity (research audit):** ${e.parity}\n**Gap report:** ${e.gap}\n\nThis is an umbrella issue tracking the subtasks under category ${e.id}. Subtasks carry the concrete Context / Definition of Done / Requirements / Upstream source / pi-zig target. Closing this epic requires every subtask under ${e.id} to reach \`done\`.`,
      priority: 100,
      metadata: epicMeta(e),
    }));
    const resp = await http('POST', '/tasks/bulk', { tasks: epicReq });
    (resp.ids || []).forEach((id, i) => {
      epicIdByCode[epicsToCreate[i].id] = id;
    });
  }
  log(`epics resolved: ${Object.keys(epicIdByCode).length}/${epics.length}`);

  // 3. Discover already-created subtasks (idempotent) + create missing in chunks.
  const subtaskIdByCode = {};
  for (const t of existingTasks) {
    if (t.metadata?.kind === 'subtask' && t.metadata?.code) {
      subtaskIdByCode[t.metadata.code] = t.id;
    }
  }
  const subtasksToCreate = subtasks.filter((t) => !subtaskIdByCode[t.code]);
  if (subtasksToCreate.length) {
    const chunkSize = 20; // Stay well under any body-size limit.
    for (let i = 0; i < subtasksToCreate.length; i += chunkSize) {
      const chunk = subtasksToCreate.slice(i, i + chunkSize);
      const subReq = chunk.map((t) => {
        const epic = epics.find((e) => e.id === t.epic);
        return {
          pipeline_id: pipelineId,
          title: `[${t.code}] ${t.title}`,
          description: buildDescription(t, epic),
          priority: t.priority,
          metadata: {
            project: PROJECT_ID,
            project_path: PROJECT_PATH,
            kind: 'subtask',
            epic_id: t.epic,
            epic_task_id: epicIdByCode[t.epic],
            code: t.code,
            upstream: t.upstream,
            pizig_target: t.pizig,
            complexity: t.complexity,
          },
        };
      });
      const resp = await http('POST', '/tasks/bulk', { tasks: subReq });
      (resp.ids || []).forEach((id, j) => {
        subtaskIdByCode[chunk[j].code] = id;
      });
      log(`  chunk ${i / chunkSize + 1}: +${(resp.ids || []).length} subtasks`);
    }
  }
  log(`subtasks resolved: ${Object.keys(subtaskIdByCode).length}/${subtasks.length}`);

  // 4. Wire dependencies idempotently. Use GET /tasks/{id}/dependencies to skip
  //    already-wired prerequisites. Each subtask depends on its prereq tasks;
  //    each epic depends on all its subtasks.
  async function ensureDep(taskId, prereqId) {
    const existing = await http('GET', `/tasks/${taskId}/dependencies`);
    const have = new Set((existing || []).map((d) => d.depends_on_task_id ?? d.id ?? d.task_id));
    if (have.has(prereqId)) return false;
    try {
      await http('POST', `/tasks/${taskId}/dependencies`, { depends_on_task_id: prereqId });
      return true;
    } catch {
      return false;
    }
  }
  let depCount = 0;
  for (const t of subtasks) {
    const tid = subtaskIdByCode[t.code];
    if (!tid) continue;
    // Epic depends on subtask (epic done only when all subtasks done).
    if (await ensureDep(epicIdByCode[t.epic], tid)) depCount++;
    for (const d of t.depends) {
      const dependsOn = subtaskIdByCode[d];
      if (!dependsOn) continue;
      if (await ensureDep(tid, dependsOn)) depCount++;
    }
  }
  log(`wired ${depCount} new dependencies`);

  // 5. Dump the JSON snapshot.
  const jsonOut = {
    generatedAt: new Date().toISOString(),
    project: PROJECT_ID,
    projectPath: PROJECT_PATH,
    nullticketsApi: API,
    pipelineId,
    pipelineName: 'pi-zig-parity',
    pipelineDefinition: pipelineDef,
    epics: epics.map((e) => ({
      code: e.id,
      title: e.title,
      taskId: epicIdByCode[e.id],
      sliceParity: e.parity,
      gapReport: e.gap,
    })),
    subtasks: subtasks.map((t) => ({
      code: t.code,
      epic: t.epic,
      taskId: subtaskIdByCode[t.code],
      title: t.title,
      context: t.context,
      definitionOfDone: t.dod,
      requirements: t.requirements,
      dependencies: t.depends,
      upstream: t.upstream,
      pizigTarget: t.pizig,
      complexity: t.complexity,
      priority: t.priority,
    })),
  };
  const jsonPath = path.join(repoRoot, 'docs/research/MASTER-GAPS.json');
  fs.writeFileSync(jsonPath, JSON.stringify(jsonOut, null, 2));
  log(`wrote ${jsonPath}`);

  // 6. Human-readable MASTER-GAPS.md.
  const mdLines = [];
  mdLines.push('# pi-zig parity — master gap inventory');
  mdLines.push('');
  mdLines.push(`Generated: ${jsonOut.generatedAt}`);
  mdLines.push('');
  mdLines.push(`**nulltickets pipeline:** \`${pipelineId}\` (\`pi-zig-parity\`)`);
  mdLines.push(`**Project path metadata:** \`${PROJECT_PATH}\` — open this folder in the Prin7r workspace to filter the tasks to this project.`);
  mdLines.push('');
  mdLines.push('## Epics (slice parity per research audit)');
  mdLines.push('');
  mdLines.push('| Code | Title | Slice parity | Gap report |');
  mdLines.push('|------|-------|--------------|------------|');
  for (const e of epics) mdLines.push(`| ${e.id} | ${e.title} | ${e.parity} | [${e.gap}](${e.gap.replace('docs/research/', '')}) |`);
  mdLines.push('');
  mdLines.push('## Subtasks (numbered checklist)');
  mdLines.push('');
  let n = 1;
  for (const e of epics) {
    mdLines.push(`### ${e.id} — ${e.title}`);
    mdLines.push('');
    const items = subtasks.filter((t) => t.epic === e.id);
    for (const t of items) {
      mdLines.push(`**${String(n).padStart(4, '0')}. [${t.code}] ${t.title}**`);
      mdLines.push(`- _Complexity:_ ${t.complexity}  ·  _Priority:_ ${t.priority}  ·  _Depends:_ ${t.depends.length ? t.depends.join(', ') : '—'}`);
      mdLines.push(`- _Upstream:_ \`${t.upstream}\`  →  _pi-zig:_ \`${t.pizig}\``);
      mdLines.push(`- **Context:** ${t.context}`);
      mdLines.push(`- **DoD:** ${t.dod}`);
      mdLines.push(`- **Requirements:** ${t.requirements.join('; ')}`);
      mdLines.push('');
      n++;
    }
  }
  const mdPath = path.join(repoRoot, 'docs/research/MASTER-GAPS.md');
  fs.writeFileSync(mdPath, mdLines.join('\n'));
  log(`wrote ${mdPath}`);

  log(`DONE — pipeline ${pipelineId}, ${epics.length} epics + ${subtasks.length} subtasks + ${depCount} deps`);
}

main().catch((e) => fail(e.stack ?? e.message ?? String(e)));

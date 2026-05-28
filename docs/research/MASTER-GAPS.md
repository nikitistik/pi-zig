# pi-zig parity — master gap inventory

Generated: 2026-05-28T11:04:58.008Z

**nulltickets pipeline:** `c0beb29a-12f2-4df2-8b2f-7882d6fc9182` (`pi-zig-parity`)
**Project path metadata:** `/Users/keer/projects/pi-zig` — open this folder in the Prin7r workspace to filter the tasks to this project.

## Epics (slice parity per research audit)

| Code | Title | Slice parity | Gap report |
|------|-------|--------------|------------|
| A | A — Agent-session runtime | 25-30% | [docs/research/gap-01-agent-session.md](gap-01-agent-session.md) |
| B | B — Auth / HTTP / Settings | 45% | [docs/research/gap-02-auth-http-settings.md](gap-02-auth-http-settings.md) |
| C | C — Messages / Compaction | 47% | [docs/research/gap-03-messages-compaction.md](gap-03-messages-compaction.md) |
| D | D — Modes / CLI / Main | 63% | [docs/research/gap-05-modes-cli-main.md](gap-05-modes-cli-main.md) |
| E | E — Interactive TUI | 10% | [docs/research/gap-06-interactive-tui.md](gap-06-interactive-tui.md) |
| F | F — Agent package library | 55% | [docs/research/gap-07-agent-package.md](gap-07-agent-package.md) |
| G | G — AI providers | 40-50% | [docs/research/gap-08-ai-providers.md](gap-08-ai-providers.md) |
| H | H — AI core | 43% | [docs/research/gap-09-ai-core.md](gap-09-ai-core.md) |
| I | I — Tools / Extensions / Resources | 47% | [docs/research/gap-04-tools-extensions-resources.md](gap-04-tools-extensions-resources.md) |
| J | J — TUI primitives | 20% | [docs/research/gap-10-tui-primitives.md](gap-10-tui-primitives.md) |

## Subtasks (numbered checklist)

### A — A — Agent-session runtime

**0001. [A1] Port event-bus.ts → event_bus.zig**
- _Complexity:_ Low  ·  _Priority:_ 90  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/event-bus.ts:1-33`  →  _pi-zig:_ `NEW src/pi/event_bus.zig`
- **Context:** Upstream packages/coding-agent/src/core/event-bus.ts (33 LoC) provides a typed pub/sub bus used by every emitted lifecycle event. pi-zig has NO equivalent module.
- **DoD:** New src/pi/event_bus.zig with subscribe/publish + per-event handler lists; unit tests cover ordering, multiple subscribers, removal mid-dispatch; wired into agent.zig + rpc.zig.
- **Requirements:** No stubs; Type-safe per-event payload; Re-entrant dispatch supported; Zig 0.16 idioms

**0002. [A2] Port telemetry.ts → telemetry.zig**
- _Complexity:_ Low  ·  _Priority:_ 60  ·  _Depends:_ A1
- _Upstream:_ `packages/coding-agent/src/core/telemetry.ts:1-13`  →  _pi-zig:_ `NEW src/pi/telemetry.zig`
- **Context:** Upstream telemetry.ts (13 LoC) exports a minimal telemetry sink interface that other modules call. pi-zig has no equivalent.
- **DoD:** src/pi/telemetry.zig with structured event emission; optional OTLP forwarding path stubbed cleanly (skip without endpoint); unit tests.
- **Requirements:** Honest skip when no endpoint; No PII

**0003. [A3] Port timings.ts → timings.zig**
- _Complexity:_ Low  ·  _Priority:_ 60  ·  _Depends:_ A1
- _Upstream:_ `packages/coding-agent/src/core/timings.ts:1-31`  →  _pi-zig:_ `NEW src/pi/timings.zig`
- **Context:** Upstream timings.ts (31 LoC) records spans + durations for prompt/turn/tool execution. pi-zig has no equivalent.
- **DoD:** src/pi/timings.zig with start/stop span API; emitted into event_bus; unit tests cover nested spans.
- **Requirements:** Monotonic clock; Nested span support

**0004. [A4] Port exec.ts → exec.zig**
- _Complexity:_ Medium  ·  _Priority:_ 70  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/exec.ts:1-107`  →  _pi-zig:_ `NEW src/pi/exec.zig`
- **Context:** Upstream exec.ts (107 LoC) is the cross-platform process exec helper used by tools and the agent harness. pi-zig calls std.process.run directly in scattered sites.
- **DoD:** src/pi/exec.zig with consolidated exec API (env, cwd, stdin, timeout, signal); callers refactored where it removes duplication.
- **Requirements:** Cooperative cancellation; stdout+stderr capture

**0005. [A5] Full FooterDataProvider (watcher + worktrees + reftable + extension statuses + provider badge)**
- _Complexity:_ High  ·  _Priority:_ 80  ·  _Depends:_ A1, H1
- _Upstream:_ `packages/coding-agent/src/core/footer-data-provider.ts:1-354`  →  _pi-zig:_ `NEW src/pi/footer_data.zig`
- **Context:** Upstream footer-data-provider.ts (354 LoC) feeds the live footer: git branch with reftable + worktree awareness, watched extension health badges, provider/model + thinking-level + token usage + cost. pi-zig's current `resolveGitBranch` (tui.zig) is a one-shot stub that runs `git symbolic-ref` once.
- **DoD:** src/pi/footer_data.zig that exposes a FooterData struct mirroring upstream's fields; fs.watch on .git/HEAD + worktrees + extension manifests; subscriber API for tui_footer.zig; unit tests + smoke driving a real worktree switch.
- **Requirements:** fs.watch / poll fallback; Reactive update; Per-token costs from Usage

**0006. [A6] Wire all missing AgentSessionEvent dispatches**
- _Complexity:_ High  ·  _Priority:_ 95  ·  _Depends:_ A1, I3
- _Upstream:_ `packages/coding-agent/src/core/agent-session.ts (event emit sites)`  →  _pi-zig:_ `src/pi/rpc.zig + src/pi/agent.zig FLOW_J regions`
- **Context:** Upstream emits 29+ AgentSessionEvents; pi-zig advertises them in upstream.zig but DOES NOT actually dispatch ~17 of them (session_before_compact, session_compact, session_before_tree, session_tree, session_before_fork, session_before_switch, queue_update, compaction_start/end, session_info_changed, thinking_level_changed, model_select, thinking_level_select, message_update, tool_execution_*, before_agent_start, resources_discover, context, input).
- **DoD:** Each missing event has a concrete dispatch site in rpc.zig/agent.zig with the upstream payload shape; extensions receive them via the existing FLOW_J seam; per-event smoke proves the extension handler observes the event.
- **Requirements:** No fire-and-forget where upstream chains values (must honor returned transforms); Test each event independently

**0007. [A7] importFromJsonl / exportToJsonl / reload**
- _Complexity:_ Medium  ·  _Priority:_ 70  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/session-manager.ts`  →  _pi-zig:_ `src/pi/session.zig`
- **Context:** Upstream session-manager exposes importFromJsonl, exportToJsonl, reload(); none exist in pi-zig.
- **DoD:** src/pi/session.zig gains the three functions with byte-exact JSONL round-trip; unit tests cover empty/malformed/header-only sessions.
- **Requirements:** Round-trip equality; Atomic file replace

**0008. [A8] createAgentSessionServices / FromServices / Runtime factory pattern**
- _Complexity:_ High  ·  _Priority:_ 50  ·  _Depends:_ A1
- _Upstream:_ `packages/coding-agent/src/core/agent-session-services.ts + agent-session-runtime.ts`  →  _pi-zig:_ `src/pi/agent.zig + src/pi/rpc.zig`
- **Context:** Upstream uses a 3-layer factory: createAgentSessionServices (wire services), createAgentSessionFromServices (compose), createAgentSessionRuntime (drive). pi-zig builds Runtime once at process start; cannot tear down and rebuild mid-process.
- **DoD:** Refactor agent.zig + rpc.zig so a Runtime can be (re)constructed from a Services struct; in-process swap supported; unit test exercises two sequential lifetimes.
- **Requirements:** No leaks on swap; Outstanding work cancelled cleanly

**0009. [A9] getAttributionHeaders (OpenRouter / Cloudflare / opencode)**
- _Complexity:_ Low  ·  _Priority:_ 60  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/providers/* (search getAttributionHeaders)`  →  _pi-zig:_ `src/pi/ai_client.zig`
- **Context:** Upstream attaches HTTP attribution headers (HTTP-Referer, X-Title, opencode session id) on provider requests. pi-zig sends none.
- **DoD:** ai_client.zig adds attribution-header construction gated by provider id; smoke asserts headers on outgoing requests.
- **Requirements:** No PII; Per-provider exact header names

**0010. [A10] excludeFromContext (!! prefix), scoped-models cycling, setRebindSession, withSession, nextTurn custom messages, before_agent_start system-prompt override, dynamic image filtering**
- _Complexity:_ High  ·  _Priority:_ 70  ·  _Depends:_ A6
- _Upstream:_ `packages/coding-agent/src/core/agent-session.ts`  →  _pi-zig:_ `src/pi/rpc.zig + src/pi/agent.zig`
- **Context:** Cluster of session-control features missing entirely. excludeFromContext lets a user message with `!!` prefix run a bash without entering the LLM context; scoped-models cycles a curated subset; setRebindSession swaps the bound session; withSession() wraps a callback in a session; before_agent_start hook can replace the system prompt per turn; blockImages dynamically strips images from outgoing messages.
- **DoD:** Each sub-feature has a code path + unit test + integration smoke; documented in docs/parity.md per-feature row.
- **Requirements:** No silent failures; Per-feature smoke against fake provider

### B — B — Auth / HTTP / Settings

**0011. [B1] AuthStorage class abstraction + runtime --api-key override + models.json fallback**
- _Complexity:_ High  ·  _Priority:_ 85  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/auth-storage.ts`  →  _pi-zig:_ `NEW src/pi/auth_storage.zig`
- **Context:** Upstream AuthStorage class exposes get/set/list with runtime --api-key override and models.json fallback for custom providers. pi-zig's auth.zig has flat function helpers and only 3 of 6 upstream source arms in status output; no runtime --api-key override.
- **DoD:** src/pi/auth_storage.zig with full AuthStorage API + `--api-key` override + models.json fallback resolver; status output covers all 6 source arms; unit tests for each source.
- **Requirements:** Thread-safe; No secrets in logs

**0012. [B2] Interactive OAuth login: PKCE + device-code + local callback HTTP server**
- _Complexity:_ High  ·  _Priority:_ 80  ·  _Depends:_ B1
- _Upstream:_ `packages/ai/src/utils/oauth/* + packages/coding-agent/src/core/auth-guidance.ts`  →  _pi-zig:_ `NEW src/pi/auth_login.zig`
- **Context:** pi-zig's interactive login (auth.zig:1431-1447) always returns InteractiveLoginUnavailable. Upstream supports PKCE for Anthropic, device-code for OpenAI Codex + GitHub Copilot, local callback HTTP server, manual-paste fallback.
- **DoD:** src/pi/auth_login.zig with PKCE generator, callback server, device-code polling for each of the 3 OAuth providers; live-cred opt-in smokes (skip cleanly without creds); never print secrets.
- **Requirements:** No secrets logged; Browser open via std.process

**0013. [B3] Cross-process file lock for auth.json + chmod 0o600**
- _Complexity:_ Medium  ·  _Priority:_ 90  ·  _Depends:_ B1
- _Upstream:_ `packages/coding-agent/src/core/auth-storage.ts (writeAuthStorage)`  →  _pi-zig:_ `src/pi/auth.zig`
- **Context:** Concurrent pi-zig instances can clobber freshly minted OAuth tokens. Upstream uses flock. pi-zig has none. File mode is default (group-readable on most setups).
- **DoD:** auth.json reads/writes wrapped in OS-appropriate advisory lock; chmod 0o600 on write; unit test triggers two concurrent writes and verifies last-writer-wins atomic.
- **Requirements:** Lock timeout configurable; macOS + Linux

**0014. [B4] configureHttpDispatcher with runtime httpIdleTimeoutMs effect**
- _Complexity:_ Medium  ·  _Priority:_ 75  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/http-dispatcher.ts`  →  _pi-zig:_ `NEW src/pi/http_dispatcher.zig`
- **Context:** pi-zig parses httpIdleTimeoutMs from settings and shows it but it has ZERO runtime effect on actual HTTP traffic. Upstream's http-dispatcher applies it.
- **DoD:** src/pi/http_dispatcher.zig that wraps std.http.Client with idle-timeout enforcement; setting changes propagate live; smoke proves a slow server times out at the configured value.
- **Requirements:** Configurable per-request override; Honor "disabled" → 0

**0015. [B5] session-cwd.ts: persist cwd into session header, missing-cwd check**
- _Complexity:_ Low  ·  _Priority:_ 80  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/session-cwd.ts`  →  _pi-zig:_ `src/pi/session.zig`
- **Context:** Upstream session-cwd.ts persists project cwd into the session JSONL header and exposes a missing-cwd check. pi-zig writes `"cwd":"."` (hardcoded) so the precondition is destroyed.
- **DoD:** Session header carries the real absolute cwd; missing-cwd check refuses to load when target cwd is gone; unit + smoke.
- **Requirements:** Absolute path; Symlink-stable

**0016. [B6] output-guard.ts: stdout takeover + ENOBUFS-retry backpressure pump**
- _Complexity:_ Medium  ·  _Priority:_ 75  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/output-guard.ts`  →  _pi-zig:_ `NEW src/pi/output_guard.zig`
- **Context:** Upstream output-guard.ts owns the stdout takeover for JSON/RPC modes and applies ENOBUFS-retry backpressure on writes. pi-zig has no such layer.
- **DoD:** src/pi/output_guard.zig with write pump + ENOBUFS retry + flush guarantees; rpc.zig and JSON mode routed through it; unit test with a fake non-blocking pipe.
- **Requirements:** No write reordering; EOF safe

**0017. [B7] auth-guidance.ts: 4 shared formatter functions**
- _Complexity:_ Low  ·  _Priority:_ 50  ·  _Depends:_ B1
- _Upstream:_ `packages/coding-agent/src/core/auth-guidance.ts`  →  _pi-zig:_ `src/pi/auth.zig`
- **Context:** Upstream auth-guidance.ts exports 4 shared formatter functions used in CLI error messages. Absent in pi-zig.
- **DoD:** Helper functions ported with byte-exact strings; reused from auth + cli_runtime error paths; unit tests pin the exact strings.
- **Requirements:** Byte-exact upstream strings

**0018. [B8] diagnostics.ts schemas: ResourceCollision + ResourceDiagnostic**
- _Complexity:_ Low  ·  _Priority:_ 60  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/diagnostics.ts`  →  _pi-zig:_ `NEW src/pi/diagnostics.zig`
- **Context:** Upstream diagnostics.ts defines two TypeBox schemas (ResourceCollision, ResourceDiagnostic) consumed by commands/themes. pi-zig emits a similar JSON but has no type/schema.
- **DoD:** src/pi/diagnostics.zig with the two structs + JSON serialization; commands.zig and themes.zig use them.
- **Requirements:** Schema matches upstream field names

**0019. [B9] resolveConfigValue cache + resolveHeaders helper**
- _Complexity:_ Low  ·  _Priority:_ 55  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/resolve-config-value.ts`  →  _pi-zig:_ `src/pi/auth.zig`
- **Context:** Upstream caches `!cmd` shell-resolved values; pi-zig re-runs the shell exec on every call. Upstream has a separate resolveHeaders that expands `!cmd` per-header.
- **DoD:** auth.zig adds a cache (TTL configurable) + resolveHeaders helper; unit test ensures cache hit on repeated read.
- **Requirements:** TTL semantics; No stale tokens

**0020. [B10] Settings write-path per-field validation + clamping**
- _Complexity:_ Medium  ·  _Priority:_ 50  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/settings-manager.ts`  →  _pi-zig:_ `src/pi/settings.zig`
- **Context:** Settings READ-path validates but WRITE-path doesn't. Bad values land in settings.json silently.
- **DoD:** Each write path validates + clamps per upstream rules; bad input rejected with diagnostic; unit tests per field.
- **Requirements:** Match upstream error strings

### C — C — Messages / Compaction

**0021. [C1] Compaction: findCutPoint + keepRecentTokens + split-turn**
- _Complexity:_ High  ·  _Priority:_ 85  ·  _Depends:_ H1, C3
- _Upstream:_ `packages/coding-agent/src/core/compaction/`  →  _pi-zig:_ `NEW src/pi/compaction.zig`
- **Context:** Upstream compaction preserves a "recent window" and can split a turn boundary. pi-zig compacts the entire ring (no recent window) and never splits a turn.
- **DoD:** src/pi/compaction.zig with findCutPoint / keepRecentTokens / split-turn helpers; rpc.zig FLOW_E uses them; unit tests cover token-budget edge cases.
- **Requirements:** Match upstream cut semantics byte-for-byte; Token budget from Usage

**0022. [C2] UPDATE_SUMMARIZATION_PROMPT + TURN_PREFIX_SUMMARIZATION_PROMPT**
- _Complexity:_ Low  ·  _Priority:_ 70  ·  _Depends:_ C1
- _Upstream:_ `packages/coding-agent/src/core/compaction/`  →  _pi-zig:_ `src/pi/rpc.zig FLOW_E`
- **Context:** Two summarization prompt constants used when re-summarizing on top of an existing compaction or prefixing a turn. Absent in pi-zig.
- **DoD:** Constants ported byte-exact; used by FLOW_E compaction code path.
- **Requirements:** Byte-exact

**0023. [C3] estimateContextTokens from Usage**
- _Complexity:_ Medium  ·  _Priority:_ 80  ·  _Depends:_ H1
- _Upstream:_ `packages/coding-agent/src/core/compaction/`  →  _pi-zig:_ `src/pi/ai_client.zig + src/pi/rpc.zig`
- **Context:** pi-zig estimates tokens by chars/4. Upstream uses provider-reported Usage. Requires Usage in ChatCompletionResult.
- **DoD:** ChatCompletionResult carries Usage; compaction trigger reads it; unit tests check overflow trigger fires when usage exceeds budget.
- **Requirements:** Per-provider usage parse

**0024. [C4] Fix firstKeptEntryId semantic (currently OPPOSITE of upstream)**
- _Complexity:_ Low  ·  _Priority:_ 95  ·  _Depends:_ C1
- _Upstream:_ `packages/coding-agent/src/core/compaction/`  →  _pi-zig:_ `src/pi/rpc.zig FLOW_E`
- **Context:** pi-zig sets firstKeptEntryId = messages[0].entryId() — the FIRST message. Upstream sets it to the first KEPT message after compaction (typically the last one before the cut). Reload misbehaves.
- **DoD:** Semantic corrected; reload tests pass; round-trip exercises pre/post-compaction state.
- **Requirements:** Reload-stable

**0025. [C5] parseStoredRole / loadSessionEntries: recognize branchSummary**
- _Complexity:_ Low  ·  _Priority:_ 85  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/messages.ts`  →  _pi-zig:_ `src/pi/rpc.zig`
- **Context:** Upstream stores branch_summary as a role-tagged entry; on reload pi-zig's parseStoredRole DOES NOT recognize the branchSummary role, so branch_summary entries don't re-inject into in-memory context.
- **DoD:** parseStoredRole supports branchSummary; loadSessionEntries loads them; re-injects on reload; round-trip test.
- **Requirements:** Round-trip stable

**0026. [C6] BRANCH_SUMMARY_PREFIX/SUFFIX constants + BranchSummaryDetails {readFiles, modifiedFiles, replaceInstructions, BRANCH_SUMMARY_PREAMBLE}**
- _Complexity:_ Medium  ·  _Priority:_ 75  ·  _Depends:_ C5
- _Upstream:_ `packages/coding-agent/src/core/messages.ts + compaction/`  →  _pi-zig:_ `src/pi/rpc.zig FLOW_G`
- **Context:** Upstream wraps branch_summary entries in PREFIX/SUFFIX and carries file-ops details. Absent in pi-zig.
- **DoD:** Constants + struct ported; FLOW_G writes them; unit tests assert the on-disk JSONL shape.
- **Requirements:** Byte-exact

**0027. [C7] Wire remaining 9 of 21 builtin slash commands**
- _Complexity:_ High  ·  _Priority:_ 90  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/slash-commands.ts`  →  _pi-zig:_ `src/pi/tui.zig + src/pi/cli_runtime.zig`
- **Context:** tui.zig:runCommand reports "recognized but not yet wired" for ~9 of 21 slash commands. The user demanded no stubs.
- **DoD:** Each remaining command is fully implemented (real handler, not "not yet wired"); per-command App-level unit test; smoke proves CLI-observable behavior where applicable.
- **Requirements:** No "not yet wired" lines remain in tui.zig

**0028. [C8] KeybindingsManager: 43 ids + keybindings.json loader + KEYBINDING_NAME_MIGRATIONS + Windows special cases**
- _Complexity:_ High  ·  _Priority:_ 75  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/keybindings.ts`  →  _pi-zig:_ `NEW src/pi/keybindings.zig`
- **Context:** pi-zig covers ~12 of 43 upstream AppKeybindings ids; no keybindings.json loader, no migrations, no Windows differences.
- **DoD:** src/pi/keybindings.zig (new) with full id list + JSON loader + migrations table + Windows variants; unit tests per id.
- **Requirements:** Migration table byte-exact

**0029. [C9] SessionManager: list / listAll / inMemory / continueRecent / createBranchedSession**
- _Complexity:_ Medium  ·  _Priority:_ 80  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/session-manager.ts`  →  _pi-zig:_ `src/pi/session.zig`
- **Context:** Upstream surfaces 5 session-level operations missing in pi-zig.
- **DoD:** Each function ported; unit tests + smoke; CLI `--resume` picker (D6) consumes list output.
- **Requirements:** mtime-sorted; Cross-cwd safe

**0030. [C10] LabelEntry: appendLabelChange + getLabel**
- _Complexity:_ Low  ·  _Priority:_ 50  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/session-manager.ts`  →  _pi-zig:_ `src/pi/session.zig`
- **Context:** Upstream session JSONL supports LabelEntry rows; pi-zig has no such entry type.
- **DoD:** session.zig writes/reads LabelEntry; appendLabelChange/getLabel; round-trip test.
- **Requirements:** JSONL schema matches upstream

**0031. [C11] Fix hardcoded session-header cwd="." and timestamp="local-foundation"**
- _Complexity:_ Low  ·  _Priority:_ 75  ·  _Depends:_ B5
- _Upstream:_ `packages/coding-agent/src/core/session-manager.ts + session-cwd.ts`  →  _pi-zig:_ `src/pi/session.zig`
- **Context:** session.zig:108 writes `"cwd":"."`; timestamp is a placeholder string. Upstream writes the real absolute cwd + ISO timestamp.
- **DoD:** Real cwd + ISO timestamp; backward-load is tolerant of legacy values; smoke verifies fresh session header.
- **Requirements:** ISO 8601 timestamp; Absolute cwd

**0032. [C12] Multi-version session loading (v1→v2, v2→v3 migrations)**
- _Complexity:_ Medium  ·  _Priority:_ 55  ·  _Depends:_ C11
- _Upstream:_ `packages/coding-agent/src/core/session-manager.ts`  →  _pi-zig:_ `src/pi/session.zig`
- **Context:** pi-zig rejects any session whose header is not version:3. Upstream migrates v1→v2 and v2→v3 on load.
- **DoD:** Migration functions ported; reload of legacy session works; round-trip test per migration.
- **Requirements:** Lossless

**0033. [C13] excludeFromContext (!! prefix) modeled in messages**
- _Complexity:_ Medium  ·  _Priority:_ 60  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/messages.ts`  →  _pi-zig:_ `src/pi/session.zig + src/pi/rpc.zig`
- **Context:** A user message starting with `!!` runs a bash but is NOT entered into the LLM context. Not modeled in pi-zig's messages.
- **DoD:** Message type carries excludeFromContext flag; provider history skips them; smoke shows the bash ran and the assistant didn't see the message.
- **Requirements:** Flag persisted

**0034. [C14] CustomMessage.details + image-block content persisted**
- _Complexity:_ Low  ·  _Priority:_ 55  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/messages.ts`  →  _pi-zig:_ `src/pi/session.zig`
- **Context:** CustomMessage.details (free-form JSON) and image-block content are NOT persisted by pi-zig's appendCustomMessage.
- **DoD:** JSONL carries details + image parts; reload restores them; unit test round-trip.
- **Requirements:** Schema matches upstream

**0035. [C15] Source-info: SourceScope / SourceOrigin / SourceInfo + createSourceInfo / createSyntheticSourceInfo**
- _Complexity:_ Low  ·  _Priority:_ 45  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/source-info.ts`  →  _pi-zig:_ `NEW src/pi/source_info.zig`
- **Context:** Upstream models source-info as 3 typed scopes + factory functions. pi-zig only serializes JSON via writeSourceInfoWithOrigin; no types/factories.
- **DoD:** src/pi/source_info.zig with the 3 types + factory functions; commands.zig consumes them; unit tests.
- **Requirements:** Type-safe

### D — D — Modes / CLI / Main

**0036. [D1] Migrations: 5 missing (auth-to-json, sessions-from-agent-root, commands-to-prompts, tools-to-bin, keybindings-config-file)**
- _Complexity:_ Medium  ·  _Priority:_ 75  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/migrations.ts`  →  _pi-zig:_ `NEW src/pi/migrations.zig`
- **Context:** Upstream migrations.ts runs 5 one-shot migrations on first launch. pi-zig has 0% of this.
- **DoD:** src/pi/migrations.zig with all 5 migrations; idempotent; runs on cli_runtime entrypoint; unit tests verify each migration's before/after on a temp dir.
- **Requirements:** Idempotent; Atomic

**0037. [D2] RpcClient programmatic API**
- _Complexity:_ Medium  ·  _Priority:_ 50  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/modes/rpc/rpc-client.ts`  →  _pi-zig:_ `NEW src/pi/rpc_client.zig`
- **Context:** Upstream exports an RpcClient class for embedders (Node/TS callers). pi-zig has no equivalent — consumers must speak JSONL directly.
- **DoD:** src/pi/rpc_client.zig (Zig embedder API) + a frontend client wrapper if needed; smoke drives it.
- **Requirements:** Type-safe wrappers per command

**0038. [D3] utils/ closures: clipboard, image-resize, syntax-highlight, version-check, tools-manager, Windows self-update quarantine, changelog parser**
- _Complexity:_ High  ·  _Priority:_ 65  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/utils/*`  →  _pi-zig:_ `src/pi/cli_runtime.zig + new utils modules`
- **Context:** pi-zig's utils coverage is ~30%; 7 specific helpers missing.
- **DoD:** Each helper has a Zig port (or honest shell-out for image-resize); per-helper unit test.
- **Requirements:** No PII; Cross-platform

**0039. [D4] cli/ closures: selectConfig, selectSession, listModels text rendering, image-resize processFileArguments**
- _Complexity:_ Medium  ·  _Priority:_ 60  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/cli/*`  →  _pi-zig:_ `src/pi/cli.zig + src/pi/cli_runtime.zig`
- **Context:** pi-zig's cli/ coverage is ~40%.
- **DoD:** Each function ported; smoke verifies CLI-observable text output.
- **Requirements:** Byte-exact upstream output where applicable

**0040. [D5] `pi config` TUI**
- _Complexity:_ High  ·  _Priority:_ 60  ·  _Depends:_ E1
- _Upstream:_ `packages/coding-agent/src/cli/config-selector.ts`  →  _pi-zig:_ `src/pi/cli_runtime.zig + new tui module`
- **Context:** Upstream `pi config` opens a TUI for resource enable/disable. pi-zig has no such command.
- **DoD:** New subcommand `pi-zig config` opens a TUI dialog (via tui_selector) to toggle resources; persisted to settings.
- **Requirements:** Live reflect to settings.json

**0041. [D6] `--resume` session picker UI**
- _Complexity:_ Medium  ·  _Priority:_ 60  ·  _Depends:_ E1, C9
- _Upstream:_ `packages/coding-agent/src/cli/session-selector`  →  _pi-zig:_ `src/pi/cli_runtime.zig`
- **Context:** pi-zig opens the newest session directly. Upstream offers a picker UI.
- **DoD:** TUI picker built on tui_selector; smoke drives selection by index.
- **Requirements:** Sorted mtime; Cross-cwd

**0042. [D7] `--session` cross-project global prompt**
- _Complexity:_ Low  ·  _Priority:_ 45  ·  _Depends:_ B5
- _Upstream:_ `packages/coding-agent/src/cli/args.ts`  →  _pi-zig:_ `src/pi/cli_runtime.zig`
- **Context:** Upstream supports a cross-project session prompt. pi-zig is project-local.
- **DoD:** --session can target any cwd; safety: refuse if cwd missing; unit test.
- **Requirements:** Refuse missing cwd

**0043. [D8] `--api-key` without `--model` diagnostic**
- _Complexity:_ Low  ·  _Priority:_ 40  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/cli/args.ts`  →  _pi-zig:_ `src/pi/cli.zig`
- **Context:** Upstream emits a specific error when --api-key is supplied without --model. pi-zig silently ignores.
- **DoD:** Exact upstream diagnostic emitted; unit test pins the string.
- **Requirements:** Byte-exact

**0044. [D9] `queue_update` RPC event**
- _Complexity:_ Low  ·  _Priority:_ 70  ·  _Depends:_ A6
- _Upstream:_ `packages/coding-agent/src/modes/rpc/rpc-mode.ts`  →  _pi-zig:_ `src/pi/rpc.zig`
- **Context:** Upstream emits queue_update events whenever steering/follow-up queue changes. pi-zig requires clients to poll.
- **DoD:** rpc.zig emits queue_update on every change; smoke asserts events flow.
- **Requirements:** Wire shape matches upstream

**0045. [D10] Multi-message print mode (loop)**
- _Complexity:_ Low  ·  _Priority:_ 55  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/modes/print-mode.ts`  →  _pi-zig:_ `src/pi/cli_runtime.zig`
- **Context:** Upstream `for (const message of messages) await session.prompt(message)`; pi-zig folds multiple messages into one.
- **DoD:** Print-mode loops per-message; smoke proves N messages produce N assistant turns.
- **Requirements:** Order preserved

**0046. [D11] `--list-models` text rendering**
- _Complexity:_ Low  ·  _Priority:_ 35  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/cli/list-models.ts`  →  _pi-zig:_ `src/pi/cli_runtime.zig`
- **Context:** pi-zig emits JSON only; upstream has a tabular text mode (default).
- **DoD:** Default text rendering; --json keeps JSON output; unit test.
- **Requirements:** Match upstream column layout

### E — E — Interactive TUI

**0047. [E1] Wire orphan tui_markdown / tui_footer / tui_messages / tui_theme / tui_selector into tui.zig + index.zig**
- _Complexity:_ Medium  ·  _Priority:_ 100  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/modes/interactive/components/* + packages/tui/src/components/markdown.ts`  →  _pi-zig:_ `src/pi/tui.zig + src/pi/index.zig`
- **Context:** These modules exist with passing unit tests but are NOT imported by tui.zig and NOT exported from src/pi/index.zig — dead code. The live binary never paints them.
- **DoD:** tui.zig:buildScreen routes user/assistant/tool/bash entries through tui_messages; transcript text routes through tui_markdown; bottom strip uses tui_footer; theme palette derived via tui_theme; overlay selectors use tui_selector; pty harness + browser screenshots show the live difference.
- **Requirements:** No dead modules; Each integration has at least one smoke assertion that the new render reaches stdout

**0048. [E2] Port 24 missing interactive components**
- _Complexity:_ High  ·  _Priority:_ 95  ·  _Depends:_ E1, J4
- _Upstream:_ `packages/coding-agent/src/modes/interactive/components/*`  →  _pi-zig:_ `NEW src/pi/tui_components/*.zig`
- **Context:** 24 of 35 upstream components have NO equivalent: login-dialog, oauth-selector, session-selector, session-selector-search, tree-selector, settings-selector, scoped-models-selector, extension-editor, extension-input, extension-selector, config-selector, custom-editor, theme-selector, thinking-selector, show-images-selector, user-message-selector, dynamic-border, bordered-loader, custom-message, branch-summary-message, compaction-summary-message, skill-invocation-message, tool-execution, image.
- **DoD:** Each component has a Zig module + unit tests + integration smoke proving live render.
- **Requirements:** Box-drawing matches upstream square corners (not arc)

**0049. [E3] Theme: full 49-token palette, truecolor, file watcher, COLORFGBG/OSC 11 detection, theme reload, markdown/syntax themes, /theme builtin**
- _Complexity:_ High  ·  _Priority:_ 80  ·  _Depends:_ E1
- _Upstream:_ `packages/coding-agent/src/modes/interactive/theme/theme.ts`  →  _pi-zig:_ `src/pi/tui_theme.zig`
- **Context:** pi-zig consumes 6 of 49 upstream theme tokens; no truecolor; no watcher; no COLORFGBG/OSC 11 detection; /theme not even in builtin_commands.
- **DoD:** tui_theme.zig consumes all 49 tokens, truecolor support, file watcher reloads, COLORFGBG/OSC 11 read at startup, /theme command opens a theme selector; per-token unit tests.
- **Requirements:** Truecolor + 256-color fallback

**0050. [E4] InteractiveMode controller: port remaining ~125 of 150 methods**
- _Complexity:_ High  ·  _Priority:_ 90  ·  _Depends:_ E1, E2, A6
- _Upstream:_ `packages/coding-agent/src/modes/interactive/interactive-mode.ts`  →  _pi-zig:_ `src/pi/tui.zig + src/pi/cli_runtime.zig`
- **Context:** Upstream's InteractiveMode (5564 LoC) has ~150 methods. pi-zig has ≤25. Missing entire subsystems: extension UI, message queueing/steering/follow-up, double-key timing, compaction/retry state, event-driven handleEvent (15-arm switch).
- **DoD:** Each missing subsystem ported with App-level unit tests + integration smoke; documented per-method coverage.
- **Requirements:** Behaviorally faithful

**0051. [E5] Animated spinner (replace static "[working...]")**
- _Complexity:_ Low  ·  _Priority:_ 55  ·  _Depends:_ E1
- _Upstream:_ `packages/coding-agent/src/modes/interactive/components/bordered-loader.ts + loader.ts`  →  _pi-zig:_ `src/pi/tui.zig`
- **Context:** pi-zig shows "[working... press Esc to abort]" static. Upstream animates a spinner.
- **DoD:** Spinner cycles per render; smoke captures multiple frames.
- **Requirements:** Frame-rate stable

**0052. [E6] Terminal-width dynamic dividers**
- _Complexity:_ Medium  ·  _Priority:_ 55  ·  _Depends:_ E1, J6
- _Upstream:_ `packages/tui/src/terminal.ts`  →  _pi-zig:_ `src/pi/tui.zig + src/pi/tui_terminal.zig`
- **Context:** Dividers are hardcoded 80 cells. Upstream scales to terminal width.
- **DoD:** Read columns via TIOCGWINSZ; divider auto-fits; SIGWINCH triggers reflow.
- **Requirements:** SIGWINCH handler

**0053. [E7] OSC 133 zone codes + OSC 9;4 progress**
- _Complexity:_ Low  ·  _Priority:_ 45  ·  _Depends:_ E1
- _Upstream:_ `packages/tui/src/terminal.ts`  →  _pi-zig:_ `src/pi/tui.zig`
- **Context:** Modern terminals (iTerm2, WezTerm, kitty) honor OSC 133 (semantic prompt zones) and OSC 9;4 (progress bar). Both absent.
- **DoD:** Emit OSC 133 around prompt/output zones; OSC 9;4 progress around active tool runs; smoke captures escape sequences in stdout.
- **Requirements:** No terminal harm without support

**0054. [E8] Earendil-announcement / armin / daxnuts easter eggs**
- _Complexity:_ Low  ·  _Priority:_ 20  ·  _Depends:_ E1
- _Upstream:_ `packages/coding-agent/src/modes/interactive/components/{earendil-announcement,armin,daxnuts}.ts`  →  _pi-zig:_ `src/pi/tui.zig`
- **Context:** Three small visual easter-eggs present upstream; absent in pi-zig.
- **DoD:** Each rendered when triggered; smoke proves activation paths.
- **Requirements:** Opt-in only

**0055. [E9] Switch box-drawing arc corners ╭╮╰╯ → square ┌┐└┘ (or expose as theme)**
- _Complexity:_ Low  ·  _Priority:_ 40  ·  _Depends:_ E1
- _Upstream:_ `packages/coding-agent/src/modes/interactive/components/*`  →  _pi-zig:_ `src/pi/tui_messages.zig + tui_footer.zig`
- **Context:** pi-zig uses arc corners; upstream uses square. Visual divergence.
- **DoD:** Default is square (matching upstream); theme can override.
- **Requirements:** No regression in unit tests asserting specific glyphs

**0056. [E10] Update Available banner with real version-check HTTP probe**
- _Complexity:_ Medium  ·  _Priority:_ 50  ·  _Depends:_ E1
- _Upstream:_ `packages/coding-agent/src/modes/interactive/components/footer.ts`  →  _pi-zig:_ `src/pi/tui_footer.zig`
- **Context:** Currently gated on PI_ZIG_NEW_VERSION env; no real version check.
- **DoD:** Background HTTP probe of pi.dev/api/latest-version (configurable); banner shows when newer is available; cached for N hours.
- **Requirements:** No blocking startup; Honor PI_OFFLINE

### F — F — Agent package library

**0057. [F1] Embeddable Agent / AgentHarness classes**
- _Complexity:_ High  ·  _Priority:_ 60  ·  _Depends:_ A8
- _Upstream:_ `packages/agent/src/agent.ts + agent-harness.ts`  →  _pi-zig:_ `NEW src/pi/agent_harness.zig`
- **Context:** Upstream exports Agent + AgentHarness classes for library consumers. pi-zig's code is process-coupled.
- **DoD:** src/pi/agent_harness.zig provides a stable embedder API; sample embedder demo; unit tests.
- **Requirements:** No global state

**0058. [F2] Pluggable StreamFn**
- _Complexity:_ Medium  ·  _Priority:_ 55  ·  _Depends:_ —
- _Upstream:_ `packages/agent/src/agent.ts`  →  _pi-zig:_ `src/pi/agent.zig`
- **Context:** Provider is hardcoded in ai_client.zig. Upstream allows a StreamFn override.
- **DoD:** agent.zig accepts a stream callback; existing providers wrap it; unit test with a fake StreamFn.
- **Requirements:** Cancellation propagated

**0059. [F3] Parallel tool execution + executionMode**
- _Complexity:_ High  ·  _Priority:_ 65  ·  _Depends:_ F2
- _Upstream:_ `packages/agent/src/agent.ts`  →  _pi-zig:_ `src/pi/agent.zig`
- **Context:** Upstream supports parallel tool execution per-turn. pi-zig is sequential.
- **DoD:** agent.zig executes independent tool calls in parallel when executionMode=parallel; per-tool isolation; unit test counts wall-clock vs serial.
- **Requirements:** No tool cross-talk; Cancellation per-tool

**0060. [F4] transformContext / convertToLlm callbacks**
- _Complexity:_ Medium  ·  _Priority:_ 50  ·  _Depends:_ —
- _Upstream:_ `packages/agent/src/agent.ts`  →  _pi-zig:_ `src/pi/agent.zig`
- **Context:** Upstream hooks to transform context + convert to LLM format. pi-zig has no such seam.
- **DoD:** Hooks added to RunOptions; unit tests cover transform + convert.
- **Requirements:** Type-safe

**0061. [F5] ExecutionEnv abstraction**
- _Complexity:_ High  ·  _Priority:_ 55  ·  _Depends:_ —
- _Upstream:_ `packages/agent/src/exec-env.ts`  →  _pi-zig:_ `src/pi/tools.zig + src/pi/agent.zig`
- **Context:** Upstream tools call through an ExecutionEnv; pi-zig calls std.fs / std.process directly. Hard to mock.
- **DoD:** ExecutionEnv interface added; tools refactored to call it; mock-env tests.
- **Requirements:** Backwards-compat default

**0062. [F6] Result<T,E> model + stable error-code classes**
- _Complexity:_ Medium  ·  _Priority:_ 45  ·  _Depends:_ —
- _Upstream:_ `packages/agent/src/result.ts`  →  _pi-zig:_ `src/pi/agent.zig + src/pi/rpc.zig`
- **Context:** Upstream uses a Result pattern with classified errors; pi-zig uses Zig error union with coarse names.
- **DoD:** Wrap public APIs in Result-equivalent; map upstream error codes 1:1; consumer-friendly.
- **Requirements:** Error mapping table

**0063. [F7] streamProxy**
- _Complexity:_ Medium  ·  _Priority:_ 35  ·  _Depends:_ F2
- _Upstream:_ `packages/agent/src/stream-proxy.ts`  →  _pi-zig:_ `src/pi/agent.zig`
- **Context:** Upstream's streamProxy multiplexes provider streams; absent in pi-zig.
- **DoD:** streamProxy ported; smoke proves dual-consumer scenario.
- **Requirements:** Backpressure-safe

**0064. [F8] In-memory session backend**
- _Complexity:_ Medium  ·  _Priority:_ 45  ·  _Depends:_ —
- _Upstream:_ `packages/agent/src/in-memory-session.ts`  →  _pi-zig:_ `src/pi/session.zig`
- **Context:** Upstream supports an in-memory session backend for tests/ephemeral runs.
- **DoD:** src/pi/session_repo.zig with an InMemory backend selectable via RunOptions; unit test exercises both backends.
- **Requirements:** No disk writes when in-memory

**0065. [F9] JsonlSessionRepo class + cwd-indexed dirs + encodeCwd**
- _Complexity:_ Medium  ·  _Priority:_ 60  ·  _Depends:_ F8
- _Upstream:_ `packages/agent/src/jsonl-session-repo.ts`  →  _pi-zig:_ `NEW src/pi/session_repo.zig`
- **Context:** Upstream organizes session JSONLs in cwd-indexed dirs via encodeCwd helper. pi-zig uses a single sessions dir.
- **DoD:** JsonlSessionRepo with cwd-encoded subdirs; encodeCwd helper byte-exact; smoke verifies dir layout.
- **Requirements:** Byte-exact encodeCwd

**0066. [F10] UUID v7**
- _Complexity:_ Low  ·  _Priority:_ 50  ·  _Depends:_ —
- _Upstream:_ `packages/agent/src/uuid.ts`  →  _pi-zig:_ `NEW src/pi/uuid.zig`
- **Context:** Upstream uses UUID v7 for run ids; pi-zig uses ad-hoc ids.
- **DoD:** src/pi/uuid.zig with v7 generator; unit tests verify time-ordered uniqueness.
- **Requirements:** RFC9562 v7

**0067. [F11] Outer follow-up replay (single agent loop drains batches)**
- _Complexity:_ High  ·  _Priority:_ 60  ·  _Depends:_ —
- _Upstream:_ `packages/agent/src/agent.ts`  →  _pi-zig:_ `src/pi/agent.zig + src/pi/rpc.zig`
- **Context:** RPC currently re-invokes runPrompt per drained batch. Upstream's agent loop drains internally.
- **DoD:** agent.zig loops over queue; rpc.zig dispatches once; unit test exercises multi-batch drain.
- **Requirements:** Cancellation semantics preserved

**0068. [F12] prepareNextTurn: replace context/messages/tools/thinkingLevel**
- _Complexity:_ Medium  ·  _Priority:_ 55  ·  _Depends:_ F4
- _Upstream:_ `packages/agent/src/agent.ts`  →  _pi-zig:_ `src/pi/agent.zig`
- **Context:** pi-zig can swap only system_prompt/provider/model/api_key. Upstream's hook can replace context/messages/tools/thinkingLevel.
- **DoD:** Hook signature extended; unit tests cover each replacement field.
- **Requirements:** Backwards-compat default

**0069. [F13] Tool hook fields: signal / args(validated) / context / details**
- _Complexity:_ Medium  ·  _Priority:_ 65  ·  _Depends:_ —
- _Upstream:_ `packages/agent/src/agent.ts`  →  _pi-zig:_ `src/pi/agent.zig + src/pi/extension_runner.zig`
- **Context:** Before/after tool hooks miss the upstream-shaped fields (validated args, cancellation signal, ambient context, run details).
- **DoD:** Hook signature extended; each field test-asserted; extensions can read all four.
- **Requirements:** ABI-stable

**0070. [F14] agentLoopContinue + listener-signal propagation**
- _Complexity:_ Medium  ·  _Priority:_ 45  ·  _Depends:_ F13
- _Upstream:_ `packages/agent/src/agent.ts`  →  _pi-zig:_ `src/pi/agent.zig`
- **Context:** Upstream's agentLoopContinue lets a hook abort or chain; signal propagates to listeners.
- **DoD:** Function + signal wired; unit test triggers continue/abort from a hook.
- **Requirements:** Signal-safe

**0071. [F15] File-ops tracking (readFiles / modifiedFiles summary blocks)**
- _Complexity:_ Medium  ·  _Priority:_ 55  ·  _Depends:_ —
- _Upstream:_ `packages/agent/src/tool-ops.ts`  →  _pi-zig:_ `src/pi/tools.zig + src/pi/agent.zig`
- **Context:** Tool runs that touch files surface readFiles/modifiedFiles in turn summaries upstream; absent in pi-zig.
- **DoD:** tools.zig records file ops; agent.zig surfaces them in turn summary; smoke shows the lists.
- **Requirements:** No false positives

**0072. [F16] BUG: bash full-output path collides on concurrent runs**
- _Complexity:_ Low  ·  _Priority:_ 95  ·  _Depends:_ F5
- _Upstream:_ `packages/agent/src/exec-env.ts (createTempFile)`  →  _pi-zig:_ `src/pi/tools.zig`
- **Context:** tools.zig writes shell full-output to fixed zig-out/pi-zig-bash-full-output.log. Two concurrent bash tools clobber each other.
- **DoD:** Per-run temp file via ExecutionEnv.createTempFile; concurrent-run test passes.
- **Requirements:** Cleanup on success and failure

**0073. [F17] getEntriesToFork "at" mode**
- _Complexity:_ Low  ·  _Priority:_ 40  ·  _Depends:_ —
- _Upstream:_ `packages/agent/src/session-fork.ts`  →  _pi-zig:_ `src/pi/session.zig`
- **Context:** Upstream supports forking AT a specific entry; pi-zig's fork is "from leaf" only.
- **DoD:** API supports both modes; smoke proves each.
- **Requirements:** Round-trip stable

### G — G — AI providers

**0074. [G1] Codex Responses transport (entirely missing)**
- _Complexity:_ High  ·  _Priority:_ 95  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/providers/openai-codex-responses.ts`  →  _pi-zig:_ `src/pi/ai_client.zig`
- **Context:** Catalog lists openai-codex-responses models; dispatcher routes them through chat/completions — INCOMPATIBLE shape. No SSE, no responses_websockets=2026-02-06, no chatgpt-account-id header, no retry-after-ms, no plan-aware errors, no session connection cache, no previous_response_id delta-context.
- **DoD:** ai_client.zig dispatches openai-codex-responses to chatgpt.com/backend-api/codex/responses with SSE + all required headers + retry-after parsing + previous_response_id chaining; smoke proves end-to-end.
- **Requirements:** No secrets logged; Fake server smoke

**0075. [G2] detectCompat 14-field per-provider compat (20+ providers)**
- _Complexity:_ High  ·  _Priority:_ 90  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/providers/openai-completions.ts:detectCompat`  →  _pi-zig:_ `src/pi/ai_client.zig`
- **Context:** pi-zig sends one fixed shape with tool_choice:"auto". Upstream's detectCompat (line 1070, openai-completions.ts) has 14 fields covering 20+ providers (Cerebras, x.ai, Together, chutes.ai, DeepSeek, z.ai, Moonshot, Cloudflare Workers AI/AI Gateway, GitHub Copilot, OpenRouter, Vercel AI Gateway, Anthropic-via-OpenRouter).
- **DoD:** detectCompat ported with all 14 fields + 20+ providers; smoke tests per provider hit a fake server with the right shape.
- **Requirements:** Match upstream regex byte-for-byte

**0076. [G3] Interactive OAuth login (PKCE + callback + device-code)**
- _Complexity:_ High  ·  _Priority:_ 85  ·  _Depends:_ B2
- _Upstream:_ `packages/ai/src/utils/oauth/*`  →  _pi-zig:_ `src/pi/auth.zig + src/pi/auth_login.zig`
- **Context:** Refresh works for all 3 providers; login requires manual `auth set-oauth <…>`. No PKCE, no callback server, no device-code, no manual-paste race.
- **DoD:** `pi-zig auth login <provider>` runs the full PKCE/device-code flow; live cred opt-in; never prints secrets; fake-endpoint smoke.
- **Requirements:** No secrets logged; Cross-platform browser launch

**0077. [G4] Anthropic Messages depth: cache_control / thinking / OAuth tool-name remap / eager_input_streaming / redacted_thinking / x-session-affinity / dynamic max_tokens**
- _Complexity:_ High  ·  _Priority:_ 85  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/providers/anthropic.ts`  →  _pi-zig:_ `src/pi/ai_client.zig`
- **Context:** pi-zig's Anthropic transport is shallow: max_tokens hardcoded 4096; no cache_control ephemeral blocks; no thinking/output_config.effort; no OAuth tool-name remap (16 canonical names); no eager_input_streaming; no redacted_thinking round-trip; no aborted-thinking-signature downgrade; no x-session-affinity.
- **DoD:** Each feature wired with smoke + unit; OAuth tool-name remap table byte-exact.
- **Requirements:** No regression in fake-server smoke

**0078. [G5] Bedrock depth: cache points / reasoningContent.signature / additionalModelRequestFields / requestMetadata / GovCloud strip / exception-name map / ~/.aws/credentials profile / IMDS chain**
- _Complexity:_ High  ·  _Priority:_ 75  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/providers/amazon-bedrock.ts`  →  _pi-zig:_ `src/pi/ai_client.zig + src/pi/auth.zig`
- **Context:** SigV4 signer verified vs AWS get-vanilla; missing all the cache and reasoning features.
- **DoD:** Each feature ported with unit test; profile + IMDS chain end-to-end smoke.
- **Requirements:** No live AWS contact

**0079. [G6] Missing helpers: transform-messages.ts / cloudflare.ts / github-copilot-headers.ts / openai-prompt-cache.ts / simple-options.ts (reasoning plumbing)**
- _Complexity:_ Medium  ·  _Priority:_ 70  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/providers/*.ts shared helpers`  →  _pi-zig:_ `src/pi/ai_client.zig`
- **Context:** Several cross-provider helpers absent; their consumers degrade silently.
- **DoD:** Each helper ported with unit tests + consumed by providers that need it.
- **Requirements:** Match upstream functions byte-for-byte

**0080. [G7] Wire 15+ unwired OpenAI-compatible providers in endpointForProvider**
- _Complexity:_ Medium  ·  _Priority:_ 80  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/providers/*.ts`  →  _pi-zig:_ `src/pi/ai_client.zig`
- **Context:** Only 7 providers wired in endpointForProvider; 15+ in the catalog have no endpoint mapping → 404 on use.
- **DoD:** Each catalog provider has a mapped endpoint; smoke per provider against a fake server.
- **Requirements:** Per-provider auth header

### H — H — AI core

**0081. [H1] Usage tracking in ChatCompletionResult + calculateCost**
- _Complexity:_ High  ·  _Priority:_ 90  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/usage.ts + per-provider parsing`  →  _pi-zig:_ `src/pi/ai_client.zig + NEW src/pi/usage.zig`
- **Context:** No Usage struct anywhere; no per-token cost calculation. Compaction triggers can't use real tokens; footer can't show cost.
- **DoD:** ChatCompletionResult carries Usage {prompt_tokens, completion_tokens, cache_read, cache_write}; calculateCost computes from model costs; unit tests cover each provider's usage parse.
- **Requirements:** Per-provider usage parse exact

**0082. [H2] api-registry: provider registration + custom-provider extension API landing**
- _Complexity:_ High  ·  _Priority:_ 85  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/api-registry.ts`  →  _pi-zig:_ `NEW src/pi/api_registry.zig`
- **Context:** Provider dispatch is a hardcoded switch in streamChatTurnData. Extension API pi.registerProvider has nowhere to land.
- **DoD:** src/pi/api_registry.zig with a registry; built-in providers register at startup; extensions can dynamically register; smoke proves a custom-provider extension dispatches.
- **Requirements:** No global state hazards

**0083. [H3] AssistantMessageEventStream + 13-arm typed event union**
- _Complexity:_ High  ·  _Priority:_ 70  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/assistant-event-stream.ts`  →  _pi-zig:_ `NEW src/pi/assistant_event_stream.zig`
- **Context:** pi-zig uses scattered callbacks. Upstream has a typed 13-arm event union streamed during a turn.
- **DoD:** src/pi/assistant_event_stream.zig with the union; agent.zig emits via it; CLI/RPC consumers re-emit.
- **Requirements:** Backwards-compat with callbacks

**0084. [H4] utils/json-parse.ts: repair + streaming-JSON tolerance**
- _Complexity:_ Medium  ·  _Priority:_ 65  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/utils/json-parse.ts`  →  _pi-zig:_ `NEW src/pi/json_parse.zig`
- **Context:** Provider responses occasionally have malformed JSON or interleaved control sequences. Upstream repairs; pi-zig errors out.
- **DoD:** src/pi/json_parse.zig with repair + partial-token tolerance; unit tests cover common malformations.
- **Requirements:** No false repairs of structurally bad input

**0085. [H5] utils/node-http-proxy.ts: HTTP_PROXY / HTTPS_PROXY / no_proxy**
- _Complexity:_ Medium  ·  _Priority:_ 75  ·  _Depends:_ B4
- _Upstream:_ `packages/ai/src/utils/node-http-proxy.ts`  →  _pi-zig:_ `NEW src/pi/http_proxy.zig`
- **Context:** pi-zig ignores all proxy env vars.
- **DoD:** src/pi/http_proxy.zig parses env, wires std.http.Client proxy; smoke verifies routing through a fake proxy.
- **Requirements:** no_proxy honored

**0086. [H6] utils/sanitize-unicode.ts, diagnostics.ts, validation.ts, typebox-helpers.ts, hash.ts**
- _Complexity:_ Medium  ·  _Priority:_ 55  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/utils/*.ts`  →  _pi-zig:_ `src/pi/ai_client.zig + new utility modules`
- **Context:** Five shared utilities absent. Some are nice-to-have (diagnostics, validation); sanitize-unicode is load-bearing (prevents homograph attacks in CLI output).
- **DoD:** Each ported with unit tests.
- **Requirements:** Hash impl uses std.crypto

**0087. [H7] Image-models catalog (not just inline openrouter)**
- _Complexity:_ Medium  ·  _Priority:_ 55  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/models/images.ts`  →  _pi-zig:_ `src/pi/ai_client.zig + src/pi/models.zig`
- **Context:** Only one image provider is inline-wired; upstream has a catalog.
- **DoD:** Image-models catalog generator; multiple image providers; smoke per provider.
- **Requirements:** Provider parity

**0088. [H8] Compat overrides on ModelEntry (OpenAICompletionsCompat / OpenAIResponsesCompat / AnthropicMessagesCompat)**
- _Complexity:_ Medium  ·  _Priority:_ 60  ·  _Depends:_ —
- _Upstream:_ `packages/ai/src/models/*.ts`  →  _pi-zig:_ `src/pi/models.zig + src/pi/ai_client.zig`
- **Context:** ModelEntry has no per-model compat overrides upstream; pi-zig has none either, but consumers depend on it for openRouterRouting/vercelGatewayRouting.
- **DoD:** ModelEntry gains an optional compat struct; per-provider serializers read it; smoke per override.
- **Requirements:** Backwards-compat default

### I — I — Tools / Extensions / Resources

**0089. [I1] pi.* API: 14 missing methods**
- _Complexity:_ High  ·  _Priority:_ 90  ·  _Depends:_ A6, H2
- _Upstream:_ `packages/coding-agent/src/core/extensions/*`  →  _pi-zig:_ `src/pi/extension_runner.zig`
- **Context:** Extension API surface is 8/22 wired. Missing: registerShortcut, registerMessageRenderer, registerProvider, unregisterProvider, setSessionName, getSessionName, setLabel, exec, getActiveTools, getAllTools, setActiveTools, getCommands, setModel, getThinkingLevel, setThinkingLevel.
- **DoD:** Each method wired in extension_runner.zig; pi.* shim exposes them; per-method smoke runs an extension calling the method and asserts the effect.
- **Requirements:** Type-safe; Async-safe

**0090. [I2] Dispatch 17 currently-unfired lifecycle events**
- _Complexity:_ High  ·  _Priority:_ 90  ·  _Depends:_ A6
- _Upstream:_ `packages/coding-agent/src/core/extensions/*`  →  _pi-zig:_ `src/pi/rpc.zig + src/pi/agent.zig`
- **Context:** Events context / before_agent_start / model_select / thinking_level_select / input / session_before_* / session_compact / session_shutdown / tool_execution_start/update/end / message_update / resources_discover are NEVER dispatched in production code.
- **DoD:** Each event has a dispatch site; per-event smoke asserts the extension handler observes it.
- **Requirements:** Match upstream emission order

**0091. [I3] Honor return values of 9 fire-and-forget lifecycle events**
- _Complexity:_ High  ·  _Priority:_ 90  ·  _Depends:_ A6
- _Upstream:_ `packages/coding-agent/src/core/extensions/*`  →  _pi-zig:_ `src/pi/rpc.zig + src/pi/extension_runner.zig`
- **Context:** session_start / before_provider_request / after_provider_response / agent_start/end / turn_start/end / message_start/end / user_bash fire but DISCARD return values. RuntimeLifecycleEmitContext.emit explicitly drops them (rpc.zig:3834-3842).
- **DoD:** Each event's return value is applied per upstream semantics (transform-chain or short-circuit); per-event smoke proves the effect.
- **Requirements:** Backwards-compat with extensions that return undefined

**0092. [I4] Provider display names: 28-entry map**
- _Complexity:_ Low  ·  _Priority:_ 45  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/provider-display-names.ts`  →  _pi-zig:_ `NEW src/pi/provider_display.zig`
- **Context:** pi-zig surfaces raw provider ids (google-vertex) instead of display names (Google Vertex AI).
- **DoD:** src/pi/provider_display.zig with the 28-entry map; commands/themes/RPC use it; smoke asserts UI shows display names.
- **Requirements:** Map matches upstream byte-for-byte

**0093. [I5] Models.json: ~/.pi/models.json loading + schema validation + applyModelOverride + mergeCompat + per-model headers**
- _Complexity:_ High  ·  _Priority:_ 65  ·  _Depends:_ H8
- _Upstream:_ `packages/coding-agent/src/core/model-registry.ts + model-resolver.ts`  →  _pi-zig:_ `NEW src/pi/custom_models.zig`
- **Context:** Custom model registry: users put models in ~/.pi/models.json and pi-zig should load + validate + merge. None of this exists.
- **DoD:** src/pi/custom_models.zig loads + validates + merges; openRouterRouting / vercelGatewayRouting helpers; per-model headers passed to ai_client; smoke uses a temp models.json.
- **Requirements:** Schema validation strict

**0094. [I6] HTML export: marked.min.js + highlight.min.js vendored + ansi-to-html + ToolHtmlRenderer + 5-mode sidebar filter + branch-tree sidebar**
- _Complexity:_ High  ·  _Priority:_ 60  ·  _Depends:_ —
- _Upstream:_ `packages/coding-agent/src/core/export-html/*`  →  _pi-zig:_ `src/pi/html_export.zig`
- **Context:** Server-side rendering works; the interactive SPA chrome is absent.
- **DoD:** Vendor marked + highlight at build (in repo); ansi-to-html.zig converter; ToolHtmlRenderer interface; 5-mode filter UI; branch-tree sidebar with active-path markers; smoke loads the HTML in headless Chrome and asserts each element.
- **Requirements:** Self-contained (no CDN)

**0095. [I7] Built-in tool *Operations seams + withFileMutationQueue + BashSpawnHook + image auto-resize + macOS read-path fallbacks + edit-tool diff/patch/firstChangedLine + prepareArguments legacy migration**
- _Complexity:_ High  ·  _Priority:_ 70  ·  _Depends:_ F5
- _Upstream:_ `packages/coding-agent/src/core/tools/*`  →  _pi-zig:_ `src/pi/tools.zig`
- **Context:** Tool execution is at parity; the customization seams + macOS fallbacks + ANSI-to-HTML + image worker are absent.
- **DoD:** Each seam implemented; macOS read-path variant fallback table ported; edit-tool result carries details.diff + patch + firstChangedLine; smoke proves each seam.
- **Requirements:** Backwards-compat

### J — J — TUI primitives

**0096. [J1] keys.ts: Kitty + modifyOtherKeys + non-Latin-layout + Apple-Terminal + Windows-Terminal CSI-u (~900 LoC)**
- _Complexity:_ High  ·  _Priority:_ 80  ·  _Depends:_ —
- _Upstream:_ `packages/tui/src/keys.ts`  →  _pi-zig:_ `src/pi/tui_keys.zig`
- **Context:** pi-zig's tui_keys.zig handles legacy non-Kitty sequences; misses Kitty key protocol, modifyOtherKeys, non-Latin keyboard layouts, Apple Terminal CSI-u quirks, Windows Terminal CSI-u.
- **DoD:** tui_keys.zig fully ported; per-protocol unit tests; pty harness covers a Kitty terminal handshake.
- **Requirements:** No misclassification of legacy sequences

**0097. [J2] utils.ts: visible-width / ANSI-aware wrap / grapheme segmentation (~1100 LoC)**
- _Complexity:_ High  ·  _Priority:_ 90  ·  _Depends:_ —
- _Upstream:_ `packages/tui/src/utils.ts`  →  _pi-zig:_ `NEW src/pi/tui_text.zig`
- **Context:** pi-zig is byte-based throughout. Emoji, accented Latin, combining marks all break.
- **DoD:** src/pi/tui_text.zig with width / wrap / grapheme APIs based on Unicode UCD tables; unit tests for emoji + combining marks + accented Latin + ZWJ.
- **Requirements:** Width 0 for combining marks; Width 2 for wide chars

**0098. [J3] terminal-image.ts + components/image.ts (~580 LoC)**
- _Complexity:_ High  ·  _Priority:_ 65  ·  _Depends:_ —
- _Upstream:_ `packages/tui/src/terminal-image.ts + components/image.ts`  →  _pi-zig:_ `NEW src/pi/tui_image.zig`
- **Context:** Zero image support. No kitty graphics, no iTerm2 inline images, no SIXEL.
- **DoD:** tui_image.zig with kitty + iTerm2 image protocols; smoke renders a tiny PNG and detects the escape.
- **Requirements:** Detect protocol support

**0099. [J4] Components: input / settings-list / box / loader / cancellable-loader / text / spacer / truncated-text**
- _Complexity:_ High  ·  _Priority:_ 75  ·  _Depends:_ J2
- _Upstream:_ `packages/tui/src/components/{input,settings-list,box,loader,cancellable-loader,text,spacer,truncated-text}.ts`  →  _pi-zig:_ `NEW src/pi/tui_components/*.zig`
- **Context:** 8 small but load-bearing layout components entirely missing.
- **DoD:** Each component has a Zig module + unit tests; used by tui_messages and tui_footer.
- **Requirements:** Style-token aware

**0100. [J5] tui.ts: overlay compositor + IME CURSOR_MARKER + viewport + synchronized output + Kitty image lifecycle**
- _Complexity:_ High  ·  _Priority:_ 80  ·  _Depends:_ —
- _Upstream:_ `packages/tui/src/tui.ts`  →  _pi-zig:_ `src/pi/tui.zig + src/pi/tui_render.zig`
- **Context:** pi-zig's differential renderer doesn't composite overlays, has no IME cursor marker, no viewport math, no \x1b[?2026h/l synchronized output, no Kitty image lifecycle.
- **DoD:** tui.zig / tui_render.zig extended; each feature has a per-feature snapshot test.
- **Requirements:** No flicker

**0101. [J6] terminal.ts: bracketed paste / Kitty probe / drain / setTitle / setProgress / SIGWINCH / Windows console mode**
- _Complexity:_ Medium  ·  _Priority:_ 70  ·  _Depends:_ —
- _Upstream:_ `packages/tui/src/terminal.ts`  →  _pi-zig:_ `src/pi/tui_terminal.zig`
- **Context:** tui_terminal.zig has the basics; missing 7 specific behaviors.
- **DoD:** Each ported with smoke (where observable in stdout) or unit test.
- **Requirements:** Cross-platform

**0102. [J7] autocomplete.ts: @-path completion + fd-based fuzzy file walk**
- _Complexity:_ High  ·  _Priority:_ 60  ·  _Depends:_ —
- _Upstream:_ `packages/tui/src/autocomplete.ts`  →  _pi-zig:_ `NEW src/pi/tui_autocomplete.zig`
- **Context:** No autocomplete in the composer. Upstream has @<partial-path> file fuzzy.
- **DoD:** tui_autocomplete.zig with fd-based walk + fuzzy match; integrated into editor; unit + smoke.
- **Requirements:** Ignore .gitignore

**0103. [J8] stdin-buffer.ts: OSC/APC/DCS accumulator + bracketed-paste + 10ms partial-sequence flush + WezTerm escape fixup**
- _Complexity:_ High  ·  _Priority:_ 75  ·  _Depends:_ J1
- _Upstream:_ `packages/tui/src/stdin-buffer.ts`  →  _pi-zig:_ `NEW src/pi/tui_stdin_buffer.zig`
- **Context:** pi-zig reads stdin raw and parses each chunk synchronously. Long OSC/APC/DCS sequences can be split across reads and get mis-parsed.
- **DoD:** tui_stdin_buffer.zig accumulates partial sequences with a 10ms flush; bracketed-paste assembly; smoke pipes a split OSC sequence and asserts correct assembly.
- **Requirements:** No loss on partial reads

**0104. [J9] Editor: paste-marker system + visual-line nav + sticky preferred column + grapheme-aware cursor + jumpToChar + pageScroll + multi-level undo + autocomplete UI + bordered render**
- _Complexity:_ High  ·  _Priority:_ 75  ·  _Depends:_ J2, J7
- _Upstream:_ `packages/tui/src/components/editor.ts`  →  _pi-zig:_ `src/pi/tui_editor.zig`
- **Context:** tui_editor.zig has byte-based logic. Missing 9 specific editor features.
- **DoD:** Each feature added with unit tests + at least one pty smoke step.
- **Requirements:** Undo depth ≥ 100

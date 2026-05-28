# Gap Report 01: Agent Session Slice (upstream/pi → pi-zig)

Audit scope: every public exported function/class/type/event in the assigned
upstream files. All upstream line references are against the snapshot in
`upstream/pi/packages/coding-agent/src/core/`. The pi-zig counterparts live in
`src/pi/` (primarily `agent.zig`, `rpc.zig`, `cli_runtime.zig`, `tools.zig`,
`session.zig`, `extension_runner.zig`).

Method:
- I read every line of every assigned upstream file (10 files, 4824 LOC).
- I grep-traced each public surface into pi-zig sources to confirm presence,
  partial coverage, or absence.
- Where pi-zig has comments claiming a flow exists I still confirmed the symbol
  is wired through to a runtime path (RPC dispatch, agent loop, or external
  caller); "wired" means "this code is reachable from a user-facing entry point",
  not just "the constant/function compiles".

---

## 1. Surface inventory (upstream)

### 1.1 `event-bus.ts` (33 LOC)
- `interface EventBus { emit, on }` — event-bus.ts:3
- `interface EventBusController extends EventBus { clear }` — event-bus.ts:8
- `function createEventBus(): EventBusController` — event-bus.ts:12

### 1.2 `telemetry.ts` (13 LOC)
- `function isInstallTelemetryEnabled(settingsManager, telemetryEnv?)` — telemetry.ts:8
- (private) `isTruthyEnvFlag` — telemetry.ts:3

### 1.3 `timings.ts` (31 LOC)
- `function resetTimings(): void` — timings.ts:10
- `function time(label: string): void` — timings.ts:16
- `function printTimings(): void` — timings.ts:23
- (env gate) `PI_TIMING` — timings.ts:6

### 1.4 `exec.ts` (107 LOC)
- `interface ExecOptions { signal?, timeout?, cwd? }` — exec.ts:11
- `interface ExecResult { stdout, stderr, code, killed }` — exec.ts:23
- `function execCommand(command, args, cwd, options?)` — exec.ts:34

### 1.5 `bash-executor.ts` (156 LOC)
- `interface BashExecutorOptions { onChunk?, signal? }` — bash-executor.ts:22
- `interface BashResult { output, exitCode, cancelled, truncated, fullOutputPath? }` — bash-executor.ts:29
- `function executeBashWithOperations(command, cwd, operations, options?)` — bash-executor.ts:50
- Side effects: ANSI stripping, binary-output sanitization, rolling-buffer truncation, tmpfile persistence — bash-executor.ts:78-104

### 1.6 `footer-data-provider.ts` (354 LOC)
- `class FooterDataProvider` — footer-data-provider.ts:87
  - `constructor(cwd)` — :106
  - `getGitBranch(): string | null` — :113
  - `getExtensionStatuses(): ReadonlyMap<string,string>` — :121
  - `onBranchChange(cb): () => void` — :126
  - `setExtensionStatus(key, text?)` — :132
  - `clearExtensionStatuses()` — :141
  - `getAvailableProviderCount()` — :146
  - `setAvailableProviderCount(count)` — :151
  - `setCwd(cwd)` — :155
  - `dispose()` — :173
  - private: `scheduleRefresh`, `refreshGitBranchAsync`, `resolveGitBranchSync/Async`, `setupGitWatcher`, `clearGitWatchers`, reftable watcher path, `handleGitWatcherError`, `scheduleGitWatcherRetry`
- `type ReadonlyFooterDataProvider` — footer-data-provider.ts:351
- (free fn) `findGitPaths(cwd)` — :16
- (free fn) `resolveBranchWithGitSync/Async` — :51/:62
- Git-worktree handling (`.git` file with `gitdir:`), reftable layout, atomic-rename watcher behavior

### 1.7 `sdk.ts` (422 LOC)
- `interface CreateAgentSessionOptions` — sdk.ts:34
  - fields: cwd, agentDir, authStorage, modelRegistry, model, thinkingLevel,
    scopedModels, noTools ("all"|"builtin"), tools, customTools, resourceLoader,
    sessionManager, settingsManager, sessionStartEvent
- `interface CreateAgentSessionResult { session, extensionsResult, modelFallbackMessage? }` — sdk.ts:84
- `async function createAgentSession(options)` — sdk.ts:202
- Re-exports from agent-session-runtime + extensions + prompt-templates + skills + tools
- (private) `getAttributionHeaders(model, settingsManager, sessionId?)` — sdk.ts:129
  - Special handling: opencode/opencode-go, openrouter, cloudflare-workers-ai/cloudflare-ai-gateway
- Wires Agent core with: convertToLlmWithBlockImages, streamFn (with apiKey/headers/timeouts/maxRetries), onPayload (before_provider_request), onResponse (after_provider_response), transformContext (context event), steeringMode, followUpMode, transport, thinkingBudgets, maxRetryDelayMs
- Model fallback / restore path; thinking-level restore + clamp; session resume injects history
- Persists initial modelChange + thinkingLevelChange entries on fresh session

### 1.8 `agent-session-services.ts` (199 LOC)
- `interface AgentSessionRuntimeDiagnostic { type, message }` — services.ts:21
- `interface CreateAgentSessionServicesOptions` — services.ts:33
  (cwd, agentDir, authStorage, settingsManager, modelRegistry, extensionFlagValues, resourceLoaderOptions)
- `interface CreateAgentSessionFromServicesOptions` — services.ts:49
- `interface AgentSessionServices` — services.ts:67
- `async function createAgentSessionServices(options)` — services.ts:130
- `async function createAgentSessionFromServices(options)` — services.ts:180
- (private) `applyExtensionFlagValues` — services.ts:77 (validates --flag values, type checks)
- Side effects: registers pending provider registrations from extensions, returns diagnostics

### 1.9 `agent-session-runtime.ts` (420 LOC)
- `interface CreateAgentSessionRuntimeResult extends CreateAgentSessionResult { services, diagnostics }` — runtime.ts:18
- `type CreateAgentSessionRuntimeFactory` — runtime.ts:30
- `class SessionImportFileNotFoundError extends Error` — runtime.ts:40
- `class AgentSessionRuntime` — runtime.ts:68
  - getters: `services`, `session`, `cwd`, `diagnostics`, `modelFallbackMessage`
  - `setRebindSession(cb?)` — :111
  - `setBeforeSessionInvalidate(cb?)` — :123
  - `switchSession(sessionPath, options?)` — :187
  - `newSession(options?)` — :212
  - `fork(entryId, options?)` — :246
  - `importFromJsonl(inputPath, cwdOverride?)` — :340
  - `dispose()` — :377
  - private: `emitBeforeSwitch`, `emitBeforeFork`, `teardownCurrent`, `apply`, `finishSessionReplacement`
  - Emits `session_before_switch`, `session_before_fork`, `session_shutdown`, `session_start`
- `async function createAgentSessionRuntime(factory, options)` — runtime.ts:393
- Re-exports services types/functions — runtime.ts:413-420

### 1.10 `agent-session.ts` (3089 LOC)
- `interface ParsedSkillBlock` — agent-session.ts:100
- `function parseSkillBlock(text)` — agent-session.ts:111
- `type AgentSessionEvent` — agent-session.ts:122
  - variants: `agent_end{messages, willRetry}`, `queue_update{steering, followUp}`, `compaction_start{reason}`, `session_info_changed{name}`, `thinking_level_changed{level}`, `compaction_end{reason, result, aborted, willRetry, errorMessage?}`, `auto_retry_start{attempt,maxAttempts,delayMs,errorMessage}`, `auto_retry_end{success,attempt,finalError?}`, plus all non-`agent_end` AgentEvent variants
- `type AgentSessionEventListener` — agent-session.ts:150
- `interface AgentSessionConfig` — agent-session.ts:156
- `interface ExtensionBindings` — agent-session.ts:186
- `interface PromptOptions` — agent-session.ts:195
  - `expandPromptTemplates`, `images`, `streamingBehavior`, `source`, `preflightResult`
- `interface ModelCycleResult` — agent-session.ts:209
- `interface SessionStats` — agent-session.ts:217
- `class AgentSession` — agent-session.ts:252
  - Construction: `constructor(config)` — :319
  - Getters: `modelRegistry`, `state`, `model`, `thinkingLevel`, `isStreaming`,
    `systemPrompt`, `retryAttempt`, `isCompacting`, `messages`, `steeringMode`,
    `followUpMode`, `sessionFile`, `sessionId`, `sessionName`, `scopedModels`,
    `promptTemplates`, `resourceLoader`, `pendingMessageCount`,
    `isBashRunning`, `hasPendingBashMessages`, `autoCompactionEnabled`,
    `isRetrying`, `autoRetryEnabled`, `extensionRunner`
  - Tool registry: `getActiveToolNames`, `getAllTools`, `getToolDefinition`,
    `setActiveToolsByName`
  - Subscriptions: `subscribe(listener) => unsubscribe`
  - Lifecycle: `dispose()`, `reload()`, `bindExtensions(bindings)`,
    `createReplacedSessionContext()`, `hasExtensionHandlers(eventType)`
  - Prompting: `prompt(text, options?)`, `steer(text, images?)`, `followUp(text, images?)`,
    `sendCustomMessage(message, options?)`, `sendUserMessage(content, options?)`,
    `clearQueue()`, `getSteeringMessages()`, `getFollowUpMessages()`,
    `abort()`
  - Model: `setModel(model)`, `cycleModel(direction)`
  - Thinking: `setThinkingLevel(level)`, `cycleThinkingLevel()`,
    `getAvailableThinkingLevels()`, `supportsThinking()`
  - Queue modes: `setSteeringMode(mode)`, `setFollowUpMode(mode)`,
    `setScopedModels(scoped)`
  - Compaction: `compact(customInstructions?)`, `abortCompaction()`,
    `abortBranchSummary()`, `setAutoCompactionEnabled(enabled)`,
    `setAutoRetryEnabled(enabled)`, `abortRetry()`
  - Bash: `executeBash(command, onChunk?, options?)`, `recordBashResult(...)`,
    `abortBash()`
  - Session: `setSessionName(name)`, `navigateTree(targetId, options?)`,
    `getUserMessagesForForking()`, `getSessionStats()`, `getContextUsage()`,
    `exportToHtml(outputPath?)`, `exportToJsonl(outputPath?)`,
    `getLastAssistantText()`
- Built-in private machinery (extension event fan-out, retry classifier,
  overflow recovery, queue eject, tool wrappers, system prompt rebuild,
  resources_discover handler, model registry refresh, in-place message
  replacement, etc.)
- Emits these AgentSessionEvents internally (visible to subscribers): every
  upstream-Agent event, plus the seven extra variants listed above

---

## 2. Mapped to pi-zig

| Upstream surface | pi-zig location | Status |
|---|---|---|
| `event-bus.ts` createEventBus / EventBus | — | (MISSING). pi-zig has no in-process pub/sub; events stream directly out as JSON-RPC notifications from `rpc.zig`. |
| `telemetry.ts` isInstallTelemetryEnabled / `PI_TELEMETRY` | — | (MISSING). No `PI_TELEMETRY` plumbing anywhere; `settings.zig:491` writes `blockImages` but no `enableInstallTelemetry`. |
| `timings.ts` resetTimings/time/printTimings / `PI_TIMING` | — | (MISSING). No `PI_TIMING` env gate, no timing instrumentation. |
| `exec.ts` ExecOptions / ExecResult / execCommand | (no direct counterpart) | (MISSING as a public utility). `tools.zig` has `runShell*` family (`runShellCaptureWithUpdates` at tools.zig:774) which is shell-based (`sh -c`), not the upstream `spawn(command, args, {shell:false})` style. There is no general extension-facing `execCommand` API. |
| `bash-executor.ts` BashResult / executeBashWithOperations / `BashOperations` indirection | `tools.zig` `runShellCaptureWithUpdates` (tools.zig:774); `rpc.zig` `executeBash` (rpc.zig:1564), `captureBash` (rpc.zig:1536), `recordBashResult` (rpc.zig:1559), `ActiveBashJob` (rpc.zig:99) | PARTIAL. Same surface shape (output, exit_code, cancelled, truncated, full_output_path, plus a richer `truncation` block). NO BashOperations indirection - the upstream interface allowing remote/SSH/container backends is absent. NO ANSI stripping (`stripAnsi`) of streamed output. NO binary-output sanitization (`sanitizeBinaryOutput`). Streaming `onChunk` callback exists via `ShellUpdateCallback` in tools.zig:39 but is fired on a debounce schedule, not per-chunk. |
| `footer-data-provider.ts` FooterDataProvider class | `tui.zig:264-520` (git_branch_buf, resolveGitBranch) | PARTIAL. pi-zig resolves `git_branch` once lazily via shelling out (tui.zig:446 `if (!self.git_branch_resolved) self.resolveGitBranch()`). NO live watcher, NO worktree (`.git` file) handling, NO reftable support, NO `setExtensionStatus`/`getExtensionStatuses` (extension status text in the footer), NO `getAvailableProviderCount`, NO `onBranchChange` callback list, NO `setCwd` rewatch, NO `dispose`. The footer's branch is effectively static once resolved; it will not update mid-session on `git checkout`. |
| `footer-data-provider.ts` findGitPaths / resolveBranchWithGit{Sync,Async} | `tui.zig:resolveGitBranch` shells out | PARTIAL. pi-zig does not walk up to find the repo root (relies on the spawned `git` doing it); does not handle worktrees that store HEAD outside `.git`; does not implement the read-HEAD-directly fast path. |
| `sdk.ts` createAgentSession / CreateAgentSessionOptions / CreateAgentSessionResult | `rpc.zig` Runtime struct (rpc.zig:573) + per-command setup in `cli_runtime.zig` runTopLevel (cli_runtime.zig:118) | PARTIAL. There is no single `createAgentSession` factory. `Runtime` is built directly by the RPC entry point. Coverage breakdown: `cwd` (yes via cli args), `agentDir` (yes via config.zig), `authStorage` (yes via auth.zig), `modelRegistry` (yes via models.zig), `model`/`thinkingLevel` (yes), `scopedModels` (MISSING - no Ctrl+P scoped cycling list), `noTools` `"all"`/`"builtin"` (PARTIAL - `--no-tools` exists but `"builtin"` mode unclear), `tools` allowlist (PARTIAL), `customTools` SDK arg (MISSING - extensions register tools but there is no public SDK), `resourceLoader` (MISSING as a swappable object - resources are loaded directly), `sessionManager` (MISSING - sessions are a `PersistentStore`, not pluggable), `sessionStartEvent` (PARTIAL — rpc.zig:1955-2015 emits `session_start` with reason but no caller can inject metadata). |
| `sdk.ts` getAttributionHeaders | — | (MISSING). pi-zig sends NO attribution headers. The `x-opencode-session`/`x-opencode-client`, `HTTP-Referer`/`X-OpenRouter-Title`/`X-OpenRouter-Categories`, and Cloudflare `User-Agent` overrides are all absent. |
| `sdk.ts` convertToLlm + blockImages dynamic filter | `rpc.zig:4860, 4882` count/skip images; `settings.zig:491` reads blockImages | PARTIAL. Image counting exists; the dynamic per-turn replacement with "Image reading is disabled." text and consecutive-dedupe is not implemented. |
| `sdk.ts` onPayload / onResponse hooks for extensions | `agent.zig:386, 406, 414` emitLifecycle("turn_start"/"before_provider_request"/"after_provider_response") | PARTIAL. The fields_json passed to before_provider_request is `{"provider":...,"model":...}`; upstream `onPayload` actually returns a possibly-modified payload (extension can rewrite the request body). pi-zig comment at agent.zig:23 explicitly acknowledges this: "notify-style here ... not owned by this seam ... before_provider_request surfaces the provider/model for observation rather than rewriting the raw HTTP body." So mutation is impossible. |
| `sdk.ts` Agent state restore + modelFallbackMessage | `rpc.zig:1268-1276` loads thinking_level_change / compaction entries from JSONL | PARTIAL. Session messages are restored; no `modelFallbackMessage` returned to caller; no "Could not restore model X" UX path. |
| `agent-session-services.ts` AgentSessionRuntimeDiagnostic | — | (MISSING). pi-zig has no diagnostics-list return shape - errors are returned as Zig `error.X` from initialization. |
| `agent-session-services.ts` createAgentSessionServices / createAgentSessionFromServices / AgentSessionServices | — | (MISSING). The two-stage "build services first, then bind a session" split does not exist; pi-zig creates everything inline at startup. This precludes mid-process cwd switching. |
| `agent-session-services.ts` applyExtensionFlagValues (extension flag value validation) | `extension_runner.zig:460 validateFlags` (and CommandDefinition machinery) | PARTIAL. pi-zig validates flag types but the "unknown options" error message + per-call extension flag injection at services-create time is not invoked from a runtime factory; it happens at extension-load. |
| `agent-session-runtime.ts` AgentSessionRuntime class with switchSession/newSession/fork/importFromJsonl | `rpc.zig switchSession` (:768), `new_session` command (:3203), `forkSession` (:775), no JSONL import | PARTIAL. switch_session, new_session, fork are present and call into `PersistentStore`. **`importFromJsonl` (and `SessionImportFileNotFoundError`) is entirely MISSING** - the `/import` flow has no RPC counterpart. setRebindSession / setBeforeSessionInvalidate callbacks (host hooks for UI teardown) are MISSING. The `withSession(replacedSessionContext)` callback shape is MISSING. |
| `agent-session-runtime.ts` `session_before_switch` / `session_before_fork` cancellation events | `upstream.zig:146-147` (string list); `extension_runner.zig:1626-1628, 1680` (JS-side runtime acknowledges these events) | PARTIAL. The event NAMES are listed and the embedded JS runtime claims to honor `{cancel:true}`, but I could not find code in `rpc.zig` that actually fires `session_before_switch` or `session_before_fork` before a switch/fork is executed. Search for `dispatchLifecycle.*session_before_switch` returns no hits in `rpc.zig`. The events are advertised but not wired. |
| `agent-session.ts` parseSkillBlock(text) | — | (MISSING). No `<skill name="..." location="...">` parser in pi-zig source. The reverse direction exists (commands.zig:1664 emits a skill block when /skill:name is invoked) but parsing back from an arbitrary message is unimplemented. |
| `agent-session.ts` AgentSessionEvent variant `queue_update` | — | (MISSING). pi-zig advertises queue counts on demand via `get_state` (rpc.zig:2647-2651) but does NOT push a `queue_update` event when the queues change. UI must poll. |
| `agent-session.ts` AgentSessionEvent `compaction_start` / `compaction_end` | — | (MISSING). grep `compaction_start`/`compaction_end` against rpc.zig returns no hits. Compaction runs synchronously inside the prompt path; no event is emitted to RPC subscribers. |
| `agent-session.ts` AgentSessionEvent `session_info_changed` | — | (MISSING). `set_session_name` mutates state (rpc.zig:3303-3311) but does not push an event. |
| `agent-session.ts` AgentSessionEvent `thinking_level_changed` | — | (MISSING). `set_thinking_level` / `cycle_thinking_level` write the value out in the response body but do not push a separate notify-style event. |
| `agent-session.ts` AgentSessionEvent `auto_retry_start` / `auto_retry_end` | `rpc.zig:4548, 4583` writeRpcAutoRetryStart/EndEvent | OK. Auto-retry start/end events are emitted with attempt/maxAttempts/delayMs/error/success/finalError. |
| `agent-session.ts` AgentSessionEvent `agent_end {willRetry}` | `rpc.zig:4532 writeRpcAgentEndEvent` | OK. `willRetry` boolean is carried through. |
| `agent-session.ts` AgentSession.subscribe(listener) | — | (MISSING). There is no JS-style observer pattern; RPC clients receive notifications via the JSON-RPC stream, but in-process subscribers are absent. |
| `agent-session.ts` AgentSession.prompt() with template expansion, skill expansion, extension command dispatch, image filtering | `rpc.zig` prompt command (rpc.zig:3087) + commands.zig:245 expandPromptTemplate | PARTIAL. Template files expand via `/template-name`. Skill expansion lives in commands.zig but is invoked only for `/skill:name` slash inputs, not transparently inside `prompt()`. Extension command dispatch via slash commands is partly wired (extension_runner.zig CommandDelivery). Image filtering when `blockImages` is set is NOT performed dynamically per turn. |
| `agent-session.ts` _tryExecuteExtensionCommand | extension_runner.zig:616 runRegisteredCommand | PARTIAL. Extension commands route through extension_runner, but the upstream behavior "execute the slash command even during streaming" is not faithfully ported - pi-zig rejects steer/follow_up of slash commands by short-circuit. |
| `agent-session.ts` _expandSkillCommand for /skill: prefix | commands.zig:243-245 | OK (different code, same end shape). |
| `agent-session.ts` steer / followUp queueing with QueueUpdate emission | rpc.zig:3134 steer, :3153 follow_up, :2611 steering_queue drain | PARTIAL. Queues themselves exist. The `queue_update` event push is missing (see above). Per-message extension-command rejection works. |
| `agent-session.ts` sendCustomMessage triggerTurn / deliverAs nextTurn | rpc.zig:2788, 2853, 2860 | PARTIAL. `steer`/`follow_up` deliverAs work for custom messages. `nextTurn` delivery (pending until next user-prompt fires, then injected as context) is NOT implemented - no `_pendingNextTurnMessages` analog. |
| `agent-session.ts` sendUserMessage with deliverAs steer/followUp | rpc.zig:2775-2785 | OK (string check only). |
| `agent-session.ts` clearQueue() returning {steering, followUp} arrays | rpc.zig:3172 abort -> :3173 clears both queues | PARTIAL. The clear happens. The return value (so the UI can restore text into the editor) is NOT exposed; abort returns success only. |
| `agent-session.ts` abort() that waits for idle | rpc.zig:3172 abort + 2207 cancellable agent | PARTIAL. Cancellation works. The "wait for idle" semantics (`agent.waitForIdle()`) are implicit in the prompt thread join model but not exposed. |
| `agent-session.ts` setModel(model) with auth-required error / model_select extension event | rpc.zig:3224 set_model | PARTIAL. Model is set; **`model_select` extension event is NOT emitted** anywhere I could find in rpc.zig. `models.writeRpcAvailableModelsData` exists but no model_select notify. |
| `agent-session.ts` cycleModel(direction) - scoped vs available | rpc.zig:3252 cycle_model | PARTIAL. Cycles available models. Scoped-models cycling (--models flag scope) is NOT implemented. |
| `agent-session.ts` setThinkingLevel / cycleThinkingLevel / getAvailableThinkingLevels / supportsThinking + `thinking_level_select` extension event | rpc.zig:3313, :3326, models.nextThinkingLevel | PARTIAL. Setting works. `thinking_level_select` extension event is NOT emitted (no grep hit). `thinking_level_changed` AgentSessionEvent is NOT emitted (no grep hit). The clamping path exists. |
| `agent-session.ts` setSteeringMode / setFollowUpMode | rpc.zig:3342, :3352 | OK. |
| `agent-session.ts` setScopedModels | — | (MISSING). No setter, no storage. |
| `agent-session.ts` compact(customInstructions?) — manual compaction, with `session_before_compact` / `session_compact` extension events | rpc.zig:3383 compact + writeCompactResponse (rpc.zig:1662) | PARTIAL. Compaction text is generated via the LLM with custom instructions accepted. `session_before_compact` (cancellable) and `session_compact` (with compactionEntry / fromExtension) extension events are advertised in upstream.zig but I do NOT see them dispatched in rpc.zig's compaction path. `compaction_start` / `compaction_end` AgentSessionEvents are not emitted (see above). |
| `agent-session.ts` abortCompaction / abortBranchSummary | rpc.zig: prompt-job cancellation polls back | PARTIAL. The active prompt's cancellation token covers compaction since it runs inline; there is no dedicated `abort_compaction` RPC command. |
| `agent-session.ts` automatic compaction (`_checkCompaction`, overflow recovery, threshold) | rpc.zig:1790 shouldCompact + :2197 overflow handling | PARTIAL. Threshold compaction works (rpc.zig:1794-1812). Overflow recovery (one-shot retry after compaction) is implemented at rpc.zig:2197 (`isContextOverflowAgentError(err) and !overflow_compacted`). What is MISSING: aborted-message handling in pre-prompt check, post-compaction usage-source verification, the `_overflowRecoveryAttempted` user-facing failure message after second failure, and the "same model" overflow gate. |
| `agent-session.ts` setAutoCompactionEnabled / autoCompactionEnabled / setAutoRetryEnabled / autoRetryEnabled | rpc.zig:3392 set_auto_compaction, :3405 set_auto_retry | OK. |
| `agent-session.ts` _isRetryableError regex / exponential backoff | rpc.zig:4311 isRetryableAgentError + :2245 delay computation | PARTIAL. pi-zig uses a coarse `error.X` set instead of the regex match upstream uses. Specifically `overloaded_error`, `rate.?limit`, `429`, `500-504`, `websocket.?closed`, `stream ended before message_stop`, `http2 request did not get a response`, `retry delay`, `socket hang up`, etc. are matched by string upstream but pi-zig only sees the Zig error tag. This means many real provider errors that upstream would classify as retryable will NOT be retried by pi-zig. |
| `agent-session.ts` executeBash with `excludeFromContext` / custom `operations` | rpc.zig:1564 executeBash | PARTIAL. `excludeFromContext` flag (the `!!` prefix that records to history but hides from LLM context) is NOT implemented; the bash entry always lands in context. Custom `operations` (remote bash backend) is MISSING. |
| `agent-session.ts` recordBashResult (used by extensions that handle bash themselves) | rpc.zig:1559 recordBashResult | PARTIAL. Function exists but is not exposed via RPC as a separate command; can only be reached internally. |
| `agent-session.ts` flushPendingBashMessages while-streaming queue | — | (MISSING). Bash during streaming is not deferred; pi-zig assumes the prompt job is the only consumer and bash is a separate RPC command. Upstream's interactive mode lets the user run `!echo hi` mid-turn; that interaction isn't part of pi-zig's RPC. |
| `agent-session.ts` navigateTree(targetId, {summarize, customInstructions, replaceInstructions, label}) + `session_before_tree` / `session_tree` events | rpc.zig:796 navigateTree + :818 navigateTreeWithSummary + :3480 navigate_tree command | PARTIAL. Same-file navigation works. Summary path works (rpc.zig:818-880). What is MISSING: `replaceInstructions` flag, `label` attachment on summary/target entries, `session_before_tree` cancellation event dispatch, `session_tree` extension event dispatch. The grep for `session_before_tree`/`session_tree` only matches upstream.zig and the JS embedded runtime, not the navigation code path. |
| `agent-session.ts` getUserMessagesForForking() | rpc.zig:3275 get_fork_messages | OK. |
| `agent-session.ts` getSessionStats() / SessionStats shape | rpc.zig:3271 get_session_stats | PARTIAL. Stats include message counts; `contextUsage` and per-token cost breakdown were not visible in my reading - need to verify the writer emits all upstream-shape fields. (Could not fully verify cost breakdown without reading the writer block.) |
| `agent-session.ts` getContextUsage with post-compaction usage validity | — | (MISSING / could not verify). I could not find a getContextUsage analog in rpc.zig that handles the "no post-compaction assistant usage yet" tri-state of `{tokens: null, contextWindow, percent: null}`. The token estimate exists (`estimateTokensBeforeCompaction`, rpc.zig:1812) but the full ContextUsage shape with null-tokens semantics is not exposed. |
| `agent-session.ts` exportToHtml(outputPath?) | rpc.zig:3291 export_html + html_export.exportHtmlFromFile | OK. |
| `agent-session.ts` exportToJsonl(outputPath?) - re-chains parentIds for linear export | — | (MISSING). No `export_jsonl` RPC command. The reverse direction (importFromJsonl) is also missing. |
| `agent-session.ts` getLastAssistantText() | rpc.zig:3279 get_last_assistant_text | OK. |
| `agent-session.ts` setSessionName(name) emitting `session_info_changed` | rpc.zig:3303 set_session_name | PARTIAL (event missing). |
| `agent-session.ts` createReplacedSessionContext() | — | (MISSING). The "stale ctx invalidation + fresh ctx passed to `withSession` callback" pattern is JS-extension-specific; pi-zig has no equivalent because there is no in-process JS host - but the embedded JS runtime (extension_runner.zig:1505) advertises `navigateTree: async () => ({cancelled:true})`, so the absence will surface as broken extension UX. |
| `agent-session.ts` reload() that hot-reloads settings + resourceLoader + extensions and re-emits `session_start{reason:"reload"}` | — | (MISSING). No /reload command, no reload command in `rpc_commands` list (upstream.zig:185-215). Settings/extension changes require process restart. |
| `agent-session.ts` extendResourcesFromExtensions (resources_discover wiring) | extension_runner.zig:1643-1655 (runtime acknowledges resources_discover) + rpc.zig writeSessionTree | PARTIAL. The JS runtime claims to aggregate skill/prompt/theme paths from extensions. I did not find the corresponding Zig consumer that calls `_resourceLoader.extendResources` and rebuilds the system prompt mid-session, but this is partially handled via the embedded runtime contract. |
| `agent-session.ts` bindExtensions (ExtensionBindings: uiContext, commandContextActions, abortHandler, shutdownHandler, onError) | extension_runner.zig has CommandDefinition / FlagDefinition / lifecycle plumbing; rpc.zig wires lifecycle_emit via RuntimeLifecycleEmitContext | PARTIAL. The data channel exists for lifecycle events. UI context, shutdown handler, and onError listener slots are not visible as a single bind point. |

---

## 3. Gap detail (MISSING and PARTIAL items)

### 3.1 In-process event bus (`event-bus.ts`)
- **Upstream**: tiny pub/sub layer around node:EventEmitter so different parts of the host (TUI, RPC, extensions) can listen to a shared channel without coupling. Safe-handler wrapper catches async handler errors.
- **Missing in pi-zig**: there is no equivalent. RPC pushes JSON-RPC notifications directly out the wire. Internal subscribers (e.g. a TUI rendering compaction progress alongside the agent loop) cannot be added without re-architecting.
- **Complexity to close**: Low (50-150 LOC) on its own, but Medium-High once you wire all the AgentSession events to it.
- **User-visible**: internal (architectural).

### 3.2 Telemetry env gate (`telemetry.ts`)
- **Upstream**: `PI_TELEMETRY=1/true/yes` env var overrides settings; otherwise falls back to `settings.enableInstallTelemetry`. Used by `sdk.ts:getAttributionHeaders` to decide whether to send openrouter/cloudflare attribution headers.
- **Missing in pi-zig**: both the env var read and the settings field. pi-zig sends NO attribution headers anywhere. From a provider-relationship standpoint that means OpenRouter cannot identify pi-zig traffic.
- **Complexity to close**: Low (env read + settings field + plumb into header builder = ~30 LOC).
- **User-visible**: internal (affects OpenRouter / Cloudflare provider-side attribution).

### 3.3 Startup timing instrumentation (`timings.ts`)
- **Upstream**: `PI_TIMING=1` env-gated startup profiler that records `{label, ms}` deltas and prints a startup-timings table on shutdown. Called from many bootstrap call sites (e.g. `sdk.ts:219 time("resourceLoader.reload")`).
- **Missing in pi-zig**: no env gate, no per-phase recording.
- **Complexity to close**: Low (~50 LOC), but trivial wins.
- **User-visible**: developer-only.

### 3.4 Generic `exec.ts` execCommand utility
- **Upstream**: `spawn(command, args, {shell:false})` style executor with AbortSignal, timeout, SIGTERM-then-SIGKILL escalation. Used by extensions and custom tools that need to fire one-shot binaries (not a shell pipeline).
- **Missing in pi-zig**: tools.zig has `runShell*` which always goes through `sh -c <command>`. There is no shell-bypass path for extension/custom-tool use.
- **Complexity to close**: Medium. Need new public API surface in tools.zig that takes argv array directly + propagate AbortSignal-equivalent (a `should_cancel` callback already exists).
- **User-visible**: extension authors lose the ability to invoke argv-style commands safely (their args go through shell quoting today).

### 3.5 bash-executor.ts behavioral differences
- **Upstream**:
  - Strips ANSI escapes (`stripAnsi`) before recording.
  - Sanitizes binary garbage (`sanitizeBinaryOutput`).
  - Per-chunk callback `onChunk(text)` for streaming.
  - Pluggable `BashOperations` interface so the bash step can be redirected (SSH, docker, etc.).
  - Tmpfile spilled at `tmpdir()/pi-bash-<hex>.log` once output exceeds `DEFAULT_MAX_BYTES`.
- **Missing in pi-zig**:
  - No ANSI stripping; raw bytes are stored.
  - No binary sanitization.
  - Streaming callback is debounce-batched, not per-chunk.
  - No `BashOperations` indirection; bash always runs locally.
  - Tmpfile spill is implemented (verified `full_output_path` in tools.zig:880 / session.zig:752).
- **Complexity to close**: Medium for ANSI/sanitize (pure functions + buffer plumbing). High for BashOperations indirection (would require a new tool-callback contract).
- **User-visible**: yes - colored CLI output (e.g. `git status`) currently records raw escapes that show as garbage in tools that read the session JSONL or display history.

### 3.6 FooterDataProvider
- **Upstream**:
  - Live `fs.watch` on `.git/HEAD` (and reftable variant) so the footer updates on `git checkout` without polling.
  - Walks up for git root and handles worktrees (`.git` is a file with `gitdir:`).
  - Exposes `getExtensionStatuses` so extensions can paint text in the footer (e.g. "MCP: 3 servers").
  - Exposes `getAvailableProviderCount` for the provider-count badge.
  - `onBranchChange` callback set for subscribers.
  - `setCwd` rewatches if cwd changes mid-session.
- **Missing in pi-zig**: tui.zig:446 resolves git branch lazily once by shelling `git`. Worktree handling, reftable handling, watcher, extension statuses, provider-count badge, branch-change callbacks, setCwd all absent.
- **Complexity to close**: High. The fs.watch + watchFile + reftable fallback alone is substantial; the extension-status surface requires wiring through `bindCore.setStatus` from the extension runner (not present).
- **User-visible**: yes - footer is static today; pi-zig won't update when user switches branches outside the agent.

### 3.7 sdk.ts createAgentSession + AgentSessionRuntime / AgentSessionServices
- **Upstream**: three-layer factory pattern (`createAgentSessionServices` -> `createAgentSessionFromServices` -> `createAgentSessionRuntime`) so the host can rebuild services for a new cwd without restarting the process. Returns `{session, extensionsResult, modelFallbackMessage, services, diagnostics}` and supports `setRebindSession` / `setBeforeSessionInvalidate` host hooks for clean UI teardown.
- **Missing in pi-zig**: factory pattern is absent. The Runtime struct is built once in `rpc.zig` and never torn down/rebuilt mid-process. Switching cwd requires restarting; diagnostics are returned as Zig errors (not a list of `{type, message}`).
- **Complexity to close**: High. Touches initialization, teardown ordering, extension reload, session import/JSONL, and ResourceLoader hot-swap. Would also unblock `/reload`, `/cwd`, and `/import`.
- **User-visible**: yes - blocks `/import`, `/reload`, and any planned cwd-switching feature.

### 3.8 sdk.ts getAttributionHeaders
- **Upstream**: emits `HTTP-Referer`/`X-OpenRouter-Title`/`X-OpenRouter-Categories` for OpenRouter, `User-Agent: pi-coding-agent` for Cloudflare, and `x-opencode-session`/`x-opencode-client` for opencode/opencode-go providers. Gated by `isInstallTelemetryEnabled`.
- **Missing in pi-zig**: completely absent.
- **Complexity to close**: Low (~40 LOC + header threading through ai_client request).
- **User-visible**: internal/provider-policy.

### 3.9 Block-images dynamic per-turn filter
- **Upstream**: when `settings.images.blockImages` is true, EVERY turn replaces `ImageContent` blocks in the LLM messages with `"Image reading is disabled."` text, with consecutive-dupe collapsing. Defense-in-depth (in case a vision-capable model is later set).
- **Missing in pi-zig**: settings field is read (settings.zig:491) but no message-rewriting path. The image-count code at rpc.zig:4860,4882 only counts.
- **Complexity to close**: Low-Medium (~80 LOC pre-stream message walk).
- **User-visible**: yes - blockImages today has no effect on what is sent to the LLM.

### 3.10 onPayload / before_provider_request as mutation hook
- **Upstream**: `sdk.ts:onPayload` lets a `before_provider_request` extension handler replace the request payload entirely.
- **Missing in pi-zig**: explicitly notify-only per agent.zig:23 comment. Extensions can observe but cannot rewrite the HTTP body.
- **Complexity to close**: High. The HTTP payload assembly is buried in `ai_client.zig`; exposing a mutation seam requires lifting payload assembly out of the streaming call.
- **User-visible**: yes - any extension that wants to add headers / rewrite payload / swap models on the fly (a documented use case) doesn't work.

### 3.11 ParsedSkillBlock / parseSkillBlock
- **Upstream**: regex parser that recovers `{name, location, content, userMessage}` from any user message containing `<skill name="..." location="...">...</skill>` markup.
- **Missing in pi-zig**: no parser, only the emitter. This means a session resumed by another tool that re-injects a skill block cannot be introspected.
- **Complexity to close**: Low (~30 LOC of regex / scan).
- **User-visible**: low (mainly affects export/import tooling).

### 3.12 AgentSessionEvent variants not emitted as RPC notifications
- **Missing in pi-zig** (no grep hit in rpc.zig):
  - `queue_update` — UI must poll `get_state` to see queue counts.
  - `compaction_start` / `compaction_end` — UI sees no progress events.
  - `session_info_changed` — UI must poll after `set_session_name`.
  - `thinking_level_changed` — UI must read response only.
  - `model_select` extension event — extensions cannot observe model swaps.
  - `thinking_level_select` extension event — extensions cannot observe thinking level swaps.
  - `session_before_compact`, `session_compact`, `session_before_tree`, `session_tree`, `session_before_fork`, `session_before_switch` — listed in `upstream.zig:146-147` and advertised by the embedded JS runtime, but I cannot find the dispatch sites in `rpc.zig`. The events appear to be advertised but unwired.
- **Complexity to close**: Medium-High collectively. Each is a 5-30 LOC dispatch site, but identifying every fire point and the right payload shape is the work. Some (session_before_*) need cancellation routing.
- **User-visible**: yes - the workbench / RPC clients today have stale views of queue / compaction / session state and must poll.

### 3.13 AgentSession.prompt() pipeline
- **Upstream**: the order is (1) check if `/extension-command` and execute, (2) emit `input` event for transform/handle, (3) `_expandSkillCommand` for `/skill:name`, (4) `expandPromptTemplate`, (5) decide streaming-behavior, (6) build user-message with images, (7) inject pendingNextTurn messages, (8) emit `before_agent_start` (extensions may add custom messages and/or override system prompt), (9) run the agent.
- **Missing/PARTIAL in pi-zig**:
  - `input` event with action="transform" / "handled" (text/images rewrite) — no grep evidence in rpc.zig.
  - `pendingNextTurnMessages` injection — no analog.
  - `before_agent_start` returning `{messages, systemPrompt}` for per-turn override — no analog.
- **Complexity to close**: Medium. Each is a small dispatch addition but they affect message-array assembly.
- **User-visible**: yes - several documented extension capabilities don't work.

### 3.14 abort() returning queue contents
- **Upstream**: `clearQueue()` returns `{steering, followUp}` arrays so the UI can repopulate the editor with the user's lost messages.
- **Missing in pi-zig**: clear happens, but the values are not returned.
- **Complexity to close**: Low (~15 LOC).
- **User-visible**: yes - cancel-while-queued discards the user's typed text.

### 3.15 cycleModel scoped models / setScopedModels / `--models` flag scope
- **Upstream**: when `--models A B C` is passed at startup, Ctrl+P cycles only those three. Otherwise cycles all available.
- **Missing in pi-zig**: scoped storage and cycling are absent. cycle_model always cycles all available.
- **Complexity to close**: Medium (~120 LOC: parse flag, store list, branch in cycle, settings reload).
- **User-visible**: yes - upstream's `--models` flag has no effect on pi-zig.

### 3.16 Retry error classifier divergence
- **Upstream**: regex over the error message string covering 20+ patterns (overloaded_error, rate.?limit, 429-504, websocket closures, premature stream endings, http2 not-got-a-response, terminated, retry delay, fetch failed, etc.).
- **Missing in pi-zig**: classifier matches a small set of Zig `error.X` tags (rpc.zig:4311 isRetryableAgentError). Many real provider transient errors land outside the matched set and are not retried.
- **Complexity to close**: Medium (~100 LOC). Requires preserving the provider error message string through ai_client and matching on it.
- **User-visible**: yes - intermittent provider errors that upstream survives transparently fail hard in pi-zig.

### 3.17 executeBash excludeFromContext / BashOperations
- **Upstream**: `!!echo hi` records bash output to history but excludes it from LLM context. `BashOperations` lets the bash step run remotely.
- **Missing in pi-zig**: `excludeFromContext` flag not in `bash` RPC, `BashOperations` indirection absent.
- **Complexity to close**: Low for excludeFromContext (~30 LOC). High for BashOperations.
- **User-visible**: medium - the `!!` pattern is documented but inert.

### 3.18 navigateTree label / replaceInstructions / session_before_tree / session_tree
- **Upstream**: navigateTree accepts `replaceInstructions` (replaces the default summarization prompt outright) and `label` (attached to the resulting branch-summary or target entry). Emits `session_before_tree` (cancellable) and `session_tree` (with `newLeafId, oldLeafId, summaryEntry?, fromExtension?`) extension events.
- **Missing in pi-zig**: navigate_tree command (rpc.zig:3480) accepts only `targetId` and optional `customInstructions`. Label and replaceInstructions are absent. Events are advertised in upstream.zig but the dispatch sites are not in rpc.zig's nav code.
- **Complexity to close**: Medium (~150 LOC).
- **User-visible**: yes - branch labels (a feature visible in the tree-selector UI) are broken.

### 3.19 exportToJsonl / importFromJsonl
- **Upstream**: round-trippable JSONL with linearized parentIds. `importFromJsonl` copies a JSONL into the session dir and switches to it; throws `SessionImportFileNotFoundError` on missing input.
- **Missing in pi-zig**: both directions. No `export_jsonl` or `import_jsonl` RPC.
- **Complexity to close**: Medium (~200 LOC for round-trip + error type).
- **User-visible**: yes - blocks `/import` and `/export` slash commands.

### 3.20 reload() (hot reload of settings / extensions / resources)
- **Upstream**: shuts extensions down with `reason:"reload"`, reloads settings, resets ai_client providers, reloads ResourceLoader, rebuilds tool registry, re-emits `session_start{reason:"reload"}`.
- **Missing in pi-zig**: no /reload command, no analogous teardown/rebuild flow.
- **Complexity to close**: High - depends on createAgentSessionServices factoring being in place first.
- **User-visible**: yes - blocks `/reload`.

### 3.21 getContextUsage post-compaction null-token tri-state
- **Upstream**: returns `{tokens: number | null, contextWindow, percent: number | null}`. After a fresh compaction the assistant has not yet responded post-compaction, so `tokens`/`percent` are explicitly null to avoid showing the stale pre-compaction context size in the UI.
- **Missing in pi-zig**: I could not find a getContextUsage analog at all. Token estimation (`estimateTokensBeforeCompaction` rpc.zig:1812) is internal-only.
- **Complexity to close**: Medium.
- **User-visible**: yes - context-usage gauges (footer/header) would show wrong values right after compaction.

### 3.22 Compaction extension hooks (`session_before_compact` cancel + extension-provided compaction content)
- **Upstream**: extensions may cancel a compaction or supply their own `{summary, firstKeptEntryId, tokensBefore, details}` to be persisted with `fromHook:true`.
- **Missing in pi-zig**: I see the `from_hook` boolean column in session.zig:695 (`appendBranchSummary(..., from_hook)`) but no dispatch site that asks extensions for the compaction payload.
- **Complexity to close**: Medium.
- **User-visible**: yes - the documented compaction-customization extension capability does not work.

### 3.23 `_pendingNextTurnMessages` (asides / context injection on next prompt)
- **Upstream**: `sendCustomMessage(..., {deliverAs:"nextTurn"})` queues a custom message that is injected alongside the next user prompt (not as a turn of its own). Used by extensions to add transient context.
- **Missing in pi-zig**: no such buffer; `deliverAs` accepts only `steer` and `follow_up`.
- **Complexity to close**: Low-Medium.
- **User-visible**: yes for extension authors.

---

## 4. Honest summary

Counting public surfaces from the assigned upstream files:

- `event-bus.ts`: 3 surfaces. 0 ported → 0%.
- `telemetry.ts`: 1 public + 1 private (private excluded). 0 ported → 0%.
- `timings.ts`: 3 functions + 1 env gate. 0 ported → 0%.
- `exec.ts`: 3 surfaces (2 types + 1 function). 0 ported as a public API → 0% (there's a shell-only analog so counting is generous).
- `bash-executor.ts`: 3 surfaces. The function is partly ported (output capture, exit_code, truncated, full_output_path, cancelled). ANSI/sanitize/BashOperations/per-chunk stream are missing → ~50%.
- `footer-data-provider.ts`: 13 surfaces on the class + 2 free fns + 1 type. pi-zig has 1 surface (`getGitBranch` semantically). → ~7%.
- `sdk.ts`: 1 fn + 2 interfaces + re-exports + 1 private header builder. The factory exists by another name, lacks ~12 documented option fields and the attribution headers. → ~35%.
- `agent-session-services.ts`: 4 interfaces + 2 functions. None ported as a separable layer → 0% (Runtime exists but isn't the same shape).
- `agent-session-runtime.ts`: AgentSessionRuntime class (10 public methods) + 1 error class + 1 type + 1 factory. switchSession/newSession/fork are present at the RPC level. importFromJsonl, setRebindSession, setBeforeSessionInvalidate, withSession callback, error type, diagnostics chaining are MISSING. → ~35%.
- `agent-session.ts`: 8 exported interfaces/types + 1 function (`parseSkillBlock`) + 1 class with ~50 public methods/getters. The big class is the slice's heart and where most parity work lives.
  - Getters: ~22 ported.
  - Prompt pipeline: PARTIAL (template + skill yes; input-transform, before_agent_start custom messages, nextTurn injection, blockImages dynamic filter MISSING).
  - Queue + retry: queue counts PARTIAL (no push event); retry classifier PARTIAL (coarse).
  - Model: PARTIAL (no scoped models, no model_select event).
  - Thinking: PARTIAL (no thinking_level_changed/select events).
  - Compaction: PARTIAL (manual + threshold + overflow work; events and hooks MISSING).
  - Bash: PARTIAL (no excludeFromContext, no BashOperations, no flushPending).
  - Navigation: PARTIAL (no label, no replaceInstructions, no events).
  - Session lifecycle (reload, import/export jsonl, replaced ctx): MOSTLY MISSING.
  - Roughly 30-35 of ~50 surfaces are reachable in some form, but ~20-25 are MISSING or so partial they don't fulfill the upstream contract.
  - → ~50% of the AgentSession class surface, but weighted by feature depth ~35%.

Weighted estimate across the slice:

```
event-bus.ts             : 0%   * weight 1
telemetry.ts             : 0%   * weight 1
timings.ts               : 0%   * weight 1
exec.ts                  : 0%   * weight 1
bash-executor.ts         : 50%  * weight 2
footer-data-provider.ts  : 7%   * weight 2
sdk.ts                   : 35%  * weight 3
agent-session-services.ts: 0%   * weight 2
agent-session-runtime.ts : 35%  * weight 3
agent-session.ts         : 35%  * weight 8  (largest, deepest)

Weighted total: (0+0+0+0+100+14+105+0+105+280) / (1+1+1+1+2+2+3+2+3+8)
              = 604 / 24
              = 25.2%
```

**Estimated true parity of this slice = ~25-30%.**

Caveats / things I could not verify by static read alone:
- The exact field set written by `get_session_stats` (cost breakdown) — would need to read rpc.zig:3271's writer body to confirm.
- Whether the embedded JS runtime's claim to dispatch `session_before_*` events is actually backed by Zig-side dispatch (no grep hit suggests no, but the JS surface might be reachable from outside `rpc.zig`).
- Whether `auto_retry_start/end` events match the upstream payload shape byte-for-byte (the writer code exists; I did not diff the JSON keys).
- Some PARTIAL items might be closer to OK if I missed a wiring in another file I did not enumerate (e.g. `cli_runtime.zig` might be doing some of the model_select dispatch outside the search I ran).

Where I claim MISSING I have grep-verified the absence by name and by upstream-side identifier; where I claim PARTIAL I have read the pi-zig analog and identified the specific upstream behavior it does not reproduce.

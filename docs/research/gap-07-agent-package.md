# Gap-07 - Upstream `packages/agent` vs. pi-zig

Read-only audit of `upstream/pi/packages/agent/` (the upstream "agent harness"
package, the npm artifact `@earendil-works/pi-agent-core`) against pi-zig's
`src/pi/agent.zig`, `src/pi/ai_client.zig`, `src/pi/tools.zig`, `src/pi/rpc.zig`,
`src/pi/session.zig`, `src/pi/commands.zig`, and `src/pi/system_prompt.zig`.

The upstream package is ~8 kLoC of TypeScript across:

| File | LoC |
|---|---:|
| `src/index.ts` | 44 |
| `src/agent.ts` | 557 |
| `src/agent-loop.ts` | 742 |
| `src/proxy.ts` | 367 |
| `src/types.ts` | 418 |
| `src/node.ts` | 2 |
| `src/harness/agent-harness.ts` | 995 |
| `src/harness/types.ts` | 815 |
| `src/harness/messages.ts` | 164 |
| `src/harness/system-prompt.ts` | 34 |
| `src/harness/prompt-templates.ts` | 267 |
| `src/harness/skills.ts` | 375 |
| `src/harness/compaction/compaction.ts` | 755 |
| `src/harness/compaction/utils.ts` | 144 |
| `src/harness/compaction/branch-summarization.ts` | 262 |
| `src/harness/utils/shell-output.ts` | 143 |
| `src/harness/utils/truncate.ts` | 344 |
| `src/harness/env/nodejs.ts` | 528 |
| `src/harness/session/jsonl-storage.ts` | 293 |
| `src/harness/session/jsonl-repo.ts` | 177 |
| `src/harness/session/memory-storage.ts` | 131 |
| `src/harness/session/memory-repo.ts` | 50 |
| `src/harness/session/session.ts` | 252 |
| `src/harness/session/repo-utils.ts` | 51 |
| `src/harness/session/uuid.ts` | 54 |

Pi-zig's parity ledger (`docs/parity.md`) currently lists "Agent
runtime/harness/tool loop" at 100% complete (weight 13, contribution 13.00).
The actual evidence in this audit is **less rosy**: pi-zig has a usable
single-turn / multi-turn provider+tool loop with hook points but does NOT have
the upstream-shaped `Agent` / `AgentHarness` orchestration objects, the
`AgentLoopConfig` callback contract, the rich session-tree types, the
`Result<T,E>` error model, `transformContext`, `convertToLlm`,
`agentLoopContinue`, the `EventStream`, or the proxy stream. Most of those
gaps live behind RPC and are partly *substituted* by pi-zig's `rpc.zig`
runtime, but the abstractions themselves are absent and external consumers
cannot embed pi-zig as a library the way upstream's package supports.

---

## 1. Surface inventory (upstream)

Public exports re-exported from `index.ts`.

### 1.1 `agent.ts` - core `Agent` class
- `class Agent` - stateful wrapper around `runAgentLoop`/`runAgentLoopContinue`
  - constructor `(options: AgentOptions)`
  - `subscribe((event, signal) => Promise<void>|void): () => void`
  - getter `state: AgentState`
  - getter/setter `steeringMode: QueueMode`
  - getter/setter `followUpMode: QueueMode`
  - `steer(message: AgentMessage): void`
  - `followUp(message: AgentMessage): void`
  - `clearSteeringQueue()`, `clearFollowUpQueue()`, `clearAllQueues()`
  - `hasQueuedMessages(): boolean`
  - getter `signal: AbortSignal | undefined`
  - `abort(): void`
  - `waitForIdle(): Promise<void>`
  - `reset(): void`
  - `prompt(message: AgentMessage | AgentMessage[]): Promise<void>`
  - `prompt(input: string, images?: ImageContent[]): Promise<void>` (overload)
  - `continue(): Promise<void>`
  - public mutable fields: `convertToLlm`, `transformContext`, `streamFn`,
    `getApiKey`, `onPayload`, `onResponse`, `beforeToolCall`, `afterToolCall`,
    `prepareNextTurn`, `sessionId`, `thinkingBudgets`, `transport`,
    `maxRetryDelayMs`, `toolExecution`
- `type QueueMode` (re-export of `types.ts` definition)
- `interface AgentOptions` (constructor input)

### 1.2 `agent-loop.ts` - low-level loop
- `type AgentEventSink = (event: AgentEvent) => Promise<void> | void`
- `function agentLoop(prompts, context, config, signal?, streamFn?): EventStream`
- `function agentLoopContinue(context, config, signal?, streamFn?): EventStream`
- `async function runAgentLoop(prompts, context, config, emit, signal?, streamFn?): Promise<AgentMessage[]>`
- `async function runAgentLoopContinue(context, config, emit, signal?, streamFn?): Promise<AgentMessage[]>`
- Internal turn-loop machinery (private but observable through events):
  - sequential vs. parallel tool execution (`executeToolCallsSequential`,
    `executeToolCallsParallel`)
  - `prepareToolCall` lifecycle (`tool.prepareArguments` then
    `validateToolArguments` then `beforeToolCall`)
  - `executePreparedToolCall` (calls `tool.execute(id, args, signal, onUpdate)`)
  - `finalizeExecutedToolCall` (runs `afterToolCall`, merges patches)
  - per-batch `terminate` early-stop (every finalized result must set `terminate=true`)
  - assistant-stream consumption via `EventStream` events
    (`start`/`text_*`/`thinking_*`/`toolcall_*`/`done`/`error`)
  - explicit `agent_start`/`turn_start`/`message_start`/`message_update`/
    `message_end`/`tool_execution_start`/`tool_execution_update`/
    `tool_execution_end`/`turn_end`/`agent_end` event order

### 1.3 `types.ts` - public surface
- `type StreamFn`
- `type ToolExecutionMode = "sequential" | "parallel"`
- `type QueueMode = "all" | "one-at-a-time"`
- `type AgentToolCall` (extracted from `AssistantMessage.content`)
- `interface BeforeToolCallResult { block?, reason? }`
- `interface AfterToolCallResult { content?, details?, isError?, terminate? }`
- `interface BeforeToolCallContext { assistantMessage, toolCall, args, context }`
- `interface AfterToolCallContext { ...BeforeToolCallContext, result, isError }`
- `interface ShouldStopAfterTurnContext { message, toolResults, context, newMessages }`
- `interface AgentLoopTurnUpdate { context?, model?, thinkingLevel? }`
- `interface PrepareNextTurnContext extends ShouldStopAfterTurnContext`
- `interface AgentLoopConfig extends SimpleStreamOptions`:
  - `model`, required
  - `convertToLlm` (required) - AgentMessage[] -> Message[]
  - `transformContext?` - AgentMessage[] -> AgentMessage[]
  - `getApiKey?`
  - `shouldStopAfterTurn?`
  - `prepareNextTurn?`
  - `getSteeringMessages?`
  - `getFollowUpMessages?`
  - `toolExecution?`
  - `beforeToolCall?`
  - `afterToolCall?`
- `type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh"`
- `interface CustomAgentMessages` (declaration-merging extension point)
- `type AgentMessage = Message | CustomAgentMessages[keyof CustomAgentMessages]`
- `interface AgentState` (with accessor properties for `tools`/`messages`,
  readonly `isStreaming`, `streamingMessage`, `pendingToolCalls`,
  `errorMessage`)
- `interface AgentToolResult<T> { content, details, terminate? }`
- `type AgentToolUpdateCallback<T>`
- `interface AgentTool<TParameters, TDetails> extends Tool { label, prepareArguments?, execute, executionMode? }`
- `interface AgentContext { systemPrompt, messages, tools? }`
- `type AgentEvent` (discriminated union, 9 variants - see 1.2)

### 1.4 `proxy.ts` - server-proxy stream function
- `type ProxyAssistantMessageEvent` (slimmed wire-format mirror of `AssistantMessageEvent`)
- `interface ProxyStreamOptions extends ProxySerializableStreamOptions { signal?, authToken, proxyUrl }`
- `function streamProxy(model, context, options): ProxyMessageEventStream`
  - implements the `StreamFn` contract over HTTP SSE to a server
  - reconstructs partial `AssistantMessage` client-side from the streamed
    proxy events
  - cancellable via `AbortSignal`

### 1.5 `harness/agent-harness.ts` - durable orchestration layer
- `class AgentHarness<TSkill, TPromptTemplate, TTool>`
  - constructor `(options: AgentHarnessOptions)`
  - `prompt(text, options?): Promise<AssistantMessage>`
  - `skill(name, additionalInstructions?): Promise<AssistantMessage>`
  - `promptFromTemplate(name, args?): Promise<AssistantMessage>`
  - `steer(text, options?): Promise<void>`
  - `followUp(text, options?): Promise<void>`
  - `nextTurn(text, options?): Promise<void>`
  - `appendMessage(message)`
  - `compact(customInstructions?): Promise<CompactResult>`
  - `navigateTree(targetId, options?): Promise<NavigateTreeResult>`
  - `getModel()`, `setModel(model)`
  - `getThinkingLevel()`, `setThinkingLevel(level)`
  - `setActiveTools(toolNames)`
  - `getSteeringMode()`, `setSteeringMode(mode)`
  - `getFollowUpMode()`, `setFollowUpMode(mode)`
  - `getResources()`, `setResources(resources)`
  - `getStreamOptions()`, `setStreamOptions(opts)`
  - `setTools(tools, activeToolNames?)`
  - `abort(): Promise<AbortResult>`
  - `waitForIdle()`
  - `subscribe(listener)` - observer for any event
  - `on(type, handler)` - participating hook for one event type
  - internal phases: `"idle" | "turn" | "compaction" | "branch_summary" | "retry"`
  - pending session writes flushed at save points
- Own events (in addition to `AgentEvent`):
  `queue_update`, `save_point`, `abort`, `settled`, `before_agent_start`,
  `context`, `before_provider_request`, `before_provider_payload`,
  `after_provider_response`, `tool_call`, `tool_result`,
  `session_before_compact`, `session_compact`, `session_before_tree`,
  `session_tree`, `model_select`, `thinking_level_select`,
  `resources_update`

### 1.6 `harness/types.ts` - harness public types
- `type Result<T,E>`, `ok()`, `err()`, `getOrThrow()`, `getOrUndefined()`,
  `toError()`
- `interface Skill { name, description, content, filePath, disableModelInvocation? }`
- `interface PromptTemplate { name, description?, content }`
- `interface AgentHarnessResources<TSkill, TPromptTemplate> { promptTemplates?, skills? }`
- `interface AgentHarnessStreamOptions { transport?, timeoutMs?, maxRetries?,
  maxRetryDelayMs?, headers?, metadata?, cacheRetention? }`
- `interface AgentHarnessStreamOptionsPatch`
- `type FileKind`, `type FileErrorCode`, `class FileError`
- `type ExecutionErrorCode`, `class ExecutionError`
- `type CompactionErrorCode`, `class CompactionError`
- `type BranchSummaryErrorCode`, `class BranchSummaryError`
- `type SessionErrorCode`, `class SessionError`
- `type AgentHarnessErrorCode`, `class AgentHarnessError`
- `interface FileInfo`
- `interface ExecutionEnvExecOptions`
- `interface FileSystem` (abstract, 14 methods)
- `interface Shell` (`exec`, `cleanup`)
- `interface ExecutionEnv extends FileSystem, Shell`
- Session-tree entry shapes (10 types):
  - `MessageEntry`, `ThinkingLevelChangeEntry`, `ModelChangeEntry`,
    `CompactionEntry<T>`, `BranchSummaryEntry<T>`, `CustomEntry<T>`,
    `CustomMessageEntry<T>`, `LabelEntry`, `SessionInfoEntry`, `LeafEntry`
  - tagged union `SessionTreeEntry`
- `interface SessionContext { messages, thinkingLevel, model }`
- `interface SessionMetadata`, `interface JsonlSessionMetadata extends SessionMetadata`
- `interface SessionStorage<TMetadata>` (8 methods)
- `interface SessionRepo<...>` (5 methods: `create`, `open`, `list`, `delete`, `fork`)
- `interface JsonlSessionCreateOptions`, `interface JsonlSessionListOptions`
- `interface JsonlSessionRepoApi extends SessionRepo<...>`
- `type AgentHarnessPhase`
- `type PendingSessionWrite` (mapped over `SessionTreeEntry`)
- Event interface for every own event listed under 1.5
- Hook result interfaces:
  `BeforeAgentStartResult`, `ContextResult`, `BeforeProviderRequestResult`,
  `BeforeProviderPayloadResult`, `ToolCallResult`, `ToolResultPatch`,
  `SessionBeforeCompactResult`, `SessionBeforeTreeResult`
- `type AgentHarnessEventResultMap` (compile-time `on(...)` return types)
- `interface AgentHarnessPromptOptions { images? }`
- `interface AbortResult { clearedSteer, clearedFollowUp }`
- `interface CompactResult { summary, firstKeptEntryId, tokensBefore, details? }`
- `interface NavigateTreeResult { cancelled, editorText?, summaryEntry? }`
- `interface CompactionSettings`, `interface CompactionPreparation`,
  `interface FileOperations`, `interface TreePreparation`,
  `interface GenerateBranchSummaryOptions`, `interface BranchSummaryResult`
- `interface AgentHarnessOptions<TSkill, TPromptTemplate, TTool>`

### 1.7 `harness/messages.ts` - custom message types and LLM conversion
- Constants: `COMPACTION_SUMMARY_PREFIX`, `COMPACTION_SUMMARY_SUFFIX`,
  `BRANCH_SUMMARY_PREFIX`, `BRANCH_SUMMARY_SUFFIX`
- `interface BashExecutionMessage { role:"bashExecution", command, output, exitCode, cancelled, truncated, fullOutputPath?, timestamp, excludeFromContext? }`
- `interface CustomMessage<T> { role:"custom", customType, content, display, details?, timestamp }`
- `interface BranchSummaryMessage { role:"branchSummary", summary, fromId, timestamp }`
- `interface CompactionSummaryMessage { role:"compactionSummary", summary, tokensBefore, timestamp }`
- Augments `CustomAgentMessages` via declaration merging
- `function bashExecutionToText(msg)`
- Constructors:
  `createBranchSummaryMessage`, `createCompactionSummaryMessage`, `createCustomMessage`
- `function convertToLlm(messages: AgentMessage[]): Message[]`
  (concrete `AgentLoopConfig.convertToLlm` used by the harness)

### 1.8 `harness/system-prompt.ts`
- `function formatSkillsForSystemPrompt(skills: Skill[]): string`
  (renders the `<available_skills>` XML block consumed by the system prompt)

### 1.9 `harness/prompt-templates.ts`
- `type PromptTemplateDiagnosticCode`, `interface PromptTemplateDiagnostic`
- `async function loadPromptTemplates(env, paths): { promptTemplates, diagnostics }`
- `async function loadSourcedPromptTemplates(env, inputs, mapPromptTemplate?)`
- `function parseCommandArgs(argsString): string[]` (shell-style quoting)
- `function substituteArgs(content, args): string`
  (`$1`, `$@`, `$ARGUMENTS`, `${@:N}`, `${@:N:L}`)
- `function formatPromptTemplateInvocation(template, args?): string`

### 1.10 `harness/skills.ts`
- `type SkillDiagnosticCode`, `interface SkillDiagnostic`
- `function formatSkillInvocation(skill, additionalInstructions?): string`
- `async function loadSkills(env, dirs): { skills, diagnostics }`
- `async function loadSourcedSkills(env, inputs, mapSkill?)`
- Honors `SKILL.md` discovery rules, `.gitignore`/`.ignore`/`.fdignore`,
  parent-dir-name validation, `disable-model-invocation` frontmatter,
  `MAX_NAME_LENGTH`/`MAX_DESCRIPTION_LENGTH` checks

### 1.11 `harness/compaction/compaction.ts`
- Constants: `DEFAULT_COMPACTION_SETTINGS`, `SUMMARIZATION_SYSTEM_PROMPT`,
  internal `SUMMARIZATION_PROMPT`, `UPDATE_SUMMARIZATION_PROMPT`,
  `TURN_PREFIX_SUMMARIZATION_PROMPT`
- `interface CompactionDetails`
- `interface CompactionResult<T>`
- `interface CompactionSettings`
- `function calculateContextTokens(usage)`
- `function getLastAssistantUsage(entries)`
- `interface ContextUsageEstimate`
- `function estimateContextTokens(messages): ContextUsageEstimate`
- `function shouldCompact(contextTokens, contextWindow, settings)`
- `function estimateTokens(message)`
- `function findTurnStartIndex(entries, entryIndex, startIndex)`
- `interface CutPointResult`
- `function findCutPoint(entries, startIndex, endIndex, keepRecentTokens)`
- `async function generateSummary(currentMessages, model, reserveTokens, apiKey, headers?, signal?, customInstructions?, previousSummary?, thinkingLevel?)`
- `interface CompactionPreparation`
- `function prepareCompaction(pathEntries, settings)`
- `async function compact(preparation, model, apiKey, headers?, customInstructions?, signal?, thinkingLevel?)`
- Re-exports `serializeConversation` from `utils.ts`

### 1.12 `harness/compaction/utils.ts`
- `interface FileOperations`
- `function createFileOps()`, `function extractFileOpsFromMessage(message, fileOps)`
- `function computeFileLists(fileOps)`
- `function formatFileOperations(readFiles, modifiedFiles)`
- `function serializeConversation(messages: Message[]): string`
  (used in summarization prompts; truncates `tool_result` text at 2 000 chars)

### 1.13 `harness/compaction/branch-summarization.ts`
- `interface BranchSummaryDetails`
- `interface BranchPreparation`
- `interface CollectEntriesResult`
- `interface GenerateBranchSummaryOptions`
- `async function collectEntriesForBranchSummary(session, oldLeafId, targetId)`
  (computes common ancestor, returns entries to summarize)
- `function prepareBranchEntries(entries, tokenBudget?)`
- `async function generateBranchSummary(entries, options)`

### 1.14 `harness/utils/shell-output.ts`
- `interface ShellCaptureOptions extends ExecutionEnvExecOptions`
- `interface ShellCaptureResult { output, exitCode, cancelled, truncated, fullOutputPath? }`
- `function sanitizeBinaryOutput(str)` (strips control chars)
- `async function executeShellWithCapture(env, command, options?)`
  (streams stdout+stderr through `onChunk`, ring-buffers tail output, spills
  full output to a temp file when output exceeds `DEFAULT_MAX_BYTES`)

### 1.15 `harness/utils/truncate.ts`
- Constants: `DEFAULT_MAX_LINES` (2 000), `DEFAULT_MAX_BYTES` (50 KB),
  `GREP_MAX_LINE_LENGTH` (500)
- `interface TruncationResult`, `interface TruncationOptions`
- `function formatSize(bytes)`
- `function truncateHead(content, options?): TruncationResult`
- `function truncateTail(content, options?): TruncationResult`
- `function truncateLine(line, maxChars?)`

### 1.16 `harness/env/nodejs.ts`
- `class NodeExecutionEnv implements ExecutionEnv` - Node-flavored `FileSystem +
  Shell` (uses `node:fs/promises`, `node:child_process` spawn with
  `detached`/`killProcessTree`, `crypto.randomUUID`, `tmpdir()`)

### 1.17 `harness/session/*`
- `class Session<TMetadata>` (252 LoC) with methods:
  - `getMetadata`, `getStorage`, `getLeafId`, `getEntry`, `getEntries`,
    `getBranch(fromId?)`, `buildContext`, `getLabel`, `getSessionName`,
    `appendMessage`, `appendThinkingLevelChange`, `appendModelChange`,
    `appendCompaction`, `appendCustomEntry`, `appendCustomMessageEntry`,
    `appendLabel`, `appendSessionName`, `moveTo`
- `function buildSessionContext(pathEntries): SessionContext`
  (reduces an entry-path to `{ messages, thinkingLevel, model }`, splicing in
  compaction summaries)
- `class JsonlSessionStorage implements SessionStorage<JsonlSessionMetadata>`
  (header version 3, durable `leaf` entries, label cache)
- `function loadJsonlSessionMetadata(fs, filePath)`
- `class JsonlSessionRepo implements JsonlSessionRepoApi`
  - `create(options)` - encodes `cwd` into a directory name, creates timestamp_id.jsonl
  - `open(metadata)`, `list(options?)`, `delete(metadata)`, `fork(source, options)`
- `class InMemorySessionStorage implements SessionStorage`
- `class InMemorySessionRepo implements SessionRepo`
- `repo-utils.ts`: `createSessionId`, `createTimestamp`, `toSession`,
  `getFileSystemResultOrThrow`, `getEntriesToFork` (handles `position: "before" | "at"`)
- `uuid.ts`: `uuidv7()` with monotonic sequence (custom, no external dep)

---

## 2. Surface mapping vs. pi-zig

### 2.1 Core orchestration

| Upstream | Pi-zig | Status |
|---|---|---|
| `class Agent` (stateful) | `agent.runPrompt()` (one-shot function) | **MISSING** as a class; the stateful instance, listeners, queue ownership, `waitForIdle`, `subscribe`, `reset`, `state` accessors, `prompt`/`continue` overloads, public mutable hook fields are not present. Pi-zig threads everything through `RunOptions` and per-call return values; the only stateful agent in pi-zig is `rpc.Runtime` (see 2.13). |
| `class AgentHarness` (995 LoC) | partial substitute via `rpc.Runtime` | **MISSING** as a separable layer. The runtime has overlapping responsibilities (session, queues, phases, hooks) but is bound to the RPC binary; it is not reusable by `cli.zig`, `cli_runtime.zig`, or any embedded consumer. |
| `agentLoop(...) => EventStream<AgentEvent, AgentMessage[]>` | `agent.runPrompt()` returning `RunResult` | **DEGRADED**. No event stream, no `agent_start`/`message_update`/`message_update.assistantMessageEvent` parity, no `tool_execution_update.partialResult`. Pi-zig emits a small subset via `LifecycleEmitCallback` (`turn_start`, `before_provider_request`, `after_provider_response`, `message_start`, `message_end`, `turn_end`, plus `agent_start`/`agent_end` synthesized at RPC level). |
| `agentLoopContinue(...)`, `runAgentLoopContinue(...)` | none | **MISSING**. Pi-zig has no equivalent: you cannot "continue" from a transcript whose last entry is a `user`/`toolResult` without re-issuing a prompt; retry paths run a fresh prompt via the RPC retry/recovery code. |
| `Agent.continue()` (drains steer→follow-up→continue order) | partial - `rpc.Runtime.drainQueuedMessages` | **DEGRADED**. The pi-zig RPC runtime drains steering→follow-up between turns but never as a public "continue" API. |
| `Agent.subscribe`/`Agent.processEvents` (await listeners, propagate `signal`) | none | **MISSING**. `LifecycleEmitCallback` is fire-and-forget, swallows errors, has no signal. |

### 2.2 Turn loop semantics

| Upstream behavior | Pi-zig | Status |
|---|---|---|
| Outer `while(true)` over follow-up queue; inner loop while `hasMoreToolCalls`/`pendingMessages` | Single inner loop with `max_turns`, no outer follow-up replay | **DEGRADED**. Pi-zig's `runPrompt` returns once the loop exhausts. RPC layers a follow-up drain on top by re-invoking `runAgentIfAuthenticated` per drained batch (see `rpc.zig` `runQueuedBatch`/`drainQueuedMessages`). Upstream does this inside `runLoop` so the same `Agent` instance/transcript stays coherent and external observers see the loop continue without restart. |
| `pendingMessages` injected as user messages **before** the next assistant request | Pi-zig RPC drains queues *between* `runPrompt` invocations | **DEGRADED**, indistinguishable in steady state but not callable from outside RPC. |
| Per-turn `prepareNextTurn({ message, toolResults, context, newMessages })` returning `{ context?, model?, thinkingLevel? }` | `prepare_next_turn` callback returning `{ system_prompt, provider, model, api_key }` | **DEGRADED**. Pi-zig replaces `system_prompt/provider/model/api_key` but does not let the callback swap whole `AgentContext.messages`/`tools` or `thinkingLevel`. Upstream context-rewriting (e.g. for branch summary injection between turns) is not expressible. |
| `shouldStopAfterTurn(...)` gate (return `true` to exit normally) | `should_stop_after_turn` callback | **PARITY** for the boolean result. Context shape differs (`turn_index`, `assistant_text`, `tool_results`, `system_prompt`, `provider`, `model`) and does not include `newMessages` or full `AgentContext`. |
| Terminate-batch: if every tool result in batch sets `terminate=true`, exit | `ToolResult.terminate` flag is plumbed, batch-terminate computed via `terminating_results == tool_calls.len` | **PARITY** for the gate logic. |
| Steering messages polled at loop start and after each turn (skips initial poll on `skipInitialSteeringPoll`) | RPC `drainQueuedMessages` polls only between `runPrompt` invocations | **DEGRADED**. No mid-turn steering injection inside a single `runPrompt`. |
| Failure path: emit `message_start`/`message_end`/`turn_end`/`agent_end` for a synthetic failure message | RPC layer constructs a failure assistant message and emits lifecycle equivalents via `writeRpcAgentEndEvent*` | **DEGRADED, RPC-only**. Pi-zig's `agent.runPrompt` returns errors as Zig errors; the failure-message lifecycle is duplicated in `rpc.zig` for the RPC path and again in JSON mode under `cli_runtime.zig`. There is no shared helper. |

### 2.3 Tool execution lifecycle

| Upstream | Pi-zig | Status |
|---|---|---|
| `ToolExecutionMode` (`"sequential" | "parallel"`) + per-tool `executionMode` override | none | **MISSING**. Pi-zig executes built-in tools strictly sequentially. There is no parallel preflight + concurrent execution, no source-order emission for `tool_execution_end` vs. tool-result messages. |
| `tool.prepareArguments` (raw JSON shim before schema validation) | `BeforeToolCallResult.arguments_json` reuses the before-tool-call hook to mutate args | **DEGRADED**. The replacement happens, but the upstream call order is `tool.prepareArguments` → `validateToolArguments` → `beforeToolCall`. Pi-zig has neither typebox validation nor a per-tool shim. |
| `validateToolArguments(tool, prepared)` (typebox) | none | **MISSING**. Pi-zig parses JSON ad hoc inside each tool. No schema-driven coercion or error message parity. |
| `beforeToolCall({ assistantMessage, toolCall, args, context }, signal?) => { block?, reason? }` | `BeforeToolCallCallback(ctx, call) => BeforeToolCallResult { block, reason, arguments_json }` | **DEGRADED**. No `assistantMessage` / `context` / `args` (validated) handed to the hook; no abort signal. The hook can mutate args (extra superset over upstream `block/reason`). |
| `afterToolCall({ ..., result, isError, context }, signal?) => { content?, details?, isError?, terminate? }` | `AfterToolCallCallback(ctx, call, result) => AfterToolCallResult { content, content_parts, is_error, terminate }` | **DEGRADED**. No `args` / `context` / `signal`, no `details` patch (pi-zig has no `details` field; only `content_parts`). `content_parts` is pi-zig-specific. |
| `tool.execute(toolCallId, params, signal?, onUpdate?) => AgentToolResult<T>` with streaming partials | Built-in tools are hard-coded functions in `agent.zig`; only `bash` calls back through `ToolUpdateCallback` (full snapshot, not `partialResult` shape) | **DEGRADED**. Other tools (read/write/edit/grep/find/ls) cannot stream progress. Extension-registered tools call a stateless `CustomToolCallback`. |
| Tool registration: `AgentTool<TParameters, TDetails>` with `name/label/description/parameters/prepareArguments/execute/executionMode` | `agent.ToolSet` (boolean toggles for builtins) + `RunOptions.custom_tools: []ChatToolDefinition` + `execute_custom_tool: CustomToolCallback` | **DEGRADED**. No `label`, no `details<T>`, no per-tool `executionMode`. Tool registration in pi-zig is bifurcated between hardcoded builtins and extension-only customs. |
| `AgentToolResult<T> { content, details, terminate? }` | `ToolExecutionResult { content, content_parts, is_error, terminate, arguments_json }` | **DEGRADED**. `details` field is missing - upstream uses it heavily for structured tool-result metadata that the UI consumes (and it survives session storage). |
| `tool_execution_update.partialResult: AgentToolResult` event | `ToolUpdate { content, is_error, terminate, truncated, full_output_path, truncation }` | **DEGRADED**. Pi-zig's update event carries different fields (shell-specific) and is fired only by bash. |
| Sequential vs. parallel ordering rules and event interleaving | n/a (always sequential) | **MISSING**. Document the divergence; upstream tests pin the ordering. |

### 2.4 Before/after hook semantics

Both hooks are surface-mapped above. Key behavioral differences:
- **Upstream hooks receive the `AbortSignal`** and can honor it. Pi-zig hooks
  must consult `RunOptions.should_cancel` themselves, and the agent loop only
  re-checks cancellation around hook calls, not inside them.
- **Upstream hooks receive `args` (validated)**. Pi-zig hands the raw
  `ChatToolCall` (which has only `arguments_json`).
- **Upstream `afterToolCall` can return `details` overrides**. Pi-zig has no
  `details` field, so the structured metadata upstream extensions return (e.g.
  the bash truncation block, file-operation lists) is not patchable.

### 2.5 Prepare-next-turn

| Upstream | Pi-zig |
|---|---|
| `prepareNextTurn(context) => AgentLoopTurnUpdate \| undefined` returning `{ context?, model?, thinkingLevel? }`. The loop replaces the active context wholesale (`currentContext = nextTurnSnapshot.context ?? currentContext`) and updates `reasoning`. | `prepare_next_turn(ctx, turn) => PrepareNextTurnResult { system_prompt, provider, model, api_key }`. Only those four scalars can change; the message ring and tool list are immutable across the run. |

This affects two real upstream workflows pi-zig cannot do mid-run:
1. Re-resolving the system prompt from a `systemPrompt` callback per turn
   (upstream `AgentHarness.createTurnState`).
2. Swapping the active tool list between turns (e.g. enabling a fresh tool
   after `bash` introduces a file).

### 2.6 Should-stop-after-turn

The boolean gate is **PARITY** for top-level intent (return `true` to stop
before another provider request). Differences:
- Upstream emits `agent_end` and returns; pi-zig sets `stopped_after_turn:
  true` on `RunResult` and returns. RPC consumers must translate.
- Upstream context includes `newMessages` (loop-relative); pi-zig's
  `TurnContext` does not.

### 2.7 Cancellation propagation

| Upstream | Pi-zig |
|---|---|
| Single `AbortSignal` threaded through the stream call, every hook, every tool `execute`, every `getSteeringMessages`/`getFollowUpMessages`. `signal.aborted` is polled before each tool call in both sequential and parallel paths. The proxy stream cancels the fetch reader on abort. The harness `abort()` calls `runAbortController?.abort()` and `waitForIdle()`. | `RunOptions.should_cancel: CancellationCallback` + `cancellation_context: ?*anyopaque`. `checkCancellation()` is polled at loop boundaries, before/after tool execution, and threaded into `ai_client` (`ChatTurnRequest.should_cancel`/`cancellation_context`). RPC's `ActivePromptJob` exposes `requestCancel()` and a retry-sleep cancel path. **Hard socket-level cancellation while blocked inside Zig 0.16 `std.http` is not possible** (documented limitation in `docs/parity.md`). |

**Status: DEGRADED but explicitly bounded by platform**. The cooperative
checkpoints are reasonable; the missing piece is signal propagation **into the
hook callbacks** and into `getSteeringMessages`/`getFollowUpMessages`.

### 2.8 Retry classification

| Upstream | Pi-zig |
|---|---|
| Retry is owned by `streamSimple`/`completeSimple` in `@earendil-works/pi-ai`. The agent package only forwards `maxRetries`, `maxRetryDelayMs`, and `transport` via `SimpleStreamOptions`. | Retry orchestration lives in `rpc.zig` (`runAgentIfAuthenticated` loop): provider error classification (`isContextOverflowAgentError`, `isRetryableAgentError`), exponential backoff with base/max delay, `auto_retry_start`/`auto_retry_end`/`agent_end.willRetry` event emission, `abort_retry` to cancel a delay. Provider-body error text classifier lives in `ai_client.zig` (`isRetryableProviderErrorText`, `isContextOverflowErrorText`, `isKnownNonOverflowProviderErrorText`). |

**Status: DIVERGED**. Pi-zig has retry support but at a different layer (RPC,
not the agent loop). The classifier behavior is unit-tested
(`docs/parity.md` line 23 enumerates the assertions). Embeddable consumers
that do not route through RPC get **no retry behavior at all** — this is a
real functional gap for any pi-zig-as-library use case.

### 2.9 Image handling and content parts

| Upstream | Pi-zig |
|---|---|
| `ImageContent` block on user / tool-result / assistant content arrays. Tool results may return mixed text/image content. The harness has no special image handling - it passes parts through to the provider. Resizing/downscaling is handled by the application or by `@earendil-works/pi-ai` if at all. | `ai_client.ChatContentPart` is a `union(enum) { text, image }`. Tool results carry `content_parts` alongside `content`. Image resizing has only an **encoded-size gate**: oversized inline images (>4.5 MB base64) are omitted with a placeholder note (`image_resize_omitted_note`), with the gate controlled by `RunOptions.auto_resize_images`. Pi-zig has no Photon-equivalent decoder. Non-vision models get the `non_vision_image_note` placeholder appended. |

**Status: DIVERGED**. The data model is **parity-equivalent**; the resize
worker is a documented absence (pi-zig can't downscale, only gate). The
provider-side serialization (OpenAI-compatible, Anthropic, Google, Mistral,
Bedrock, Vertex) is byte-equivalent to upstream per the parity ledger.

### 2.10 Content parts in messages

| Upstream | Pi-zig |
|---|---|
| `AgentMessage = Message | CustomAgentMessages[keyof CustomAgentMessages]`. `Message.content` is `(TextContent | ImageContent)[]` for users, mixed content blocks for assistants, mixed for tool results. Custom messages defined via declaration merging: `BashExecutionMessage`, `CustomMessage`, `BranchSummaryMessage`, `CompactionSummaryMessage`. | `ai_client.ChatMessage` has a flat `content: []const u8` plus optional `content_parts: []ChatContentPart` plus `tool_calls`/`tool_call_id` fields. There is **no discriminated union of message roles** mirroring upstream's `CustomAgentMessages`. RPC's `StoredMessage` carries `role: enum { user, assistant, tool, system, bash_execution, custom, custom_entry, compaction_summary, ... }` (see `session.zig`/`rpc.zig`), wider than `ChatRole` and storage-only. |

**Status: DIVERGED**. The on-wire content is byte-compatible at the provider
boundary; the internal type system is incompatible with upstream consumers.

### 2.11 Message persistence handoff

Upstream `runAgentLoop` does NOT persist messages — it returns `newMessages`
and the **harness** (`agent-harness.ts:handleAgentEvent`) listens for
`message_end` and calls `session.appendMessage(event.message)`. Pending
mutations queue into `pendingSessionWrites` and flush at `turn_end` and
`agent_end` save points.

Pi-zig's `agent.runPrompt` also does not persist; it returns
`RunResult { final_text, tool_call_batches, tool_results, ... }`. **The
caller is responsible for persistence**. In practice the caller is `rpc.zig`
(via `addAgentResultMessages` → `appendMessage`/`appendToolResult`/etc) or
`cli_runtime.zig` for top-level JSON/print. No harness-shaped save-point
abstraction exists; persistence is inlined per caller.

**Status: DEGRADED**. The contract works because there are only two callers,
both in-tree. An external consumer cannot rely on lifecycle save points and
pending-write ordering the way `AgentHarness` provides them.

### 2.12 Provider abstraction (StreamFn)

| Upstream | Pi-zig |
|---|---|
| `StreamFn = (...args of streamSimple) => ReturnType | Promise<ReturnType>`. The `Agent` exposes `streamFn` as a public mutable field; callers can install `streamProxy` or any custom function. The contract requires it to encode failures as protocol events plus a final assistant message, **not throw**. | The provider is hardcoded inside `ai_client.zig` (`runChatTurn`, `streamChatTurn*`, provider-specific functions like `runAnthropicMessagesTurn`, `runGoogleGenerateContentTurn`, etc.). `RunOptions` has `provider` (string), `model` (string), `api_key` — no pluggable stream function. |

**Status: MISSING**. Pi-zig cannot accept a custom provider implementation
(e.g. a proxy backend, an in-test mock) the way upstream can. Tests use the
real `ai_client` plus a fake HTTP server (see `frontend/fake-provider.mjs`,
`scripts/flow-*-smoke.mjs`). Embedding pi-zig with a custom stream pipe is
not currently a supported integration.

### 2.13 RPC substitute layer

Pi-zig's `src/pi/rpc.zig` (5 256 LoC) is a partial substitute for the upstream
`AgentHarness`. Mapping:

| AgentHarness feature | rpc.Runtime equivalent |
|---|---|
| `prompt(text)` | `handlePromptCommand` / `startPromptAsync` |
| `steer(text)`, `followUp(text)` | `enqueuePendingMessage` into `steering_queue` / `follow_up_queue` |
| `nextTurn(text)` | `next_turn_custom_queue` enqueue (custom messages only - the text-prompt nextTurn for top-level CLI is documented as not yet wired, see `docs/parity.md` line 15) |
| `compact(customInstructions?)` | `writeCompactResponse`, `performCompaction` (LLM-driven + static fallback) |
| `navigateTree(targetId, options?)` | `navigate_tree` command → `navigateTree` / `navigateTreeWithSummary` |
| `getModel()/setModel`, `getThinkingLevel()/setThinkingLevel` | `set_model`, `set_thinking_level`, `cycle_model`, `cycle_thinking_level` |
| `setSteeringMode`, `setFollowUpMode` | `set_steering_mode`, `set_follow_up_mode` |
| `abort()` | `abort` command (+ `abort_bash`, `abort_retry`) |
| `appendMessage(message)` | implicit via `addAgentResultMessages` per turn |
| `subscribe(listener)` / events | RPC commands stream JSONL events (`agent_start`, `turn_start`, `before_provider_request`, etc.) via `emitLifecycleNotify`; consumers see them on the RPC pipe |
| Phases (`idle/turn/compaction/branch_summary/retry`) | not explicit; concurrent operations are gated through mutex + active-job pointers |
| Pending session writes / save points | implicit; pi-zig writes are append-only and durable each call |

**Status: in-tree only**. A pi-zig consumer that wants harness semantics
either spawns `pi-zig rpc <session-file>` as a child process and speaks NDJSON
(this is what the Preact workbench does) or has nothing to embed. The
upstream package is consumable as `import { Agent, AgentHarness } from
"@earendil-works/pi-agent-core"`; pi-zig has no equivalent library surface.

### 2.14 Compaction

Pi-zig has a port of compaction inside `rpc.zig` and `session.zig`:

| Upstream | Pi-zig |
|---|---|
| `DEFAULT_COMPACTION_SETTINGS = { enabled: true, reserveTokens: 16384, keepRecentTokens: 20000 }` | `default_auto_compaction_reserve_tokens = 16384` (see `rpc.zig`); `keepRecentTokens` equivalent not exposed |
| `SUMMARIZATION_SYSTEM_PROMPT` and `SUMMARIZATION_PROMPT` (exact text) | `compaction_summarization_system_prompt` and `compaction_summarization_prompt` constants (text matches per parity ledger) |
| `UPDATE_SUMMARIZATION_PROMPT` (for prior-summary updates) | **MISSING** (pi-zig's compaction always generates a fresh summary from kept entries, even when a prior summary exists; the `previousSummary` plumbing in `compaction.ts:generateSummary` is not implemented) |
| `TURN_PREFIX_SUMMARIZATION_PROMPT` (split-turn handling) | **MISSING** (pi-zig's `findCutPoint` always cuts at a `user` boundary; split-turn prefix summarization is not implemented) |
| `prepareCompaction(entries, settings)` → `CompactionPreparation` | `performCompaction` does the prep+summarize+persist in one call inside `rpc.zig`; there is no reusable preparation step exposed |
| `compact(preparation, model, apiKey, headers?, customInstructions?, signal?, thinkingLevel?)` | `performCompaction` (RPC-internal) |
| `calculateContextTokens`, `getLastAssistantUsage`, `estimateContextTokens`, `estimateTokens`, `shouldCompact`, `findTurnStartIndex`, `findCutPoint` | `estimateTokensBeforeCompaction` (single function in rpc.zig), no separate cut-point/turn-start helpers |
| `CompactionDetails { readFiles, modifiedFiles }` | `CompactionProvider { provider, model }` (different shape; pi-zig stores provider metadata for "LLM-driven" provenance instead of read/modified-files) |
| `formatFileOperations(readFiles, modifiedFiles)` (appends `<read-files>`/`<modified-files>` blocks to the summary) | **MISSING** in pi-zig; the file-op tracking and summary append are not ported |
| Auto-compaction trigger (`shouldCompact` before each prompt) | `maybeAutoCompactBeforePrompt` in `rpc.zig` (FLOW_H_AUTO_COMPACTION) |
| Context-overflow recovery (re-compact + retry on provider context-window-exceeded error) | `runAgentIfAuthenticated` overflow recovery branch (single-attempt) |
| `serializeConversation(messages)` (2 000-char tool-result truncation) | implemented inline in rpc.zig per parity ledger |

**Status: DEGRADED**. Auto-compaction triggers and the overall pipeline are
ported; split-turn handling, prior-summary updates, and the read/modified-files
metadata are not.

### 2.15 Branch summarization

| Upstream | Pi-zig |
|---|---|
| `collectEntriesForBranchSummary(session, oldLeafId, targetId)` (common-ancestor walk) | implemented in `rpc.zig` `navigateTreeWithSummary` (partial - the abandoned-branch walk is there, but it does not expose the common ancestor) |
| `prepareBranchEntries(entries, tokenBudget?)` | not separable; inlined |
| `generateBranchSummary(entries, options)` returning `BranchSummaryResult { summary, readFiles, modifiedFiles }` | inline in `rpc.zig` (single function call, persists via `appendBranchSummary`) |
| `BRANCH_SUMMARY_PREAMBLE` + `BRANCH_SUMMARY_PROMPT` | `branch_summary_prompt` constant in `rpc.zig` (text matches per parity ledger; preamble is appended inline) |

**Status: DEGRADED**. The feature works end-to-end (parity ledger flow E) but
is not a reusable helper, and the read/modified-files details are not stored.

### 2.16 Session storage and repos

| Upstream | Pi-zig |
|---|---|
| `interface SessionStorage<TMetadata>` (abstract) | `session.PersistentStore` (concrete struct, fixed-size buffers) |
| `interface SessionRepo<...>` (abstract, `create/open/list/delete/fork`) | no abstraction; `session.zig` provides `forkFromFile`, `findMostRecentSession`, `findSessionByIdPrefix`, `newSessionPath` as free functions |
| `class JsonlSessionStorage` (uses version-3 header, `leaf` entries, label cache) | `session.PersistentStore` writes a version-3 header and processes leaf entries; label cache is **missing** (no `appendLabel`/`getLabel` in pi-zig session storage — see 2.17) |
| `class JsonlSessionRepo` (encodes cwd to dirname, list directories, fork with `entryId`/`position`/`id`) | `forkFromFile` works on full file paths only; no cwd-indexed session directory (parity ledger lists `sessionDir` resolution in settings, but `JsonlSessionRepo.encodeCwd` is not ported) |
| `class InMemorySessionStorage` / `InMemorySessionRepo` | **MISSING**. Pi-zig has no in-memory session backend (all sessions write a real JSONL file; tests use temp files). |
| `Session<TMetadata>` (rich API: `getEntry`, `getEntries`, `getBranch`, `buildContext`, `getLabel`, `getSessionName`, `appendThinkingLevelChange`, `appendModelChange`, `appendCompaction`, `appendCustomEntry`, `appendCustomMessageEntry`, `appendLabel`, `appendSessionName`, `moveTo`) | `session.PersistentStore` covers most of these but with different shapes. `appendLabel` and `appendSessionName` are **partially implemented** (session naming is via `set_session_name` RPC; label entries are NOT supported by the pi-zig store loader). |
| `buildSessionContext(pathEntries)` reducer | `rpc.Runtime.loadSessionEntries` is the equivalent reduction, but it lives inside the RPC runtime and is not exposed as a pure helper |
| `getEntriesToFork(storage, { entryId?, position? })` | `forkFromFile` accepts only the full source file path; `position: "before" | "at"` semantics are inlined in `rpc.zig.forkSession` (only "before" - the `"at"` mode is not exposed). |
| `uuidv7()` (custom monotonic) | not directly used; pi-zig generates entry IDs via a numeric counter (`PersistentStore.nextEntryId`), not UUID v7. |

**Status: DEGRADED**. Pi-zig sessions support reload, fork, clone, navigation,
compaction, branch summary, custom-message entries, and custom-data entries —
the durable feature set is broadly equivalent. But the in-memory storage, the
abstract storage/repo interfaces, the `Label` entry shape, and `uuidv7` are
missing, so external embedding cannot supply alternative session backends.

### 2.17 Session entry types

Upstream `SessionTreeEntry` is a discriminated union of 10 variants. Pi-zig
parses entries by string-matching the `type` field in
`session.PersistentStore.loadExisting` and produces internal `StoredMessage`
records. Coverage:

| Upstream entry type | Pi-zig | Notes |
|---|---|---|
| `message` (with embedded `AgentMessage`) | yes | union of internal roles |
| `thinking_level_change` | yes | `appendThinkingLevelChange` |
| `model_change` | yes | `appendModelChange` |
| `compaction` | yes | `appendCompaction` (with optional provider meta) |
| `branch_summary` | yes | `appendBranchSummary` |
| `custom` | yes | `appendCustomEntry` / `appendCustomEntryRawJson` |
| `custom_message` | yes | `appendCustomMessage` (RPC-level) |
| `label` | **MISSING** | pi-zig does not write or load `label` entries; the upstream label-cache invalidation feature is not present |
| `session_info` | partial | `appendSessionName` writes a `session_info`-shaped row, but the `name` field is the only one used; the upstream "legacy" backward-compat semantics may not all match |
| `leaf` | yes | leaf moves are durable |

**Status: DEGRADED** — labels are the visible gap (the upstream TUI uses
labels to mark session-tree nodes; pi-zig has no equivalent).

### 2.18 Skills and prompt templates

| Upstream | Pi-zig | Status |
|---|---|---|
| `loadSkills(env, dirs)` walks directories, finds `SKILL.md`, applies `.gitignore`/`.ignore`/`.fdignore`, validates name+description, returns `{ skills, diagnostics }` | `commands.zig` enumerates skill paths (`discoverSkills` in `commands.zig`) but does not run frontmatter validation, does not honor every ignore-file class, and does not produce structured diagnostics matching upstream codes | **DEGRADED** |
| `loadPromptTemplates(env, paths)` (.md files, frontmatter parse, diagnostics) | `commands.zig` `expandPromptTemplateFile` reads a single file on demand, plus `parseTemplateArgs` (upstream parity per ledger line 16 + `commands.zig` comments) | **DEGRADED** — pi-zig loads templates lazily on slash-command expansion rather than batching+returning diagnostics |
| `formatSkillsForSystemPrompt(skills)` (XML block) | `system_prompt.zig:appendSkills` (equivalent rendering, parity by inspection) | **PARITY** |
| `formatSkillInvocation(skill, additionalInstructions?)` (`<skill>` wrapper for system prompt) | `commands.zig` rebuilds the skill wrapper inline during slash expansion (parity ledger lines 16-26 cite the upstream format) | **PARITY (inlined)** |
| `formatPromptTemplateInvocation(template, args?)` | `commands.zig` `expandPromptTemplateFile`/`substituteArgs` | **PARITY (inlined)** |
| `parseCommandArgs`, `substituteArgs` | `commands.zig` exports these by the same logic (parity ledger calls them "matches upstream parseCommandArgs/substituteArgs") | **PARITY** |
| `Skill { name, description, content, filePath, disableModelInvocation? }` | `system_prompt.Skill { name, description, file_path, disable_model_invocation }` — **content is not held in memory**; pi-zig reads it on demand | **DEGRADED** — pi-zig's `Skill` does not carry `content`; consumers must re-read the file. |
| `PromptTemplate { name, description?, content }` | **MISSING as a struct** (pi-zig parses templates lazily and does not represent them as objects in memory) |
| `loadSourcedSkills`, `loadSourcedPromptTemplates` (typed `source` provenance) | **MISSING** |
| `SkillDiagnostic`, `PromptTemplateDiagnostic` | **MISSING** | structured diagnostic codes are not produced |

### 2.19 Truncation, shell capture

| Upstream | Pi-zig | Status |
|---|---|---|
| `DEFAULT_MAX_LINES` (2000), `DEFAULT_MAX_BYTES` (50 KB), `GREP_MAX_LINE_LENGTH` (500) | matching constants in `tools.zig` (`default_read_max_lines=2000`, `default_read_max_bytes=50*1024`, `default_bash_max_lines=2000`, `default_bash_max_bytes=50*1024`, `grep_max_line_chars=500`) | **PARITY (constants)** |
| `truncateHead`, `truncateTail`, `truncateLine` with `TruncationResult { content, truncated, truncatedBy, totalLines, totalBytes, outputLines, outputBytes, lastLinePartial, firstLineExceedsLimit, maxLines, maxBytes }` | `tools.zig:truncateHead`, `truncateTail` return a `Truncation` struct with subset fields; `lastLinePartial`/`firstLineExceedsLimit` are not present, and the API is private (no equivalent of `formatSize`) | **DEGRADED** |
| `formatSize(bytes)` | **MISSING** | |
| `sanitizeBinaryOutput(str)` (filter C0 control chars, keep tab/LF/CR, skip annotation U+FFF9..U+FFFB) | `tools.zig:sanitizeShellOutput` (different impl, sanitizes ANSI + control bytes for shell output specifically) | **DEGRADED — different shape** |
| `executeShellWithCapture(env, command, options)` returning `{ output, exitCode, cancelled, truncated, fullOutputPath? }` with ring-buffered tail and temp-file overflow | `tools.zig:runShellCaptureWithUpdates` returning `ShellResult { output, exit_code, cancelled, truncated, full_output_path, truncation }` (writes full output to `zig-out/pi-zig-bash-full-output.log`, the **same fixed path every time** rather than a per-run temp file) | **DEGRADED** — pi-zig uses a fixed log path rather than `createTempFile`/`appendFile` (upstream uses a per-run temp file). Two concurrent bash tools would overwrite each other's logs in pi-zig. |

### 2.20 Execution environment abstraction

| Upstream | Pi-zig |
|---|---|
| `interface FileSystem` (14 methods returning `Result<T, FileError>` with stable error codes `not_found`/`permission_denied`/...), `interface Shell` (`exec` returning `Result<{stdout, stderr, exitCode}, ExecutionError>`), `interface ExecutionEnv extends FileSystem, Shell` | none |
| `class NodeExecutionEnv` (Node-flavored implementation with `spawn` + `killProcessTree` + temp files via `mkdtemp(tmpdir())` + `crypto.randomUUID`) | direct calls to `std.Io.Dir`, `std.process.Child`, `std.posix`, `std.fs.cwd()` throughout `tools.zig` |
| `FileError { code, path?, cause? }`, `ExecutionError { code, cause? }` | Zig errors (`anyerror`) |

**Status: MISSING**. The `ExecutionEnv` indirection is gone; tools call Zig
stdlib directly. This makes the harness untestable with a fake filesystem
without monkey-patching, and prevents alternate execution environments
(remote, sandboxed) from being plugged in.

### 2.21 Result<T,E> error model and typed error codes

Upstream uses `Result<T,E>` for "expected failures" (filesystem ops, shell
ops, resource loading, compaction, branch summarization) and throws/rejects
for high-level orchestration (`AgentHarness`, `Session` mutations). Five
named error classes (`AgentHarnessError`, `SessionError`, `CompactionError`,
`BranchSummaryError`, `FileError`, `ExecutionError`) with stable union-of-strings
error codes.

Pi-zig uses Zig's `anyerror` (and named error sets in specific spots like
`ai_client.ChatCompletionError`). There is no `Result<T,E>` analog and no
stable error-code surface for upstream-parity error classification. Consumers
that need to discriminate (e.g. extension UIs that decide whether to retry,
prompt for re-auth, etc.) must rely on `@errorName` string matching, which
the parity ledger does in places (`isContextOverflowAgentError`,
`isRetryableAgentError`).

**Status: MISSING**. This is a structural divergence between idiomatic Zig
and the upstream TS surface; converting wholesale would change every pi-zig
function signature. The functional gap is the inability for an external
consumer to discriminate error classes the way `instanceof AgentHarnessError`
or `error.code === "auth"` allows in TS.

### 2.22 Public-API doc surface

Upstream `packages/agent/docs/` contains 4 design notes
(`agent-harness.md`, `durable-harness.md`, `hooks.md`, `observability.md`).
Pi-zig does not have a corresponding `docs/agent-harness.md` design note;
parity tracking is in `docs/parity.md` and `docs/12-agent-implementation-wave.md`.

---

## 3. Gap detail per item with complexity

Complexity legend: **Low** = mechanical port / small struct rename;
**Medium** = moderate refactor or new abstraction with cross-cutting impact;
**High** = touches every consumer or requires platform features pi-zig lacks.

| # | Gap | Complexity | Notes |
|---|---|---|---|
| 1 | `Agent` class abstraction (stateful wrapper) | **High** | Touches `agent.zig`, every caller (`cli_runtime.zig`, `rpc.zig`), and the test suite. Public mutable hook fields + `subscribe` + `waitForIdle` + `state` accessor + `prompt`/`continue` overloads + listener-await behavior is a serious API. |
| 2 | `AgentHarness` class abstraction | **High** | 995 LoC upstream. Subsumes session, queues, phases, save-points, pending writes, hooks, abort behavior. Pi-zig's `rpc.Runtime` covers most behaviors for the RPC path only; turning it into a reusable harness would require pulling out session/queue/phase concerns into a generic Zig type. |
| 3 | `EventStream<AgentEvent, AgentMessage[]>` shape | **Medium** | Pi-zig's `LifecycleEmitCallback` is fire-and-forget. Building a proper event stream with `push`/`end`/`result()` + back-pressure + listener-await + signal propagation is a structural change to the loop. |
| 4 | `agentLoopContinue` / `runAgentLoopContinue` | **Medium** | Requires a "continue from last `toolResult`/`user` message" entry point. Pi-zig's current shape always starts a new prompt; the continue path would need to re-enter the loop without emitting `message_start`/`message_end` for an existing prompt. |
| 5 | `prepareNextTurn` returning `{ context?, model?, thinkingLevel? }` (full context swap, not just system prompt) | **Medium** | Loop already calls a `prepare_next_turn` hook. Extending the return type to swap whole `messages`/`tools`/`thinkingLevel` requires audit of the borrowed-messages lifetime in `runPrompt`. |
| 6 | `shouldStopAfterTurn` context shape parity (`message`, `toolResults`, `context`, `newMessages`) | **Low** | Mechanical addition. |
| 7 | Tool-execution-mode (`sequential` vs `parallel`) + per-tool override | **High** | Pi-zig has no concurrency primitives in the agent loop; would require a Zig threadpool or coroutine model. Parallel tool execution semantics (preflight sequential, execute concurrent, `tool_execution_end` in completion order, message artifacts in source order) is intricate. |
| 8 | `tool.prepareArguments` + `validateToolArguments` (typebox-equivalent schema validation) | **High** | Pi-zig has no JSON-schema validator. Building one matching typebox semantics is large; alternative is `--tools` consumers writing manual JSON parsing (already done). |
| 9 | Before/after tool hooks receiving `signal`, `args` (validated), `context`, `details` patch | **Medium** | Extends existing callback shape; touches `rpc.zig`/`extension_runner.zig` extension bindings. |
| 10 | `tool.execute(toolCallId, params, signal?, onUpdate?)` signature with streaming partials | **Medium** | Pi-zig's bash tool already streams via `ToolUpdateCallback`; extending to all tools and giving extensions a streaming-update channel requires a new callback shape on `CustomToolCallback`. |
| 11 | `AgentToolResult<T> { content, details, terminate? }` with `details` channel | **Medium** | Adding an opaque `details` field to `ToolResult` + persisting it in session storage + exposing in JSON/RPC events + threading through every tool wrapper. |
| 12 | `Agent.continue()` queue-priority semantics (steer-then-followup-then-error) | **Low** | RPC already does this; would need to expose it on a re-usable `Agent` API. |
| 13 | `proxy.ts` (`streamProxy` / `ProxyAssistantMessageEvent`) | **Medium** | Requires implementing a remote-stream protocol in `ai_client.zig`. Useful for embedding pi-zig behind a server. |
| 14 | Pluggable `StreamFn` | **High** | Pi-zig's `ai_client.zig` is hardcoded; making the agent loop call through a function pointer to a swappable provider is invasive (every provider-specific function would need to live behind the abstraction). |
| 15 | `convertToLlm` callback (custom-message → LLM-message mapping) | **Medium** | Pi-zig currently does the conversion inline per RPC role (see `appendStoredHistoryMessage`). Exposing it as a `RunOptions` callback is a refactor of how `runPrompt` builds its `borrowMessages` view. |
| 16 | `transformContext` callback (pre-`convertToLlm` AgentMessage transform) | **Medium** | Same as above; useful for context pruning, external context injection. |
| 17 | `BashExecutionMessage`, `CustomMessage`, `BranchSummaryMessage`, `CompactionSummaryMessage` declarations | **Low** | Pi-zig already stores these as session-tree entry kinds; exposing them as message-role variants is essentially a header file. |
| 18 | `Skill.content` held in memory at load time | **Low** | Trivial to add a content field; today pi-zig reads on demand. |
| 19 | `PromptTemplate` struct held in memory | **Low** | Same as above. |
| 20 | `loadSkills`/`loadPromptTemplates` returning structured `{ items, diagnostics }` with stable codes | **Medium** | Touches `commands.zig` discovery; existing pi-zig discovery is functional but does not surface every upstream diagnostic. |
| 21 | `loadSourcedSkills`/`loadSourcedPromptTemplates` (provenance tagging) | **Low** | Add a generic `source` param. |
| 22 | `formatSkillsForSystemPrompt` parity rendering | **n/a** | Already in `system_prompt.zig`. |
| 23 | `formatSkillInvocation` / `formatPromptTemplateInvocation` / `substituteArgs` / `parseCommandArgs` | **n/a** | Already in `commands.zig`. |
| 24 | `truncateHead`/`truncateTail`/`truncateLine` returning the rich `TruncationResult` | **Low** | Add the extra fields (`lastLinePartial`, `firstLineExceedsLimit`, `maxLines`, `maxBytes`). |
| 25 | `formatSize(bytes)` | **Low** | One function. |
| 26 | `sanitizeBinaryOutput(str)` (the upstream variant) | **Low** | Mechanical. |
| 27 | `executeShellWithCapture` with per-run temp file (instead of fixed `bash-full-output.log`) | **Low** | Real bug-class issue today: two parallel bash tools clobber each other's full-output log. |
| 28 | `ExecutionEnv` abstraction (FileSystem + Shell with `Result<T,E>` returns + stable error codes) | **High** | Touches every tool in `tools.zig` plus `session.zig`. Foundational change. |
| 29 | `Result<T,E>` analog + named error classes with stable codes | **High** | Pi-zig idiom is Zig error sets. Building TS-equivalent stable error codes requires touching every public function. Probably not done wholesale; pick specific subsystems (`SessionError`, `CompactionError`). |
| 30 | `SessionStorage<T>` / `SessionRepo<T>` abstract interfaces | **High** | Pi-zig couples session shape and storage. Abstracting requires generic types and a fork of `session.zig`. |
| 31 | `InMemorySessionStorage` / `InMemorySessionRepo` | **Medium** | After 30, this is a separate concrete struct. Useful for tests. |
| 32 | `JsonlSessionRepo` (cwd-indexed directories, `encodeCwd`, list across cwds, fork with `entryId`/`position`/`id`) | **Medium** | Pi-zig discovers sessions by directory listing (`findMostRecentSession`/`findSessionByIdPrefix`) but does not encode cwd into a subdir. Touches `session.zig` + RPC + CLI. |
| 33 | `Session.appendLabel` / `getLabel` + `LabelEntry` persistence | **Medium** | Pi-zig session loader does not parse `label` entries; would need a new entry kind plus a label cache in `PersistentStore`. |
| 34 | `uuidv7()` (monotonic per-process UUID) | **Low** | Pi-zig uses a numeric counter; switching to UUID v7 is a small file. Behavior-equivalent across resumes is the bigger concern (UUIDs must remain stable). |
| 35 | `getEntriesToFork(storage, { position: "at" })` | **Low** | Pi-zig's fork only supports "before"; add the `at` mode. |
| 36 | `compact()` taking a `CompactionPreparation` (separable preparation) | **Medium** | Today `performCompaction` runs prep+summarize+persist in one step. Splitting requires hoisting the cut-point/turn-start logic out. |
| 37 | `UPDATE_SUMMARIZATION_PROMPT` (prior-summary updates) | **Low** | Add the prompt and branch in `performCompaction`. |
| 38 | `TURN_PREFIX_SUMMARIZATION_PROMPT` + split-turn handling | **Medium** | Touches the cut-point logic. |
| 39 | `CompactionDetails { readFiles, modifiedFiles }` + `formatFileOperations` summary footer | **Medium** | Requires tracking file-ops across summarized history (`createFileOps`, `extractFileOpsFromMessage`, `computeFileLists`). |
| 40 | `generateBranchSummary` returning `BranchSummaryResult { summary, readFiles, modifiedFiles }` | **Low** | After 39, mirror the same structure. |
| 41 | `AgentHarness` own events (`queue_update`, `save_point`, `abort`, `settled`, `before_agent_start`, `context`, `before_provider_request`, `before_provider_payload`, `after_provider_response`, `tool_call`, `tool_result`, `session_before_compact`, `session_compact`, `session_before_tree`, `session_tree`, `model_select`, `thinking_level_select`, `resources_update`) | **High** | 17 distinct events with hook-result types and an `on(type, handler)` per-event registration. RPC partially emits a subset (`emitLifecycleNotify`, `emitSessionStart`, `emitUserBash`) but the result-merging behavior of upstream `on(type, ...)` is not present. |
| 42 | `AgentHarnessPhase` (`idle`/`turn`/`compaction`/`branch_summary`/`retry`) + structural-op gating | **Medium** | Pi-zig already implicitly gates via the active-prompt pointer; making phases explicit and exposing them on a getter is a small refactor. |
| 43 | Pending session writes / save-point flush | **Medium** | RPC currently writes inline; durable queueing of writes accepted during a run with deterministic ordering at save points is missing. |
| 44 | `nextTurn` for top-level CLI (text-prompt one-shot queue) | **Low** | Documented limitation in parity ledger; visible top-level rejection today. |
| 45 | Listener `signal` propagation + listener-await for run settlement | **Medium** | Pi-zig lifecycle emitters swallow errors; upstream lets a hook participate in the run lifetime. |
| 46 | Provider HTTP socket cancellation while blocked inside `std.http` | **Platform-blocked** | Documented in `docs/parity.md`; not a port gap, a Zig 0.16 stdlib limitation. |
| 47 | `getApiKey?: (provider) => Promise<string|undefined>` (dynamic per-request key resolution) | **Medium** | Pi-zig's `auth.zig` resolves once before the run starts. Threading per-request resolution would touch `ai_client.zig` request setup. |
| 48 | `thinkingBudgets: ThinkingBudgets` forwarded to stream | **Low** | Add the field to `RunOptions` and forward through `ai_client`. |
| 49 | `cacheRetention` / `metadata` / per-request headers (in `SimpleStreamOptions`) | **Low** | Mostly already plumbed; expose on `RunOptions`. |
| 50 | `AgentMessage = Message | CustomMessage` typed union with declaration merging | **n/a (Zig idiom)** | Cannot replicate TS declaration-merging directly. Pi-zig's `StoredMessage.role` enum is the existing substitute. |

---

## 4. Estimated parity

Counting only what is actually implemented vs. the upstream public surface
(types, functions, classes, events) of `packages/agent`:

| Bucket | Upstream items | Pi-zig has | %  |
|---|---:|---:|---:|
| Core `Agent` class API (`prompt`/`continue`/`steer`/`followUp`/`abort`/`waitForIdle`/`subscribe`/`reset`/`state`/...) | 21 | RPC-substitute for ~14 | ~67 % |
| `agentLoop` / `agentLoopContinue` / `runAgentLoop`+continue | 4 | 1 (`runPrompt`) | 25 % |
| `AgentLoopConfig` callbacks (10) | 10 | 6 (no `convertToLlm`, no `transformContext`, no `getApiKey`, no parallel tool execution) | 60 % |
| `AgentEvent` variants (9) | 9 | ~6 (no `message_update.assistantMessageEvent`, no `tool_execution_update.partialResult` shape, no `agent_start`/`agent_end` from the loop itself) | ~65 % |
| `AgentHarness` class API (~28 methods) | 28 | RPC-substitute for ~22 | ~78 % (RPC-only) |
| `AgentHarness` own events (17) | 17 | RPC emits ~5 | ~30 % |
| `proxy.ts` (`streamProxy`) | 1 | 0 | 0 % |
| `harness/messages.ts` (message constructors + `convertToLlm` + constants) | 8 | 4 (inline in rpc.zig, not as helpers) | 50 % |
| `harness/system-prompt.ts` (`formatSkillsForSystemPrompt`) | 1 | 1 | 100 % |
| `harness/prompt-templates.ts` (loader + diagnostics + arg parser + substituter + invocation formatter) | 6 | 3 | 50 % |
| `harness/skills.ts` (loader + diagnostics + invocation formatter) | 5 | 2 | 40 % |
| `harness/compaction/compaction.ts` (15 named exports) | 15 | ~7 inline equivalents | ~47 % |
| `harness/compaction/utils.ts` (file-ops helpers + `serializeConversation`) | 6 | 1 (`serializeConversation` inlined) | ~17 % |
| `harness/compaction/branch-summarization.ts` (branch summary helpers) | 7 | ~3 inline equivalents | ~43 % |
| `harness/utils/shell-output.ts` (`executeShellWithCapture` + `sanitizeBinaryOutput`) | 3 | 2 (with different shape + fixed log path bug) | ~67 % |
| `harness/utils/truncate.ts` (`truncateHead`/`truncateTail`/`truncateLine` + result type + `formatSize`) | 5 | 2 (smaller result type, no `formatSize`) | ~40 % |
| `harness/env/nodejs.ts` (`NodeExecutionEnv` + `FileSystem`/`Shell`/`ExecutionEnv` interfaces) | 4 | 0 | 0 % |
| `harness/session/session.ts` (`Session` class + `buildSessionContext`) | 19 methods + 1 fn | 14 equivalents (no `appendLabel`/`getLabel`, no `getSessionName` parity, `moveTo` partial) | ~70 % |
| `harness/session/jsonl-storage.ts` + `jsonl-repo.ts` (Jsonl storage + repo + `encodeCwd` + `loadJsonlSessionMetadata`) | 2 classes + 2 helpers | `PersistentStore` covers most of storage; **no `JsonlSessionRepo` class** (free functions only); no cwd encoding | ~55 % |
| `harness/session/memory-storage.ts` + `memory-repo.ts` | 2 classes | 0 | 0 % |
| `harness/session/repo-utils.ts` (`createSessionId`, `createTimestamp`, `toSession`, `getEntriesToFork`, `getFileSystemResultOrThrow`) | 5 | partial inline (counter ID not UUID v7, no `getEntriesToFork "at"` mode) | ~40 % |
| `harness/session/uuid.ts` | 1 (`uuidv7`) | 0 (numeric counter) | 0 % |
| Hook result types (8 result interfaces) | 8 | 2 mirror partial (`BeforeToolCallResult` / `AfterToolCallResult`) | ~25 % |
| Session-tree entry types (10) | 10 | 9 (no `LabelEntry` durable) | 90 % |
| Stable error classes (`AgentHarnessError`, `SessionError`, `CompactionError`, `BranchSummaryError`, `FileError`, `ExecutionError`) | 6 | 0 (Zig error sets only) | 0 % |
| `Result<T,E>` + `ok`/`err`/`getOrThrow`/`getOrUndefined`/`toError` | 5 | 0 | 0 % |

**Weighted average (volume-weighted estimate of the agent-package public
surface that is observable from outside pi-zig):**

- High-volume gaps: `Agent` class (0 % as an embeddable class), `streamFn`
  pluggability (0 %), `ExecutionEnv` abstraction (0 %), `Result<T,E>` model
  (0 %), `proxy.ts` (0 %), `AgentHarness` own-event hook contract (~30 %),
  in-memory session backend (0 %), parallel tool execution (0 %).
- Mid-volume parity: turn loop control flow, compaction, branch summary,
  session storage, prompt-template/skill loading (all ~50-70 %).
- High parity: provider-side wire formats, session-tree entry shapes (which
  is a session-package concern, but the union itself is largely matched),
  built-in tool semantics (truncation constants + behavior).

### Honest estimated parity: **~55 %**

That number reflects:
- Pi-zig has a **working** provider+tool turn loop, queue-aware draining,
  compaction (including LLM-driven), branch summary, durable JSONL sessions,
  extension hooks for before/after-tool and registered tools, lifecycle
  emission for the subset of upstream events the RPC consumers exercise, and
  byte-equivalent serialization on every provider transport.
- Pi-zig **does not** have the `Agent`/`AgentHarness` class abstractions as
  embeddable types, no pluggable `StreamFn`, no parallel tool execution, no
  `transformContext`/`convertToLlm` callbacks, no `ExecutionEnv` indirection,
  no `Result<T,E>` model, no `streamProxy`, no in-memory session backend,
  no stable error classes, no listener-await for run settlement, no rich
  truncation result, and the per-bash-run temp-file behavior is replaced by
  a single fixed log path.
- The current `docs/parity.md` "100 %" on Agent runtime/harness/tool loop
  reflects *behavioral coverage of the in-tree consumers* (top-level CLI,
  RPC, JSON mode, Preact workbench). It does NOT reflect parity with
  upstream's published library surface; that is **~55 %** when measured
  against the public exports enumerated above.

For an external consumer who wants to embed pi-zig the way they could embed
`@earendil-works/pi-agent-core` (i.e. `import { Agent, AgentHarness,
JsonlSessionRepo, ... }` and write a custom front-end), the answer today is:
**pi-zig is not embeddable as a library** — it is an executable plus an
NDJSON RPC protocol. The Preact workbench in `frontend/` and the upcoming
Prin7r integration both spawn `pi-zig rpc <session>` as a child process,
which is the de-facto integration shape.

---

## 5. Files referenced

Upstream (read-only audit targets, all under
`/Users/keer/projects/pi-zig/upstream/pi/packages/agent/src/`):

- `index.ts`, `agent.ts`, `agent-loop.ts`, `types.ts`, `proxy.ts`, `node.ts`
- `harness/agent-harness.ts`, `harness/types.ts`, `harness/messages.ts`,
  `harness/system-prompt.ts`, `harness/prompt-templates.ts`, `harness/skills.ts`
- `harness/compaction/compaction.ts`, `harness/compaction/utils.ts`,
  `harness/compaction/branch-summarization.ts`
- `harness/utils/shell-output.ts`, `harness/utils/truncate.ts`
- `harness/env/nodejs.ts`
- `harness/session/session.ts`, `harness/session/jsonl-storage.ts`,
  `harness/session/jsonl-repo.ts`, `harness/session/memory-storage.ts`,
  `harness/session/memory-repo.ts`, `harness/session/repo-utils.ts`,
  `harness/session/uuid.ts`

Pi-zig (compared against):

- `/Users/keer/projects/pi-zig/src/pi/agent.zig` (2156 LoC)
- `/Users/keer/projects/pi-zig/src/pi/ai_client.zig` (6324 LoC)
- `/Users/keer/projects/pi-zig/src/pi/tools.zig` (2376 LoC)
- `/Users/keer/projects/pi-zig/src/pi/rpc.zig` (5256 LoC)
- `/Users/keer/projects/pi-zig/src/pi/session.zig` (1576 LoC)
- `/Users/keer/projects/pi-zig/src/pi/commands.zig`
- `/Users/keer/projects/pi-zig/src/pi/system_prompt.zig`
- `/Users/keer/projects/pi-zig/src/pi/extension_runner.zig`

Parity context: `/Users/keer/projects/pi-zig/docs/parity.md`.

# Gap-04: Tools, Extensions, Resources, Models, HTML Export

Read-only audit comparing upstream `earendil-works/pi` (commit
`fc8a1559017f1e581cfa971aa3cef11a507a4975` per
`docs/inventory/upstream-inventory.json`) against pi-zig branch
`codex/pi-zig-progress`. Files reviewed:

- `upstream/pi/packages/coding-agent/src/core/tools/*` (15 files)
- `upstream/pi/packages/coding-agent/src/core/extensions/*` (5 files)
- `upstream/pi/packages/coding-agent/src/core/resource-loader.ts`
- `upstream/pi/packages/coding-agent/src/core/skills.ts`
- `upstream/pi/packages/coding-agent/src/core/prompt-templates.ts`
- `upstream/pi/packages/coding-agent/src/core/package-manager.ts`
- `upstream/pi/packages/coding-agent/src/core/model-registry.ts`
- `upstream/pi/packages/coding-agent/src/core/model-resolver.ts`
- `upstream/pi/packages/coding-agent/src/core/provider-display-names.ts`
- `upstream/pi/packages/coding-agent/src/core/export-html/*` (6 files + vendored libs)

Pi-zig counterparts: `src/pi/tools.zig`, `src/pi/extensions.zig`,
`src/pi/extension_runner.zig`, `src/pi/commands.zig`, `src/pi/themes.zig`,
`src/pi/package_manager.zig`, `src/pi/models.zig`, `src/pi/models.generated.zig`,
`src/pi/html_export.zig`, `src/pi/agent.zig`, `src/pi/rpc.zig`, `src/pi/session.zig`.

Status legend:
- `present` — pi-zig has a meaningful port (may diverge in details).
- `partial` — wired, but with documented missing behavior.
- `MISSING` — no port at all (the surface does not exist in pi-zig).

---

## 1. Surface Inventory

### 1.1 Built-in tool surfaces (7 tools, 15 module files)

| Upstream file | Surface (export, behavior) | Pi-zig target | Status |
|---|---|---|---|
| `tools/index.ts` | `ToolName` union `"read"\|"bash"\|"edit"\|"write"\|"grep"\|"find"\|"ls"`; `allToolNames`, `createTool/createToolDefinition`, `createCodingTools/Definitions` (read+bash+edit+write), `createReadOnlyTools/Definitions` (read+grep+find+ls), `createAllTools/Definitions`, `ToolsOptions` per-tool options struct | `src/pi/tools.zig` (single module, hardcoded set called from `src/pi/agent.zig` `BUILT_IN_TOOL_DEFS`) | partial — set is identical; the upstream "coding" / "read-only" subset factories are not exposed (pi-zig always exposes the full 7-tool set, gated only by `--no-builtin-tools` / `--tools` flags) |
| `tools/bash.ts` | `BashOperations` pluggable exec abstraction, `BashSpawnContext` + `BashSpawnHook` env/command/cwd rewrite, `commandPrefix`, `shellPath`, throttled `onUpdate` (`BASH_UPDATE_THROTTLE_MS=100`), `BASH_PREVIEW_LINES=5`, `formatBashCall`/`renderResult` TUI components, `createLocalBashOperations` (exported so SSH/remote extensions can reuse pi's local shell), output accumulation via `OutputAccumulator`, abort via `AbortSignal`+`killProcessTree`, timeout-as-error with `timeout:N` string protocol, partial-output preservation on cancel/timeout | `src/pi/tools.zig` `runShellCaptureWithUpdates`, `ShellCaptureOptions` (timeout_ms, cancellation_callback, update_callback, max_lines, max_bytes), `resolveShellPath`, `killShellChildTree`, throttled `ShellUpdate` | partial — execution behavior is parity-equivalent (timeout, cancel, ANSI strip, stderr→stdout merge, tail truncate, full-output file). MISSING: (a) `BashOperations` pluggable backend exported as a public seam for extensions to swap shell execution, (b) `BashSpawnContext` / `BashSpawnHook` env/cwd/command rewrite hook, (c) `commandPrefix` option (RPC settings `shellCommandPrefix` is wired separately), (d) `createLocalBashOperations` reusable export, (e) TUI render components (`renderCall`, `renderResult` — these live in `tui.zig` / `html_export.zig` separately and do not share the upstream `Container`/`Box` rendering shell) |
| `tools/edit.ts` | `EditOperations` pluggable (readFile/writeFile/access), `prepareArguments` legacy `oldText`/`newText` migration + JSON-string `edits` parsing (Opus 4.6 / GLM-5.1 fallback), `withFileMutationQueue` serialization, BOM/CRLF preservation, fuzzy-match via `applyEditsToNormalizedContent`, overlap detection, `EditToolDetails` (diff + patch + firstChangedLine), `computeEditsDiff` async preview, TUI `renderShell:"self"` with live preview (`computeEditsDiff` runs as args complete), `renderDiff` colored output, error-vs-success header background | `src/pi/tools.zig` `editFileMany`/`editFileManyResult`, `EditReplacement`, `EditOutcome`, `normalizeForFuzzyMatch`+NFKC, BOM/CRLF preservation, overlap detection | partial — core algorithm (fuzzy match, NFKC normalize, BOM, line ending preserve, multiple edits with reverse-order application, overlap rejection) is present. MISSING: (a) `EditOperations` pluggable filesystem ops, (b) `withFileMutationQueue` cross-tool file-level serialization (write+edit serializing access to the same file), (c) `prepareArguments` legacy `oldText`/`newText` and JSON-string `edits` migration, (d) `computeEditsDiff` standalone preview API (only synchronous apply), (e) `generateUnifiedPatch` (returns combined diff+patch+firstChangedLine in `details`), (f) TUI `renderShell:"self"` async preview rendering |
| `tools/edit-diff.ts` | `detectLineEnding`, `normalizeToLF`, `restoreLineEndings`, `normalizeForFuzzyMatch` (NFKC, smart quotes/dashes/spaces ASCII fold, trailing whitespace strip), `stripBom`, `fuzzyFindText`, `applyEditsToNormalizedContent`, `generateUnifiedPatch` (via `diff` package), `generateDiffString` (line-numbered colored display with `contextLines=4`), `computeEditsDiff`, `computeEditDiff` | `src/pi/tools.zig` internal helpers `detectLineEnding`, `normalizeToLfAlloc`, `writeRestoredLineEndings`, `normalizeForFuzzyMatch`, `nfkcNormalizeAlloc`, `precomposeLatin`, `fuzzyAsciiReplacement`, `stripTrailingWhitespacePerLine`, `stripUtf8Bom` | partial — diff *application* is at parity. MISSING: (a) `generateDiffString` — pi-zig does not return a line-numbered colored diff to the model in `details.diff`; (b) `generateUnifiedPatch` — `details.patch` field is not produced; (c) `firstChangedLine` is not computed/returned; (d) `computeEditsDiff` is not exposed for TUI preview |
| `tools/file-mutation-queue.ts` | `withFileMutationQueue<T>(filePath, fn)` realpath-keyed per-file serialization map, `getMutationQueueKey` (realpath, fallback to resolved on ENOENT/ENOTDIR), `registrationQueue` global serialization for queue setup | (none) | MISSING — pi-zig does not serialize concurrent writes/edits to the same path. Parallel edit+write to the same file would race. This is structurally absent: agent loop in `src/pi/agent.zig` runs tools sequentially in single-threaded turns, so the gap is latent until parallel tool execution or extension-driven concurrency is added |
| `tools/find.ts` | `FindOperations` pluggable (exists/glob), spawns `fd` via `ensureTool("fd", true)` (auto-downloads if missing), `--no-require-git` + `--hidden` + `--glob` + `--max-results`, path-globbing requires `--full-path` and `**/` prefix, `.gitignore` respected hierarchically by fd, abort via SIGTERM, default limit 1000, byte truncation via `truncateHead` with `MAX_SAFE_INTEGER` line limit, `details.resultLimitReached` + `details.truncation` | `src/pi/tools.zig` `findFiles`/`findFilesText` | partial — basic glob/path/limit works with relative POSIX output and gitignore basics. MISSING: (a) shells out to its own walker (no `fd` dependency or auto-download — divergent by design), (b) `FindOperations` pluggable backend, (c) `--full-path` `**/` prefix auto-prepend for path-containing globs (upstream find.ts:240-247), (d) abort-mid-walk (no cancellation seam), (e) hierarchical `.gitignore` precedence matches "basic" only per parity ledger, (f) limit-doubling hint `Use limit=N*2 for more` in notices |
| `tools/grep.ts` | `GrepOperations` pluggable (isDirectory/readFile), spawns `rg` via `ensureTool("rg", true)`, `--json --line-number --color=never --hidden`, glob filter, ignoreCase, literal, context lines (block-rendered), `--ignore-case`, `--fixed-strings`, default limit 100, kill-on-match-limit-reached, `truncateLine` for `GREP_MAX_LINE_LENGTH=500` chars, `details.matchLimitReached`/`details.truncation`/`details.linesTruncated` | `src/pi/tools.zig` `grep`/`grepText`, shells to `rg` | partial — shells to `rg` like upstream; glob+ignoreCase+literal+context+limit appear wired (per parity ledger). MISSING: (a) `GrepOperations` pluggable backend, (b) abort/cancel mid-search via `child.kill()` (no `AbortSignal` plumbing in current tool surface), (c) match-limit auto-kill (upstream's `stopChild(true)` once limit reached saves rg cycles), (d) per-line `truncateLine` to 500 chars |
| `tools/ls.ts` | `LsOperations` pluggable (exists/stat/readdir), case-insensitive `localeCompare` sort, dotfiles included, default limit 500, per-entry stat for `/` suffix, `details.entryLimitReached`/`details.truncation` | `src/pi/tools.zig` `listDir`/`listDirText`, `lessThanListEntry`, `lessThanAsciiIgnoreCase` | partial — sort, `/` suffix, limit are present. MISSING: (a) `LsOperations` pluggable backend, (b) abort signal, (c) limit-doubling hint string |
| `tools/read.ts` | `ReadOperations` pluggable (readFile/access/detectImageMimeType), `autoResizeImages` default true via `resizeImage` (2000×2000), `detectSupportedImageMimeTypeFromFile`, macOS NFD/NBSP/curly-quote/AM-PM path variants in `resolveReadPath(Async)`, 1-indexed offset/limit, 2000 line / 50 KB head truncation, image content parts + non-vision text note `[Current model does not support images...]`, compact-read classification (`docs`/`resource`/`skill`) for `SKILL.md`/`AGENTS.md`/`CLAUDE.md`/`docs/`/`examples/`/`README.md` (upstream pi docs only), `replaceTabs`+`highlightCode` TUI rendering, `firstLineExceedsLimit` with sed fallback message | `src/pi/tools.zig` `readFileForTool`/`readFileForToolText`, `detectImageMimeType` (PNG/JPG/GIF/WEBP), `read` tool wiring in agent | partial — offset/limit, image content parts, non-vision note, truncation messages are wired (per parity ledger). MISSING: (a) `ReadOperations` pluggable backend, (b) **image auto-resize** to 2000×2000 — pi-zig has `images.autoResize=false` threaded but the resize worker itself is MISSING (parity ledger acknowledges this), (c) macOS path variant fallbacks (`tryMacOSScreenshotPath`/`tryNFDVariant`/`tryCurlyQuoteVariant`) in `resolveReadPath`, (d) animated-PNG detection (`isAnimatedPng` exists in pi-zig but is unused — needs verification), (e) compact-read classification (`SKILL.md`/`docs/`/`examples/` collapsing in TUI), (f) `firstLineExceedsLimit` sed-fallback message format |
| `tools/write.ts` | `WriteOperations` pluggable (writeFile/mkdir), `withFileMutationQueue` serialization, recursive parent dir creation, returns `Successfully wrote N bytes to <path>`, TUI `renderCall` shows incremental syntax-highlighted preview as args stream (`WriteHighlightCache`, `WRITE_PARTIAL_FULL_HIGHLIGHT_LINES=50`), error-state result rendering | `src/pi/tools.zig` `writeFile`/`writeFileForTool`/`writeFileForToolText` | partial — write+mkdir+bytes-written response is at parity. MISSING: (a) `WriteOperations` pluggable backend, (b) `withFileMutationQueue` serialization, (c) syntax-highlighted streaming preview (TUI-side gap, not a tool gap), (d) tab-replacement / display normalization |
| `tools/output-accumulator.ts` | `OutputAccumulator` class with streaming UTF-8 decoder, bounded `tailText` (max 2× maxBytes), incremental newline counting, `appendDecodedText`, `trimTail` at UTF-8 boundary, `shouldUseTempFile`, opens temp file at `tmpdir()/pi-bash-<hex>.log`, `closeTempFile`, `getLastLineBytes` for "partial last line" status text | `src/pi/tools.zig` shell capture buffer (`ShellResult`, `ShellTruncationDetails`, `ShellTruncatedBy`) | partial — final tail-truncation result is at parity. MISSING: (a) streaming incremental snapshots — pi-zig appears to buffer the whole output then truncate at the end, vs. upstream's bounded rolling tail. The throttled `tool_execution_update` snapshots are emitted, but the underlying mechanism differs and the `getLastLineBytes` "partial last line" UI hint is not produced |
| `tools/path-utils.ts` | `pathExists` (async+sync), `expandPath` (`normalizePath` with `stripAtPrefix`, NBSP normalize), `resolveToCwd`, `resolveReadPath`/`Async` with 4 macOS path-variant fallbacks (AM/PM NBSP, NFD, curly quote, NFD+curly) | `src/pi/tools.zig` shares path resolution via `std.fs.cwd()` + manual joins | partial — basic path resolution is present. MISSING: (a) the macOS screenshot/curly-quote/NFD variant fallback chain in read tool path resolution, (b) `stripAtPrefix` for `@filename` CLI attachment paths (mentioned in `agent.zig` `prompt_content_parts` but no central util) |
| `tools/render-utils.ts` | `shortenPath` (`~` for home), `str(unknown)` null/empty/null-on-non-string protocol, `replaceTabs(text)` (3 spaces), `normalizeDisplayText` (strip `\r`), `getTextOutput` (text+image content array → display string with `imageFallback` when terminal lacks images), `invalidArgText` themed `[invalid arg]` marker | (none — pi-zig has TUI-side helpers in `tui.zig`) | partial — equivalents exist in pi-zig TUI render code, but they are not exposed as a shared rendering library. MISSING as a public seam: tool authors writing custom renderers cannot import these helpers |
| `tools/tool-definition-wrapper.ts` | `wrapToolDefinition` adapts `ToolDefinition` → `AgentTool` injecting `ExtensionContext` factory, `wrapToolDefinitions` plural, `createToolDefinitionFromAgentTool` reverse-direction synthesis for AgentSession registry | (n/a — pi-zig uses a different agent-loop seam) | MISSING by design — pi-zig's `agent.ToolHooks` + `execute_registered_tool` cover the equivalent role for extension-registered tools, but there is no public `ToolDefinition` / `AgentTool` boundary type the same way upstream exposes |
| `tools/truncate.ts` | `DEFAULT_MAX_LINES=2000`, `DEFAULT_MAX_BYTES=50KB`, `GREP_MAX_LINE_LENGTH=500`, `TruncationResult` (content, truncated, truncatedBy `"lines"\|"bytes"\|null`, totalLines, totalBytes, outputLines, outputBytes, lastLinePartial, firstLineExceedsLimit, maxLines, maxBytes), `truncateHead` (no partial lines, firstLineExceedsLimit special case returning empty content), `truncateTail` (partial first line allowed when single line exceeds bytes), `truncateLine` (per-line `... [truncated]` suffix), `formatSize` (B/KB/MB) | `src/pi/tools.zig` `Truncation`, `ShellTruncationDetails`, `ShellTruncatedBy` enum | partial — head/tail truncation behavior is at parity. MISSING: (a) `firstLineExceedsLimit` flag separately surfaced for read tool's "Use bash: sed -n '...'" message branch (parity ledger flags read-tool truncation is implemented; verification that the sed-fallback case is wired needs explicit smoke), (b) `truncateLine` per-line truncation hook for grep, (c) `formatSize` shared util (pi-zig has equivalent inline formatting) |

### 1.2 Extensions API (`core/extensions/*`, 5 files)

#### 1.2.1 `pi.*` API methods (22 per upstream `types.ts`)

| Method | Upstream signature/semantics | Pi-zig runner JS shim (`src/pi/extension_runner.zig`) | Status |
|---|---|---|---|
| `on(event, handler)` | Subscribe to one of 29 lifecycle events | `handlers.set(type, handlers.get(type)?.push(handler))` map registration | present — registration captured |
| `registerTool(tool)` | `ToolDefinition<TParams,TDetails,TState>`, calls `runtime.refreshTools()` after | `activeToolMap.set(tool.name, tool)` inside `loadExtension` scope; tools surfaced via `discoverToolDefinitions` event | present — first-extension-wins precedence verified by unit tests |
| `registerCommand(name, options)` | `Omit<RegisteredCommand,"name"\|"sourceInfo">` (description, handler, getArgumentCompletions) | `activeCommandMap.set(name, {name, ...options})`; resolved with `:N` suffix duplicates | present — handler is executed for `execute_command` event, argument completions are NOT plumbed |
| `registerShortcut(shortcut, options)` | Bind `KeyId` keyboard shortcut with handler running inside `ExtensionContext`; conflict with reserved-keybindings list logged as diagnostic | (none — `api` object in runner JS has no `registerShortcut`) | **MISSING** — pi-zig has no TUI shortcut registration path; calls would throw `TypeError: api.registerShortcut is not a function` |
| `registerFlag(name, options)` | `{description?, type:"boolean"\|"string", default?}`; runner stores in `flagValues` map | `activeFlagMap.set(name, {name, ...options})`; default value seeded into `runtime.flagValues` if not already set; `flag_type` `unspecified` legacy supported | present |
| `getFlag(name)` | Returns boolean/string/undefined; checks extension owns flag before returning value | Reads from `payloadFlags` (per-request), then `activeFlagMap.default`/`defaultValue`, then any extension's registered flag default | present — verified by smokes |
| `registerMessageRenderer(customType, renderer)` | Bind a renderer for `CustomMessage<T>` entries in interactive TUI | (none — `api` object has no `registerMessageRenderer`) | **MISSING** — pi-zig has no message-renderer registration; custom messages are persisted as JSONL but cannot be rendered by extension-provided components |
| `registerProvider(name, config)` | `ProviderConfig` (baseUrl, apiKey, api, streamSimple, headers, authHeader, models, oauth); applied either via queued `pendingProviderRegistrations` pre-bind or `ModelRegistry.registerProvider` post-bind; supports inline oauth login/refreshToken/getApiKey/modifyModels closures | (none — `api` object has no `registerProvider`) | **MISSING** — pi-zig cannot register custom providers dynamically from extensions; existing example extensions `custom-provider-anthropic` and `custom-provider-gitlab-duo` are non-functional under pi-zig |
| `unregisterProvider(name)` | Remove dynamic provider, restore overridden built-ins via `ModelRegistry.refresh()` (resets dynamic OAuth + API stream registrations) | (none) | **MISSING** — depends on `registerProvider` |
| `sendMessage(message, options)` | `Pick<CustomMessage<T>,"customType"\|"content"\|"display"\|"details">` + `{triggerTurn?, deliverAs?:"steer"\|"followUp"\|"nextTurn"}` | `actions.push({type:"send_message", message, options})` for harness consumption | present — RPC consumes the action; `triggerTurn`/`deliverAs: nextTurn` are wired (parity ledger) |
| `sendUserMessage(content, options)` | string \| `(TextContent\|ImageContent)[]` + `{deliverAs?:"steer"\|"followUp"}` | `actions.push({type:"send_user_message", content, options})` | present — image arrays and `deliverAs` work in RPC |
| `appendEntry(customType, data)` | Append hidden `custom` JSONL entry, advances leaf, excluded from LLM context | `actions.push({type:"append_entry", customType, data})` | present — RPC + top-level persist it |
| `setSessionName(name)` | Set session display name | (none) | **MISSING** — RPC has a `set_session_name` command but that's a separate request/response surface; `pi.setSessionName()` from inside an extension factory/handler would throw |
| `getSessionName()` | Read session name | (none) | **MISSING** |
| `setLabel(entryId, label)` | Attach/clear user-defined label on a session entry (for bookmarking, navigation) | (none) | **MISSING** |
| `exec(command, args, options)` | `execCommand` (`core/exec.ts`) — generic shell exec returning `ExecResult`, scoped to current `cwd` | (none — `api.exec` is not defined) | **MISSING** — extensions cannot run arbitrary shell commands from inside the runner |
| `getActiveTools()` | Returns `string[]` of currently active tool names | (none) | **MISSING** |
| `getAllTools()` | Returns `ToolInfo[]` = `Pick<ToolDefinition,"name"\|"description"\|"parameters">` + `sourceInfo` | (none) | **MISSING** |
| `setActiveTools(toolNames)` | Replace active tool set at runtime | (none) | **MISSING** |
| `getCommands()` | Returns `SlashCommandInfo[]` for the current session | (none) | **MISSING** — note that pi-zig RPC has `get_commands` but that's a separate inbound command; the `pi.getCommands()` API method is not |
| `setModel(model)` | `Promise<boolean>`; returns false when no API key configured | (none) | **MISSING** |
| `getThinkingLevel()` | Returns current `ThinkingLevel` | (none) | **MISSING** |
| `setThinkingLevel(level)` | Set thinking level, clamped to model capabilities | (none) | **MISSING** |
| `events: EventBus` | Shared `EventBus` (`createEventBus`) for inter-extension communication | (none) | **MISSING** — runner JS defines `api.events = { on(){}, emit(){} }` as a stub but those are no-ops |

**Summary of pi.* API parity (22 methods):**
- present (8): `on`, `registerTool`, `registerCommand`, `registerFlag`, `getFlag`, `sendMessage`, `sendUserMessage`, `appendEntry`
- MISSING (14): `registerShortcut`, `registerMessageRenderer`, `registerProvider`, `unregisterProvider`, `setSessionName`, `getSessionName`, `setLabel`, `exec`, `getActiveTools`, `getAllTools`, `setActiveTools`, `getCommands`, `setModel`, `getThinkingLevel`, `setThinkingLevel`, plus `events: EventBus` (functional, not method but used as `events.on/emit`)

Parity ledger says "in_progress (wired in runner): registerTool, registerCommand, registerFlag, getFlag, sendMessage, sendUserMessage, appendEntry" — that aligns with the JS shim, excluding `on` which is also wired but only useful when paired with lifecycle emit sites (next section).

#### 1.2.2 Extension lifecycle events (29 per upstream `types.ts` `pi.on(...)`)

| Event | Result semantics (upstream) | Pi-zig dispatch site (production code, not test) | Status |
|---|---|---|---|
| `resources_discover` | Aggregate `{skillPaths, promptPaths, themePaths}` from all handlers, fed back into `DefaultResourceLoader.extendResources()` | (none — pi-zig resource discovery in `commands.zig`/`themes.zig`/`context_files.zig` does not invoke any extension handler) | **MISSING** — extensions cannot contribute skill/prompt/theme paths dynamically |
| `session_start` | Notify all handlers; reason `"startup"\|"reload"\|"new"\|"resume"\|"fork"`; `previousSessionFile` for new/resume/fork | `src/pi/rpc.zig:2015` `emitLifecycleNotify(..., "session_start", ...)` for new/resume/fork; runtime emits at session bootstrap | partial — RPC emits `session_start`, but `reason` payload coverage and `previousSessionFile` need verification; top-level (print/JSON) does NOT emit |
| `session_before_switch` | Cancellable `{cancel?:boolean}`; reason `"new"\|"resume"`; `targetSessionFile?` | (none) | **MISSING** |
| `session_before_fork` | Cancellable `{cancel?, skipConversationRestore?}`; `entryId`, `position` | (none) | **MISSING** |
| `session_before_compact` | Cancellable `{cancel?, compaction?}`; preparation, branchEntries, customInstructions, signal | (none) | **MISSING** |
| `session_compact` | Notify after compaction; `compactionEntry`, `fromExtension` | (none) | **MISSING** |
| `session_shutdown` | Notify before runtime teardown; reason `"quit"\|"reload"\|"new"\|"resume"\|"fork"`; `targetSessionFile?`. `emitSessionShutdownEvent` helper export | (none) | **MISSING** |
| `session_before_tree` | Cancellable `{cancel?, summary?, customInstructions?, replaceInstructions?, label?}`; preparation includes target/old leaf/common ancestor/entries to summarize | (none) | **MISSING** |
| `session_tree` | Notify after navigation; newLeafId, oldLeafId, summaryEntry, fromExtension | (none) | **MISSING** |
| `context` | Transform-style: each handler returns `{messages?:AgentMessage[]}`; chained — last non-undefined wins via runner JS `TRANSFORM_EVENTS` | The runner JS `dispatchLifecycleEvent` handles `TRANSFORM_EVENTS = {..., context: "messages"}` but **no production code in `src/pi/agent.zig` or `src/pi/rpc.zig` invokes `dispatchLifecycleEvent` with `type: "context"`** before sending messages to the provider | **MISSING (dispatch site)** — handler registration would succeed but the event is never emitted in production. Only `src/pi/extension_runner.zig` unit tests fire it |
| `before_provider_request` | Transform-style: `{payload}` chained; last non-undefined wins | `src/pi/agent.zig:406` `emitLifecycle(options, "before_provider_request", ...)`; agent loop wires the seam | partial — emitted notify-style (fire-and-forget); the **returned transformed payload is NOT consumed**. Upstream replaces the request body; pi-zig discards the result. Verified at `src/pi/rpc.zig:3834-3842` (`RuntimeLifecycleEmitContext.emit` calls `dispatchLifecycleEvent` then `result.deinit` without applying the result) |
| `after_provider_response` | Notify-style with `{status, headers}` | `src/pi/agent.zig:414` `emitLifecycle(options, "after_provider_response", "{\"status\":200}")` | partial — emitted but with HARDCODED `status:200` and EMPTY headers; the actual response status/headers are not captured |
| `before_agent_start` | Combined-result: returns `{messages?, systemPrompt?}` chained; injects custom messages and replaces system prompt mid-loop | (none) | **MISSING** — agent loop does not invoke this hook; extensions cannot inject custom assistant-visible messages or rewrite the system prompt per turn |
| `agent_start` | Notify; fires when agent loop starts | `src/pi/rpc.zig:2103` `emitLifecycleNotify(..., "agent_start", "{}")` | partial — RPC only; agent.zig print/JSON paths do NOT emit |
| `agent_end` | Notify; `{messages:AgentMessage[]}` | `src/pi/rpc.zig:2131` `emitLifecycleNotify(..., "agent_end", "{}")` | partial — RPC only; payload `messages` is EMPTY (`"{}"`) |
| `turn_start` | Notify; `{turnIndex, timestamp}` | `src/pi/agent.zig:386` `emitLifecycle(..., "turn_start", lifecycleTurnFields(...))` | partial — emitted; payload shape needs verification against upstream `{turnIndex, timestamp}` |
| `turn_end` | Notify; `{turnIndex, message, toolResults}` | `src/pi/agent.zig:426`, `:500` `emitLifecycle(..., "turn_end", lifecycleTurnFields(...))` | partial — emitted; full `message` + `toolResults` shape needs verification |
| `message_start` | Notify; `{message}` — user/assistant/toolResult | `src/pi/agent.zig:424, :437` `emitLifecycle(..., "message_start", "{\"role\":\"assistant\"}")` | partial — emitted with HARDCODED `{role: "assistant"}`; the actual `message` object is not included, user/toolResult messages do NOT emit this event |
| `message_update` | Notify with token-by-token streaming `{message, assistantMessageEvent}` | (none) | **MISSING** — no `message_update` emission anywhere in agent.zig or rpc.zig |
| `message_end` | Combined-result `{message?}` for replacement; replacement must keep same role; runner has dedicated `emitMessageEnd` that validates role and returns replacement message | `src/pi/agent.zig:425, :439` `emitLifecycle(..., "message_end", "{\"role\":\"assistant\"}")` | partial — emitted as notify-style with `{role: "assistant"}`; the **returned replacement `message` is NOT applied** to the transcript; no role validation; no user/toolResult message_end |
| `tool_execution_start` | Notify; `{toolCallId, toolName, args}` | (none — `agent.zig` tool execution callbacks like `on_tool_start` fire a different `ToolExecution*Event` payload to local JSON/RPC consumers, but they do NOT dispatch a `tool_execution_start` lifecycle event to extensions) | **MISSING** as an extension event; the JSON/RPC event stream is separate |
| `tool_execution_update` | Notify; `{toolCallId, toolName, args, partialResult}` | (none — same as above) | **MISSING** |
| `tool_execution_end` | Notify; `{toolCallId, toolName, result, isError}` | (none — same as above) | **MISSING** |
| `model_select` | Short-circuit (first decisive handler wins) `{model, previousModel, source:"set"\|"cycle"\|"restore"}` | (none) | **MISSING** |
| `thinking_level_select` | Short-circuit `{level, previousLevel}` | (none) | **MISSING** |
| `tool_call` | Short-circuit-on-block `{block?, reason?}`; mutate `event.input` in place to patch args; runner has dedicated `emitToolCall` that returns the first block decision | `src/pi/agent.zig` `BeforeToolCallResult` — extension_runner wires `runBeforeToolCall` and JSON/RPC agent loops invoke it | present — block + reason + arguments_json rewrite all work; verified by smokes |
| `tool_result` | Combined-result `{content?, details?, isError?}` mutation, dedicated `emitToolResult` aggregator | `src/pi/agent.zig` `AfterToolCallResult` — extension_runner `runAfterToolCall` | present — content (text + parts) + isError + terminate + details overrides all work; verified |
| `user_bash` | Short-circuit `{operations?, result?}` either to swap exec backend or replace the result | `src/pi/rpc.zig:2024-2036` `emitUserBash`, called from `rpc.zig:3186-3191` before launching command | partial — emitted, the returned **command string** rewrite is honored (see `effective_command`); the upstream `operations` and `result` short-circuit shapes are NOT (you can't swap the exec backend or return a pre-canned result, just rewrite the command) |
| `input` | Transform/handled `{action:"continue"\|"transform"\|"handled", text?, images?}`; runner has dedicated `emitInput` | (none) | **MISSING** — pi-zig has no input event emission anywhere in the prompt-receive path |

**Summary of lifecycle events (29):**
- fully wired in production (2): `tool_call`, `tool_result`
- partially wired in production (8): `session_start`, `before_provider_request` (result discarded), `after_provider_response` (no real status/headers), `agent_start`, `agent_end`, `turn_start`, `turn_end`, `message_start`/`message_end` (no role variants beyond assistant; result discarded), `user_bash` (only command rewrite honored)
- MISSING in production despite runner-JS handler registration support (14+): `resources_discover`, `session_before_switch`, `session_before_fork`, `session_before_compact`, `session_compact`, `session_shutdown`, `session_before_tree`, `session_tree`, `context`, `before_agent_start`, `message_update`, `tool_execution_start`/`update`/`end`, `model_select`, `thinking_level_select`, `input`

Parity ledger says "in_progress (dispatched): tool_call, tool_result, input, context" but `input` and `context` are NOT actually emitted by production code paths — only the unit-test harness in `extension_runner.zig` fires them. **The parity ledger overstates dispatch by 2 events.**

#### 1.2.3 Resource events / extension-side resource provision

- `ResourcesDiscoverResult { skillPaths?, promptPaths?, themePaths? }` is processed by upstream `DefaultResourceLoader` via `emitResourcesDiscover` → `extendResources({skillPaths, promptPaths, themePaths})`. Pi-zig **does not call** `dispatchLifecycleEvent({type:"resources_discover", ...})` from anywhere, and there is no equivalent of `extendResources` on the pi-zig `commands.zig`/`themes.zig` registry. Extensions cannot inject skills or prompts dynamically.

#### 1.2.4 Extension UI context (`ExtensionUIContext`)

Per upstream `types.ts:124-275`, the UI context has 27 methods:

`select`, `confirm`, `input`, `notify`, `onTerminalInput`, `setStatus`, `setWorkingMessage`, `setWorkingVisible`, `setWorkingIndicator`, `setHiddenThinkingLabel`, `setWidget` (string-array and component-factory overloads), `setFooter`, `setHeader`, `setTitle`, `custom` (component overlay), `pasteToEditor`, `setEditorText`, `getEditorText`, `editor` (multi-line dialog), `addAutocompleteProvider`, `setEditorComponent`, `getEditorComponent`, `theme` (getter), `getAllThemes`, `getTheme`, `setTheme`, `getToolsExpanded`, `setToolsExpanded`.

Pi-zig runner JS exposes only `ctx.ui = { notify, select, input, prompt, confirm }`. The remaining 22 methods (status/working indicator, widgets, footer/header, terminal-input listener, custom overlays, editor injection, theme inspection, tools-expanded state) are **MISSING**.

The headless `confirm()` returning `false` is verified by the parity ledger (extension can block a bash tool call). Beyond that, every TUI-attached UI capability is absent.

#### 1.2.5 Extension command context (`ExtensionCommandContext`)

Per upstream `types.ts:333-364`, command handlers receive an extended ctx with 6 additional methods:

`waitForIdle`, `newSession`, `fork`, `navigateTree`, `switchSession`, `reload`.

Pi-zig runner JS provides all six but as **no-op stubs** that return `{cancelled:true}` (newSession/fork/navigateTree/switchSession) or empty promises (waitForIdle, reload). See `extension_runner.zig:1499-1509`. The handlers do not actually drive session changes through `src/pi/session.zig` or `src/pi/rpc.zig`. **Functionally MISSING** for any non-trivial command-driven workflow.

The runner JS also does not bind the `ExtensionContext.compact()`, `ExtensionContext.shutdown()`, `ExtensionContext.abort()`, `ExtensionContext.signal`, `ExtensionContext.hasPendingMessages()`, `ExtensionContext.getContextUsage()`, or `ExtensionContext.getSystemPrompt()` to real implementations.

#### 1.2.6 Extension loader (`extensions/loader.ts`)

| Feature | Status |
|---|---|
| `createJiti` with virtual modules (Bun binary) / aliases (Node dev) — bundled `typebox`, `@earendil-works/pi-*`, `@mariozechner/pi-*` (legacy alias) | **MISSING** — pi-zig spawns a regular `node` (or `tsx`) child with the user's own node_modules, no virtual-module substitution. The parity ledger acknowledges this: "full upstream `jiti` aliasing, virtual modules, dependency roots, and long-lived extension state remain open" — actually long-lived state is fixed by the persistent runner, but jiti aliasing/virtualModules is still open |
| `discoverAndLoadExtensions(configuredPaths, cwd, agentDir, eventBus)` — project `.pi/extensions/`, global `~/.pi/agent/extensions/`, then configured paths | present — `src/pi/extensions.zig` `discover` walks these layers |
| `loadExtensionFromFactory(factory, cwd, eventBus, runtime, extensionPath)` — inline factory loading for SDK/test harnesses | **MISSING** — pi-zig has no inline-factory path; all extensions are file paths |
| `discoverExtensionsInDir(dir)` rules: direct `.ts`/`.js` files, subdir with `index.ts`/`index.js`, subdir with `package.json` + `pi.extensions` manifest | present |
| `readPiManifest(packageJsonPath)` — `pi: {extensions?, themes?, skills?, prompts?}` reading | present — see `src/pi/extensions.zig:523` `readManifestExtensions` |
| `createExtensionRuntime()` — pending provider registration queue, `assertActive`, `invalidate` stale-context detection | partial — flag-values map and persistent process exist; `pendingProviderRegistrations` queue is absent because `registerProvider` itself is absent; `assertActive`/`invalidate` not implemented |
| `createExtensionAPI(extension, runtime, cwd, eventBus)` — the `pi` object exposed to extensions | partial — see §1.2.1; 8/22 methods wired |

#### 1.2.7 Extension runner (`extensions/runner.ts`)

| Feature | Status |
|---|---|
| `ExtensionRunner` class (extensions list, runtime, ui context, sessionManager, modelRegistry, error listeners, getter functions for model/idle/signal/system-prompt/context-usage/pending-messages) | partial — pi-zig `extension_runner.Runner` covers tool discovery, command discovery, flag discovery, before/after tool hooks, registered-tool execution, command execution, single lifecycle dispatch. Session/model/system-prompt/abort/usage getters are MISSING |
| `bindCore(actions, contextActions, providerActions)` — bind 12 actions + 9 context actions + provider register/unregister | **MISSING** — no `bindCore` equivalent; only `flag_values` is wired through `Runner.FlagValue` |
| `bindCommandContext(actions)` — wire 6 command-context actions | partial — JS stubs return `{cancelled:true}`; no Zig-side binding |
| `setUIContext` / `getUIContext` / `hasUI` | partial — runner JS has hardcoded `hasUI: false` and stubs for `ui.{notify,select,input,prompt,confirm}` |
| `getAllRegisteredTools` (first-wins precedence across extensions) | present |
| `getToolDefinition(name)` lookup | present |
| `getFlags()` (all flags, first-extension-wins) | present |
| `getShortcuts(resolvedKeybindings)` with reserved-keybinding conflict diagnostics (`RESERVED_KEYBINDINGS_FOR_EXTENSION_CONFLICTS` list of 15 reserved IDs) | **MISSING** — depends on `registerShortcut` |
| `getMessageRenderer(customType)` | **MISSING** — depends on `registerMessageRenderer` |
| `resolveRegisteredCommands` with `:N` invocation-name suffix for duplicates | present — see runner JS `allRegisteredCommands` (matches upstream exactly) |
| `getCommandDiagnostics` / `getShortcutDiagnostics` | partial — diagnostics array exists in runner JS, but `getShortcutDiagnostics` is not callable from Zig |
| `invalidate(message)` — stale-context detection | **MISSING** |
| `onError(listener)` | partial — diagnostics propagate via JSON response; no listener registration |
| `hasHandlers(eventType)` | partial — only checked indirectly via dispatch |
| `emit(event)`, `emitMessageEnd(event)`, `emitToolResult(event)`, `emitToolCall(event)`, `emitUserBash(event)`, `emitContext(messages)`, `emitBeforeProviderRequest(payload)`, `emitBeforeAgentStart(...)`, `emitResourcesDiscover(cwd, reason)`, `emitInput(text, images, source)` — dedicated typed emit methods with per-event aggregation | partial — `dispatchLifecycleEvent` handles all event types in one entry point with `TRANSFORM_EVENTS`/`SHORT_CIRCUIT_EVENTS`/`SESSION_BEFORE_EVENTS`/`resources_discover` aggregation. **But production code in agent.zig and rpc.zig only invokes it for `before_provider_request`, `after_provider_response`, `turn_start`/`turn_end`, `message_start`/`message_end`, `session_start`, `agent_start`/`agent_end`, `user_bash`, and via `RuntimeLifecycleEmitContext` from the agent loop.** Result *application* (transform-replacement, message-end role validation, before-agent-start systemPrompt swap, context messages mutation) is NOT done — every result is freed without being applied. |
| `createContext()` — `ExtensionContext` getter (model/sessionManager/modelRegistry/cwd/ui/hasUI/isIdle/signal/abort/hasPendingMessages/shutdown/getContextUsage/compact/getSystemPrompt) | partial — runner JS exposes `ctx.hasUI`, `ctx.ui` (5 methods), `ctx.diagnostics`. The 8 other context methods are MISSING |
| `createCommandContext()` — `ExtensionCommandContext` adds waitForIdle/newSession/fork/navigateTree/switchSession/reload | partial — 6 method names exist as JS stubs returning `{cancelled:true}` (see §1.2.5) |

#### 1.2.8 Wrapper / type guards (`extensions/wrapper.ts`, `extensions/index.ts`)

- `wrapRegisteredTool(registeredTool, runner)` — adapts to `AgentTool` for core runtime — n/a (pi-zig executes via JSON RPC over node, not via AgentTool wrap)
- `wrapRegisteredTools` plural — n/a same
- Type guards `isBashToolResult`, `isReadToolResult`, `isEditToolResult`, `isWriteToolResult`, `isGrepToolResult`, `isFindToolResult`, `isLsToolResult`, `isToolCallEventType` — n/a (TypeScript-only)
- Exported types (~100 type re-exports) — n/a

### 1.3 Resource loader (`core/resource-loader.ts`)

| Function/feature | Upstream behavior | Pi-zig target | Status |
|---|---|---|---|
| `loadProjectContextFiles({cwd, agentDir})` | Returns global agent dir context file first, then ancestor `AGENTS.md`/`CLAUDE.md` (NFKC-cased filename) walking up to `/`, deduping by realpath | `src/pi/context_files.zig` (per parity ledger: "discovers global and ancestor `AGENTS.md`/`CLAUDE.md` in upstream order") | present |
| `DefaultResourceLoader` class — single-source orchestrator for extensions, skills, prompts, themes, agents files, system prompt, append system prompt | (none — pi-zig fans out per-resource through separate modules: `commands.zig`, `themes.zig`, `context_files.zig`, `system_prompt.zig`, `extensions.zig`) | **MISSING (as a single object)** — functionality is split across multiple modules and there is no orchestrator class with `reload()`, `extendResources()`, overrides for skills/prompts/themes/agents-files/system-prompt, or settings-watcher integration |
| `reload()` async — re-reads settings, repopulates from `packageManager.resolve()`, walks CLI extension sources, applies enabled filters, runs `loadExtensions`, applies inline extension factories, runs `detectExtensionConflicts`, dedupes prompts/themes by name, loads agents files, loads system prompt + append system prompt, applies override callbacks | (none) | **MISSING** as a single reload entry point. Pi-zig discovers each resource independently and there is no central reload bus |
| `extendResources({skillPaths, promptPaths, themePaths})` — apply paths emitted by `resources_discover` extension event, with source-info attribution and `metadata.baseDir` resolution | (none) | **MISSING** |
| `applyExtensionSourceInfo(extensions, metadataByPath)` — back-fill source-info on extension tools/commands based on settings vs auto-discovery scope | partial — pi-zig writes per-resource source-info inline at discovery time |
| `detectExtensionConflicts(extensions)` — diagnose duplicate tool/flag names across extensions; surface conflicts as `extensionsResult.errors` while still loading all extensions | partial — `extension_runner.zig` JS uses first-wins precedence for tools and flags; conflict diagnostics are NOT surfaced as errors back to the user |
| `dedupePrompts(prompts)` — collision diagnostics by name | present in `src/pi/commands.zig` (`dedupePrompts` referenced at `:69, :102`) |
| `dedupeThemes(themes)` — collision diagnostics by name | present in `src/pi/themes.zig` (`dedupeThemes` referenced at `:77, :119`) |
| `discoverSystemPromptFile()` — project `.pi/SYSTEM.md` then global `~/.pi/SYSTEM.md` | present (per parity ledger context_files coverage) |
| `discoverAppendSystemPromptFile()` — project `.pi/APPEND_SYSTEM.md` then global | present |
| Override callbacks (`extensionsOverride`, `skillsOverride`, `promptsOverride`, `themesOverride`, `agentsFilesOverride`, `systemPromptOverride`, `appendSystemPromptOverride`) — SDK injection seam | **MISSING** — pi-zig has no SDK injection seam for these |
| `findSourceInfoForPath(resourcePath, extraSourceInfos, metadataByPath)` — multi-level source-info attribution including `synthetic`, extension-attributed (`<inline:N>`), and metadata-by-path lookup | partial — pi-zig writes source-info per-resource at discovery time without centralized attribution |
| `getDefaultSourceInfoForPath(filePath)` — agent dir / project dir / synthetic / scope=user/project/temporary buckets | partial — pi-zig handles these inline per-resource type |

### 1.4 Skills (`core/skills.ts`)

| Feature | Upstream behavior | Pi-zig | Status |
|---|---|---|---|
| `SkillFrontmatter`: `name`, `description` (REQUIRED, max 1024 chars), `disable-model-invocation` flag, arbitrary keys | per-skill parsing in `src/pi/commands.zig` (mention in description-prompt only) | partial — frontmatter parsing is present (per parity ledger discovery layers), but `disable-model-invocation` honoring and 1024-char validation need verification |
| `validateName(name)` — max 64 chars, lowercase a-z, 0-9, hyphens, no leading/trailing/consecutive hyphens | (not visible in pi-zig src) | **MISSING** — pi-zig does not appear to validate name format; verify by grep |
| `validateDescription(description)` — required, max 1024 chars | (not visible) | partial — required-ness is enforced via the `description: required` field, max-length not verified |
| `loadSkillsFromDir` recursive walk: `SKILL.md` makes the directory a skill root and stops recursion; otherwise direct `.md` children in root + recurse subdirectories for SKILL.md | partial — pi-zig discovers `SKILL.md` per-directory but the recursion-stop semantics and direct `.md` children need verification |
| `IgnoreMatcher` with `.gitignore`/`.ignore`/`.fdignore` hierarchical respect (prefixed patterns per-level) | (not visible) | **MISSING** — pi-zig does not apply ignore patterns when discovering skills |
| `loadSkills({cwd, agentDir, skillPaths, includeDefaults})` — global `~/.pi/skills/`, project `.pi/skills/`, explicit paths, source attribution `user`/`project`/`path` | present (per parity ledger commands.zig coverage) |
| Real-path deduplication (canonicalize symlinks before name-collision check) | partial — `canonicalizePath` is referenced in pi-zig but full real-path dedupe at skill load needs verification |
| `formatSkillsForPrompt(skills)` — XML `<available_skills><skill><name><description><location>` format; excludes `disableModelInvocation` skills | present (per parity ledger system_prompt.zig coverage); `disableModelInvocation` filter unverified |
| `createSkillSourceInfo` — source-attributed (`user`/`project`/`path`) | partial — pi-zig has source-info but the exact tagging convention needs verification |

### 1.5 Prompt templates (`core/prompt-templates.ts`)

| Feature | Upstream behavior | Pi-zig | Status |
|---|---|---|---|
| `PromptTemplate { name, description, argumentHint?, content, sourceInfo, filePath }` | present in `src/pi/commands.zig` |
| `parseCommandArgs(argsString)` — bash-style argument splitter (single+double quotes) | present (per parity ledger Skills/templates coverage) |
| `substituteArgs(content, args)` — `$1`...`$N` positional, `$@`/`$ARGUMENTS` join-all, `${@:start}`/`${@:start:length}` bash-style slice | present — verified via verify-basic smokes |
| `loadTemplateFromFile(filePath, sourceInfo)` — frontmatter (`description`, `argument-hint`), name from basename without `.md`, fallback description from first non-empty line truncated to 60 chars | partial — name + frontmatter present; the 60-char-truncated fallback description needs verification |
| `loadTemplatesFromDir` — non-recursive `.md` scan | present |
| `loadPromptTemplates({cwd, agentDir, promptPaths, includeDefaults})` — global `~/.pi/prompts/`, project `.pi/prompts/`, explicit paths | present |
| `expandPromptTemplate(text, templates)` — match `/templateName args` against loaded set, substitute args, return content | present — verified |

### 1.6 Package manager (`core/package-manager.ts`, 2538 lines)

| Surface | Upstream | Pi-zig `src/pi/package_manager.zig` | Status |
|---|---|---|---|
| `PackageManager` interface (resolve, install, installAndPersist, remove, removeAndPersist, update, listConfiguredPackages, resolveExtensionSources, addSourceToSettings, removeSourceFromSettings, setProgressCallback, getInstalledPath) | All entry points exist for `pi install`/`remove`/`update`/`list`; `setProgressCallback`/`getInstalledPath` partial |
| `ParsedSource` union — `NpmSource`/`LocalSource`/`GitSource` | present |
| `ResolvedPaths { extensions, skills, prompts, themes }` with `ResolvedResource { path, enabled, metadata }` and `PathMetadata { source, scope, origin, baseDir? }` | partial — pi-zig returns the resolved set but the precedence rank function (`resourcePrecedenceRank`) and exact "first wins" ordering after sort need verification |
| `NETWORK_TIMEOUT_MS = 10000`, `UPDATE_CHECK_CONCURRENCY = 4`, `GIT_UPDATE_CONCURRENCY = 4`, `PI_OFFLINE` env opt-out | partial — `--offline` flag is parsed, but the concurrency knobs and timeout match need verification |
| `globSync` (from `glob` package) for include glob matching in package filters | (replaced with custom wildcard matcher) — partial parity, depends on pattern complexity |
| `minimatch` for glob in extensionsOverride/skillsOverride filters | (replaced) — partial |
| `ignore` library for hierarchical `.gitignore` handling during install file collection | **MISSING** — pi-zig does not apply gitignore-style filtering during package install path collection |
| Managed npm install via `npmInstallArgv` (detects pnpm/yarn/bun, picks per-manager flags) — supports `--prefix npm/node_modules`, `--no-audit`, `--no-fund`, `--ignore-scripts` (pnpm), `add --silent` (bun), `add --silent --no-progress` (yarn) | partial — pi-zig has npm flow (per parity ledger), pnpm/yarn/bun detection and per-manager flags need verification |
| `installGitDependenciesIfPresent` — auto-runs npm/pnpm/yarn/bun install when `package.json` has `dependencies` after git clone | partial — pi-zig clones git, runs dependencies install per parity ledger |
| `update --self` — checks `pi.dev/api/latest-version`, refuses unmanaged checkout binaries, follows global bin symlinks, detects npm/pnpm/yarn/bun globally-installed pi, runs `<manager> install --global pi-coding-agent@latest --ignore-scripts` | present — verified per parity ledger |
| `markPathIgnoredByCloudSync` (macOS extended attribute to skip iCloud sync) | **MISSING** in pi-zig — package install paths are not tagged with the iCloud-ignore xattr |
| Cross-platform `getEnv()` (Linux `/proc/self/environ` fallback) | partial — pi-zig reads env via `std.process.Environ.Map`; fallback unverified |
| `parseGitUrl` (utils/git.ts) — `git+ssh://`, `git+https://`, `git@host:path`, `host/path` shorthand | partial — pi-zig parser at `:723-806` handles `git@host:path` and host/path shorthand; `git+ssh:`/`git+https:` protocol prefixes need verification |
| Concurrent update checks (Promise.all with `pLimit(4)`) for npm version polling | partial — pi-zig serializes by default unless explicit concurrency is wired |

### 1.7 Model registry (`core/model-registry.ts`, 958 lines)

| Surface | Upstream | Pi-zig | Status |
|---|---|---|---|
| `ModelRegistry` class with `getAll`, `getAvailable`, `find`, `hasConfiguredAuth`, `getApiKeyAndHeaders`, `getProviderAuthStatus`, `getProviderDisplayName`, `getApiKeyForProvider`, `isUsingOAuth`, `registerProvider`, `unregisterProvider`, `refresh` | `src/pi/models.zig` exposes equivalents for `getAll`/`getAvailable`/`find`/`hasConfiguredAuth`/`getApiKeyAndHeaders` (per parity ledger). `registerProvider`/`unregisterProvider` are MISSING (no dynamic provider registration) |
| `ModelsConfig` schema (`providers: Record<string, ProviderConfig>`) loaded from `~/.pi/models.json` with comment stripping (`stripJsonComments`), TypeBox validation, `formatValidationPath` error messages | partial — pi-zig settings layer reads `~/.pi/settings.json`; `~/.pi/models.json` reading status needs verification |
| `ProviderConfig` shape — `name?, baseUrl?, apiKey?, api?, headers?, compat?, authHeader?, models?, modelOverrides?` | partial — base reading is wired; per-model override merging needs verification |
| `ModelOverride` partial-override merging (deep cost merge, deep `compat` merge, `mergeCompat` for `openRouterRouting`/`vercelGatewayRouting`) | **MISSING** — pi-zig does not appear to merge models.json overrides into built-in model rows |
| `applyModelOverride(model, override)` — name/reasoning/thinkingLevelMap/input/cost/compat/contextWindow/maxTokens merge | **MISSING** |
| `loadCustomModels(modelsJsonPath)` — JSON-with-comments parser, schema validation, file-not-found tolerance | **MISSING** |
| `parseModels(config)` — synthesize `Model<Api>` rows from config; built-in default fallback for `api`/`baseUrl` | **MISSING** |
| Validation: built-in vs non-built-in providers, baseUrl/apiKey required when defining custom models, api required at provider-or-model level | **MISSING** |
| `validateConfig(config)` — provider/model-level validation, contextWindow/maxTokens > 0 | **MISSING** |
| `getProviderAuthStatus` — returns `models_json_command`, `models_json_key`, `environment` (with label), `auth_store` sources | partial — pi-zig auth.zig surfaces `stored` vs `env`; `models_json_*` sources are MISSING |
| `clearApiKeyCache` exported function | **MISSING** |
| OAuth provider integration: `authStorage.getOAuthProviders().modifyModels` to update baseUrl based on credentials | partial — Vertex `ya29.*` bearer routing exists (per parity ledger), but the generic `modifyModels` hook is MISSING |
| `OpenRouterRoutingSchema` (allow_fallbacks, require_parameters, data_collection, zdr, enforce_distillable_text, order, only, ignore, quantizations, sort, max_price, preferred_min_throughput, preferred_max_latency, percentile cutoffs) | **MISSING** — pi-zig has no OpenRouter routing schema. OpenRouter models flow through OpenAI-compatible shim without these knobs |
| `VercelGatewayRoutingSchema` (only, order) | **MISSING** |
| `ThinkingLevelMapSchema` (off/minimal/low/medium/high/xhigh as nullable string-or-null map) | partial — model rows include `thinkingLevelMap` (per `models.generated.zig`), but custom-override merging is MISSING |
| `OpenAICompletionsCompatSchema` — `supportsStore`, `supportsDeveloperRole`, `supportsReasoningEffort`, `supportsUsageInStreaming`, `maxTokensField` (`max_completion_tokens`/`max_tokens`), `requiresToolResultName`, `requiresAssistantAfterToolResult`, `requiresThinkingAsText`, `requiresReasoningContentOnAssistantMessages`, `thinkingFormat` (openai/openrouter/together/deepseek/zai/qwen/qwen-chat-template), `cacheControlFormat: "anthropic"`, `openRouterRouting`, `vercelGatewayRouting`, `supportsStrictMode`, `supportsLongCacheRetention` | partial — pi-zig models.generated.zig likely carries some of these via `compat` field; thinkingFormat variants for qwen/deepseek/together/zai need verification |
| `OpenAIResponsesCompatSchema` — `sendSessionIdHeader`, `supportsLongCacheRetention` | partial |
| `AnthropicMessagesCompatSchema` — `supportsEagerToolInputStreaming`, `supportsLongCacheRetention`, `sendSessionAffinityHeaders`, `supportsCacheControlOnTools`, `forceAdaptiveThinking` | partial |

### 1.8 Model resolver (`core/model-resolver.ts`, 637 lines)

| Surface | Upstream | Pi-zig | Status |
|---|---|---|---|
| `defaultModelPerProvider: Record<KnownProvider, string>` — default model id per provider (44 entries: amazon-bedrock, anthropic, openai, azure-openai-responses, openai-codex, deepseek, google, google-vertex, github-copilot, openrouter, vercel-ai-gateway, xai, groq, cerebras, zai, mistral, minimax, minimax-cn, moonshotai, moonshotai-cn, huggingface, fireworks, together, opencode, opencode-go, kimi-coding, cloudflare-workers-ai, cloudflare-ai-gateway, xiaomi, xiaomi-token-plan-cn/ams/sgp) | partial — pi-zig `src/pi/models.zig` resolves models but the explicit `defaultModelPerProvider` table for fallback selection needs verification |
| `ScopedModel { model, thinkingLevel? }` for `--model` repeat / settings `scopedModels` array | present (per parity ledger RPC `get_available_models`/`set_model`/`cycle_model`) |
| `isAlias(id)` — heuristic: id ends with `-latest` OR doesn't end with `-YYYYMMDD` | partial — pi-zig model selection picks aliases over dated rows per parity ledger; the specific date-pattern regex match needs verification |
| `findExactModelReferenceMatch(modelReference, availableModels)` — canonical `provider/modelId`, slash-prefix provider, bare-id (rejects ambiguous cross-provider matches) | partial — pi-zig matches by id + provider prefix; ambiguity rejection needs verification |
| `tryMatchModel(pattern, availableModels)` — exact, then partial (id-includes or name-includes), then alias-preference, then latest-dated-by-localeCompare | partial — pi-zig has fuzzy match; alias-preference and date-sort tiebreakers need verification |
| `parseModelPattern(pattern, availableModels, options)` — split on last colon for `:level` thinking suffix, recursive descent on prefix when suffix is valid thinking level; `allowInvalidThinkingLevelFallback` strict-mode toggle | partial — pi-zig resolves `:level` suffix per parity ledger; the recursive descent and strict-mode-fallback toggle need verification |
| `resolveModelScope(patterns, modelRegistry)` — glob support (`*`, `?`, `[`) via minimatch, per-pattern fuzzy match, dedupe via `modelsAreEqual` | partial — pi-zig accepts model patterns; glob support and dedupe needs verification |
| `resolveCliModel({cliProvider, cliModel, modelRegistry})` — case-insensitive provider lookup, `--model <provider>/<pattern>` slash-strip, `inferredProvider` fallback to raw-id match for OpenRouter-style ids (`openai/gpt-4o:extended`), `buildFallbackModel` synthesizing custom-id row for unknown ids on a known provider | partial — pi-zig wires `--provider`/`--model` resolution and slash-prefix handling per parity ledger; the OpenRouter-style `provider/model` ambiguity disambiguation and custom-id fallback need verification |
| `findInitialModel` — 5-tier priority: CLI, scoped models, restored from session, saved default from settings, first available with API key. Falls through to `defaultModelPerProvider` candidates | partial — pi-zig selects initial model (per parity ledger); explicit 5-tier ordering needs verification |
| `restoreModelFromSession(savedProvider, savedModelId, currentModel, shouldPrintMessages, modelRegistry)` — fallback chain with reason logging | partial — pi-zig restores from session per parity ledger |

### 1.9 Provider display names (`core/provider-display-names.ts`)

| Surface | Upstream | Pi-zig | Status |
|---|---|---|---|
| `BUILT_IN_PROVIDER_DISPLAY_NAMES: Record<string, string>` — 28 mappings: `anthropic→"Anthropic"`, `amazon-bedrock→"Amazon Bedrock"`, `azure-openai-responses→"Azure OpenAI Responses"`, `cerebras→"Cerebras"`, `cloudflare-ai-gateway→"Cloudflare AI Gateway"`, `cloudflare-workers-ai→"Cloudflare Workers AI"`, `deepseek→"DeepSeek"`, `fireworks→"Fireworks"`, `google→"Google Gemini"`, `google-vertex→"Google Vertex AI"`, `groq→"Groq"`, `huggingface→"Hugging Face"`, `kimi-coding→"Kimi For Coding"`, `mistral→"Mistral"`, `minimax→"MiniMax"`, `minimax-cn→"MiniMax (China)"`, `moonshotai→"Moonshot AI"`, `moonshotai-cn→"Moonshot AI (China)"`, `opencode→"OpenCode Zen"`, `opencode-go→"OpenCode Go"`, `openai→"OpenAI"`, `openrouter→"OpenRouter"`, `together→"Together AI"`, `vercel-ai-gateway→"Vercel AI Gateway"`, `xai→"xAI"`, `zai→"ZAI"`, `xiaomi→"Xiaomi MiMo"`, `xiaomi-token-plan-cn→"Xiaomi MiMo Token Plan (China)"`, `xiaomi-token-plan-ams→"Xiaomi MiMo Token Plan (Amsterdam)"`, `xiaomi-token-plan-sgp→"Xiaomi MiMo Token Plan (Singapore)"` | (none — `grep` finds no display-name map in `src/pi/`) | **MISSING** — pi-zig does NOT have a provider display-name map. Provider strings in TUI/RPC outputs use the raw provider id (e.g. `google-vertex` instead of `Google Vertex AI`). `ModelRegistry.getProviderDisplayName` has no Zig analog. Required for: `auth list`, `--list-models`, scoped-model picker UI, settings selector |

### 1.10 HTML export (`core/export-html/*`, 6 files + 2 vendored libs)

| File / surface | Upstream | Pi-zig `src/pi/html_export.zig` | Status |
|---|---|---|---|
| `index.ts` `exportSessionToHtml(sm, state?, options?)` — uses live `SessionManager` (entries+header+leafId) plus `AgentState` (systemPrompt, tools), pre-renders custom tools via `ToolHtmlRenderer` | `renderSessionHtml` in `src/pi/html_export.zig` | partial — top-level export from session file works; live AgentState systemPrompt + tools serialization is partial (parity ledger says systemPrompt/tools serialization is wired but tool pre-rendering is NOT) |
| `exportFromFile(inputPath, options?)` — standalone export from `.jsonl` without state | `exportHtmlFromFile` | present |
| `ExportOptions { outputPath?, themeName?, toolRenderer? }` | partial — outputPath and themeName supported; `toolRenderer` is **MISSING** (no `ToolHtmlRenderer` plumbing) |
| `ToolHtmlRenderer` interface — `renderCall(toolCallId, toolName, args) → string?`, `renderResult(...) → {collapsed?, expanded?}?` for custom (non-built-in) tools | (none) | **MISSING** — custom tools registered by extensions are NOT pre-rendered in HTML export. Falls back to JSON dump or generic structured rendering |
| `parseColor(color)`, `getLuminance`, `adjustBrightness`, `deriveExportColors(baseColor)` — derive page/card/info backgrounds from user-message-bg color | (similar logic exists in `src/pi/themes.zig` for theme export, per parity ledger) | partial — theme color resolution is wired but the derivation of `pageBg`/`cardBg`/`infoBg` may differ |
| `generateThemeVars(themeName?)` — emits all theme colors as CSS custom properties plus `--exportPageBg`/`--exportCardBg`/`--exportInfoBg` | partial — `src/pi/html_export.zig:315` `writeDocumentHead` injects theme CSS variables (per parity ledger); the explicit export-color triplet needs verification |
| `SessionData { header, entries, leafId, systemPrompt?, tools?, renderedTools? }` — base64-encoded JSON passed via `<script id="session-data" type="application/json">` | (pi-zig renders HTML directly without a base64-embedded data island, per parity ledger; the template is built server-side) | **DIVERGENT** — pi-zig does NOT use the upstream's HTML+JS template architecture. Upstream ships a vendored client-side renderer (`template.js` is **76 KB** of JS that handles markdown, syntax highlight, search, filtering, branch tree navigation, image modal, sidebar resize); pi-zig writes a self-contained HTML with server-rendered entries and a small inline filter script |
| `preRenderCustomTools(entries, toolRenderer)` — walks session entries, looks up custom tool calls/results, renders via `toolRenderer.renderCall/renderResult`, emits `Record<toolCallId, {callHtml, resultHtmlCollapsed, resultHtmlExpanded}>` | (none) | **MISSING** |
| `TEMPLATE_RENDERED_TOOLS = Set("bash", "read", "write", "edit", "ls")` — tools handled directly by template.js (no pre-render) | n/a — pi-zig server-renders all tools directly, no client-side dispatch table |
| `template.html` — sidebar + filter buttons (default/no-tools/user-only/labeled-only/all) + tree-container + tree-status + sidebar-resizer + image-modal | `writeSidebar` in `src/pi/html_export.zig:146` | partial — sidebar with nav + search filter is present (per parity ledger closure pass); the 5-mode filter selector (default/no-tools/user-only/labeled-only/all) is **partially MISSING** (parity ledger says "upstream filter modes" still pending) |
| `template.css` — full styles (22724 bytes) covering sidebar, content, tool rendering, code blocks, markdown, image modal, hamburger menu, responsive layout | partial — pi-zig emits a self-contained CSS (visible in `writeDocumentHead`); coverage is "approximate" per parity ledger |
| `template.js` — 76 KB client-side renderer with: markdown rendering (vendored marked), syntax highlighting (vendored highlight.js), session-tree rendering, branch navigation, filter modes, search, image modal, sidebar resize, ANSI-to-HTML for custom tool output | (none — pi-zig has a small inline filter script per parity ledger HTML closure pass) | **MAJOR DIVERGENCE** — pi-zig does NOT vendor `marked.min.js` (39 KB) or `highlight.min.js` (122 KB). Markdown is rendered approximate via inline `writeProse`/`writeInlineMarkdown`/`writeInlineEmphasis` per `html_export.zig:812-908`; syntax highlight is plain `<pre><code>` (no tokenization). Parity ledger acknowledges this: "Markdown/syntax-highlight is **approximate**" |
| `ansi-to-html.ts` — ANSI escape converter for SGR codes 0-7/30-37/40-47/90-97/100-107, 256-color (38;5;N / 48;5;N), RGB true color (38;2;R;G;B / 48;2;R;G;B), bold/dim/italic/underline, palette including 6×6×6 color cube and 24-step grayscale | (none) | **MISSING** — pi-zig has no ANSI-to-HTML converter. Custom tool output containing ANSI escapes from extensions would not render correctly in HTML export. (Built-in tools strip ANSI before persistence.) |
| `tool-renderer.ts` `createToolHtmlRenderer({getToolDefinition, theme, cwd, width=100})` — invokes tool's `renderCall`/`renderResult` via TUI render path, captures component output as ANSI lines, runs `ansiLinesToHtml` to convert | (none) | **MISSING** — depends on `ToolHtmlRenderer` interface and ANSI converter, neither of which exist |
| `vendor/marked.min.js` (39055 bytes) — Markdown rendering vendored | (not vendored) | **MISSING** |
| `vendor/highlight.min.js` (121727 bytes) — Syntax highlight vendored | (not vendored) | **MISSING** |

---

## 2. Surface mapping summary (counts)

| Domain | Upstream surfaces | Present | Partial | MISSING |
|---|---:|---:|---:|---:|
| Built-in tools (factories + ops + render) | 15 modules | 0 | 14 | 1 (file-mutation-queue) |
| `pi.*` API methods | 22 | 7 | 1 (commands argument completions partial) | 14 |
| Extension lifecycle events (production dispatch) | 29 | 2 | 9 | 18 |
| Extension UI context methods | 27 | 0 | 5 | 22 |
| Extension command context methods | 6 | 0 | 0 | 6 (JS stubs only) |
| Extension loader features | 7 | 4 | 1 | 2 (jiti, inline factory) |
| Extension runner features | 16 | 4 | 6 | 6 |
| Resource loader features | 13 | 3 | 4 | 6 |
| Skill loader features | 9 | 4 | 3 | 2 |
| Prompt template features | 7 | 6 | 1 | 0 |
| Package manager features | 14 | 6 | 6 | 2 |
| Model registry features | 18 | 4 | 6 | 8 |
| Model resolver features | 10 | 1 | 8 | 1 |
| Provider display names | 1 (28-entry map) | 0 | 0 | 1 |
| HTML export features | 12 | 2 | 3 | 7 |

---

## 3. Gap detail — extension API methods and event dispatch

### 3.1 `pi.registerProvider` / `pi.unregisterProvider` (MISSING)

The two example extension packages `pi-extension-custom-provider-anthropic` and `pi-extension-custom-provider-gitlab-duo` declared in the upstream monorepo workspace **cannot run under pi-zig**. The runner JS shim does not bind `registerProvider`/`unregisterProvider` to `api`. Loading these extensions either:
- silently no-ops (registration goes nowhere), or
- throws `TypeError: pi.registerProvider is not a function` depending on factory code shape.

Implementation cost: requires a queued-pre-bind / immediate-post-bind path mirroring `extensions/types.ts:ExtensionRuntimeState.{registerProvider,unregisterProvider}` plus dynamic `ModelRegistry` mutation (which pi-zig models registry doesn't currently expose). The provider config supports inline `oauth { login, refreshToken, getApiKey, modifyModels }` closures which would need to bridge through the persistent node runner back into pi-zig auth/token flow.

### 3.2 `pi.registerShortcut` and reserved-keybinding diagnostics (MISSING)

`runner.ts:62-80` declares 15 reserved keybindings (`app.interrupt`, `app.clear`, `app.exit`, `app.suspend`, `app.thinking.cycle`, `app.model.cycleForward`, `app.model.cycleBackward`, `app.model.select`, `app.tools.expand`, `app.thinking.toggle`, `app.editor.external`, `app.message.followUp`, `tui.input.submit`, `tui.select.confirm`, `tui.select.cancel`, `tui.input.copy`, `tui.editor.deleteToLineEnd`) that cannot be overridden by extensions. Pi-zig has no shortcut registration path at all, so the reserved-list enforcement is moot until shortcut registration exists.

### 3.3 `pi.registerMessageRenderer` and custom message rendering (MISSING)

Without a renderer registration, `CustomMessage<T>` entries persisted via `pi.sendMessage()` and `pi.appendEntry()` cannot be visualized in the TUI or HTML export. Pi-zig persists them (parity ledger confirms session-state persistence) but they render as raw text or are hidden entirely. The Preact workbench (`frontend/`) does its own rendering, so this only affects native TUI + HTML export.

### 3.4 `pi.exec`, `pi.setSessionName`, `pi.setLabel`, `pi.getActiveTools`, `pi.getAllTools`, `pi.setActiveTools`, `pi.getCommands`, `pi.setModel`, `pi.getThinkingLevel`, `pi.setThinkingLevel`, `pi.events` (all MISSING)

These 10 read/write methods on the runtime require the `bindCore(actions, contextActions, providerActions)` wiring path that pi-zig has not implemented. The runner JS exposes none of them. Calls would throw `TypeError`.

Implementation cost varies:
- `pi.exec` — straightforward (spawn through pi-zig's `runShell` via JSON RPC back from node to Zig)
- `pi.getActiveTools` / `pi.getAllTools` / `pi.setActiveTools` — needs a per-session tool state cache in the runner JS, synced from Zig via session start/refresh events
- `pi.setModel` / `pi.setThinkingLevel` — needs RPC commands routed back into pi-zig session state, with auth refresh and provider re-binding
- `pi.setSessionName` — RPC has the inbound command; just needs the JS-side binding
- `pi.setLabel` — needs session entry labeling support in `src/pi/session.zig`
- `pi.events` (EventBus) — needs a process-bound multi-extension pubsub channel; the JS shim's `events: { on(){}, emit(){} }` stub is a placeholder, not a real bus

### 3.5 Lifecycle event dispatch (14+ events MISSING in production)

The parity ledger reports `tool_call, tool_result, input, context` as "dispatched". Reading the production code shows:

- `tool_call` — DISPATCHED via `agent.zig` BeforeToolCallResult callback
- `tool_result` — DISPATCHED via `agent.zig` AfterToolCallResult callback
- `input` — **NOT DISPATCHED** in production (only `extension_runner.zig` unit tests fire it via `dispatchLifecycleEvent`). RPC/print/JSON prompt entry points (`src/pi/rpc.zig:prompt`/`steer`/`follow_up`, `src/pi/cli_runtime.zig` print/json entry) do not call `runner.dispatchLifecycleEvent(.{ .type = "input", ... })` before handling user text
- `context` — **NOT DISPATCHED** in production (transform-style result that should mutate messages before sending to provider; no agent.zig site invokes it)

Production dispatch sites (from `grep emitLifecycle agent.zig rpc.zig`):

| Event | agent.zig | rpc.zig | Total prod sites |
|---|:---:|:---:|:---:|
| `turn_start` | yes (line 386) | — | 1 |
| `before_provider_request` | yes (line 406) | — | 1 |
| `after_provider_response` | yes (line 414, hardcoded `status:200`) | — | 1 |
| `message_start` | yes (lines 424, 437, hardcoded `role:assistant`) | — | 1 |
| `message_end` | yes (lines 425, 439, hardcoded `role:assistant`, result discarded) | — | 1 |
| `turn_end` | yes (lines 426, 500) | — | 1 |
| `session_start` | — | yes (line 2015) | 1 |
| `agent_start` | — | yes (line 2103, hardcoded `"{}"`) | 1 |
| `agent_end` | — | yes (line 2131, hardcoded `"{}"`, no `messages` payload) | 1 |
| `user_bash` | — | yes (line 2036) | 1 |
| `tool_call` | yes (via callback path) | yes (via callback path) | 2 paths |
| `tool_result` | yes (via callback path) | yes (via callback path) | 2 paths |

ALL OTHER 17 EVENTS (`resources_discover`, `session_before_switch/fork/compact/tree`, `session_compact`, `session_shutdown`, `session_tree`, `context`, `before_agent_start`, `message_update`, `tool_execution_start/update/end`, `model_select`, `thinking_level_select`, `input`) — **never emitted in production code**.

The runner JS `dispatchLifecycleEvent` handler can process all 29 event types, but the Zig side never calls it for those 17 event types.

Moreover: of the 11 events that ARE dispatched, none of their **result-application semantics** are honored. `RuntimeLifecycleEmitContext.emit` (`rpc.zig:3834-3842`) explicitly discards the result:

```zig
const result = context.runner.dispatchLifecycleEvent(.{
    .type = event.type,
    .fields_json = event.fields_json,
}) catch return;
result.deinit(context.runner.allocator);  // <-- result discarded
```

This means:
- `before_provider_request`-style transform → returned payload is **never applied** to the actual outgoing request
- `context` (would-be dispatched) → returned messages array is **never substituted** for the messages sent to the provider
- `message_end` → returned replacement `message` is **never written** to the transcript
- `before_agent_start` (would-be dispatched) → returned `{messages?, systemPrompt?}` is **never applied** to the agent loop
- `session_before_*` → returned `{cancel: true}` is **never honored** to cancel the operation
- `model_select` / `thinking_level_select` / `user_bash` → first-decisive short-circuit return value is **never consumed** to actually swap the model/level/exec-backend (with the exception of `user_bash` command-string rewrite, which is consumed at `rpc.zig:3191`)
- `input` → `{action: "transform" | "handled"}` is **never honored** to suppress or rewrite the user input

### 3.6 Resource event chain (`resources_discover`, `extendResources`) MISSING

Upstream `DefaultResourceLoader.reload()` calls `emitResourcesDiscover(cwd, reason)`, then `extendResources({skillPaths, promptPaths, themePaths})` to merge contributed resource paths. Pi-zig has no equivalent: extensions cannot inject skill/prompt/theme paths at runtime. Skills/prompts/themes are discovered only from settings + filesystem + package manifests at startup, with no late-bound contribution.

---

## 4. Honest parity estimate

Note: the existing parity ledger (`docs/parity.md`) reports **Extensions at 100%** and the methods-and-events table at:
- registered methods "in_progress (wired in runner)": 7 of 22 → 32%
- events "in_progress (dispatched)": 4 of 29 → 14%

This audit revises the event dispatch downward (only 11 of 29 are emitted in production, and only 2 of those 11 honor result semantics; `input` and `context` listed in the parity ledger are not actually dispatched in production).

### Component-level parity (this gap area only)

| Component | Estimated parity | Rationale |
|---|---:|---|
| Built-in tools (7 tools, output/render) | **75%** | Core tool execution is at parity (truncate, fuzzy edit, NFKC, BOM, line-ending preserve, ANSI strip, partial-output, image content parts, non-vision note). Missing: pluggable `*Operations` seams (BashOperations, EditOperations, ReadOperations, etc.), `withFileMutationQueue` file-level serialization, `BashSpawnHook`, image auto-resize worker, macOS path variant fallbacks, edit-tool `details.diff`/`patch`/`firstChangedLine` fields, `prepareArguments` legacy compat, TUI live-preview integration |
| Extension `pi.*` API surface (22 methods) | **35%** | 8 of 22 wired. Critical gaps: `registerProvider`/`unregisterProvider` (breaks 2 of 4 example extensions), `setModel`/`setActiveTools`/`getActiveTools`/`getAllTools`/`exec`/`setSessionName`/`setLabel` (all runtime-management methods), `registerShortcut` and `registerMessageRenderer` (TUI-side hooks) |
| Extension lifecycle events (29 events) | **15%** | Only `tool_call` + `tool_result` actually emit + consume results. 9 more events emit notify-style without result application. 18 events never dispatched in production. Critical missing: `resources_discover` (no extendResources path), `before_agent_start` (no system-prompt rewrite), `context` (no message-array transform), `model_select`/`thinking_level_select` (no model swap consent), `input` (no input rewrite), `session_before_*` (no operation cancellation), `tool_execution_*` (no extension-visible tool lifecycle) |
| Extension UI context (27 methods) | **15%** | 5 of 27 methods stubbed (`notify`, `select`, `confirm`, `input`, `prompt`). All TUI integration (status, widgets, footer/header, custom overlays, editor injection, theme inspection, tools-expanded) MISSING. Headless `confirm` blocking is verified, but every UI-visible feature is absent |
| Extension command context (6 methods) | **5%** | All 6 methods exist as `{cancelled:true}` stubs that do nothing. No actual session manipulation from extension commands |
| Extension loader (jiti aliasing, virtual modules, inline factory) | **65%** | File discovery + manifest reading + persistent-process runner are at parity. No jiti virtual-module substitution (extensions must resolve their own deps via user-side node_modules), no inline-factory load path |
| Extension runner (bindCore, emit*, conflict detection, shortcut diagnostics) | **40%** | `dispatchLifecycleEvent` is the single dispatch entry. `bindCore`/`bindCommandContext` not modeled. Per-event aggregation logic exists in runner JS but is rarely invoked from Zig. Shortcut/command/extension conflict diagnostics not wired back to user |
| Resource loader (DefaultResourceLoader, reload, extendResources) | **55%** | Resource discovery is at parity per-domain (skills, prompts, themes, agents files, system prompt). MISSING: single orchestrator class, `reload()` central entry, `extendResources()` event-driven contribution, override callbacks for SDK injection |
| Skill loader | **75%** | Discovery + frontmatter + XML formatting present. MISSING: name/description length validation (1024/64 chars), `disable-model-invocation` filter, `.gitignore`/`.ignore`/`.fdignore` hierarchical respect during skill walk |
| Prompt templates | **90%** | Discovery + frontmatter + arg substitution + slash expansion all present. Minor MISSING: 60-char-truncated fallback description from body |
| Package manager | **65%** | npm/git/local install + update + list + self-update wired. MISSING: `markPathIgnoredByCloudSync` (macOS xattr), `installGitDependenciesIfPresent` per-manager flags (pnpm/yarn/bun), full `ignore` library for gitignore-based path collection, full concurrency knobs, full `parseGitUrl` protocol-prefix coverage |
| Model registry (models.json, overrides) | **40%** | Built-in models + auth resolution + provider-env wired. MISSING: `~/.pi/models.json` loading, JSON-with-comments stripping, `ModelDefinitionSchema` validation, `applyModelOverride` deep merge (cost+compat+thinkingLevelMap+contextWindow+maxTokens), `mergeCompat` (openRouterRouting + vercelGatewayRouting), per-model headers, dynamic `registerProvider`/`unregisterProvider` |
| Model resolver | **70%** | Initial selection + fuzzy match + slash-prefix + scoped models present. MISSING: `defaultModelPerProvider` explicit fallback table verification, alias-preference + date-sort tiebreakers, recursive thinking-level descent, glob pattern support (`*`, `?`, `[`) via minimatch, ambiguity rejection for cross-provider bare-id matches |
| Provider display names | **0%** | No display-name map exists in pi-zig. Provider ids surface verbatim everywhere (e.g. `google-vertex` instead of `Google Vertex AI`) |
| HTML export | **55%** | Server-rendered HTML with sidebar nav, search filter, theme CSS, fenced code, anchors, timestamps — all present (verified per parity ledger closure pass). MISSING: vendored marked.min.js / highlight.min.js (markdown + syntax highlight are approximate), ANSI-to-HTML converter, custom tool `ToolHtmlRenderer` interface + plumbing, 5-mode filter (default/no-tools/user-only/labeled-only/all) parity, branch-tree sidebar with active-path markers |

### Weighted aggregate for this gap area

Treating each surface domain by approximate weight (extension API + events are the largest, since they unlock the entire extension ecosystem):

| Domain | Weight | Parity | Contribution |
|---|---:|---:|---:|
| Built-in tools | 15 | 75% | 11.25 |
| `pi.*` API surface (22 methods) | 12 | 35% | 4.20 |
| Lifecycle events (production dispatch + result application) | 12 | 15% | 1.80 |
| Extension UI context | 8 | 15% | 1.20 |
| Extension command context | 4 | 5% | 0.20 |
| Extension loader | 5 | 65% | 3.25 |
| Extension runner | 8 | 40% | 3.20 |
| Resource loader | 6 | 55% | 3.30 |
| Skill loader | 4 | 75% | 3.00 |
| Prompt templates | 3 | 90% | 2.70 |
| Package manager | 7 | 65% | 4.55 |
| Model registry (models.json) | 6 | 40% | 2.40 |
| Model resolver | 4 | 70% | 2.80 |
| Provider display names | 1 | 0% | 0.00 |
| HTML export | 5 | 55% | 2.75 |
| **TOTAL** | **100** | — | **46.60** |

**Honest gap-04 parity estimate: ~47%.**

This sits well below the `docs/parity.md` weighted-total figure of 100% for the "Extensions" row (7/110 weight @ 100%) — because the parity ledger weights extensions as a single 7-point line item and credits it for the persistent-runner + register-tool/register-command/register-flag wiring. The honest read across **all** 14 extension API methods + 17 lifecycle events that pi-zig does not emit + the UI/command context gaps is much lower than 100%. The parity ledger explicitly notes "full upstream `jiti` and long-lived extension runner binding, full discovered extension lifecycle plus interactive/TUI registered-command context actions, streaming/queued `pi.sendMessage` flows, flag validation/events, ... are still missing" in the row text — those caveats are real and material.

The model-registry models.json layer (~40% — no custom-model schema loading) and the provider-display-names file (0%) are the most surprising untouched surfaces given how short and self-contained those upstream files are. HTML export's vendored marked + highlight + custom-tool renderer also represent a substantial code volume gap (~160 KB of vendored JS + the ANSI converter + tool-renderer module not ported).

---

## 5. References

- Upstream pinned at `fc8a155` per `docs/inventory/upstream-inventory.json` and `docs/upstream-inventory.md`
- Pi-zig sources audited:
  - `/Users/keer/projects/pi-zig/src/pi/tools.zig` (95087 bytes)
  - `/Users/keer/projects/pi-zig/src/pi/extensions.zig` (39789 bytes)
  - `/Users/keer/projects/pi-zig/src/pi/extension_runner.zig` (142711 bytes)
  - `/Users/keer/projects/pi-zig/src/pi/commands.zig` (85951 bytes)
  - `/Users/keer/projects/pi-zig/src/pi/themes.zig` (55828 bytes)
  - `/Users/keer/projects/pi-zig/src/pi/package_manager.zig` (100901 bytes)
  - `/Users/keer/projects/pi-zig/src/pi/models.zig` (37507 bytes)
  - `/Users/keer/projects/pi-zig/src/pi/models.generated.zig` (685311 bytes)
  - `/Users/keer/projects/pi-zig/src/pi/html_export.zig` (79186 bytes)
  - `/Users/keer/projects/pi-zig/src/pi/agent.zig` (100275 bytes — for tool execution + lifecycle emit sites)
  - `/Users/keer/projects/pi-zig/src/pi/rpc.zig` (241474 bytes — for lifecycle emit sites + RuntimeLifecycleEmitContext)
- Existing parity ledger context (cross-checked): `/Users/keer/projects/pi-zig/docs/parity.md`, `/Users/keer/projects/pi-zig/docs/upstream-inventory.md`
- No code modified during this audit.

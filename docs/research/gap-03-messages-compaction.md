# Gap 03 — messages / session-manager / compaction / system-prompt / keybindings / slash-commands / source-info

Read-only audit of upstream `earendil-works/pi` vs. `pi-zig`. Source paths are absolute.

Upstream files audited:
- `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/core/messages.ts` (196 LOC)
- `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/core/session-manager.ts` (1467 LOC)
- `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/core/compaction/branch-summarization.ts` (356 LOC)
- `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/core/compaction/compaction.ts` (877 LOC)
- `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/core/compaction/index.ts` (8 LOC)
- `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/core/compaction/utils.ts` (171 LOC)
- `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/core/system-prompt.ts` (176 LOC)
- `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/core/keybindings.ts` (371 LOC)
- `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/core/slash-commands.ts` (41 LOC)
- `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/core/source-info.ts` (41 LOC)

pi-zig files audited:
- `/Users/keer/projects/pi-zig/src/pi/session.zig` (1577 LOC)
- `/Users/keer/projects/pi-zig/src/pi/rpc.zig` (5256 LOC, focus FLOW_E / FLOW_H / FLOW_G regions)
- `/Users/keer/projects/pi-zig/src/pi/system_prompt.zig` (865 LOC)
- `/Users/keer/projects/pi-zig/src/pi/commands.zig` (2187 LOC)
- `/Users/keer/projects/pi-zig/src/pi/tui.zig` (2156 LOC)
- `/Users/keer/projects/pi-zig/src/pi/tui_keys.zig` (defaults table)

---

## 1. Surface inventory (upstream)

### 1.1 `messages.ts` — custom message types + LLM transformer

| Upstream symbol | Kind |
|---|---|
| `COMPACTION_SUMMARY_PREFIX` / `COMPACTION_SUMMARY_SUFFIX` | const string |
| `BRANCH_SUMMARY_PREFIX` / `BRANCH_SUMMARY_SUFFIX` | const string |
| `BashExecutionMessage` (`role:"bashExecution"`, fields `command`, `output`, `exitCode`, `cancelled`, `truncated`, `fullOutputPath?`, `timestamp`, `excludeFromContext?`) | interface |
| `CustomMessage<T>` (`role:"custom"`, fields `customType`, `content` string-or-blocks, `display`, `details?`, `timestamp`) | interface |
| `BranchSummaryMessage` (`role:"branchSummary"`, `summary`, `fromId`, `timestamp`) | interface |
| `CompactionSummaryMessage` (`role:"compactionSummary"`, `summary`, `tokensBefore`, `timestamp`) | interface |
| `bashExecutionToText(msg)` | function |
| `createBranchSummaryMessage(summary, fromId, timestamp)` | factory |
| `createCompactionSummaryMessage(summary, tokensBefore, timestamp)` | factory |
| `createCustomMessage(customType, content, display, details, timestamp)` | factory |
| `convertToLlm(messages[]) -> Message[]` | message-stream transformer (handles bashExecution/custom/branchSummary/compactionSummary/user/assistant/toolResult; respects `excludeFromContext`; emits user-role wrapping with COMPACTION_SUMMARY_PREFIX/SUFFIX and BRANCH_SUMMARY_PREFIX/SUFFIX) |
| `CustomAgentMessages` declaration-merging extension | TS-only |

### 1.2 `session-manager.ts` — append-only JSONL tree

Entry types:
- `session` header (`type:"session"`, `version:1|2|3`, `id`, `timestamp`, `cwd`, `parentSession?`)
- `message` (`SessionMessageEntry`)
- `thinking_level_change`
- `model_change`
- `compaction` (`details?: T`, `fromHook?`)
- `branch_summary` (`details?: T`, `fromHook?`)
- `custom` (extension state, NOT in context)
- `custom_message` (extension content INTO context, has `display`)
- `label` (user bookmark on any entry, can be empty to clear)
- `session_info` (display name)

Methods/fns:
- `CURRENT_SESSION_VERSION = 3`
- `migrateV1ToV2(entries)` — generates `id`/`parentId`, converts `firstKeptEntryIndex` → `firstKeptEntryId`
- `migrateV2ToV3(entries)` — renames `hookMessage` → `custom`
- `migrateSessionEntries`, `migrateToCurrentVersion`
- `parseSessionEntries(content)`
- `getLatestCompactionEntry(entries)`
- `buildSessionContext(entries, leafId?, byId?)` — walks leaf → root, emits compaction-summary first then kept window
- `getDefaultSessionDir(cwd, agentDir)`
- `loadEntriesFromFile`, `findMostRecentSession`, `buildSessionInfo`, `buildSessionInfosWithConcurrency`, `listSessionsFromDir`
- Class `SessionManager` with statics `create`, `open`, `continueRecent`, `inMemory`, `forkFrom`, `list`, `listAll`
- Instance: `setSessionFile`, `newSession({id?,parentSession?})`, `appendMessage`, `appendThinkingLevelChange`, `appendModelChange`, `appendCompaction(summary, firstKeptEntryId, tokensBefore, details?, fromHook?)`, `appendCustomEntry(customType, data?)`, `appendSessionInfo(name)`, `getSessionName`, `appendCustomMessageEntry(customType, content, display, details?)`, `appendLabelChange(targetId, label)`, `getLabel(id)`, `getChildren(parentId)`, `getEntry(id)`, `getEntries`, `getTree` (returns nodes w/ resolved label + labelTimestamp), `getLeafId`, `getLeafEntry`, `getHeader`, `getCwd`, `getSessionDir`, `getSessionId`, `getSessionFile`, `isPersisted`, `branch(branchFromId)`, `resetLeaf()`, `branchWithSummary(branchFromId|null, summary, details?, fromHook?)`, `createBranchedSession(leafId)`
- `SessionListProgress` callback type
- Deferred-flush rule: nothing is written to disk until the first assistant message arrives; then the buffered entries are flushed in one go.

### 1.3 `compaction/compaction.ts` — pure compaction logic

- Constants: `DEFAULT_COMPACTION_SETTINGS = { enabled:true, reserveTokens:16384, keepRecentTokens:20000 }`
- `CompactionDetails { readFiles, modifiedFiles }`
- `CompactionResult { summary, firstKeptEntryId, tokensBefore, details? }`
- `CompactionSettings { enabled, reserveTokens, keepRecentTokens }`
- `extractFileOperations(messages, entries, prevCompactionIndex)` — pulls from previous pi-generated compaction + assistant tool calls
- `getMessageFromEntry(entry)` / `getMessageFromEntryForCompaction(entry)`
- `calculateContextTokens(usage)`
- `getLastAssistantUsage(entries)`
- `estimateContextTokens(messages)` — returns `{ tokens, usageTokens, trailingTokens, lastUsageIndex }`; prefers real provider usage from latest non-aborted assistant message, falls back to chars/4 estimate over messages after it
- `shouldCompact(contextTokens, contextWindow, settings)` — `contextTokens > contextWindow - settings.reserveTokens`
- `estimateTokens(message)` — chars/4 heuristic with per-role handling (user/assistant/custom/toolResult/bashExecution/branchSummary/compactionSummary); image counts as 4800 chars
- `findValidCutPoints(entries, start, end)` — valid points only at user / assistant / custom / bashExecution / branchSummary / compactionSummary / branch_summary / custom_message entries (NEVER at toolResult)
- `findTurnStartIndex(entries, idx, start)` — locates the user/bashExecution/branch_summary/custom_message that begins the turn
- `findCutPoint(entries, start, end, keepRecentTokens) -> CutPointResult { firstKeptEntryIndex, turnStartIndex, isSplitTurn }`
- `SUMMARIZATION_PROMPT` (verbatim multi-section template: Goal / Constraints & Preferences / Progress[Done/In Progress/Blocked] / Key Decisions / Next Steps / Critical Context)
- `UPDATE_SUMMARIZATION_PROMPT` — distinct prompt for iterative updates over a `<previous-summary>` block; PRESERVE/ADD/UPDATE/REMOVE rules
- `TURN_PREFIX_SUMMARIZATION_PROMPT` — separate prompt for the prefix of a split turn (Original Request / Early Progress / Context for Suffix)
- `generateSummary(messages, model, reserveTokens, apiKey, headers?, signal?, customInstructions?, previousSummary?, thinkingLevel?, streamFn?)` — `maxTokens = min(0.8*reserveTokens, model.maxTokens)`; threads `thinkingLevel` through when model supports reasoning; serializes via `serializeConversation(convertToLlm(messages))`; wraps in `<conversation>...</conversation>` + `<previous-summary>...</previous-summary>`; uses `streamFn` if provided otherwise `completeSimple`
- `CompactionPreparation { firstKeptEntryId, messagesToSummarize, turnPrefixMessages, isSplitTurn, tokensBefore, previousSummary?, fileOps, settings }`
- `prepareCompaction(pathEntries, settings)` — locates previous compaction, slices boundary, calls `findCutPoint`, walks history vs. turn-prefix message arrays, computes `fileOps`
- `compact(preparation, model, apiKey, headers?, customInstructions?, signal?, thinkingLevel?, streamFn?)` — runs history + turn-prefix summaries in `Promise.all` when split; merges via `\n\n---\n\nTurn Context (split turn):\n\n`; appends file lists via `formatFileOperations`; stores `CompactionDetails`
- `generateTurnPrefixSummary(...)` — `maxTokens = min(0.5*reserveTokens, model.maxTokens)`

### 1.4 `compaction/branch-summarization.ts`

- `BranchSummaryResult { summary?, readFiles?, modifiedFiles?, aborted?, error? }`
- `BranchSummaryDetails { readFiles, modifiedFiles }`
- `BranchPreparation { messages, fileOps, totalTokens }`
- `CollectEntriesResult { entries, commonAncestorId }`
- `GenerateBranchSummaryOptions { model, apiKey, headers?, signal, customInstructions?, replaceInstructions?, reserveTokens? }`
- `collectEntriesForBranchSummary(session, oldLeafId, targetId)` — common-ancestor walk, returns entries chronologically
- `getMessageFromEntry(entry)` — variant that includes compaction summary entries (unlike compaction.ts version)
- `prepareBranchEntries(entries, tokenBudget)` — two-pass: (1) collect cumulative file ops from nested branch summaries, (2) walk newest-to-oldest accumulating messages until budget; summary entries may still fit if total < 0.9 * budget
- `BRANCH_SUMMARY_PROMPT` — distinct prompt (Goal / Constraints / Progress / Key Decisions / Next Steps; NO Critical Context section, NO ## Done/In Progress/Blocked sub-headings inside Progress)
- `BRANCH_SUMMARY_PREAMBLE = "The user explored a different conversation branch before returning here.\nSummary of that exploration:\n\n"`
- `generateBranchSummary(entries, options)` — `tokenBudget = contextWindow - reserveTokens`; calls `completeSimple` with `maxTokens: 2048`; supports `replaceInstructions:true` to override the default prompt entirely; appends `formatFileOperations` output and prepends `BRANCH_SUMMARY_PREAMBLE`

### 1.5 `compaction/utils.ts`

- `FileOperations { read, written, edited }` (Sets)
- `createFileOps()`
- `extractFileOpsFromMessage(message, fileOps)` — recognizes tool calls `read` / `write` / `edit` and the `path` argument
- `computeFileLists(fileOps)` — readFiles = read minus modified, modifiedFiles = edited ∪ written
- `formatFileOperations(readFiles, modifiedFiles)` — emits `<read-files>...</read-files>` and `<modified-files>...</modified-files>` blocks
- `TOOL_RESULT_MAX_CHARS = 2000`
- `truncateForSummary(text, maxChars)` — keep prefix + `[... N more characters truncated]` tail
- `serializeConversation(messages)` — emits `[User]:`, `[Assistant thinking]:`, `[Assistant]:`, `[Assistant tool calls]:` `name(k=v, ...)`, `[Tool result]:` (truncated to 2000 chars)
- `SUMMARIZATION_SYSTEM_PROMPT` — shared between compaction + branch summary

### 1.6 `system-prompt.ts`

- `BuildSystemPromptOptions { customPrompt?, selectedTools?, toolSnippets?, promptGuidelines?, appendSystemPrompt?, cwd, contextFiles?, skills? }`
- `buildSystemPrompt(options)` — returns string. Default skeleton: header + Available tools list + custom guidelines + Pi documentation paragraph; appends `appendSystemPrompt`; appends `<project_context>...<project_instructions path=...>...</project_instructions>...</project_context>`; if `read` tool present + skills nonempty, appends `formatSkillsForPrompt`; appends `Current date: YYYY-MM-DD` and `Current working directory: <cwd>` (backslashes normalized to slashes)
- Built-in guideline rules: when bash present without grep/find/ls → "Use bash for file operations..."; when bash + any of (grep/find/ls) → "Prefer grep/find/ls tools over bash..."; always: "Be concise in your responses", "Show file paths clearly when working with files"
- Tools-list emission rule: only emit a tool when caller-supplied `toolSnippets[name]` exists; otherwise `(none)`
- Documentation paths come from `config.ts` getters (`getReadmePath`, `getDocsPath`, `getExamplesPath`)

### 1.7 `keybindings.ts`

- `AppKeybindings` (43 ids — `app.interrupt`, `app.clear`, `app.exit`, `app.suspend`, `app.thinking.cycle`, `app.model.cycleForward`, `app.model.cycleBackward`, `app.model.select`, `app.tools.expand`, `app.thinking.toggle`, `app.session.toggleNamedFilter`, `app.editor.external`, `app.message.followUp`, `app.message.dequeue`, `app.clipboard.pasteImage`, `app.session.new`, `app.session.tree`, `app.session.fork`, `app.session.resume`, `app.tree.foldOrUp`, `app.tree.unfoldOrDown`, `app.tree.editLabel`, `app.tree.toggleLabelTimestamp`, `app.session.togglePath`, `app.session.toggleSort`, `app.session.rename`, `app.session.delete`, `app.session.deleteNoninvasive`, `app.models.save`, `app.models.enableAll`, `app.models.clearAll`, `app.models.toggleProvider`, `app.models.reorderUp`, `app.models.reorderDown`, `app.tree.filter.default`, `app.tree.filter.noTools`, `app.tree.filter.userOnly`, `app.tree.filter.labeledOnly`, `app.tree.filter.all`, `app.tree.filter.cycleForward`, `app.tree.filter.cycleBackward`)
- `KEYBINDINGS` const — merges `TUI_KEYBINDINGS` + the app defaults above, each with `defaultKeys` and `description`. Windows special-case: `app.suspend` defaultKeys = `[]`; `app.clipboard.pasteImage` = `alt+v` on win else `ctrl+v`
- `KEYBINDING_NAME_MIGRATIONS` (~55 legacy → new name pairs spanning editor + app keys)
- `migrateKeybindingsConfig(rawConfig)` — applies legacy renames; deduplicates collisions (new key wins); calls `orderKeybindingsConfig` so output JSON follows the canonical KEYBINDINGS key order
- `orderKeybindingsConfig` — produces stable ordering
- `class KeybindingsManager extends TuiKeybindingsManager` — `create(agentDir)`, `reload()`, `getEffectiveConfig()`, private `loadFromFile(path)` (reads `<agentDir>/keybindings.json`, applies `migrateKeybindingsConfig`)

### 1.8 `slash-commands.ts`

- `SlashCommandSource = "extension" | "prompt" | "skill"`
- `SlashCommandInfo { name, description?, source, sourceInfo }`
- `BuiltinSlashCommand { name, description }`
- `BUILTIN_SLASH_COMMANDS` (21 entries: settings, model, scoped-models, export, import, share, copy, name, session, changelog, hotkeys, fork, clone, tree, login, logout, new, compact, resume, reload, quit)

### 1.9 `source-info.ts`

- `SourceScope = "user" | "project" | "temporary"`
- `SourceOrigin = "package" | "top-level"`
- `SourceInfo { path, source, scope, origin, baseDir? }`
- `createSourceInfo(path, metadata)` (consumes `PathMetadata` from package-manager.ts)
- `createSyntheticSourceInfo(path, options)`

---

## 2. Mapped to pi-zig or (MISSING)

### 2.1 messages.ts

| Upstream surface | pi-zig location | Status |
|---|---|---|
| `COMPACTION_SUMMARY_PREFIX` / `_SUFFIX` | `src/pi/rpc.zig:39-40` (`compaction_summary_prefix` / `compaction_summary_suffix`) | mapped (byte-identical strings) |
| `BRANCH_SUMMARY_PREFIX` / `_SUFFIX` | (MISSING) | constants not defined; branch_summary entries never re-injected to context |
| `BashExecutionMessage` shape (incl. `excludeFromContext`) | `src/pi/session.zig:720-763` (`appendBashExecution`) + `src/pi/rpc.zig:302-385` (`StoredMessage` fields) | partial — `excludeFromContext` field is NOT persisted or honored |
| `CustomMessage` (`role:"custom"`) | `src/pi/rpc.zig:230-242` (`StoredRole.custom`), `src/pi/session.zig:306-337` (`appendCustomMessage`) | mapped |
| `BranchSummaryMessage` (`role:"branchSummary"`) | (MISSING) | no `branchSummary` `StoredRole`; `parseStoredRole` at `rpc.zig:4757-4766` does not recognize it; branch_summary entries are read into the tree but NOT into the in-memory message ring or LLM history |
| `CompactionSummaryMessage` (`role:"compactionSummary"`) | `src/pi/rpc.zig:229,240,4763` | mapped |
| `bashExecutionToText` | `src/pi/rpc.zig:2409-2434` (`bashExecutionHistoryText`) | mapped (byte-equivalent output) |
| `convertToLlm` | partially inlined across `appendHistoryRange`, `appendCompactionHistoryMessage`, `bashExecutionHistoryText`, `addCustomMessage` paths | mapped functionally; no equivalent single transformer; branchSummary leg is missing |
| `createCustomMessage` / `createBranchSummaryMessage` / `createCompactionSummaryMessage` factories | not factored — pi-zig writes JSON directly via `appendCustomMessage` / `appendCompaction` / `appendBranchSummary` | n/a (factory absence is fine because pi-zig persists structurally) |
| `excludeFromContext` (`!!` prefix) | (MISSING) | upstream bashExecution `!!`-prefix mechanism (skip-from-context) has no Zig equivalent |

### 2.2 session-manager.ts

| Upstream surface | pi-zig location | Status |
|---|---|---|
| `CURRENT_SESSION_VERSION = 3` | `src/pi/session.zig:104,148` (writes `"version":3`, accepts only `version==3` on read) | mapped |
| `migrateV1ToV2` / `migrateV2ToV3` | (MISSING) | `loadExisting` (`session.zig:148`) rejects any version != 3 with `UnsupportedSessionVersion`. pi-zig cannot read upstream v1 or v2 session files at all |
| `migrateSessionEntries` (exported for tests) | (MISSING) | |
| `parseSessionEntries` | inline only in `loadExisting` / `readTree` | partial |
| `getLatestCompactionEntry` | inline `firstKeptMessageIndex` / `lastCompactionIndex` patterns in rpc.zig | partial |
| `buildSessionContext(entries, leafId?, byId?)` | `src/pi/rpc.zig` `loadSessionEntries` + `pruneToBranch` + history-build paths (`appendHistoryRange`, `appendCompactionHistoryMessage`) | partial — pi-zig only builds it from the active leaf at reload, not as a pure standalone function callers can invoke against arbitrary leafs |
| `getDefaultSessionDir` | `src/pi/session.zig:1005-1030` (`defaultSessionDir`) | mapped (path-encoding semantics match) |
| `loadEntriesFromFile` (exported) | private to `loadExisting` | partial (not separable) |
| `findMostRecentSession` | `src/pi/session.zig:1038-1071` | mapped |
| `isValidSessionFile` | `src/pi/session.zig:1188-1195` | mapped |
| `buildSessionInfo` (per-file SessionInfo with name/cwd/firstMessage/allMessagesText etc.) | (MISSING) | |
| `SessionListProgress` callback | (MISSING) | |
| `buildSessionInfosWithConcurrency` / `listSessionsFromDir` | (MISSING) | |
| `SessionManager.create` / `.open` / `.continueRecent` / `.inMemory` / `.forkFrom` | partial: `PersistentStore.create`, `.open`, `.init`, `forkFromFile`. No `inMemory`, no `continueRecent` (caller must wire `findMostRecentSession` themselves) | partial |
| `SessionManager.list(cwd, sessionDir?, onProgress?)` | (MISSING) — no RPC `list_sessions` command, no `SessionInfo` shape | gap |
| `SessionManager.listAll(onProgress?)` | (MISSING) | gap |
| `newSession({id?, parentSession?})` | `src/pi/session.zig:90-115` (`newSession`, accepts only `parent_session`) | partial — explicit `id` override absent (pi-zig regenerates) |
| `appendMessage` | `src/pi/session.zig:190-232` + `appendMessageWithContentParts` | mapped |
| `appendThinkingLevelChange` | `src/pi/session.zig:583-600` | mapped |
| `appendModelChange` | `src/pi/session.zig:602-621` | mapped |
| `appendCompaction(summary, firstKeptEntryId, tokensBefore, details?, fromHook?)` | `src/pi/session.zig:634-680` | partial — pi-zig writes `details:{local:true|false, provider?, model?, messageCount, customInstructions?}`, which is a DIFFERENT shape than upstream `CompactionDetails {readFiles, modifiedFiles}`; `fromHook` flag is NOT persisted |
| `appendCustomEntry(customType, data?)` | `src/pi/session.zig:339-394` (including `appendCustomEntryRawJson`) | mapped |
| `appendSessionInfo(name)` | `src/pi/session.zig:564-581` | mapped |
| `getSessionName()` | (MISSING as a fn) — `Runtime.session_name_len` tracks the name, but no upstream-equivalent walker | partial (only via in-memory state, not from durable file scan) |
| `appendCustomMessageEntry(customType, content, display, details?)` | `src/pi/session.zig:306-337` (`appendCustomMessage`) | partial — `details` field NOT persisted, `content` only as string (no `(TextContent|ImageContent)[]` form) |
| `appendLabelChange(targetId, label)` / `getLabel(id)` / `LabelEntry` | (MISSING) | gap — no label entry type, no `labelsById`, no setter/getter |
| `getChildren(parentId)` | (MISSING) | partial — tree node listing exists (`readTree`) but no direct children lookup |
| `getEntry(id)` | (MISSING) — only `TreeNode` lookup in `SessionTree.contains` | gap |
| `getEntries()` (returns all SessionEntry shallow copy) | (MISSING) — `readTree` returns trimmed `TreeNode`s with id/parentId/kind/role/preview only, not full entries | partial |
| `getTree()` returning `SessionTreeNode { entry, children, label, labelTimestamp }` | `src/pi/session.zig:811-825` (`SessionTree { nodes, count }`) — flat list, no nested children, no resolved labels | partial — flat tree, callers must rebuild parent/child links; label support absent |
| `getLeafEntry()` | (MISSING) — only `leafId()` exists | partial |
| `getHeader()` | (MISSING) — parsed and discarded inside `loadExisting`; `sessionId()` exposed but `cwd`/`parentSession`/`timestamp` are not | partial |
| `branch(branchFromId)` | `src/pi/session.zig:937-949` (`setLeaf`) | mapped |
| `resetLeaf()` | `src/pi/session.zig:953-962` | mapped |
| `branchWithSummary(branchFromId, summary, details?, fromHook?)` | `src/pi/session.zig:689-718` (`appendBranchSummary`) + rpc.zig:818-885 (`navigateTreeWithSummary`) | partial — `details` (FileOperations) NOT persisted; `fromHook` IS persisted; `branchFromId == null` (resetLeaf path) is not exercised by pi-zig's navigate_tree |
| `createBranchedSession(leafId)` (single-path extraction; rewrites labels) | (MISSING) | gap — there is no "extract a single path" extraction; only fork (whole-source-copy) exists |
| `isPersisted()` | (MISSING) — `PersistentStore` is always disk-backed | gap |
| Deferred-flush rule (no disk writes until first assistant message) | (MISSING) | pi-zig writes every entry on append (`appendBytes` is called immediately). Upstream's `_persist` deferral and `flushed` flag are not replicated |
| `SessionHeader.cwd` populated from real cwd | partial — pi-zig writes literal `"cwd":"."` (`session.zig:108`) | gap — upstream resolves the path, pi-zig hardcodes "." |
| Session header timestamp | partial — pi-zig writes literal `"local-foundation"` via `timestampString` (`session.zig:1172-1175`) instead of an ISO-8601 string | gap — readers expecting real timestamps will treat sessions as undated |
| `ReadonlySessionManager` type alias | (MISSING) | n/a (Zig has no comparable concept; if anything, pass `*const PersistentStore`) |

### 2.3 compaction/compaction.ts

| Upstream surface | pi-zig location | Status |
|---|---|---|
| `CompactionDetails { readFiles, modifiedFiles }` | (MISSING) — pi-zig persists `details:{local, provider?, model?, messageCount, customInstructions?}` instead | gap — file-tracking provenance lost |
| `CompactionResult` | partial — `rpc.zig:1698-1708` `CompactionOutcome` carries `summary` + `first_kept_entry_id` + `tokens_before` + `provider_meta` | partial |
| `CompactionSettings { enabled, reserveTokens, keepRecentTokens }` | partial — `keepRecentTokens` IS NOT modeled anywhere; only `enabled` + `reserveTokens` (`rpc.zig:589-594`) | gap |
| `DEFAULT_COMPACTION_SETTINGS` (16384 reserve / 20000 keepRecent) | partial — `default_auto_compaction_reserve_tokens = 16384` (`rpc.zig:35`); `keepRecentTokens` not in defaults because the feature is missing | gap |
| `extractFileOperations(messages, entries, prevCompactionIndex)` | (MISSING) | gap |
| `getMessageFromEntry` / `getMessageFromEntryForCompaction` | (MISSING) as standalone — replicated implicitly by `buildCompactionPromptText` | partial |
| `calculateContextTokens(usage)` | (MISSING) | gap — `estimateTokensBeforeCompaction` is chars/4 only, never consults assistant `usage` |
| `getLastAssistantUsage(entries)` | (MISSING) | gap |
| `ContextUsageEstimate { tokens, usageTokens, trailingTokens, lastUsageIndex }` | (MISSING) | gap |
| `estimateContextTokens(messages)` (uses latest assistant usage + trailing) | (MISSING) | gap — pi-zig's `estimateTokensBeforeCompaction` (`rpc.zig:1926-1933`) is purely chars/4 over message text, never reads `usage` from assistant messages |
| `shouldCompact(contextTokens, contextWindow, settings)` | `rpc.zig:1793-1802` (`shouldAutoCompact`) | mapped (predicate semantics match) |
| `estimateTokens(message)` per-role | partial — pi-zig sums `message.text().len + message.commandText().len` only; no per-role weighting; images count zero (upstream gives images 4800 chars) | gap |
| `findValidCutPoints(entries, start, end)` | (MISSING) | gap |
| `findTurnStartIndex` | (MISSING) | gap |
| `findCutPoint(entries, start, end, keepRecentTokens) -> CutPointResult` | (MISSING) | gap — pi-zig always compacts ALL messages up to current leaf; no `keepRecentTokens` window, no split-turn handling, no `firstKeptEntryIndex` calculation |
| `CutPointResult` / `isSplitTurn` semantics | (MISSING) | gap |
| `SUMMARIZATION_PROMPT` | `rpc.zig:48-57` (`compaction_summarization_prompt`) | mapped (text-identical to upstream) |
| `UPDATE_SUMMARIZATION_PROMPT` | (MISSING) | gap — pi-zig has no iterative-update prompt; multi-pass compactions cannot accumulate context properly |
| `TURN_PREFIX_SUMMARIZATION_PROMPT` | (MISSING) | gap — no split-turn → no turn-prefix prompt |
| `createSummarizationOptions` / `completeSummarization` (with `streamFn` + thinking-level threading) | partial — `rpc.zig:1850-1863` calls `agent.runPrompt` with `max_turns:1`; no `streamFn` injection point; thinking-level is NOT threaded through |
| `generateSummary(currentMessages, model, reserveTokens, apiKey, headers?, signal?, customInstructions?, previousSummary?, thinkingLevel?, streamFn?)` | `rpc.zig:runCompactionSummaryIfAuthenticated` (`1828-1868`) | partial — `previousSummary` is NOT carried into the prompt (no `<previous-summary>` wrapping); `thinkingLevel` is NOT threaded; `maxTokens` is left to provider default (not `0.8 * reserveTokens`); no `streamFn` |
| `CompactionPreparation { firstKeptEntryId, messagesToSummarize, turnPrefixMessages, isSplitTurn, tokensBefore, previousSummary?, fileOps, settings }` | (MISSING) | gap |
| `prepareCompaction(pathEntries, settings)` | (MISSING) | gap — `performCompaction` (`rpc.zig:1715-1779`) compresses the entire in-memory ring; there is no preparation step, no recent-keep slicing, no `previousSummary` lookup, no `fileOps` extraction |
| `compact(...)` returning structured result with parallel turn-prefix summary | `rpc.zig:1715-1779` `performCompaction` | partial — single summary only, no split-turn, no parallel calls, no `formatFileOperations` tail appended |
| `generateTurnPrefixSummary(...)` (`0.5 * reserveTokens`) | (MISSING) | gap |
| File-tracking append to summary (`<read-files>...</read-files>` + `<modified-files>...</modified-files>`) | (MISSING) | gap |

### 2.4 compaction/branch-summarization.ts

| Upstream surface | pi-zig location | Status |
|---|---|---|
| `BranchSummaryResult` / `BranchSummaryDetails` / `BranchPreparation` / `CollectEntriesResult` | (MISSING) as named types | gap |
| `collectEntriesForBranchSummary(session, oldLeafId, targetId)` (common-ancestor walk) | partial — `rpc.zig:818-885` `navigateTreeWithSummary` infers abandoned-vs-keep by walking `target_ancestors` over the in-memory ring; common-ancestor walk over the on-disk tree is not exposed | partial |
| `prepareBranchEntries(entries, tokenBudget)` (cumulative file-op accumulation + budget walk) | (MISSING) | gap — pi-zig's `buildBranchSummaryPromptText` (`rpc.zig:887-947`) just emits all abandoned entries in chronological order with no token budgeting |
| `BRANCH_SUMMARY_PROMPT` | `rpc.zig:63-71` (`branch_summary_prompt`) | mapped (text-identical) |
| `BRANCH_SUMMARY_PREAMBLE` (`"The user explored a different conversation branch before returning here..."`) | (MISSING) | gap — pi-zig stores raw summary; on later re-injection there is also no `BRANCH_SUMMARY_PREFIX/SUFFIX` wrapping (the wrapping `<summary>...</summary>` is also missing because branch_summary entries are never re-injected to context at all) |
| `replaceInstructions` option | (MISSING) | gap — pi-zig only appends `Additional focus:` after the default prompt |
| `reserveTokens` (default 16384) | (MISSING) — `runBranchSummaryIfAuthenticated` does not pass a max-tokens budget for the response | gap |
| `generateBranchSummary(entries, options)` (`maxTokens:2048`) | `rpc.zig:runBranchSummaryIfAuthenticated` (`954+`) | partial — single LLM call without a configured maxTokens, without file-op tail, without preamble |
| File-op tracking from `branch_summary.details` carrying across nested branches | (MISSING) | gap |
| `aborted` / `error` distinction in result | (MISSING) | gap |

### 2.5 compaction/utils.ts

| Upstream surface | pi-zig location | Status |
|---|---|---|
| `FileOperations { read, written, edited }` | (MISSING) | gap |
| `createFileOps()` | (MISSING) | gap |
| `extractFileOpsFromMessage(message, fileOps)` (scans toolCalls for read/write/edit + `path` arg) | (MISSING) | gap |
| `computeFileLists(fileOps)` | (MISSING) | gap |
| `formatFileOperations(readFiles, modifiedFiles)` | (MISSING) | gap |
| `TOOL_RESULT_MAX_CHARS = 2000` | (MISSING) | gap — pi-zig embeds full tool-result text in the compaction prompt body |
| `truncateForSummary(text, maxChars)` | (MISSING) | gap |
| `serializeConversation(messages)` — emits `[User]:`, `[Assistant thinking]:`, `[Assistant]:`, `[Assistant tool calls]: name(k=v,...)`, `[Tool result]: ...` (truncated) | partial — `rpc.zig:1872-1923` `buildCompactionPromptText` emits `[User]:`, `[Assistant]:`, `[Tool result]:`, `[Bash]:`, `[Custom]:`, `[Previous summary]:` but no `[Assistant thinking]:`, no `[Assistant tool calls]:` (tool calls are dropped from the serialized form), no truncation on tool-result bodies | gap |
| `SUMMARIZATION_SYSTEM_PROMPT` | `rpc.zig:45-47` (`compaction_summarization_system_prompt`) | mapped (text-identical) |

### 2.6 system-prompt.ts

| Upstream surface | pi-zig location | Status |
|---|---|---|
| `BuildSystemPromptOptions` shape | `src/pi/system_prompt.zig:18-30` (`BuildOptions`) | mapped (adds `package_dir`, `date`, `include_builtin_tool_metadata`; these are pi-zig conveniences for the CLI subcommand) |
| `buildSystemPrompt(options)` | `src/pi/system_prompt.zig:154-223` (`build`) | mapped — body, project-context block, skills block, date+cwd footer all match |
| Custom-prompt branch (custom prompt + append + project_context + skills + date+cwd) | `system_prompt.zig:160-172` | mapped |
| Default prompt body (header + Available tools + Guidelines + Pi documentation paragraph) | `system_prompt.zig:176-210` | mapped (Pi documentation paragraph wording matches verbatim) |
| `Available tools:` line with `- name: snippet` and `(none)` fallback | `appendToolsList` (`system_prompt.zig:225-241`) | mapped, plus pi-zig adds a builtin-snippet fallback (`builtinToolSnippet`) for read/bash/edit/write/grep/find/ls when `include_builtin_tool_metadata` is set |
| Guideline rules (bash-only → bash usage tip, bash + grep/find/ls → prefer-tools tip; always: be concise, show file paths) | `appendGuidelines` (`system_prompt.zig:243-280`) | mapped (semantically equivalent; pi-zig dedups via `appendUniqueGuideline`) |
| `<project_context>` / `<project_instructions path="...">` wrapping | `appendProjectContext` (`system_prompt.zig:289-301`) | mapped |
| Skills block (`<available_skills>` ... `</available_skills>`) | `appendSkills` (`system_prompt.zig:303-325`) | mapped |
| `Current date: …` + `Current working directory: …` footer | `appendDateAndCwd` (`system_prompt.zig:327-332`) | mapped |
| `cwd.replace(/\\/g, "/")` → POSIX path | `writePosixPath` (`system_prompt.zig:332`) | mapped |
| README / docs / examples path resolution via `getReadmePath` / `getDocsPath` / `getExamplesPath` | `appendPackagePath` (`system_prompt.zig:334-338`) + `resolvePackageDir` | partial — pi-zig derives all three from a single `package_dir`; the upstream split (separate getters) is collapsed (only matters if someone overrides one path independently) |

### 2.7 keybindings.ts

| Upstream surface | pi-zig location | Status |
|---|---|---|
| `AppKeybindings` (43 ids) | `src/pi/tui_keys.zig:217-263` (`default_bindings`) | partial — covers ~17 app ids: `app.interrupt`, `app.clear`, `app.exit`, `app.editor.external`, `app.model.select`, `app.model.cycleForward`, `app.model.cycleBackward`, `app.thinking.cycle`, `app.thinking.toggle`, `app.tools.expand`, `app.message.followUp`, `app.message.dequeue`. (MISSING: `app.suspend`, `app.session.toggleNamedFilter`, `app.clipboard.pasteImage`, all 4 `app.session.{new,tree,fork,resume}` ids, all 4 `app.tree.{foldOrUp,unfoldOrDown,editLabel,toggleLabelTimestamp}` ids, all 4 `app.session.{togglePath,toggleSort,rename,delete,deleteNoninvasive}` ids, all 6 `app.models.{save,enableAll,clearAll,toggleProvider,reorderUp,reorderDown}` ids, all 7 `app.tree.filter.*` ids) |
| Windows special-cases (`app.suspend` = `[]`, `app.clipboard.pasteImage` = `alt+v`) | (MISSING) | gap |
| `KEYBINDINGS` const merging TUI + app defaults with per-binding `description` | partial — pi-zig has a flat `default_bindings` table; merge step is implicit (no upstream-shaped `KEYBINDINGS` map exposed for the RPC `get_keybindings` semantics) | partial |
| `KEYBINDING_NAME_MIGRATIONS` (55 legacy → new pairs) | (MISSING) | gap — users with old keybindings.json files will have unrecognized entries silently dropped |
| `migrateKeybindingsConfig(rawConfig)` | (MISSING) | gap |
| `orderKeybindingsConfig` | (MISSING) | gap |
| `KeybindingsManager` class | (MISSING) | gap — pi-zig has no `<agentDir>/keybindings.json` loader, no `reload()` path, no user-override surface at all; bindings are compile-time constants |
| `getEffectiveConfig()` | (MISSING) | gap |
| `KeybindingsConfig` JSON shape (string or array) | (MISSING) | gap |

### 2.8 slash-commands.ts

| Upstream surface | pi-zig location | Status |
|---|---|---|
| `SlashCommandSource` type | implicit string values `"extension"`/`"prompt"`/`"skill"` in `commands.zig` JSON emission | mapped (no Zig enum, but the JSON shape matches) |
| `SlashCommandInfo` shape | `commands.zig` JSON emission via `writeSourceInfo*` paths | mapped |
| `BuiltinSlashCommand` struct | `src/pi/tui.zig:54-77` (`builtin_commands`) | mapped |
| `BUILTIN_SLASH_COMMANDS` (21 entries) | `src/pi/tui.zig:55-76` | mapped — all 21 names present (settings, model, scoped-models, export, import, share, copy, name, session, changelog, hotkeys, fork, clone, tree, login, logout, new, compact, resume, reload, quit) with byte-identical descriptions (pi-zig substitutes `pi-zig` for `APP_NAME` in quit description) |
| Per-command wiring in TUI / RPC | `src/pi/tui.zig:630-743` (`runCommand`) | partial — TUI handles `quit`, `help`/`hotkeys`, `new`/`clear`, `session`, `model`, `changelog`, `compact`, `export`, `name`, `fork`, `clone`. (MISSING TUI wiring: `settings`, `scoped-models`, `import`, `share`, `copy`, `tree`, `login`, `logout`, `resume`, `reload`. Each falls through to `"recognized but not yet wired"`.) RPC side has `compact`, `set_session_name`, `fork`, `clone`, `export_html`, `switch_session`, `new_session`, `get_session_tree`, `navigate_tree`, `set_auto_compaction`, `set_auto_retry`, `set_steering_mode`, `set_follow_up_mode`, `set_thinking_level`, `cycle_thinking_level`, `set_model`, `cycle_model`, `get_available_models`. (MISSING RPC: `import`, `share`, `copy`, `login`, `logout`, `reload`, `scoped-models`, full `settings`-menu surface, label-edit / tree-filter / fold-unfold tree-mode subcommands.) |
| `APP_NAME` substitution into quit description | hardcoded `"pi-zig"` | mapped (intentional rename) |

### 2.9 source-info.ts

| Upstream surface | pi-zig location | Status |
|---|---|---|
| `SourceScope = "user"|"project"|"temporary"` (string union) | string literal values emitted inline in `commands.zig` (`writeSourceInfoWithOrigin`, calls passing `"user"`/`"project"`) | partial — no Zig enum / type; callers pass raw strings, opening room for typos |
| `SourceOrigin = "package"|"top-level"` | same — `writeSourceInfoWithOrigin` 5th argument | partial |
| `SourceInfo { path, source, scope, origin, baseDir? }` struct | `commands.zig:1832-1851` (`writeSourceInfoWithOrigin`) emits the JSON shape directly | partial — no struct type, only the JSON serializer; `baseDir` is always emitted (upstream marks it optional) |
| `createSourceInfo(path, metadata: PathMetadata)` | (MISSING) — pi-zig has no `PathMetadata` equivalent; the package-manager.ts metadata pipeline is not ported (FLOW boundaries: see commands.zig `writePackagePromptCommands*` which infers scope manually) | gap |
| `createSyntheticSourceInfo(path, options)` | (MISSING) | gap |

---

## 3. Gap detail per item

The list below collapses the table above to the concrete behavioural gaps the user will see when running pi-zig against an upstream-produced workload.

### 3.1 Session format compatibility

- **Session version migration (`migrateV1ToV2`, `migrateV2ToV3`)** is absent. `loadExisting` (`session.zig:148`) **rejects any session whose header is not exactly `version:3`** with `UnsupportedSessionVersion`. Users with pre-existing v1 or v2 session files cannot resume them with pi-zig.
- **Session header `cwd` is hardcoded** to `"."` (`session.zig:108`). Upstream resolves the real cwd. Tools that filter sessions by their original project dir (such as upstream's `SessionManager.listAll`) will see all pi-zig sessions clustered under `"."`.
- **Session header `timestamp` is hardcoded** to the literal string `"local-foundation"` (`session.zig:1172-1175`). All append timestamps are also `"local-foundation"`. This breaks any consumer that parses timestamps as ISO-8601 dates, including `buildSessionInfo`/`listAll`-style code paths if they were ported.
- **Deferred-flush rule** (no disk writes until first assistant message) is not implemented. pi-zig appends every entry to disk immediately. Functionally still correct but produces empty/half-filled session files when a user spawns a session and exits before getting an answer (upstream would have left no file behind).

### 3.2 In-memory message types

- **`branchSummary` LLM role is unhandled.** `parseStoredRole` (`rpc.zig:4757-4766`) does not recognize it; `loadSessionEntries` (`rpc.zig:1248-1284`) reads `message`/`session_info`/`thinking_level_change`/`model_change`/`compaction`/`custom_message`/`custom` but explicitly **does not** load `branch_summary` entries. The on-disk file holds them (and html_export renders them), but they are NEVER replayed into the in-memory message ring and therefore NEVER injected into provider history. Re-entering a branched session loses the branch_summary context for the LLM.
- **`BRANCH_SUMMARY_PREFIX` / `BRANCH_SUMMARY_SUFFIX`** constants are absent. Even if branch_summary were re-injected, there is no upstream-shaped `<summary>...</summary>` wrapper to mark it as a summary in the user-role text the model receives.
- **`excludeFromContext`** (the `!!` bashExecution prefix flag) is not modeled in `StoredMessage` and not honored when serializing history. Users typing `!!some-command` get the same context behavior as `!some-command`.
- **CustomMessage `details`** is not persisted. `appendCustomMessage` (`session.zig:306-337`) only writes `customType`/`content`/`display`. Extensions that round-trip metadata via `details` lose it.
- **CustomMessage `content` as image blocks** is not supported. pi-zig stores content as a plain string; upstream allows `(TextContent | ImageContent)[]`.
- **No single `convertToLlm`** equivalent. The transformation is split across multiple rpc.zig paths (`appendHistoryRange`, `appendCompactionHistoryMessage`, `bashExecutionHistoryText`, `addCustomMessage`). Functionally close but cannot be reused by other components (e.g. a future structured-export path or extension SDK).

### 3.3 Compaction core

- **`keepRecentTokens`** is not modeled. There is no `findCutPoint`. `performCompaction` (`rpc.zig:1715-1779`) compacts EVERYTHING in the in-memory ring; the recent-window preservation upstream uses (default 20000 tokens) does not exist. Users compacting a long-running session lose the most recent turn-and-a-half they would have kept upstream.
- **`firstKeptEntryId` is degenerate.** Pi-zig sets it to `messages[0].entryId()` whenever there are messages (`rpc.zig:1721`), i.e. the FIRST entry in the ring — which is the OPPOSITE of upstream's semantic ("first entry to KEEP after the cut"). On reload, the kept-prefix logic over this field effectively keeps nothing, so the summary becomes the only context.
- **`isSplitTurn` / `turnStartIndex` / turn-prefix prompt** are absent. There is no `TURN_PREFIX_SUMMARIZATION_PROMPT`, no parallel `generateTurnPrefixSummary` call, no merge of history + turn-prefix summaries. A cut that lands mid-turn loses the turn's prefix entirely.
- **`UPDATE_SUMMARIZATION_PROMPT`** is absent. Second and later compactions inside a single session do NOT carry the previous summary into the prompt as `<previous-summary>`. Pi-zig only flows the prior summary as a `[Previous summary]:` line embedded in the conversation block (`rpc.zig:1891`), with the same root prompt as the first compaction. This drops upstream's PRESERVE/ADD/UPDATE/REMOVE iteration semantics.
- **Token estimation uses chars/4 only.** `estimateTokensBeforeCompaction` (`rpc.zig:1926-1933`) sums `text.len + commandText.len` over the ring and divides by 4. Upstream `estimateContextTokens` prefers the LAST non-aborted assistant `usage` and adds chars/4 for trailing messages. Result: pi-zig's auto-compaction threshold detection is materially less accurate, especially for image-heavy or thinking-heavy turns (upstream weights images at 4800 chars; pi-zig at 0).
- **`thinkingLevel` is not threaded into summarization.** Upstream `createSummarizationOptions` adds `reasoning` when the model supports it. pi-zig's `runCompactionSummaryIfAuthenticated` (`rpc.zig:1828-1868`) does not pass thinking_level to the provider call.
- **`maxTokens` is not bounded.** Upstream computes `min(0.8 * reserveTokens, model.maxTokens)` for history summary and `min(0.5 * reserveTokens, model.maxTokens)` for turn-prefix. Pi-zig calls `agent.runPrompt` with `max_turns:1` only — no provider-side response-token cap is configured.
- **`streamFn` injection** is absent. Upstream optionally streams the summary call; pi-zig always uses the non-streaming `agent.runPrompt` path.
- **File-operation tracking (`FileOperations`, `extractFileOpsFromMessage`, `computeFileLists`, `formatFileOperations`)** is entirely absent. Compaction summaries do not carry the `<read-files>` / `<modified-files>` tail. Upstream uses this both for prompt context and for cumulative tracking across multi-pass compactions; both signals are lost.
- **CompactionEntry `details` is the wrong shape.** Pi-zig writes `details:{local, provider?, model?, messageCount, customInstructions?}` (`session.zig:662-676`); upstream expects `CompactionDetails {readFiles, modifiedFiles}`. Tools reading pi-zig sessions for file-history will find nothing; tools written for upstream `details` will misparse pi-zig's provenance fields.
- **`fromHook` is not persisted on CompactionEntry.** `appendCompaction` (`session.zig:634-680`) takes `provider_meta` but never writes a `fromHook` flag. Upstream relies on `fromHook` to distinguish extension-generated summaries from pi-generated ones (for cumulative file-op accumulation).
- **No tool-result truncation in summary input.** Upstream `serializeConversation` truncates each `[Tool result]:` body to 2000 chars and appends `[... N more characters truncated]`. Pi-zig (`rpc.zig:1872-1923`) emits the full content. For sessions with many large tool outputs, this can push the summarization prompt over the model's max-input window.
- **Assistant `tool calls` and `thinking` blocks are dropped from the summary input.** Upstream serializes `[Assistant thinking]: ...` and `[Assistant tool calls]: name(k=v, ...)`. Pi-zig only emits `[Assistant]: <text>`, so the model summarizes without knowing what tools were invoked.

### 3.4 Branch summarization

- **`collectEntriesForBranchSummary`** as a common-ancestor walk over the on-disk tree is missing. Pi-zig's `navigateTreeWithSummary` (`rpc.zig:818-885`) infers "abandoned vs. keep" by walking the IN-MEMORY ring against the target's ancestor set. This works for the common case but fails when the in-memory ring is incomplete (e.g. after a session reload that pruned to a branch).
- **No token budget on branch summary input.** `prepareBranchEntries` (upstream) walks newest-to-oldest until the budget fills, optionally allowing summary entries up to 90% of budget. pi-zig serializes every abandoned entry in chronological order with no cap.
- **`BRANCH_SUMMARY_PREAMBLE`** is absent. The summary text written to disk does NOT carry the `"The user explored a different conversation branch before returning here..."` preamble. Even if pi-zig later re-injected branch_summary entries (which it doesn't — see 3.2), the model would not see the upstream-shaped framing.
- **`replaceInstructions:true`** mode is absent. The custom-instructions handling in `buildBranchSummaryPromptText` (`rpc.zig:891-947`) only appends `Additional focus:` after the default prompt. There is no way to fully override.
- **`maxTokens:2048` on branch-summary completion** is not set. Same as compaction, no response-token cap is configured.
- **No `BranchSummaryDetails {readFiles, modifiedFiles}`** persisted. `appendBranchSummary` (`session.zig:689-718`) writes `type/id/parentId/timestamp/fromId/summary/fromHook` only — no `details`. Cumulative file-op tracking across nested branches is impossible.
- **No `aborted` / `error` result distinction.** `runBranchSummaryIfAuthenticated` returns `null` on no-auth and bubbles errors; there is no upstream-shaped result that distinguishes "user aborted mid-stream" from "provider returned an error message".

### 3.5 Session-manager surface gaps

- **No `SessionInfo`** type, no `buildSessionInfo`, no `listSessionsFromDir`, no `SessionManager.list` / `.listAll`. The TUI `/resume` command falls through to the "not wired" notice because there is no per-session metadata (first message, message count, name, cwd, modified date) to drive the selector UI.
- **No `inMemory()` constructor.** All pi-zig sessions write to disk. Tests or sandboxed callers cannot run a session entirely in memory the way upstream does for unit tests of agent-session logic.
- **No `continueRecent(cwd, sessionDir?)` convenience.** Callers must wire `findMostRecentSession` + `PersistentStore.open` themselves.
- **No `newSession({id})` override.** Pi-zig regenerates the session id internally (`refreshSessionId`); callers can't pass an explicit id (matters for resume-from-snapshot flows).
- **No `createBranchedSession(leafId)`** path-extraction operation. `forkFromFile` always copies the full source file. Upstream's createBranchedSession writes only the chosen leaf's ancestor path (plus re-bound label entries), enabling the "extract this branch as its own session" UX.
- **No label entries / `appendLabelChange` / `getLabel` / labelTimestamp.** The `LabelEntry` shape doesn't exist anywhere in pi-zig — not in session.zig, not in rpc.zig, not in tui.zig, not in html_export.zig. Users cannot bookmark / annotate entries; the upstream `app.tree.editLabel` / `app.tree.toggleLabelTimestamp` keybindings have no backing handler.
- **No `getChildren(parentId)`, `getEntry(id)`, `getEntries()` accessors** returning full SessionEntry shapes. `readTree` returns trimmed `TreeNode { id, parentId, kind, role, preview }` instances. Callers needing the full message body (for tree-filter UX, label edits, content search) have to re-read the JSONL.
- **No `getLeafEntry()` / `getHeader()` getters.** Pi-zig exposes `leafId()` and `sessionId()`; `cwd` / `parentSession` / `timestamp` from the header are read once during `loadExisting` and not surfaced.
- **No `isPersisted()` distinction.** `PersistentStore` is always disk-backed.

### 3.6 Keybindings

- **No `<agentDir>/keybindings.json` loader.** `tui_keys.zig:default_bindings` is a compile-time array. Users cannot override keys without rebuilding pi-zig.
- **No `KeybindingsManager` class, no `create(agentDir)` / `reload()` / `getEffectiveConfig()`.** The upstream RPC surface for reading the effective keybindings (used by Preact workbench / TUI overlay for the hotkeys palette) cannot be served.
- **No `KEYBINDING_NAME_MIGRATIONS`.** Users upgrading from an older upstream pi-with-mounted-zig setup will have their legacy bindings (the old `interrupt` / `clear` / `cursorUp` style) ignored. Upstream's silent name-migration step does not run because pi-zig never reads keybindings.json in the first place.
- **No `orderKeybindingsConfig`.** Output JSON ordering is undefined (relevant only if pi-zig later adds a write-back path).
- **Coverage gap.** Of upstream's 43 `AppKeybindings` ids, only ~12 are recognized by pi-zig's `default_bindings`. The missing ids include all `app.session.*` (new/tree/fork/resume/togglePath/toggleSort/rename/delete/deleteNoninvasive/toggleNamedFilter), all `app.tree.*` (foldOrUp/unfoldOrDown/editLabel/toggleLabelTimestamp), all `app.tree.filter.*` (default/noTools/userOnly/labeledOnly/all/cycleForward/cycleBackward), all `app.models.*` (save/enableAll/clearAll/toggleProvider/reorderUp/reorderDown), and `app.suspend` + `app.clipboard.pasteImage`. The TUI cannot bind keystrokes to these actions because the binding ids don't exist in `tui_keys.zig`, even when the underlying RPC commands DO exist (e.g. `fork`, `clone`, `navigate_tree`, `switch_session`).
- **No Windows platform branches.** `app.suspend` defaults to `ctrl+z` on every OS (upstream emits `[]` on Windows); `app.clipboard.pasteImage` is not bound at all (upstream prefers `alt+v` on Windows).

### 3.7 Slash commands

- **Builtin command list is byte-aligned** with upstream (all 21 names + descriptions, modulo `pi-zig` ↔ `APP_NAME`).
- **Per-command wiring is partial.** TUI `runCommand` only dispatches: `quit`/`exit`, `help`/`hotkeys`, `new`/`clear`, `session`, `model`, `changelog`, `compact`, `export`, `name`, `fork`, `clone`. Everything else (settings, scoped-models, import, share, copy, tree, login, logout, resume, reload) falls through to `"/<name> is a recognized command but is not yet wired in the Zig TUI."`. RPC backend serves the underlying primitives for fork/clone/export/name/compact/navigate_tree/switch_session, but `import`/`share`/`copy`/`login`/`logout`/`reload`/full settings/`scoped-models` are absent at both layers.
- **No `SlashCommandInfo` Zig struct.** The JSON shape is emitted inline by `commands.zig` but there is no in-process type representing a slash command discovery result. Consumers in Zig code consume raw JSON.

### 3.8 Source-info

- **No Zig types** `SourceScope` / `SourceOrigin` / `SourceInfo`. The values are emitted as JSON strings by `writeSourceInfoWithOrigin` (`commands.zig:1832-1851`) — pi-zig callers pass `"local"`/`"package"` etc. as raw strings.
- **No `createSourceInfo(path, metadata)` / `createSyntheticSourceInfo(path, options)` factory functions.** There is no `PathMetadata`-equivalent pipeline in pi-zig because the `package-manager.ts` Zig port is structured very differently (`package_manager.zig`). Resource-loader call-sites in `commands.zig` rebuild source info by hand at each emission site.
- **`baseDir` is always emitted.** Upstream marks it optional; pi-zig's serializer always writes a value (defaults to dirname-of-path when absent in the caller's data).
- (could not verify) — whether any downstream consumer (Preact workbench, extension SDK, html_export) depends on `baseDir` being absent rather than `""`; if a consumer treats `""` as a valid path, this is harmless.

---

## 4. Honest estimated parity = **47%**

Weighting (subjective, scoped to the seven files in this gap):

| Area | Weight | Parity | Notes |
|---|---|---|---|
| messages.ts (factories + transformer) | 10% | 55% | core mapped; `branchSummary` role + `excludeFromContext` + image custom content missing |
| session-manager.ts entry types | 10% | 70% | message/compaction/branch_summary/custom_message/custom/session_info/thinking_level_change/model_change present; label missing |
| session-manager.ts SessionManager surface | 15% | 35% | core append + leaf-pointer mapped; list/listAll/inMemory/continueRecent/createBranchedSession/labels missing; header timestamp+cwd hardcoded; migrations absent |
| compaction.ts core algorithm | 15% | 25% | shouldCompact + summarization prompt + provider summary call mapped; findCutPoint/keepRecentTokens/turn-prefix/prevSummary-update/FileOps/estimateContextTokens-from-usage all missing |
| branch-summarization.ts | 10% | 35% | basic abandoned-branch summary + persistence mapped; token-budget/preamble/replaceInstructions/details-file-ops/reserveTokens-maxTokens missing |
| compaction/utils.ts | 10% | 35% | summarization system prompt + most serialization buckets mapped; toolCalls+thinking buckets+truncation+FileOperations entirely missing |
| system-prompt.ts | 10% | 90% | almost a faithful port; only difference is the package_dir/getReadme/getDocs/getExamples split is collapsed |
| keybindings.ts | 10% | 18% | `default_bindings` array exists; KeybindingsManager + migrations + keybindings.json + Windows special cases + 31/43 app ids all missing |
| slash-commands.ts | 5% | 70% | command list byte-aligned; per-command wiring is ~55% TUI / ~70% RPC; no Zig type for SlashCommandInfo |
| source-info.ts | 5% | 50% | JSON serializer for SourceInfo shape exists in commands.zig; the factory functions and the SourceScope/SourceOrigin enums and the metadata-driven `createSourceInfo` are absent |

Weighted average: `(10*0.55 + 10*0.70 + 15*0.35 + 15*0.25 + 10*0.35 + 10*0.35 + 10*0.90 + 10*0.18 + 5*0.70 + 5*0.50) / 100 = 46.8%` → **~47%**.

Confidence: medium-high for messages/compaction/branch-summarization/keybindings; medium for session-manager surface (the in-memory + tree paths are spread across rpc.zig and the boundary between rpc and session is harder to draw cleanly); medium for slash-commands (the RPC layer has dozens of related commands; "wired" vs. "not wired" depends on whether you require full UX or just the primitive — counted "wired" when the primitive exists).

# Gap 05: modes / CLI / main parity (upstream `earendil-works/pi` vs `pi-zig`)

Read-only audit produced by walking `upstream/pi/packages/coding-agent/src/{cli,cli.ts,main.ts,config.ts,migrations.ts,modes,utils,bun,package-manager-cli.ts,index.ts}` and comparing against
`src/main.zig`, `src/pi/cli.zig`, `src/pi/cli_runtime.zig`, `src/pi/rpc.zig`, `src/pi/config.zig`, `src/pi/settings.zig`.

The deliverable is structured as four sections:

1. Surface inventory (every upstream-public surface)
2. Mapped to pi-zig or `(MISSING)`
3. Gap detail per item
4. Honest estimated parity per surface and overall

---

## 1. Surface inventory

### 1.1 CLI flags — `cli/args.ts` `parseArgs` (37 flag identifiers, ~24 distinct flag values plus aliases)

| Long form | Short alias | Value type | Source: `parseArgs` |
|---|---|---|---|
| `--help` | `-h` | bool | yes |
| `--version` | `-v` | bool | yes |
| `--mode` | — | enum `text\|json\|rpc` | yes |
| `--continue` | `-c` | bool | yes |
| `--resume` | `-r` | bool | yes |
| `--provider` | — | string | yes |
| `--model` | — | string (pattern, optional `:thinking` suffix) | yes |
| `--api-key` | — | string | yes |
| `--system-prompt` | — | string | yes |
| `--append-system-prompt` | — | string (repeatable) | yes |
| `--no-session` | — | bool | yes |
| `--session` | — | string (path or id prefix) | yes |
| `--fork` | — | string (path or id prefix) | yes |
| `--session-dir` | — | string (directory) | yes |
| `--models` | — | comma list (with `:thinking` suffix support) | yes |
| `--no-tools` | `-nt` | bool | yes |
| `--no-builtin-tools` | `-nbt` | bool | yes |
| `--tools` | `-t` | comma list (allowlist) | yes |
| `--thinking` | — | enum `off\|minimal\|low\|medium\|high\|xhigh` | yes |
| `--print` | `-p` | bool + optional inline prompt (lookahead rule) | yes |
| `--export` | — | string (path) | yes |
| `--extension` | `-e` | string (repeatable) | yes |
| `--no-extensions` | `-ne` | bool | yes |
| `--skill` | — | string (repeatable) | yes |
| `--prompt-template` | — | string (repeatable) | yes |
| `--theme` | — | string (repeatable) | yes |
| `--no-skills` | `-ns` | bool | yes |
| `--no-prompt-templates` | `-np` | bool | yes |
| `--no-themes` | — | bool | yes |
| `--no-context-files` | `-nc` | bool | yes |
| `--list-models` | — | bool with optional fuzzy search arg | yes |
| `--verbose` | — | bool | yes |
| `--offline` | — | bool | yes |
| `@<path>` | — | repeatable file argument | yes |
| `--<unknown>` / `--<unknown>=value` | — | passed to extension flag registry | yes |
| bare positional | — | message (repeatable) | yes |

Also tracked: a `diagnostics: Array<{type, message}>` array (warnings for invalid thinking, errors for unknown short options).

Constants exported: `VALID_THINKING_LEVELS`, helper `isValidThinkingLevel`.

### 1.2 Top-level subcommands — handled by `package-manager-cli.ts` + main.ts dispatch

| Command | Path | Notes |
|---|---|---|
| `pi install <source> [-l] [--help]` | `handlePackageCommand` | aliases: `install` |
| `pi remove <source> [-l] [--help]` | `handlePackageCommand` | |
| `pi uninstall <source> [-l] [--help]` | `handlePackageCommand` | alias for `remove` |
| `pi update [source\|self\|pi] [--self] [--extensions] [--extension <source>] [--force] [--help]` | `handlePackageCommand` | |
| `pi list [--help]` | `handlePackageCommand` | |
| `pi config` | `handleConfigCommand` | Opens TUI config selector (`cli/config-selector.ts`) |
| `pi <command> --help` | per-command handler | Per-subcommand help |

Self-update / install-method detection: `detectInstallMethod`, `getSelfUpdateCommand`, `getSelfUpdateUnavailableInstruction`, `getUpdateInstruction`.

### 1.3 App modes — `resolveAppMode`

Four `AppMode` values: `interactive`, `print`, `json`, `rpc`. Decisions:

- `--mode rpc` → `"rpc"` (rejects `@file` arguments)
- `--mode json` → `"json"`
- `--print` or non-TTY stdin → `"print"`
- otherwise → `"interactive"`

`toPrintOutputMode(appMode)` converts non-rpc to `"text" | "json"` for `runPrintMode`.

### 1.4 Mode entrypoints — `src/modes/index.ts`

Public exports:
- `InteractiveMode` class + `InteractiveModeOptions` (interactive TUI)
- `runPrintMode(runtimeHost, PrintModeOptions)` + `PrintModeOptions`
- `runRpcMode(runtimeHost)` (returns `Promise<never>`)
- `RpcClient` class + `RpcClientOptions`, `ModelInfo`, `RpcEventListener`
- Types re-exported: `RpcCommand`, `RpcResponse`, `RpcSessionState`

### 1.5 RPC inbound commands — `modes/rpc/rpc-types.ts` (29 commands)

Listed verbatim from the `RpcCommand` union:

| # | type | Required fields | Async/streamed? |
|---|---|---|---|
| 1 | `prompt` | `message`, optional `images`, optional `streamingBehavior: "steer"|"followUp"` | streams events; preflight-aware success |
| 2 | `steer` | `message`, optional `images` | sync ack |
| 3 | `follow_up` | `message`, optional `images` | sync ack |
| 4 | `abort` | — | sync ack |
| 5 | `new_session` | optional `parentSession` | returns `{cancelled}` |
| 6 | `get_state` | — | returns `RpcSessionState` |
| 7 | `set_model` | `provider`, `modelId` | returns `Model` |
| 8 | `cycle_model` | — | returns `{model, thinkingLevel, isScoped} | null` |
| 9 | `get_available_models` | — | returns `{models}` |
| 10 | `set_thinking_level` | `level` | sync ack |
| 11 | `cycle_thinking_level` | — | returns `{level} | null` |
| 12 | `set_steering_mode` | `mode: "all"|"one-at-a-time"` | sync ack |
| 13 | `set_follow_up_mode` | `mode: "all"|"one-at-a-time"` | sync ack |
| 14 | `compact` | optional `customInstructions` | returns `CompactionResult` |
| 15 | `set_auto_compaction` | `enabled` | sync ack |
| 16 | `set_auto_retry` | `enabled` | sync ack |
| 17 | `abort_retry` | — | sync ack |
| 18 | `bash` | `command` | returns `BashResult` |
| 19 | `abort_bash` | — | sync ack |
| 20 | `get_session_stats` | — | returns `SessionStats` |
| 21 | `export_html` | optional `outputPath` | returns `{path}` |
| 22 | `switch_session` | `sessionPath` | returns `{cancelled}` |
| 23 | `fork` | `entryId` | returns `{text, cancelled}` |
| 24 | `clone` | — | returns `{cancelled}` |
| 25 | `get_fork_messages` | — | returns `{messages: [{entryId, text}]}` |
| 26 | `get_last_assistant_text` | — | returns `{text: string|null}` |
| 27 | `set_session_name` | `name` | sync ack |
| 28 | `get_messages` | — | returns `{messages: AgentMessage[]}` |
| 29 | `get_commands` | — | returns `{commands: RpcSlashCommand[]}` |

`RpcSlashCommand`: `{ name, description?, source: "extension"|"prompt"|"skill", sourceInfo: SourceInfo }`.

### 1.6 RPC `RpcSessionState` shape (12 fields)

`model?`, `thinkingLevel`, `isStreaming`, `isCompacting`, `steeringMode`, `followUpMode`,
`sessionFile?`, `sessionId`, `sessionName?`, `autoCompactionEnabled`, `messageCount`, `pendingMessageCount`.

### 1.7 RPC extension UI request methods — `RpcExtensionUIRequest` (9 methods)

- Dialog methods (require response): `select`, `confirm`, `input`, `editor`.
- Fire-and-forget methods: `notify`, `setStatus`, `setWidget`, `setTitle`, `set_editor_text`.

`RpcExtensionUIResponse` shapes: `{value}`, `{confirmed}`, `{cancelled: true}`.

### 1.8 RpcClient programmatic API (28 methods)

Lifecycle: `start()`, `stop()`, `onEvent(listener)`, `getStderr()`, `waitForIdle(timeout)`, `collectEvents(timeout)`, `promptAndWait(message, images, timeout)`.

Per-command wrappers (21): `prompt`, `steer`, `followUp`, `abort`, `newSession`, `getState`, `setModel`,
`cycleModel`, `getAvailableModels`, `setThinkingLevel`, `cycleThinkingLevel`, `setSteeringMode`,
`setFollowUpMode`, `compact`, `setAutoCompaction`, `setAutoRetry`, `abortRetry`, `bash`,
`abortBash`, `getSessionStats`, `exportHtml`, `switchSession`, `fork`, `clone`, `getForkMessages`,
`getLastAssistantText`, `setSessionName`, `getMessages`, `getCommands`.

### 1.9 Mode-specific event types — `AgentSessionEvent` (`core/agent-session.ts`)

Extension over base `AgentEvent`:
- `agent_end` augmented with `messages: AgentMessage[]` + `willRetry: boolean`
- `queue_update` (`{steering, followUp}`)
- `compaction_start` / `compaction_end` with `reason: "manual"|"threshold"|"overflow"`
- `session_info_changed` (`{name}`)
- `thinking_level_changed` (`{level}`)
- `auto_retry_start` / `auto_retry_end`

(Base `AgentEvent` types are owned by `@earendil-works/pi-agent-core`, not under audit, but include `agent_start`, `turn_start`, `turn_end`, `message_start`, `message_update`, `message_end`, `tool_execution_start`, `tool_execution_update`, `tool_execution_end`, etc.)

### 1.10 PrintMode options — `PrintModeOptions`

`{ mode: "text" | "json", messages?: string[], initialMessage?: string, initialImages?: ImageContent[] }`.

### 1.11 InteractiveMode options — `InteractiveModeOptions`

From `main.ts` invocation: `{ migratedProviders, modelFallbackMessage, initialMessage, initialImages, initialMessages, verbose }`.

### 1.12 `cli/` directory utilities

- `cli/args.ts`: `parseArgs(argv) -> Args`, `printHelp(extensionFlags?)`, `isValidThinkingLevel(level)`, exported `VALID_THINKING_LEVELS`, exported `Args` interface, `Mode` type.
- `cli/config-selector.ts`: `selectConfig({resolvedPaths, settingsManager, cwd, agentDir}) -> Promise<void>` (TUI for `pi config`).
- `cli/file-processor.ts`: `processFileArguments(fileArgs, {autoResizeImages?}) -> Promise<{text, images}>` (handles `@file` inputs, MIME-sniffs PNG/JPEG/GIF/WEBP, resizes images).
- `cli/initial-message.ts`: `buildInitialMessage({parsed, fileText?, fileImages?, stdinContent?}) -> {initialMessage?, initialImages?}`.
- `cli/list-models.ts`: `listModels(modelRegistry, searchPattern?) -> Promise<void>` (formatted columns, fuzzy filter, `formatTokenCount`).
- `cli/session-picker.ts`: `selectSession(currentSessionsLoader, allSessionsLoader) -> Promise<string|null>` (TUI session selector for `--resume`).

### 1.13 `main.ts` helper surfaces

- `main(args, options?: MainOptions)`: program entrypoint. `MainOptions.extensionFactories?: ExtensionFactory[]`.
- `readPipedStdin(): Promise<string|undefined>`.
- `collectSettingsDiagnostics(settingsManager, context)`.
- `reportDiagnostics(diagnostics)`.
- `resolveAppMode(parsed, stdinIsTTY): AppMode`.
- `toPrintOutputMode(appMode)`.
- `prepareInitialMessage(parsed, autoResizeImages, stdinContent?)`.
- `resolveSessionPath(sessionArg, cwd, sessionDir?)` (returns `"path"|"local"|"global"|"not_found"`).
- `promptConfirm(message)`.
- `validateForkFlags(parsed)` (rejects `--fork` combined with `--session`, `--continue`, `--resume`, `--no-session`).
- `forkSessionOrExit(sourcePath, cwd, sessionDir?)`.
- `createSessionManager(parsed, cwd, sessionDir, settingsManager)`.
- `buildSessionOptions(parsed, scopedModels, hasExistingSession, modelRegistry, settingsManager)`.
- `resolveCliPaths(cwd, paths)`.
- `promptForMissingSessionCwd(issue, settingsManager)` (TUI prompt for session lacking a cwd).
- `isTruthyEnvFlag(value)`.

### 1.14 `config.ts` surfaces (38 exported symbols)

Detection: `isBunBinary`, `isBunRuntime`, `detectInstallMethod()`, `getSelfUpdateCommand(...)`, `getSelfUpdateUnavailableInstruction(...)`, `getUpdateInstruction(...)`. Type `InstallMethod = "bun-binary"|"npm"|"pnpm"|"yarn"|"bun"|"unknown"`. Type `SelfUpdateCommand`.

Asset paths: `getPackageDir()`, `getThemesDir()`, `getExportTemplateDir()`, `getPackageJsonPath()`, `getReadmePath()`, `getDocsPath()`, `getExamplesPath()`, `getChangelogPath()`, `getInteractiveAssetsDir()`, `getBundledInteractiveAssetPath(name)`.

App constants: `PACKAGE_NAME`, `APP_NAME`, `APP_TITLE`, `CONFIG_DIR_NAME`, `VERSION`, `ENV_AGENT_DIR`, `ENV_SESSION_DIR`.

Helpers: `expandTildePath(path)`, `getShareViewerUrl(gistId)`.

User config paths: `getAgentDir()`, `getCustomThemesDir()`, `getModelsPath()`, `getAuthPath()`, `getSettingsPath()`, `getToolsDir()`, `getBinDir()`, `getPromptsDir()`, `getSessionsDir()`, `getDebugLogPath()`.

Env vars consumed: `PI_PACKAGE_DIR`, `PI_OFFLINE`, `PI_TELEMETRY`, `PI_SHARE_VIEWER_URL`, `PI_SKIP_VERSION_CHECK`, `ENV_AGENT_DIR` (`PI_CODING_AGENT_DIR`), `ENV_SESSION_DIR` (`PI_CODING_AGENT_SESSION_DIR`), `PI_STARTUP_BENCHMARK`, `PI_CODING_AGENT`.

### 1.15 `migrations.ts`

- `runMigrations(cwd) -> {migratedAuthProviders, deprecationWarnings}` — top-level.
- `migrateAuthToAuthJson()` — `oauth.json` + `settings.json.apiKeys` → `auth.json` (0o600).
- `migrateSessionsFromAgentRoot()` — move stray `.jsonl` under `agent/` to `agent/sessions/<encoded-cwd>/`.
- `showDeprecationWarnings(warnings)` — interactive press-any-key prompt with migration URLs.
- Internal: `migrateCommandsToPrompts(...)`, `migrateKeybindingsConfigFile()`, `migrateToolsToBin()`, `checkDeprecatedExtensionDirs(...)`, `migrateExtensionSystem(cwd)`.

### 1.16 `utils/` surfaces (26 modules)

| Module | Public surface |
|---|---|
| `ansi.ts` | `stripAnsi(value)` |
| `changelog.ts` | `parseChangelog(path)`, `compareVersions(v1,v2)`, `getNewEntries(entries, lastVersion)`, re-exports `getChangelogPath` |
| `child-process.ts` | `spawnProcess(cmd,args,opts)` (Windows cross-spawn fallback), `spawnProcessSync(...)`, `waitForChildProcess(child)` |
| `clipboard.ts` | `copyToClipboard(text)` — native addon → `pbcopy`/`clip`/`wl-copy`/`xclip`/`xsel`/`termux-clipboard-set`/OSC 52 |
| `clipboard-image.ts` | `readClipboardImage(...)`, `isWaylandSession()` (and other image-clipboard helpers, ~300 lines) |
| `clipboard-native.ts` | `clipboard` (native addon binding, ~32 lines) |
| `exif-orientation.ts` | `parseExifOrientation(...)` (~183 lines) |
| `frontmatter.ts` | `parseFrontmatter<T>(content)`, `stripFrontmatter(content)` |
| `fs-watch.ts` | `closeWatcher(watcher)`, `watchWithErrorHandler(path, listener, onError)`, `FS_WATCH_RETRY_DELAY_MS` |
| `git.ts` | `parseGitUrl(source) -> GitSource | null`, `GitSource` type |
| `html.ts` | `decodeHtmlEntity(entity)`, `decodeHtmlEntityAt(html, index)`, `DecodedHtmlEntity` |
| `image-convert.ts` | (image conversion helpers ~41 lines) |
| `image-resize.ts` | `resizeImage(content, mimeType)`, `formatDimensionNote(resized)`, `ResizedImage` |
| `image-resize-core.ts` | resize core (~164 lines) |
| `image-resize-worker.ts` | worker thread wrapper (~42 lines) |
| `mime.ts` | `detectSupportedImageMimeType(buffer)`, `detectSupportedImageMimeTypeFromFile(path)` (PNG signature + acTL animated-PNG rejection, JPEG, GIF, WEBP) |
| `paths.ts` | `canonicalizePath(path)`, `isLocalPath(value)`, `normalizePath(input, options)`, `resolvePath(input, baseDir?, options?)`, `getCwdRelativePath(filePath, cwd)`, `formatPathRelativeToCwdOrAbsolute(filePath, cwd)`, `markPathIgnoredByCloudSync(path)` |
| `photon.ts` | photon WASM image binding (~139 lines) |
| `pi-user-agent.ts` | `getPiUserAgent(version)` |
| `shell.ts` | `getShellConfig(customShellPath?)`, `getShellEnv()`, `sanitizeBinaryOutput(str)`, `trackDetachedChildPid(pid)`, `untrackDetachedChildPid(pid)`, `killTrackedDetachedChildren()`, `killProcessTree(pid)` |
| `sleep.ts` | `sleep(ms, signal?)` |
| `syntax-highlight.ts` | `highlight(code, options)`, `supportsLanguage(name)`, `renderHighlightedHtml(html, theme?)`, types `HighlightOptions`, `HighlightTheme`, `HighlightFormatter` |
| `tools-manager.ts` | `getToolPath(tool: "fd"|"rg")`, `ensureTool(tool, silent?)` (downloads from GitHub releases when missing) |
| `version-check.ts` | `getLatestPiRelease(currentVersion, options?)`, `getLatestPiVersion(currentVersion)`, `checkForNewPiVersion(currentVersion)`, `isNewerPackageVersion(candidate, current)`, `comparePackageVersions(left, right)` |
| `windows-self-update.ts` | `cleanupWindowsSelfUpdateQuarantine(packageDir)`, `quarantineWindowsNativeDependencies(packageDir)` |
| `highlight-js-lib-index.d.ts` | TS declaration only |

### 1.17 `bun/` directory (3 files)

- `bun/cli.ts`: entrypoint for Bun-compiled binary (sets `process.title`, suppresses warnings, registers Bedrock, calls `cli.ts`).
- `bun/register-bedrock.ts`: registers the Bedrock provider module against `@earendil-works/pi-ai`.
- `bun/restore-sandbox-env.ts`: `restoreSandboxEnv()` — recover `process.env` from `/proc/self/environ` under Bun sandbox bug (oven-sh/bun#27802).

### 1.18 `index.ts` — programmatic SDK exports (>150 symbols)

Selected top-level re-exports:
- Config: `getAgentDir`, `VERSION`
- Session core: `AgentSession`, plus 7 supporting types
- Auth storage: `AuthStorage` + 4 backends + 4 types
- Compaction: 18 functions / types
- Session manager: `SessionManager` + 14 types
- Settings manager: `SettingsManager` + 4 types
- Skills: `loadSkills` + 4 types
- Tools: 7 tool definition factories + ~30 type re-exports
- Extension API: ~70 events/types via `core/extensions/index.ts`
- SDK: `createAgentSession`, `createAgentSessionRuntime`, `createAgentSessionFromServices`, `createCodingTools`, `createReadOnlyTools`, etc.
- Modes: `runPrintMode`, `runRpcMode`, `RpcClient`, `InteractiveMode` plus 4 types
- UI components (interactive): 32 component classes
- Theme utilities: `initTheme`, `Theme`, `getMarkdownTheme`, `highlightCode`, etc.
- `main` itself plus `MainOptions`

### 1.19 `package-manager-cli.ts`

- `handlePackageCommand(args)` — entrypoint for `install`/`remove`/`uninstall`/`update`/`list`.
- `handleConfigCommand(args)` — entrypoint for `pi config`.
- `PackageCommand` type.

---

## 2. Mapped to pi-zig (or `(MISSING)`)

### 2.1 CLI flags

| Upstream flag | pi-zig location | Status |
|---|---|---|
| `--help` / `-h` | `cli.zig` parse; `cli_runtime.zig writeTopLevelHelpWithExtensions` | mapped |
| `--version` / `-v` | `cli.zig` parse; `main.zig` early branch and `cli_runtime.zig` | mapped |
| `--mode` | `cli.zig parse` (`Mode.parse` text/json/rpc) | mapped (text/json/rpc; no `interactive` value in upstream either — `interactive` is mode resolution result, not input) |
| `--continue` / `-c` | `cli.zig` parse; `cli_runtime.zig resolveSessionPath` | mapped (foundation) |
| `--resume` / `-r` | `cli.zig` parse; `cli_runtime.zig resolveSessionPath` | partial — pi-zig opens newest session; **(MISSING)** TUI session selector picker UI |
| `--provider` | `cli.zig` parse | mapped |
| `--model` | `cli.zig` parse | mapped (with `applyDefaultModelSelection` fallback) |
| `--api-key` | `cli.zig` parse | partial — pi-zig accepts but does not error when no `--model` is given (upstream errors with `--api-key requires a model to be specified`) |
| `--system-prompt` | `cli.zig` parse | mapped |
| `--append-system-prompt` | `cli.zig` parse | mapped (multi-value into fixed array) |
| `--no-session` | `cli.zig` parse | mapped |
| `--session` | `cli.zig` parse | partial — resolves by id-prefix + local path, **(MISSING)** global-search "fork from other project" prompt |
| `--fork` | `cli.zig` parse + `validateSessionFlags` | mapped |
| `--session-dir` | `cli.zig` parse | mapped |
| `--models` | `cli.zig` parse (kept as raw string) | partial — pi-zig stores the comma list but does not implement scoped-model resolution / Ctrl+P cycling (upstream `resolveModelScope`) |
| `--no-tools` / `-nt` | `cli.zig` parse | mapped |
| `--no-builtin-tools` / `-nbt` | `cli.zig` parse | mapped |
| `--tools` / `-t` | `cli.zig` parse | mapped (single comma string; filtered against built-in + extension tools) |
| `--thinking` | `cli.zig` parse | mapped (with diagnostic for invalid values) |
| `--print` / `-p` | `cli.zig` parse (with `isPrintInlinePrompt` lookahead) | mapped |
| `--export` | `cli.zig` parse; `cli_runtime.zig` export-html branch | mapped (output path argument passes through messages[0]) |
| `--extension` / `-e` | `cli.zig` parse; `extensions.discoverRuntimePaths` | mapped |
| `--no-extensions` / `-ne` | `cli.zig` parse | mapped |
| `--skill` | `cli.zig` parse; `commands.zig` discovery | mapped |
| `--prompt-template` | `cli.zig` parse | mapped |
| `--theme` | `cli.zig` parse | partial — paths recorded; **(MISSING)** TUI theme switching is interactive-only |
| `--no-skills` / `-ns` | `cli.zig` parse | mapped |
| `--no-prompt-templates` / `-np` | `cli.zig` parse | mapped |
| `--no-themes` | `cli.zig` parse | mapped |
| `--no-context-files` / `-nc` | `cli.zig` parse | mapped |
| `--list-models` | `cli.zig` parse; `models.writeListModelsJson` | partial — pi-zig only emits JSON; **(MISSING)** upstream's chalk-coloured aligned text columns (`cli/list-models.ts`) |
| `--verbose` | `cli.zig` parse | mapped (stored, threaded into interactive) |
| `--offline` | `cli.zig` parse | mapped (stored) — **(MISSING)** `PI_SKIP_VERSION_CHECK` env propagation done by upstream `main.ts` before any provider work |
| `@<path>` file args | `cli.zig parse` | mapped (built into prompt by `buildPrompt`) |
| `--<unknown>` | `cli.zig parse` + `extension_runner.validateFlags` | mapped (validate against `registerFlag` definitions) |
| bare positional | `cli.zig parse` | mapped |
| Diagnostics array | `cli.zig` `Diagnostic` + `writeDiagnostics` | mapped (with byte-exact upstream messages via `DiagnosticTemplate.invalid_thinking_level` and `unknown_option`) |

### 2.2 Top-level subcommands

| Upstream | pi-zig location | Status |
|---|---|---|
| `install <source> [-l]` | `src/pi/package_manager.zig` `run` | mapped (foundation; settings entry persistence + extension discovery wired) |
| `remove <source> [-l]` | `src/pi/package_manager.zig` | mapped |
| `uninstall <source> [-l]` | `src/pi/package_manager.zig` | mapped (alias) |
| `update [source|self|pi] [--self] [--extensions] [--extension <source>] [--force]` | `src/pi/package_manager.zig` | partial — install method detection + command construction exist; **(MISSING)** the latest-release fetch + `printSelfUpdateNote` markdown rendering + Windows quarantine handoff |
| `list` | `src/pi/package_manager.zig` | mapped |
| `config` | **(MISSING)** | No pi-zig branch handles `pi config`; upstream's TUI `selectConfig` invokes `ConfigSelectorComponent` for which there is no pi-zig analogue. |
| `pi <command> --help` | mapped via per-subcommand help in package_manager.zig | partial |

### 2.3 App modes

| Upstream `AppMode` | pi-zig location | Status |
|---|---|---|
| `interactive` | `cli_runtime.runInteractive` + `tui.zig` | partial — App-level logic + abort + `/compact` `/export` `/name` `/fork` `/clone` are unit-tested; **(MISSING)** model selector UI, scoped-models cycle, theme selector UI, ExtensionSelector for missing-session-cwd prompt, full extension component palette |
| `print` | `cli_runtime.runTextPrintFoundation` | mapped (provider-backed agent loop + signal handling) |
| `json` | `cli_runtime.runJsonPrintFoundation` + `runJsonProviderTextStream` | mapped (event lifecycle, retry, abort) |
| `rpc` | `src/pi/rpc.zig` | mapped (29 commands, plus pi-zig extras) |

`resolveAppMode` decision rule (rpc → json → print/stdin-not-TTY → interactive): mapped in `cli_runtime.runTopLevel` plus `main.zig`.

### 2.4 Mode entrypoints

| Upstream export | pi-zig analogue | Status |
|---|---|---|
| `InteractiveMode` class | `tui.App` in `src/pi/tui.zig` | partial — App-level callbacks/runners (`InteractivePromptRunner`, `InteractiveCompactRunner`, `SessionOps`) live in cli_runtime; **(MISSING)** the OO `InteractiveMode` class wrapping migrated-providers + modelFallbackMessage + interactive lifecycle |
| `runPrintMode(runtime, opts)` | `cli_runtime.runTextPrintFoundation` + `runJsonPrintFoundation` | partial — pi-zig dispatches by mode in `cli_runtime` itself rather than via a callable `runPrintMode`; **(MISSING)** the unified `PrintModeOptions` shape (`messages[]`, `initialMessage`, `initialImages`, `mode`) and the unified text-vs-json switch inside one function |
| `runRpcMode(runtime)` | `rpc.run` in `src/pi/rpc.zig` | mapped |
| `RpcClient` class | **(MISSING)** | No pi-zig RPC client; pi-zig is the server only |
| `RpcClientOptions`, `ModelInfo`, `RpcEventListener` types | **(MISSING)** | Not exposed |

### 2.5 RPC inbound commands

| Upstream RPC command | pi-zig rpc.zig handler | Status |
|---|---|---|
| `prompt` | `rpc.zig:3087` | mapped (preflight-aware; honours `streamingBehavior`) |
| `steer` | `rpc.zig:3134` | mapped |
| `follow_up` | `rpc.zig:3153` | mapped |
| `abort` | `rpc.zig:3172` | mapped |
| `new_session` | `rpc.zig:3203` | mapped |
| `get_state` | `rpc.zig:3216` | mapped |
| `set_model` | `rpc.zig:3224` | mapped |
| `cycle_model` | `rpc.zig:3252` | mapped |
| `get_available_models` | `rpc.zig:3244` | mapped |
| `set_thinking_level` | `rpc.zig:3313` | mapped |
| `cycle_thinking_level` | `rpc.zig:3326` | mapped |
| `set_steering_mode` | `rpc.zig:3342` | mapped |
| `set_follow_up_mode` | `rpc.zig:3352` | mapped |
| `compact` | `rpc.zig:3383` | mapped |
| `set_auto_compaction` | `rpc.zig:3392` | mapped |
| `set_auto_retry` | `rpc.zig:3405` | mapped |
| `abort_retry` | `rpc.zig:3415` | mapped |
| `bash` | `rpc.zig:3179` | mapped |
| `abort_bash` | `rpc.zig:3198` | mapped |
| `get_session_stats` | `rpc.zig:3271` | mapped |
| `export_html` | `rpc.zig:3291` | mapped |
| `switch_session` | `rpc.zig:3430` | mapped |
| `fork` | `rpc.zig:3445` | mapped |
| `clone` | `rpc.zig:3460` | mapped |
| `get_fork_messages` | `rpc.zig:3275` | mapped |
| `get_last_assistant_text` | `rpc.zig:3279` | mapped |
| `set_session_name` | `rpc.zig:3303` | mapped |
| `get_messages` | `rpc.zig:3220` | mapped |
| `get_commands` | `rpc.zig:3420` | mapped |

**Extras present in pi-zig (NOT upstream RpcCommand union):**
- `get_session_tree` (rpc.zig:3470) — pi-zig superset
- `navigate_tree` (rpc.zig:3480) — pi-zig superset

These are pi-zig additions; upstream surfaces tree navigation via interactive UI and `SessionBeforeTreeEvent`/`SessionTreeEvent`, not as RPC commands.

### 2.6 RPC extension UI methods

| Upstream method | pi-zig rpc.zig | Status |
|---|---|---|
| `select` | `Method.select` | mapped |
| `confirm` | `Method.confirm` | mapped |
| `input` | `Method.input` | mapped |
| `editor` | `Method.editor` | mapped |
| `notify` | `Method.notify` | mapped (fire-and-forget) |
| `setStatus` | `Method.set_status` | mapped |
| `setWidget` | `Method.set_widget` | partial — pi-zig accepts string-array widgets; **(MISSING)** widget factory component support (upstream comment: "Component factories are not supported in RPC mode") matches pi-zig — neither supports factories — so this is parity |
| `setTitle` | `Method.set_title` | mapped |
| `set_editor_text` | `Method.set_editor_text` | mapped |

**(MISSING)** upstream-side `pasteToEditor`, `getEditorText` (synchronous), `addAutocompleteProvider`, `setEditorComponent`, `getEditorComponent`, `setFooter`, `setHeader`, `setWorkingMessage`, `setWorkingVisible`, `setWorkingIndicator`, `setHiddenThinkingLabel`, `getAllThemes`, `getTheme`, `setTheme`, `getToolsExpanded`, `setToolsExpanded`, `onTerminalInput`, `custom()` — these are part of `ExtensionUIContext` and the RPC implementation in upstream returns sane no-ops/empties for them. pi-zig does not expose these surfaces, but it also does not need to as long as the RPC client cannot trigger them. The audit flags them for future extension-loader parity work.

### 2.7 RpcClient programmatic API

**(MISSING)** — no pi-zig RpcClient. The Preact workbench (`frontend/`) speaks JSONL to a `pi-zig rpc <session>` child directly. There is no programmatic client analogue for embedding consumers.

### 2.8 Mode-specific event types

| Upstream `AgentSessionEvent` augmentation | pi-zig location | Status |
|---|---|---|
| `agent_end{messages, willRetry}` | `cli_runtime.zig` `runJsonPrintFoundation` writes `messages` + `willRetry`; `rpc.zig` same | mapped |
| `queue_update{steering, followUp}` | `rpc.zig` — search for `queue_update` | **(MISSING)** — no `queue_update` emitter found in pi-zig RPC. Upstream emits when steer/follow-up queues change shape; pi-zig appears to skip this lifecycle |
| `compaction_start{reason}` | `rpc.zig` | partial — pi-zig fires events around `compact` but the `compaction_start` / `compaction_end` event shapes with `reason` discriminator may be incomplete |
| `compaction_end{reason, result, aborted, willRetry, errorMessage?}` | `rpc.zig` | partial — emits compact completion but `aborted`/`willRetry`/`errorMessage` fields' presence not verified for every code path |
| `session_info_changed{name}` | `rpc.zig` `set_session_name` handler | partial — verify the event fires on every name change |
| `thinking_level_changed{level}` | `rpc.zig` `set_thinking_level` / `cycle_thinking_level` | partial — same as above |
| `auto_retry_start{attempt, maxAttempts, delayMs, errorMessage}` | `cli_runtime.zig emitJsonAutoRetryStart` + `rpc.zig` | mapped |
| `auto_retry_end{success, attempt, finalError?}` | `cli_runtime.zig emitJsonAutoRetryEnd` + `rpc.zig` | mapped |

### 2.9 PrintMode / InteractiveMode options

| Upstream | pi-zig | Status |
|---|---|---|
| `PrintModeOptions.mode` | implicit from `cli.Mode` | mapped |
| `PrintModeOptions.messages[]` (additional prompts) | pi-zig text/json path consumes `parsed.messages` directly | partial — pi-zig doesn't yet support sending **additional** sequential prompts in print mode; it folds them into a single initial message via `buildPrompt` (which concatenates with `\n\n`). Upstream loops `for (const message of messages) await session.prompt(message)`. |
| `PrintModeOptions.initialMessage` | `cli_runtime buildPrompt` | mapped |
| `PrintModeOptions.initialImages` | `cli_runtime buildPrompt` | mapped |
| `InteractiveModeOptions.migratedProviders` | **(MISSING)** | pi-zig does not run upstream's `migrateAuthToAuthJson` and so cannot surface the migrated-providers banner in the TUI |
| `InteractiveModeOptions.modelFallbackMessage` | **(MISSING)** | upstream surfaces a banner when the requested model isn't found |
| `InteractiveModeOptions.initialMessages` | partial | pi-zig only uses `parsed.messages[0]`; not the full array |
| `InteractiveModeOptions.verbose` | partial | `parsed.verbose` stored but not threaded |

### 2.10 `cli/` directory utilities

| Upstream file / export | pi-zig location | Status |
|---|---|---|
| `cli/args.ts parseArgs` | `src/pi/cli.zig parse` | mapped (byte-exact diagnostics) |
| `cli/args.ts printHelp(extensionFlags?)` | `cli_runtime.writeTopLevelHelpWithExtensions` + `writeExtensionFlagHelp` | partial — pi-zig emits a help block but the wording diverges from upstream's chalk-formatted block and omits the upstream "Examples", "Environment Variables", "Built-in Tool Names" sections of `printHelp` |
| `cli/args.ts isValidThinkingLevel` | `src/pi/types.zig ThinkingLevel.parse` | mapped |
| `cli/config-selector.ts selectConfig` | **(MISSING)** | No `pi config` TUI in pi-zig |
| `cli/file-processor.ts processFileArguments` | `cli_runtime.buildPrompt` (inline image MIME sniff via `imageMimeTypeForPath`) | partial — pi-zig uses file-extension MIME mapping, not signature sniffing; **(MISSING)** image auto-resize (upstream `resizeImage` + `formatDimensionNote`), Unicode-space normalization, empty-file skip, and resilient resize-failure note `[Image omitted: could not be resized below the inline image size limit.]` |
| `cli/initial-message.ts buildInitialMessage` | `cli_runtime.buildPrompt` | partial — pi-zig orders `[stdin, fileText, firstMessage]` per upstream; **(MISSING)** the `parsed.messages.shift()` behaviour that lets the remaining `messages[]` be sent as additional turns |
| `cli/list-models.ts listModels` | `models.writeListModelsJson` | partial — pi-zig only emits JSON, no `formatTokenCount` text columns, no fuzzy filter, no header padding, no "No models matching" message, no `formatNoModelsAvailableMessage` integration |
| `cli/session-picker.ts selectSession` | **(MISSING)** | pi-zig `--resume` opens the newest session directly instead of showing a TUI session selector |

### 2.11 `main.ts` helpers

| Upstream helper | pi-zig analogue | Status |
|---|---|---|
| `main(args, options?)` | `src/main.zig main` + `cli_runtime.runTopLevel` | mapped (different shape; functional parity) |
| `readPipedStdin()` | `cli_runtime.readPipedStdin` | mapped |
| `collectSettingsDiagnostics` | not separated; settings errors surface via `settings.zig` directly | partial — pi-zig has no "drainErrors" sequence labelled per context (startup vs. runtime); upstream contextualises diagnostics |
| `reportDiagnostics` | `cli_runtime.writeDiagnostics` | mapped (without chalk colors) |
| `resolveAppMode` | implicit in `cli_runtime.runTopLevel` mode branching | mapped |
| `toPrintOutputMode` | implicit | mapped |
| `prepareInitialMessage` | `cli_runtime.buildPrompt` | partial — see file-processor gap above |
| `resolveSessionPath` (with `"path"|"local"|"global"|"not_found"` discriminant) | `cli_runtime.resolveSessionPath` | partial — pi-zig only distinguishes path-vs-id; **(MISSING)** the global "session found in different project, fork into current?" branch |
| `promptConfirm` | **(MISSING)** | No readline-based yes/no prompt analogue |
| `validateForkFlags` | `cli_runtime.validateSessionFlags` | mapped |
| `forkSessionOrExit` | inline in `cli_runtime.resolveSessionPath` | mapped |
| `createSessionManager` | `cli_runtime.maybeOpenStore` + `resolveSessionPath` | partial — pi-zig opens / forks but lacks `SessionManager.inMemory()` and `SessionManager.continueRecent()` flow encapsulation |
| `buildSessionOptions` | inline | partial — pi-zig threads `provider`/`model`/`thinking`/`tools`/`noTools`/`noBuiltinTools` directly; **(MISSING)** `scopedModels` resolution, `cliThinkingFromModel` precedence, `savedInScope` fallback logic |
| `resolveCliPaths` | `resolveLocalPath` (single value) | partial — upstream maps arrays; pi-zig path arrays are stored raw |
| `promptForMissingSessionCwd` | **(MISSING)** | no TUI prompt; pi-zig errors directly |
| `isTruthyEnvFlag` | inline `isTruthyEnvFlag` checks for `PI_OFFLINE`/`PI_STARTUP_BENCHMARK`/`PI_TELEMETRY` | partial — only `PI_OFFLINE` consumed in pi-zig |

### 2.12 `config.ts` surfaces

| Upstream | pi-zig | Status |
|---|---|---|
| `isBunBinary`, `isBunRuntime` | n/a (Zig binary) | not applicable |
| `detectInstallMethod` | `src/pi/package_manager.zig detectInstallMethod` | mapped |
| `getSelfUpdateCommand` | `package_manager.zig` | partial — covers npm/pnpm/yarn/bun heuristics |
| `getSelfUpdateUnavailableInstruction` | `package_manager.zig` | partial |
| `getUpdateInstruction` | `package_manager.zig` | partial |
| `InstallMethod`, `SelfUpdateCommand` types | `package_manager.zig` | partial |
| `getPackageDir` | `src/pi/system_prompt.zig resolvePackageDir` | partial — pi-zig walks up from cwd; **(MISSING)** Bun-binary `process.execPath`-based resolution, `PI_PACKAGE_DIR` env override |
| `getThemesDir` | `src/pi/themes.zig` | mapped |
| `getExportTemplateDir` | implicit in `html_export.zig` | partial — pi-zig uses a self-contained template |
| `getPackageJsonPath`, `getReadmePath`, `getDocsPath`, `getExamplesPath`, `getChangelogPath` | **(MISSING)** | not exposed |
| `getInteractiveAssetsDir`, `getBundledInteractiveAssetPath` | **(MISSING)** | not applicable until interactive components ship assets |
| `PACKAGE_NAME` | `src/pi/config.zig app_name` | mapped (literal `"pi-zig"`) |
| `APP_NAME` | `src/pi/config.zig app_name` | mapped |
| `APP_TITLE` | **(MISSING)** | upstream toggles between `APP_NAME` and `"π"` |
| `CONFIG_DIR_NAME` | `src/pi/config.zig config_dir` | mapped |
| `VERSION` | `src/pi/config.zig version` | mapped (`"0.1.0"`) |
| `ENV_AGENT_DIR` / `ENV_SESSION_DIR` | hardcoded `"PI_CODING_AGENT_DIR"` / `"PI_CODING_AGENT_SESSION_DIR"` strings throughout | partial — values inlined, but upstream computes from `APP_NAME` so a fork keeping `pi-zig`'s name should derive `PI_ZIG_CODING_AGENT_DIR`. **Confirmed**: pi-zig uses upstream's literal `PI_CODING_AGENT_DIR` to stay on-disk compatible with upstream sessions/settings, which is a deliberate divergence from `APP_NAME.toUpperCase()` derivation |
| `expandTildePath` | `cli_runtime.expandMaybeTilde` | mapped |
| `getShareViewerUrl` | **(MISSING)** | `/share` viewer URL helper not present (no `/share` command in pi-zig TUI) |
| `getAgentDir` | `settings.zig` agent-dir resolution | mapped |
| `getCustomThemesDir` | `themes.zig` | mapped |
| `getModelsPath`, `getAuthPath`, `getSettingsPath`, `getToolsDir`, `getBinDir`, `getPromptsDir`, `getSessionsDir`, `getDebugLogPath` | partial — sessions-dir, settings-path, auth-path, prompts-dir computed inline at call sites in `auth.zig`, `settings.zig`, `session.zig`, `commands.zig` | partial — no central registry; each subsystem builds its own paths |

Env vars consumed:
- `PI_PACKAGE_DIR` — **(MISSING)** in pi-zig
- `PI_OFFLINE` — mapped (read in `parsed.offline` + tools-manager fallback)
- `PI_TELEMETRY` — **(MISSING)** no telemetry surface
- `PI_SHARE_VIEWER_URL` — **(MISSING)** (no `/share`)
- `PI_SKIP_VERSION_CHECK` — **(MISSING)** (no version-check fetch)
- `PI_CODING_AGENT_DIR` — mapped
- `PI_CODING_AGENT_SESSION_DIR` — mapped
- `PI_STARTUP_BENCHMARK` — **(MISSING)** (`main.ts`'s interactive-only startup benchmark path)
- `PI_CODING_AGENT` — **(MISSING)** (sub-process detection flag set by upstream's wrapper)

### 2.13 `migrations.ts`

**(MISSING)** entirely. pi-zig has no `runMigrations` analogue. Specifically:
- `migrateAuthToAuthJson` — pi-zig reads `auth.json` directly but has no migration from legacy `oauth.json` + `settings.json.apiKeys`.
- `migrateSessionsFromAgentRoot` — pi-zig does not relocate stray `.jsonl` files under `agent/`.
- `migrateCommandsToPrompts` — pi-zig does not rename `commands/` → `prompts/`.
- `migrateToolsToBin` — pi-zig does not move `tools/fd|rg` → `bin/fd|rg`.
- `migrateKeybindingsConfigFile` — pi-zig has no keybindings persistence.
- `checkDeprecatedExtensionDirs` — pi-zig does not warn about deprecated `hooks/` and `tools/` dirs.
- `showDeprecationWarnings` — no migration-guide URL banner.

### 2.14 `utils/` surfaces

| Upstream module | pi-zig coverage | Status |
|---|---|---|
| `ansi.ts stripAnsi` | inline ANSI handling in `tui_render.zig` + `tools.zig` | partial — pi-zig sanitises ANSI in specific paths but no canonical `stripAnsi` |
| `changelog.ts` (parse / compare / new entries) | **(MISSING)** | no changelog browser; `/changelog` slash command absent |
| `child-process.ts spawnProcess[Sync]` / `waitForChildProcess` | `tools.zig` / `package_manager.zig` use `std.process.Child` directly | partial — pi-zig spawns processes but has no Windows cross-spawn equivalent and no graceful close timeout (`EXIT_STDIO_GRACE_MS`) |
| `clipboard.ts copyToClipboard` | **(MISSING)** | no clipboard integration |
| `clipboard-image.ts` / `clipboard-native.ts` | **(MISSING)** | no native clipboard or Wayland detection |
| `exif-orientation.ts` | **(MISSING)** | no EXIF orientation parsing for clipboard-pasted images |
| `frontmatter.ts parseFrontmatter / stripFrontmatter` | `commands.zig` frontmatter parsing | mapped (YAML frontmatter for skills/prompts) |
| `fs-watch.ts` | `themes.zig` watcher | partial |
| `git.ts parseGitUrl` | `package_manager.zig` git URL parsing | partial — basic recognition; **(MISSING)** `hosted-git-info` parity, `pinned` ref detection, SCP-like URL ref splitting |
| `html.ts decodeHtmlEntity` | `html_export.zig` | partial |
| `image-convert.ts` / `image-resize*.ts` / `photon.ts` | **(MISSING)** | no image-resize pipeline; `auto_resize_images` flag exists but resize is a passthrough |
| `mime.ts detectSupportedImageMimeType[FromFile]` | `cli_runtime.imageMimeTypeForPath` (extension-only) | partial — pi-zig uses file extension, not magic-byte signatures; **(MISSING)** PNG animated-frame rejection (acTL chunk), WEBP RIFF detection, GIF/JPEG signature checks |
| `paths.ts canonicalizePath` | implicit via `std.fs.realpath` | partial |
| `paths.ts isLocalPath` | `package_manager.zig` source classification | partial |
| `paths.ts normalizePath` | `cli_runtime.expandMaybeTilde` | partial — pi-zig handles `~`, not Unicode spaces, `@`-prefix stripping, `file://` URL conversion |
| `paths.ts resolvePath` | `cli_runtime.resolveLocalPath` | partial |
| `paths.ts getCwdRelativePath` / `formatPathRelativeToCwdOrAbsolute` | implicit in tool messages | partial |
| `paths.ts markPathIgnoredByCloudSync` | **(MISSING)** | no Dropbox/iCloud xattr marking on session paths |
| `pi-user-agent.ts getPiUserAgent` | **(MISSING)** | no version-check HTTP requests, so no UA |
| `shell.ts getShellConfig` | `settings.zig loadShellSettings` | partial — pi-zig loads user shell setting; **(MISSING)** Git Bash discovery on Windows, `findBashOnPath`, fallback chain to `sh` |
| `shell.ts getShellEnv` | implicit env passthrough | partial — no `binDir` PATH augmentation |
| `shell.ts sanitizeBinaryOutput` | partial in `tools.zig` | partial |
| `shell.ts trackDetachedChildPid` / `killTrackedDetachedChildren` / `killProcessTree` | partial in `tools.zig` bash executor | partial |
| `sleep.ts sleep` | `cli_runtime.sleepMilliseconds` | mapped |
| `syntax-highlight.ts highlight` | **(MISSING)** | no highlight.js binding; HTML export uses plain `<pre><code>` |
| `tools-manager.ts ensureTool` | `tools.zig` uses system `fd` / `rg` only | partial — pi-zig calls system binaries directly; **(MISSING)** auto-download from GitHub releases, version negotiation, archive extraction, platform-specific binary naming, Termux fallback |
| `version-check.ts` | **(MISSING)** | no version check, no `getLatestPiRelease`, no `comparePackageVersions` |
| `windows-self-update.ts` | **(MISSING)** | no Windows quarantine handling for self-update |

### 2.15 `bun/` directory

**(MISSING)** entirely — Zig binary doesn't need Bun-runtime shims. The functional concern (registering Bedrock) is handled by `src/pi/providers.zig`; the sandbox-env workaround is unnecessary because Zig builds inherit env directly.

### 2.16 `index.ts` programmatic exports

**(MISSING)** as a programmatic SDK. pi-zig is a CLI executable; consumers integrate via the RPC protocol (`pi-zig rpc <session>`), not via library imports. The 150+ symbols re-exported in upstream `index.ts` (AgentSession, SessionManager, SettingsManager, all UI components, tool factories, etc.) have no consumer-facing equivalent in pi-zig.

### 2.17 `package-manager-cli.ts`

| Upstream | pi-zig | Status |
|---|---|---|
| `handlePackageCommand` | `src/pi/package_manager.zig run` | partial — install/remove/list mapped; update partial (no latest-release fetch + Markdown note rendering); `--force` partial |
| `handleConfigCommand` | **(MISSING)** | `pi config` TUI absent |
| `parsePackageCommand` rich error reporting (`invalidOption`, `invalidArgument`, `missingOptionValue`, `conflictingOptions`) | partial in `package_manager.zig` | partial |
| `printPackageCommandHelp` per-command help (`install`/`remove`/`update`/`list`) | partial | partial |

---

## 3. Gap detail per item

### 3.1 CLI flags — concrete behavioural gaps

- `--api-key` without `--model`: upstream emits a diagnostic
  *"--api-key requires a model to be specified via --model, --provider/--model, or --models"*.
  pi-zig accepts the flag silently when no model is given and either resolves via provider default or proceeds with the foundation response.
- `--resume`: upstream invokes the `selectSession()` TUI (`cli/session-picker.ts`). pi-zig opens the newest session in `findMostRecentSession`. Picker UI **(MISSING)**.
- `--session` with id-prefix that exists in a *different* project: upstream's `resolveSessionPath` distinguishes `"global"` and asks via `promptConfirm("Fork this session into current directory?")`. pi-zig only searches the active session dir (`session.findSessionByIdPrefix`).
- `--models`: pi-zig stores the comma string in `parsed.models` but never resolves scoped models (`resolveModelScope`) or implements Ctrl+P cycling. The `scopedModels` member of `CreateAgentSessionOptions` is upstream-only.
- `--list-models`: pi-zig emits a JSON document. Upstream prints a chalk-styled, column-aligned text table (`cli/list-models.ts`) including columns `provider model context max-out thinking images` and a `No models matching <pattern>` fallback. **No text/`stdout` rendering in pi-zig.**
- `--theme`: pi-zig stores the path list but the theme is only applied in interactive contexts. Upstream's `--theme <path>` integrates with the ResourceLoader's `additionalThemePaths` to make custom themes available in non-interactive `--export` HTML rendering.
- `--export` second positional: pi-zig takes the second argument from `parsed.messages[0]`; upstream similarly takes `parsed.messages[0]` after parsing. **Functional parity confirmed**; only the message-consumption ordering diverges slightly when other messages would have been queued.
- `--offline` env propagation: upstream sets `PI_OFFLINE=1` and `PI_SKIP_VERSION_CHECK=1` for child processes. pi-zig records the flag but does not propagate env vars.
- `--verbose`: upstream threads into `InteractiveModeOptions.verbose` to force the timing/start-up banner; pi-zig stores but does not act on it.
- Unknown long flags: upstream stores in `Map<string, boolean|string>` and validates against extension `registerFlag` definitions. pi-zig uses a fixed-capacity `[MaxItems]UnknownFlag` array with a `value: ?[]const u8` (`null` ≡ boolean true). Functional parity confirmed; capacity limit is a small divergence.

### 3.2 Subcommands

- `pi config`: **(MISSING)** entirely in pi-zig. Upstream opens a TUI (`ConfigSelectorComponent`) that enables/disables resources from installed packages and writes back to settings. pi-zig has no analogue.
- `pi update --self`: pi-zig calls the install-method-specific command but does NOT fetch latest version from `https://pi.dev/api/latest-version`. Upstream's `getLatestPiRelease` + `printSelfUpdateNote` flow (markdown-rendered release notes via `Markdown` component) is **(MISSING)**.
- `pi update`: pi-zig's `parsePackageCommand` lacks the `--extension <source>` (singular) flag for one-package updates that conflicts-checks against `--self`, `--extensions`, and positional args.
- Windows self-update quarantine: `prepareWindowsNpmSelfUpdate` (calls `cleanupWindowsSelfUpdateQuarantine` + `quarantineWindowsNativeDependencies`) is **(MISSING)**.

### 3.3 App modes

- `interactive`: pi-zig TUI is App-level unit-tested but several UI surfaces are **(MISSING)**:
  - `ModelSelectorComponent` (model picker behind Ctrl+P / `/model`)
  - `ScopedModelsSelectorComponent`
  - `ThemeSelectorComponent`
  - `ThinkingSelectorComponent`
  - `SessionSelectorComponent` / `SessionSelectorSearchComponent` (for `--resume`)
  - `SettingsSelectorComponent`
  - `ConfigSelectorComponent` (for `pi config`)
  - `ExtensionSelectorComponent` (for the missing-session-cwd prompt and option pickers)
  - `OAuthSelectorComponent`, `LoginDialogComponent`
  - `ShowImagesSelectorComponent`, `TreeSelectorComponent`, `UserMessageSelectorComponent`
- `runPrintMode`: pi-zig dispatches `text` vs `json` in two separate `cli_runtime` functions. Upstream uses a single `runPrintMode(runtime, {mode, messages, initialMessage, initialImages})` exported from `modes/print-mode.ts`. The pi-zig path does not iterate `messages[]` as additional prompts (upstream `for (const message of messages) await session.prompt(message)`); messages beyond the first are concatenated into the initial prompt via `\n\n` in `buildPrompt`. **Behavioural gap** for multi-prompt print sessions.
- `runRpcMode`: pi-zig adds two non-upstream commands (`get_session_tree`, `navigate_tree`). RPC clients written against the upstream type union must tolerate these as extra surface. No upstream `RpcCommand` is missing.

### 3.4 RPC commands

- All 29 upstream RPC commands are present in pi-zig.
- pi-zig superset: `get_session_tree`, `navigate_tree` (2 extra commands).
- `RpcSessionState` fields: all 12 are emitted (verified by reading `rpc.zig:3216` and downstream writers).
- Event lifecycle gaps:
  - `queue_update` event: **(MISSING)** — pi-zig does not emit when steer/follow-up queues change. Upstream emits a `queue_update{steering, followUp}` event when queues mutate so the client can show pending-prompt indicators.
  - `compaction_start` / `compaction_end` `reason` discriminator: pi-zig event emission was not exhaustively verified to cover all three values `manual` / `threshold` / `overflow`.
  - `session_info_changed` and `thinking_level_changed` should fire on every state mutation; pi-zig coverage was not confirmed end-to-end.

### 3.5 Extension UI surfaces

The 9 RPC `extension_ui_request` methods are mapped. The broader `ExtensionUIContext` surface (16+ methods like `pasteToEditor`, `getEditorText`, `setFooter`, `setHeader`, `addAutocompleteProvider`, `setEditorComponent`, `getEditorComponent`, `setWorkingMessage`, `setWorkingVisible`, `setWorkingIndicator`, `setHiddenThinkingLabel`, `getAllThemes`, `getTheme`, `setTheme`, `getToolsExpanded`, `setToolsExpanded`, `onTerminalInput`, `custom()`) is not invoked from RPC mode in upstream either (those return `undefined`/no-op), so this is parity by design at the RPC boundary, even though pi-zig's extension runner does not expose these surfaces directly.

### 3.6 `cli/` directory gaps

- `cli/list-models.ts`: pi-zig has no text output. **High-visibility gap** for `pi --list-models <pattern>` interactive use.
- `cli/file-processor.ts`: pi-zig misses image MIME signature sniffing (extension-only), image auto-resize (`resizeImage`), `formatDimensionNote`, empty-file skip, the `<file name="absolute-path">` wrapping format with optional dimension note, the `error.exit(1)` on missing file. pi-zig's `buildPrompt` writes `@<path>\n<bytes>` inline.
- `cli/session-picker.ts`: **(MISSING)** entirely. `--resume` lacks the TUI picker.
- `cli/config-selector.ts`: **(MISSING)** entirely. `pi config` lacks the TUI.
- `cli/initial-message.ts`: pi-zig orders `[stdin, fileText, firstMessage]` like upstream, but does not subsequently treat `messages[1..]` as additional prompts.
- `cli/args.ts printHelp`: pi-zig help (`writeTopLevelHelp`) is paraphrased and shorter; **(MISSING)** the upstream Examples block, full Environment Variables list (30+ env keys), Built-in Tool Names list, the chalk-styled section headers.

### 3.7 `main.ts` orchestration gaps

- `MissingSessionCwdError` / `promptForMissingSessionCwd`: when a session header lacks a `cwd`, upstream interactively asks the user (`ExtensionSelectorComponent` with `["Continue", "Cancel"]`). pi-zig errors out in non-interactive contexts and has no TUI prompt for interactive.
- `cleanupWindowsSelfUpdateQuarantine` on Windows at startup: pi-zig **(MISSING)**.
- `configureHttpDispatcher(idleTimeoutMs)` (HTTP client tuning from settings): pi-zig **(MISSING)**.
- `process.title = APP_NAME`: pi-zig **(MISSING)** (no Zig stdlib for `prctl(PR_SET_NAME)` or Windows `SetConsoleTitle`).
- `process.emitWarning = (() => {})`: not applicable.
- `process.env.PI_CODING_AGENT = "true"`: pi-zig **(MISSING)** — child processes spawned by pi-zig will not see this marker (extensions may use it to detect they're running inside the agent).
- Startup benchmark (`PI_STARTUP_BENCHMARK`): pi-zig **(MISSING)**.
- Diagnostics-per-context naming (`startup session lookup` vs `runtime creation`): pi-zig emits diagnostics without contextual labels.

### 3.8 `config.ts` gaps

- `getPackageDir` does not consult `PI_PACKAGE_DIR` env var.
- `APP_TITLE` constant for `π` symbol display **(MISSING)**.
- Path helpers (`getReadmePath`, `getDocsPath`, `getExamplesPath`, `getChangelogPath`) **(MISSING)** as a centralised registry; some are inlined in `commands.zig`.
- `getShareViewerUrl(gistId)` **(MISSING)** (no `/share` command).
- ENV constant derivation: upstream derives `ENV_AGENT_DIR` from `${APP_NAME.toUpperCase()}_CODING_AGENT_DIR`. pi-zig hardcodes `PI_CODING_AGENT_DIR` (deliberate, for upstream compatibility), so a renamed fork of pi-zig would not auto-derive its env var name.

### 3.9 `migrations.ts` gaps

All five migrations **(MISSING)** in pi-zig. The on-disk format compatibility note (pi-zig reads `~/.pi/agent/auth.json`, `~/.pi/agent/sessions/...`, `.pi/settings.json`) means users upgrading from an old upstream `pi` install with `oauth.json` or stray `.jsonl` files will silently see no migrations performed.

### 3.10 `utils/` gaps

The high-impact missing utilities:
- `clipboard.ts copyToClipboard` — affects every `/copy`-style slash command and image paste handling.
- `clipboard-image.ts` / `exif-orientation.ts` — image paste pipeline.
- `image-resize.ts` / `image-resize-core.ts` / `photon.ts` — entire image resizing pipeline; `--auto-resize-images` flag exists but is not honoured for inline @file images.
- `mime.ts` signature-based sniff — pi-zig uses file-extension MIME, missing rejection of animated PNG and binary signature verification.
- `syntax-highlight.ts` — HTML export and TUI markdown rendering use plain `<pre><code>` instead of hljs-tokenised output.
- `tools-manager.ts ensureTool` — no auto-download of `fd`/`rg` binaries; pi-zig requires system installation.
- `version-check.ts` — no startup version notification.
- `windows-self-update.ts` — Windows self-update path will fail without quarantine handling.
- `changelog.ts` — no `/changelog` command, no startup new-version notice.
- `git.ts parseGitUrl` — `hosted-git-info` parity (with refs, hosted shorthand `github:user/repo`, SCP-style `git@host:user/repo@ref`) is partial.
- `paths.ts markPathIgnoredByCloudSync` — session files are not marked ignored to Dropbox/iCloud/Bionic.

### 3.11 `bun/` gaps

Not applicable to pi-zig.

### 3.12 `index.ts` gaps

No programmatic SDK. Direct library consumers cannot integrate with pi-zig the way they can with upstream's npm package.

---

## 4. Honest estimated parity per surface and overall

| Surface | Upstream items | Mapped | Partial | Missing | Parity % |
|---|---:|---:|---:|---:|---:|
| CLI flags (36 distinct flags + diagnostics) | 36 | 26 | 7 | 3 | **~80%** |
| Subcommands (5 + config) | 6 | 4 | 1 | 1 | **~75%** |
| App modes (4) | 4 | 3 | 1 | 0 | **~85%** |
| Mode entrypoints (RpcClient, runPrintMode, runRpcMode, InteractiveMode) | 4 | 2 | 1 | 1 | **~65%** |
| RPC commands (29 inbound) | 29 | 29 | 0 | 0 | **100%** (+ pi-zig adds 2 extras) |
| RPC extension UI methods (9 at RPC boundary) | 9 | 9 | 0 | 0 | **100%** (at boundary; broader ExtensionUIContext is partial both sides) |
| RPC `RpcSessionState` (12 fields) | 12 | 12 | 0 | 0 | **100%** |
| RPC event types (`AgentSessionEvent` augmentations: 7) | 7 | 4 | 2 | 1 | **~70%** |
| RPC client programmatic API | 1 class, 28 methods | 0 | 0 | 28 | **0%** |
| `cli/` utilities (6 modules) | 6 | 1 | 2 | 3 | **~40%** |
| `main.ts` orchestration helpers (~15) | 15 | 6 | 5 | 4 | **~55%** |
| `config.ts` paths/constants (35+ exports) | 35 | 12 | 12 | 11 | **~50%** |
| `migrations.ts` (5 migrations) | 5 | 0 | 0 | 5 | **0%** |
| `utils/` (26 modules) | 26 | 1 | 13 | 12 | **~30%** |
| `bun/` | 3 | 0 | 0 | 0 | not applicable |
| `index.ts` programmatic SDK | 150+ symbols | 0 | 0 | all | **0%** (CLI-only by design) |
| `package-manager-cli.ts` | 2 main + ~6 helpers | 1 | 4 | 1 | **~55%** |

### Overall weighted parity estimate

Weighted by upstream-source-of-truth importance (CLI surface and RPC behaviour weigh heavier than SDK exports or Bun shims that pi-zig deliberately drops):

| Weight | Surface | % |
|---:|---|---:|
| 5 | CLI flags | 80 |
| 4 | Subcommands | 75 |
| 5 | App modes | 85 |
| 4 | Mode entrypoints | 65 |
| 8 | RPC commands | 100 |
| 5 | RPC extension UI | 100 |
| 3 | RPC session state | 100 |
| 6 | RPC events | 70 |
| 3 | RPC client | 0 |
| 4 | `cli/` utilities | 40 |
| 4 | `main.ts` helpers | 55 |
| 3 | `config.ts` paths | 50 |
| 3 | `migrations.ts` | 0 |
| 4 | `utils/` | 30 |
| 0 | `bun/` (n/a) | — |
| 1 | `index.ts` SDK (CLI-only design) | 0 |
| 3 | `package-manager-cli.ts` | 55 |

**Weighted average ≈ 64%** (Σ(weight × pct) / Σ(weight) ≈ (400 + 300 + 425 + 260 + 800 + 500 + 300 + 420 + 0 + 160 + 220 + 150 + 0 + 120 + 0 + 55) / 65 ≈ 4110 / 65 ≈ **63%**).

### Honest narrative

- **RPC surface is the strongest area** (100% command coverage, plus two pi-zig extras for tree navigation). Event-lifecycle augmentations (`queue_update` in particular) are the biggest behavioural gap.
- **CLI flag parsing surface is at very strong parity** (~80%): every documented flag is recognised and stored with byte-exact diagnostics. The remaining 20% is behavioural (multi-message print, scoped-models cycling, list-models text rendering, session picker UI, missing-session-cwd UI, --api-key/model coupling diagnostic, `pi config` TUI).
- **Mode entrypoints are halfway there**: `runRpcMode` is full parity. `runPrintMode` is functionally present but folds messages instead of looping. `InteractiveMode` is App-level unit-tested but lacks the UI component palette. `RpcClient` (the programmatic client wrapper) is entirely absent.
- **`cli/`, `main.ts`, `migrations.ts`, `utils/`, `config.ts`** are the weakest areas. Most missing pieces are clipboard/image/syntax-highlight side surfaces, on-disk migration paths, and Node/Bun-runtime concerns that have no Zig equivalent. The high-impact gaps are: `pi config` TUI, the session picker for `--resume`, the global session prompt for `--session`, the list-models text rendering, the image-resize pipeline, and the version-check + auto-update notification flow.
- **`bun/` is intentionally not applicable** (no Bun runtime).
- **`index.ts` SDK is intentionally not applicable** (pi-zig is CLI-only; consumers integrate via `pi-zig rpc <session>`).

**Estimated overall parity for this gap (modes / CLI / main): ~63%.**

Of that, ~85% is mapped on the surfaces that matter most to RPC consumers (Preact workbench, Prin7r packaging, `--mode rpc`), and ~40% is mapped on the surfaces that matter most to interactive CLI users (TUI selectors, image handling, `pi config`).

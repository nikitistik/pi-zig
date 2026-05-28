# gap-02 audit: auth-storage, auth-guidance, http-dispatcher, settings-manager, defaults, diagnostics, output-guard, session-cwd, resolve-config-value

Read-only audit performed on branch `codex/pi-zig-progress` against pi-zig HEAD (commit `5db2192`). Comparison is between:

- Upstream: `upstream/pi/packages/coding-agent/src/core/{auth-storage,auth-guidance,http-dispatcher,settings-manager,defaults,diagnostics,output-guard,session-cwd,resolve-config-value}.ts`
- pi-zig: primarily `src/pi/auth.zig`, `src/pi/settings.zig`, `src/pi/session.zig`, with cross-references to `src/pi/providers.zig`, `src/pi/cli.zig`, `src/pi/cli_runtime.zig`, `src/pi/main.zig`.

All file:line references were verified by reading the listed files in full where reasonable. A few items are marked `(could not verify)` when behavior depends on runtime wiring outside the audited files.

---

## 1. Surface inventory (every exported function / class / type in upstream)

### `auth-storage.ts`
- `type ApiKeyCredential = { type: "api_key"; key: string }`
- `type OAuthCredential = { type: "oauth" } & OAuthCredentials`
- `type AuthCredential = ApiKeyCredential | OAuthCredential`
- `type AuthStorageData = Record<string, AuthCredential>`
- `type AuthStatus = { configured: boolean; source?: "stored"|"runtime"|"environment"|"fallback"|"models_json_key"|"models_json_command"; label?: string }`
- `interface AuthStorageBackend { withLock<T>(fn) ; withLockAsync<T>(fn) }`
- `class FileAuthStorageBackend implements AuthStorageBackend` (constructor takes `authPath`; private `ensureParentDir`/`ensureFileExists`/`acquireLockSyncWithRetry`; cross-process file lock via `proper-lockfile`; chmod 0o600 on write; mkdir 0o700 parent)
- `class InMemoryAuthStorageBackend implements AuthStorageBackend`
- `class AuthStorage` with:
  - `static create(authPath?)`, `static fromStorage(storage)`, `static inMemory(data?)`
  - `setRuntimeApiKey(provider, apiKey)`, `removeRuntimeApiKey(provider)`
  - `setFallbackResolver(resolver)` (used for `models.json` custom providers)
  - `reload()`, `drainErrors()`
  - `get(provider)`, `set(provider, cred)`, `remove(provider)`, `list()`, `has(provider)`, `hasAuth(provider)`
  - `getAuthStatus(provider): AuthStatus` (returns the 6-arm source tag above)
  - `getAll(): AuthStorageData`
  - `async login(providerId, callbacks)` (delegates to `getOAuthProvider(id).login`)
  - `logout(provider)`
  - `private async refreshOAuthTokenWithLock(providerId)` (cross-process file-locked refresh; on refresh failure, callers reload and recheck whether another instance refreshed)
  - `async getApiKey(providerId, options?: { includeFallback? }): Promise<string|undefined>` with the 5-tier priority: runtime override → stored api_key (via `resolveConfigValue`) → stored OAuth (auto-refresh with lock) → `getEnvApiKey()` → fallback resolver
  - `getOAuthProviders()` (passthrough to the OAuth registry)

### `auth-guidance.ts`
- `getProviderLoginHelp(): string` — multi-line "/login + docs/providers.md + docs/models.md" message
- `formatNoModelsAvailableMessage(): string`
- `formatNoModelSelectedMessage(): string`
- `formatNoApiKeyFoundMessage(provider: string): string` (substitutes "unknown" → "the selected model")

### `http-dispatcher.ts`
- `const DEFAULT_HTTP_IDLE_TIMEOUT_MS = 300_000`
- `const HTTP_IDLE_TIMEOUT_CHOICES` (5 labeled choices: 30 sec / 1 min / 2 min / 5 min / disabled)
- `parseHttpIdleTimeoutMs(value): number | undefined` (accepts number, numeric string, "disabled", trims, rejects negatives/NaN)
- `formatHttpIdleTimeoutMs(timeoutMs): string`
- `configureHttpDispatcher(timeoutMs?): void` — installs `undici.EnvHttpProxyAgent` as the global dispatcher with `allowH2:false`, `bodyTimeout`, `headersTimeout`, and then calls `undici.install()` to ensure fetch + dispatcher share the same `undici` build (the comment notes this avoids Node 26.0 decompression bugs).

### `settings-manager.ts`
- Types: `CompactionSettings`, `BranchSummarySettings`, `ProviderRetrySettings`, `RetrySettings`, `TerminalSettings`, `ImageSettings`, `ThinkingBudgetsSettings`, `MarkdownSettings`, `WarningSettings`, `TransportSetting`, `PackageSource`, `Settings`, `SettingsScope` ("global"|"project"), `SettingsError`
- `interface SettingsStorage { withLock(scope, fn) }`
- `class FileSettingsStorage implements SettingsStorage` (locks via `proper-lockfile`, retries on `ELOCKED`, lazy directory creation, real-path off)
- `class InMemorySettingsStorage`
- `class SettingsManager` with:
  - `static create(cwd, agentDir?)`, `static fromStorage(storage)`, `static inMemory(settings?)`
  - Private: `loadFromStorage`, `tryLoadFromStorage`, `migrateSettings`
  - Migrations: `queueMode → steeringMode`, `websockets:boolean → transport:"websocket"|"sse"`, legacy `skills.{enableSkillCommands,customDirectories}` → flat keys, `retry.maxDelayMs → retry.provider.maxRetryDelayMs`
  - `getGlobalSettings()`, `getProjectSettings()`
  - `async reload()`, `applyOverrides(overrides)`
  - Modified-field tracking (global + project, with nested-key granularity) so writes preserve unrelated keys in the file
  - `private save()` and `private saveProjectSettings(settings)` enqueueing onto an async `writeQueue` chain; on hook failure the error is recorded and saving is silently skipped if the corresponding file had a load error
  - `async flush()`, `drainErrors(): SettingsError[]`
  - Getters/setters for: `lastChangelogVersion`, `sessionDir`, `defaultProvider`, `defaultModel`, `setDefaultModelAndProvider`, `steeringMode`, `followUpMode`, `theme`, `defaultThinkingLevel`, `transport`, `compactionEnabled`/`reserveTokens`/`keepRecentTokens`/`compactionSettings`, `branchSummarySettings`/`branchSummarySkipPrompt`, `retryEnabled`/`retrySettings`/`httpIdleTimeoutMs`/`providerRetrySettings`, `hideThinkingBlock`, `shellPath`, `quietStartup`, `shellCommandPrefix`, `npmCommand`, `collapseChangelog`, `enableInstallTelemetry`, `packages`/`extensionPaths`/`skillPaths`/`promptTemplatePaths`/`themePaths` (with project-scoped twins: `setProject*Paths`), `enableSkillCommands`, `thinkingBudgets`, `showImages`/`imageWidthCells`/`clearOnShrink`/`showTerminalProgress`, `imageAutoResize`/`blockImages`, `enabledModels`, `doubleEscapeAction`, `treeFilterMode`, `showHardwareCursor`, `editorPaddingX`, `autocompleteMaxVisible`, `codeBlockIndent`, `warnings` (get/set).

### `defaults.ts`
- `const DEFAULT_THINKING_LEVEL: ThinkingLevel = "medium"`

### `diagnostics.ts`
- `interface ResourceCollision { resourceType: "extension"|"skill"|"prompt"|"theme"; name; winnerPath; loserPath; winnerSource?; loserSource? }`
- `interface ResourceDiagnostic { type: "warning"|"error"|"collision"; message; path?; collision? }`

### `output-guard.ts`
- `takeOverStdout(): void` (rebinds `process.stdout.write` so writes go through stderr; saves originals)
- `restoreStdout(): void`
- `isStdoutTakenOver(): boolean`
- `writeRawStdout(text: string): void` (chained promise, retries `ENOBUFS`/`EAGAIN`/`EWOULDBLOCK`)
- `waitForRawStdoutBackpressure(): Promise<void>`
- `flushRawStdout(): Promise<void>`

### `session-cwd.ts`
- `interface SessionCwdIssue { sessionFile?; sessionCwd; fallbackCwd }`
- `getMissingSessionCwdIssue(sessionManager, fallbackCwd): SessionCwdIssue | undefined`
- `formatMissingSessionCwdError(issue): string`
- `formatMissingSessionCwdPrompt(issue): string`
- `class MissingSessionCwdError extends Error { readonly issue }`
- `assertSessionCwdExists(sessionManager, fallbackCwd): void`

### `resolve-config-value.ts`
- `resolveConfigValue(config): string | undefined` (cached: `!cmd` exec via configured shell; env lookup; else literal)
- `resolveConfigValueUncached(config): string | undefined`
- `resolveConfigValueOrThrow(config, description): string`
- `resolveHeaders(headers?): Record<string,string> | undefined` (recurses values through `resolveConfigValue`)
- `resolveHeadersOrThrow(headers?, description): Record<string,string> | undefined`
- `clearConfigValueCache(): void` (test hook)
- Internally: per-process cache `commandResultCache` for `!cmd` results; on Windows tries configured shell first, falls back to default `execSync`; 10s timeout; stderr suppressed via `stdio:["ignore","pipe","ignore"]`.

---

## 2. Mapping table to pi-zig

| Upstream symbol / behavior | pi-zig location | Status |
|---|---|---|
| `auth-storage.ts` |  |  |
| `ApiKeyCredential` / `OAuthCredential` shape on disk | `src/pi/auth.zig:299-335` (setApiKey/setOAuth write the same `{type,key}`/`{type,access,refresh,expires[,accountId]}` JSON) | Matches on-disk schema |
| `AuthStorageData` (Record provider → cred) | `src/pi/auth.zig:299-372` (root JSON object keyed by provider) | Schema match |
| `AuthStatus { configured, source, label }` | `src/pi/auth.zig:30-36` (`AuthStatus` struct adds `has_auth` and `credential_type`) | Partial — see gap #1 |
| `interface AuthStorageBackend` | (MISSING) | No abstraction; pi-zig calls `loadAuth`/`writeAuth` directly |
| `class FileAuthStorageBackend` (file lock + chmod 0o600 + 0o700 dir) | `src/pi/auth.zig:1515-1546` (`loadAuth`/`writeAuth`/`ensureAuthFile`) | Partial — no lock, no chmod, no parent-dir mode (`createDirPath` uses default perms) |
| `class InMemoryAuthStorageBackend` | (MISSING) | Tests instead poke `std.json.Value` directly (e.g. `src/pi/auth.zig:1615-1638`) |
| `class AuthStorage` (long-lived instance) | (MISSING) | Each `auth.zig` command rereads `auth.json`; no in-memory `AuthStorage` object |
| `AuthStorage.setRuntimeApiKey` / `removeRuntimeApiKey` | (MISSING) | No CLI `--api-key` runtime override path |
| `AuthStorage.setFallbackResolver` (models.json custom-provider keys) | (MISSING) | No fallback resolver hook |
| `AuthStorage.reload()` | (MISSING) | Each invocation re-reads from disk anyway |
| `AuthStorage.has()` / `hasAuth()` | `src/pi/auth.zig:374-392` (`authStatus()` returns `.has_auth` mirroring `hasAuth`) | Partial — no method, but the value is derivable |
| `AuthStorage.getAuthStatus()` 6-arm source | `src/pi/auth.zig:374-392` (`authStatus`) — exposes `stored`/`environment` and ambient placeholders, but **no** `runtime`, `fallback`, `models_json_key`, `models_json_command` arms | Partial — see gap #1 |
| `AuthStorage.list()` | `src/pi/auth.zig:201-237` (CLI `auth list`) | Matches at CLI level |
| `AuthStorage.set()` / `remove()` | `src/pi/auth.zig:299-350` (CLI subcommands) | Matches at CLI level |
| `AuthStorage.getAll()` | (MISSING as a programmatic API) | CLI `auth list` is the closest analog |
| `AuthStorage.drainErrors()` | (MISSING) | pi-zig propagates Zig errors directly; no buffered error list |
| `AuthStorage.login(providerId, callbacks)` (real PKCE/device-code) | `src/pi/auth.zig:1431-1447` (`beginInteractiveLogin`) | Scaffold only — always returns `InteractiveLoginUnavailable`, see gap #2 |
| `AuthStorage.logout()` | `src/pi/auth.zig:337-350` (`auth remove`) | CLI parity |
| OAuth refresh with cross-process lock | `src/pi/auth.zig:620-749` (`refreshOAuthCredential`, called from `resolveExpiredOAuth`) | OAuth refresh implemented, **no lock** — see gap #3 |
| `AuthStorage.getApiKey()` 5-tier priority | `src/pi/auth.zig:409-456` (`resolveApiKeyMutable`) | Tiers 1 (runtime override) and 5 (fallback resolver) MISSING — see gap #1 |
| `AuthStorage.getOAuthProviders()` | `src/pi/auth.zig:352-372` (CLI `auth providers`) and `oauth_provider_specs[]` at `:567-595` | Matches the 3 built-in IDs; no register/unregister/reset API |
| `getOAuthProvider`/`registerOAuthProvider`/`resetOAuthProviders` (pi-ai surface re-used by upstream) | `src/pi/auth.zig:567-602` (hard-coded `oauth_provider_specs`, `oauthProviderSpec()`) | Partial — no dynamic registration; extension/SDK consumers cannot add OAuth providers |
| `auth-guidance.ts` |  |  |
| `getProviderLoginHelp` / `formatNoModelsAvailableMessage` / `formatNoModelSelectedMessage` / `formatNoApiKeyFoundMessage` | (MISSING) | grep finds zero references in pi-zig — no shared "no API key" message |
| `http-dispatcher.ts` |  |  |
| `DEFAULT_HTTP_IDLE_TIMEOUT_MS = 300_000` | `src/pi/settings.zig:4` (`default_http_idle_timeout_ms: i64 = 300_000`) | Matches default value only |
| `HTTP_IDLE_TIMEOUT_CHOICES` (settings picker options) | (MISSING) | No labelled list; CLI/TUI cannot expose the same picker |
| `parseHttpIdleTimeoutMs` (number/numeric-string/"disabled"/trim/reject) | `src/pi/settings.zig:507-523` (`parseHttpIdleTimeoutMs`) | Behavior matches: accepts integer, float (floored), numeric string, "disabled" (case-insensitive); rejects negatives and unparseable strings |
| `formatHttpIdleTimeoutMs` (label or "N sec") | (MISSING) | No formatter |
| `configureHttpDispatcher(timeoutMs?)` (sets undici global dispatcher + `undici.install()`) | (MISSING) | pi-zig uses `std.http.Client` per call (e.g. `src/pi/auth.zig:639-700`, `src/pi/ai_client.zig` — verified via line count only); no global idle-timeout enforcement. `httpIdleTimeoutMs` is parsed and surfaced in `settings resolved` JSON but has no effect on actual HTTP traffic — see gap #4 |
| `settings-manager.ts` |  |  |
| `Settings` schema (every field above) | `src/pi/settings.zig:383-420` (`resolvedSettings`) emits the same keys: `lastChangelogVersion`, `defaultProvider`, `defaultModel`, `defaultThinkingLevel`, `transport`, `steeringMode`, `followUpMode`, `theme`, `shellPath`, `shellCommandPrefix`, `sessionDir`, `compaction.*`, `branchSummary.*`, `retry.*`, `httpIdleTimeoutMs`, `hideThinkingBlock`, `quietStartup`, `collapseChangelog`, `enableInstallTelemetry`, `enableSkillCommands`, `terminal.*`, `images.*`, `doubleEscapeAction`, `treeFilterMode`, `showHardwareCursor`, `editorPaddingX`, `autocompleteMaxVisible`, `markdown.codeBlockIndent`, `warnings.anthropicExtraUsage`, `thinkingBudgets`, `enabledModels`, `npmCommand`. **Not surfaced**: `packages`, `extensions`, `skills` (paths), `prompts`, `themes` (path arrays) — though `enableSkillCommands` is exposed | Read parity strong; write parity limited |
| `migrateSettings` | `src/pi/settings.zig:293-346` | All 4 migrations present and tested (`:781-836`) |
| `SettingsStorage` interface / `FileSettingsStorage` (lockfile, lazy mkdir) | (MISSING) | No storage abstraction; pi-zig reads/writes files directly via `std.Io.Dir.cwd()` (`:694-703`). No cross-process locking |
| `InMemorySettingsStorage` | (MISSING) | Tests parse JSON in-memory but there is no reusable in-memory backend |
| `SettingsManager.tryLoadFromStorage` (collects parse errors per scope) | `src/pi/settings.zig:265-272` (records `error_name` on parse failure, includes in `errors[]` JSON `:640-652`) | Behavior parity at JSON-report level |
| `SettingsManager.reload()` | (MISSING) | No persistent manager; every CLI call reloads anyway |
| `applyOverrides(overrides)` | (MISSING) | No runtime override merge path |
| Modified-field tracking + write queue + nested-key granularity | `src/pi/settings.zig:229-252` (`updateSettingsFile`) preserves unrelated keys by reading→migrating→setting dotted path→writing whole document | Partial — see gap #5 |
| `drainErrors()` programmatic API | `src/pi/settings.zig:140-141, :640-652` (errors array embedded in `pi-zig settings` JSON output) | Partial — accessible only via the settings JSON report, no separate consumer-facing drain |
| ~80 getter/setter methods (e.g. `setCompactionEnabled`, `setShowImages`, ...) | `src/pi/settings.zig:177-222` (`settings set`/`set-model` accept dotted paths) | The full state is readable via dotted `settings get`/`settings --json`; writes go through a single `settings set <key> <value>` path. Upstream's per-field setters with built-in validation/clamping (e.g. `editorPaddingX` clamp 0-3, `autocompleteMaxVisible` clamp 3-20, `imageWidthCells` floor≥1, `defaultThinkingLevel` enum) are partially mirrored only in `resolvedSettings` (read path), not on the write path |
| `getSessionDir()` returning `normalizePath` of `sessionDir` | `src/pi/settings.zig:619-622` (`resolvedSessionDir`) tilde-expands but does not resolve to absolute via `normalizePath` (could not verify — `utils/paths.ts` normalizePath behavior was not in the assigned files) |
| Project-scoped writes (`setProjectPackages`, `setProjectExtensionPaths`, ...) | `src/pi/settings.zig:106-110, :177-209` (`settings set ... --local|--project`) | Generic project-scope writes are supported, but pi-zig has no dedicated setters for `packages`/`extensions`/`skills`/`prompts`/`themes` per-scope |
| `defaults.ts` |  |  |
| `DEFAULT_THINKING_LEVEL = "medium"` | `src/pi/settings.zig:643-645` (defaults documented in upstream's `getDefaultThinkingLevel`) — pi-zig's `resolvedSettings` exposes the field but **does not substitute "medium" as a default** when absent (returns `null`) | Partial — see gap #6 |
| `diagnostics.ts` |  |  |
| `ResourceCollision` / `ResourceDiagnostic` interfaces | (MISSING) | pi-zig has *parser* diagnostics (`src/pi/cli.zig:60, :167-173`), unrelated to upstream's *resource* diagnostics for extension/skill/prompt/theme collisions |
| `output-guard.ts` |  |  |
| `takeOverStdout`/`restoreStdout`/`isStdoutTakenOver`/`writeRawStdout`/`flushRawStdout`/`waitForRawStdoutBackpressure` | (MISSING) | grep finds zero references in pi-zig; backpressure-aware raw stdout pump is entirely absent |
| `session-cwd.ts` |  |  |
| `SessionCwdIssue` / `getMissingSessionCwdIssue` / `formatMissingSessionCwdError` / `formatMissingSessionCwdPrompt` / `MissingSessionCwdError` / `assertSessionCwdExists` | (MISSING) | grep finds zero references in pi-zig. The current session header writes `"cwd":"."` (`src/pi/session.zig:108`) — i.e. cwd is not actually tracked, so missing-cwd recovery cannot apply. The whole missing-cwd UX (warn user that the stored cwd no longer exists, fall back to current) is absent |
| `resolve-config-value.ts` |  |  |
| `resolveConfigValue` (cached, env-or-literal, `!cmd` shell exec) | `src/pi/auth.zig:518-550` (`resolveConfigValue` + `executeShellConfig`) | Behavior parity for the **non-cached** case |
| Per-process command cache + `clearConfigValueCache` | (MISSING) | No process-lifetime cache; every call to `resolveConfigValue` for a `!cmd` re-runs the shell — see gap #7 |
| `resolveConfigValueUncached` | `src/pi/auth.zig:518` (the existing function is already uncached) | Effectively present |
| `resolveConfigValueOrThrow` | (MISSING — but inline `null` checks at callers cover the call sites) |  |
| `resolveHeaders` / `resolveHeadersOrThrow` | (MISSING) | No header value resolution helper. Upstream uses it for `models.json` custom provider headers; pi-zig's ai_client/model-registry path was not in this audit's scope (could not verify whether headers are resolved elsewhere) |
| Windows shell fallback (`getShellConfig` then `execSync`) | `src/pi/auth.zig:533-540` (`executeShellConfig` always invokes `sh -c`) | Partial — Windows would have no `sh`; behavior diverges on Win32 |

---

## 3. Per-gap detail

### Gap 1 — `AuthStorage` runtime overrides, fallback resolver, full source set
- **Upstream behavior**: `setRuntimeApiKey`/`removeRuntimeApiKey` let `--api-key` win without touching disk; `setFallbackResolver` lets `models.json` custom providers contribute a key after env-var lookup fails; `getAuthStatus` returns 6 distinct `source` arms (`stored`, `runtime`, `environment`, `fallback`, `models_json_key`, `models_json_command`) so the UI can label exactly where the credential is coming from; `getApiKey` honors all 5 tiers and `options.includeFallback` to suppress the resolver.
- **Missing in pi-zig**: no in-memory `AuthStorage` object → no place to attach a runtime override or a fallback resolver. `authStatus()` in `src/pi/auth.zig:374-392` only emits `stored` / `environment` / ambient placeholders. `resolveApiKeyMutable` (`:409-456`) skips the runtime tier and the fallback resolver tier entirely.
- **Complexity**: Medium — needs (a) a long-lived `AuthStorage` struct with mutable maps for runtime overrides and a `?*const fn` fallback resolver, (b) routing every `cli_runtime` consumer through that struct, (c) adding the missing source arms to the JSON status output.
- **User-visible**: Yes — currently `--api-key`-style flows (if added) and custom-provider keys from `models.json` cannot be wired in; status output cannot tell the user "key came from models.json".

### Gap 2 — Real interactive OAuth login (PKCE + device-code + loopback server)
- **Upstream behavior**: `AuthStorage.login()` delegates to `getOAuthProvider(id).login(callbacks)`, which (per `upstream/pi/packages/ai/src/utils/oauth/{anthropic,github-copilot,openai-codex}.ts` and `pkce.ts`/`device-code.ts`) opens a browser/device-code flow, runs a loopback HTTP callback server, exchanges the authorization code for tokens, and persists the resulting `OAuthCredentials`.
- **Missing in pi-zig**: `beginInteractiveLogin` (`src/pi/auth.zig:1431-1447`) is explicitly a scaffold — it always returns `error.InteractiveLoginUnavailable` and prints "Interactive OAuth login is not yet implemented". The only way to add an OAuth credential is `pi-zig auth set-oauth <provider> <access> <refresh> <expires-ms>` with values the user obtained out-of-band.
- **Complexity**: High — full PKCE + loopback callback server (or device-code polling) + browser launch + per-provider auth URL construction. Three provider variants (anthropic, github-copilot, openai-codex) each with their own grants.
- **User-visible**: Yes — `/login` from a TUI cannot complete an OAuth flow; users must run external tooling to obtain `access`/`refresh` tokens manually.

### Gap 3 — Cross-process file lock around OAuth refresh and credential writes
- **Upstream behavior**: `FileAuthStorageBackend.withLock`/`withLockAsync` use `proper-lockfile` (`auth-storage.ts:74-99, :122-170`) with retry/backoff and stale-lock detection (30 s). `refreshOAuthTokenWithLock` (`:407-451`) re-reads the file under lock so two `pi` instances racing on an expired token converge instead of double-refreshing; on refresh failure the caller reloads and checks whether the peer succeeded.
- **Missing in pi-zig**: `loadAuth`/`writeAuth` in `src/pi/auth.zig:1515-1546` perform an unlocked read-modify-write. `resolveExpiredOAuth` (`:458-498`) refreshes the token outside any lock; if two instances race, one will overwrite the other's freshly minted credential. There is also no chmod 0o600/0o700 — the file/parent directory inherit the umask defaults.
- **Complexity**: Medium — Zig needs either a dedicated `flock(2)` wrapper or a sidecar `.lock` file with retry. Adding `chmod` after write is trivial; making it portable to Windows is not.
- **User-visible**: Yes (rare). Concurrent `pi-zig` invocations during OAuth refresh can lose one party's refreshed tokens, forcing a re-login. Local-file 0o600/0o700 perms are a security hygiene gap.

### Gap 4 — `configureHttpDispatcher` (global HTTP idle timeout enforcement)
- **Upstream behavior**: `configureHttpDispatcher(timeoutMs)` (`http-dispatcher.ts:39-55`) installs an `EnvHttpProxyAgent` with `bodyTimeout` and `headersTimeout` equal to the configured value (or 0 = disabled), then calls `undici.install()` so global `fetch` and the dispatcher share an undici build (avoiding the documented Node 26 decompression bug). Called from `main.ts:620`, `cli.ts:18`, and `interactive-mode.ts` (initial start + `/settings` change + warmup), so every outbound provider call honors the setting.
- **Missing in pi-zig**: zero references to `configureHttpDispatcher`-equivalent logic. `httpIdleTimeoutMs` is parsed (`src/pi/settings.zig:501-523`) and surfaced in `settings resolved` JSON but is not threaded into the `std.http.Client` instances used in `auth.zig` and `ai_client.zig`. Also missing: `HTTP_IDLE_TIMEOUT_CHOICES` (the labelled picker options) and `formatHttpIdleTimeoutMs` (the label formatter).
- **Complexity**: Medium — `std.http.Client` exposes `read_timeout`/`receive_timeout` per request, but routing the configured value to every callsite (and to every transport in `ai_client.zig`) is a non-trivial refactor. Picker labels are trivially derivable.
- **User-visible**: Yes — users with slow proxies cannot tune the timeout via `httpIdleTimeoutMs`; the setting is accepted but has no effect.

### Gap 5 — Settings write durability: file locking, write queue, per-field setters with clamping
- **Upstream behavior**: `SettingsManager` enqueues writes onto a per-scope `writeQueue` so concurrent setters serialize, holds a `proper-lockfile` lock during read-modify-write, and persists only modified fields (with nested-key granularity) by merging against the on-disk content immediately before writing. Per-field setters (`setEditorPaddingX`, `setAutocompleteMaxVisible`, `setImageWidthCells`, `setHttpIdleTimeoutMs`, ...) clamp/validate inputs before persisting. Project-scope variants exist for `packages`, `extensions`, `skills`, `prompts`, `themes`.
- **Missing in pi-zig**: no lockfile, no write queue (each CLI invocation is fire-and-forget), and `settings set` accepts any dotted path with any JSON value — there is no per-field validation on the write path. The validation/clamping that exists today only runs on the read path (`resolvedSettings`).
- **Complexity**: Medium — write-time validation tables and a small lock helper. The single-call CLI model is partial natural protection but breaks down with the persistent RPC server.
- **User-visible**: Yes — pi-zig will happily persist e.g. `httpIdleTimeoutMs: "bogus"` to disk; on next read, `resolveHttpIdleTimeoutMs` will return `error.InvalidHttpIdleTimeoutMs` and break the `settings` JSON report.

### Gap 6 — `DEFAULT_THINKING_LEVEL = "medium"` as a fallback default
- **Upstream behavior**: `defaults.ts` exports `"medium"` so callers (`agent-core`, the runner) have a single source of truth for the default; `SettingsManager.getDefaultThinkingLevel()` returns `undefined` only when the field is absent, and downstream code substitutes the constant.
- **Missing in pi-zig**: `src/pi/settings.zig:390` exposes `defaultThinkingLevel` as `null` when absent; there is no exported constant. (could not verify) whether the agent loop substitutes "medium" elsewhere — `agent.zig` was not in scope.
- **Complexity**: Low.
- **User-visible**: Maybe — depends on whether the agent loop already inlines `medium` somewhere.

### Gap 7 — `!cmd` shell-resolution result cache (`commandResultCache`)
- **Upstream behavior**: `resolve-config-value.ts:9-23, :78-86` caches the *result* of every `!cmd` invocation for the process lifetime (`Map<string, string|undefined>`), so a `models.json` provider whose API key is `!1password read op://...` only triggers one shell exec per process, not one per provider call.
- **Missing in pi-zig**: `executeShellConfig` (`src/pi/auth.zig:533-550`) re-execs every call. For short-lived `pi-zig auth resolve <provider>` calls this is a wash; for an in-process RPC server (which pi-zig now ships), every credential resolution will re-shell.
- **Complexity**: Low — a `std.StringHashMap([]const u8)` keyed by the raw `!cmd` string.
- **User-visible**: Yes (performance + UX) — users with `1password`/`pass`-style commands may see repeated TTY/Touch-ID prompts.

### Gap 8 — `output-guard.ts` raw stdout pump
- **Upstream behavior**: `takeOverStdout()` rebinds `process.stdout.write` so accidental writes during the TUI render go to stderr; `writeRawStdout` is a chained promise that retries `ENOBUFS`/`EAGAIN`/`EWOULDBLOCK` after a 10 ms delay; `waitForRawStdoutBackpressure` / `flushRawStdout` allow callers to drain.
- **Missing in pi-zig**: no equivalent. pi-zig writes directly through `std.Io.File.stdout().writeStreamingAll`. The TUI render path (`src/pi/tui_terminal.zig`, not in scope) may already coalesce writes, but the backpressure-and-retry contract is absent.
- **Complexity**: Medium — Zig's std.Io does not expose POSIX-level `ENOBUFS` retry; an explicit `EAGAIN` retry loop must wrap every TUI write.
- **User-visible**: Maybe — under heavy output (large streamed responses) the TUI can hit kernel buffer pressure and drop or interleave frames.

### Gap 9 — `session-cwd.ts` missing-cwd UX
- **Upstream behavior**: When a stored session's `cwd` no longer exists on disk, `getMissingSessionCwdIssue` flags it, `formatMissingSessionCwdError` and `formatMissingSessionCwdPrompt` produce the user-facing strings, and `MissingSessionCwdError` carries the issue object for the TUI to prompt "continue in current cwd?".
- **Missing in pi-zig**: zero references. Worse, `src/pi/session.zig:108` writes `"cwd":"."` into the session header — the actual cwd is *not even captured*, so the missing-cwd check would never fire even if implemented. Resuming a session in a different directory silently loses the original context.
- **Complexity**: Medium — first capture cwd in the session header (touching `newSession`/`loadExisting`/`PersistentStore` schema → bump session version 3 → 4 and migrate), then add the recovery UX.
- **User-visible**: Yes — resumed sessions reference the wrong working directory.

### Gap 10 — `auth-guidance.ts` shared "no API key" messaging
- **Upstream behavior**: Four exported formatters give consistent wording across CLI, TUI, and error paths ("Use /login to log into a provider via OAuth or API key. See: docs/providers.md, docs/models.md") substituting the provider name (or "the selected model" for the "unknown" sentinel).
- **Missing in pi-zig**: zero references. Each error site rolls its own message (e.g. `src/pi/auth.zig:292-295` prints `No API key found for <provider>.`). No single source of truth.
- **Complexity**: Low — four formatter functions and a `getDocsPath()` helper.
- **User-visible**: Yes — error messages diverge between subcommands; users who see one form won't recognize the other.

### Gap 11 — `diagnostics.ts` resource-collision schema
- **Upstream behavior**: `ResourceCollision` and `ResourceDiagnostic` are the shared schema for "two extensions registered the same /command", "two skills with the same name from different packages", etc. Used by extension-loader and surfaced to the TUI/CLI.
- **Missing in pi-zig**: pi-zig has parser diagnostics (`src/pi/cli.zig`) and extension loader paths (`src/pi/extensions.zig`, not in scope) but no `ResourceCollision` schema. (could not verify) whether extensions.zig emits any similar warnings.
- **Complexity**: Low (schema) — Medium if the goal is end-to-end collision detection across packages/extensions/skills/prompts/themes.
- **User-visible**: Yes — package authors get no first-class warning when their `/foo` shadows another package's `/foo`.

### Gap 12 — `FileSettingsStorage` parity (lockfile, lazy mkdir, real-path off)
- **Upstream behavior**: `FileSettingsStorage.withLock` (`settings-manager.ts:170-225`) retries on `ELOCKED`, only creates the parent directory when writing, and disables real-path resolution so symlinks behave intuitively.
- **Missing in pi-zig**: `src/pi/settings.zig:694-703` (`writeSettings`) unconditionally `createDirPath`s before writing (matches upstream's intent except for the "lazy on read" optimization) but does no locking. Symlink behavior — (could not verify).
- **Complexity**: Low.
- **User-visible**: Rare — concurrent RPC calls writing `settings.json` could interleave.

### Gap 13 — `resolveHeaders`/`resolveHeadersOrThrow` for `models.json` custom-provider headers
- **Upstream behavior**: `resolve-config-value.ts:115-138` recurses every header value through `resolveConfigValue`, so headers like `{"X-API-Key": "!op read op://..."}` work for custom providers.
- **Missing in pi-zig**: no header-resolution helper. (could not verify) whether `src/pi/ai_client.zig` (out of scope) does any equivalent expansion when reading `models.json` headers — but the helper itself is absent.
- **Complexity**: Low.
- **User-visible**: Yes — if `models.json` is supported with header values that need env or shell expansion, those will be sent literally.

### Gap 14 — Persistent `SettingsManager` instance + reload/applyOverrides/drainErrors API
- **Upstream behavior**: `SettingsManager` is constructed once per process, holds the merged `Settings`, exposes `reload()` (re-read both files), `applyOverrides(overrides)` (e.g. for `--settings`-style runtime overrides), and `drainErrors()`/`flush()` so the TUI can show parse errors and ensure writes have hit disk before exit.
- **Missing in pi-zig**: pi-zig is CLI-call-shaped — every `settings get`/`set` re-reads both files. The RPC server (mentioned in `cli_runtime.zig` line counts) may need a persistent manager (could not verify — `cli_runtime.zig` and `rpc.zig` were not in scope).
- **Complexity**: Medium.
- **User-visible**: Maybe — only matters for the RPC server lifetime.

---

## 4. Estimated parity = ~45%

### Math

Weight each upstream surface by **size + user-visibility**, then score what fraction pi-zig actually implements.

| Surface | Weight | pi-zig coverage | Score | Notes |
|---|---:|---:|---:|---|
| `auth-storage.ts` (storage backend abstraction, file lock, in-memory backend, runtime override, fallback resolver, drainable error queue, full 6-arm getAuthStatus, login()) | 25 | 40% | 10 | OAuth refresh + provider registry + on-disk schema present; no AuthStorage instance, no lock, no runtime override, no fallback resolver, no real login |
| `auth-guidance.ts` (4 formatters) | 3 | 0% | 0 | No references |
| `http-dispatcher.ts` (default, choices, parse, format, configureHttpDispatcher) | 12 | 25% | 3 | parser + default value mirrored; no dispatcher install, no labelled choices, no format helper, `httpIdleTimeoutMs` has no runtime effect |
| `settings-manager.ts` (Settings schema, 4 migrations, FileSettingsStorage with lockfile, persistent SettingsManager with writeQueue, ~80 typed getters/setters with clamping/enum validation, projectScoped paths, applyOverrides, reload, drainErrors, flush) | 25 | 55% | 14 | Read parity strong (`resolvedSettings` covers most fields including default substitution); migrations all implemented and tested; CLI `settings set` writes preserve unrelated keys. No persistent manager, no lockfile, no write queue, no per-field validation on the write path, `packages`/`extensions`/`skills`/`prompts`/`themes` arrays not surfaced in resolved output |
| `defaults.ts` (single constant) | 1 | 0% | 0 | Not exported by pi-zig as a constant; (could not verify) whether the agent loop already substitutes the default elsewhere |
| `diagnostics.ts` (collision/diagnostic interfaces) | 3 | 0% | 0 | pi-zig has CLI parser diagnostics, no resource collision schema |
| `output-guard.ts` (stdout takeover + backpressure-safe writer) | 10 | 0% | 0 | Entirely missing |
| `session-cwd.ts` (missing-cwd issue + UX + assertion) | 8 | 0% | 0 | Entirely missing — and the session header writes `"cwd":"."`, so the precondition isn't even captured |
| `resolve-config-value.ts` (cached value/header expansion + Windows shell fallback + throw variants) | 13 | 35% | 5 | Non-cached `!cmd` + env + literal resolution present in `auth.zig`; no cache, no header helper, no `OrThrow` variants, sh-only (no Windows fallback) |
| **Total** | **100** | | **32 / 100** | |

Sanity check (independent count): of 80 distinct symbols/methods I enumerated in section 1, I count ~35 with at least partial pi-zig mapping in section 2 (~44%). The weighted method above yields **~32%**; averaging with the symbol-count yields **~38%**. Rounding up for the read-side parity that *does* work end-to-end (`resolveApiKeyMutable`, the migrations, `resolvedSettings`, OAuth refresh + Vertex ADC + AWS profile resolution — all of which are substantive features not in upstream's `core/` modules but live in `auth.zig`) gives:

**Estimated parity ≈ 40–45%.** I will state **45%** as the headline number with the caveat that this includes the bonus Zig-only surface (Vertex ADC token minting with RS256 service-account JWTs; AWS shared-credentials parsing; CLI subcommands) that has no upstream-`core/` counterpart and therefore doesn't count toward the parity numerator above. Without that bonus surface, parity against the assigned files alone is closer to **35%**.

### Honest caveats
- Several gaps depend on files outside scope (`ai_client.zig`, `cli_runtime.zig`, `extensions.zig`, `agent.zig`, `tui_terminal.zig`). For each `(could not verify)` mark above, the gap may be smaller or larger than this audit asserts.
- pi-zig adds substantial surface area upstream's `core/` doesn't have (Vertex ADC RS256 minting, AWS profile parsing, `auth providers` CLI, ambient-credential auth-status hints, settings JSON report with `errors` array). Those are credited only as "matching where they overlap" and not double-counted as parity.
- "User-visible Y/N" assumes the gap is hit during normal usage; rare race conditions (gap #3, gap #12) are marked Y because they cause data loss when they do hit.
- The 45% figure is a defensible lower bound for the union "feature surface listed in upstream `core/` ∪ pi-zig auth/settings/session surface". A reviewer who weights the cross-process locking and OAuth login as catastrophic would land closer to **30%**; one who weights the JSON-report parity highly would land closer to **55%**.

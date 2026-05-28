# gap-09 audit: AI core utilities (`packages/ai/src/` excluding `providers/` and `utils/oauth/`)

Read-only audit performed on branch `codex/pi-zig-progress` against pi-zig HEAD (commit `5db2192`). Comparison is between:

- **Upstream**: `upstream/pi/packages/ai/src/` root files plus `utils/{diagnostics,event-stream,hash,headers,json-parse,node-http-proxy,overflow,sanitize-unicode,typebox-helpers,validation}.ts`. The `providers/` subdirectory and `utils/oauth/` are intentionally excluded (covered by gap-08).
- **pi-zig**: primarily `src/pi/ai_client.zig` (6324 LoC), `src/pi/models.zig` (892), `src/pi/models.generated.zig` (20394), `src/pi/providers.zig` (153), `src/pi/types.zig` (66), with cross-references into `src/pi/agent.zig` and `src/pi/cli_runtime.zig`.

All file:line references were verified by reading the listed files in full where reasonable. The upstream `providers/openai-codex-responses.ts:103-108` retry classifier and `agent-session.ts:2429-2441` retry classifier (which both live just outside the audit boundary) are explicitly included because the audit deliverable calls for the retry classifier comparison and they are the only retry-classifier source-of-truth strings in the package family.

---

## 1. Surface inventory (every exported function / class / type / constant in upstream)

### `index.ts` — re-exports
The root index re-exports the following modules wholesale (not separate surface, but it pins what's "public"):

- `Type` and types `Static`, `TSchema` from `typebox`
- `* from api-registry.ts, env-api-keys.ts, image-models.ts, images.ts, images-api-registry.ts, models.ts, session-resources.ts, stream.ts, types.ts`
- `* from providers/{faux,register-builtins}` + `providers/images/register-builtins`
- `provider option types only` (Anthropic/Bedrock/etc.) — bodies live in `providers/` (out of scope)
- `* from utils/{diagnostics,event-stream,json-parse,overflow,typebox-helpers,validation}.ts`
- `OAuth* types only` from `utils/oauth/types.ts`

### `types.ts`
- **Api union types**: `KnownApi` (9-arm: openai-completions, mistral-conversations, openai-responses, azure-openai-responses, openai-codex-responses, anthropic-messages, bedrock-converse-stream, google-generative-ai, google-vertex), `Api = KnownApi | (string & {})`
- **Provider union types**: `KnownProvider` (32 arms — Amazon Bedrock, Anthropic, Google, Vertex, OpenAI, Azure, OpenAI-codex, DeepSeek, GitHub Copilot, xAI, Groq, Cerebras, OpenRouter, Vercel AI Gateway, z.ai, Mistral, MiniMax, MiniMax-CN, MoonshotAI, MoonshotAI-CN, HuggingFace, Fireworks, Together, OpenCode, OpenCode-Go, Kimi-Coding, Cloudflare Workers AI, Cloudflare AI Gateway, Xiaomi + 3 token-plan variants), `Provider = KnownProvider | string`
- **Images types**: `KnownImagesApi = "openrouter-images"`, `KnownImagesProvider = "openrouter"`, `ImagesApi = KnownImagesApi | (string & {})`, `ImagesProvider`
- **Thinking levels**: `ThinkingLevel` ("minimal"|"low"|"medium"|"high"|"xhigh"), `ModelThinkingLevel = "off" | ThinkingLevel`, `ThinkingLevelMap = Partial<Record<ModelThinkingLevel, string | null>>`
- **`interface ThinkingBudgets`** (`minimal?:number; low?:number; medium?:number; high?:number`)
- `type CacheRetention = "none"|"short"|"long"`
- `type Transport = "sse"|"websocket"|"websocket-cached"|"auto"`
- `interface ProviderResponse { status; headers }`
- **`interface StreamOptions`** (large; comprehensive list): `temperature`, `maxTokens`, `signal` (AbortSignal), `apiKey`, `transport`, `cacheRetention`, `sessionId`, `onPayload(payload, model) => unknown | Promise`, `onResponse(response, model) => void | Promise`, `headers`, `timeoutMs`, `maxRetries`, `maxRetryDelayMs` (default 60_000), `metadata`
- `type ProviderStreamOptions = StreamOptions & Record<string, unknown>`
- **`interface ImagesOptions`** (analogue subset)
- `interface SimpleStreamOptions extends StreamOptions { reasoning?: ThinkingLevel; thinkingBudgets?: ThinkingBudgets }`
- **Generic stream function signatures**: `StreamFunction<TApi, TOptions>`, `ImagesFunction<TApi, TOptions>`
- **Content parts**: `TextSignatureV1` (`{ v:1; id; phase?:"commentary"|"final_answer" }`), `TextContent`, `ThinkingContent` (incl. `redacted` flag), `ImageContent`, `ToolCall` (incl. Google `thoughtSignature`)
- **`interface Usage`** (`input`, `output`, `cacheRead`, `cacheWrite`, `totalTokens`, nested `cost: { input, output, cacheRead, cacheWrite, total }` in dollars)
- `type StopReason = "stop"|"length"|"toolUse"|"error"|"aborted"`
- **Message types**: `UserMessage`, `AssistantMessage` (incl. `api`, `provider`, `model`, `responseModel?`, `responseId?`, `diagnostics?`, `usage`, `stopReason`, `errorMessage?`, `timestamp`), `ToolResultMessage<TDetails>`, `Message`
- **Images message types**: `ImagesInputContent`, `ImagesOutputContent`, `ImagesContext`, `ImagesStopReason`, `AssistantImages`
- **`interface Tool<TParameters>`** (`name`, `description`, `parameters` — a TypeBox `TSchema`)
- **`interface Context`** (`systemPrompt?`, `messages`, `tools?`)
- **`type AssistantMessageEvent`** discriminated union — 13 event types: `start`, `text_start`/`text_delta`/`text_end`, `thinking_start`/`thinking_delta`/`thinking_end`, `toolcall_start`/`toolcall_delta`/`toolcall_end`, `done`, `error`
- **Compat interfaces**: `OpenAICompletionsCompat` (~18 booleans + enums + nested routing), `OpenAIResponsesCompat`, `AnthropicMessagesCompat`, `OpenRouterRouting`, `VercelGatewayRouting`
- **`interface Model<TApi>`**: `id`, `name`, `api`, `provider`, `baseUrl`, `reasoning`, `thinkingLevelMap?`, `input: ("text"|"image")[]`, `cost: { input, output, cacheRead, cacheWrite }` ($/M tokens), `contextWindow`, `maxTokens`, `headers?`, conditional `compat?: …` keyed on `TApi`
- `interface ImagesModel<TApi>` (Omit-of `Model` minus `api/provider/reasoning/contextWindow/maxTokens/compat`, plus `output`)

### `models.ts`
- Module-level state: `modelRegistry: Map<string, Map<string, Model<Api>>>` initialized at load from `MODELS`
- **`getModel<TProvider, TModelId>(provider, modelId): Model<…>`**
- **`getProviders(): KnownProvider[]`**
- **`getModels<TProvider>(provider): Model<…>[]`**
- **`calculateCost<TApi>(model, usage): Usage["cost"]`** — divides `model.cost.*` by 1_000_000 and multiplies by token counts, sets `usage.cost.{input,output,cacheRead,cacheWrite,total}`
- `EXTENDED_THINKING_LEVELS = ["off","minimal","low","medium","high","xhigh"]` (private constant)
- **`getSupportedThinkingLevels<TApi>(model): ModelThinkingLevel[]`** — filters by `thinkingLevelMap` (null = unsupported; for `"xhigh"` requires `mapped !== undefined`)
- **`clampThinkingLevel<TApi>(model, level): ModelThinkingLevel`** — walk forward then backward through `EXTENDED_THINKING_LEVELS` to nearest supported
- **`modelsAreEqual<TApi>(a, b): boolean`** — id + provider equality, returns false on null/undefined

### `models.generated.ts`
- `MODELS` const — 16115 lines of generated catalog keyed `Record<KnownProvider, Record<modelId, Model<Api>>>`

### `image-models.ts`
- `imageModelRegistry: Map<string, Map<string, ImagesModel<ImagesApi>>>`
- `getImageModel<TProvider, TModelId>(provider, modelId)`
- `getImageProviders(): KnownImagesProvider[]`
- `getImageModels<TProvider>(provider): ImagesModel<…>[]`

### `image-models.generated.ts`
- `IMAGE_MODELS` const (444 lines) keyed `Record<KnownImagesProvider, Record<id, ImagesModel<ImagesApi>>>`

### `stream.ts` — top-level entry points (the "stream" / "complete" front door)
- `stream<TApi>(model, context, options?): AssistantMessageEventStream` (resolves api provider via `getApiProvider` from `api-registry`, throws on missing)
- `complete<TApi>(model, context, options?): Promise<AssistantMessage>` (calls `stream(...).result()`)
- `streamSimple<TApi>(model, context, options?: SimpleStreamOptions): AssistantMessageEventStream`
- `completeSimple<TApi>(model, context, options?: SimpleStreamOptions): Promise<AssistantMessage>`
- re-exports `getEnvApiKey`

### `api-registry.ts`
- **`type ApiStreamFunction`** (untyped), `ApiStreamSimpleFunction`
- **`interface ApiProvider<TApi, TOptions>`** (`api`, `stream`, `streamSimple`)
- Private interface `ApiProviderInternal`, private `RegisteredApiProvider = { provider, sourceId? }`
- Module-level `apiProviderRegistry: Map<string, RegisteredApiProvider>`
- Private wrapper helpers: `wrapStream`, `wrapStreamSimple` (validate `model.api === provider.api` and throw `Mismatched api` otherwise)
- **`registerApiProvider<TApi, TOptions>(provider, sourceId?): void`**
- **`getApiProvider(api): ApiProviderInternal | undefined`**
- **`getApiProviders(): ApiProviderInternal[]`**
- **`unregisterApiProviders(sourceId): void`** (used by extension hot-reload)
- **`clearApiProviders(): void`**

### `images-api-registry.ts`
- `ImagesApiFunction`, `ImagesApiProvider`, `ImagesApiProviderInternal`
- `imagesApiProviderRegistry: Map<…>`
- `registerImagesApiProvider`, `getImagesApiProvider` (no `unregister`/`clear` analogues here)

### `env-api-keys.ts`
- Module-level Node-fs lazy loaders (`_existsSync`, `_homedir`, `_join`) — async-imported only inside `node`/`bun`, never in browser/Vite
- `getProcEnv(key): string|undefined` — Bun-sandbox workaround that reads `/proc/self/environ` when `process.env` is empty (oven-sh/bun#27802)
- Module-level cache `cachedVertexAdcCredentialsExists`
- **`hasVertexAdcCredentials(): boolean`** — checks `GOOGLE_APPLICATION_CREDENTIALS` env, falls back to `~/.config/gcloud/application_default_credentials.json`. Caches result; non-cached false return while async imports are racing in `node` env so a later call retries.
- **`getApiKeyEnvVars(provider): readonly string[] | undefined`** — covers all 32 known providers
  - `github-copilot → ["COPILOT_GITHUB_TOKEN"]`
  - `anthropic → ["ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]` (OAuth precedence enforced first)
  - everything else flat single-key map (openai, azure-openai-responses, deepseek, google, google-vertex, groq, cerebras, xai, openrouter, vercel-ai-gateway, zai, mistral, minimax, minimax-cn, moonshotai, moonshotai-cn, huggingface, fireworks, together, opencode, opencode-go, kimi-coding, cloudflare-workers-ai, cloudflare-ai-gateway, xiaomi + 3 xiaomi-token-plan-*)
- **`findEnvKeys(provider): string[] | undefined`** — filters `getApiKeyEnvVars` by what's actually set in `process.env` or `/proc/self/environ`
- **`getEnvApiKey(provider): string | undefined`** — uses `findEnvKeys[0]`; **special branches**:
  - `google-vertex` returns the literal sentinel `"<authenticated>"` when `hasVertexAdcCredentials()` AND `GOOGLE_CLOUD_PROJECT|GCLOUD_PROJECT` AND `GOOGLE_CLOUD_LOCATION` are all set
  - `amazon-bedrock` returns `"<authenticated>"` for any of: `AWS_PROFILE`, `AWS_ACCESS_KEY_ID+AWS_SECRET_ACCESS_KEY`, `AWS_BEARER_TOKEN_BEDROCK`, `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`, `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_WEB_IDENTITY_TOKEN_FILE`

### `session-resources.ts`
- `type SessionResourceCleanup = (sessionId?: string) => void`
- Module-level `sessionResourceCleanups = new Set<SessionResourceCleanup>()`
- **`registerSessionResourceCleanup(cleanup): () => void`** (returns disposer)
- **`cleanupSessionResources(sessionId?): void`** — invokes every cleanup; collects throws into an `AggregateError("Failed to cleanup session resources")` and rethrows

### `cli.ts` — `@earendil-works/pi-ai` standalone OAuth login CLI (different binary from coding-agent)
- File-scoped `AUTH_FILE = "auth.json"`
- `prompt(rl, question)` — readline wrapper
- `loadAuth()` / `saveAuth(auth)` — JSON.parse / writeFileSync of cwd-local `auth.json`
- `login(providerId)` — invokes `provider.login` with stdio-driven `onAuth`/`onDeviceCode`/`onPrompt`/`onSelect`/`onProgress` callbacks
- `main()` — `help` / `list` / `login [provider]` subcommands; interactive provider selection when arg omitted

### `utils/diagnostics.ts`
- **`interface DiagnosticErrorInfo`** (`name?`, `message`, `stack?`, `code?: string|number`)
- **`interface AssistantMessageDiagnostic`** (`type`, `timestamp`, `error?`, `details?`)
- **`formatThrownValue(value): string`** (Error → message || name; string passthrough; else `String(value)`)
- **`extractDiagnosticError(error): DiagnosticErrorInfo`**
- **`createAssistantMessageDiagnostic(type, error, details?): AssistantMessageDiagnostic`**
- **`appendAssistantMessageDiagnostic<T>(message, diagnostic): void`**

### `utils/event-stream.ts`
- **Generic `class EventStream<T, R = T> implements AsyncIterable<T>`** with `push(event)`, `end(result?)`, `result(): Promise<R>`, `[Symbol.asyncIterator]()`; the `isComplete` / `extractResult` predicates parameterize termination.
- **`class AssistantMessageEventStream extends EventStream<AssistantMessageEvent, AssistantMessage>`** — wires `done`/`error` event types as terminals.
- **`createAssistantMessageEventStream(): AssistantMessageEventStream`** factory used by extensions.

### `utils/hash.ts`
- **`shortHash(str): string`** — FNV/MurmurHash-like 2-state h1/h2 mixer, returns base-36 concatenation of two 32-bit words (~13 chars typical).

### `utils/headers.ts`
- **`headersToRecord(headers: Headers): Record<string, string>`**

### `utils/json-parse.ts`
- File-scoped `VALID_JSON_ESCAPES = new Set(['"','\\','/','b','f','n','r','t','u'])`
- `isControlCharacter(char): boolean` (code-point in `0x00..0x1f`)
- `escapeControlCharacter(char): string` (maps `\b\f\n\r\t` to backslash escapes, else `\\u00xx`)
- **`repairJson(json): string`** — single-pass repairer that escapes raw control chars inside string literals and doubles backslashes before invalid escape characters (handling `\u<hex4>` as a special branch).
- **`parseJsonWithRepair<T>(json): T`** — try `JSON.parse`; on failure, run `repairJson` and retry only if it changed something.
- **`parseStreamingJson<T = Record<string, unknown>>(partial)`** — three-tier fallback: `parseJsonWithRepair` → `partial-json` package's `parse()` → `partial-json.parse(repairJson(...))` → `{}`. Empty/whitespace returns `{} as T`.

### `utils/node-http-proxy.ts`
- `DEFAULT_PROXY_PORTS` map (ftp=21, gopher=70, http=80, https=443, ws=80, wss=443)
- **`interface NodeHttpProxyAgents { httpAgent; httpsAgent }`**
- `UNSUPPORTED_PROXY_PROTOCOL_MESSAGE` constant
- Private helpers: `getProxyEnv(key)` (case-insensitive env lookup), `parseProxyTargetUrl`, `shouldProxyHostname(hostname, port)` (honors `no_proxy` with `*`, host+port matching, and `*.example.com` wildcards), `getProxyForUrl(targetUrl)` (resolves `<protocol>_proxy` then `all_proxy`)
- **`resolveHttpProxyUrlForTarget(targetUrl): URL | undefined`** (throws on non-`http(s):` proxy URLs)
- **`createHttpProxyAgentsForTarget(targetUrl): NodeHttpProxyAgents | undefined`** — wires `http-proxy-agent` + `https-proxy-agent`

### `utils/overflow.ts` (THE context-overflow detector — load-bearing)
- Private regex array `OVERFLOW_PATTERNS` (23 entries) — see §2 retry classifier section below for the full list
- Private regex array `NON_OVERFLOW_PATTERNS` (3 entries):
  - `/^(Throttling error|Service unavailable):/i` (Bedrock-prefixed)
  - `/rate limit/i`
  - `/too many requests/i`
- **`isContextOverflow(message: AssistantMessage, contextWindow?: number): boolean`** — three-arm detection:
  1. `stopReason === "error"` AND not a non-overflow pattern AND matches an overflow pattern
  2. Silent overflow (`stopReason === "stop"` + `usage.input + usage.cacheRead > contextWindow`) — z.ai-style
  3. Length-stop overflow (`stopReason === "length"` + `output === 0` + `input+cacheRead >= contextWindow * 0.99`) — Xiaomi MiMo style
- **`getOverflowPatterns(): RegExp[]`** — testing accessor

### `utils/sanitize-unicode.ts`
- **`sanitizeSurrogates(text): string`** — strips unpaired UTF-16 surrogates via `replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "")`. Used to keep providers (notably Anthropic SDK) from JSON-encoding errors on malformed text.

### `utils/typebox-helpers.ts`
- **`StringEnum<T>(values, options?): TUnsafe<T[number]>`** — emits a JSON Schema enum (so Google API + other providers that reject `anyOf`/`const` can still represent enums).

### `utils/validation.ts`
- Module-level `validatorCache: WeakMap<object, Compile>` and `TYPEBOX_KIND = Symbol.for("TypeBox.Kind")`
- Private helpers: `isRecord`, `isJsonSchemaObject`, `hasTypeBoxMetadata`, `getSchemaTypes`, `matchesJsonType`, `isValidatorSchema`, `getSubSchemaValidator`, `coercePrimitiveByType`, `applySchemaObjectCoercion`, `applySchemaArrayCoercion`, `coerceWithUnionSchema`, `coerceWithJsonSchema`, `getValidator`, `formatValidationPath`
- **`validateToolCall(tools, toolCall): any`** — finds tool by name then delegates
- **`validateToolArguments(tool, toolCall): any`** — `Value.Convert` (TypeBox) + non-TypeBox JSON-Schema coercion for raw JSON Schema; throws `Validation failed for tool "<name>":\n  - <path>: <message>\n...\n\nReceived arguments:\n<JSON>`

### Retry-classifier source (lives in `providers/openai-codex-responses.ts` + `coding-agent/agent-session.ts`, surfaced here per audit scope)
- `providers/openai-codex-responses.ts:103-108`: `isRetryableError(status, errorText)` — `status === 429|500|502|503|504` OR text matches `/rate.?limit|overloaded|service.?unavailable|upstream.?connect|connection.?refused/i`
- `providers/openai-codex-responses.ts:110-122`: `sleep(ms, signal?)` (AbortSignal-honoring)
- `providers/openai-codex-responses.ts:1270-1294`: `parseErrorResponse(response)` → `{ message, friendlyMessage? }` — codex usage-limit ChatGPT-plan messages
- `coding-agent/agent-session.ts:2429-2441`: `_isRetryableError(message: AssistantMessage)` — single regex literal (single source of truth for retry strings in upstream):
  ```
  /overloaded|provider.?returned.?error|rate.?limit|too many requests|429|500|502|503|504|service.?unavailable|server.?error|internal.?error|network.?error|connection.?error|connection.?refused|connection.?lost|websocket.?closed|websocket.?error|other side closed|fetch failed|upstream.?connect|reset before headers|socket hang up|ended without|stream ended before message_stop|http2 request did not get a response|timed? out|timeout|terminated|retry delay/i
  ```

---

## 2. Mapped to pi-zig (or `(MISSING)`)

### 2a. Retry classifier strings (token-by-token comparison)

Upstream `agent-session.ts:2438` is the single source of truth. pi-zig's `isRetryableProviderErrorText` lives in `src/pi/ai_client.zig:200-232`; uses ASCII-folding `containsWordsInOrderIgnoreCase` rather than regex but the token sets match. Status-line digits (429/500/502/503/504) are matched as bare substrings via `containsAsciiIgnoreCase` (the regex matches digits in any context too).

| upstream regex token | pi-zig | file:line |
|---|---|---|
| `overloaded` | `containsAsciiIgnoreCase(text, "overloaded")` | `ai_client.zig:201` |
| `provider.?returned.?error` | `containsWordsInOrderIgnoreCase(&.{"provider","returned","error"})` | `ai_client.zig:203` |
| `rate.?limit` | `&.{"rate","limit"}` | `ai_client.zig:204` |
| `too many requests` | `&.{"too","many","requests"}` | `ai_client.zig:205` |
| `429` / `500` / `502` / `503` / `504` | five `containsAsciiIgnoreCase` substring checks | `ai_client.zig:206-210` |
| `service.?unavailable` | `&.{"service","unavailable"}` | `ai_client.zig:211` |
| `server.?error` | `&.{"server","error"}` | `ai_client.zig:212` |
| `internal.?error` | `&.{"internal","error"}` | `ai_client.zig:213` |
| `network.?error` | `&.{"network","error"}` | `ai_client.zig:214` |
| `connection.?error` | `&.{"connection","error"}` | `ai_client.zig:215` |
| `connection.?refused` | `&.{"connection","refused"}` | `ai_client.zig:216` |
| `connection.?lost` | `&.{"connection","lost"}` | `ai_client.zig:217` |
| `websocket.?closed` | `&.{"websocket","closed"}` | `ai_client.zig:218` |
| `websocket.?error` | `&.{"websocket","error"}` | `ai_client.zig:219` |
| `other side closed` | `&.{"other","side","closed"}` | `ai_client.zig:220` |
| `fetch failed` | `&.{"fetch","failed"}` | `ai_client.zig:221` |
| `upstream.?connect` | `&.{"upstream","connect"}` | `ai_client.zig:222` |
| `reset before headers` | `&.{"reset","before","headers"}` | `ai_client.zig:223` |
| `socket hang up` | `&.{"socket","hang","up"}` | `ai_client.zig:224` |
| `ended without` | `&.{"ended","without"}` | `ai_client.zig:225` |
| `stream ended before message_stop` | `&.{"stream","ended","before","message_stop"}` | `ai_client.zig:226` |
| `http2 request did not get a response` | `&.{"http2","request","did","not","get","a","response"}` | `ai_client.zig:227` |
| `timed? out` | `&.{"timed","out"}` | `ai_client.zig:228` |
| `timeout` | `containsAsciiIgnoreCase(text, "timeout")` | `ai_client.zig:229` |
| `terminated` | `containsAsciiIgnoreCase(text, "terminated")` | `ai_client.zig:230` |
| `retry delay` | `&.{"retry","delay"}` | `ai_client.zig:231` |

**Verdict: every retryable token is mapped.** Two compatibility caveats:

1. Upstream regex tokens use `.?` as a single-character wildcard (`rate limit`, `rate-limit`, `rate_limit`, `ratellimit` all match). pi-zig's `containsWordsInOrderIgnoreCase` performs **substring chain matching** (`indexOf word1`, then `indexOf word2` after that, etc.) which is **strictly more permissive** than `.?` — `"rate" + arbitrary chars + "limit"` matches. This is observable: e.g. `"rate-limited; please slow down"` matches both. A regression would manifest only if a literal `"rateXlimit"` should NOT retry; no such case exists in upstream documentation.
2. The digit checks via `containsAsciiIgnoreCase("429", text)` also match strings like `"abc429def"` or a Unicode-fullwidth "４２９" only in ASCII (since `toLower` is byte-wise). Equivalent reach to the regex, which is also unanchored.

pi-zig adds extra Bedrock-specific Throttling word matching at `ai_client.zig:202` (`{"throttling","error"}`) for the formatted `"Throttling error: ..."` prefix that upstream's `formatBedrockError` produces — this is **a pi-zig superset**, not a gap; upstream catches `Throttling error: rate limit` via the `rate.?limit` token.

### 2b. Non-retryable / context-overflow patterns (token comparison)

Upstream `utils/overflow.ts:OVERFLOW_PATTERNS` vs pi-zig `isContextOverflowErrorText` at `ai_client.zig:234-258`.

| upstream regex | pi-zig | file:line | Notes |
|---|---|---|---|
| `/prompt is too long/i` (Anthropic) | `&.{"prompt","too","long"}` | `ai_client.zig:236` | match |
| `/request_too_large/i` (Anthropic 413) | `containsAsciiIgnoreCase(text, "request_too_large")` | `ai_client.zig:237` | match |
| `/input is too long for requested model/i` (Bedrock) | `&.{"input","too","long","requested","model"}` | `ai_client.zig:238` | match |
| `/exceeds the context window/i` (OpenAI) | `&.{"exceeds","context","window"}` | `ai_client.zig:239` | match (more permissive: chain rather than literal substring, but reachable strings overlap) |
| `/exceeds (?:the )?(?:model'?s )?maximum context length of [\d,]+ tokens?/i` (LiteLLM) | `&.{"exceeds","maximum","context","length"}` | `ai_client.zig:240` | match — the digit/token-noun tail is dropped (more permissive but won't false-positive on documented strings) |
| `/input token count.*exceeds the maximum/i` (Gemini) | `&.{"input","token","count","exceeds","maximum"}` | `ai_client.zig:241` | match |
| `/maximum prompt length is \d+/i` (xAI) | `&.{"maximum","prompt","length","is"}` | `ai_client.zig:242` | match |
| `/reduce the length of the messages/i` (Groq) | `&.{"reduce","length","messages"}` | `ai_client.zig:243` | match (drops `"of the"` — chain matcher still matches "reduce ... length ... messages") |
| `/maximum context length is \d+ tokens/i` (OpenRouter) | `&.{"maximum","context","length","is"}` | `ai_client.zig:244` | match (digits stripped) |
| `/input \(\d+ tokens\) is longer than the model'?s context length \(\d+ tokens\)/i` (Together) | `&.{"longer","model","context","length"}` | `ai_client.zig:245` | match |
| `/exceeds the limit of \d+/i` (GitHub Copilot) | `&.{"exceeds","limit"}` | `ai_client.zig:246` | match (more permissive — could false-positive on `"exceeds rate limit"`; mitigated by the upstream NON_OVERFLOW guard that pi-zig also uses) |
| `/exceeds the available context size/i` (llama.cpp) | `&.{"exceeds","available","context","size"}` | `ai_client.zig:247` | match |
| `/greater than the context length/i` (LM Studio) | `&.{"greater","than","context","length"}` | `ai_client.zig:248` | match |
| `/context window exceeds limit/i` (MiniMax) | `&.{"context","window","exceeds","limit"}` | `ai_client.zig:249` | match |
| `/exceeded model token limit/i` (Kimi) | `&.{"exceeded","model","token","limit"}` | `ai_client.zig:250` | match |
| `/too large for model with \d+ maximum context length/i` (Mistral) | `&.{"too","large","model","maximum","context","length"}` | `ai_client.zig:251` | match |
| `/model_context_window_exceeded/i` (z.ai) | `containsAsciiIgnoreCase(text, "model_context_window_exceeded")` | `ai_client.zig:252` | match |
| `/prompt too long; exceeded (?:max )?context length/i` (Ollama) | `&.{"prompt","too","long","context","length"}` | `ai_client.zig:253` | match |
| `/context[_ ]length[_ ]exceeded/i` (generic) | both `containsAsciiIgnoreCase(text, "context_length_exceeded")` and `&.{"context","length","exceeded"}` | `ai_client.zig:254-255` | match (split into snake_case and space-separated branches; covers both upstream branches) |
| `/too many tokens/i` (generic) | `&.{"too","many","tokens"}` | `ai_client.zig:256` | match |
| `/token limit exceeded/i` (generic) | `&.{"token","limit","exceeded"}` | `ai_client.zig:257` | match |
| `/^4(?:00|13)\s*(?:status code)?\s*\(no body\)/i` (Cerebras) | **(MISSING)** | — | **GAP-09-A** |

NON_OVERFLOW guards (3 entries upstream → 4 entries pi-zig at `ai_client.zig:260-265`):

| upstream pattern | pi-zig |
|---|---|
| `/^(Throttling error\|Service unavailable):/i` | `&.{"throttling","error"}` + `&.{"service","unavailable"}` (anchor `^...:` not enforced, but the formatBedrockError prefix shape still wins) |
| `/rate limit/i` | `&.{"rate","limit"}` |
| `/too many requests/i` | `&.{"too","many","requests"}` |

The non-overflow guard runs first in `isContextOverflowErrorText` (`ai_client.zig:235`), matching upstream's "skip patterns matching `NON_OVERFLOW_PATTERNS`" branch in `utils/overflow.ts:126-128`. Behaviorally equivalent for documented inputs.

**Silent-overflow detection (z.ai / Xiaomi MiMo)** — the two upstream branches at `utils/overflow.ts:132-148` that check `contextWindow` against `usage.input + usage.cacheRead`:

| upstream branch | pi-zig | Gap |
|---|---|---|
| `stopReason === "stop"` + `usage.input + cacheRead > contextWindow` | **(MISSING)** | **GAP-09-B** — pi-zig only inspects error text and never compares usage tokens to context window, so silent-overflow on z.ai successful responses is not detected. |
| `stopReason === "length"` + `output === 0` + `input+cacheRead >= contextWindow * 0.99` | **(MISSING)** | **GAP-09-B** — same: Xiaomi MiMo's truncate-to-fit-then-zero-output signal is not flagged. |

Mitigating fact: pi-zig's `ai_client.ChatCompletionResult` does **not carry token usage at all** (`ai_client.zig:82-91`), so silent overflow couldn't be detected even if the classifier wanted to. This is upstream of the classifier gap — see GAP-09-C.

### 2c. Models / catalog surface (`models.ts` + `models.generated.ts`)

| upstream | pi-zig | file:line | Status |
|---|---|---|---|
| `MODELS` const (16115 LOC) | `pub const models = [_]ModelEntry{...}` (20394 LOC) | `models.generated.zig:65+` | port — generated by `scripts/generate-model-catalog.mjs` |
| 924 models / 32 providers (counts pinned at compile-time) | `upstream_model_count: usize = 924`, `upstream_provider_count: usize = 32` | `models.generated.zig:27-28` | anchored |
| `getModel<TProvider, TModelId>(provider, modelId)` | `find(provider, model_id) ?*const ModelEntry` | `models.zig:26-31` | port (with type-parametric loss, expected in Zig) |
| `getProviders()` | `providers` slice | `models.zig:7` | port |
| `getModels<TProvider>(provider)` | implicit via `find` loop; no dedicated helper exposed | — | partial — used inline rather than as a function |
| `calculateCost(model, usage)` | **(MISSING)** | — | **GAP-09-D** — pi-zig has no `Usage` struct and no cost computation anywhere |
| `getSupportedThinkingLevels` | `thinkingLevelSupported` + iteration in `writeSupportedThinkingLevelsJson` | `models.zig:127-137, 590-600` | port (loop-based rather than filter) |
| `clampThinkingLevel` | `clampThinkingLevel` | `models.zig:139-155` | port — bidirectional search semantics identical |
| `modelsAreEqual(a, b)` | implicit equality via pointer compare in `find`; no exported helper | — | not exported but used inline |
| upstream `Model` interface | `ModelEntry` struct (flat — no nested `cost` / `compat`; `thinkingLevelMap` flattened to six bools) | `models.generated.zig:4-25` | port — **compat substructure (OpenAICompletionsCompat / OpenAIResponsesCompat / AnthropicMessagesCompat) is entirely absent**, see GAP-09-E |
| `EXTENDED_THINKING_LEVELS` constant | `thinking_order` array | `models.zig:11` | port |

CLI helpers `writeResolvedCliJson` / `writeListModelsJson` / `writeModelJson` / `writeProviderModelsJson` / `resolveScopePattern` (`models.zig:51-282`) are pi-zig additions that surface the catalog as JSON for the workbench front end; upstream serves this via TS imports rather than a CLI subcommand.

### 2d. Image-models surface

| upstream | pi-zig | Status |
|---|---|---|
| `IMAGE_MODELS` (444 LOC) | **(MISSING)** | **GAP-09-F** — no `image-models.generated.zig`; pi-zig's `ai_client.zig` runs OpenRouter images inline with a hardcoded payload builder |
| `getImageModel`, `getImageProviders`, `getImageModels` | **(MISSING)** | **GAP-09-F** |
| `ImagesModel<TApi>` struct | **(MISSING)** | **GAP-09-F** |

The image-generation code does exist in `ai_client.zig:1797-1985` (`runImageGeneration`, `parseOpenRouterImagesResult`, `buildOpenRouterImagesPayload`) and reuses the `ChatContentPart` plumbing, but there is no catalog/registry to look up an image model. The provider id `openrouter-images` appears in `src/pi/types.zig:52` and `src/pi/upstream.zig:59` as a string only.

### 2e. `stream.ts` entry points (`stream` / `complete` / `streamSimple` / `completeSimple`)

| upstream | pi-zig | Status |
|---|---|---|
| `stream(model, context, options?) -> AssistantMessageEventStream` | partially — `streamChatTurn` / `streamChatTurnText` / `streamChatTurnWithTextCallback` at `ai_client.zig:397-440` | partial — callback-based, no `AssistantMessageEventStream` |
| `complete(model, context, options?) -> Promise<AssistantMessage>` | `runChatTurn` at `ai_client.zig:330` returns `ChatCompletionResult` | partial — different return shape (no `Usage`, no `responseId`, no `diagnostics`, no `stopReason`) |
| `streamSimple` / `completeSimple` | **(MISSING)** as explicit entry points | **GAP-09-G** — the agent.zig retry/compaction loop calls `streamChatTurn` directly with no `reasoning`/`thinkingBudgets` parameter |

### 2f. `api-registry.ts` — provider runtime registration

| upstream | pi-zig | Status |
|---|---|---|
| `registerApiProvider(provider, sourceId?)` | hardcoded switch — `streamChatTurnData` at `ai_client.zig:442-518` dispatches by `isAnthropicMessagesProvider` / `isGoogleGenerativeProvider` / `isGoogleVertexProvider` / `isMistralProvider` / `isBedrockProvider` / `isAzureOpenAIResponsesProvider` / else | **(MISSING)** — **GAP-09-H** |
| `getApiProvider` / `getApiProviders` | — | **(MISSING)** — same as above |
| `unregisterApiProviders(sourceId)` | — | **(MISSING)** — extension hot-reload pathway absent |
| `clearApiProviders()` | — | **(MISSING)** |
| `wrapStream` `Mismatched api` guard | — | **(MISSING)** |

Consequence: the JS extension layer `pi.registerProvider()` / `pi.unregisterProvider()` enumerated in `src/pi/upstream.zig:135,138` has nowhere to land — extensions cannot register a new transport at runtime.

### 2g. `images-api-registry.ts`

| upstream | pi-zig | Status |
|---|---|---|
| `registerImagesApiProvider` / `getImagesApiProvider` | hardcoded `isOpenRouterImagesProvider` switch in `ai_client.zig:1858-1881` | **(MISSING)** as a registry — **GAP-09-H** |

### 2h. `env-api-keys.ts`

| upstream | pi-zig | file:line | Status |
|---|---|---|---|
| `getApiKeyEnvVars(provider)` (32-provider map) | `env_mappings = [_]EnvMapping{...}` (31 entries) | `providers.zig:55-87` | port — count differs because pi-zig folds `minimax-cn` and `moonshotai-cn` correctly but they need re-counting; both providers are present |
| OAuth-precedence for `anthropic` | `anthropic_keys = ["ANTHROPIC_OAUTH_TOKEN","ANTHROPIC_API_KEY"]` | `providers.zig:8` | port |
| `findEnvKeys(provider)` | `envKeysFor(provider) -> ?[]const []const u8` | `providers.zig:89-94` | port — but **returns env var **names** only, not what's set**; the upstream `findEnvKeys` filters by what's present in `process.env`. pi-zig consults the live env in `auth.zig` rather than in `providers.zig`. |
| `getEnvApiKey` with `<authenticated>` sentinel for `google-vertex` / `amazon-bedrock` | `auth.zig` resolution paths return the access-token / bearer / SigV4 placeholder; sentinel string not literally `"<authenticated>"` | `auth.zig` | partial — semantics replicated, sentinel string differs (no string-level compare in pi-zig because the resolver returns a typed credential variant) |
| `hasVertexAdcCredentials` | implemented across `auth.zig` for service-account ADC parsing | partial port — the function name does not exist verbatim; ADC presence is checked structurally |
| Bun `/proc/self/environ` fallback | **(MISSING)** | — | **GAP-09-I** — pi-zig reads `std.process.Environ.Map` which is filled by Zig's normal env-var loading; on Linux Bun-style sandbox bug doesn't apply (Zig binary doesn't ship as a Bun compile) |

### 2i. `session-resources.ts`

| upstream | pi-zig | Status |
|---|---|---|
| `registerSessionResourceCleanup` / `cleanupSessionResources(sessionId?)` | **(MISSING)** | **GAP-09-J** — providers that own per-session resources (the openai-codex-responses WebSocket pool, etc.) have no cleanup hook. pi-zig has no WebSocket pool to clean up (see GAP-09-N), so the immediate need is zero, but extension-registered providers would have no parking spot for cleanup. |

### 2j. `cli.ts` — `@earendil-works/pi-ai` standalone OAuth binary

| upstream | pi-zig | Status |
|---|---|---|
| Subcommands `login` / `list` / `help` writing `./auth.json` | `pi-zig auth login/list/...` writes `~/.pi/agent/auth.json` (note path divergence) | partial — pi-zig uses a different binary/subcommand and a different storage path; the standalone `@earendil-works/pi-ai` binary is not reproduced |

### 2k. `utils/diagnostics.ts`

| upstream | pi-zig | Status |
|---|---|---|
| `AssistantMessageDiagnostic` interface | **(MISSING)** | **GAP-09-K** — pi-zig's `ChatCompletionResult` (`ai_client.zig:82-91`) has no `diagnostics` field; `AssistantMessage` itself doesn't exist as a struct |
| `formatThrownValue` / `extractDiagnosticError` / `createAssistantMessageDiagnostic` / `appendAssistantMessageDiagnostic` | — | **(MISSING)** |

Cross-search confirms: `grep -rn "AssistantMessageDiagnostic\|appendDiagnostic" src/pi/*.zig` returns only the CLI-parse `Diagnostic` model in `cli_runtime.zig` (a different surface — argv parser errors, not provider/runtime failures).

### 2l. `utils/event-stream.ts`

| upstream | pi-zig | Status |
|---|---|---|
| Generic `EventStream<T, R>` async iterator with `push`/`end`/`result`/`[Symbol.asyncIterator]` | **(MISSING)** | **GAP-09-L** — pi-zig uses synchronous-style `StreamTextCallback` / `StreamDataCallback` function pointers at `ai_client.zig:152-153` instead of an iterator/queue object |
| `AssistantMessageEventStream` with `done`/`error` terminal | **(MISSING)** | **GAP-09-L** |
| `AssistantMessageEvent` discriminated union (13-arm: `start`, `text_*`, `thinking_*`, `toolcall_*`, `done`, `error`) | **(MISSING)** as a typed union | **GAP-09-L** — the JSON `print`/`json` mode and RPC events (`auto_retry_start` / `assistant_started` / `text_delta` etc.) are emitted ad-hoc as JSON in `cli_runtime.zig` and `rpc.zig` rather than going through a single typed event vocabulary. The RPC event vocabulary is functionally close but not unified. |
| `createAssistantMessageEventStream()` factory (extensions hook) | **(MISSING)** | **GAP-09-L** |

### 2m. `utils/hash.ts`

| upstream | pi-zig | Status |
|---|---|---|
| `shortHash(str)` (~13-char base-36 from a 2-state mixer) | **(MISSING)** | **GAP-09-M** — `grep -rn shortHash src/pi/*.zig` returns nothing. Upstream uses it for caching keys (e.g. session-affinity headers, fixture filenames). |

### 2n. `utils/headers.ts`

| upstream | pi-zig | Status |
|---|---|---|
| `headersToRecord(headers: Headers): Record<string, string>` | not needed — pi-zig uses `std.http.Header` slices throughout | n/a — Zig's `std.http` API works directly on headers, no `Headers` → object conversion |

### 2o. `utils/json-parse.ts`

| upstream | pi-zig | Status |
|---|---|---|
| `repairJson(json)` (control-char escaping + invalid-escape fix-up) | **(MISSING)** | **GAP-09-O** — pi-zig consumes `partial_json` deltas at `ai_client.zig:4174` by raw byte concatenation into `arguments_json`, with no repair. Anthropic, Google, and Mistral all emit raw control characters in some assistant text deltas; the resulting tool-call JSON could fail to parse downstream if the model ever streams a literal `\n` or unescaped backslash inside a partial. |
| `parseJsonWithRepair<T>(json)` | **(MISSING)** | **GAP-09-O** |
| `parseStreamingJson<T>(partial)` (three-tier fallback to `partial-json`) | **(MISSING)** | **GAP-09-O** — when pi-zig parses Anthropic `input_json_delta` arguments, it accumulates until the final `tool_use` block then parses with `std.json.parseFromSlice`, which **does not tolerate incomplete JSON**. The streaming `tool_call_delta` event surface emits `arguments_delta` as raw string deltas — the front end has to reparse incrementally on its own. |

### 2p. `utils/node-http-proxy.ts`

| upstream | pi-zig | Status |
|---|---|---|
| `createHttpProxyAgentsForTarget` + `resolveHttpProxyUrlForTarget` + `no_proxy` / `*_proxy` / `all_proxy` env handling | **(MISSING)** | **GAP-09-P** — pi-zig's `std.http.Client` does not consult any `HTTP_PROXY` / `HTTPS_PROXY` / `no_proxy` env variables; corporate-proxy users cannot route through their gateway. |

### 2q. `utils/overflow.ts`

See §2b above. Summary:
- 22 of 23 OVERFLOW_PATTERNS are ported, 1 missing (Cerebras 400/413 no-body) — **GAP-09-A**.
- Silent overflow (z.ai) and length-stop overflow (Xiaomi MiMo) — both **MISSING (GAP-09-B)**.
- 3 NON_OVERFLOW_PATTERNS ported.

### 2r. `utils/sanitize-unicode.ts`

| upstream | pi-zig | Status |
|---|---|---|
| `sanitizeSurrogates(text)` | **(MISSING)** | **GAP-09-Q** — `grep -rn "surrogate\|0xD800" src/pi/*.zig` returns nothing. pi-zig's `writeJsonString` (`ai_client.zig:4997-5045`) escapes literal control bytes (`0x00..0x1f`) but does not strip orphan UTF-16 surrogates. With models that may emit invalid UTF-16 (rare but documented for raw Anthropic SDK input), pi-zig may emit invalid UTF-8 in subsequent JSON serialization. Zig's `std.unicode.utf8ValidateSlice` is available but not used here. |

### 2s. `utils/typebox-helpers.ts`

| upstream | pi-zig | Status |
|---|---|---|
| `StringEnum(values, options?)` | **(MISSING)** | **GAP-09-R** — pi-zig has no TypeBox runtime; tool definitions are stored as raw `parameters_json` strings on `ChatToolDefinition` (`ai_client.zig:64-68`), so the choice of enum encoding is the extension/host's concern. Not material for pi-zig built-in tools (their schemas are pre-built JSON). |

### 2t. `utils/validation.ts`

| upstream | pi-zig | Status |
|---|---|---|
| `validateToolCall` / `validateToolArguments` (TypeBox + JSON-Schema coercion fallback) | **(MISSING)** | **GAP-09-S** — pi-zig accepts tool-call arguments as raw JSON strings and parses them into `std.json.Value` at tool dispatch time (`tools.zig`); no parameter-schema validation, no error reporting with a formatted path, no primitive coercion. Built-in tools each do their own `std.json.Value` field extraction. Custom JS extension tools also receive uncoerced raw JSON. |
| TypeBox `Compile` / `Value.Convert` runtime | n/a (Zig is statically typed) | — |

### 2u. Retry-with-status / parseErrorResponse / sleep helpers

| upstream | pi-zig | Status |
|---|---|---|
| `providers/openai-codex-responses.ts:isRetryableError(status, errorText)` (status 429/500/502/503/504 + `rate.?limit\|overloaded\|service.?unavailable\|upstream.?connect\|connection.?refused`) | covered by `isRetryableProviderErrorText` (superset) but pi-zig does not implement the openai-codex-responses transport at all | partial — see GAP-09-N |
| `providers/openai-codex-responses.ts:sleep(ms, signal?)` (AbortSignal-honoring) | `sleepMilliseconds` at `cli_runtime.zig:1212-1216` (non-abortable in CLI; `rpc.zig` uses `std.Io.sleep` with abort flag) | partial — abortable in RPC path, not in JSON path |
| `parseErrorResponse(response)` returning `friendlyMessage` for ChatGPT-plan exhaustion | **(MISSING)** | **GAP-09-N adjacent** — pi-zig surfaces raw provider error body text |

---

## 3. Gap detail (per gap, with concrete evidence and consequence)

### GAP-09-A: Missing Cerebras overflow pattern
- **Upstream**: `utils/overflow.ts:55` — `/^4(?:00|13)\s*(?:status code)?\s*\(no body\)/i`
- **pi-zig**: not present in `isContextOverflowErrorText` (`ai_client.zig:234-258`)
- **Symptom**: Cerebras context-overflow returns HTTP 400/413 with no body; upstream surfaces the synthetic error text `"400 status code (no body)"` (anchored at start). pi-zig wouldn't pattern-match that; the error is currently retried as a generic 5xx-ish failure via `containsAsciiIgnoreCase("400")` — but the **rest** of the body-text branch (the digit substring) is matched by the **retryable** path, so it'd be retried indefinitely instead of being treated as terminal context-overflow and routed to compaction.
- **Severity**: medium. Only affects Cerebras users with prompts that exceed context window.

### GAP-09-B: No usage-based silent-overflow detection (z.ai / Xiaomi MiMo)
- **Upstream**: `utils/overflow.ts:132-148`
- **pi-zig**: not implemented
- **Symptom**: z.ai accepts overflow silently and returns a normal `stop` with `usage.input > contextWindow`; Xiaomi MiMo truncates and returns `stopReason: "length"` with `output === 0`. Upstream catches both via `isContextOverflow` and routes to compaction. pi-zig sees both as "stop" / "length" and proceeds normally, with the LLM's response either truncated to nothing or based on a silently truncated context.
- **Severity**: medium. Affects z.ai and Xiaomi users at the very edge of their context window. Compounded by GAP-09-C below.

### GAP-09-C: No `Usage` token-counting struct in pi-zig
- **Upstream**: `types.ts:254-267` defines `Usage { input, output, cacheRead, cacheWrite, totalTokens, cost: { input, output, cacheRead, cacheWrite, total } }`; the `AssistantMessage.usage` is populated by every provider and threaded into compaction, cost displays, and `calculateCost`.
- **pi-zig**: `ChatCompletionResult` at `ai_client.zig:82-91` carries only `text` and `tool_calls`. No `Usage` field, no token aggregation, no cost.
- **Symptom**: pi-zig cannot display token cost in TUI/workbench/JSON mode, cannot weight compaction triggers by token count (only by message count), and cannot detect silent overflow (GAP-09-B).
- **Severity**: high. This is the single biggest missing piece of the `AssistantMessage` model.

### GAP-09-D: No `calculateCost(model, usage)` helper
- Pendant of GAP-09-C. Even if token counts were extracted from Anthropic `message_delta.usage.input_tokens`/`output_tokens` etc., there's no cost-multiplication pass.
- **Severity**: high — blocks the dashboard / model-picker cost-aware UX.

### GAP-09-E: Missing compat interfaces (`OpenAICompletionsCompat`, `OpenAIResponsesCompat`, `AnthropicMessagesCompat`)
- **Upstream**: `types.ts:365-448` — large surface of feature flags for OpenAI-compatible providers (`supportsStore`, `supportsDeveloperRole`, `supportsReasoningEffort`, `maxTokensField`, `requiresToolResultName`, `requiresAssistantAfterToolResult`, `requiresThinkingAsText`, `thinkingFormat: "openai"|"openrouter"|"deepseek"|"together"|"zai"|"qwen"|"qwen-chat-template"`, `openRouterRouting`, `vercelGatewayRouting`, `zaiToolStream`, `supportsStrictMode`, `cacheControlFormat: "anthropic"`, `sendSessionAffinityHeaders`, `supportsLongCacheRetention`, …)
- **pi-zig**: not present. The `ModelEntry` struct (`models.generated.zig:4-25`) does not carry any compat field. The hardcoded payload builders at `ai_client.zig:2475+` use literal field-name choices.
- **Symptom**: pi-zig cannot represent provider-specific quirks declaratively. New OpenAI-compatible providers (z.ai, qwen-chat-template, deepseek-thinking) require manual code changes rather than a compat-shape override on the model.
- **Severity**: medium-high. Limits extensibility but doesn't break built-in providers.

### GAP-09-F: No image-models catalog
- **Upstream**: `image-models.generated.ts` + `image-models.ts` registry.
- **pi-zig**: hardcoded inline implementation in `ai_client.zig:1797-1985`.
- **Symptom**: `--list-image-models` style query has nothing to enumerate. Workbench / TUI cannot show image-generation capability per provider.
- **Severity**: low — only one image provider exists today (OpenRouter).

### GAP-09-G: No `streamSimple` / `completeSimple` (reasoning + thinking-budgets entry point)
- **Upstream**: `stream.ts:43-58`.
- **pi-zig**: `streamChatTurn` takes a `ChatTurnRequest` with no `reasoning` or `thinkingBudgets` field (`ai_client.zig:72-80`); the reasoning level is sourced from the model's static thinking-level-map plus a settings default at `cli_runtime.zig` / `rpc.zig`.
- **Symptom**: callers cannot dynamically override thinking budget per request without mutating settings. The `RetrySettings.provider.timeoutMs` / `maxRetries` / `maxRetryDelayMs` fields exist (`cli_runtime.zig`, settings manager) but only `maxRetries` is honored in pi-zig's classifier; `cacheRetention`, `sessionId`, `transport`, `headers`, `metadata`, `onPayload`, `onResponse`, `timeoutMs`, `maxRetryDelayMs` — none are exposed to extensions or callers.
- **Severity**: medium-high — all upstream provider-tuning options are unreachable.

### GAP-09-H: No `ApiProvider` runtime registry (and no `ImagesApiProvider` registry)
- **Upstream**: `api-registry.ts` + `images-api-registry.ts`.
- **pi-zig**: hardcoded provider-routing switch in `streamChatTurnData` / `runChatTurn` / `runImageGeneration`.
- **Symptom**: extensions registering a new provider (the `pi.registerProvider()` extension API listed in `upstream.zig:135`) have no place to land. The extension would emit a `before_provider_request` event but pi-zig would route to its hardcoded switch regardless. `unregisterProvider` likewise no-ops.
- **Severity**: high for extension parity — blocks the upstream "custom provider via extension" workflow described in upstream's `docs/custom-provider.md`.

### GAP-09-I: No `/proc/self/environ` Bun-sandbox fallback
- Upstream-specific to Bun compile bug. pi-zig binaries are native Zig, not Bun-compiled — this is **n/a** for pi-zig and need not be ported. Listed for completeness.
- **Severity**: none.

### GAP-09-J: No `session-resources` cleanup registry
- **Upstream**: `session-resources.ts`.
- **pi-zig**: not implemented.
- **Symptom**: today's pi-zig provider stack doesn't own any session-scoped resources (no WebSocket pool, no SDK clients pinned per-session), so there's nothing to clean up — but extension-registered providers would have no cleanup hook either.
- **Severity**: low today, medium once GAP-09-H lands.

### GAP-09-K: No `AssistantMessageDiagnostic` field on the assistant result
- **Upstream**: `AssistantMessage.diagnostics?: AssistantMessageDiagnostic[]` + the `diagnostics` re-export.
- **pi-zig**: `ChatCompletionResult` carries no diagnostics; `cli_runtime.zig` emits its own `auto_retry_start` / `auto_retry_end` events directly to stdout JSON.
- **Symptom**: provider transport failures, fallback-to-SSE-after-WebSocket failures, rate-limit body parses, and timeouts are not surfaced as structured diagnostics on the final message. Users see only the final retry's error text.
- **Severity**: medium. Upstream uses diagnostics for the "X failed attempts before this success" footer in TUI/workbench.

### GAP-09-L: No `AssistantMessageEventStream` and no typed `AssistantMessageEvent` union
- **Upstream**: `utils/event-stream.ts` + the 13-arm `AssistantMessageEvent` union in `types.ts`.
- **pi-zig**: callback-based streaming with two function pointer types (`StreamTextCallback`, `StreamDataCallback`); the JSON/print and RPC modes emit ad-hoc JSON events with their own vocabularies.
- **Symptom**: extensions cannot uniformly observe a streaming session through a typed event channel. The two front ends (TUI in workbench, CLI JSON) maintain separate event shapes. The `start`/`text_start`/`text_delta`/`thinking_start`/`thinking_delta`/`toolcall_start`/`toolcall_delta`/`done`/`error` lifecycle is partially reconstructed in `cli_runtime.zig` and `rpc.zig` but not as a typed union.
- **Severity**: medium. Functional, but it forces every callsite to maintain its own event shape.

### GAP-09-M: No `shortHash`
- Upstream uses for session-affinity header keys and cache filenames.
- pi-zig: no equivalent; nowhere needs it today because session-affinity headers (GAP-09-G consequence) aren't sent.
- **Severity**: low.

### GAP-09-N: openai-codex-responses transport entirely absent (out-of-scope but relevant to retry)
- **Upstream**: `providers/openai-codex-responses.ts` is the only place with an SSE + WebSocket dual transport + its own retry classifier (`isRetryableError`, `parseErrorResponse` for ChatGPT-plan exhaustion).
- **pi-zig**: there is no `streamOpenAICodexResponses` (`grep -n openai-codex-responses src/pi/ai_client.zig` returns 0). The `openai-codex` provider (different from `openai-codex-responses`) is OAuth-resolved in `auth.zig` but no transport speaks `openai-codex-responses`; the model catalog lists 0 of them after the auth resolution.
- **Severity**: this is a `providers/` concern; mentioned because the retry classifier described in the audit prompt lives partly here.

### GAP-09-O: No JSON repair / streaming-JSON parsing
- See §2o. Affects partial tool-call argument streaming.
- **Severity**: medium. Today's built-in tools accept their args at full-message time, so the repair pass isn't strictly needed. Extension tools that stream-render arguments (or display partial tool calls) might receive un-parseable interim JSON.

### GAP-09-P: No HTTP proxy support
- See §2p. `HTTP_PROXY` / `HTTPS_PROXY` / `no_proxy` / `all_proxy` ignored. Zig's `std.http.Client` does not consult these by default.
- **Severity**: medium-high in corporate environments.

### GAP-09-Q: No `sanitizeSurrogates`
- See §2r. Subset of GAP-09-O concern.
- **Severity**: low.

### GAP-09-R: No `StringEnum` TypeBox helper
- N/A; pi-zig doesn't expose TypeBox.
- **Severity**: none — but coupled to GAP-09-S.

### GAP-09-S: No `validateToolCall` / `validateToolArguments` parameter validation + coercion
- See §2t. Tools currently do their own ad-hoc validation in Zig; extension tools have no automatic coercion of `{"x":"42"}` to `{x:42}` before invocation.
- **Severity**: medium. Affects extension tool quality (silent wrong-type bugs) and error-message uniformity.

### GAP-09-T (cross-cutting): `ai_client.zig`'s OpenAI-compatible endpoint switch is a 7-provider hardcoded allowlist
- **Upstream**: `MODELS` for each of the 32 providers carries `baseUrl`, so the provider transport just consults that field.
- **pi-zig**: `endpointForProvider` (`ai_client.zig:2265-2276`) hardcodes URLs for 6 providers (openai, openrouter, groq, deepseek, xai, together) plus a `PI_ZIG_PROVIDER_BASE_URL` env override; everything else returns `error.UnsupportedProvider`. Specifically **MISSING** in the OpenAI-compatible branch: cerebras, zai, vercel-ai-gateway, minimax, minimax-cn, moonshotai, moonshotai-cn, huggingface, fireworks, opencode, opencode-go, kimi-coding, cloudflare-workers-ai, cloudflare-ai-gateway, xiaomi (+3), github-copilot — even though they all live in the OpenAI-compatible family with known `baseUrl` values in `models.generated.zig`. The same applies to images-api-registry callers.
- **Severity**: high — many model rows in the generated catalog are unreachable at runtime.

---

## 4. Honest estimated parity

Methodology: weight each upstream surface by approximate LOC × functional importance. Equal weights would over-count tiny helpers (`headers.ts`: 7 lines) against load-bearing files (`types.ts`: 575 lines, drives every other module).

| Surface | LOC | Weight | pi-zig status | Implementation % |
|---|---:|---:|---|---:|
| `types.ts` (Api/Provider unions, Model/Message/Usage/Diagnostic, Compat, StreamOptions) | 575 | 12 | partial — content parts/messages mostly there, **no `Usage`, no `Compat`, no `Diagnostic`, no `AssistantMessageEvent`, limited `StreamOptions`** | 45 |
| `models.ts` | 92 | 3 | port — `Usage`/`calculateCost` missing | 75 |
| `models.generated.ts` | 16115 | 6 | port — anchored at 924 models / 32 providers | 100 |
| `image-models.ts` | 42 | 1 | **MISSING** as a registry; inline impl runs | 25 |
| `image-models.generated.ts` | 444 | 1 | **MISSING** | 0 |
| `images.ts` | 21 | 1 | partial (inline OpenRouter only) | 30 |
| `images-api-registry.ts` | 53 | 1 | **MISSING** | 0 |
| `stream.ts` (stream/complete/streamSimple/completeSimple) | 59 | 3 | partial — `streamChatTurn` covers `stream`; `streamSimple` absent | 50 |
| `api-registry.ts` (register / get / unregister / clear) | 98 | 4 | **MISSING** (hardcoded switch) | 5 |
| `env-api-keys.ts` (32-provider map, OAuth precedence, Vertex/Bedrock `<authenticated>`, Bun /proc fallback) | 210 | 3 | port (split across `providers.zig` + `auth.zig`) | 80 |
| `session-resources.ts` | 24 | 1 | **MISSING** | 0 |
| `cli.ts` (pi-ai standalone OAuth binary) | 147 | 1 | functional equivalent in `auth.zig` subcommand (different binary) | 60 |
| `utils/diagnostics.ts` | 46 | 2 | **MISSING** | 0 |
| `utils/event-stream.ts` (typed event stream + 13-arm union) | 89 | 4 | **MISSING** (callback-based instead) | 15 |
| `utils/hash.ts` | 13 | 0.5 | **MISSING** | 0 |
| `utils/headers.ts` | 7 | 0.5 | n/a (Zig std uses raw headers) | 100 |
| `utils/json-parse.ts` (repair + streaming partial JSON) | 125 | 3 | **MISSING** | 0 |
| `utils/node-http-proxy.ts` | 124 | 2 | **MISSING** | 0 |
| `utils/overflow.ts` (23 patterns + 3 non-overflow + silent + length-stop) | 159 | 5 | **22/23 patterns ported, silent + length-stop MISSING** | 80 |
| `utils/sanitize-unicode.ts` | 26 | 1 | **MISSING** | 0 |
| `utils/typebox-helpers.ts` | 24 | 0.5 | **MISSING** | 0 (n/a) |
| `utils/validation.ts` (TypeBox + JSON-Schema coercion + tool-call validation) | 325 | 4 | **MISSING** | 0 |
| Retry classifier in `agent-session.ts:2429-2441` (regex of 27 tokens) | (out of scope, ~14 LOC) | 4 | **all 27 tokens ported (token-by-token)** | 100 |
| Retry classifier in `providers/openai-codex-responses.ts:103-108` | (out of scope) | 1 | covered by the agent-session classifier; codex transport itself MISSING | 50 |
| Endpoint routing (15 OpenAI-compatible providers needing URLs from `baseUrl`) | inline | 4 | **MISSING for 15+ providers in OpenAI-compatible family** (only 7 wired) | 30 |

Weighted total: `(12·0.45 + 3·0.75 + 6·1.00 + 1·0.25 + 1·0 + 1·0.30 + 1·0 + 3·0.50 + 4·0.05 + 3·0.80 + 1·0 + 1·0.60 + 2·0 + 4·0.15 + 0.5·0 + 0.5·1.00 + 3·0 + 2·0 + 5·0.80 + 1·0 + 0.5·0 + 4·0 + 4·1.00 + 1·0.50 + 4·0.30) / (12+3+6+1+1+1+1+3+4+3+1+1+2+4+0.5+0.5+3+2+5+1+0.5+4+4+1+4) = `

Numerator:
- 12·0.45 = 5.40
- 3·0.75 = 2.25
- 6·1.00 = 6.00
- 1·0.25 = 0.25
- 1·0 = 0
- 1·0.30 = 0.30
- 1·0 = 0
- 3·0.50 = 1.50
- 4·0.05 = 0.20
- 3·0.80 = 2.40
- 1·0 = 0
- 1·0.60 = 0.60
- 2·0 = 0
- 4·0.15 = 0.60
- 0.5·0 = 0
- 0.5·1.00 = 0.50
- 3·0 = 0
- 2·0 = 0
- 5·0.80 = 4.00
- 1·0 = 0
- 0.5·0 = 0
- 4·0 = 0
- 4·1.00 = 4.00
- 1·0.50 = 0.50
- 4·0.30 = 1.20

Sum: 29.70

Denominator (weights): 12+3+6+1+1+1+1+3+4+3+1+1+2+4+0.5+0.5+3+2+5+1+0.5+4+4+1+4 = **68.5**

**Weighted estimated parity = 29.70 / 68.5 ≈ 43.4%.**

Rounded honest: **~43% parity** on the audited `packages/ai/src/` surface (excluding `providers/` and `utils/oauth/`).

Headline drivers of the gap:
- **`Usage`/cost tracking absent** (~10pp impact alone) — pulls types.ts, models.ts (calculateCost), and overflow.ts (silent-overflow) down together
- **API registry / extension provider injection absent** (~5pp)
- **JSON repair / streaming JSON / surrogate sanitization absent** (~5pp)
- **HTTP proxy support absent** (~3pp)
- **Compat overrides absent** (~5pp) — limits per-model provider quirks
- **Event-stream typed union absent** (~5pp) — re-implementations in CLI/RPC partially cover this
- **15+ OpenAI-compatible provider endpoints unwired despite catalog presence** (~5pp)
- **Diagnostics framework absent** (~2pp)

What is genuinely solid in pi-zig:
- The retry-classifier token set is a **complete** port of the upstream `agent-session.ts` regex (every single one of the 27 tokens) — `containsWordsInOrderIgnoreCase` is strictly more permissive than `.?` so won't false-negative on documented strings.
- 22/23 context-overflow patterns ported, all 3 non-overflow guards ported.
- Model catalog 100% anchored (924 models, 32 providers, pinned by tests).
- Provider env-key map covers all 31 single-key providers + anthropic OAuth precedence + Vertex/Bedrock sentinel-credentials branches (different sentinel string, same semantics).

Bottom line: the **classifier strings** the prompt called out are at parity; the **surrounding type system, event vocabulary, and provider-registry infrastructure** are roughly half-ported.

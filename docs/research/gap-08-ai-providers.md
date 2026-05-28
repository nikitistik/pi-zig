# Gap 08 — AI Providers (read-only audit)

**Branch:** `codex/pi-zig-progress`
**Scope:** Compare upstream `earendil-works/pi` provider files under
`packages/ai/src/providers/` and OAuth utilities under
`packages/ai/src/utils/oauth/` against the pi-zig implementation in
`src/pi/ai_client.zig`, `src/pi/providers.zig`, `src/pi/auth.zig`,
`src/pi/models.zig`.
**Mode:** Read-only. No code changes.

---

## 0. File map (upstream, lines)

| Upstream file | Lines | Surface |
| --- | --- | --- |
| `providers/anthropic.ts` | 1212 | `anthropic-messages` stream/runtime |
| `providers/openai-completions.ts` | 1161 | `openai-completions` (multi-provider compat) |
| `providers/openai-responses.ts` | 312 | `openai-responses` (OpenAI Responses API) |
| `providers/openai-responses-shared.ts` | 551 | shared message/tool/stream helpers |
| `providers/openai-codex-responses.ts` | 1375 | ChatGPT Codex Responses (SSE + WS) |
| `providers/azure-openai-responses.ts` | 298 | Azure OpenAI Responses |
| `providers/google.ts` | 501 | Google Generative AI |
| `providers/google-shared.ts` | 350 | shared Google/Vertex helpers |
| `providers/google-vertex.ts` | 568 | Google Vertex (ADC + key) |
| `providers/mistral.ts` | 634 | Mistral conversations |
| `providers/amazon-bedrock.ts` | 953 | AWS Bedrock ConverseStream |
| `providers/cloudflare.ts` | 35 | Cloudflare base URL helper |
| `providers/github-copilot-headers.ts` | 37 | Copilot dynamic headers |
| `providers/openai-prompt-cache.ts` | 8 | prompt cache key clamp |
| `providers/simple-options.ts` | 52 | StreamSimple base options |
| `providers/transform-messages.ts` | 220 | cross-provider message transform |
| `providers/register-builtins.ts` | 406 | lazy provider registry |
| `providers/faux.ts` | 499 | test/fake provider |
| `providers/images/openrouter.ts` | 188 | OpenRouter images |
| `providers/images/register-builtins.ts` | 56 | image provider registry |
| `utils/oauth/anthropic.ts` | 402 | Anthropic OAuth (PKCE + callback server) |
| `utils/oauth/github-copilot.ts` | 345 | GitHub Copilot OAuth (device-code) |
| `utils/oauth/openai-codex.ts` | 458 | ChatGPT Codex OAuth (PKCE + callback) |
| `utils/oauth/device-code.ts` | 80 | RFC 8628 polling helper |
| `utils/oauth/oauth-page.ts` | 109 | HTML success/error pages |
| `utils/oauth/pkce.ts` | 34 | PKCE verifier/challenge |
| `utils/oauth/types.ts` | 79 | shared types |
| `utils/oauth/index.ts` | 153 | provider registry + `getOAuthApiKey` |

`pi-zig` consolidates almost every provider into a single
`src/pi/ai_client.zig` (5800+ lines): one file owns endpoint resolution,
payload serialization, response parsing, SSE/event-stream framing, and
provider authentication. `src/pi/providers.zig` is only an env-key map. OAuth
refresh + Vertex ADC sit in `src/pi/auth.zig`; interactive OAuth login is
entirely absent.

---

## 1. Per-provider inventory

### 1.1 `anthropic-messages` — Anthropic Messages API
Upstream: `providers/anthropic.ts`.

- **Endpoint(s):** SDK-routed (`@anthropic-ai/sdk`). Effective base = `model.baseUrl`,
  defaulting to `https://api.anthropic.com`. Path = `/v1/messages`.
  Cloudflare AI gateway uses `https://gateway.ai.cloudflare.com/v1/{ACC}/{GW}/anthropic`.
- **Request body shape (`buildParams`, lines 889-992):**
  `model`, `messages`, `max_tokens`, `stream:true`, optional `system` (single
  text block, or `[{type:"text",text:"You are Claude Code…"}, …]` for OAuth),
  optional `temperature`, optional `tools[]`, optional `thinking`
  (`adaptive`/`enabled`/`disabled`), optional `output_config.effort`,
  `tool_choice`, `metadata.user_id`. Cache control (`cache_control:
  {type:"ephemeral", ttl?: "1h"}`) is applied to last system block, last user
  message, and last tool definition.
- **Response parsing:** SDK `RawMessageStreamEvent` decoded in
  `iterateAnthropicEvents`. Custom SSE decoder (lines 256-445) handles
  `message_start`, `content_block_start/delta/stop`, `message_delta`,
  `message_stop`, `error`.
- **Streaming format:** SSE with named events (`event:`/`data:`). Custom
  decoder is reimplemented because the SDK's iterator does not surface
  proxy errors. JSON repair via `parseStreamingJson` for partial tool input.
- **Tool-call format:** Anthropic native `tool_use` blocks with `id`, `name`,
  `input` (parsed JSON). Tools sent as `{name, description, input_schema,
  eager_input_streaming?, cache_control?}`. OAuth path remaps tool names to
  Claude-Code-canonical casing (`Read`, `Bash`, etc., 16 entries, lines
  75-93).
- **Image input format:** `{type:"image", source:{type:"base64",
  media_type:"image/(jpeg|png|gif|webp)", data}}` blocks.
- **Auth headers (`createClient`, lines 779-887):**
  - API key: `x-api-key: <key>`, plus default `accept`, `anthropic-version`.
  - OAuth (`sk-ant-oat…`): `Authorization: Bearer <key>`,
    `anthropic-beta: claude-code-20250219,oauth-2025-04-20,…`,
    `user-agent: claude-cli/2.1.75`, `x-app: cli`.
  - Cloudflare gateway: `cf-aig-authorization: Bearer <key>`, no
    `x-api-key`/`Authorization`.
  - GitHub Copilot: `authToken: <copilot-token>` plus dynamic Copilot headers
    (`X-Initiator`, `Openai-Intent`, optional `Copilot-Vision-Request`).
- **Provider-specific quirks:**
  - `interleaved-thinking-2025-05-14` and
    `fine-grained-tool-streaming-2025-05-14` beta headers (model gated).
  - `eager_input_streaming: true` per-tool flag for providers that support it
    (default true; Fireworks/Cloudflare-Anthropic opt out via compat).
  - `redacted_thinking` opaque payload round-tripped on assistant replays.
  - Aborted thinking blocks (signature missing) are downgraded to plain text
    on replay to avoid API rejection.
  - Tool call IDs sanitized to `[a-zA-Z0-9_-]` and capped at 64 chars.
  - Consecutive `toolResult` messages merged into one `user` turn with
    multiple `tool_result` content blocks (z.ai requirement).
  - `cache_control.ttl="1h"` when `cacheRetention="long"` and model supports
    it; `x-session-affinity` header for Fireworks/Cloudflare gateway.

### 1.2 `openai-completions` — OpenAI Chat Completions + 20-plus compat providers
Upstream: `providers/openai-completions.ts`.

- **Endpoint(s):** SDK-routed (`openai`). Effective URL =
  `<model.baseUrl>/chat/completions`. Cloudflare workers/gateway override
  via `resolveCloudflareBaseUrl`.
- **Request body (`buildParams`, lines 503-624):**
  `model`, `messages`, `stream:true`, `prompt_cache_key?`,
  `prompt_cache_retention?` (`"24h"` for long retention),
  `stream_options.include_usage?`, `store?`, `max_tokens` /
  `max_completion_tokens` (compat-gated), `temperature?`, `tools[]?`,
  `tool_choice?`, `reasoning_effort?` / `enable_thinking?` /
  `chat_template_kwargs?` / `thinking?` / `reasoning?` (per
  `compat.thinkingFormat`: `openai`/`zai`/`qwen`/`qwen-chat-template`/
  `deepseek`/`openrouter`/`together`), `provider?` (OpenRouter routing),
  `providerOptions.gateway?` (Vercel AI Gateway).
- **Response parsing:** SDK `ChatCompletionChunk`. Streams `choices[0].delta`
  for text (`delta.content`), reasoning (`reasoning_content`/`reasoning`/
  `reasoning_text`), tool calls (`delta.tool_calls`). Final usage from
  `chunk.usage` or `choice.usage` (Moonshot quirk). Reasoning encrypted
  signatures via `reasoning_details[].type === "reasoning.encrypted"`
  threaded into matching tool calls.
- **Streaming format:** SSE, OpenAI shape, terminated by `data: [DONE]`.
- **Tool-call format:** OpenAI function tools `{type:"function",
  function:{name, description, parameters, strict?}}`. Streaming reassembly
  uses both `tool_calls[].index` and `tool_calls[].id` so out-of-order /
  re-issued chunks merge correctly.
- **Image input format:** `image_url:{url:"data:<mime>;base64,<data>"}`.
- **Auth headers:** `Authorization: Bearer <key>`; Cloudflare gateway sends
  `cf-aig-authorization: Bearer <key>` and nulls `Authorization`. Optional
  session-affinity headers (`session_id`, `x-client-request-id`,
  `x-session-affinity`). GitHub Copilot extras: `X-Initiator`,
  `Openai-Intent`, `Copilot-Vision-Request` when images present.
- **Provider-specific quirks (`detectCompat`, 1070-1129):**
  - `supportsStore`, `supportsDeveloperRole`, `supportsReasoningEffort`,
    `supportsUsageInStreaming`, `maxTokensField`, `requiresToolResultName`,
    `requiresAssistantAfterToolResult`, `requiresThinkingAsText`,
    `requiresReasoningContentOnAssistantMessages`, `thinkingFormat`,
    `openRouterRouting`, `vercelGatewayRouting`, `zaiToolStream`,
    `supportsStrictMode`, `cacheControlFormat`,
    `sendSessionAffinityHeaders`, `supportsLongCacheRetention`.
  - Cerebras / x.ai / Together / chutes.ai / DeepSeek / z.ai / Moonshot /
    Cloudflare workers AI / Cloudflare AI gateway use non-standard fields.
  - DeepSeek: `thinking:{type:"enabled"|"disabled"}` plus
    `reasoning_content` on assistant messages.
  - z.ai: `enable_thinking`, `tool_stream`.
  - Qwen: `enable_thinking` or `chat_template_kwargs.enable_thinking +
    preserve_thinking`.
  - OpenRouter: `reasoning:{effort}`, `provider:{…}`.
  - Together: `reasoning:{enabled}` plus optional `reasoning_effort`.
  - Anthropic-via-OpenRouter: `cache_control: ephemeral` annotations
    propagated to system, last user, last tool.
  - Tool-call ID normalization: pipe-separated IDs (`call|fc_xxx`) get split
    and resanitized to 40 chars for OpenAI/Codex/opencode interop.
  - Some endpoints require an `assistant` bridge message after `tool` role
    (LiteLLM proxy quirk).
  - Some endpoints reject empty assistant content; aborted assistant
    messages are dropped.

### 1.3 `openai-responses` — OpenAI Responses API
Upstream: `providers/openai-responses.ts` (+ shared
`openai-responses-shared.ts`).

- **Endpoint:** SDK-routed (`openai`). `client.responses.create(...)`. Path =
  `/v1/responses` against `model.baseUrl`.
- **Request body (`buildParams`, lines 235-283):**
  `model`, `input` (`ResponseInput[]`: `{role,content:[{type:"input_text"|
  "input_image",text|image_url|detail}]}`, `{type:"message",role:"assistant",
  content:[{type:"output_text",...}]}`, `{type:"function_call",call_id,id,
  name,arguments}`, `{type:"function_call_output",call_id,output}`,
  `ResponseReasoningItem`), `stream:true`, `prompt_cache_key?`,
  `prompt_cache_retention?` ("24h"), `store:false`, `max_output_tokens?`,
  `temperature?`, `service_tier?`, `tools[]?`,
  `reasoning:{effort,summary}?`, `include:["reasoning.encrypted_content"]`.
- **Response parsing:** SDK `ResponseStreamEvent` consumed in
  `processResponsesStream` (shared, lines 283-530). Events:
  `response.created`, `response.output_item.added`,
  `response.reasoning_summary_part.added/.delta/.done`,
  `response.reasoning_text.delta`, `response.content_part.added`,
  `response.output_text.delta`, `response.refusal.delta`,
  `response.function_call_arguments.delta/.done`,
  `response.output_item.done`, `response.completed`, `response.failed`,
  `error`. Service-tier multiplier applied to final usage (`flex`=0.5,
  `priority`=2, gpt-5.5=2.5).
- **Streaming format:** SSE; SDK decodes JSON event-stream.
- **Tool-call format:** Responses `function_call` items with `call_id` and
  `id`. pi joins them into `<call_id>|<item_id>` and round-trips both.
  Foreign tool calls (different provider/api) get `fc_<shortHash>` synthetic
  item IDs.
- **Image input:** `input_image{detail:"auto", image_url:"data:..."}`.
- **Auth headers:** `Authorization: Bearer <key>`. Optional
  `session_id`/`x-client-request-id` (compat gated). Cloudflare gateway
  prefix.
- **Quirks:**
  - Thinking signature is the entire `ResponseReasoningItem` JSON object
    (lines 173, 445) — round-tripped verbatim.
  - Text signature is a `TextSignatureV1` JSON `{v:1, id, phase?}` stamped on
    assistant output to preserve OpenAI pairing of `rs_xxx`/`msg_xxx`.
  - Assistant message replay uses `id:undefined` for foreign function-call
    items to skip pairing validation.

### 1.4 `openai-codex-responses` — ChatGPT Codex Responses (subscription)
Upstream: `providers/openai-codex-responses.ts`.

- **Endpoint:** `https://chatgpt.com/backend-api/codex/responses` (default).
  WebSocket variant: `wss://chatgpt.com/backend-api/codex/responses`.
- **Request body (`buildRequestBody`, lines 366-414):**
  `model`, `store:false`, `stream:true`, `instructions` (system prompt or
  "You are a helpful assistant"), `input` (Responses-shaped, no system
  message included), `text:{verbosity:"low"|"medium"|"high"}`,
  `include:["reasoning.encrypted_content"]`, `prompt_cache_key`,
  `tool_choice:"auto"`, `parallel_tool_calls:true`, optional `temperature`,
  `service_tier`, `tools[]` (`strict:null`), `reasoning:{effort, summary}`.
- **Response parsing:** Custom SSE parser (`parseSSE`, lines 559-605) reads
  `data:` lines from `\n\n`-delimited frames. WebSocket variant
  (`parseWebSocket`, lines 1020-1117) yields the same event JSON objects.
  Both feed `mapCodexEvents` which: normalizes `response.done`/
  `response.incomplete` → `response.completed`; throws
  `CodexApiError` on `error` or `response.failed`; throws
  `CodexProtocolError` on JSON parse failure. Events feed into the same
  shared `processResponsesStream` as `openai-responses`.
- **Streaming format:** SSE primary, WebSocket-with-cached-context optional
  transport (`OpenAI-Beta: responses_websockets=2026-02-06`). The
  WebSocket variant maintains a per-session connection cache with idle
  timeout (5 min) and uses `previous_response_id` to send delta-only inputs
  on follow-up turns.
- **Tool-call format:** Same as Responses (joined `call_id|item_id`).
- **Image input:** Same as Responses (`input_image`).
- **Auth headers (`buildSSEHeaders`/`buildWebSocketHeaders`, lines
  1321-1375):**
  - `Authorization: Bearer <jwt-access-token>`
  - `chatgpt-account-id: <accountId>` (extracted from JWT claim
    `https://api.openai.com/auth.chatgpt_account_id`)
  - `originator: pi`
  - `User-Agent: pi (<os.platform> <os.release>; <os.arch>)` (Node) or
    `pi (browser)`
  - `OpenAI-Beta: responses=experimental` (SSE) or
    `responses_websockets=2026-02-06` (WebSocket)
  - optional `session_id`, `x-client-request-id`
- **Provider-specific quirks:**
  - JWT account-id decoding: `extractAccountId` (line 1301) base64-decodes
    the middle JWT segment and looks up `https://api.openai.com/auth.
    chatgpt_account_id`.
  - Retries with exponential backoff for 429/5xx, honors `retry-after-ms`
    and `retry-after` headers (line 261-280); usage-limit error is
    surfaced with a friendly "Try again in ~N min" message including
    `plan_type` (`parseErrorResponse`, 1270-1295).
  - WebSocket cached-context flow (`buildCachedWebSocketRequestBody`):
    if the request body differs from the cached baseline only by appended
    input items, it sends `previous_response_id` + the appended delta only
    (lines 1119-1171).
  - WebSocket session cache (`websocketSessionCache`, line 654) plus debug
    stats (`OpenAICodexWebSocketDebugStats`, 637-651) tracking
    cached-context hits, full-context fallbacks, WebSocket failures, SSE
    fallbacks.
  - Transport options: `"sse"`, `"websocket-cached"`, `"auto"`.
  - On WebSocket failure pre-event, falls back to SSE for the same request;
    on failure after first event, propagates the error (no double-stream).
  - Code 1009 (message too big) close error mapped to a clear "message too
    big" reason.

### 1.5 `azure-openai-responses` — Azure OpenAI Responses
Upstream: `providers/azure-openai-responses.ts`.

- **Endpoint:** `AzureOpenAI` SDK. Effective URL =
  `<base>/openai/v1/deployments/<deployment>/responses?api-version=<ver>`.
  `base` resolved from `azureBaseUrl` / `AZURE_OPENAI_BASE_URL` /
  `https://<azureResourceName>.openai.azure.com/openai/v1` /
  `model.baseUrl`. `api-version` defaults to `v1`.
- **Request body:** Same Responses shape as `openai-responses`, plus
  `prompt_cache_key`. Deployment name takes the `model` slot in the URL;
  resolution map = `AZURE_OPENAI_DEPLOYMENT_NAME_MAP` (`<id>=<deployment>,…`).
- **Response parsing:** Reuses `processResponsesStream`.
- **Streaming format:** SSE via SDK.
- **Tool-call / image / auth:** Same as Responses but with
  `api-key: <key>` (Azure header).
- **Quirks:** Auto-prepends `/openai/v1` to base URLs that are bare Azure
  hostnames; `AZURE_OPENAI_API_VERSION` env override; deployment name map
  parsing (`parseDeploymentNameMap`).

### 1.6 `google-generative-ai` — Gemini (developer API)
Upstream: `providers/google.ts` + `google-shared.ts`.

- **Endpoint:** SDK-routed (`@google/genai` with `vertexai:false`).
  Base = `model.baseUrl` (overridden in tests) else
  `https://generativelanguage.googleapis.com/v1beta`.
  Path = `/models/<id>:streamGenerateContent`.
- **Request body (`buildParams`, lines 336-394):**
  `{model, contents:[…], config:{temperature?, maxOutputTokens?,
  systemInstruction?, tools?, toolConfig?, thinkingConfig?, abortSignal?}}`.
- **Response parsing:** SDK iterator. Pulls `candidates[0].content.parts[]`,
  flipping between text/thinking blocks based on `part.thought === true`.
  Function calls captured with `id` (synthetic counter if missing or
  duplicate) and `thoughtSignature` (TYPE_BYTES base64). Usage from
  `usageMetadata.{promptTokenCount, candidatesTokenCount, thoughtsTokenCount,
  cachedContentTokenCount, totalTokenCount}`.
- **Streaming format:** SSE (`alt=sse`).
- **Tool-call format:** `functionDeclarations[{name, description,
  parametersJsonSchema|parameters}]`. The result side uses
  `functionResponse:{name, response:{output|error}, parts?, id?}`. Gemini-3+
  supports multimodal `parts` inside `functionResponse`; earlier models need
  a separate user image turn.
- **Image input:** `inlineData:{mimeType, data}` parts.
- **Auth headers:** SDK adds `x-goog-api-key: <key>`. Custom headers
  forwarded via `httpOptions.headers`.
- **Quirks (`google-shared.ts`):**
  - `thoughtSignature` retained across deltas (`retainThoughtSignature`,
    line 46) — never overwritten with undefined within the same block.
  - Signatures are validated as base64 before being replayed; only retained
    when same provider+model.
  - Cross-model thinking is replayed as plain text (no `thought:true`).
  - Tools allowed to use `parametersJsonSchema` (full JSON Schema) or legacy
    `parameters` (OpenAPI 3.03) when called for Claude-via-Cloud-Code-Assist.
  - Gemini-3 thinking is configured by `thinkingLevel:
    UNSPECIFIED|MINIMAL|LOW|MEDIUM|HIGH`; older Gemini 2.5 uses
    `thinkingBudget` integers.
  - Models containing `claude-`/`gpt-oss-` get tool call IDs sanitized
    (Cloud Code Assist quirk).
  - `convertMessages` collapses adjacent toolResult turns into a single
    `user` turn per Cloud Code Assist requirement.

### 1.7 `google-vertex` — Vertex AI
Upstream: `providers/google-vertex.ts`.

- **Endpoint:** SDK-routed (`@google/genai` with `vertexai:true`,
  `apiVersion:"v1"`). With API key: same shared path. With project +
  location: `https://<location>-aiplatform.googleapis.com/v1/projects/
  <project>/locations/<location>/publishers/google/models/<id>:
  streamGenerateContent`.
- **Request body:** Identical to `google-generative-ai` (shared
  `convertMessages` + `convertTools`).
- **Response parsing:** Identical.
- **Streaming format:** SSE.
- **Tool-call format:** Identical to Google (`functionDeclarations`).
- **Image input:** Identical (`inlineData`).
- **Auth headers:**
  - With Vertex API key (`GOOGLE_CLOUD_API_KEY`) — SDK route via API key.
  - With ADC — SDK uses `GoogleAuth` library; pi-zig has to re-implement
    this (see §4).
  - `gcp-vertex-credentials` is a placeholder marker meaning "use ADC".
- **Quirks:**
  - `THINKING_LEVEL_MAP` translates pi-internal `MINIMAL/LOW/MEDIUM/HIGH`
    into the SDK enum (`ThinkingLevel` consts).
  - `baseUrlIncludesApiVersion` skips appending `/v1` to override base URLs.
  - `xhigh` not supported by Vertex; clamped to `high`.

### 1.8 `mistral-conversations` — Mistral
Upstream: `providers/mistral.ts`.

- **Endpoint:** SDK-routed (`@mistralai/mistralai`). `mistral.chat.stream`.
  `serverURL = model.baseUrl`. Effective path = `<base>/v1/chat/completions`.
- **Request body (`buildChatPayload`, lines 241-268):**
  `{model, stream:true, messages, tools?, temperature?, maxTokens?,
  toolChoice?, promptMode?, reasoningEffort?}`. System prompt prepended.
- **Response parsing:** SDK `CompletionEvent` stream. Handles text content
  arrays (`type:"text"|"thinking"`), tool-call assembly across chunks,
  thinking blocks with nested text parts, finish reasons mapping
  (`stop|length|model_length|tool_calls|error`).
- **Streaming format:** SSE (SDK abstracted).
- **Tool-call format:** Function tools with `strict:false`. IDs forced to 9
  alphanumeric chars (`MISTRAL_TOOL_CALL_ID_LENGTH = 9`), conflicts
  resolved by hashing with a counter suffix.
- **Image input:** `image_url:"data:<mime>;base64,<data>"`.
- **Auth headers:** `Authorization: Bearer <key>` plus optional
  `x-affinity: <sessionId>` for KV-cache reuse.
- **Quirks:**
  - Reasoning effort accepted only by `mistral-small-2603` /
    `mistral-small-latest` / `mistral-medium-3.5`; everything else uses
    `promptMode:"reasoning"`.
  - Symbol keys in tool parameters stripped before payload.
  - Tool result text formatted with `[tool error]` prefix on errors;
    placeholder for image-only / no-output results.
  - Retry strategy disabled (`retries:{strategy:"none"}`).

### 1.9 `bedrock-converse-stream` — AWS Bedrock ConverseStream
Upstream: `providers/amazon-bedrock.ts`.

- **Endpoint:** AWS SDK (`@aws-sdk/client-bedrock-runtime`).
  Standard endpoint = `https://bedrock-runtime.<region>.amazonaws.com`
  (FIPS variant supported). Path = `/model/<modelId>/converse-stream`.
- **Request body (line 187-198):**
  `{modelId, messages, system, inferenceConfig:{maxTokens?, temperature?},
  toolConfig?, additionalModelRequestFields?, requestMetadata?}`.
- **Response parsing:** SDK event stream items: `messageStart`,
  `contentBlockStart` (tool use), `contentBlockDelta` (text /
  `reasoningContent.text` + `signature` / `toolUse.input` chunks),
  `contentBlockStop`, `messageStop` (stop reason), `metadata` (usage), plus
  exception variants.
- **Streaming format:** AWS event-stream framing (binary headers + JSON
  payload).
- **Tool-call format:** `toolConfig.tools[{toolSpec:{name, description,
  inputSchema:{json:<schema>}}}]`, optional `toolChoice:{auto|any|tool}`.
- **Image input:** `image:{source:{bytes:<Uint8Array>}, format:JPEG|PNG|GIF|
  WEBP}` (base64 decoded before sending).
- **Auth headers:** Two paths:
  - Bearer token (`AWS_BEARER_TOKEN_BEDROCK` env or `bearerToken` option):
    SDK uses `Authorization: Bearer <token>` via `httpBearerAuth`.
  - IAM SigV4: SDK signs with AWS credentials (env / profile / IMDS).
- **Quirks (Bedrock-specific):**
  - Region resolution chain: explicit > endpoint URL hostname > env
    (`AWS_REGION`/`AWS_DEFAULT_REGION`) > us-east-1 (unless `AWS_PROFILE`
    set).
  - `additionalModelRequestFields`: per-model passthrough for Claude
    thinking (`{thinking:{type:"adaptive"|"enabled", display, budget_tokens}}`
    or `output_config:{effort}`, plus `anthropic_beta:
    ["interleaved-thinking-2025-05-14"]`).
  - Cache point support: `{cachePoint:{type:DEFAULT, ttl?:ONE_HOUR}}` blocks
    inserted on system, last user message, last tool — only for Claude 3.5
    Haiku, 3.7 Sonnet, 4.x; Amazon Nova auto-caches.
  - `reasoningContent.reasoningText.signature` only for Anthropic Claude;
    OpenAI/Qwen/Minimax/Moonshot on Bedrock reject the signature field.
  - Tool call IDs sanitized to `[a-zA-Z0-9_-]{<=64}`.
  - GovCloud (`us-gov-*` region or ARN) drops the `thinking.display` field.
  - HTTP proxy support via `NodeHttpHandler` plus
    `createHttpProxyAgentsForTarget`; `AWS_BEDROCK_FORCE_HTTP1` env forces
    HTTP/1.1.
  - `BedrockRuntimeServiceException` mapped to human-readable prefixes
    (Internal server error / Throttling error / etc.) so the retry
    classifier can match.

### 1.10 `openrouter-images` — OpenRouter image generation
Upstream: `providers/images/openrouter.ts`.

- **Endpoint:** SDK-routed. Path = `<model.baseUrl>/chat/completions`.
  OpenRouter chat-completions with `modalities` array.
- **Request body:** OpenAI chat-completions shape with `stream:false`,
  `messages:[{role:"user", content:[…parts…]}]`, and
  `modalities:["image"]` or `["image","text"]`.
- **Response parsing:** Pulls `choices[0].message.content` (text) and
  `choices[0].message.images[]` data URLs (`data:<mime>;base64,<data>`).
- **Streaming format:** Non-streaming.
- **Tool-call format:** N/A.
- **Image input:** OpenAI `image_url:"data:..."`.
- **Auth headers:** `Authorization: Bearer <key>`.
- **Quirks:** `prompt_tokens_details.cached_tokens`/`cache_write_tokens`
  accounting reused from chat usage shape.

### 1.11 Helpers

- **`providers/cloudflare.ts`:** Substitutes `{CLOUDFLARE_ACCOUNT_ID}` and
  `{CLOUDFLARE_GATEWAY_ID}` from `process.env` into `model.baseUrl`. Three
  base URL templates: Workers AI, AI Gateway compat, AI Gateway OpenAI
  passthrough, AI Gateway Anthropic passthrough.
- **`providers/github-copilot-headers.ts`:** Builds dynamic Copilot headers
  (`X-Initiator: user|agent`, `Openai-Intent: conversation-edits`,
  `Copilot-Vision-Request: true` when images present).
- **`providers/openai-prompt-cache.ts`:** Caps `prompt_cache_key` to 64
  characters.
- **`providers/simple-options.ts`:** Base option builder
  (`buildBaseOptions`) and `clampReasoning` / `adjustMaxTokensForThinking`
  shared helpers.
- **`providers/transform-messages.ts`:** Cross-provider message transform;
  normalises tool call IDs across foreign provider replays.
- **`providers/register-builtins.ts`:** Lazy registers all built-in
  providers with `registerApiProvider` and exposes `setBedrockProviderModule`
  for SDK injection.

---

## 2. Mapped to pi-zig (`src/pi/ai_client.zig`)

| Upstream provider | pi-zig location | Status |
| --- | --- | --- |
| `anthropic-messages` (request) | `runAnthropicMessagesTurn` 596-644; `streamAnthropicMessagesData` 646-705; `buildAnthropicMessagesPayload` 2742-2783; `writeAnthropicSystem` 2889-2900; `writeAnthropicMessage` 2902-2926; `writeAnthropicToolResultMessage` 2928-2947; `writeAnthropicTextBlock` 2949-2955; `writeAnthropicContentPart` 2963-2980; `writeAnthropicToolUseBlock` 3022-3034; `writeAnthropicToolDefinition` 3036-3044; `anthropicAuthHeader` 1708-1716; `anthropicExtraHeaders` 1724-1740; `isAnthropicOAuthToken` 1718-1722 | partial |
| `anthropic-messages` (stream) | `readAnthropicSseStream` 3505-3557; `parseAnthropicSseEventKind` 3693-3705; `isAnthropicMessageStopData` 3707-3714; `parseAnthropicMessagesResult` 3716-3760; `isAnthropicStreamEvent` 3916; `anthropicStreamTextDelta` 3928; `appendAnthropicStreamEvent` 4148; `anthropicEventIndex` 4592; `isAnthropicToolUseBlock` 4604; `shouldSerializeInitialToolInput` 4611 | partial |
| `openai-completions` (request/stream) | `streamChatTurnData` 442-518 (default branch); `readDoneTerminatedSseStream` 520-547; `buildPayloadWithStream` 2475-2521; `writeMessage` 4634-…; `writeOpenAIToolTextMessage` 4667; `writeOpenAIToolResultImagesMessage` 4691; `parseOpenAICompatibleStreamData` 3827; `parseOpenAICompatibleStreamResultData` 3866 | partial |
| `openai-responses` (request/stream) | (none — falls through to OpenAI-compatible path; `isResponseStreamEvent` 3899; `responseStreamTextDelta` 3906; `appendResponseStreamEvent` 4109; `startResponseFunctionCall` 4373; `finishResponseFunctionCall` 4390) | **(MISSING)** — no dedicated transport, no Responses-shaped payload writer outside Azure |
| `openai-codex-responses` (request/stream/WS) | **(MISSING)** — no dedicated transport at all; the `chatgpt.com/backend-api` URL, JWT account-id headers, retry/backoff with `retry-after-ms`, the `responses_websockets=2026-02-06` WebSocket transport, the connection cache, `previous_response_id` delta-context, the SSE/WS fallback are all absent. Only the OAuth refresh + JWT decoding exist (see §4). |
| `azure-openai-responses` | `runAzureOpenAIResponsesTurn` 927-979; `streamAzureOpenAIResponsesData` 981-1039; `buildAzureResponsesPayload` 2527-2586; `writeResponsesInputMessage` 2591-2633; `writeResponsesInputText` 2635-2639; `writeResponsesInputImage` 2641-2649; `writeResponsesAssistantItems` 2651-2670; `writeResponsesToolResultItem` 2675-…; `writeResponsesToolResultText` 2718-2730; `writeResponsesToolDefinition` 2732-2740; `azureResolveDeploymentName` 2179-2192; `azureApiVersion` 2194-2203; `azureResolveBaseUrl` 2205-2222; `azureOpenAIResponsesEndpoint` 2231-2249; `azureDefaultReasoningEffort` 2459-2464 | partial |
| `google-generative-ai` | `runGoogleGenerateContentTurn` 707-753; `streamGoogleGenerateContentData` 755-812; `buildGoogleGenerateContentPayload` 2785-2821; `writeGoogleSystemInstruction` 3046-3057; `writeGoogleContent` 3059-3080; `writeGoogleToolResultContent` 3082-3123; `findToolNameForToolResult` 3125-3136; `writeGoogleTextPart` 3138-3142; `writeGoogleFunctionCallPart` 3202-3217; `writeGoogleToolDefinition` 3219-3227; `readGoogleSseStream` 3559-…; `parseGoogleGenerateContentResult` 3762-…; `isGoogleStreamChunk` 3939; `parseGoogleStreamTextDeltas` 3944; `appendGoogleStreamChunk` 4181; `appendGoogleFunctionCall` 4417; `googleGenerateContentEndpointForProvider` 2285-2297 | partial |
| `google-vertex` | `runGoogleVertexGenerateContentTurn` 814-863; `streamGoogleVertexGenerateContentData` 865-925; `googleVertexAuthHeader` 1759-1777; `googleVertexBearerHeader` 1779-1782; `isGoogleVertexOAuthAccessToken` 1784-1787; `isGoogleVertexPlaceholderApiKey` 1789-1793; `googleVertexGenerateContentEndpointForProvider` 2299-2319; `writeGoogleVertexModelResource` 2343-2366 | partial |
| `mistral-conversations` | `runMistralChatTurn` 1040-1085; `streamMistralChatData` 1087-1143; `buildMistralChatPayload` 2823-2849; `writeMistralMessage` 3229-…; `writeMistralTextPart` 3279-3283; `writeMistralContentParts` 3285-3318; `writeMistralToolDefinition` 3320-3328; `writeMistralToolCall` 3330-3338; `isMistralStreamChunk` 3959; `parseMistralStreamTextDeltas` 3969-…; `parseMistralContentDelta` 3978; `appendMistralStreamChunk` 4200; `appendMistralContentDelta` 4255; `appendMistralToolCallDeltas` 4329; `mistralChatEndpointForProvider` 2368-2371 | partial |
| `bedrock-converse-stream` | `runBedrockConverseTurn` 1145-1172; `streamBedrockConverseData` 1633-…; `buildBedrockConversePayload` 2851-2887; `writeBedrockSystem` 3340-3351; `writeBedrockMessage` 3353-3374; `writeBedrockToolResultMessage` 3376-3397; `writeBedrockTextBlock` 3399-3405; `writeBedrockContentPart` 3413-3430; `writeBedrockToolUseBlock` 3472-3484; `writeBedrockToolDefinition` 3486-3494; `bedrockImageFormatFromMime` 3496-3503; `readBedrockEventStream` 3586-3632; `bedrockEventStreamHeader` 3634-3685; `bedrockConverseStreamEndpointForProvider` 2373-2400; SigV4 signer 1191-1697 (`BedrockSigV4Credentials`, `BedrockAuth`, `awsSigV4SignCanonical`, `computeBedrockSigV4`, `signBedrockSigV4`); `isBedrockStreamEvent` 4005; `parseBedrockStreamTextDeltas` 4015; `appendBedrockStreamEvent` 4217; `startBedrockToolUse` 4459; `bedrockContentBlockIndex` 4598 | partial |
| `openrouter-images` | `runImageGeneration` 1809-1856; `imageGenerationEndpointForProvider` 1862-1877; `buildOpenRouterImagesPayload` 1882-1912; `parseOpenRouterImagesResult` 1917-…; `parseBase64DataUrl` 1986-…; `isOpenRouterImagesProvider` 1858-1860 | functional |
| `simple-options.ts` (reasoning helpers) | `azureDefaultReasoningEffort` 2459-2464 only | **(MISSING — partial)** — no `buildBaseOptions`, `clampReasoning`, `adjustMaxTokensForThinking`; pi-zig has no reasoning-effort option on `ChatTurnRequest`. |
| `transform-messages.ts` | **(MISSING)** — no per-provider message transform (foreign-provider tool-call ID handling, cross-provider thinking-to-text downgrade, etc.) |
| `register-builtins.ts` | provider dispatch is hard-coded in `streamChatTurnData` 442-468 (and the chat-turn equivalent); not a registry |
| `github-copilot-headers.ts` | **(MISSING)** — no `X-Initiator`/`Openai-Intent`/`Copilot-Vision-Request` emission |
| `openai-prompt-cache.ts` | **(MISSING)** — no `prompt_cache_key` clamping |
| `cloudflare.ts` | **(MISSING)** — no `{CLOUDFLARE_ACCOUNT_ID}` substitution; Cloudflare workers AI and AI Gateway base URLs not constructed |
| `faux.ts` | partial — `scripts/fake-*` Node helpers (separate from Zig path) cover smoke testing |

---

## 3. Gap detail (full / partial / missing)

### 3.1 Fully present
- **Bedrock SigV4 IAM signing** (HMAC-SHA256 + canonical-request +
  string-to-sign + signing key + `Authorization: AWS4-HMAC-SHA256
  Credential=…/aws4_request, SignedHeaders=…, Signature=…`). Verified
  against AWS get-vanilla vectors and end-to-end smoke
  (`scripts/flow-d-bedrock-smoke.mjs`). Bearer-vs-SigV4 precedence honored.
- **OpenRouter image generation** including data-URL parsing and usage
  accounting.
- **Native Anthropic / Google / Vertex / Mistral / Bedrock streaming**
  enough to support text-only and tool-capable turns in the harness.

### 3.2 Partial
- **Anthropic Messages:**
  - No `cache_control` ephemeral blocks (no `short`/`long` retention, no
    `ttl="1h"`, no system / last-message / last-tool annotation).
  - No `thinking` block in the request (`adaptive`/`enabled`/`disabled`)
    despite the catalog supporting it; no `output_config.effort`; no
    `metadata.user_id`; no `tool_choice`; no `interleaved-thinking` /
    `fine-grained-tool-streaming` beta header negotiation per model
    `compat` flags.
  - No `eager_input_streaming:true` per-tool flag.
  - No tool-name remapping for OAuth (Claude-Code canonical casing in 16
    upstream names: `Read`/`Bash`/`Grep`/`Glob`/`AskUserQuestion`/etc.).
  - `redacted_thinking` and signature round-trip on assistant replay not
    implemented; aborted thinking-block downgrade absent.
  - `x-session-affinity` (Fireworks / Cloudflare-Anthropic) absent.
  - `max_tokens` is hard-coded to 4096 (line 2750), not pulled from the
    catalog.
  - `Cloudflare AI Gateway` base URL / `cf-aig-authorization` not supported.
- **OpenAI chat-completions compat (default branch):**
  - No `compat` detection at all — Cerebras, x.ai, Together, chutes.ai,
    DeepSeek, z.ai, Moonshot, Cloudflare Workers AI/AI Gateway,
    GitHub-Copilot quirks not applied. All requests use one fixed
    `max_tokens`/no-temperature shape with `tool_choice:"auto"`.
  - No `reasoning_effort`/`reasoning`/`enable_thinking`/`thinking`/
    `chat_template_kwargs` per provider; no `provider`/`providerOptions`
    routing (OpenRouter, Vercel AI Gateway).
  - No `prompt_cache_key`/`prompt_cache_retention`; no
    `stream_options.include_usage`; no `store:false`.
  - No `requiresAssistantAfterToolResult` bridge messages.
  - No `requiresReasoningContentOnAssistantMessages` (DeepSeek).
  - No `reasoning_details` `reasoning.encrypted` propagation through
    `thoughtSignature` on tool calls.
  - No `cache_control` ephemeral annotations for Anthropic-via-OpenRouter.
  - No tool-call ID pipe-split normalization (`call|fc_xxx`).
- **OpenAI Responses (non-Azure):** entirely served by the
  OpenAI-compatible default path. There is no Responses-shaped payload
  outside Azure: `input` arrays, `prompt_cache_key`/`retention`,
  `service_tier`, `reasoning:{effort,summary}`,
  `include:["reasoning.encrypted_content"]`, `text:{verbosity}`,
  `previous_response_id`, the `ResponseReasoningItem` round-trip, the
  `TextSignatureV1` stamping (`msg_<index>`/`shortHash(msgId)` 64-char
  cap), and the foreign-toolcall `fc_<shortHash>` synthesis are all
  missing. Streaming pieces in `parseOpenAICompatibleStreamResultData`
  handle a subset (`response.output_item.added`/`.done`,
  `function_call_arguments.delta`/`.done`, `output_text.delta`,
  `response.completed`) but only inside the OpenAI-compatible default
  branch.
- **Azure OpenAI Responses:**
  - No `reasoningEffort`/`reasoningSummary` request option — only the
    `azureDefaultReasoningEffort` fallback (`"none"` when thinking is
    enabled by catalog and not disabled).
  - No `azureBaseUrl`/`azureResourceName`/`azureDeploymentName` request
    options (only the env vars).
  - No `service_tier` / `prompt_cache_key` / `include:
    ["reasoning.encrypted_content"]` / temperature / `max_output_tokens`
    on the wire.
  - No service-tier cost multiplier.
- **Google Generative AI:**
  - No `thinking` configuration emission (`thinkingLevel` /
    `thinkingBudget` / disabled fallback for Gemini 3+ Pro/Flash and
    Gemma 4).
  - No `thoughtSignature` round-trip on assistant replay (block-level
    signature retention exists for streaming via thinking parts; replay
    side is absent).
  - No `temperature`/`maxOutputTokens` emission outside the default.
  - No `toolChoice` parameter; tools fixed to `mode:"AUTO"`.
  - No request-side support for Cloud Code Assist `parameters` (OpenAPI
    3.03) variant for Claude models.
  - Function-call counter is monotonic per-process not per-request, with no
    retention of provider-issued IDs.
- **Google Vertex:**
  - API key + `ya29.*` OAuth bearer routing implemented; service-account
    ADC token mint via RS256 JWT exists (`auth.zig`, lines 1047-1276).
  - Authorized-user ADC refresh implemented; service-account is gated by
    Zig RSA primitives (verified via fake token server only).
  - No `project`/`location` request options; only the
    `GOOGLE_CLOUD_PROJECT`/`GOOGLE_CLOUD_LOCATION` env vars.
  - No `xhigh` clamping.
  - No `THINKING_LEVEL_MAP` translation.
  - No SDK injection / Anthropic-on-Vertex routing.
- **Mistral:**
  - No `promptMode:"reasoning"` / `reasoningEffort` emission.
  - No `toolChoice` parameter wiring.
  - No `x-affinity` session-id header.
  - No collision-resilient tool-call ID derivation (only ad-hoc index
    fallback inside the accumulator).
  - No retry strategy `"none"` override (relies on default std.http
    behavior).
- **Bedrock:**
  - No prompt-cache `{cachePoint:{type:DEFAULT, ttl:ONE_HOUR}}` blocks
    around system / last user / last tool — even for Claude 3.5 Haiku,
    3.7 Sonnet, 4.x.
  - No `reasoningContent.reasoningText.signature` round-trip — pi-zig
    drops the signature.
  - No `additionalModelRequestFields` for Claude thinking
    (`{thinking:{type:"adaptive"|"enabled", display, budget_tokens},
    output_config:{effort}, anthropic_beta:["interleaved-thinking-…"]}`).
  - No `requestMetadata` tagging.
  - No region-from-endpoint-hostname / FIPS / `AWS_BEDROCK_FORCE_HTTP1` /
    proxy agent / `AWS_BEDROCK_SKIP_AUTH` paths.
  - No `~/.aws/credentials` profile or IMDS chain (documented divergence;
    upstream uses SDK).
  - No GovCloud `thinking.display` strip.
  - No exception-name → human-readable prefix mapping for retry
    classification.

### 3.3 Missing entirely
- **`openai-codex-responses` transport.** No SSE path, no WebSocket path,
  no JWT account-id headers, no `originator: pi`, no
  `User-Agent: pi (<platform> <release>; <arch>)`, no `OpenAI-Beta`
  variants, no retry-with-`retry-after-ms`/`retry-after`, no plan-aware
  usage-limit error message, no WebSocket session cache, no
  `previous_response_id` delta context, no `responses_websockets=2026-02-06`
  beta. pi-zig's catalog lists `openai-codex-responses` for Codex models
  but the actual transport is unreachable — the dispatcher routes any
  non-Anthropic/Google/Mistral/Bedrock/Azure provider through the OpenAI
  Chat-Completions path, which is incompatible with Codex's
  `backend-api/codex/responses` shape.
- **GitHub Copilot dynamic headers.** `X-Initiator: user|agent`,
  `Openai-Intent: conversation-edits`, `Copilot-Vision-Request: true` not
  emitted for either chat-completions or Anthropic-via-Copilot.
- **`prompt_cache_key` clamping (`clampOpenAIPromptCacheKey`).** No equivalent
  in pi-zig.
- **`cloudflare.ts` base URL substitution.** No `{CLOUDFLARE_ACCOUNT_ID}` /
  `{CLOUDFLARE_GATEWAY_ID}` substitution; no Workers AI / AI Gateway
  routing.
- **`transform-messages.ts` cross-provider transform.** No re-encoding of
  foreign tool-call IDs, no cross-provider thinking-to-text downgrade, no
  consecutive-toolResult collapse (only the per-provider writers handle
  pieces of this ad-hoc).
- **Cache retention** (`cacheRetention: short|long|none`) end-to-end. The
  request struct (`ChatTurnRequest` lines 72-80) has no field for it; no
  catalog wiring; no `PI_CACHE_RETENTION` env handling.
- **`metadata.user_id`, `tool_choice`, `service_tier`,
  `reasoningSummary`, `textVerbosity`** request-side options across all
  Responses-shaped providers.
- **SimpleStream reasoning option plumbing.** No `clampThinkingLevel`,
  `thinkingLevelMap`, `thinkingBudgets`, `adjustMaxTokensForThinking`. The
  catalog records `reasoning`/`thinking_off_disabled`/`thinkingLevelMap`
  but ai_client cannot consume them beyond `azureDefaultReasoningEffort`.
- **`Faux` provider runtime** for upstream-style streaming tests. pi-zig
  uses Node-side `scripts/fake-*.mjs` for harness coverage instead.
- **Lazy provider module registry.** Upstream dynamically loads each
  provider on first use; pi-zig hardcodes the dispatch and pays the build
  cost for every provider.

---

## 4. OAuth flows

### 4.1 Anthropic OAuth (Claude Pro/Max)

Upstream (`utils/oauth/anthropic.ts`):
- Authorization code + PKCE (S256).
- `CLIENT_ID` = `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (atob-decoded).
- Authorize URL: `https://claude.ai/oauth/authorize`.
- Token URL: `https://platform.claude.com/v1/oauth/token`.
- Callback URL: `http://localhost:53692/callback`
  (host override via `PI_OAUTH_CALLBACK_HOST`).
- Scope: `org:create_api_key user:profile user:inference
  user:sessions:claude_code user:mcp_servers user:file_upload`.
- Login flow: start callback server → push auth URL to caller → race
  between callback HTTP arrival and optional `onManualCodeInput` paste →
  on state match exchange code with `grant_type=authorization_code`,
  `code_verifier`, `redirect_uri`, `state` → store
  `{access, refresh, expires=now+expires_in*1000-5*60*1000}`.
- Refresh: POST JSON `{grant_type:"refresh_token", client_id,
  refresh_token}` to TOKEN_URL → `{access_token, refresh_token, expires_in,
  scope?}`.

pi-zig (`src/pi/auth.zig`):
- **Refresh:** implemented at lines 569-577, 620-706 (`refreshOAuthCredential`
  with `grant=.post_json`). Same URL, same client ID, same body shape,
  same `5 min` expiry skew. JSON parse identical.
- **Interactive login:** **(MISSING).** `beginInteractiveLogin` (line 1431)
  exists as a stub; no callback HTTP server, no PKCE generation flow, no
  state handling, no `onAuth`/`onPrompt`/`onManualCodeInput` callback
  surface. Auth must be supplied via `auth set-oauth <provider> <access>
  <refresh> <expires-ms>` (line 313).
- **OAuth header path:** `Authorization: Bearer <token>`,
  `anthropic-beta: claude-code-20250219,oauth-2025-04-20`,
  `x-app: cli`, `user-agent: claude-cli/2.1.75` all present
  (`ai_client.zig` 1708-1740). Substring `sk-ant-oat` detection matches
  upstream.
- **PKCE generator:** **(MISSING).** No SHA-256 + base64url verifier/
  challenge helper. Upstream `utils/oauth/pkce.ts` is 34 lines of Web
  Crypto API; trivial to port but absent.

### 4.2 GitHub Copilot OAuth

Upstream (`utils/oauth/github-copilot.ts`):
- Device-code flow (RFC 8628) via `pollOAuthDeviceCodeFlow`.
- `CLIENT_ID` = `Iv1.b507a08c87ecfe98` (atob-decoded).
- Device-code URL: `https://<domain>/login/device/code` with
  `client_id`, `scope=read:user` (domain = `github.com` or enterprise
  domain).
- Access-token URL: `https://<domain>/login/oauth/access_token`,
  `grant_type=urn:ietf:params:oauth:grant-type:device_code`.
- Copilot-token URL: `https://api.<domain>/copilot_internal/v2/token`,
  `Authorization: Bearer <github-access-token>` plus Copilot headers
  (`User-Agent: GitHubCopilotChat/0.35.0`, `Editor-Version: vscode/1.107.0`,
  `Editor-Plugin-Version: copilot-chat/0.35.0`,
  `Copilot-Integration-Id: vscode-chat`). Response = `{token, expires_at}`.
- Base URL inferred from `proxy-ep=…` in the token (line 71): converts
  `proxy.individual.githubcopilot.com` → `api.individual.githubcopilot.com`.
- Login flow: prompt for enterprise URL → device-code request → emit
  `userCode + verificationUri` to caller → poll for access token →
  exchange for Copilot token (which doubles as the refresh credential via
  the GitHub access token) → call `enableAllGitHubCopilotModels(token)`
  for each catalog model (`/models/<id>/policy {state:"enabled"}` with
  `openai-intent: chat-policy`, `x-interaction-type: chat-policy`).
- `modifyModels` hook: rewrites `baseUrl` based on `proxy-ep` token
  decoding so each request hits the correct Copilot proxy host.

pi-zig (`src/pi/auth.zig`):
- **Refresh:** GitHub access token doubles as refresh; pi-zig stores the
  GitHub access token in the `refresh` field and exchanges it for the
  Copilot bearer token on demand (lines 680-700). Headers match
  upstream (`User-Agent: GitHubCopilotChat/0.35.0`, `editor-version`,
  `editor-plugin-version`, `copilot-integration-id`). Response parsing
  pulls `token` and `expires_at` (line 720-728). 5-min skew applied.
- **Interactive login (device code):** **(MISSING).** No `device/code`
  start, no polling loop, no slow_down/expired-token handling, no
  enterprise-domain prompt, no `enableAllGitHubCopilotModels`. Storage is
  via `set-oauth` only.
- **`proxy-ep` base-URL extraction:** **(MISSING).** pi-zig has no
  `getBaseUrlFromToken` equivalent; routes all Copilot traffic through
  whatever `model.baseUrl` is in the catalog. `modifyModels` hook also
  missing — there is no provider-side rewrite of `model.baseUrl` after
  login.
- **Dynamic Copilot headers** (`X-Initiator`, `Openai-Intent`,
  `Copilot-Vision-Request`): **(MISSING)** from the wire as noted in §2.

### 4.3 OpenAI Codex (ChatGPT subscription)

Upstream (`utils/oauth/openai-codex.ts`):
- Authorization code + PKCE (S256).
- `CLIENT_ID` = `app_EMoamEEZ73f0CkXaXp7hrann` (plain).
- Authorize URL: `https://auth.openai.com/oauth/authorize` with
  `response_type=code`, `code_challenge`, `code_challenge_method=S256`,
  `state` (16-byte hex), `id_token_add_organizations=true`,
  `codex_cli_simplified_flow=true`, `originator=pi`.
- Token URL: `https://auth.openai.com/oauth/token`,
  `Content-Type: application/x-www-form-urlencoded`.
- Callback URL: `http://localhost:1455/auth/callback`.
- Scope: `openid profile email offline_access`.
- JWT account-id extraction: `decodeJwt` → middle segment → JSON parse →
  `payload["https://api.openai.com/auth"].chatgpt_account_id`. Stored as
  `credentials.accountId`.
- Refresh: POST form `grant_type=refresh_token, refresh_token, client_id`
  → `{access_token, refresh_token, expires_in}`.
- Login flow: PKCE + state → local HTTP server on port 1455 → push URL
  to caller → race callback HTTP against optional manual paste → exchange
  code (`grant_type=authorization_code, code, code_verifier, redirect_uri,
  client_id`) → extract account ID from JWT → persist credentials.

pi-zig (`src/pi/auth.zig`):
- **Refresh:** implemented (lines 587-594, `grant=.post_form`,
  `requires_account_id=true`). Same URL, same client ID, same body shape
  (`grant_type=refresh_token&refresh_token=...&client_id=...`).
  `chatGptAccountIdFromAccessToken` (line 753) base64url-decodes the
  middle JWT segment and extracts `chatgpt_account_id` from
  `https://api.openai.com/auth` claim — **matches upstream**.
  `expiry_skew_ms=0` (upstream uses `Date.now() + expires_in*1000` with
  no skew → matches).
- **Interactive login (PKCE + callback):** **(MISSING).** No port-1455
  HTTP server, no PKCE flow, no state generation, no `originator=pi` /
  `codex_cli_simplified_flow=true` / `id_token_add_organizations=true`
  query parameters, no manual-paste race, no `onAuth`/`onPrompt`
  callbacks. Login is impossible without manually pasting tokens via
  `set-oauth`.
- **Codex request-side use:** even when stored credentials exist, the
  Codex Responses transport itself is absent (§3.3), so the access token
  cannot be exercised against `chatgpt.com/backend-api/codex/responses`.
  This is the single largest gap on the OAuth side.

### 4.4 Vertex / Google ADC (not in `utils/oauth/`, but related)
- Upstream relies on `@google/genai`'s `GoogleAuth` (delegates fully to
  the Google SDK). Pi-zig reimplements the relevant subset of ADC
  resolution + RS256 JWT minting in `src/pi/auth.zig` 794-1276:
  authorized_user refresh + service_account JWT-bearer exchange + RSA
  modular exponentiation over `std.crypto.ff`. Documented divergence:
  full IMDS / metadata server / impersonation chain absent.

### 4.5 OAuth registry / `getOAuthApiKey`
- Upstream `utils/oauth/index.ts` exports `getOAuthApiKey(providerId,
  credentials)` which auto-refreshes on expiry. pi-zig mirrors this via
  `resolveProviderApiKey` + `resolveApiKeyMutable` +
  `resolveExpiredOAuth` (lines 38-499). Persisted credentials are
  rewritten on disk after refresh via `updateStoredOAuthCredential`
  (line 500). `auth providers --json` lists the three OAuth specs (line
  352).

---

## 5. Estimated parity

Weighted estimate per surface (rough, by user-visible coverage):

| Provider / surface | Approx. parity |
| --- | --- |
| `anthropic-messages` request | 55% (no cache_control, no thinking, no OAuth tool-name remap, no compat flags, max_tokens hard-coded) |
| `anthropic-messages` stream  | 75% (custom SSE decoder + tool stream parsing in place; redacted_thinking, signatures, `eager_input_streaming`, fine-grained tool beta absent) |
| `openai-completions`         | 45% (catalog routes 20+ providers through the OpenAI-compat path with no `compat` differentiation, no reasoning fields, no prompt cache, no provider routing, no Anthropic-via-OpenRouter cache annotations) |
| `openai-responses`           | 25% (request/stream rerouted through OpenAI-compat path; Responses-shaped `input` items, reasoning items, text signature, foreign-toolcall normalization absent outside Azure) |
| `openai-codex-responses`     | 5% (only JWT account-id extraction + OAuth refresh; no transport, no WebSocket, no retry, no cached-context) |
| `azure-openai-responses`     | 60% (deployment routing + base URL builder + reasoning-default emit; reasoning effort/summary, service tier, prompt cache, request-side options absent) |
| `google-generative-ai`       | 55% (text/tool/image streaming working; thinking config, thoughtSignature replay, toolChoice, temperature absent) |
| `google-vertex`              | 65% (API key + `ya29.*` OAuth + authorized_user ADC + service_account JWT minting in place; project/location options, thinking_level_map, xhigh clamp absent) |
| `mistral-conversations`      | 60% (text/tool/image streaming, OpenAI-compatible result parsing; reasoning effort/promptMode, x-affinity, robust tool-call ID derivation absent) |
| `bedrock-converse-stream`    | 55% (SigV4 + bearer + event-stream + tool/text/image; cache point, signature replay, Claude thinking passthrough, requestMetadata, proxy/HTTP1, profile/IMDS absent) |
| `openrouter-images`          | 90% (request, parse, usage; only minor accounting nits) |
| OAuth refresh (3 providers)  | 95% (request shapes match; only login flow is missing) |
| OAuth interactive login      | 0% (no PKCE, no callback servers, no device-code polling, no manual-paste race) |
| Cloudflare base URL routing  | 0% |
| GitHub Copilot dynamic headers | 0% |
| Cross-provider message transform | 25% (per-writer ad-hoc, no central transform) |
| Provider compat detection    | 5% (only Anthropic vs Google vs Mistral vs Bedrock vs Azure dispatching; no per-baseUrl quirk table) |

**Bottom line.** **Provider transport parity ≈ 40–50%.** OAuth refresh
parity ≈ 95% but interactive-login parity = 0%. The two biggest gaps are
(a) the entire `openai-codex-responses` transport including its WebSocket
variant and (b) the absence of per-provider `compat` quirk handling for
the 20+ providers served by upstream's `openai-completions` path.

If users restrict themselves to:
- Anthropic Messages (API key or pre-pasted OAuth refresh token),
- OpenAI Chat Completions on api.openai.com,
- Google Generative AI with `GEMINI_API_KEY`,
- Vertex with `GOOGLE_CLOUD_API_KEY` or pre-stored `ya29.*`,
- Mistral with API key,
- Bedrock with `AWS_BEARER_TOKEN_BEDROCK` or env IAM credentials,
- Azure OpenAI Responses with `AZURE_OPENAI_*` env vars,

then pi-zig is functional. Everything else — Codex Responses, all
OpenRouter / Cloudflare / x.ai / Together / DeepSeek / z.ai / Moonshot
quirks, GitHub Copilot, all interactive logins — is unreached.

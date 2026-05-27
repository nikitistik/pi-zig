# Upstream Inventory

Snapshot:

- Repository: `https://github.com/earendil-works/pi`
- Local checkout: `upstream/pi`
- Commit: `fc8a1559017f1e581cfa971aa3cef11a507a4975`
- Commit date: 2026-05-25
- Root package: `pi-monorepo` (version `0.0.3`)
- Workspaces: `packages/*` plus four coding-agent example extension packages
- Runtime requirement: Node `>=22.19.0`
- Package file count under `packages/`: 734
- Generated model catalog: 924 models across 32 providers from
  `packages/ai/src/models.generated.ts`

All counts below are produced by `node scripts/upstream-inventory.mjs`, which
parses the pinned upstream tree and writes a machine-readable artifact to
`docs/inventory/upstream-inventory.json`. The script's self-checks fail loudly
if any enumerated surface (package, CLI command, provider, transport, extension
API, TUI component, RPC command, or public-API doc) drifts from disk, so this
inventory cannot silently miss a package.

## Packages

Eight workspace packages: four primary published packages and four private
example extensions referenced from the root `workspaces` array.

| Package | Directory | Role | Workspace deps | Source `.ts` | Test `.ts` |
|---|---|---|---|---:|---:|
| `@earendil-works/pi-ai` | `packages/ai` | primary | — | 53 | 76 |
| `@earendil-works/pi-agent-core` | `packages/agent` | primary | pi-ai | 25 | 20 |
| `@earendil-works/pi-coding-agent` | `packages/coding-agent` | primary | pi-ai, pi-agent-core, pi-tui | 145 | 133 |
| `@earendil-works/pi-tui` | `packages/tui` | primary | — | 26 | 28 |
| `pi-extension-custom-provider-anthropic` | `packages/coding-agent/examples/extensions/custom-provider-anthropic` | example | — | — | — |
| `pi-extension-custom-provider-gitlab-duo` | `packages/coding-agent/examples/extensions/custom-provider-gitlab-duo` | example | — | — | — |
| `pi-extension-sandbox` | `packages/coding-agent/examples/extensions/sandbox` | example | — | — | — |
| `pi-extension-with-deps` | `packages/coding-agent/examples/extensions/with-deps` | example | — | — | — |

Package roles:

- `@earendil-works/pi-ai`: Multi-provider LLM API, provider registry, image
  routes, OAuth, streaming. Bin `pi-ai`. Sub-path exports for each provider plus
  `./oauth` and `./bedrock-provider`.
- `@earendil-works/pi-agent-core`: Agent loop, harness, durable sessions, hooks,
  compaction, state. Exports `.` and `./node`.
- `@earendil-works/pi-coding-agent`: CLI (`pi` bin), interactive/print/JSON/RPC
  modes, tools, sessions, resources, export-html. Exports `.` and `./hooks`.
- `@earendil-works/pi-tui`: Terminal UI renderer, components, editor,
  keybindings, images. Native prebuilds for win32/darwin.

Example extensions exist to exercise the package manager and `pi.extensions`
manifest discovery; each declares `pi.extensions: ["./index.ts"]` and is private.

## CLI surface

### Top-level commands (routed before `parseArgs`)

`install`, `remove`, `uninstall` (alias for remove), `update`, `list`, `config`.
Sources: `packages/coding-agent/src/package-manager-cli.ts`
(`handlePackageCommand`, `handleConfigCommand`) and `src/main.ts`.

### Flags (46 parsed in `cli/args.ts`)

Includes `--provider`, `--model`, `--api-key`, `--system-prompt`,
`--append-system-prompt`, `--mode`, `--print/-p`, `--continue/-c`,
`--resume/-r`, `--session`, `--fork`, `--session-dir`, `--no-session`,
`--models`, `--no-tools/-nt`, `--no-builtin-tools/-nbt`, `--tools/-t`,
`--thinking`, `--extension/-e`, `--no-extensions/-ne`, `--skill`,
`--prompt-template`, `--theme`, `--no-skills/-ns`, `--no-prompt-templates/-np`,
`--no-themes`, `--no-context-files/-nc`, `--export`, `--list-models`,
`--verbose`, `--offline`, `--help/-h`, `--version/-v`. Unknown `--flags` are
collected for extension `registerFlag`/`getFlag`.

### CLI command files

`cli/args.ts`, `cli/config-selector.ts`, `cli/file-processor.ts`,
`cli/initial-message.ts`, `cli/list-models.ts`, `cli/session-picker.ts`.

### App modes / mode entrypoints

Four app modes resolved in `main.ts` `resolveAppMode`: `interactive`, `print`,
`json`, `rpc`. Entrypoints: `modes/index.ts`, `modes/print-mode.ts`,
`modes/rpc/rpc-mode.ts`, `modes/interactive/interactive-mode.ts`.

### Built-in interactive slash commands (21)

`settings`, `model`, `scoped-models`, `export`, `import`, `share`, `copy`,
`name`, `session`, `changelog`, `hotkeys`, `fork`, `clone`, `tree`, `login`,
`logout`, `new`, `compact`, `resume`, `reload`, `quit` (from
`core/slash-commands.ts` `BUILTIN_SLASH_COMMANDS`). Extension/prompt/skill slash
commands are layered on top by the resource loader.

## RPC commands (29 inbound)

The authoritative inbound command list is the `RpcCommand` union in
`packages/coding-agent/src/modes/rpc/rpc-types.ts`:
`prompt`, `steer`, `follow_up`, `abort`, `new_session`, `get_state`,
`set_model`, `cycle_model`, `get_available_models`, `set_thinking_level`,
`cycle_thinking_level`, `set_steering_mode`, `set_follow_up_mode`, `compact`,
`set_auto_compaction`, `set_auto_retry`, `abort_retry`, `bash`, `abort_bash`,
`get_session_stats`, `export_html`, `switch_session`, `fork`, `clone`,
`get_fork_messages`, `get_last_assistant_text`, `set_session_name`,
`get_messages`, `get_commands`. Extension UI methods are stdout
`extension_ui_request` events plus an `extension_ui_response` inbound reply,
which are request/response shapes outside the inbound command union.

## Built-in tools (7)

`read`, `bash`, `edit`, `write`, `grep`, `find`, `ls`. Backed by 15 modules in
`core/tools/` (the seven tool files plus `edit-diff`, `file-mutation-queue`,
`index`, `output-accumulator`, `path-utils`, `render-utils`,
`tool-definition-wrapper`, `truncate`).

## Providers

### Transport APIs (9 registered)

From `packages/ai/src/providers/register-builtins.ts`
(`registerBuiltInApiProviders`): `anthropic-messages`, `openai-completions`,
`mistral-conversations`, `openai-responses`, `azure-openai-responses`,
`openai-codex-responses`, `google-generative-ai`, `google-vertex`,
`bedrock-converse-stream`.

### Provider implementation files (20)

`packages/ai/src/providers/*`: `amazon-bedrock`, `anthropic`,
`azure-openai-responses`, `cloudflare`, `faux`, `github-copilot-headers`,
`google`, `google-shared`, `google-vertex`, `mistral`, `openai-codex-responses`,
`openai-completions`, `openai-prompt-cache`, `openai-responses`,
`openai-responses-shared`, `register-builtins`, `simple-options`,
`transform-messages`, plus image routes `images/openrouter` and
`images/register-builtins`.

### Auth surfaces

- API-key env providers (30): from `packages/ai/src/env-api-keys.ts`. Includes
  `anthropic` (OAuth-token-then-key precedence), `openai`,
  `azure-openai-responses`, `deepseek`, `google`, `google-vertex`, `groq`,
  `cerebras`, `xai`, `openrouter`, `vercel-ai-gateway`, `zai`, `mistral`,
  `minimax`(+`-cn`), `moonshotai`(+`-cn`), `huggingface`, `fireworks`,
  `together`, `opencode`(+`-go`), `kimi-coding`, `cloudflare-workers-ai`,
  `cloudflare-ai-gateway`, `xiaomi`(+ three token-plan regions),
  `github-copilot` (`COPILOT_GITHUB_TOKEN`).
- OAuth providers (3): `anthropic`, `github-copilot`, `openai-codex` from
  `packages/ai/src/utils/oauth/*`. Shared helpers: `device-code`, `pkce`,
  `oauth-page`.
- Ambient credential sources intentionally excluded from env reporting: AWS
  profiles/IAM and Google Application Default Credentials.

### Model registry

924 model rows across 32 generated providers in
`packages/ai/src/models.generated.ts`; image model catalog in
`image-models.generated.ts`. Resolution in `core/model-registry.ts` and
`core/model-resolver.ts`.

## Extension API

Source of truth: `packages/coding-agent/src/core/extensions/types.ts` plus
`loader.ts`, `runner.ts`, `wrapper.ts`, `index.ts`.

### Registration / action methods (22 on the `pi` object)

`registerTool`, `registerCommand`, `registerShortcut`, `registerFlag`,
`getFlag`, `registerMessageRenderer`, `registerProvider`, `unregisterProvider`,
`sendMessage`, `sendUserMessage`, `appendEntry`, `setSessionName`,
`getSessionName`, `setLabel`, `exec`, `getActiveTools`, `getAllTools`,
`setActiveTools`, `getCommands`, `setModel`, `getThinkingLevel`,
`setThinkingLevel`.

### Lifecycle events (29 via `pi.on(...)`)

`resources_discover`, `session_start`, `session_before_switch`,
`session_before_fork`, `session_before_compact`, `session_compact`,
`session_shutdown`, `session_before_tree`, `session_tree`, `context`,
`before_provider_request`, `after_provider_response`, `before_agent_start`,
`agent_start`, `agent_end`, `turn_start`, `turn_end`, `message_start`,
`message_update`, `message_end`, `tool_execution_start`,
`tool_execution_update`, `tool_execution_end`, `model_select`,
`thinking_level_select`, `tool_call`, `tool_result`, `user_bash`, `input`.

## TUI

### `@earendil-works/pi-tui` components (12)

`box`, `cancellable-loader`, `editor`, `image`, `input`, `loader`, `markdown`,
`select-list`, `settings-list`, `spacer`, `text`, `truncated-text`. Top-level
modules include `tui`, `terminal`, `terminal-image`, `editor-component`,
`autocomplete`, `fuzzy`, `keybindings`, `keys`, `kill-ring`, `undo-stack`,
`native-modifiers`, `stdin-buffer`, `utils`, `index`.

### Coding-agent interactive component groups (36)

`modes/interactive/components/*`: messages (`assistant-message`,
`user-message`, `custom-message`, `tool-execution`, `bash-execution`,
`compaction-summary-message`, `branch-summary-message`,
`skill-invocation-message`, `diff`), selectors/dialogs (`model-selector`,
`scoped-models-selector`, `theme-selector`, `thinking-selector`,
`session-selector`, `session-selector-search`, `settings-selector`,
`config-selector`, `extension-selector`, `oauth-selector`, `login-dialog`,
`show-images-selector`, `tree-selector`, `user-message-selector`), editors
(`custom-editor`, `extension-editor`, `extension-input`), and chrome (`footer`,
`keybinding-hints`, `bordered-loader`, `dynamic-border`, `countdown-timer`,
`visual-truncate`, `index`, `armin`, `daxnuts`, `earendil-announcement`).

## Documented public-API / DoD surfaces (26 pages)

From `packages/coding-agent/docs/docs.json` navigation. Start here: `index`,
`quickstart`, `usage`, `providers`, `settings`, `keybindings`, `sessions`,
`compaction`. Customization: `extensions`, `skills`, `prompt-templates`,
`themes`, `packages`, `models`, `custom-provider`. Reference: `session-format`.
Programmatic usage: `sdk`, `rpc`, `json`, `tui`. Platform setup: `windows`,
`termux`, `tmux`, `terminal-setup`, `shell-aliases`. Development: `development`.

High-risk parity surfaces (where behavior, not just shape, must match):

- CLI flags/commands from `cli/args.ts` and `package-manager-cli.ts`.
- RPC protocol from `docs/rpc.md` and `modes/rpc/*`.
- Built-in tools from `core/tools/*` (output accumulation, truncation, mutation
  queue).
- Session/compaction from `core/*` and `packages/agent/src/harness/*`.
- Provider transports/auth from `packages/ai/src/providers/*`, `env-api-keys.ts`,
  `utils/oauth/*`.
- Model resolution from `core/model-resolver.ts` (prefixes, fuzzy search,
  thinking suffixes).
- Resource discovery from `core/prompt-templates.ts`, `core/skills.ts`,
  `core/resource-loader.ts`, RPC `get_commands`.
- Terminal/TUI behavior from `packages/tui/src/*` and `modes/interactive/*`.

Refresh with:

```sh
node scripts/upstream-inventory.mjs
node scripts/generate-model-catalog.mjs --check
```

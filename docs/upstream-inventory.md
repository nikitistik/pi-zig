# Upstream Inventory

Snapshot:

- Repository: `https://github.com/earendil-works/pi`
- Local checkout: `upstream/pi`
- Commit: `fc8a1559017f1e581cfa971aa3cef11a507a4975`
- Commit date: 2026-05-25
- Root package: `pi-monorepo`
- Workspaces: `packages/*` plus coding-agent extension examples
- Runtime requirement: Node `>=22.19.0`
- Package file count under `packages/`: 734
- Generated model catalog: 924 models across 32 providers from
  `packages/ai/src/models.generated.ts`

Primary packages:

| Package | Directory | Role |
|---|---|---|
| `@earendil-works/pi-ai` | `packages/ai` | Multi-provider LLM API, provider registry, images, OAuth, streaming |
| `@earendil-works/pi-agent-core` | `packages/agent` | Agent loop, harness, durable sessions, hooks, compaction, state |
| `@earendil-works/pi-coding-agent` | `packages/coding-agent` | CLI, TUI mode, print mode, RPC mode, tools, sessions, resources |
| `@earendil-works/pi-tui` | `packages/tui` | Terminal UI renderer, components, editor, keybindings, images |

Source/test counts from `node scripts/upstream-inventory.mjs`:

| Package | Source Files | Test Files |
|---|---:|---:|
| `@earendil-works/pi-ai` | 53 | 76 |
| `@earendil-works/pi-agent-core` | 25 | 20 |
| `@earendil-works/pi-coding-agent` | 145 | 133 |
| `@earendil-works/pi-tui` | 26 | 28 |

High-risk parity surfaces:

- CLI flags and package commands from `packages/coding-agent/src/cli/args.ts`.
- RPC protocol from `packages/coding-agent/docs/rpc.md` and
  `packages/coding-agent/src/modes/rpc/*`; the authoritative inbound command
  list is the `RpcCommand` union in `rpc-types.ts`, while extension UI methods
  are stdout `extension_ui_request` events rather than stdin commands.
- Built-in tools from `packages/coding-agent/src/core/tools/*`.
- Session and compaction behavior from both `packages/coding-agent/src/core/*`
  and `packages/agent/src/harness/*`.
- Provider behavior from `packages/ai/src/providers/*`.
- Model registry behavior from `packages/ai/src/models.ts`,
  `packages/ai/src/models.generated.ts`, and
  `packages/coding-agent/src/core/model-registry.ts`.
- Model resolution behavior from `packages/coding-agent/src/core/model-resolver.ts`
  including provider prefixes, fuzzy search, and thinking suffixes.
- Command/resource discovery from `packages/coding-agent/src/core/prompt-templates.ts`,
  `packages/coding-agent/src/core/skills.ts`, and RPC `get_commands`.
- Terminal behavior from `packages/tui/src/*`.

Refresh with:

```sh
node scripts/upstream-inventory.mjs
node scripts/generate-model-catalog.mjs --check
```

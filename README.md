# pi-zig

Zig + Preact porting workspace for `earendil-works/pi`.

Target upstream:

- Repository: `https://github.com/earendil-works/pi`
- Commit: `fc8a1559017f1e581cfa971aa3cef11a507a4975`
- Date: 2026-05-25
- Verified against `origin/main`: 2026-05-26

The target is 100% functionality parity with the Pi Agent Harness monorepo while
keeping the package boundaries close to upstream:

- `src/pi/`: Zig backend/runtime/library surface.
- `src/main.zig`: CLI and backend entrypoint.
- `frontend/`: Preact parity workbench and future Prin7r app surface.
- `upstream/pi/`: read-only upstream checkout used as the parity source.
- `docs/`: DoD, upstream inventory, and parity ledger.

Current status: foundation started, not complete. The parity tracker in
`docs/parity.md` is the source of truth until every upstream row is green.

## Commands

```sh
zig build test
zig build run -- status
zig build run -- inventory
zig build run -- packages
zig build run -- providers
zig build run -- models
zig build run -- models-for anthropic
zig build run -- model anthropic claude-haiku-4-5
zig build run -- list-models haiku
zig build run -- --list-models haiku
zig build run -- resolve-model --provider anthropic haiku:high
zig build run -- resolve-model openai/gpt-4o
zig build run -- provider-env anthropic
zig build run -- tools
zig build run -- rpc-schema
zig build run -- list
zig build run -- install --help
zig build run -- install npm:example-package
zig build run -- install git:github.com/user/repo --local
zig build run -- update --extensions
zig build run -- auth list --json
zig build run -- auth providers --json
zig build run -- auth status openai --json
zig build run -- auth set-api-key openai OPENAI_API_KEY
zig build run -- auth resolve openai --json
zig build run -- extensions --json
zig build run -- extensions --json --no-extensions --extension ./my-extension
zig build run -- settings --json
zig build run -- settings paths
zig build run -- settings get resolved.compaction.enabled
zig build run -- settings set-model openai gpt-4o
zig build run -- commands
zig build run -- commands --skill explicit/skills --prompt-template explicit/prompts
zig build run -- themes
zig build run -- themes --export dark
COLORFGBG='0;7;15' zig build run -- themes --detect
zig build run -- themes --resolved light
zig build run -- context-files
zig build run -- context-files --no-context-files
zig build run -- system-prompt --date 2026-05-26 --json --no-context-files
npm run test # includes auth storage, extension discovery, settings-manager migration/write-safety, settings/package filters, local packages, context files, system prompt assembly, and ancestor .agents command discovery fixtures
zig-out/bin/pi-zig --export zig-out/pi-zig-top-level-json-smoke.jsonl zig-out/pi-zig-top-level-export.html
printf '{"type":"get_state"}\n' | zig build run -- rpc zig-out/pi-zig-session.jsonl
printf '{"type":"get_available_models"}\n{"type":"set_model","provider":"anthropic","modelId":"claude-haiku-4-5"}\n{"type":"get_state"}\n' | zig build run -- rpc zig-out/pi-zig-session.jsonl
printf '{"type":"prompt","message":"hello"}\n{"type":"get_session_stats"}\n{"type":"export_html","outputPath":"zig-out/pi-zig-session.html"}\n' | zig build run -- rpc zig-out/pi-zig-session.jsonl
printf '{"type":"prompt","message":"compact me"}\n{"type":"set_auto_compaction","enabled":true}\n{"type":"compact","customInstructions":"focus changes"}\n{"type":"set_auto_retry","enabled":true}\n{"type":"abort_retry"}\n' | zig build run -- rpc zig-out/pi-zig-compact-session.jsonl
printf '{"type":"get_commands"}\n' | zig build run -- rpc zig-out/pi-zig-session.jsonl
printf '{"type":"get_commands"}\n' | zig build run -- --mode rpc --session zig-out/pi-zig-session.jsonl --skill explicit/skills --prompt-template explicit/prompts
zig build run -- -p "hello top-level print"
zig build run -- --mode json --session zig-out/pi-zig-json-session.jsonl -p "hello json"
printf '{"type":"get_state"}\n' | zig build run -- --mode rpc --session zig-out/pi-zig-rpc-mode-session.jsonl
printf '{"type":"bash","command":"printf rpc-bash"}\n{"type":"get_messages"}\n' | zig build run -- rpc zig-out/pi-zig-session.jsonl
printf '{"type":"get_state"}\n{"type":"get_messages"}\n' | zig build run -- rpc zig-out/pi-zig-session.jsonl
printf '{"type":"switch_session","sessionPath":"zig-out/pi-zig-session.jsonl"}\n{"type":"get_state"}\n' | zig build run -- rpc zig-out/pi-zig-switch-driver.jsonl
printf '{"type":"prompt","message":"first"}\n{"type":"prompt","message":"second"}\n{"type":"get_fork_messages"}\n{"type":"fork","entryId":"m-2"}\n{"type":"get_state"}\n' | zig build run -- rpc zig-out/pi-zig-fork-source.jsonl
printf '{"type":"prompt","message":"clone me"}\n{"type":"clone"}\n{"type":"get_state"}\n' | zig build run -- rpc zig-out/pi-zig-clone-source.jsonl
zig build run -- parse-args --provider openai --thinking xhigh -p "say ok" @README.md
zig build run -- tool-read README.md
zig build run -- tool-ls .
zig build run -- tool-grep "Zig + Preact" README.md
zig build run -- tool-find README.md . 20
zig build run -- tool-write zig-out/pi-zig-tool-edit-smoke.txt "alpha beta"
zig build run -- tool-bash "printf ok"
zig build run -- tool-edit zig-out/pi-zig-tool-edit-smoke.txt beta gamma
node scripts/upstream-inventory.mjs
node scripts/generate-model-catalog.mjs --check
npm --prefix frontend install --ignore-scripts
npm run test
npm run build
```

## Prin7r Integration Target

After standalone parity is real, inject this project into:

```text
/Users/keer/projects/prin7r-openwork-zero_native
```

Integration must include backend wiring, Preact app wiring, navigation/app
registry exposure, full frontend/backend builds, the packaged macOS app rebuild,
launch verification, and screenshots.

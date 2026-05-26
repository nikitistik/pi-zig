# Definition of Done

Target upstream: `earendil-works/pi` commit
`fc8a1559017f1e581cfa971aa3cef11a507a4975`.

The port is done only when all of these are true:

1. The public surfaces of upstream packages have Zig counterparts:
   - `@earendil-works/pi-ai`
   - `@earendil-works/pi-agent-core`
   - `@earendil-works/pi-coding-agent`
   - `@earendil-works/pi-tui`
2. CLI parity is complete for help, version, package commands, model/provider
   options, session options, tool options, resource options, print mode, JSON
   mode, RPC mode, export mode, update/install/remove/list/config flows, and all
   documented aliases.
3. Agent runtime parity is complete for message flow, tool calling, state
   management, hooks, durable harness, compaction, session tree/branching,
   queues, cancellation, diagnostics, usage accounting, and event streaming.
4. Provider parity is complete for OpenAI Responses, OpenAI Completions,
   OpenAI Codex Responses, Anthropic, Google, Google Vertex, Mistral, Bedrock,
   GitHub Copilot, OpenRouter image routes, Cloudflare image routes, OAuth,
   proxying, cache-control, streaming, reasoning/thinking, and overflow
   handling.
5. Built-in tool parity is complete for `read`, `bash`, `edit`, `write`,
   `grep`, `find`, `ls`, output accumulation, truncation, path handling, and
   mutation queue semantics.
6. TUI parity is complete for differential rendering, editor behavior,
   keybindings, autocomplete, markdown, images, selectors, settings lists,
   themes, clipboard/image handling, terminal behavior, and Windows/macOS/Linux
   differences.
7. Resource parity is complete for extensions, skills, prompt templates,
   themes, context files, package manager flows, local/project/global settings,
   migrations, and settings persistence.
8. Session parity is complete for JSONL storage, import/export, HTML export,
   branch navigation, fork/clone/resume/continue, names, modified timestamps,
   session directories, and no-session mode.
9. The Preact frontend can inspect parity status, run backend commands, inspect
   sessions/messages, exercise RPC, and serve as the Prin7r app surface.
10. Verification includes:
    - `zig build test`
    - frontend build
    - upstream inventory script
    - CLI smoke runs
    - RPC smoke runs
    - real terminal/TUI interaction checks
    - browser/Computer Use screenshots
    - targeted regression tests matching upstream behavior
11. Prin7r injection is delivered as a backend+frontend integration patch path,
    then built and verified in the packaged Prin7r app.

No row may be marked complete based on source presence alone. Every completion
claim must be backed by a run, test, or screenshot artifact.


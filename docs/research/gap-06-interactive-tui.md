# gap-06 audit: interactive TUI (controller, components, theme, assets)

Read-only audit performed on branch `codex/pi-zig-progress` (HEAD `5db2192`). Comparison is between:

- Upstream: `upstream/pi/packages/coding-agent/src/modes/interactive/`
  - `interactive-mode.ts` (5564 LoC; the `InteractiveMode` controller)
  - `components/` (35 component files; ~213 KB total)
  - `theme/theme.ts` (1227 LoC) + `theme/dark.json` + `theme/light.json` + `theme/theme-schema.json`
  - `assets/clankolas.png` (single PNG used by the Earendil announcement)
- pi-zig: primarily `src/pi/tui.zig` (2219 LoC), with supporting modules
  - `src/pi/tui_editor.zig` (646 LoC), `src/pi/tui_render.zig` (249 LoC), `src/pi/tui_keys.zig` (384 LoC), `src/pi/tui_fuzzy.zig` (434 LoC), `src/pi/tui_terminal.zig` (101 LoC)
  - `src/pi/tui_footer.zig` (511 LoC), `src/pi/tui_messages.zig` (965 LoC), `src/pi/tui_theme.zig` (395 LoC), `src/pi/tui_selector.zig` (272 LoC)
  - `src/pi/cli_runtime.zig` (`runInteractive`)
  - `src/pi/themes.zig` (1441 LoC — but it's mostly the `pi themes` CLI subcommand, NOT a runtime palette engine)
- All file:line references verified by reading the listed files.

Bottom line up front: the interactive TUI is the single largest visible-chrome gap in pi-zig today. Upstream ships a 5564-line state machine driving 35 component classes and a 1227-line theme engine; pi-zig ships a 2219-line `App` whose composer + transcript + 1 of 14 selector overlays paints a rectangular box-drawn approximation of the upstream layout. Three of the new helper modules (`tui_messages.zig`, `tui_theme.zig`, `tui_selector.zig`) exist in the source tree but are **not imported by `tui.zig` and not exported from `src/pi/index.zig`** — they are dead code with their own unit tests, none of their renderers reach the live screen.

---

## 1. Component inventory (every component file in `interactive/components/`)

Sizes from `wc -l` / `ls -la` on each file.

| Upstream file | LoC | Exported entry point | What it renders / does |
|---|---|---|---|
| `armin.ts` | 383 | `class ArminComponent` | 31×36 XBM "Armin says hi" easter-egg animated with 7 effects (typewriter/scanline/rain/fade/crt/glitch/dissolve) — half-block ASCII art rendered into the chat. |
| `assistant-message.ts` | 148 | `class AssistantMessageComponent extends Container` | Wraps assistant text + thinking + abort/error footer; emits OSC 133 zone codes (`\x1b]133;A/B/C\x07`) for terminal integration. Handles `hideThinkingBlock` + custom `hiddenThinkingLabel`. |
| `bash-execution.ts` | 219 | `class BashExecutionComponent extends Container` | `$ <cmd>` header in green box, streaming output preview capped at 20 lines, `(cancelled)/(exit N)` footer, expand/collapse hint, truncation-to-file path notice. Uses `stripAnsi` + `truncateTail`. |
| `bordered-loader.ts` | 69 | `class BorderedLoader extends Container` | `CancellableLoader`/`Loader` wrapped in a `DynamicBorder` with a cancel hint — used by extensions for in-line spinners. |
| `branch-summary-message.ts` | 59 | `class BranchSummaryMessageComponent extends Box` | `[branch]` label, collapsed/expanded toggle, markdown-rendered branch summary on purple `customMessageBg`. |
| `compaction-summary-message.ts` | 60 | `class CompactionSummaryMessageComponent extends Box` | `[compaction]` label + "Compacted from N tokens" header with collapsed/expanded summary markdown. |
| `config-selector.ts` | 629 | `class ConfigSelectorComponent extends Container` | Hierarchical Extensions/Skills/Prompts/Themes resource browser with fuzzy filter, scope grouping (user/project/package), Space-to-toggle persistence into settings. |
| `countdown-timer.ts` | 40 | `class CountdownTimer` | Per-second ticker calling `onTick(seconds)` and `onExpire()`; used by retry banner, extension dialogs. |
| `custom-editor.ts` | 81 | `class CustomEditor extends Editor` | Subclass of upstream `Editor` that intercepts app keybindings, paste-image, Ctrl+D-when-empty, extension shortcuts, and per-action handlers (`onAction`). |
| `custom-message.ts` | 100 | `class CustomMessageComponent extends Container` | Extension-injected message: tries a renderer-supplied component, else default `[<customType>]` label + markdown body on `customMessageBg`. |
| `daxnuts.ts` | 165 | `class DaxnutsComponent` | 32×32 RGB "Powered by daxnuts" PNG drawn with half-block + truecolor SGR, scanline reveal, 25-frame animation, then text fade-in. Easter egg. |
| `diff.ts` | 148 | `function renderDiff(diffText, options) -> string` | Word-level diff (`Diff.diffWords`) with intra-line inverse on changed tokens, themed `+`/`-`/space lines (`toolDiffAdded`/`toolDiffRemoved`/`toolDiffContext`). |
| `dynamic-border.ts` | 26 | `class DynamicBorder` | Single line of `─` glyphs filling the viewport width, colorable. |
| `earendil-announcement.ts` | 54 | `class EarendilAnnouncementComponent extends Container` | Bordered block with title, blog URL, and inline `clankolas.png` via Kitty/iTerm/Sixel/fallback `Image` widget. |
| `extension-editor.ts` | 157 | `class ExtensionEditorComponent extends Container` | Top+bottom borders, title, multi-line `Editor`, submit/newline/cancel hints, optional external editor launch ($VISUAL/$EDITOR) with TUI stop/start. |
| `extension-input.ts` | 88 | `class ExtensionInputComponent extends Container` | Single-line `Input`, title, optional `CountdownTimer` that auto-cancels, submit/cancel hints. |
| `extension-selector.ts` | 113 | `class ExtensionSelectorComponent extends Container` | Generic vertical list of string options for extensions; ↑↓/j/k navigation, Enter/Esc, optional countdown timeout. |
| `footer.ts` | 234 | `class FooterComponent implements Component` | THE real footer: pwd (with `~`), git branch, session name, ↑/↓/R/W token counts, `$cost (sub)`, context-percent (colored at >70/>90), model + thinking-level + provider, extension status lines. |
| `index.ts` | 33 | (re-exports) | Public surface for `pi-tui` consumers. |
| `keybinding-hints.ts` | 49 | `keyHint`, `keyText`, `keyDisplayText`, `rawKeyHint`, `formatKeyText` | Format a keybinding name as `<dim key> <muted desc>`; capitalizes / handles `alt→option` on macOS. |
| `login-dialog.ts` | 226 | `class LoginDialogComponent extends Container` | OAuth/API-key login surface: shows verification URL (with OSC 8 hyperlink for Cmd/Ctrl+click), opens browser, polls device code, prompt for code/key/value, `cancel()` aborts via `AbortController`. |
| `model-selector.ts` | 339 | `class ModelSelectorComponent extends Container` | Search-filtered model list with scope toggle (all/scoped), current model first, fuzzy match on `provider/id`, scroll window of 10, model name footer, persists selection via `setDefaultModelAndProvider`. |
| `oauth-selector.ts` | 209 | `class OAuthSelectorComponent extends Container` | Login/logout provider picker; per-row status badge (configured / env / runtime / fallback / models.json key/command / unconfigured), fuzzy filter, scroll window of 8. |
| `scoped-models-selector.ts` | 356 | `class ScopedModelsSelectorComponent extends Container` | `/scoped-models`: enable/disable + reorder models for Ctrl+P cycling, toggle provider, all/clear, session-only vs save-to-settings, dirty-state indicator. |
| `session-selector-search.ts` | 195 | `filterAndSortSessions`, `parseSearchQuery`, `matchSession`, `hasSessionName`, types | Parser + matcher for the session-selector query language: tokens, `"phrases"`, `re:<pattern>`; modes recent/relevance/threaded; name filter all/named. |
| `session-selector.ts` | 1023 | `class SessionSelectorComponent extends Container` | `/resume`: threaded/recent/relevance view, current-folder/all scope, search, message-count + age, current-session marker, name filter, rename mode (inline `Input`), delete with confirmation (trash CLI → unlink fallback), progress during load, tree prefixes (`├─`/`└─`/`│`). |
| `settings-selector.ts` | 552 | `class SettingsSelectorComponent extends Container` | The whole `/settings` panel: 25+ items (autocompact, steering-mode, follow-up-mode, transport, http-timeout, thinking, hide-thinking, theme with live preview, image flags, hardware cursor, editor padding, autocomplete max visible, quiet-startup, clear-on-shrink, terminal progress, warnings sub-menu). Live theme preview on selection change. |
| `show-images-selector.ts` | 51 | `class ShowImagesSelectorComponent extends Container` | Yes/No `SelectList` with descriptions. |
| `skill-invocation-message.ts` | 56 | `class SkillInvocationMessageComponent extends Box` | `[skill]` label, skill name as bold header, collapsed (one-line summary) vs expanded (full markdown body). |
| `theme-selector.ts` | 68 | `class ThemeSelectorComponent extends Container` | Themes via `getAvailableThemes()`, marks `(current)`, preview on selection change, persist on confirm. |
| `thinking-selector.ts` | 75 | `class ThinkingSelectorComponent extends Container` | off/minimal/low/medium/high/xhigh with token-cost descriptions; `SelectList` of available levels per model. |
| `tool-execution.ts` | 353 | `class ToolExecutionComponent extends Container` | THE inline tool box: dual `callRenderer`/`resultRenderer` via tool definitions (built-in + extension), `renderShell: "self"\|"default"` switch, pending/success/error background, multi-image rendering (Kitty/iTerm/Sixel/PNG conversion fallback), image-block extraction, expand/collapse, partial-stream rendering. |
| `tree-selector.ts` | 1392 | `class TreeSelectorComponent extends Container` (+ `TreeList`, `SearchLine`, `LabelInput`) | `/tree`: the full session DAG with branch glyphs, multiple filter modes (default/no-tools/user-only/labeled-only/all), per-node fold/unfold, branch segment jump, label editing with `LabelInput`, label timestamp toggle, scroll, active-path highlight, parent-chain walk. |
| `user-message-selector.ts` | 156 | `class UserMessageSelectorComponent extends Container` | `/fork`: pick a previous user message to branch a new session; 2-line entries; auto-cancel if empty. |
| `user-message.ts` | 36 | `class UserMessageComponent extends Container` | User text as `Markdown` on `userMessageBg` slab; OSC 133 zone start/end/final codes. |
| `visual-truncate.ts` | 51 | `truncateToVisualLines(text, max, width, paddingX)` | Width-aware tail-truncation used by `BashExecutionComponent` and `ToolExecutionComponent` previews. |

Total: **35 component files, ~6740 LoC just under `components/`**.

---

## 2. Mapped to pi-zig

The table below answers, for each upstream component: **does pi-zig have ANY equivalent reachable from the live `App`?** "Reachable" means the App's `buildScreen` / `paint` path actually invokes it. "Orphan" means the module exists in `src/pi/` with tests but `tui.zig` does NOT import it (the live screen never calls it).

| Upstream component | pi-zig location | Reach | Note |
|---|---|---|---|
| `index.ts` (re-exports) | — | n/a | No external `pi-tui` package; pi-zig has no equivalent re-export hub. |
| `armin.ts` (easter egg) | — | **missing** | No animation framework, no XBM/half-block decoder. |
| `assistant-message.ts` | `tui_messages.zig` `renderAssistantMessage` (lines 330–367) | **orphan** | Box-drawing chip ("ASSISTANT" + box border), but tui.zig never calls it. tui.zig instead appends `assistant: <text>` as a single transcript line (tui.zig:1054–1056). No OSC 133 zone codes. No abort/error footer, no thinking block, no markdown rendering. |
| `bash-execution.ts` | `tui_messages.zig` `renderBashExecution` (lines 453–535) | **orphan** | Box w/ green chrome, 20-line preview, exit code, cancelled marker, truncation notice — well-modeled, but unreachable from `tui.zig` (no `/bash` keybinding, no bash mode toggle, no `!`/`!!` handling). |
| `bordered-loader.ts` | — | **missing** | No `Loader` widget. tui.zig prints a static `"[working... press Esc to abort]"` status string (tui.zig:381–384). No spinner animation, no signal abort wiring. |
| `branch-summary-message.ts` | `tui_messages.zig` `renderBranchSummary` (lines 579–613) | **orphan** | Orphan; tui.zig has no `branchSummary` message type to render. |
| `compaction-summary-message.ts` | `tui_messages.zig` `renderCompactionSummary` (lines 540–574) | **orphan** | Orphan; `/compact` does write `"[Context compacted]" + summary` as plain transcript lines (tui.zig:743–746). No tokens-before label, no expand/collapse. |
| `config-selector.ts` | — | **missing** | No equivalent UI. `/settings` and resource toggling are not in the live TUI. |
| `countdown-timer.ts` | — | **missing** | No retry banner, no extension input timeout. |
| `custom-editor.ts` | `tui_editor.Editor` (646 LoC) + tui.zig dispatch | partial | The Zig editor handles char/word cursor, kill ring, history, single-level undo. But there is no `onAction(action, handler)` map, no `onPasteImage`, no `onExtensionShortcut`, no Ctrl+D-when-empty branch matching upstream. |
| `custom-message.ts` | `tui_messages.zig` `renderCustomMessage` (lines 618–645) | **orphan** | No extension-injected messages reach the live screen. |
| `daxnuts.ts` (easter egg) | — | **missing** | No truecolor RGB renderer, no `/daxnuts` command. |
| `diff.ts` | — | **missing** | No diff renderer; tool result text is rendered as raw preview only. `Diff.diffWords` intra-line inverse is gone. |
| `dynamic-border.ts` | `tui_messages.zig` `buildDivider` + box helpers; `tui_footer.zig` `buildDivider` | partial | Two divider helpers exist; the footer uses one for its 80-char dim rule. `tui.zig.renderStatusBar` (lines 432–496) has its own inline divider. |
| `earendil-announcement.ts` | — | **missing** | No image rendering, no Kitty/Sixel/iTerm protocols, no inline image widget. `assets/clankolas.png` not even copied. |
| `extension-editor.ts` | — | **missing** | No extension dialogs of any kind. |
| `extension-input.ts` | — | **missing** | Same. |
| `extension-selector.ts` | — | **missing** | Same. |
| `footer.ts` | `tui_footer.zig` `render` (lines 208–234) | partial-reachable | Reached from `App.buildScreen` (tui.zig:432). Renders divider/banner/divider/blank/divider/status-row/hint-row. **No** token-usage counts, **no** cost, **no** context percent, **no** extension statuses; only `provider | model · thinking <session-timer> <bar> <pct>  | Week ...`. Banner gated on `PI_ZIG_NEW_VERSION` env var, not on a real version check. |
| `keybinding-hints.ts` | — | **missing** | No `keyHint`/`keyText`/`rawKeyHint` helpers — `tui_footer.buildHintLine` hard-codes `Ctrl+C clear/abort` and `/help keyboard shortcuts`. |
| `login-dialog.ts` | — | **missing** | No `/login` UI. tui.zig:686 has `findCommand(name) != null` fall-through that prints `"/<name> is a recognized command but is not yet wired in the Zig TUI."` |
| `model-selector.ts` | `tui.zig` `renderModelSelector`/`openModelSelector`/`modelSelectorCycle`/`modelSelectorAccept` (lines 542–917) | partial-reachable | Two-line overlay: `"Select model (...)"` + `"> <provider> / <id>"`. No fuzzy search, no description (`Model Name: ...`), no scope toggle, no scroll, no current-marker checkmark, no `setDefaultModelAndProvider` persistence (only `options.provider`/`options.model` are updated). |
| `oauth-selector.ts` | — | **missing** | No `/login` flow. |
| `scoped-models-selector.ts` | — | **missing** | No `/scoped-models` UI; no `session.scopedModels`. |
| `session-selector-search.ts` | `tui_fuzzy.zig` (434 LoC) | partial | Generic fuzzy matcher exists. But the session-specific tokens/phrases/regex/sort-mode parser doesn't. |
| `session-selector.ts` | — | **missing** | No `/resume` UI. The slash command falls through to the unwired path. |
| `settings-selector.ts` | — | **missing** | No `/settings` UI. |
| `show-images-selector.ts` | — | **missing** | No image rendering at all, so no toggle. |
| `skill-invocation-message.ts` | `tui_messages.zig` `renderSkillInvocation` (lines 650–676) | **orphan** | Orphan; tui.zig doesn't parse skill blocks. |
| `theme-selector.ts` | `tui_selector.SelectList` (272 LoC) | **orphan** | `tui_selector.zig` is a generic select-list with palette, but `tui.zig` never instantiates it. There is no `/theme` keybinding/command. Theme switching is only via `PI_THEME` env var at startup (tui_theme.zig:155–159). |
| `thinking-selector.ts` | — | **missing** | `thinking_level` field exists on `App` (tui.zig:289) and the footer displays it, but there's no UI to change it; no cycle keybinding, no selector. |
| `tool-execution.ts` | `tui_messages.zig` `renderToolExecution` (lines 373–447) | **orphan** | Orphan: tui.zig:932–946 appends a 2-line bracketed `[tool: name]` + preview to the transcript instead. Lots missing vs upstream: no tool-definition `renderCall`/`renderResult`, no `renderShell: "self"`, no pending/success/error chrome backgrounds, no images-in-tool-result, no `setArgsComplete` for diff-on-edit, no per-id update tracking, no `setExpanded`. |
| `tree-selector.ts` | — | **missing** | No `/tree` UI; no session DAG navigation; no per-node labels, fold/unfold, filter modes, segment-jump, label editing. |
| `user-message-selector.ts` | — | **missing** | No `/fork` selector. The host's `SessionCallbacks.fork` is wired (tui.zig:704–717) but there's no UI to pick the fork point — it forks from "wherever". |
| `user-message.ts` | `tui_messages.zig` `renderUserMessage` (lines 282–324) | **orphan** | tui.zig:1024–1026 just appends `> <prompt>` to the transcript (single line). No box chrome reaches the live screen. No markdown rendering. No OSC 133 zone codes. |
| `visual-truncate.ts` | — | **missing** | No width-aware visual truncation. tui_messages.zig truncates by **byte count** for tool output and **logical-line count** for bash output (not visual lines). |

Reachability summary:

- **0 of 35** upstream components have a fully reachable, byte/behavior-faithful Zig port.
- **3 of 35** have a partial reachable port: `footer.ts` → `tui_footer.zig` (4 of ~9 features), `dynamic-border.ts` → divider helpers, `model-selector.ts` → 2-line overlay.
- **8 of 35** have an orphan implementation in `tui_messages.zig` / `tui_selector.zig` / `tui_theme.zig` (tests pass, live screen never calls them): user-message, assistant-message, tool-execution, bash-execution, compaction-summary, branch-summary, custom-message, skill-invocation, theme-selector (via `SelectList`).
- **24 of 35** are completely missing: armin, bordered-loader, config-selector, countdown-timer, custom-editor (subclass), daxnuts, diff, earendil-announcement, extension-editor, extension-input, extension-selector, keybinding-hints, login-dialog, oauth-selector, scoped-models-selector, session-selector (+ search), settings-selector, show-images-selector, thinking-selector, tree-selector, user-message-selector, visual-truncate, index re-exports.

The orphan modules also have feature gaps vs upstream even on their own terms — see Section 3.

---

## 3. Behavior parity (does pi-zig's render look like upstream's?)

### Box-drawing chrome
- **Upstream**: uses `Box` / `DynamicBorder` from `pi-tui`, which paint single-line horizontal rules (`─` U+2500) and the four corner glyphs. Boxes use solid background slabs (`userMessageBg`, `customMessageBg`, `toolPendingBg`, `toolSuccessBg`, `toolErrorBg`) so the entire row is themed.
- **pi-zig (`tui_messages.zig`)**: uses `╭ ╮ ╰ ╯ ─ │` (arc corners, U+256D/E/F/0 + U+2500/2 — note **arc corners**, NOT the upstream square `┌┐└┘` style). The box backgrounds upstream uses for full-row slabs are explicitly NOT implemented: `tui_messages.zig:380–388` says `_ = surface_bg; // Reserved for a future opaque-fill chrome variant`. So even when reached, the orphan boxes wouldn't fill the whole row.
- **pi-zig (`tui.zig`)**: the LIVE screen has no box-drawing at all for messages. It's plain transcript lines.

### ANSI palettes
- **Upstream**: ~49-token theme schema (`theme.ts:30–92`) covering core UI (accent/border/borderAccent/borderMuted/success/error/warning/muted/dim/text/thinkingText), backgrounds (selectedBg/userMessageBg/customMessageBg/toolPendingBg/toolSuccessBg/toolErrorBg), tool text (toolTitle/toolOutput/userMessageText/customMessageText/customMessageLabel), 10 markdown tokens, 3 diff tokens, 9 syntax-highlight tokens, 6 thinking-level border tokens, plus `bashMode`. Each can be `#rrggbb`, an ANSI 256 index, or a var-ref. Variable references resolve recursively with cycle detection. Truecolor vs 256-color is auto-selected from `getCapabilities().trueColor`.
- **pi-zig (`tui_theme.zig`)**: implements ONLY 6 tokens (accent / muted / branch (=upstream `border`) / good (=`success`) / warn (=`warning`) / code_bg (=`selectedBg`)). 43 of upstream's 49 tokens are not consumed. All output is 256-color (`hexTo256`, no truecolor). No grayscale-spread heuristic for thinkingText. No markdown highlight tokens. No syntax-highlight tokens. No thinking-level borders. No `bashMode` derivation (a hard-coded `\x1b[38;5;82m` is used in `tui_messages.zig:55`).
- **pi-zig (`tui.zig` and `tui_messages.zig`)**: the LIVE renderer uses inline 256-color SGR escapes hard-coded as `pub const` strings (`tui.zig:36–52`, `tui_messages.zig:42–69`). Neither the `App` nor `tui_footer` actually reads from the `tui_theme.Palette`. The `App` field set never adds a palette; you can grep `tui_theme` from `tui.zig` and get zero hits.

### Layout / scrolling
- **Upstream**: `TUI` (from `pi-tui`) uses a top-down container model (`headerContainer` / `chatContainer` / `pendingMessagesContainer` / `statusContainer` / `widgetContainerAbove` / `editorContainer` / `widgetContainerBelow` / `footer`). The terminal scrolls naturally via OS scrollback; image/Kitty handling and shrink-on-resize are handled in the `pi-tui` core. Each component owns its width-aware rendering.
- **pi-zig**: `App.buildScreen` (`tui.zig:362–430`) concatenates: transcript lines + streaming lines + status line + editor lines + (model selector OR command palette) + status bar. The `tui_render.Renderer` (`tui_render.zig`) does line-level diffing: full redraw on line-count change, in-place rewrite on line-equal-count change. There is no `chatContainer` vs `statusContainer` separation (so an extension `setExtensionStatus` would have nowhere to write). No `headerContainer` either — the printBanner runs once and the masthead is just transcript line 0. No `widgetContainerAbove`/`Below` for extension widgets.

### Overlays / dialogs
- **Upstream**: 14 distinct selector/dialog overlay components, each registered as the active editor focus owner (`ui.setFocus(component)`). Escape/Esc semantics differ per overlay; the `interactive-mode.ts` controller toggles them via `showSelector` (line 3825) which swaps the editor out, sets focus, registers shortcuts, and restores everything on close.
- **pi-zig**: 2 overlays exist (`palette_active`, `model_selector_active`); both are exclusive (`if model else if palette` at `tui.zig:412–415`). There's no `showSelector` framework — adding a new overlay requires touching the build-screen path manually. Permission dialog is also synchronous: it reads keys in a tight stdin loop inside `permissionCb` (tui.zig:881–924) blocking the main render loop instead of becoming a focusable component.

### Dynamic borders / spinners
- **Upstream**: `DynamicBorder` re-renders its `─` glyphs at the current terminal width on every paint. `Loader` / `CancellableLoader` animate a spinner per ~80ms via `setInterval` + `ui.requestRender()`, then `dispose()` cleans up.
- **pi-zig**: dividers are 80-char fixed-width (`tui.zig:436`, `tui_footer.zig:75–80`, `tui_messages.zig:93` = `default_box_width = 60`). They do NOT track terminal width. There are no animated spinners — `App.streaming` is repainted on every chunk, but the working indicator is a static string `"[working... press Esc to abort]"` (tui.zig:381–384).

### Countdown timers
- **Upstream**: `CountdownTimer` ticks per 1s via `setInterval`, calls `onTick(seconds)` and `onExpire()`. Used by retry banner, extension dialogs (`extension-input`, `extension-selector` with `opts.timeout`).
- **pi-zig**: there is no time-based callback path. The footer DOES read `Clock.real.now` once per paint to compute the session/week elapsed seconds, but no per-second tick wakes the loop.

### Image rendering
- **Upstream**: `Image` widget from `pi-tui` dispatches to Kitty / iTerm2 inline / Sixel / fallback (`getCapabilities().images`). `ToolExecutionComponent.maybeConvertImagesForKitty` re-encodes JPEG/etc → PNG via `convertToPng` (libvips or similar). `EarendilAnnouncementComponent` and `DaxnutsComponent` ship inline PNG / RGB hex art.
- **pi-zig**: zero image support. `tui_messages.zig` has no Image type. The `clankolas.png` asset is not embedded. There's no `getCapabilities()` Zig equivalent.

### Diff viewer
- **Upstream**: `diff.ts` parses lines as `[+-\s]<lineNum> <content>`, batches consecutive removed+added pairs, renders intra-line word diff with `\x1b[7m` inverse on changed tokens. Used by `Edit` tool's `renderResult`.
- **pi-zig**: no diff viewer. Tool results are byte-prefix previews only.

### Login / OAuth dialogs
- **Upstream**: `LoginDialogComponent` shows a clickable URL (OSC 8 hyperlink `\x1b]8;;url\x07text\x1b]8;;\x07`), opens browser with `open`/`xdg-open`/`start`, polls device code, prompts for manual code/URL fallback, accepts `cancel()` via `AbortController`.
- **pi-zig**: there is no `/login` or `/logout` UI. The path returns "not yet wired" via the `findCommand(name) != null` arm (tui.zig:686).

### OSC 133 / terminal integration
- **Upstream**: `UserMessageComponent` and `AssistantMessageComponent` wrap their output in `OSC133_ZONE_START` (`\x1b]133;A\x07`), `OSC133_ZONE_END` (`\x1b]133;B\x07`), `OSC133_ZONE_FINAL` (`\x1b]133;C\x07`) for terminal shell integration (iTerm/WezTerm/etc).
- **pi-zig**: no OSC 133 codes anywhere (grep `133` across `src/pi/` returns zero hits).

### OSC 9;4 progress
- **Upstream**: `agent_start` / `agent_end` / `compaction_start` / `compaction_end` toggle `ui.terminal.setProgress(true/false)` which emits OSC 9;4 progress indicators for the terminal tab bar (gated on `showTerminalProgress` setting).
- **pi-zig**: no OSC 9;4 path.

### Markdown rendering
- **Upstream**: `Markdown` widget from `pi-tui` with a `MarkdownTheme` (heading/link/code/codeBlock/quote/hr/listBullet colors) + syntax highlighting via `cli-highlight` against the theme's 9 syntax tokens. Code blocks get a bordered surface (`mdCodeBlock` + `mdCodeBlockBorder`). Bullets, quotes, links, italics, bold, strikethrough, underline all rendered.
- **pi-zig**: NO markdown renderer. All upstream messages that pass through `Markdown(text, ..., themeOverride)` (assistant/user/branch/compaction/custom) lose all formatting. Hyperlinks are not detected. Code blocks are not highlighted.

---

## 4. Interactive-mode controller parity (`interactive-mode.ts` 5564 LoC vs `tui.App`)

The `InteractiveMode` class has the following groupings of methods (line numbers from `grep -nE "^\s*(private|public|async|protected)\s+(async\s+)?\w+\s*\("`). pi-zig equivalent column lists what reaches the live screen; blank = missing.

| Group | Upstream method | LoC range | pi-zig equivalent |
|---|---|---|---|
| **Lifecycle / init** | `constructor` | 359 | `tui.App.init` (tui.zig:297) — covers ~12 of the 60+ fields. |
| | `init()` | 568 | (folded into `App.init`, no async setup) |
| | `run()` | 716 | `App.run` (tui.zig:1068) |
| | `shutdown()` | 3251 | None — `App.deinit` runs from `defer`. |
| | `emergencyTerminalExit()` | 3265 | None |
| | `uncaughtCrash()` | 3285 | None |
| | `registerSignalHandlers/unregisterSignalHandlers` | 3312–3357 | None (no signal handlers in tui.zig) |
| **Resource paths / labels** | `formatDisplayPath`, `formatExtensionDisplayPath`, `formatContextPath`, `getShortPath`, `getCompactPathLabel`, `getCompactPackageSourceLabel`, `getCompactExtensionLabel`, `getCompactDisplayPathSegments`, `getCompactNonPackageExtensionLabel`, `getCompactExtensionLabels`, `getDisplaySourceInfo`, `getScopeGroup`, `isPackageSource`, `buildScopeGroups`, `formatScopeGroups`, `findSourceInfoForPath`, `formatPathWithSource`, `formatDiagnostics` | 917–1281 | None (no resource listing in TUI) |
| **Startup notices** | `getChangelogForDisplay`, `getStartupExpansionState`, `showStartupNoticesIfNeeded`, `showLoadedResources`, `reportInstallTelemetry`, `checkTmuxKeyboardSetup`, `checkForPackageUpdates` | 538–1481 | None — `printBanner` (tui.zig:1140) prints only the masthead + provider/model. No changelog. No "What's New". No package-update probe. No tmux keyboard hint. |
| **Session binding** | `bindCurrentSessionExtensions`, `applyRuntimeSettings`, `rebindCurrentSession`, `handleFatalRuntimeError`, `renderCurrentSessionState`, `renderSessionContext`, `renderInitialMessages`, `rebuildChatFromMessages` | 1483–3223 | None — `App` has no concept of an `AgentSession`. The runtime/extensions/skills layer is wired through the AI runtime, not the TUI. |
| **Extension UI** | `setExtensionStatus`, `setExtensionWidget`, `clearExtensionWidgets`, `resetExtensionUI`, `renderWidgets`, `renderWidgetContainer`, `setExtensionFooter`, `setExtensionHeader`, `addExtensionTerminalInputListener`, `clearExtensionTerminalInputListeners`, `createExtensionUIContext`, `showExtensionSelector`, `hideExtensionSelector`, `showExtensionConfirm`, `showExtensionInput`, `hideExtensionInput`, `showExtensionEditor`, `hideExtensionEditor`, `setCustomEditorComponent`, `showExtensionNotify`, `showExtensionError` | 1681–2354 | None — no extension UI in the live TUI, only the agent-side extension runner. |
| **Key handlers** | `setupKeyHandlers`, `handleClipboardImagePaste`, `setupEditorSubmitHandler`, `handleCtrlC`, `handleCtrlD`, `checkShutdownRequested`, `handleCtrlZ`, `handleFollowUp`, `handleDequeue`, `updateEditorBorderColor`, `cycleThinkingLevel`, `cycleModel`, `toggleToolOutputExpansion`, `setToolsExpanded`, `toggleThinkingBlockVisibility`, `openExternalEditor` | 2376–3641 | partial: `App.handleKey` / `handleOverlayKey` / `dispatchKey` (tui.zig:1183–1402) covers a subset (ctrl+c/ctrl+d/escape, model cycle Ctrl+L/P/Shift+P, submit/newline, editor cursor + delete + yank + undo, slash detection). **Missing**: handleCtrlZ (suspend), `app.thinking.cycle`, `app.tools.expand`, `app.thinking.toggle`, `app.editor.external`, `app.message.followUp`, `app.message.dequeue`, `app.session.{new,tree,fork,resume}`, paste-image, bash mode (`!`/`!!`) detection. The `tui.zig` palette handler does not check `app.session.*` keybindings. |
| **Queueing** | `getAllQueuedMessages`, `clearAllQueues`, `updatePendingMessagesDisplay`, `restoreQueuedMessagesToEditor`, `queueCompactionMessage`, `isExtensionCommand`, `flushCompactionQueue`, `flushPendingBashComponents` | 3641–3837 | None — no message queue, no steering, no follow-up, no compaction-queue. |
| **Selectors** | `showSelector`, `showSettingsSelector`, `showModelSelector`, `showModelsSelector`, `showUserMessageSelector`, `showTreeSelector`, `showSessionSelector`, `showLoginAuthTypeSelector`, `showLoginProviderSelector`, `showOAuthSelector` | 3825–4611 | partial: `openModelSelector` is the only one wired. There's no `showSelector` framework. |
| **Login** | `handleResumeSession`, `getLoginProviderOptions`, `getLogoutProviderOptions`, `completeProviderAuthentication`, `showBedrockSetupDialog`, `showApiKeyLoginDialog`, `showOAuthLoginSelect`, `showLoginDialog` | 4416–4865 | None |
| **Slash commands** | `handleModelCommand`, `findExactModelMatch`, `getModelCandidates`, `handleCloneCommand`, `handleReloadCommand`, `handleExportCommand`, `getPathCommandArgument`, `handleImportCommand`, `handleShareCommand`, `handleCopyCommand`, `handleNameCommand`, `handleSessionCommand`, `handleChangelogCommand`, `handleHotkeysCommand`, `handleClearCommand`, `handleDebugCommand`, `handleArminSaysHi`, `handleDementedDelves`, `handleDaxnuts`, `checkDaxnutsEasterEgg`, `handleBashCommand`, `handleCompactCommand` | 3999–5599 | partial: `App.runCommand` (tui.zig:540–676) implements quit/help/new/clear/session/model/changelog/compact/export/name/fork/clone. **Missing**: `/scoped-models`, `/import`, `/share`, `/copy`, `/hotkeys` (partial), `/login`, `/logout`, `/reload`, `/debug`, `/tree`, `/resume`, easter eggs. |
| **Event handlers** | `subscribeToAgent`, `handleEvent` (5070 LoC switch on `agent_start` / `queue_update` / `session_info_changed` / `thinking_level_changed` / `message_start` / `message_update` / `message_end` / `tool_execution_start` / `tool_execution_update` / `tool_execution_end` / `agent_end` / `compaction_start` / `compaction_end` / `auto_retry_start` / `auto_retry_end`) | 2645–3000 | None — pi-zig's `App` uses a callback API (`PromptRunner` → `on_text` / `on_tool_result` / `should_cancel` / `on_tool_permission`, tui.zig:124–134), not an event-driven `AgentSession.subscribe`. There is no message queue update, no thinking-level change event, no retry banner. |
| **Loader / status** | `getWorkingLoaderMessage`, `createWorkingLoader`, `stopWorkingLoader`, `setWorkingVisible`, `setWorkingIndicator`, `setHiddenThinkingLabel`, `showStatus`, `addMessageToChat` | 1686–3122 | None — a single string `App.status` is shown above the editor (tui.zig:381–384). |
| **Misc** | `getUserInput`, `getUserMessageText`, `formatDiagnostics`, `setupExtensionShortcuts`, `getRegisteredToolDefinition`, `getMarkdownThemeWithSettings`, `getAppKeyDisplay`, `getEditorKeyDisplay`, `updateAvailableProviderCount`, `maybeWarnAboutAnthropicSubscriptionAuth`, `updateTerminalTitle` | 1006–5429 | None |

**Method count parity**: upstream has 150 methods on `InteractiveMode`. pi-zig `App` has roughly 45 methods. Of the 150 upstream methods, **fewer than 25 have any pi-zig equivalent** by behavior, and most of those are partial.

### State machine
- **Upstream** has dense interlocking flags: `lastSigintTime` (double-Ctrl-C exits), `lastEscapeTime` (double-Escape opens tree/fork based on setting), `isBashMode` (color border green), `streamingComponent` + `streamingMessage` (assistant accumulator), `pendingTools` (map of toolCallId → component), `compactionQueuedMessages`, `pendingBashComponents` (move from pending to chat on submit), `autoCompactionLoader` + `autoCompactionEscapeHandler`, `retryLoader` + `retryCountdown` + `retryEscapeHandler`, `extensionSelector`/`extensionInput`/`extensionEditor`, `extensionWidgetsAbove`/`Below`, `customFooter`, `customHeader`, `builtInHeader`, `shutdownRequested`, `startupNoticesShown`, `anthropicSubscriptionWarningShown`, `hideThinkingBlock`, `toolOutputExpanded`, `skillCommands`, `workingVisible`/`workingMessage`/`workingIndicatorOptions`/`hiddenThinkingLabel`. 17+ distinct UI-relevant state fields beyond the editor + selectors.
- **pi-zig** has 9 state fields beyond editor + transcript: `status`, `running`, `awaiting_permission`, `abort_requested`, `streaming` (ArrayList(u8) instead of structured component), `palette_active`/`palette_selected`, `model_selector_active`/`selected_model`. No double-key timing, no extension state, no compaction state, no retry state, no per-tool-id pending tracking.

---

## 5. Theme system

### Upstream (`theme/theme.ts`, 1227 LoC)
- **Schema** (`ThemeJsonSchema`, lines 29–100): 49 required color tokens + optional `vars` dictionary + optional `export` (pageBg/cardBg/infoBg for HTML export).
- **`Theme` class** (lines 322–421):
  - Reads truecolor capability from `getCapabilities().trueColor`, falls back to 256-color.
  - Builds a `Map<ThemeColor, string>` of pre-computed `\x1b[38;2;R;G;Bm` (truecolor) or `\x1b[38;5;Nm` (256-color) escapes.
  - `fg(color, text) → "<escape><text>\x1b[39m"` (foreground reset only, preserves bg).
  - `bg(color, text) → "<escape><text>\x1b[49m"` (background reset only).
  - `bold`, `italic`, `underline`, `inverse`, `strikethrough` via `chalk`.
  - `getThinkingBorderColor(level)` maps off/minimal/low/medium/high/xhigh → 6 dedicated theme colors.
  - `getBashModeBorderColor` → `bashMode` token.
- **Variable resolution** (`resolveVarRefs`, lines 289–306): recursive, with `visited` set for cycle detection.
- **Color quantization** (`rgbTo256`, lines 221–252): finds closest 6×6×6 cube vs 24-step gray ramp, weighted Euclidean (0.299R + 0.587G + 0.114B), prefers cube unless the source RGB has spread<10 AND grayscale is closer.
- **Built-in themes** (lines 427–440): `dark.json` and `light.json` embedded via filesystem read at first use.
- **Custom themes** (lines 480–502): scanned from `~/.pi/agent/themes/*.json`, parsed via `loadThemeFromPath`, registered.
- **Resource-loader themes** (line 769): `setRegisteredThemes` accepts themes from extensions/skills/prompts/themes package sources.
- **File watcher** (lines 829–909): `startThemeWatcher` watches `~/.pi/agent/themes/<currentTheme>.json` with `chokidar`-style debounce, reloads on change, fires `onThemeChangeCallback`.
- **Global access** (lines 743–760): theme stored on `globalThis` so both `tsx` and `jiti` module loaders share one instance. The `theme` export is a `Proxy` that reads from globalThis on every access.
- **Terminal background detection** (lines 633–737): reads `COLORFGBG` env var, parses OSC 11 background queries, returns `"dark"|"light"`.
- **Markdown theme** (`getMarkdownTheme`, lines 1163–1200): maps the 10 md* tokens + bold/italic/underline/strike + `highlightCode` (using the 9 syntax tokens).
- **Editor theme** (`getEditorTheme`, lines 1212–1217): borderColor + selectList.
- **Settings list theme** (`getSettingsListTheme`, lines 1219–1227): label/value/description/cursor/hint formatters.
- **Select list theme** (`getSelectListTheme`, lines 1202–1210): selectedPrefix/selectedText/description/scrollInfo/noMatch.
- **HTML export support** (lines 911–1028): `getResolvedThemeColors`, `isLightTheme`, `getThemeExportColors`, `ansi256ToHex`.
- **Syntax highlighting** (lines 1071–1090): builds a `cli-highlight` theme from the 9 syntax tokens; falls back to plain text if `cli-highlight` can't identify the language.
- **Language detection** (lines 1095–1161): `getLanguageFromPath` maps ~30 file extensions to language names.

### pi-zig
- **`tui_theme.zig` (395 LoC)** — exists as an orphan. Derives ONLY 6 ANSI escape strings (accent/muted/branch/good/warn/code_bg). 43 tokens unported. No truecolor (always 256-color). No `Theme` class, only a `Palette` struct of `[]const u8` slices into a 12-byte buffer per token. No var-ref cycle detection (it has cycle detection in `resolveTo256Inner` lines 207–218, but the cycle set is a 16-slot fixed array — overflows are silently treated as cycles). No file watcher. No registered themes. No COLORFGBG / OSC 11 background detection. **It is not used**: `tui.zig` doesn't import `tui_theme`; the live screen relies on hard-coded `tui.sgr.*` strings (`tui.zig:36–52`) and `tui_messages.sgr.*` (`tui_messages.zig:42–69`).
- **`themes.zig` (1441 LoC)** — implements the `pi themes` CLI subcommand (list, --export, --detect, JSON output) and embeds the upstream JSON. It does NOT expose a runtime palette to the TUI. Only `builtinThemeBytes(name) -> ?[]const u8` is consumed by `tui_theme.zig`.
- **Markdown theme**: not implemented. `tui_messages.zig` renders assistant/user/branch/compaction/custom text as plain styled lines with no markdown parsing. The 10 md* tokens are unimplemented.
- **Editor theme**: not implemented. `tui_editor.zig` has no border-color or select-list theme integration.
- **Settings list theme**: not implemented (no `/settings`).
- **Select list theme**: implemented in `tui_selector.SelectList` as `palette: tui_theme.Palette`, but `tui.zig` never instantiates `SelectList`.
- **HTML export support**: `html_export.zig` exists (79 KB), but only the CLI export path uses it; runtime theme integration is unported.
- **Syntax highlighting**: not implemented anywhere.
- **Terminal background detection**: not implemented.

### Theme reload
- **Upstream**: `interactive-mode.ts:684–688` registers `onThemeChange(() => { this.ui.invalidate(); this.updateEditorBorderColor(); this.ui.requestRender(); })`. `theme.ts:829–909` runs an fs.watch on `~/.pi/agent/themes/<name>.json`.
- **pi-zig**: no theme reload. Switching themes requires restarting with `PI_THEME=<name>` (tui_theme.zig:155–159). The `/theme` slash command exists in the upstream builtin list (tui.zig:60–82) but isn't in pi-zig's builtin_commands array (`pi-zig`'s list omits it).

### Light/dark switching
- **Upstream**: `/settings` → Theme → live preview on selection change (`settings-selector.ts:336–358`), Escape restores original.
- **pi-zig**: not implemented.

---

## 6. Honest parity estimate

### Component reach (Section 2)
Counts from the table above:
- **0 of 35** components have a fully reachable Zig port → **0% full**.
- **3 of 35** have a partial reachable port (footer, dynamic-border, model-selector) → **8.6% partial-reach**.
- **8 of 35** orphan ports exist with tests but never reach the live screen.
- **24 of 35** are completely missing.

If we count "any equivalent code exists in src/pi/" (including orphans), pi-zig has implementation for **11 of 35 = 31% surface coverage**. If we count "reaches the live screen with comparable behavior", it's **3 of 35 = 8.6%**.

### Behavior fidelity (Section 3)
On the 3 reachable ports, scoring against upstream behavior breadth:
- `footer.ts`: pi-zig renders 5 of upstream's ~12 footer features (pwd/branch line, token counts × 4, cost, context%, extension statuses, model+thinking, provider parens, sub-indicator, color thresholds). → ~30%.
- `dynamic-border.ts`: pi-zig has a fixed-width 80-char rule, upstream uses terminal width and accepts a color callback. → ~50%.
- `model-selector.ts`: pi-zig renders 2-line overlay with no search, no scope, no scroll, no persistence. Of upstream's ~12 features, ~2. → ~17%.

Reachable-behavior parity = (0.30 + 0.50 + 0.17) / 35 ≈ **2.8%**.

### Controller methods (Section 4)
Upstream has 150 methods on `InteractiveMode`. pi-zig `App` has ~45 methods, of which ≤25 implement something upstream does. → **≤17%** controller-method parity.

### Theme system (Section 5)
- Schema tokens consumed: 6 of 49 = **12.2%**.
- Truecolor: missing.
- Var-ref recursion + cycle detection: present but with 16-slot ceiling.
- Custom themes: missing.
- File watcher: missing.
- Markdown / syntax / editor / settings / selectlist themes: missing.
- HTML export integration: separately wired in `html_export.zig`, not via runtime theme.
- COLORFGBG / OSC 11 detection: missing.
- `/theme` command: missing from builtin_commands list.
- Theme reload: missing.

Theme-system parity ≈ **10%** (driven by the 6/49 token coverage and missing reload/watch/markdown).

### Combined estimate (weighted)
Using the deliverable's example math style:
- 35 upstream component files; 11 have any pi-zig code = **31% surface coverage**.
- Of those 11, only 3 reach the live screen with comparable behavior = **8.6% effective coverage**.
- Of those 3, ~30% / ~50% / ~17% behavior fidelity averages to **~32% of their own scope** = ~3 / 35 = **2.8% behavior-faithful coverage**.
- Controller-state-machine parity: 25 / 150 = **17%**, but most are partial → effective controller parity ~**10%**.
- Theme parity: **~10%**.

**Overall interactive-TUI parity: 8% to 10%** if we average "code-exists" surface (31%), "reaches-screen" behavior (3%), controller (10%), and theme (10%). The honest number is **~10% parity**.

This is consistent with the broader pi-zig posture: the runtime, RPC, session store, agent loop, settings, models registry, and HTML export are solidly ported (Section 1.x of `docs/parity.md`), but the interactive TUI is essentially still the same composer + transcript shell, with three "satellite" modules (`tui_messages.zig`, `tui_theme.zig`, `tui_selector.zig`) that were written speculatively and never wired into the live `App`.

---

## File:line references (for follow-up tasks)

- pi-zig orphan modules to wire up before claiming any of their parity:
  - `/Users/keer/projects/pi-zig/src/pi/tui_messages.zig:1–965` (all 8 renderers)
  - `/Users/keer/projects/pi-zig/src/pi/tui_theme.zig:1–395` (Palette init)
  - `/Users/keer/projects/pi-zig/src/pi/tui_selector.zig:1–272` (SelectList)
- pi-zig index that doesn't expose the orphan modules:
  - `/Users/keer/projects/pi-zig/src/pi/index.zig:1–62` (omits `tui_messages`, `tui_theme`, `tui_selector`)
- pi-zig live screen that bypasses the orphans:
  - `/Users/keer/projects/pi-zig/src/pi/tui.zig:362–490` (buildScreen)
  - `/Users/keer/projects/pi-zig/src/pi/tui.zig:1024–1056` (executePrompt emits flat transcript lines)
- pi-zig footer that's the only reached `tui_*` module:
  - `/Users/keer/projects/pi-zig/src/pi/tui_footer.zig:208–326` (render + renderStatusRow)
- Upstream controller anchors:
  - `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/modes/interactive/interactive-mode.ts:359–697` (constructor + init)
  - `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/modes/interactive/interactive-mode.ts:2376–2643` (setupKeyHandlers + setupEditorSubmitHandler)
  - `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/modes/interactive/interactive-mode.ts:2651–2997` (handleEvent state machine)
  - `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/modes/interactive/interactive-mode.ts:3825–4611` (selector framework)
- Upstream theme anchors:
  - `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/modes/interactive/theme/theme.ts:29–100` (ThemeJsonSchema)
  - `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/modes/interactive/theme/theme.ts:221–252` (rgbTo256)
  - `/Users/keer/projects/pi-zig/upstream/pi/packages/coding-agent/src/modes/interactive/theme/theme.ts:829–909` (startThemeWatcher)

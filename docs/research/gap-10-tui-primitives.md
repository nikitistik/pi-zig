# gap-10: TUI primitives — upstream `earendil-works/pi` vs. `pi-zig`

Read-only audit (branch `codex/pi-zig-progress`). Scope: every public surface
under `upstream/pi/packages/tui/src/**` and the corresponding `src/pi/tui*.zig`
modules in pi-zig.

- Upstream tree (LoC totals, source-of-truth files actually read):
  - `tui.ts` 1319 · `terminal.ts` 420 · `keys.ts` 1400 · `keybindings.ts` 244
  - `editor-component.ts` 74 · `fuzzy.ts` 137 · `kill-ring.ts` 46
  - `native-modifiers.ts` 59 · `stdin-buffer.ts` 434 · `terminal-image.ts` 453
  - `undo-stack.ts` 28 · `utils.ts` 1140 · `autocomplete.ts` 783
  - `components/editor.ts` 2292 · `components/markdown.ts` 797
  - `components/input.ts` 503 · `components/select-list.ts` 229
  - `components/settings-list.ts` 250 · `components/box.ts` 137
  - `components/loader.ts` 92 · `components/cancellable-loader.ts` 40
  - `components/image.ts` 126 · `components/text.ts` 106
  - `components/spacer.ts` 28 · `components/truncated-text.ts` 65
  - Upstream `index.ts` 106 (the public façade)
  - **Total**: ~15.3k LoC visible-surface (pure logic only — not counting the
    `marked` parser dep, the native modifier helper, or `get-east-asian-width`).

- pi-zig tree (LoC, files inspected):
  - `tui.zig` 2156 (app shell, not "the TUI primitives package")
  - `tui_editor.zig` 646 · `tui_keys.zig` 384 · `tui_render.zig` 249
  - `tui_terminal.zig` 101 · `tui_fuzzy.zig` 434 (fuzzy + NFKC fold)
  - `tui_markdown.zig` 1136 (block + inline markdown → ANSI, no marked dep)
  - `tui_selector.zig` 272 (SelectList port — items + scroll math)
  - `tui_footer.zig` ~358 (no upstream peer in this gap)
  - `tui_messages.zig` ~700 (transcript renderers, not a primitive package)
  - `tui_theme.zig` ~258 (palette helpers)
  - **Total ported "primitive" code (editor + keys + render + terminal +
    fuzzy + markdown + selector)**: ~3.3k LoC vs upstream ~15.3k.

---

## 1. Per-file inventory & mapping

Format: `upstream symbol → pi-zig equivalent (file:line, or `(MISSING)`)`.

### 1.1 `index.ts` (public exports — the contract every consumer reads against)

| Upstream public export | Pi-zig equivalent | Status |
|---|---|---|
| `AutocompleteItem`, `AutocompleteProvider`, `AutocompleteSuggestions`, `CombinedAutocompleteProvider`, `SlashCommand` | — | **MISSING** (no autocomplete provider; only the static `builtin_commands` slash list in `tui.zig:60` and palette UI) |
| `Box` | — | **MISSING** |
| `CancellableLoader` | — | **MISSING** |
| `Editor`, `EditorOptions`, `EditorTheme` | `tui_editor.Editor` (logic only) | partial — no theming, no render method |
| `Image`, `ImageOptions`, `ImageTheme` | — | **MISSING** |
| `Input` | — | **MISSING** (single-line input class) |
| `Loader`, `LoaderIndicatorOptions` | — | **MISSING** |
| `Markdown`, `MarkdownTheme`, `DefaultTextStyle` | `tui_markdown.render` + `renderInlineLine` | partial — see §3.7 (block subset covered, no tables, no OSC-8) |
| `SelectList`, `SelectItem`, `SelectListLayoutOptions`, `SelectListTheme`, `SelectListTruncatePrimaryContext` | `tui_selector.SelectList` (+ inline palette/model overlays in `tui.zig:588`/`:607`) | partial — single-column list with scroll + wrap-around + descriptions appended after label; **no two-column description layout, no theme struct, no filter typing, no `truncatePrimary` callback, no layout-options struct** |
| `SettingsList`, `SettingItem`, `SettingsListTheme` | — | **MISSING** |
| `Spacer` | — | **MISSING** |
| `Text` | — | **MISSING** |
| `TruncatedText` | — | **MISSING** |
| `EditorComponent` interface | — | **MISSING** |
| `FuzzyMatch`, `fuzzyFilter`, `fuzzyMatch` | `tui_fuzzy.FuzzyMatch`, `tui_fuzzy.fuzzyFilter`, `tui_fuzzy.fuzzyMatch` | **PORTED** (with NFKC/diacritic fold parity beyond ASCII) |
| `getKeybindings`, `Keybinding`, `KeybindingConflict`, `KeybindingDefinition`, `KeybindingDefinitions`, `Keybindings`, `KeybindingsConfig`, `KeybindingsManager`, `setKeybindings`, `TUI_KEYBINDINGS` | `tui_keys.default_bindings` (flat constant only), `tui_keys.matches`, `tui_keys.lookupBinding` | partial — no user-config layering, no conflict detection, no per-instance `KeybindingsManager`, no declaration-merging for downstream `Keybindings` |
| `decodeKittyPrintable`, `isKeyRelease`, `isKeyRepeat`, `isKittyProtocolActive`, `Key`, `KeyEventType`, `KeyId`, `matchesKey`, `parseKey`, `setKittyProtocolActive` | `tui_keys.decode`, `tui_keys.matchesKey`, `tui_keys.sequences` | partial — **no Kitty protocol at all**; `parseKey` direction only (no `Key` helper object); no event types |
| `StdinBuffer`, `StdinBufferEventMap`, `StdinBufferOptions` | `tui_keys.sequences` iterator (very thin slice of upstream behaviour) | partial — see §3.6 |
| `ProcessTerminal`, `Terminal` interface | `tui_terminal.RawMode`, `tui_terminal.querySize`, `tui_terminal.readNonblocking` | partial — see §3.5 |
| `allocateImageId`, `calculateImageRows`, `CellDimensions`, `deleteAllKittyImages`, `deleteKittyImage`, `detectCapabilities`, `encodeITerm2`, `encodeKitty`, `getCapabilities`, `getCellDimensions`, `getGifDimensions`, `getImageDimensions`, `getJpegDimensions`, `getPngDimensions`, `getWebpDimensions`, `hyperlink`, `ImageDimensions`, `ImageProtocol`, `ImageRenderOptions`, `imageFallback`, `renderImage`, `resetCapabilitiesCache`, `setCapabilities`, `setCellDimensions`, `TerminalCapabilities` | — | **MISSING** (no terminal-image module at all) |
| `Component`, `Container`, `CURSOR_MARKER`, `Focusable`, `isFocusable`, `OverlayAnchor`, `OverlayHandle`, `OverlayMargin`, `OverlayOptions`, `SizeValue`, `TUI` | `tui.App` (monolithic shell, see §3.1) | partial — no component tree, no overlay stack, no focus model, no `CURSOR_MARKER` IME positioning, no synchronized-output guard |
| `truncateToWidth`, `visibleWidth`, `wrapTextWithAnsi` | — | **MISSING** |

### 1.2 `tui.ts` (1319 LoC: render loop, overlays, IME cursor, Kitty images)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `Component` interface (`render`, `handleInput`, `wantsKeyRelease`, `invalidate`) | — | **MISSING** (no component contract) |
| `Focusable` + `isFocusable()` | — | **MISSING** |
| `CURSOR_MARKER` (APC `\x1b_pi:c\x07`) | — | **MISSING** |
| `Container` class (`addChild`/`removeChild`/`clear`/`invalidate`/`render`) | — | **MISSING** |
| `OverlayAnchor` / `OverlayMargin` / `OverlayOptions` / `OverlayHandle` | — | **MISSING** |
| `parseSizeValue()` (number or `"50%"`) | — | **MISSING** |
| `TUI.start()` / `TUI.stop()` (cursor, alt-screen, kitty cell-size query, stdin pipeline) | `tui.App.run` (`tui.zig:1133`) | partial — does raw-mode + `hide_cursor`/`show_cursor`/`clear_to_end`; no kitty cell-size probe, no alt-screen toggle, no SIGWINCH refresh |
| `setFocus`/`focusedComponent` | — | **MISSING** |
| `showOverlay()` / `hideOverlay()` / overlay stack with `focusOrder` & `nonCapturing` | — | **MISSING** (model selector + palette are inline branches in `buildScreen`) |
| `addInputListener()` / `removeInputListener()` | — | **MISSING** |
| `consumeCellSizeResponse()` (`ESC[6;h;wt`) | — | **MISSING** |
| `requestRender({force})` + `renderTimer` + `MIN_RENDER_INTERVAL_MS` (16 ms) | — | **MISSING** (every keystroke calls `renderer.render` synchronously) |
| `doRender()` differential pipeline (first/full/partial/append/shrink branches) | `tui_render.Renderer.render` (`tui_render.zig:71`) | partial — supports only "same line count → diff" and "line count change → full repaint"; no viewport handling, no scrollback awareness, no append-without-clear, no kitty image deletion |
| `compositeOverlays()` (z-order, anchor, margins, percentage layout) | — | **MISSING** |
| `compositeLineAt()` (slice-aware splice, width verification, crash log on overflow) | — | **MISSING** |
| `extractCursorPosition()` (find APC marker, calculate visible col) | — | **MISSING** |
| `positionHardwareCursor()` (IME-aware cursor placement) | — | **MISSING** (the pi-zig "cursor" is a literal `\|` character inserted into the editor line — `tui.zig:463`) |
| `fullRender()` with `\x1b[?2026h` / `\x1b[?2026l` synchronized output | — | **MISSING** (no synchronized-output wrapping; risk of tearing on macOS Terminal) |
| `applyLineResets()` (normalizes and appends `\x1b[0m\x1b]8;;\x07` per line) | — | **MISSING** (pi-zig relies on each renderer to balance SGR per-line, which is policy-only) |
| `extractKittyImageIds()` / `collectKittyImageIds()` / `deleteKittyImages()` / `expandLastChangedForKittyImages()` | — | **MISSING** |
| `PI_HARDWARE_CURSOR`, `PI_CLEAR_ON_SHRINK`, `PI_DEBUG_REDRAW`, `PI_TUI_DEBUG`, `PI_TUI_WRITE_LOG` env switches | — | **MISSING** |
| Termux height-change special case (`isTermuxSession`) | — | **MISSING** |
| Crash log path (`~/.pi/agent/pi-crash.log`) when a rendered line exceeds terminal width | — | **MISSING** (no width check; over-long line would corrupt the terminal silently) |

### 1.3 `terminal.ts` (420 LoC)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `Terminal` interface (`start`, `stop`, `drainInput`, `write`, `columns`, `rows`, `kittyProtocolActive`, `moveBy`, `hideCursor`, `showCursor`, `clearLine`, `clearFromCursor`, `clearScreen`, `setTitle`, `setProgress`) | `tui_terminal.RawMode` + `tui_terminal.querySize` + `tui_terminal.hide_cursor`/`show_cursor`/`clear_screen`/`clear_to_end` | partial — no `Terminal` abstraction; no `drainInput`, no `setTitle`, no `setProgress` (`OSC 9;4`), no `moveBy` cursor relative motion API |
| `ProcessTerminal` class (raw-mode setup, resize hook, bracketed paste enable `ESC[?2004h`/`l`, Kitty proto probe `ESC[?u` → `ESC[>7u`, modifyOtherKeys fallback `ESC[>4;2m`, Windows VT input native helper, Apple Terminal Shift+Enter normalization, SIGWINCH on resume) | `tui_terminal.RawMode.enable` | partial — only raw-mode; **no bracketed paste, no Kitty probe, no modifyOtherKeys, no Windows console mode, no SIGWINCH refresh, no Apple-Terminal Shift+Enter sequence (`\x1b[13;2u`) injection, no `PI_TUI_WRITE_LOG`** |
| `isAppleTerminalSession()` / `normalizeAppleTerminalInput()` | — | **MISSING** |
| `setKittyProtocolActive`/`isKittyProtocolActive` shared global | — | **MISSING** |
| Progress keep-alive interval (1 s, `OSC 9;4;3`) | — | **MISSING** |
| `drainInput(maxMs, idleMs)` (idle-poll drain after Kitty disable to swallow late release events over SSH) | — | **MISSING** — pi-zig just disables raw mode |

### 1.4 `keys.ts` (1400 LoC: the largest single gap)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `setKittyProtocolActive` / `isKittyProtocolActive` globals | — | **MISSING** |
| Type-level `KeyId` (compile-time-checked) + `Key` helper object (`Key.escape`, `Key.ctrl("c")`, `Key.ctrlShift("p")`, …) | string-only constants in `tui_keys.default_bindings` | partial — runtime strings, no compile-time autocomplete/typo catching |
| `LEGACY_KEY_SEQUENCES` / `LEGACY_SHIFT_SEQUENCES` / `LEGACY_CTRL_SEQUENCES` / `LEGACY_SEQUENCE_KEY_IDS` (≈80 fixed sequences) | `tui_keys.decode` table (≈60 entries) | partial — see §3.4 |
| `KITTY_FUNCTIONAL_KEY_EQUIVALENTS` (numpad → ASCII codepoints, 26 entries) | — | **MISSING** |
| `normalizeKittyFunctionalCodepoint` | — | **MISSING** |
| `normalizeShiftedLetterIdentityCodepoint` | — | **MISSING** |
| `ParsedKittySequence` parser (CSI-u + flag 4 alternate keys) | — | **MISSING** |
| `ParsedModifyOtherKeysSequence` parser (xterm `ESC[27;mod;code~`) | — | **MISSING** |
| `KeyEventType` (`press`/`repeat`/`release`) + `_lastEventType` | — | **MISSING** |
| `isKeyRelease(data)` / `isKeyRepeat(data)` | — | **MISSING** |
| `parseKittySequence()` for arrow/functional/CSI-u with optional `:event` / `:base_layout_key` | — | **MISSING** |
| `parseModifyOtherKeysSequence()` (`ESC[27;m;c~`) | — | **MISSING** |
| `matchesKittySequence()` (with non-Latin layout fallback via `baseLayoutKey`) | — | **MISSING** |
| `matchesModifyOtherKeys()` / `matchesPrintableModifyOtherKeys()` | — | **MISSING** |
| `matchesRawBackspace()` (Windows-Terminal-aware Ctrl+Backspace vs plain Backspace) | — | **MISSING** |
| Apple Terminal `Shift+Enter` (`\x1b[13;2u`) handling | — | **MISSING** |
| `rawCtrlChar(key)` (`code & 0x1f`) | implicit in `tui_keys.decode` for letters | partial — only the letter case, no symbol case (`[`, `\`, `]`, `_`, `-`) and no `ctrl+shift+key` decoding |
| `formatKeyNameWithModifiers()` (build canonical id) | inline `setSynth` in `tui_keys` | partial — only emits `ctrl+letter`, `alt+letter`, `alt+digit`, `ctrl+alt+letter`; **no `super+`, no `shift+letter`/`shift+ctrl+letter` synthesis** |
| `parseKeyId(keyId)` (split string into modifier flags) | — | **MISSING** |
| `matchesKey(data, keyId)` (full switch over `escape`/`space`/`tab`/`enter`/`backspace`/`insert`/`delete`/`clear`/`home`/`end`/`pageUp`/`pageDown`/`up`/`down`/`left`/`right`/`f1..f12`, each with kitty/modifyOtherKeys/legacy branches) | `tui_keys.matchesKey` | partial — only "decode → equality on the canonical id"; the upstream switch covers ~360 distinct (key, modifier) pairs; pi-zig covers ≈70 |
| `parseKey(data)` returning canonical id | `tui_keys.decode` | partial — see §3.4 |
| `decodeKittyPrintable(data)` (extract printable from CSI-u) | — | **MISSING** |
| `decodeModifyOtherKeysPrintable(data)` (extract from `ESC[27;…`) | — | **MISSING** |
| `decodePrintableKey(data)` (the combined entry the editor uses) | — | **MISSING** |
| `isWindowsTerminalSession()` heuristic | — | **MISSING** |

### 1.5 `keybindings.ts` (244 LoC)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `Keybinding` / `Keybindings` interface (declaration-mergeable) | — | **MISSING** |
| `KeybindingDefinition` / `KeybindingDefinitions` / `KeybindingsConfig` types | `tui_keys.Binding` (struct of id/keys/description) | partial |
| `TUI_KEYBINDINGS` (29 default ids) | `tui_keys.default_bindings` (37 ids — includes app.\*) | parity for tui.editor.\* and tui.input.\* and tui.select.\*; **MISSING**: per-binding default-list of multiple `KeyId`s is supported, but `super+*` keys can never resolve |
| `KeybindingConflict` (detect when one key maps to ≥ 2 bindings) | — | **MISSING** |
| `normalizeKeys(keys)` (dedupe + flatten) | — | **MISSING** |
| `KeybindingsManager` class (`matches`, `getKeys`, `getDefinition`, `getConflicts`, `setUserBindings`, `getUserBindings`, `getResolvedBindings`, `rebuild()`) | global `tui_keys.matches`/`lookupBinding` | partial — **no per-instance manager, no user-bindings overlay, no rebuild on config change** |
| `setKeybindings()` / `getKeybindings()` globals | — | **MISSING** |

### 1.6 `editor-component.ts` (74 LoC)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `EditorComponent` interface (`getText`, `setText`, `handleInput`, `onSubmit`, `onChange`, `addToHistory`, `insertTextAtCursor`, `getExpandedText`, `setAutocompleteProvider`, `borderColor`, `setPaddingX`, `setAutocompleteMaxVisible`) | partial methods on `tui_editor.Editor` (`getText`, `setText`, `insertText`, `addHistory`) | partial — no `handleInput`, no `onSubmit`/`onChange` callbacks, no `setAutocompleteProvider`, no `getExpandedText` (paste-marker expansion), no theming/padding setters |

### 1.7 `fuzzy.ts` (137 LoC)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `FuzzyMatch` / `fuzzyMatch` / `fuzzyFilter` | `tui_fuzzy.FuzzyMatch`/`fuzzyMatch`/`fuzzyFilter` | **PORTED** with documented enhancement: NFKC-aware fold (Latin-1 + Latin-Extended-A diacritics, fullwidth ASCII, ideographic space). Tests in `tui_fuzzy.zig:331-419` cover the same word-boundary/consecutive/swapped-query scoring as upstream. |

### 1.8 `kill-ring.ts` (46 LoC)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `KillRing.push(text, {prepend, accumulate})` | `tui_editor.KillRing.push(allocator, text, prepend, accumulate)` | **PORTED** |
| `KillRing.peek()` | `tui_editor.KillRing.peek` | **PORTED** |
| `KillRing.rotate()` | `tui_editor.KillRing.rotate(allocator)` | **PORTED** |
| `KillRing.length` (getter) | `tui_editor.KillRing.len` | **PORTED** |

### 1.9 `native-modifiers.ts` (59 LoC)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `isNativeModifierPressed(key: "shift" | "command" | "control" | "option")` | — | **MISSING** (loads a darwin `.node` native module to poll real-time modifier state — used so Apple Terminal Shift+Enter detection works) |

### 1.10 `stdin-buffer.ts` (434 LoC)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `StdinBuffer` class with EventEmitter (`data`, `paste`) | `tui_keys.SequenceIterator` (slicing-only) | partial — see §3.6 |
| `isCompleteCsiSequence` (with SGR-mouse detection: `<digits;digits;digits[Mm]`) | `tui_keys.escapeSequenceLen` (CSI: consumes until final byte) | partial — does not buffer across reads, has no special SGR-mouse handling |
| `isCompleteOscSequence` (until `ESC\` or BEL) | — | **MISSING** |
| `isCompleteDcsSequence` (DCS = `ESC P …`) | — | **MISSING** |
| `isCompleteApcSequence` (APC = `ESC _ …`) | — | **MISSING** |
| Bracketed paste accumulator (`ESC[200~ … ESC[201~`) | — | **MISSING** (pi-zig sees the raw bytes; the bracketed-paste markers leak through to the editor as if typed) |
| WezTerm escape-release fixup (`\x1b\x1b` followed by `[`/`]`/`O`/`P`/`_` is split into ESC + new sequence) | — | **MISSING** |
| 10-ms incomplete-sequence flush timer | — | **MISSING** (pi-zig reads non-blocking, so partial sequences are lost — a slow SSH typing a function key can break) |
| High-byte conversion (single byte > 127 → `ESC` + (byte - 128)) | — | **MISSING** |
| `pendingKittyPrintableCodepoint` dedup against legacy printable | — | **MISSING** |

### 1.11 `terminal-image.ts` (453 LoC)

Entire module **MISSING** in pi-zig. Affected surface (every export is gone):

- `ImageProtocol`, `TerminalCapabilities`, `CellDimensions`, `ImageDimensions`
- `getCellDimensions` / `setCellDimensions` (cell-size in px, queried via `ESC[16t`)
- `detectCapabilities` (heuristics for kitty, ghostty, wezterm, iterm2, alacritty, vscode, Windows Terminal, tmux/screen)
- `getCapabilities` / `setCapabilities` / `resetCapabilitiesCache`
- `isImageLine` (detects Kitty `ESC_G` or iTerm2 `ESC]1337;File=` lines)
- `allocateImageId`, `encodeKitty` (chunked 4096-byte base64 with `m=1`/`m=0` continuation), `encodeITerm2`
- `deleteKittyImage` / `deleteAllKittyImages` (`a=d,d=I,i=<id>`)
- `getPngDimensions` / `getJpegDimensions` / `getGifDimensions` / `getWebpDimensions` (parse headers without decoding)
- `getImageDimensions(b64, mimeType)`
- `calculateImageCellSize` / `calculateImageRows` (aspect-ratio aware sizing)
- `renderImage(b64, dims, options)` (dispatches kitty vs. iterm2)
- `hyperlink(text, url)` (OSC 8 wrapping)
- `imageFallback(mimeType, dims, filename)`

### 1.12 `undo-stack.ts` (28 LoC)

| Upstream | Pi-zig | Status |
|---|---|---|
| `UndoStack<S>` (deep-cloned snapshots, multi-level) | `tui_editor.Editor.undo_text` (single-level snapshot) | partial — only the most recent edit is undoable; upstream stores a full LIFO stack and resets it on submit |

### 1.13 `utils.ts` (1140 LoC: the foundational pure-text layer)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `getSegmenter()` (shared `Intl.Segmenter`) | — | **MISSING** (no grapheme segmentation; cursor moves by byte) |
| `visibleWidth(str)` (East-Asian-aware, RGI emoji-aware, regional-indicator-aware, with caching) | — | **MISSING** — no width function at all |
| `normalizeTerminalOutput(str)` (strip BEL inside OSC, normalize line endings) | — | **MISSING** |
| `extractAnsiCode(str, pos)` (CSI, OSC, DCS, APC parser with `length`) | — | **MISSING** |
| `wrapTextWithAnsi(text, width)` (preserve ANSI across line breaks) | `tui_render.wrapLine` (byte-based, no ANSI awareness) | partial — wraps on byte count and assumes no embedded SGR; would split escape sequences mid-byte if used on styled text |
| `isWhitespaceChar(ch)` | inline in `tui_editor.isWhitespace` (`' '`, `\t`, `\r`, `\n`, `\x0b`, `\x0c`) | partial — upstream regex covers all Unicode whitespace; pi-zig only ASCII |
| `isPunctuationChar(ch)` | inline in `tui_editor.isPunctuation` (29 ASCII chars) | partial — byte-equality only |
| `applyBackgroundToLine(line, width, bgFn)` | — | **MISSING** |
| `truncateToWidth(text, maxWidth, ellipsis, pad)` | — | **MISSING** |
| `sliceByColumn(line, startCol, length, strict)` | — | **MISSING** |
| `sliceWithWidth(line, startCol, length, strict)` | — | **MISSING** |
| `extractSegments(line, startCol, afterStart, afterWidth, strict)` | — | **MISSING** |

### 1.14 `autocomplete.ts` (783 LoC)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `AutocompleteItem`, `AutocompleteProvider`, `AutocompleteSuggestions`, `SlashCommand` | — | **MISSING** |
| `CombinedAutocompleteProvider` (slash commands + `@` path completion + `~/` expansion + quoted prefix + fd-based fuzzy walk with `.gitignore` honoring + scope-aware path completion) | — | **MISSING** — pi-zig has only an inline fuzzy-filter over the static `builtin_commands` array (`tui.zig:101 filterCommands`) |
| `buildFdPathQuery`, `walkDirectoryWithFd` (spawn `fd` with `--full-path`, etc.) | — | **MISSING** |
| `findLastDelimiter`, `findUnclosedQuoteStart`, `extractQuotedPrefix`, `parsePathPrefix`, `buildCompletionValue` | — | **MISSING** |
| `getSuggestions`, `applyCompletion`, `shouldTriggerFileCompletion` | — | **MISSING** |

### 1.15 `components/editor.ts` (2292 LoC: the visual editor wrapping the buffer)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `wordWrapLine(line, maxWidth, preSegmented?)` (word-aware wrap with back-tracking + atomic-segment re-wrap for paste markers wider than the column) | — | **MISSING** |
| `EditorTheme`, `EditorOptions` (borderColor, selectList theme, paddingX, autocompleteMaxVisible) | — | **MISSING** |
| `Editor` class — the **render** path | — | **MISSING** (pi-zig draws `> ` + line + `\|` caret inline in `tui.zig:455-471`; no border, no scroll indicator, no wrapping, no theme) |
| `layoutText` (multi-line + word-wrap to layout lines) | — | **MISSING** |
| `buildVisualLineMap` / `findVisualLineAt` / `findCurrentVisualLine` (visual-line index for vertical navigation) | — | **MISSING** (pi-zig moves cursor only in logical lines — `moveUp`/`moveDown` ignore wrap) |
| `moveToVisualLine` + sticky preferred-column logic + atomic-segment snapping | — | **MISSING** |
| `computeVerticalMoveColumn` (7-case sticky-column decision table) | — | **MISSING** |
| `pageScroll` (`pageUp`/`pageDown` by 30% of terminal rows) | — | **MISSING** — `tui_keys.default_bindings` declares them, but `tui_editor.Editor` has no `pageScroll` method |
| `addNewLine` | `tui_editor.Editor.newLine` | **PORTED** |
| `handlePaste` with the **paste-marker system**: pastes > 10 lines OR > 1000 chars are replaced with `[paste #N +123 lines]` / `[paste #N 1234 chars]`; segmenter merges those into atomic segments for cursor/word movement; `getExpandedText()` expands markers on submit; submission clears `pastes` | — | **MISSING** (pi-zig has no paste accumulation; the raw bytes go into the editor including `\x1b[200~`/`\x1b[201~` markers) |
| `expandPasteMarkers`, `getExpandedText`, `pastes` map, `pasteCounter` | — | **MISSING** |
| `segmentWithMarkers(text, validIds)` | — | **MISSING** |
| `submitValue` (expands paste markers, clears editor + paste map + undo stack + history-index, fires `onSubmit`) | inline submit in `tui.zig:1299` (no paste expansion, no undo clear) | partial |
| `handleBackspace` (grapheme-aware via `Intl.Segmenter`) | `tui_editor.Editor.deleteCharBackward` (byte-only) | partial — would split a multi-byte codepoint or emoji |
| `handleForwardDelete` | `tui_editor.Editor.deleteCharForward` (byte-only) | partial |
| `moveCursor(deltaLine, deltaCol)` — grapheme-aware with visual-line mapping and history-aware top/bottom behaviour (Up at top of empty editor enters history; Down at bottom of history exits history) | `tui_editor.Editor.moveLeft/Right/Up/Down` (byte-only, no visual-line awareness; up/down only step logical lines) | partial — see §3.2 |
| `moveWordBackwards` / `moveWordForwards` with **paste-marker as atomic word** and **Intl-segmenter graphemes** | `tui_editor.Editor.moveWordLeft/Right` (ASCII bytes only) | partial — fails on emoji, accented letters, and ignores paste markers |
| `deleteToStartOfLine` / `deleteToEndOfLine` with kill-ring accumulation | `tui_editor.Editor.deleteToLineStart` / `deleteToLineEnd` | **PORTED** (close parity) |
| `deleteWordBackwards` / `deleteWordForward` with kill-ring accumulation | `tui_editor.Editor.deleteWordBackward`/`deleteWordForward` | **PORTED** (close parity, modulo byte-vs-grapheme) |
| `yank()` / `yankPop()` (multi-line aware: `insertYankedText`/`deleteYankedText` reconstruct the inserted span) | `tui_editor.Editor.yank` / `yankPop` (via undo restore + rotate) | partial — pi-zig **reuses the single-level undo snapshot to delete the yanked span**, so an interleaved edit between yank and yank-pop would corrupt; upstream computes the inserted region from `yankLines.length` directly |
| `jumpToChar` + `jumpMode` (`Ctrl+]` forward, `Ctrl+Alt+]` backward, multi-line, case-sensitive) | — | **MISSING** |
| `decodePrintableKey` codepath for non-ASCII input | partial (`tui_keys.decode` accepts non-ASCII as printable but doesn't decode CSI-u shifted variants) | partial |
| **Bracketed paste detection** (`\x1b[200~` enters paste mode, `\x1b[201~` exits, content is filtered for control chars except `\n`, re-encoded `\x1b[<n>;5u` Ctrl-letter sequences are turned back into raw control bytes for the per-char filter) | — | **MISSING** |
| **Programmatic** `insertTextAtCursor(text)` (atomic for undo, multi-line aware) | — | **MISSING** (only `insertText` on a single line) |
| **History** (`addToHistory`, `navigateHistory(1|-1)`, max 100, dedupe consecutive) | `tui_editor.Editor.addHistory`/`historyPrev`/`historyNext` | partial — pi-zig has no max-100 cap; upstream prepends on `history.unshift(trimmed)`, pi-zig appends; `historyPrev` walks backward via `history_index -= 1` from `history.len`; behaviour close but the on-empty-editor "up enters history" rule is in `tui.zig:1350` (only at logical line 0, not at first visual line, because there are no visual lines) |
| `onChange` / `onSubmit` callbacks | — | **MISSING** |
| `pushUndoSnapshot` with `structuredClone` (full state) | `tui_editor.Editor.pushUndoSnapshot` (snapshot of text + cursor as a single string) | partial — only one snapshot |
| `setText` / `setTextInternal` (normalize `\r\n`/`\r`/`\t`, fire `onChange`) | `tui_editor.Editor.setText` (split-only, no tab/CR normalization, no onChange) | partial |
| `disableSubmit` flag | — | **MISSING** |
| `shouldSubmitOnBackslashEnter` (`\` + Enter on a Shift+Enter-enabled keymap submits, on others is just newline) | — | **MISSING** |
| `lastAction` coalescing (kill / yank / type-word) | `tui_editor.Editor.last_action` (none / kill / yank) | partial — pi-zig has no `type-word` coalescing for undo, so each printable character creates a fresh undo snapshot if it were a stack (it's not; single-snapshot) |
| Autocomplete UI integration (Tab triggers `handleSlashCommandCompletion`/`forceFileAutocomplete`; live debounce; partial-match indexing; `AbortController` + start/request tokens) | inline palette in `tui.zig:1251` (no debouncing, no async, no AbortController) | partial |
| Border / scroll indicators (`─── ↑ N more ` / `─── ↓ N more `) | — | **MISSING** |
| Hardware cursor marker emit (`CURSOR_MARKER`) | — | **MISSING** |
| Reverse-video fake cursor at the focused position | a literal `\|` character inserted into the line | partial — visible but **not invertible**, takes up a column, can shift wrap |
| `setPaddingX` / `getPaddingX` | — | **MISSING** |

### 1.16 `components/markdown.ts` (797 LoC) — partially ported as `tui_markdown.zig` (1136 LoC)

| Upstream | Pi-zig | Status |
|---|---|---|
| `Markdown` class (stateful component with cache + `render(width)`) | `tui_markdown.render(allocator, text, options)` returning `[][]u8` | partial — function-style instead of class-based; no instance cache |
| `MarkdownTheme` interface (15 styling functions) | inline `tui_markdown.sgr` constants | partial — fixed palette, no caller-overridable theme |
| `DefaultTextStyle` (color, bgColor, bold, italic, strikethrough, underline) | — | **MISSING** |
| `StrictStrikethroughTokenizer` | — | **MISSING** (no `~~` handling) |
| Block tokens: `heading` (depth 1-6) | partial — ATX headers `#..######` parsed | partial — no `#` prefix preserved for h3+, no h1 underline |
| Block tokens: `paragraph`, `text` | parsed + inline-styled | **PORTED** |
| Block tokens: `code` (fenced) | parsed with optional language; dim-background indent | partial — local keyword/string/comment tokenizer for highlighting (no language list match upstream's `highlightCode` callback) |
| Block tokens: `list` (with `start`, nesting, task items `[x]`/`[ ]`) | unordered + ordered with start offset | partial — **no nesting, no task items** |
| Block tokens: `table` | — | **MISSING** (explicitly out of scope, documented in `tui_markdown.zig:32`) |
| Block tokens: `blockquote` | parsed; `│ ` border | partial — **not recursive** (a fenced code inside a blockquote is rendered as raw text) |
| Block tokens: `hr` | parsed | **PORTED** |
| Block tokens: `html`, `space` | — | **MISSING** |
| Inline tokens: `text`, `paragraph`, `strong`, `em`, `codespan`, `del` | `**bold**`, `*italic*`/`_italic_`, `` `code` `` parsed | partial — **no `~~strikethrough~~`** (no `del` token) |
| Inline tokens: `link` `[text](href)` with OSC 8 fallback | parsed as `[text](href)` then formatted to `text (href)` plain-text always | partial — **no OSC 8 hyperlink**, always emits `(href)` even when capable terminal could render the link |
| Inline tokens: `br`, `html` | — | **MISSING** |
| Tables column allocator (`minWordWidths`, `naturalWidths`, weighted growth) | — | **MISSING** |
| Lists: indent per depth, task-marker `[x]`/`[ ]`, ordered `start` offset, prefix vs continuation indent | partial — ordered `start` honored | partial — no nesting depth, no task markers |
| Blockquote: `│ ` border + recursive block rendering | partial border, body is rendered as flat lines | partial |
| `applyBackgroundToLine` for full-width background | — | **MISSING** |
| Top/bottom `paddingY` empty lines | — | **MISSING** (`paddingY` not in options) |
| Sentinel-based `getStylePrefix` for nested SGR restoration | — | **MISSING** |
| Render cache | — | **MISSING** (every call re-parses) |
| `highlightCode` callback | inline tokenizer (keyword/string/comment) shared with `html_export.zig` | partial — fixed grammar, no language-aware highlighter |
| Configurable `codeBlockIndent` | hardcoded 2 spaces | partial |
| East-Asian-aware width / grapheme awareness | byte-based wrap only | partial — same byte-width assumption as the rest of pi-zig |

What pi-zig users actually see: ATX headers (no h1 underline), paragraphs, fenced code blocks (with a basic keyword/string/comment colorer), `-`/`*`/`+` unordered + `1.` ordered single-level lists, blockquotes (non-recursive), HR (`---`), `**bold**`, `*italic*`, `` `inline code` ``, plain-text `text (href)` links. Tables, `~~strike~~`, OSC 8 hyperlinks, task lists, nested lists, nested blockquotes, and HTML are not rendered.

### 1.17 `components/input.ts` (503 LoC) — **ENTIRELY MISSING**

Single-line input with horizontal scrolling, bracketed paste, kill ring, undo, grapheme-aware backspace, word boundary movement, OSC-cursor IME marker, and prompt-aware rendering (`> ` prefix, cursor centered when scrolled). Replacement: none. `SettingsList` upstream uses this for search; pi-zig has no `SettingsList`.

### 1.18 `components/select-list.ts` (229 LoC) — partially ported as `tui_selector.zig` (272 LoC)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `SelectItem` (value, label, description) | `tui_selector.Item` | **PORTED** |
| `SelectListTheme` (`selectedPrefix`, `selectedText`, `description`, `scrollInfo`, `noMatch`) | — | **MISSING** (no theme struct; fixed styling) |
| `SelectListLayoutOptions` (`minPrimaryColumnWidth`, `maxPrimaryColumnWidth`, `truncatePrimary` callback) | — | **MISSING** |
| `SelectList.setFilter`/`setSelectedIndex`/`getSelectedItem` | partial — selectedIndex management & getSelectedItem in `tui_selector.SelectList`; **no `setFilter`** | partial |
| `SelectList.render` (primary-column auto-width + description right-column truncation + scroll indicator `(idx/total)`) | scroll math present (mirrors upstream `Math.min(selected - floor(max/2), total - max)`); descriptions appended after label instead of two-column layout | partial |
| `SelectList.handleInput` (wrap-around up/down, enter confirms, escape cancels) | `tui_selector.SelectList.handleKey` — wrap-around present | **PORTED** |
| `onSelect` / `onCancel` / `onSelectionChange` callbacks | — | **MISSING** (the App polls state instead) |
| filter-by-prefix search-in-list | — | **MISSING** |

### 1.19 `components/settings-list.ts` (250 LoC) — **ENTIRELY MISSING**

Settings-list component with: cycle-through values, submenu support, optional search input, hint footer, description preview. Pi-zig's `/settings` command is wired but reports "not yet wired" (`tui.zig`).

### 1.20 `components/box.ts` (137 LoC) — **ENTIRELY MISSING**

`Box` container with padding, background function, child caching. Pi-zig draws boxes ad-hoc in `tui_messages.zig` using `box.top_left`/`top_right`/etc.

### 1.21 `components/loader.ts` (92 LoC) + `cancellable-loader.ts` (40 LoC)

| Upstream symbol | Pi-zig | Status |
|---|---|---|
| `Loader` class (10-frame braille spinner `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, 80 ms interval, configurable frames/interval) | — | **MISSING** |
| `LoaderIndicatorOptions` | — | **MISSING** |
| `CancellableLoader` (escape → `AbortController.abort()`) | — | **MISSING** |
| `Loader.setMessage` / `setIndicator` / `start` / `stop` | — | **MISSING** |
| `Loader.spinnerColorFn` / `messageColorFn` | — | **MISSING** |

Pi-zig shows a static `"[working... press Esc to abort]"` string while running (`tui.zig:448`).

### 1.22 `components/image.ts` (126 LoC) — **ENTIRELY MISSING**

`Image` component renders kitty / iTerm2 inline images with proper row reservation and cursor-up positioning. Pi-zig has no inline image surface at all.

### 1.23 `components/text.ts` / `spacer.ts` / `truncated-text.ts`

| Upstream | Pi-zig | Status |
|---|---|---|
| `Text` (multi-line with word wrapping, custom background, tab expansion, render cache) | — | **MISSING** |
| `Spacer(lines)` | — | **MISSING** |
| `TruncatedText` (single-line, padding, truncate-to-width with `truncateToWidth`) | — | **MISSING** (the closest analogue is `tui_messages.zig` line-builders that do byte-level truncation only) |

---

## 2. Mapping summary table (one-glance)

| Upstream module | LoC | Pi-zig peer | Parity |
|---|---:|---|---|
| `tui.ts` | 1319 | `tui_render.zig` (renderer only) + `tui.zig` (app shell) | ~5–10% |
| `terminal.ts` | 420 | `tui_terminal.zig` | ~15% |
| `keys.ts` | 1400 | `tui_keys.zig` | ~25% |
| `keybindings.ts` | 244 | `tui_keys.default_bindings` | ~40% |
| `editor-component.ts` | 74 | partial methods on `tui_editor.Editor` | ~25% |
| `fuzzy.ts` | 137 | `tui_fuzzy.zig` | ~100% (+ NFKC) |
| `kill-ring.ts` | 46 | inline `tui_editor.KillRing` | ~100% |
| `native-modifiers.ts` | 59 | — | 0% |
| `stdin-buffer.ts` | 434 | `tui_keys.sequences` | ~15% |
| `terminal-image.ts` | 453 | — | 0% |
| `undo-stack.ts` | 28 | inline `Editor.undo_text` | ~40% |
| `utils.ts` | 1140 | inline byte ops in `tui_render.wrapLine` + `tui_editor.isWhitespace/isPunctuation` | ~3% |
| `autocomplete.ts` | 783 | `tui.filterCommands` (slash only) | ~10% |
| `components/editor.ts` | 2292 | `tui_editor.Editor` (logic only, no render) | ~25% |
| `components/markdown.ts` | 797 | `tui_markdown.zig` | ~50% (no tables, no `del`, no OSC8, no nesting, no theme) |
| `components/input.ts` | 503 | — | 0% |
| `components/select-list.ts` | 229 | `tui_selector.zig` (+ inline palette) | ~55% (no filter, no theme, no two-column layout) |
| `components/settings-list.ts` | 250 | — | 0% |
| `components/box.ts` | 137 | — | 0% (ad-hoc box drawing in `tui_messages.zig`) |
| `components/loader.ts` | 92 | — | 0% |
| `components/cancellable-loader.ts` | 40 | — | 0% |
| `components/image.ts` | 126 | — | 0% |
| `components/text.ts` | 106 | — | 0% |
| `components/spacer.ts` | 28 | — | 0% |
| `components/truncated-text.ts` | 65 | — | 0% |

---

## 3. Gap detail (the deep dives)

### 3.1 Renderer / TUI shell (`tui.ts` → `tui_render.zig` + `tui.zig`)

Upstream `TUI.doRender()` is a 330-line state machine with these distinct branches:

1. **First render**: `previousLines.length === 0 && !widthChanged && !heightChanged` → `fullRender(false)` (no clear).
2. **Width change**: `widthChanged` → `fullRender(true)` (clear scrollback + 2J + H + 3J).
3. **Height change (not Termux)**: `fullRender(true)`.
4. **Content shrunk** (with `clearOnShrink`): `fullRender(true)`.
5. **Differential** with seven sub-cases:
   - `firstChanged >= newLines.length` (all changes in deleted lines → cursor down to last new line, clear extra lines with `\x1b[2K` + `\x1b[1B`).
   - `firstChanged < prevViewportTop` (changed line above viewport → `fullRender(true)`).
   - `moveTargetRow > prevViewportBottom` (scroll the viewport via `\r\n` injection).
   - Normal in-place rewrite (`\x1b[<n>A` / `\x1b[<n>B`, `\r`, `\x1b[2K`, write line; if `previousLines.length > newLines.length` clear extra lines and move back).
   - Each path wrapped in `\x1b[?2026h` … `\x1b[?2026l` synchronized output.

Pi-zig `Renderer.render()` (`tui_render.zig:71`) handles **two** branches:
- Same line count → diff & rewrite changed rows.
- Different line count → move up to top, clear-to-end, rewrite everything.

What pi-zig misses:

- **No synchronized output** (`\x1b[?2026h` / `\x1b[?2026l`) — terminals like Apple Terminal can render mid-frame.
- **No viewport awareness** — pi-zig assumes the entire content is on screen. Once `transcript.items` exceeds rows, upstream computes `viewportTop` and only repaints the visible slice; pi-zig repaints the full buffer.
- **No `\x1b[3J` scrollback clear** on width change.
- **No append-without-clear path** — `appendStart` case in upstream lets streaming a single new line emit just `\r\n<new line>`; pi-zig's count-change branch always does an up-N + clear-to-end + full rewrite (more flicker, more bytes).
- **No Kitty image lifecycle** — `extractKittyImageIds`, `collectKittyImageIds`, `deleteKittyImages` are gone. If images were ever drawn, they'd persist across re-renders.
- **No overlay compositor** (§3.3).
- **No IME cursor positioning** — upstream emits `CURSOR_MARKER` in the rendered line, extracts it via `extractCursorPosition`, strips it, then writes `\x1b[<rowDelta>B/A` + `\x1b[<col+1>G` after the diff so macOS / Linux IMEs can place candidate windows correctly. Pi-zig embeds a literal `\|` character into the editor line — this *shifts* the line width and prevents IME candidate-window placement.
- **No frame rate guard** — upstream has `MIN_RENDER_INTERVAL_MS = 16`, `requestRender({force: false})` schedules via `process.nextTick` + `setTimeout`. Pi-zig calls `renderer.render` synchronously on every keystroke (acceptable, but burns CPU on streaming).
- **No crash log** when a line exceeds terminal width (would silently corrupt).
- **No env switches** (`PI_HARDWARE_CURSOR`, `PI_CLEAR_ON_SHRINK`, `PI_TUI_DEBUG`, `PI_DEBUG_REDRAW`, `PI_TUI_WRITE_LOG`).
- **No `terminal.setProgress(true)`** keep-alive while running.
- **No Termux height-change exception**.

### 3.2 Editor (components/editor.ts → tui_editor.zig + inline render in tui.zig)

Pi-zig has the **buffer + cursor + kill ring + history + single undo** in `tui_editor.zig`. What's missing inside the buffer/cursor logic:

- **Grapheme awareness**. Upstream uses `Intl.Segmenter({granularity: "grapheme"})` everywhere (`segment()`, `segmentWithMarkers`). Pi-zig uses byte offsets. Concrete bugs the byte model produces:
  - Backspace on `é` (0xC3 0xA9) deletes just the trailing byte → invalid UTF-8.
  - Word-left/word-right on a string containing emoji walks into the middle of a multi-codepoint sequence.
  - Cursor right on a wide character (Chinese, emoji) advances one cell visually but two bytes — fine for `getText()` but doesn't match column rendering.
  - Combining diacritics (`e` + U+0301) are two graphemes pre-Intl-segmenter; pi-zig deletes only the combining mark.
- **Word boundaries**: pi-zig's `isWhitespace` covers only ASCII (`' '`, `\t`, `\r`, `\n`, `0x0B`, `0x0C`). Upstream uses `/\s/` (Unicode whitespace) + `Intl.Segmenter`. So ` ` (non-breaking space), `　` (ideographic space), and other Unicode whitespace are treated as word characters by pi-zig.
- **Visual-line vs logical-line up/down**. Upstream `moveCursor(deltaLine, 0)` walks the **visual** line map built by `wordWrapLine`, with a 7-case sticky-column decision table (`computeVerticalMoveColumn`) that handles "clamped to short line", "rewrapped after resize", "preferred column carried forward". Pi-zig moves to the previous/next logical line without considering wrap, so on a long line the user can't navigate within it vertically.
- **Pasted-block markers**. The single most user-visible upstream feature missing: a paste of >10 lines or >1000 chars becomes `[paste #1 +123 lines]` inline. The marker is treated as one atomic grapheme for cursor/word movement, deletion, wrap. `getExpandedText()` swaps it back on submit. Pi-zig has zero handling — the entire pasted block is inserted as raw bytes (plus terminal-injected `\x1b[200~`/`\x1b[201~` brackets that the user sees as literal characters).
- **Bracketed paste mode end-to-end**. Pi-zig has no `\x1b[200~` / `\x1b[201~` detection. The terminal enables bracketed paste in `ProcessTerminal.start()` upstream; pi-zig's terminal doesn't enable it, so the user never gets atomic paste behaviour, and even if they did the editor wouldn't know how to handle the markers.
- **External editor (`$EDITOR`)**. The upstream `tui.editor.opens external` flow isn't actually in `components/editor.ts` itself — it's wired through the slash-command `/edit` — but pi-zig's `app.editor.external` keybinding (`tui_keys.zig:254`, `ctrl+g`) is declared with no handler.
- **Multi-level undo**. Upstream `UndoStack<EditorState>` keeps a LIFO of `structuredClone(state)`. Pi-zig keeps **one** snapshot (`undo_text`/`undo_line`/`undo_col`). After two edits, only the most recent is recoverable.
- **Undo coalescing**. Upstream pushes on whitespace boundary, so "hello world" undoes in two steps; pi-zig pushes only inside `deleteWordBackward` etc. — printable inserts never push, so undo cannot recover printable insertion at all.
- **Yank-pop correctness**. Upstream `yankPop` recomputes the inserted span from `yankLines.length`; pi-zig restores the undo snapshot then inserts the new entry, which is semantically wrong if anything (an unrelated edit) happened between yank and yank-pop — but in practice the immediately-previous behaviour is fine.
- **`jumpToChar`** (Ctrl+] / Ctrl+Alt+] forward/backward character search, multi-line, case-sensitive). Declared in upstream `TUI_KEYBINDINGS`, also declared in `tui_keys.default_bindings`, but **the editor handler is missing in pi-zig** (`tui_editor.zig` has no `jumpToChar`).
- **`pageScroll`** (PageUp/PageDown by 30% of terminal rows). Keybinding declared (`tui_keys.default_bindings`), but `tui_editor.Editor` has no `pageScroll` method, and `tui.zig dispatchKey` has no `pageUp`/`pageDown` branch.
- **Autocomplete hookup**. Upstream's editor owns a `SelectList` autocomplete dropdown, debounce-timer, AbortController, request-token ordering, and `applyCompletion` integration. Pi-zig has palette-only completion (no `@`-path completion, no async fd walks).
- **Rendering**. Upstream `render(width)` produces a 1-pixel-perfect bordered editor with scroll indicators (`─── ↑ N more ` / `─── ↓ N more `), padding, reverse-video cursor, hardware-cursor IME marker, autocomplete list below. Pi-zig draws `> ` + the editor line + a literal `\|` character (`tui.zig:455-471`). No border, no scroll indicator, no padding, no theme.

### 3.3 Overlay / focus model (only upstream)

Upstream tracks an `overlayStack[]` with `{ component, options, preFocus, hidden, focusOrder }`. Calling `tui.showOverlay(component, options)` returns a handle with `hide`, `setHidden`, `focus`, `unfocus`, `isFocused`. The overlay can be:

- Sized in cells (`width: 80`) or percent (`width: "50%"`).
- Anchored (`center` / `top-left` / `bottom-right` / 9 positions), offset, percent-positioned, margin-constrained.
- Visibility-gated (`visible: (cols, rows) => boolean` callback — auto-hides on small terminals).
- Non-capturing (won't take focus).
- Compositied above the base content via `compositeLineAt(baseLine, overlayLine, startCol, overlayWidth, totalWidth)` which:
  - Slice-extracts the base into before/overlay-span/after segments.
  - Pads each segment to its target width.
  - Composes with `\x1b[0m\x1b]8;;\x07` resets between segments to prevent SGR/OSC bleed.
  - Verifies final width and force-truncates if drift occurred.
- Focus restored on hide via `preFocus`; or to the topmost remaining visible overlay; or to `preFocus` if none.

Pi-zig has **two** ad-hoc inline overlays (`palette_active` and `model_selector_active` in `tui.zig`). Both append lines to the editor screen output. Neither composites, anchors, sizes by percent, supports hidden state, or stacks. The model selector and palette are mutually exclusive (one of two booleans).

### 3.4 Key parsing (the biggest single LoC gap)

Upstream `keys.ts` is **1400 LoC**; pi-zig `tui_keys.zig` is **384 LoC** (of which ~100 is tests and ~100 is the binding table).

What pi-zig **does** parse (from `tui_keys.decode`):

- Bare control bytes 0x01..0x1A → `ctrl+<letter>` (a..z).
- 0x1B → `escape`; 0x1C/0x1D/0x1F → `ctrl+\`/`]`/`-`.
- ESC + control byte → `ctrl+alt+<letter>` (a..z).
- ESC + letter/digit → `alt+<letter/digit>`.
- ESC ESC → `ctrl+alt+[`.
- Exact strings for arrows `\x1b[A/B/C/D`, home/end, delete/insert/pageUp/pageDown, F-key names by `\x1bOP`/`\x1bOQ`/etc., `\x1b[Z` → `shift+tab`, modified arrows `\x1b[1;5D` (ctrl+left), `\x1b[1;3D` (alt+left), `\x1b[1;2A` (shift+up).
- Plain printable ASCII 0x20..0x7E → returned as `printable` + id = the byte itself.
- Multi-byte UTF-8 (not starting with ESC and not control) → `printable` (no id).

What pi-zig **does not** parse (every item below is a real entry in upstream `LEGACY_KEY_SEQUENCES`/`LEGACY_SHIFT_SEQUENCES`/`LEGACY_CTRL_SEQUENCES` and is matched in `matchesKey`):

- `\x1bOA/B/C/D` SS3 arrow variants (some terminals send these instead of `\x1b[A/B/C/D`).
- `\x1b[1~` (home), `\x1b[4~` (end), `\x1b[7~`, `\x1b[8~` (alternate home/end).
- `\x1b[a/b/c/d` shift+arrow legacy, `\x1bOa/b/c/d` ctrl+arrow legacy.
- `\x1b[2$/3$/5$/6$/7$/8$` shift+functional, `\x1b[2^/3^/5^/6^/7^/8^` ctrl+functional.
- `\x1b[E`/`\x1bOE`/`\x1bOe`/`\x1b[e` clear/shift+clear/ctrl+clear.
- `\x1b[F5..F12]` (`\x1b[15~` to `\x1b[24~`) function keys 5–12.
- `\x1b[[A/B/C/D/E` rxvt-style F1–F5.
- `\x1bb/f/p/n` alt+left/right/up/down (Mac Terminal's default emacs mode).
- `\x1bB/F` upper-case Apple Terminal alt-arrow variants.
- `\x1bOM` numpad enter.
- The full **Kitty keyboard protocol** (CSI-u format):
  - `\x1b[<codepoint>u` / `;<mod>u` / `:<event>u` / `:<shifted>;<mod>u` / `:<shifted>:<base>;<mod>u` / `::<base>;<mod>u`.
  - 26 numpad → ASCII codepoint equivalences (`KP_0..KP_9`, `KP_DECIMAL`, etc.).
  - Modifier mask bit-decode (shift=1, alt=2, ctrl=4, super=8, caps-lock=64, num-lock=128).
  - Event-type byte (`:1` press, `:2` repeat, `:3` release).
  - `baseLayoutKey` fallback so Ctrl+С (Cyrillic) matches Ctrl+c (Latin).
  - `_lastEventType` global for `isKeyRelease`/`isKeyRepeat` queries.
  - `decodeKittyPrintable` for printable keys typed under flag 1 (disambiguate).
- **xterm `modifyOtherKeys` mode 2** (`\x1b[27;<mod>;<keycode>~`), which tmux and others fall back to when Kitty isn't supported.
- **Apple Terminal Shift+Enter** (`\x1b[13;2u`) injection — `normalizeAppleTerminalInput` rewrites `\r` to this when Apple Terminal is detected via TERM_PROGRAM and the native modifier helper reports Shift held.
- **Windows Terminal Ctrl+Backspace** (raw 0x08 disambiguated from Ctrl+H by `isWindowsTerminalSession()`).
- `super+` modifier handling (Cmd on macOS, Win on Windows).
- `shift+letter` synthesis — pi-zig accepts `A` as a printable character but never returns `shift+a` even when the kitty event reports it.
- `ctrl+shift+letter` — pi-zig has no codepath for this combination.
- `ctrl+digit` / `shift+digit` — only modifier-name digits work in pi-zig's binding table.
- The non-Latin-layout fallback (`baseLayoutKey`) — pi-zig has no concept of base layout, so a Russian/Greek/etc. keyboard cannot trigger `ctrl+c`.
- IME composition: upstream relies on the kitty/xterm protocols + `CURSOR_MARKER` placement to give the OS IME the cursor position; pi-zig has neither, so candidate windows place at the upper-left of the terminal.
- Paste mode: pi-zig has no idea bracketed paste exists.

The practical effect: pi-zig handles **legacy non-Kitty input only**, and only the most common subset. Anyone running kitty, ghostty, wezterm, foot, or any terminal with Kitty protocol pushed will see arrow keys / function keys / modified keys behave oddly because the CSI-u sequences don't decode at all and fall through to "ignored or treated as printable".

### 3.5 Terminal abstraction (`terminal.ts` → `tui_terminal.zig`)

Upstream `ProcessTerminal.start()` does, in order:

1. Save previous raw mode flag, `setRawMode(true)`.
2. `setEncoding('utf8')`, `stdin.resume()`.
3. Enable bracketed paste mode (`\x1b[?2004h`).
4. Install resize handler on `process.stdout`.
5. SIGWINCH self-kill (Unix-only) to refresh stale dimensions after a Ctrl+Z resume.
6. Windows VT-input native helper (`win32-console-mode.node`) — toggles `ENABLE_VIRTUAL_TERMINAL_INPUT` on stdin so Shift+Tab actually sends `\x1b[Z`.
7. Kitty protocol probe: send `\x1b[?u`, wait for `\x1b[?<flags>u` response; if seen within 150 ms, send `\x1b[>7u` (push flags 1+2+4 = disambiguate + event types + alternate keys).
8. If no Kitty response after 150 ms, fall back to `\x1b[>4;2m` (modifyOtherKeys mode 2) — this is what tmux supports.
9. `StdinBuffer` wired between `process.stdin.on('data')` and the user's input handler so partial sequences buffer.
10. Each emitted sequence runs through `normalizeAppleTerminalInput` (Apple Terminal Shift+Enter `\r` → `\x1b[13;2u`).
11. `setTitle(title)` via `\x1b]0;<title>\x07`.
12. `setProgress(true)` via `\x1b]9;4;3\x07` + 1 s keep-alive interval; `setProgress(false)` via `\x1b]9;4;0;\x07`.

`drainInput(maxMs=1000, idleMs=50)` is called on shutdown to:
- Disable Kitty protocol first (`\x1b[<u`).
- Disable modifyOtherKeys (`\x1b[>4;0m`).
- Suspend the user handler, wait until 50 ms idle or 1 s elapsed.
- This swallows late key-release events over slow SSH so they don't leak to the parent shell as `:3F` etc.

`stop()` additionally:
- Disables bracketed paste (`\x1b[?2004l`).
- Pauses stdin (so any Ctrl+D buffered post-raw-disable doesn't close the parent SSH shell).
- Restores the original raw mode flag.

Pi-zig `RawMode.enable` (`tui_terminal.zig:23`):
- Reads termios, disables ICANON/ECHO/ECHONL/IEXTEN/ISIG, disables ICRNL/INPCK/ISTRIP/IXON/BRKINT, sets MIN=1/TIME=0.
- That's it. **No alt screen, no bracketed paste, no Kitty probe, no modifyOtherKeys, no Windows console mode, no SIGWINCH, no Apple Terminal normalization, no drain on shutdown, no title/progress, no synchronized output enable.**

`querySize()` does TIOCGWINSZ + COLUMNS/LINES env fallback. Reasonable parity. But there's **no resize handler** — pi-zig polls `querySize()` only on initial render, so a terminal resize during a session is not noticed.

`readNonblocking(fd, buf)` uses `poll` with 0 ms timeout — a 0-byte read returns immediately. Upstream's `process.stdin.on('data')` is event-driven; this is functionally similar but pi-zig will burn CPU on its read loop if the loop polls without sleep.

### 3.6 Stdin buffering (`stdin-buffer.ts` → `tui_keys.sequences`)

Upstream `StdinBuffer` is the partial-sequence assembler. It maintains:
- `buffer: string` — accumulated bytes pending sequence completion.
- `pasteMode: bool` + `pasteBuffer: string` — bracketed paste accumulator.
- 10 ms timeout to flush incomplete sequences (network delays).
- `pendingKittyPrintableCodepoint` to dedup Kitty printable + legacy printable.

Sequence completeness is decided by `isCompleteSequence`:
- CSI (`ESC [ ... <0x40..0x7e>`): SGR mouse (`<digits;digits;digits[Mm]`) needs the exact tri-digit shape, otherwise any final byte in range ends it.
- OSC (`ESC ] ... ST` where ST = `ESC \` or BEL).
- DCS (`ESC P ... ESC \`) — used by XTVersion responses.
- APC (`ESC _ ... ESC \`) — used by Kitty graphics responses.
- SS3 (`ESC O <single char>`).
- Meta (`ESC <single char>`).
- Old-style mouse (`ESC [ M + 3 bytes`) — exactly 6 bytes.
- WezTerm escape-release fixup: `ESC ESC` followed by `[`/`]`/`O`/`P`/`_` is split, emitting only the first ESC and restarting.

Pi-zig `tui_keys.escapeSequenceLen` handles **only**:
- `ESC [` (CSI): consume until 0x40..0x7E.
- `ESC O`: return min(3, len) — SS3 + one char.
- `ESC ESC` → 2 bytes.
- `ESC <single>` → 2 bytes.

What pi-zig misses:
- OSC accumulation (e.g. terminal title responses, hyperlinks).
- DCS accumulation (XTVersion, capability responses).
- APC accumulation (Kitty graphics protocol responses).
- Mouse: SGR `\x1b[<…M/m` would correctly stop at `M`/`m`, but old-style mouse `\x1b[M` + 3 bytes (where the 3 bytes can be in 0x20..0x7e — the column/row encoded with +32 offset) would terminate at the first byte that happens to be in 0x40..0x7e, *cutting the sequence in half*.
- Bracketed paste accumulator — pi-zig sees `\x1b[200~` as a regular CSI sequence and emits it as a single "key", followed by the pasted body as individual key sequences, followed by `\x1b[201~` as another single key. The editor doesn't recognize the markers, so all three become literal text.
- 10 ms timeout flush — pi-zig's read is event-driven by `poll`, so an incomplete sequence at the tail of a read returns to the caller as a sliced-off prefix, never completes, and corrupts state.
- High-byte conversion (8-bit metakey).

### 3.7 Markdown (`components/markdown.ts` → `tui_markdown.zig`)

Pi-zig has a from-scratch markdown port at `src/pi/tui_markdown.zig` (1136 LoC; documented as "honest gaps" in its header) that does NOT depend on `marked`. It implements:

- A minimal **block grammar** by line scanning: ATX headers (`#..######`), unordered (`-`, `*`, `+`) and ordered (`1.`) lists (single-level), blockquotes (`>`), fenced code blocks (`` ``` … ``` ``) with optional language, horizontal rules (`---`), and prose paragraphs (re-joined by `' '` to mirror marked).
- An **inline tokenizer** for `**bold**`, `*italic*` / `_italic_`, `` `code` ``, `[text](href)` links, and `\` escapes for markdown control chars.
- A **shared keyword/string/comment colorer** for fenced code blocks (sharing the tokenizer with `html_export.zig` so TUI + HTML look consistent).
- **Byte-based hard wrap** with ANSI-aware column accounting (skips SGR sequences when measuring).
- Per-line balanced SGR (every open closed on the same line, matching the differential renderer's expectations).

Side-by-side with upstream:

| Markdown element | Upstream behaviour | Pi-zig |
|---|---|---|
| `# Heading` | Styled headings via `theme.heading(...)`; h1 gets bold+underline; h3+ get `### ` prefix; trailing blank line | ATX 1-6 parsed; fixed accent style; **no h1 underline, no h3+ `#` prefix preserved** |
| `**bold**` | `theme.bold(...)` + style prefix restoration | **PORTED** |
| `*italic*` / `_italic_` | `theme.italic(...)` | **PORTED** |
| `` `inline code` `` | `theme.code(...)` + style restoration | **PORTED** (with dim background) |
| ` ```fenced``` ` | `codeBlockBorder` opening line + each code line via `codeBlock(line)` or `highlightCode(text, lang)` callback + `codeBlockIndent` prefix + closing fence | **PORTED** with built-in keyword/string/comment tokenizer; no closing fence line ("border" treatment differs visually) |
| `> blockquote` | `quoteBorder('│ ')` + recursive block render of nested tokens; italic style applied to body | partial — `│ ` border emitted, **body rendered flat** (a code block inside the quote stays raw) |
| `- item` / `1. item` | Indent per depth (4 spaces), `theme.listBullet` for `- ` / `1. `, task `[x]`/`[ ]` support, ordered `start` offset, prefix/continuation indent | partial — `-`/`*`/`+` + `1.` parsed, ordered `start` honored; **no nesting depth, no task markers `[x]`/`[ ]`** |
| `\| col1 \| col2 \|` table | Column-width allocator with min/natural/grow logic; cell wrapping; `┌─┬─┐` / `├─┼─┤` / `└─┴─┘` rules; bold headers | **MISSING** (explicitly out of scope) |
| `---` HR | `theme.hr(...)` with up-to-80-char dash run | **PORTED** |
| `~~strike~~` | `theme.strikethrough(...)` via strict tokenizer | **MISSING** (no `del` token at all) |
| `<u>underline</u>` (HTML) | Plain text (after `applyDefaultStyle`) | Plain text |
| `[label](url)` | `theme.link(theme.underline(text))`; OSC 8 hyperlink when capability available, otherwise `text (url)` fallback unless text == url (with mailto: stripping) | parsed; **always emits `text (url)` plain-text** — no OSC 8 hyperlink path, no mailto: stripping |
| Autolinks `<https://…>` | Handled by marked tokenizer + `link` arm above | **MISSING** (no `<…>` autolink parsing) |
| Escape sequences `\\*` etc. | Marked tokenizer handles them | **PORTED** (backslash escapes for markdown control chars) |
| `<br>` | Newline | **MISSING** |
| Render cache (`cachedText`/`cachedWidth`/`cachedLines`) | Yes | **MISSING** — every call re-parses |
| `applyBackgroundToLine` so background extends full width | Yes | **MISSING** (no `defaultTextStyle.bgColor` integration) |
| Top/bottom `paddingY` empty lines | Yes | **MISSING** |
| Caller-overridable `MarkdownTheme` (15 funcs) | Yes | **MISSING** — fixed palette |
| `DefaultTextStyle` | Yes | **MISSING** |
| Grapheme / east-asian-width awareness | Yes | byte-based |

### 3.8 Components / widgets

Concrete UX features the pi-zig user does not get:

- **Loaders / spinners**: Pi-zig shows `"[working... press Esc to abort]"` as a literal string. Upstream paints a 10-frame braille spinner at 80 ms cadence with theme-coloured prefix.
- **Cancellable loaders**: Upstream's `CancellableLoader` wires `AbortController` to escape; pi-zig has the escape-to-abort intent (`abort_requested` in `tui.zig:283`) but no async cancellation primitive.
- **Inline images**: Upstream renders kitty/iterm2 images inline (file attachments in chat, screenshots in tool output). Pi-zig has nothing.
- **Settings UI**: Upstream `/settings` opens a live `SettingsList` overlay with submenu / cycle / search / hint footer. Pi-zig prints a "not yet wired" notice.
- **Select list scrolling**: Upstream's `SelectList` paginates with `startIndex = Math.min(selected - floor(max/2), total - max)`; pi-zig palette caps at 8 rows with no scroll indicator.
- **Box-drawing layer**: Upstream `Box` component handles padding+background+caching; pi-zig draws boxes ad-hoc with `box.top_left`/`top_right`/`bottom_left`/`bottom_right`/`horizontal`/`vertical` inline. No padding, no caching, no nesting.
- **Spacer / Text / TruncatedText**: Upstream provides these as first-class primitives; pi-zig has none.

---

## 4. Honest parity estimate

### 4.1 Weighting (LoC + user-visible-feature blend)

The upstream tui package is ~15.3k LoC of pure-logic + UI primitives (excluding `marked` and the native helpers). Of that:

- **Foundation / always-on** (`utils.ts`, `keys.ts`, `terminal.ts`, `stdin-buffer.ts`, `tui.ts`, `keybindings.ts`, `terminal-image.ts`, `native-modifiers.ts`, `index.ts`): ~5640 LoC. **Parity ≈ 10%**.
- **Editor surface** (`components/editor.ts`, `editor-component.ts`, `kill-ring.ts`, `undo-stack.ts`): ~2440 LoC. **Parity ≈ 25%** (the buffer/cursor/kill-ring/undo logic is functional but byte-based and missing paste-markers, jumpToChar, pageScroll, multi-level undo, autocomplete; render is absent).
- **Markdown** (`components/markdown.ts`): 797 LoC. **Parity ≈ 50%** (`tui_markdown.zig` covers headers, paragraphs, fenced code with syntax tokenizer, simple lists, blockquotes, HR, bold/italic/code; no tables, no del, no OSC 8, no nesting, no theme).
- **SelectList** (`components/select-list.ts`): 229 LoC. **Parity ≈ 55%** (`tui_selector.zig` has core scroll/wrap + descriptions; no filter, no theme, no two-column layout).
- **Other visible widgets** (input, settings-list, box, loader, cancellable-loader, image, text, spacer, truncated-text): ~1594 LoC. **Parity ≈ 0%**.
- **Fuzzy** (`fuzzy.ts`): 137 LoC. **Parity = 100%+** (with NFKC fold beyond upstream).
- **Autocomplete** (`autocomplete.ts`): 783 LoC. **Parity ≈ 10%** (static slash list only).

LoC-weighted parity:
```
(5640 × 0.10) + (2440 × 0.25) + (797 × 0.50) + (229 × 0.55) + (1594 × 0.00)
+ (137 × 1.00) + (783 × 0.10)
= 564 + 610 + 399 + 126 + 0 + 137 + 78
= 1914 LoC-equivalent of upstream value covered
÷ 11620 total
≈ 16.5%
```

### 4.2 Feature-axis estimate (10 representative TUI capabilities, each weighted equally):

| Capability | Parity |
|---|---|
| Raw mode + termios | 70% |
| Key parsing (legacy non-Kitty) | 35% |
| Key parsing (Kitty protocol + modifyOtherKeys) | 0% |
| Editor buffer (cursor/kill/undo/history) | 50% |
| Editor render (border, scroll, autocomplete UI) | 5% |
| Differential renderer (overlays, viewport, images, sync output) | 15% |
| Markdown rendering | 50% |
| Inline images + capability detection | 0% |
| Select / Settings / Box / Loader / Image / Text / Spacer / TruncatedText / Input | 8% (select-list ~55%, all others 0) |
| Stdin buffer (OSC/APC/DCS/paste accumulator) | 15% |

Mean = **(70+35+0+50+5+15+50+0+8+15) / 10 = 24.8%**.

### 4.3 Final estimate

Reconciling LoC-weighted (16.5%) with feature-axis (24.8%) — and acknowledging that pi-zig's well-ported pieces (fuzzy + kill-ring + the editor buffer logic + markdown block grammar + select-list scroll math) cover a disproportionate share of user-visible *correctness* relative to their LoC weight, but the un-ported pieces (Kitty protocol, IME positioning, paste handling, terminal-image, all the visible-widget primitives, settings UI, autocomplete) account for the visible-surface gaps users hit first:

**Estimated parity ≈ 20%.**

The 80% gap is dominated by:
- 100% of `keys.ts`'s Kitty + modifyOtherKeys + non-Latin-layout + Apple-Terminal + Windows-Terminal codepaths (~900 LoC).
- 100% of `utils.ts`'s visible-width + ANSI-aware wrap + grapheme segmentation (~1100 LoC).
- 100% of `image.ts`, `terminal-image.ts`, `settings-list.ts`, `box.ts`, `loader.ts`, `cancellable-loader.ts`, `text.ts`, `spacer.ts`, `truncated-text.ts`, `input.ts` (~1900 LoC).
- ~50% of `markdown.ts` — tables, `~~del~~`, OSC 8 hyperlinks, nested lists/quotes, theme + default text style, render cache, padding (~400 LoC).
- ~90% of `autocomplete.ts` (fd-walk, `@`-path completion, scoped fuzzy file search).
- ~85% of `tui.ts`'s overlay compositor + IME cursor + viewport + Kitty image lifecycle + frame guard.
- ~85% of `terminal.ts`'s bracketed paste + kitty probe + modifyOtherKeys + drain + setTitle + setProgress.

Together that's **~80% of upstream's visible-surface code** with **zero or near-zero equivalent** in pi-zig.

What pi-zig *has* implemented (fuzzy filtering with NFKC fold; kill ring; deletion / cursor / word movement on ASCII; raw mode; default keybinding table; single-level undo; differential renderer for the simple case; markdown headers + paragraphs + fenced code + simple lists + blockquotes + bold/italic/inline-code; SelectList scroll + wrap-around) is the **20%** that keeps the prompt composer functional for a basic, non-IME, non-Kitty, ASCII-only Linux/macOS session over a stable terminal — with markdown-styled scrollback that already reads close to upstream for the common assistant-response shapes.

---

## Notes on files I did not need to read in full

- `upstream/pi/packages/tui/src/utils.ts` was read up to line ~200 (the `visibleWidth` / `extractAnsiCode` core), plus `grep`-driven inventory of every `export`. The remaining 940 lines are implementation detail (slicing, segment extraction, background application) and don't change the inventory.
- `components/editor.ts` was read in full (2292 lines across multiple slices).
- `tui_messages.zig` and `tui_theme.zig` were inventoried (export lists) rather than read line-by-line — they are pi-zig-specific transcript renderers / palette helpers with no direct upstream peer in the gap-10 scope.
- `tui_footer.zig` is a pi-zig-only multi-row status footer with no upstream peer; out of scope for this audit beyond noting its existence.

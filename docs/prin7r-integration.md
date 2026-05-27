# Prin7r Integration & Release Packaging (Flow 12)

This document describes how to inject **pi-zig** (this repo) into
**`/Users/keer/projects/prin7r-openwork-zero_native`** as a backend + frontend
capability, **without editing the Prin7r repo in this wave**. All Prin7r-side
changes are delivered as patch packages (see
[Patch packaging](#7-package--update-path)); nothing here edits Prin7r in place.

- Upstream parity target: `earendil-works/pi` @ `fc8a1559017f1e581cfa971aa3cef11a507a4975`
- pi-zig release schema: `pi-zig.release.v1` (emitted by `release/package.sh`)
- Prin7r app sidecar schema: `prin7r.application.v1` (see `release/prin7r-app.manifest.json`)

---

## 0. What Prin7r is (so the integration shape is grounded)

Prin7r is a [`zero-native`](https://www.npmjs.com/package/zero-native) desktop
app, not a web service:

- **Host**: a Zig executable (`prin7r`) that hosts a system **webview** and
  imports sibling Zig modules under `modules/` (`rou7r`, `voice-stt`) plus
  `src/prin7r_lib`. Subprocesses are launched through a PTY layer
  (`src/terminal_pty.c`). Proof: `/Users/keer/projects/prin7r-openwork-zero_native/build.zig`
  (`addAppExecutable`, `rou7rModule`), `app.zon`.
- **Frontend**: a Vite/Next bundle built into `frontend/out` and served by the
  webview (`app.zon` → `.frontend.dist = "frontend/out"`).
- **Keys**: loaded from `~/.nth-kir-keys.env` (or `$PRIN7R_KEYS_FILE`). Proof:
  `/Users/keer/projects/prin7r-openwork-zero_native/src/config.zig:116-118`.
- **Packaging**: `npm exec -- zero-native package … frontend/out --output zig-out/package/<app>`.
  Proof: `build.zig` lines ~149-175.
- **App artifacts** carry a sidecar manifest `schema: "prin7r.application.v1"`
  with an `applicationClass` (one of `static_document`, `interactive_document`,
  `standalone_spa`, `backend_service_app`, `integrated_prin7r_app`) and an icon
  path. Proof: `/Users/keer/projects/prin7r-openwork-zero_native/AGENTS.md`
  "Application Artifacts".

pi-zig therefore plugs in as **two coordinated artifacts**:

| pi-zig artifact | Prin7r role | applicationClass |
|---|---|---|
| `bin/pi-zig` (RPC over NDJSON) | sidecar backend child | `backend_service_app` |
| `frontend/` (static Preact bundle) | embedded inspection/control surface | `integrated_prin7r_app` |

---

## 1. Release artifacts

A fresh checkout produces both artifacts with one script.

```bash
# from this repo root
release/package.sh                 # builds + stages everything (ReleaseSafe)
release/package.sh --dry-run       # plan only, no builds, no writes
release/package.sh --optimize ReleaseSmall
release/package.sh --skip-frontend # backend only
```

Staged layout (default `zig-out/release/`):

```
zig-out/release/
├── bin/pi-zig            # backend binary (RPC over NDJSON)
├── frontend/
│   ├── index.html        # SPA entry
│   └── assets/…          # hashed JS + CSS
├── manifest.json         # schema "pi-zig.release.v1": versions, sha256, launch
└── SHA256SUMS            # one sha256 per staged file
```

Direct (no-staging) artifact paths after a normal build:

| Artifact | Path | Built by |
|---|---|---|
| Backend binary | `zig-out/bin/pi-zig` | `zig build` |
| Frontend bundle | `frontend/dist/{index.html,assets/*}` | `npm --prefix frontend run build` |

> `zig-out/` and `frontend/dist/` are git-ignored (`.gitignore`), so the staged
> release tree is a build output, never committed.

---

## 2. Backend launch command & RPC lifecycle

pi-zig's backend mode is a **line-delimited JSON (NDJSON) process** over
stdin/stdout. Prin7r launches it as a long-lived PTY/sidecar child.

**Launch:**

```bash
bin/pi-zig rpc <session-file>
# equivalently: bin/pi-zig --mode rpc --session <session-file>
```

**Lifecycle (verified against this build):**

1. **One JSON object per input line** on stdin → **one JSON response object per
   line** on stdout. Example:

   ```bash
   printf '{"type":"get_state"}\n' | zig-out/bin/pi-zig rpc zig-out/probe.jsonl
   # {"type":"response","command":"get_state","success":true,"data":{ … "sessionFile":"zig-out/probe.jsonl","messageCount":0 …}}
   ```

2. **Session is durable**: the `<session-file>` (`.jsonl`) is appended to and
   survives restart. State is reported via `get_state` (`sessionId`,
   `sessionFile`, `messageCount`, streaming/retry/compaction flags).

3. **Clean shutdown on EOF**: closing the child's stdin terminates the process
   with exit code 0. Verified:

   ```bash
   printf '' | zig-out/bin/pi-zig rpc zig-out/eof.jsonl ; echo "exit=$?"   # exit=0
   ```

4. **Health probe** (cheap, no provider/network): `bin/pi-zig status` →
   prints foundation banner, exit 0.

The full RPC command surface (29+ `RpcCommand` inputs: `prompt`, `bash`,
`compact`, `fork`, `clone`, `switch_session`, `get_commands`, `get_messages`,
`get_session_stats`, `set_model`, `abort`/`abort_retry`, etc.) is owned by other
flows; this flow only fixes the **launch + lifecycle contract** for embedding.
See `docs/parity.md` (RPC rows) and `src/pi/rpc.zig` for the command set.

---

## 3. Frontend embedding shape

The Preact bundle is a **static SPA** (`frontend/dist/`). Prin7r embeds it the
same way it embeds its own `frontend/out`: as a webview-served static
directory with `index.html` as entry and SPA fallback.

- **Entry**: `frontend/index.html`
- **Assets**: `frontend/assets/*` (content-hashed, safe to cache)
- **No server required**: it is pure static output from `vite build`; the
  webview loads it from disk (e.g. a `zero://` app origin).
- **Backend wiring**: the SPA talks to the `bin/pi-zig rpc` child. In the
  current parity checkpoint the SPA renders parity/inventory status; live RPC
  wiring (sending NDJSON to the backend child) is the integration-phase task and
  is described in the manifest, not yet built into the UI.

The Prin7r app sidecar manifest for this surface is
`release/prin7r-app.manifest.json` (`applicationClass: "integrated_prin7r_app"`
with a nested `backend_service_app` descriptor).

---

## 4. App manifest for Prin7r

`release/prin7r-app.manifest.json` (schema `prin7r.application.v1`) is the
sidecar Prin7r expects next to an application artifact. Key fields:

- `applicationClass: "integrated_prin7r_app"` (frontend) with
  `backend.applicationClass: "backend_service_app"`.
- `icon`: `frontend/assets/icon.svg` (placeholder path; replace with a generated
  icon during the integration phase using Prin7r's app icon provider).
- `backend.launch`: `["bin/pi-zig", "rpc", "${PI_ZIG_SESSION_FILE}"]`.
- `backend.protocol: "ndjson-stdio"`, `backend.shutdown: "close-stdin-eof"`.
- `backend.healthcheck`: `["bin/pi-zig", "status"]`, expect exit 0.
- `backend.env` / `backend.sessionStorage`: see sections 5–6.

This manifest intentionally references **paths and env-var names only** — no
secret values.

---

## 5. Settings / env-var handoff & auth/key preflight

pi-zig resolves provider credentials from environment variables and its own
`auth.json` (see `src/pi/auth.zig`, `src/pi/providers.zig`). Prin7r already
loads a key file at `~/.nth-kir-keys.env` (or `$PRIN7R_KEYS_FILE`)
(`prin7r-openwork-zero_native/src/config.zig:116-118`).

**Handoff rule (no secret duplication):**

1. Prin7r is the source of the key file path. The integration passes that path
   through, it does **not** copy values.
2. The launcher exports the needed provider variables into the child's
   environment from the already-loaded key file, then spawns `bin/pi-zig rpc`.
3. The manifest's `backend.env.keysReferenced` lists the variable **names** pi-zig
   consumes (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`,
   `GROQ_API_KEY`); `backend.env.keyFile` records the **path**, never contents.

**Preflight (must be visible, never silent):** before launching the backend the
integration should verify the key file exists and at least one referenced
provider key is present, and **fail loudly** if not. pi-zig exposes the
resolution surface for this check without printing secret values:

```bash
bin/pi-zig auth status anthropic --json   # {"provider":"anthropic","resolved":true|false, …}
bin/pi-zig provider-env anthropic         # the env-var name(s) for a provider
```

Required keys live in `/Users/keer/.nth-kir-keys.env` (per global policy). They
are referenced by path only.

---

## 6. Session storage path handoff

- pi-zig default session file: `zig-out/pi-zig-session.jsonl`
  (`src/pi/session.zig:6`).
- pi-zig supports an explicit session file (`rpc <file>` /
  `--session <file>`) and a session **directory** with auto-naming
  (`--session-dir <dir>`, files `*_pi-zig-*.jsonl`; see `session.zig`
  `newSessionPath`).
- **Handoff**: Prin7r passes a per-app state directory. The manifest declares
  `backend.sessionStorage.dirEnv = "PI_ZIG_SESSION_DIR"` with default
  `${PRIN7R_STATE_ROOT}/pi-zig/sessions`. The launcher resolves a concrete
  `.jsonl` path under that dir and passes it as the `rpc` argument.
- Sessions are durable JSONL and resumable (`--continue`, `fork`, `clone`), so
  Prin7r can re-attach to a prior session by reusing the same file path.

---

## 7. Package / update path

**pi-zig side (this repo):**

- Build & stage: `release/package.sh` → `zig-out/release/` + `manifest.json`
  + `SHA256SUMS`.
- Version comes from `bin/pi-zig --version` (currently `0.1.0`, sourced from
  `build.zig.zon` / `src/pi/config.zig`).
- Update = re-run `release/package.sh` against a newer pi-zig checkout; the
  manifest's `version` + `backend.sha256` change, giving Prin7r a deterministic
  upgrade signal.

**Prin7r side (patch-packaged, never ad hoc):**

All Prin7r-repo changes are delivered as a **patch package** under this repo's
`patches/<patch-id>/`, each containing `README.md` + an `apply.*` script, per the
global patch-packaging standard. The skeleton lives at:

```
patches/prin7r-pi-zig-integration/
├── README.md      # scope, rationale, exact apply + dry-run instructions
└── apply.sh       # idempotent installer; supports --dry-run; writes a
                   #   Prin7r-side patch package, never edits Prin7r in place
```

`apply.sh --dry-run` performs **no writes** and prints precisely what it would
copy/generate into the Prin7r tree (a sidecar manifest + a launcher patch +,
if/when containerized, a Dockerfile delivered as its own nested patch package —
**never an in-place Dockerfile string replacement**, per the Prin7r/global
rule). Running it without `--dry-run` is the only step that touches Prin7r, and
only during an explicit integration phase approved by the controller.

> **Dockerfile policy.** Prin7r's only Dockerfile today is
> `modules/9router/Dockerfile`. pi-zig does not modify it. If a containerized
> pi-zig backend is ever required, it ships as a **new** patch package adding a
> **new** Dockerfile (multi-stage: a Zig build stage producing `pi-zig`, then a
> minimal runtime stage running `pi-zig rpc`), delivered under `patches/` with
> its own `README.md` + `apply.*` — not as edits to the existing one.

---

## 8. Failure modes (must be visible)

| Failure | How it surfaces |
|---|---|
| Missing `zig`/`npm`/`node` | `release/package.sh` exits 2 with a named-tool error |
| `zig build` / frontend build fails | `release/package.sh` exits 3 with the failing step |
| Backend binary missing post-build | exit 3, explicit path in message |
| Generated manifest not valid JSON | exit 3 (node-validated before success) |
| Key file missing / no provider key | integration preflight fails loudly via `pi-zig auth status …`; never a silent fallback |
| Backend child given bad NDJSON | RPC emits `{"success":false, …}` response line; no silent drop |
| Backend shutdown | close stdin → exit 0; orphan detection is Prin7r's PTY responsibility |

No hidden fallbacks and no silent truncation are introduced by this integration.

---

## 9. Verification

```bash
# baselines (this repo)
zig build
npm --prefix frontend run build
zig build test
node --check scripts/verify-basic.mjs

# packaging
release/package.sh --dry-run                 # plan, exit 0 if toolchain present
release/package.sh                            # stage; inspect zig-out/release/
node -e "JSON.parse(require('fs').readFileSync('zig-out/release/manifest.json','utf8'))"

# Prin7r integration patch (no writes)
patches/prin7r-pi-zig-integration/apply.sh --dry-run
```

`scripts/verify-basic.mjs` includes a Flow 12 packaging block that runs
`release/package.sh --dry-run` as a no-op-safe smoke (see the
`// ===== FLOW 12: packaging =====` section at the end of that file).

---

## 10. Exact remaining manual Prin7r step

When the controller authorizes the **integration phase**, the only manual,
Prin7r-touching step is:

1. From this repo: `release/package.sh` to produce `zig-out/release/`.
2. From this repo: `patches/prin7r-pi-zig-integration/apply.sh` (no `--dry-run`)
   pointing at the Prin7r checkout. This writes a Prin7r-side patch package
   (sidecar manifest + launcher patch) under Prin7r's `patches/`.
3. Inside Prin7r: apply that generated patch package, then **rebuild the correct
   app bundle and inspect it** (`zig build frontend-build` + `npm exec --
   zero-native package …`), per the Prin7r UI rule.

Until then, this flow ships **only** the staged release artifacts, the app
manifest, the integration docs, and a **dry-run-only** patch skeleton. No file
under `/Users/keer/projects/prin7r-openwork-zero_native` is modified.

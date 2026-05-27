# Patch package: prin7r-pi-zig-integration

**Status: SKELETON (dry-run only in this wave).** This patch package describes
how to inject **pi-zig** into
`/Users/keer/projects/prin7r-openwork-zero_native` as a backend + frontend
capability. In the current parity wave it is **not** executed against Prin7r;
only its `--dry-run` plan runs. The controller authorizes a real apply during an
explicit integration phase.

## Scope

- Target repo: `/Users/keer/projects/prin7r-openwork-zero_native` (a `zero-native`
  desktop app; see `../../docs/prin7r-integration.md` for its shape).
- pi-zig source: this repo, parity target `earendil-works/pi`
  @ `fc8a1559017f1e581cfa971aa3cef11a507a4975`.

## Rationale

Prin7r app artifacts must be patch-packaged, not edited ad hoc, and Dockerfile
changes must never be done as in-place string replacements (global + Prin7r
rule). This package is the single, reviewable unit that carries every
Prin7r-side change required to host pi-zig:

1. A `prin7r.application.v1` sidecar manifest for the pi-zig app surface
   (generated from `../../release/prin7r-app.manifest.json`).
2. A launcher that spawns the pi-zig backend (`pi-zig rpc <session-file>`) as a
   PTY/sidecar child, with the env/key handoff described in the integration doc.
3. (Only if containerization is ever required) a **new** Dockerfile shipped as a
   **nested** patch package — never an edit to Prin7r's existing
   `modules/9router/Dockerfile`.

## Prerequisites

Produce the pi-zig release artifacts first (from this repo root):

```sh
release/package.sh            # stages zig-out/release/{bin,frontend,manifest.json}
```

## Apply

Dry run first — performs **no writes** and prints the exact plan:

```sh
patches/prin7r-pi-zig-integration/apply.sh --dry-run
# optional: target a non-default Prin7r checkout
patches/prin7r-pi-zig-integration/apply.sh --dry-run --prin7r /path/to/prin7r-openwork-zero_native
```

Real apply (integration phase only, controller-approved). This is the **only**
step that writes into the Prin7r tree, and it writes a Prin7r-side patch package
under Prin7r's own `patches/` directory — it does not edit Prin7r source in
place:

```sh
patches/prin7r-pi-zig-integration/apply.sh \
  --release zig-out/release \
  --prin7r /Users/keer/projects/prin7r-openwork-zero_native
```

After applying, inside Prin7r:

```sh
# rebuild the correct app bundle and inspect it (Prin7r UI rule)
zig build frontend-build
npm exec -- zero-native package --manifest app.zon --frontend frontend/out \
  --output zig-out/package/prin7r
```

## What it writes (real apply only)

Into `<prin7r>/patches/pi-zig-backend/` (a Prin7r-side patch package with its own
`README.md` + `apply.*`):

- `manifest/pi-zig.application.json` — the sidecar app manifest.
- `manifest/SHA256SUMS` — checksums of the staged pi-zig release it targets.
- `apply.sh` — Prin7r-side installer that registers the pi-zig artifact + sidecar
  launcher.

It also copies (does not symlink) the staged pi-zig release
(`bin/pi-zig`, `frontend/`) into a location the Prin7r packager can pick up,
recorded in that generated package's README.

## Hard rules honored

- No in-place Dockerfile string replacement (Prin7r + global policy).
- No secret values copied. Keys are referenced by path
  (`~/.nth-kir-keys.env` / `$PRIN7R_KEYS_FILE`) only.
- No hidden fallbacks / no silent truncation: missing prerequisites fail loudly.
- This wave: dry-run only. `apply.sh` refuses to write unless invoked without
  `--dry-run` **and** given an explicit `--prin7r` target.

## Verified

```sh
patches/prin7r-pi-zig-integration/apply.sh --dry-run   # exit 0, prints plan
```

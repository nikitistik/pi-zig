#!/usr/bin/env bash
# =============================================================================
# patches/prin7r-pi-zig-integration/apply.sh
#
# Installs the pi-zig backend + frontend capability into a Prin7r checkout by
# writing a Prin7r-SIDE patch package under <prin7r>/patches/pi-zig-backend/.
# It NEVER edits Prin7r source files in place, and NEVER edits any existing
# Dockerfile.
#
# SAFETY: by default this is a SKELETON. It only writes when invoked WITHOUT
# --dry-run AND given an explicit --prin7r <path>. With --dry-run (recommended,
# and the only mode used in the parity wave) it performs no writes and prints
# the exact plan.
#
# Usage:
#   apply.sh --dry-run [--prin7r <path>] [--release <dir>]
#   apply.sh --prin7r <path> [--release <dir>]      # real apply (integration phase)
#
# Flags:
#   --dry-run          Plan only; no writes. Exit 0 if prerequisites are present.
#   --prin7r <path>    Path to the Prin7r checkout. Required for a real apply.
#   --release <dir>    pi-zig staged release dir. Default: zig-out/release
#                      (produced by release/package.sh).
#
# Exit codes:
#   0  success / successful dry-run
#   1  bad arguments
#   2  missing prerequisite (release artifacts or Prin7r target)
#   3  write failure
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# patches/<id>/apply.sh -> repo root is two levels up.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DRY_RUN=0
PRIN7R=""
RELEASE_DIR_REL="zig-out/release"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --prin7r) PRIN7R="${2:?--prin7r needs a path}"; shift 2 ;;
    --release) RELEASE_DIR_REL="${2:?--release needs a dir}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { printf '[pi-zig-integration] %s\n' "$*"; }

RELEASE_DIR="${REPO_ROOT}/${RELEASE_DIR_REL}"
APP_MANIFEST_SRC="${REPO_ROOT}/release/prin7r-app.manifest.json"

# --- prerequisite inventory --------------------------------------------------
have_release=1
[ -f "${APP_MANIFEST_SRC}" ] || { log "MISSING app manifest: ${APP_MANIFEST_SRC}"; have_release=0; }

# The staged release is only required for a real apply; for --dry-run we just
# report whether it is present so the operator knows to run release/package.sh.
release_staged=1
if [ ! -x "${RELEASE_DIR}/bin/pi-zig" ] || [ ! -f "${RELEASE_DIR}/manifest.json" ]; then
  release_staged=0
fi

# --- dry-run -----------------------------------------------------------------
if [ "${DRY_RUN}" -eq 1 ]; then
  log "DRY RUN — no writes."
  log "pi-zig repo root   : ${REPO_ROOT}"
  log "app manifest source: ${APP_MANIFEST_SRC} ($([ -f "${APP_MANIFEST_SRC}" ] && echo present || echo MISSING))"
  log "staged release dir : ${RELEASE_DIR} ($([ "${release_staged}" -eq 1 ] && echo present || echo 'not staged — run release/package.sh'))"
  if [ -n "${PRIN7R}" ]; then
    log "prin7r target      : ${PRIN7R} ($([ -d "${PRIN7R}" ] && echo present || echo MISSING))"
  else
    log "prin7r target      : (none given; real apply requires --prin7r)"
  fi
  log "WOULD write Prin7r-side patch package: <prin7r>/patches/pi-zig-backend/"
  log "  - README.md                                  (scope + rebuild instructions)"
  log "  - manifest/pi-zig.application.json           (from ${APP_MANIFEST_SRC##*/})"
  log "  - manifest/SHA256SUMS                        (copied from staged release)"
  log "  - payload/bin/pi-zig                         (copied from staged release)"
  log "  - payload/frontend/                          (copied from staged release)"
  log "  - apply.sh                                   (Prin7r-side installer)"
  log "WOULD NOT edit any Prin7r source file in place."
  log "WOULD NOT edit any existing Dockerfile (modules/9router/Dockerfile untouched)."
  log "WOULD NOT copy any secret values (keys referenced by path only)."
  [ "${have_release}" -eq 1 ] && { log "dry-run OK"; exit 0; } || { log "dry-run found a MISSING prerequisite above"; exit 2; }
fi

# --- real apply (integration phase) ------------------------------------------
log "REAL APPLY requested."
[ -n "${PRIN7R}" ]      || { echo "error: real apply requires --prin7r <path>" >&2; exit 1; }
[ -d "${PRIN7R}" ]      || { echo "error: prin7r target not found: ${PRIN7R}" >&2; exit 2; }
[ "${have_release}" -eq 1 ] || { echo "error: app manifest missing; cannot apply" >&2; exit 2; }
[ "${release_staged}" -eq 1 ] || { echo "error: staged release missing at ${RELEASE_DIR}; run release/package.sh first" >&2; exit 2; }

DEST="${PRIN7R}/patches/pi-zig-backend"
log "writing Prin7r-side patch package: ${DEST}"
mkdir -p "${DEST}/manifest" "${DEST}/payload" || { echo "error: mkdir failed" >&2; exit 3; }

cp "${APP_MANIFEST_SRC}" "${DEST}/manifest/pi-zig.application.json" || exit 3
[ -f "${RELEASE_DIR}/SHA256SUMS" ] && cp "${RELEASE_DIR}/SHA256SUMS" "${DEST}/manifest/SHA256SUMS"
cp -R "${RELEASE_DIR}/bin" "${DEST}/payload/bin" || exit 3
[ -d "${RELEASE_DIR}/frontend" ] && cp -R "${RELEASE_DIR}/frontend" "${DEST}/payload/frontend"

# Prin7r-side README (the generated package's own README, per patch standard).
cat > "${DEST}/README.md" <<'PRIN7R_README'
# Patch package: pi-zig-backend (generated)

Generated by pi-zig `patches/prin7r-pi-zig-integration/apply.sh`. Registers the
pi-zig backend (`payload/bin/pi-zig`, RPC over NDJSON) and its static frontend
(`payload/frontend/`) as a Prin7r application using the sidecar manifest in
`manifest/pi-zig.application.json` (schema `prin7r.application.v1`).

Apply (Prin7r-side):

```sh
patches/pi-zig-backend/apply.sh
```

Then rebuild and inspect the app bundle:

```sh
zig build frontend-build
npm exec -- zero-native package --manifest app.zon --frontend frontend/out \
  --output zig-out/package/prin7r
```

Rules honored: no in-place Dockerfile edits; keys referenced by path
(`~/.nth-kir-keys.env` / `$PRIN7R_KEYS_FILE`) only; no hidden fallbacks.
PRIN7R_README

# Prin7r-side installer stub (kept minimal + idempotent; expanded during the
# integration phase against the then-current Prin7r app-registry layout).
cat > "${DEST}/apply.sh" <<'PRIN7R_APPLY'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[pi-zig-backend] manifest: ${HERE}/manifest/pi-zig.application.json"
echo "[pi-zig-backend] backend : ${HERE}/payload/bin/pi-zig (rpc over NDJSON)"
echo "[pi-zig-backend] frontend: ${HERE}/payload/frontend/index.html"
echo "[pi-zig-backend] Next: register this artifact with the Prin7r app registry,"
echo "[pi-zig-backend]       then 'zig build frontend-build' + zero-native package."
PRIN7R_APPLY
chmod +x "${DEST}/apply.sh"

log "wrote: ${DEST}"
log "Next (inside Prin7r): run patches/pi-zig-backend/apply.sh, then rebuild + package the app bundle."
log "done"

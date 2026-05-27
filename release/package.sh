#!/usr/bin/env bash
# =============================================================================
# pi-zig release packaging (Flow 12)
#
# Produces the two artifacts Prin7r needs to inject pi-zig as a backend +
# frontend capability:
#
#   1. backend binary   : zig-out/bin/pi-zig            (RPC sidecar over NDJSON)
#   2. frontend bundle   : frontend/dist/*               (static Preact assets)
#
# It stages both into a single release tree with a manifest + checksums so a
# downstream packager (Prin7r `zero-native package`, a Docker image, or a tar
# release) has one deterministic directory to copy from.
#
# This script NEVER edits any other repository. It only reads source and writes
# under the local repo's release output dir (default: zig-out/release).
#
# Usage:
#   release/package.sh [--dry-run] [--optimize <mode>] [--out <dir>] [--skip-frontend]
#
# Flags:
#   --dry-run         Plan only. Performs no builds and writes nothing. Prints
#                     the exact steps + target paths and exits 0 if the toolchain
#                     is present, non-zero if a prerequisite is missing.
#   --optimize <mode> Zig optimize mode. Default: ReleaseSafe.
#                     One of: Debug ReleaseSafe ReleaseFast ReleaseSmall.
#   --out <dir>       Release staging dir. Default: zig-out/release.
#   --skip-frontend   Stage backend only (frontend bundle omitted).
#
# Exit codes:
#   0  success (or successful dry-run)
#   1  bad arguments
#   2  missing prerequisite (zig / npm / node)
#   3  build or staging failure
# =============================================================================
set -euo pipefail

# --- resolve repo root from this script's location (no cwd assumptions) ------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DRY_RUN=0
OPTIMIZE="ReleaseSafe"
OUT_DIR_REL="zig-out/release"
SKIP_FRONTEND=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --optimize) OPTIMIZE="${2:?--optimize needs a value}"; shift 2 ;;
    --out) OUT_DIR_REL="${2:?--out needs a value}"; shift 2 ;;
    --skip-frontend) SKIP_FRONTEND=1; shift ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "${OPTIMIZE}" in
  Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;;
  *) echo "error: invalid --optimize '${OPTIMIZE}'" >&2; exit 1 ;;
esac

OUT_DIR="${REPO_ROOT}/${OUT_DIR_REL}"
BIN_SRC="${REPO_ROOT}/zig-out/bin/pi-zig"
FRONTEND_SRC="${REPO_ROOT}/frontend/dist"

log() { printf '[release] %s\n' "$*"; }

require_tool() {
  local tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "error: required tool '${tool}' not found on PATH" >&2
    return 1
  fi
}

# Pick the best available checksum tool (macOS uses shasum, Linux sha256sum).
sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    echo "error: no sha256sum or shasum available" >&2
    return 1
  fi
}

UPSTREAM_PIN="fc8a1559017f1e581cfa971aa3cef11a507a4975"
PI_VERSION="$("${REPO_ROOT}/zig-out/bin/pi-zig" --version 2>/dev/null || echo "unknown")"

# --- prerequisite check (both dry-run and real run) --------------------------
MISSING=0
require_tool zig || MISSING=1
if [ "${SKIP_FRONTEND}" -eq 0 ]; then
  require_tool npm || MISSING=1
  require_tool node || MISSING=1
fi
if [ "${MISSING}" -ne 0 ]; then
  exit 2
fi

# Host triple from uname (portable across zig env format changes). Example:
# arm64-darwin, x86_64-linux.
HOST_TRIPLE="$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]')"

# --- dry-run: print the plan and stop ----------------------------------------
if [ "${DRY_RUN}" -eq 1 ]; then
  log "DRY RUN — no builds, no writes."
  log "repo root          : ${REPO_ROOT}"
  log "upstream pin        : ${UPSTREAM_PIN}"
  log "host triple        : ${HOST_TRIPLE}"
  log "optimize           : ${OPTIMIZE}"
  log "would build backend : zig build -Doptimize=${OPTIMIZE}  ->  ${BIN_SRC}"
  if [ "${SKIP_FRONTEND}" -eq 0 ]; then
    log "would build frontend: npm --prefix frontend run build  ->  ${FRONTEND_SRC}/"
  else
    log "frontend           : SKIPPED (--skip-frontend)"
  fi
  log "would stage into    : ${OUT_DIR}/"
  log "  - ${OUT_DIR}/bin/pi-zig"
  [ "${SKIP_FRONTEND}" -eq 0 ] && log "  - ${OUT_DIR}/frontend/ (static bundle)"
  log "  - ${OUT_DIR}/prin7r-app.manifest.json (sidecar; schema prin7r.application.v1)"
  log "  - ${OUT_DIR}/assets/icon.svg"
  log "  - ${OUT_DIR}/manifest.json"
  log "  - ${OUT_DIR}/SHA256SUMS"
  log "dry-run OK"
  exit 0
fi

# --- real build --------------------------------------------------------------
log "building backend (optimize=${OPTIMIZE}) ..."
( cd "${REPO_ROOT}" && zig build -Doptimize="${OPTIMIZE}" ) || { echo "error: zig build failed" >&2; exit 3; }
[ -x "${BIN_SRC}" ] || { echo "error: backend binary not found at ${BIN_SRC}" >&2; exit 3; }

if [ "${SKIP_FRONTEND}" -eq 0 ]; then
  log "building frontend bundle ..."
  if [ ! -d "${REPO_ROOT}/frontend/node_modules" ]; then
    log "frontend deps missing; running npm --prefix frontend install ..."
    ( cd "${REPO_ROOT}" && npm --prefix frontend install ) || { echo "error: frontend install failed" >&2; exit 3; }
  fi
  ( cd "${REPO_ROOT}" && npm --prefix frontend run build ) || { echo "error: frontend build failed" >&2; exit 3; }
  [ -d "${FRONTEND_SRC}" ] || { echo "error: frontend bundle not found at ${FRONTEND_SRC}" >&2; exit 3; }
fi

# Re-read version from the freshly built binary.
PI_VERSION="$("${BIN_SRC}" --version 2>/dev/null || echo "unknown")"

# --- stage -------------------------------------------------------------------
log "staging release into ${OUT_DIR} ..."
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}/bin"
cp "${BIN_SRC}" "${OUT_DIR}/bin/pi-zig"
chmod +x "${OUT_DIR}/bin/pi-zig"

if [ "${SKIP_FRONTEND}" -eq 0 ]; then
  mkdir -p "${OUT_DIR}/frontend"
  cp -R "${FRONTEND_SRC}/." "${OUT_DIR}/frontend/"
fi

# Stage the Prin7r app sidecar manifest + icon alongside the artifacts so the
# manifest's relative "assets/icon.svg" reference resolves inside the release.
if [ -f "${REPO_ROOT}/release/prin7r-app.manifest.json" ]; then
  cp "${REPO_ROOT}/release/prin7r-app.manifest.json" "${OUT_DIR}/prin7r-app.manifest.json"
fi
if [ -d "${REPO_ROOT}/release/assets" ]; then
  mkdir -p "${OUT_DIR}/assets"
  cp -R "${REPO_ROOT}/release/assets/." "${OUT_DIR}/assets/"
fi

# --- checksums ---------------------------------------------------------------
log "computing checksums ..."
( cd "${OUT_DIR}" && find . -type f ! -name SHA256SUMS ! -name manifest.json | sort | while read -r f; do
    printf '%s  %s\n' "$(sha256_of "$f")" "${f#./}"
  done > SHA256SUMS )

BIN_SHA="$(sha256_of "${OUT_DIR}/bin/pi-zig")"
BIN_BYTES="$(wc -c < "${OUT_DIR}/bin/pi-zig" | tr -d ' ')"

# --- manifest ----------------------------------------------------------------
log "writing manifest.json ..."
{
  printf '{\n'
  printf '  "schema": "pi-zig.release.v1",\n'
  printf '  "name": "pi-zig",\n'
  printf '  "version": "%s",\n' "${PI_VERSION}"
  printf '  "upstreamPin": "%s",\n' "${UPSTREAM_PIN}"
  printf '  "hostTriple": "%s",\n' "${HOST_TRIPLE}"
  printf '  "optimize": "%s",\n' "${OPTIMIZE}"
  printf '  "backend": {\n'
  printf '    "binary": "bin/pi-zig",\n'
  printf '    "sha256": "%s",\n' "${BIN_SHA}"
  printf '    "bytes": %s,\n' "${BIN_BYTES}"
  printf '    "launch": ["bin/pi-zig", "rpc", "<session-file>"],\n'
  printf '    "protocol": "ndjson-stdio",\n'
  printf '    "shutdown": "close-stdin-eof"\n'
  printf '  },\n'
  if [ "${SKIP_FRONTEND}" -eq 0 ]; then
    printf '  "frontend": {\n'
    printf '    "dir": "frontend",\n'
    printf '    "entry": "index.html",\n'
    printf '    "kind": "static-spa"\n'
    printf '  }\n'
  else
    printf '  "frontend": null\n'
  fi
  printf '}\n'
} > "${OUT_DIR}/manifest.json"

# Validate the manifest is well-formed JSON if node is available.
if command -v node >/dev/null 2>&1; then
  node -e "JSON.parse(require('fs').readFileSync('${OUT_DIR}/manifest.json','utf8'))" \
    || { echo "error: generated manifest.json is not valid JSON" >&2; exit 3; }
fi

log "release ready:"
log "  binary   : ${OUT_DIR}/bin/pi-zig (${BIN_BYTES} bytes, sha256 ${BIN_SHA})"
[ "${SKIP_FRONTEND}" -eq 0 ] && log "  frontend : ${OUT_DIR}/frontend/index.html"
log "  manifest : ${OUT_DIR}/manifest.json"
log "  checksums: ${OUT_DIR}/SHA256SUMS"
log "done"

#!/usr/bin/env bash
# =============================================================================
# release/package-cli.sh
#
# Stages the STANDALONE CLI bundle for pi-zig: a single-binary distribution
# meant to be installed and run from a terminal like `claude-code` — no
# frontend, no WS bridge, no Prin7r integration. The same binary supports four
# modes: print (`pi-zig -p`), JSON (`pi-zig --mode json`), RPC over NDJSON
# stdio (`pi-zig rpc <session>`), and interactive TUI (`pi-zig`).
#
# Output: zig-out/release-cli/ (or $RELEASE_CLI_DIR if set).
#
# Layout:
#   bin/pi-zig            statically built Zig binary
#   README.md             CLI quickstart (modes, flags, auth)
#   manifest.json         pi-zig.release-cli.v1 description
#   SHA256SUMS            integrity (the same shape as the Prin7r bundle)
#
# Companion: release/package.sh (Prin7r-integration bundle with frontend).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASE_DIR="${RELEASE_CLI_DIR:-${REPO_ROOT}/zig-out/release-cli}"

log() { printf '[release-cli] %s\n' "$*"; }

# --- 1. Build the binary if it isn't already present. -----------------------
if [ ! -x "${REPO_ROOT}/zig-out/bin/pi-zig" ]; then
  log "binary missing — running zig build"
  (cd "${REPO_ROOT}" && zig build) || { echo "zig build failed" >&2; exit 1; }
fi

# --- 2. Stage the CLI release dir. ------------------------------------------
log "staging standalone CLI release into ${RELEASE_DIR}"
rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}/bin"
cp "${REPO_ROOT}/zig-out/bin/pi-zig" "${RELEASE_DIR}/bin/pi-zig"
chmod +x "${RELEASE_DIR}/bin/pi-zig"

# --- 3. CLI README (kept in this script so the bundle is self-describing). --
cat > "${RELEASE_DIR}/README.md" <<'CLI_README'
# pi-zig — standalone CLI

A single Zig binary that runs a coding agent in your terminal. No frontend,
no service to start — drop `bin/pi-zig` on your `PATH` and invoke it.

## Modes

| Command                                  | Mode        | When to use                                  |
|------------------------------------------|-------------|----------------------------------------------|
| `pi-zig`                                 | interactive | Live TUI with prompt composer + tool panels |
| `pi-zig -p "<prompt>"`                   | print       | One-shot prompt, prints final assistant text |
| `pi-zig --mode json -p "<prompt>"`       | json events | Newline-delimited JSON event stream          |
| `pi-zig --mode rpc --session <file>`     | RPC         | NDJSON stdio for embedding in another host   |

## Provider auth

The same binary speaks all nine transports (Anthropic, OpenAI completions /
responses / codex, Azure OpenAI Responses, Google, Vertex, Mistral, Bedrock).
Authenticate via environment variables or stored OAuth:

```sh
pi-zig auth list                              # show stored credentials
pi-zig auth status anthropic --json           # check a specific provider
ANTHROPIC_API_KEY=… pi-zig -p "hello" \
  --provider anthropic --model claude-haiku-4-5
```

OAuth refresh (Anthropic / GitHub-Copilot / OpenAI-Codex), Vertex ADC mint
(authorized-user + service-account RS256 JWT), and Bedrock SigV4 (IAM env or
`~/.aws/credentials` profile) all work out of the box.

## Useful flags

- `--provider <id> --model <id>`  pin the provider/model for the turn.
- `--session <path>` / `--session-dir <dir>` / `--continue` / `--fork`  session persistence.
- `--extension <path.mjs|.ts>` / `--no-extensions`  JS/TS extension loading.
- `--tools <name1,name2>` / `--no-tools` / `--no-builtin-tools`  tool gating.
- `--no-context-files`  suppress AGENTS.md/CLAUDE.md/SYSTEM.md autoload.
- `--export <session.jsonl> [out.html]`  static HTML export of a session.

## Quickstart

```sh
# Interactive TUI (requires a real terminal):
pi-zig

# Non-TTY one-shot:
ANTHROPIC_API_KEY=… pi-zig -p "Summarize this directory" \
  --provider anthropic --model claude-haiku-4-5

# Drive programmatically over NDJSON stdio:
echo '{"id":"a","type":"prompt","message":"hi"}' | \
  ANTHROPIC_API_KEY=… pi-zig --mode rpc --session ./s.jsonl \
    --provider anthropic --model claude-haiku-4-5
```

This bundle is the CLI distribution. The companion `release/` bundle adds the
Preact workbench frontend + Prin7r app manifest for desktop-app embedding.
CLI_README

# --- 4. Manifest. -----------------------------------------------------------
BIN_SHA="$(shasum -a 256 "${RELEASE_DIR}/bin/pi-zig" | awk '{print $1}')"
BIN_BYTES="$(wc -c < "${RELEASE_DIR}/bin/pi-zig" | awk '{print $1}')"
cat > "${RELEASE_DIR}/manifest.json" <<MANIFEST
{
  "schema": "pi-zig.release-cli.v1",
  "kind": "standalone-cli",
  "binary": "bin/pi-zig",
  "binarySha256": "${BIN_SHA}",
  "binaryBytes": ${BIN_BYTES},
  "upstreamPin": "earendil-works/pi @ fc8a1559017f1e581cfa971aa3cef11a507a4975",
  "modes": ["interactive", "print", "json", "rpc"],
  "notes": [
    "Single binary; no runtime dependencies beyond a POSIX shell for bash tools.",
    "Companion: pi-zig.release.v1 (release/) packages the same binary with the workbench frontend for desktop-app embedding.",
    "Sessions persist as JSONL under \$PI_CODING_AGENT_DIR/sessions or the explicit --session/--session-dir target."
  ]
}
MANIFEST

# --- 5. Checksums. ----------------------------------------------------------
(
  cd "${RELEASE_DIR}"
  shasum -a 256 bin/pi-zig README.md manifest.json > SHA256SUMS
)

log "release ready:"
log "  binary   : ${RELEASE_DIR}/bin/pi-zig (${BIN_BYTES} bytes, sha256 ${BIN_SHA})"
log "  manifest : ${RELEASE_DIR}/manifest.json"
log "  checksums: ${RELEASE_DIR}/SHA256SUMS"
log "done"

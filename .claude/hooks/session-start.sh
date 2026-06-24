#!/bin/bash
# SessionStart hook: ensure the `aql` interpreter is available so the agent can
# run this library's scripts and tests. AQL has no tagged release, so we build
# it from source at the commit this library is pinned to (the same ref CI uses).
#
# Synchronous and idempotent: skips the build if the binary already exists, and
# caches into the container so later sessions are instant. Progress goes to
# stderr; stdout is left clean (SessionStart stdout is injected as context).
set -uo pipefail

# Web sessions are the target; locally a developer already has aql. No-op
# elsewhere. (Remove this guard to build everywhere.)
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

log() { echo "[session-start] $*" >&2; }

# Keep this in lockstep with the workflow's AQL_REF (the consistency CI job
# fails if they drift). The canonical workflow currently lives in ci/test.yml
# pending promotion to .github/workflows/ (see ci/README.md). Full 40-char
# commit so the build is reproducible.
AQL_REF=407fedad2ea2b30c3dde2f29cfbe60e55f94db4e
BIN_DIR="$HOME/.local/bin"
AQL="$BIN_DIR/aql"

# Persist PATH for the rest of the session.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
export PATH="$BIN_DIR:$PATH"

if command -v aql >/dev/null 2>&1 || [ -x "$AQL" ]; then
  log "aql already present ($("$AQL" -version 2>/dev/null || aql -version 2>/dev/null)); skipping build."
else
  if ! command -v go >/dev/null 2>&1; then
    log "WARNING: Go toolchain not found; cannot build aql. Install Go, or build aql manually (see docs/how-to.md)."
    exit 0
  fi
  log "Building aql @ $AQL_REF from source (one-time; cached afterwards)…"
  mkdir -p "$BIN_DIR"
  src="$(mktemp -d)"
  if git clone --quiet https://github.com/aql-lang/aql "$src" \
     && git -C "$src" checkout --quiet "$AQL_REF"; then
    ( cd "$src/cmd/go" \
      && GOFLAGS=-mod=mod go build \
           -ldflags "-X github.com/aql-lang/aql/cmd/go.Version=${AQL_REF}" \
           -o "$AQL" ./aql ) \
      && log "Built $("$AQL" -version 2>/dev/null)." \
      || log "WARNING: aql build failed; see docs/how-to.md to build manually."
  else
    log "WARNING: could not fetch aql source (network?); see docs/how-to.md."
  fi
  rm -rf "$src"
fi

# Fast confidence check: run the smoke test if aql is usable. Never fail the
# session on a check error.
if [ -x "$AQL" ] && [ -f "$CLAUDE_PROJECT_DIR/test/bloom_smoke_test.aql" ]; then
  if ( cd "$CLAUDE_PROJECT_DIR" && "$AQL" test/bloom_smoke_test.aql >/dev/null 2>&1 ); then
    log "Smoke check passed (aql test/bloom_smoke_test.aql)."
  else
    log "NOTE: smoke check did not pass; toolchain may be incomplete."
  fi
fi

exit 0

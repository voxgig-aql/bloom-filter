#!/usr/bin/env bash
# Run every test suite through all three aql execution surfaces and assert
# none of them errors or disagrees:
#
#   interpreter   aql X                  the default — what CI and users run
#   check         aql check X            static type-check (must be 0 errors)
#   byte compiler aql --compile X        bytecode when compilable, else a SILENT
#                                        fallback to the interpreter; documented
#                                        to be IDENTICAL to it ("opt-in
#                                        performance, never semantics")
#
# Plus an informational `aql --force-compile X` line per suite — how much of
# each program the emitter can fully lower today (refusals there are expected
# coverage gaps; under --compile they fall back, so they are not failures).
#
# A check error, a non-zero interpreter run, or any difference between
# `aql --compile X` and `aql X` fails the script. This harness builds its OWN
# aql at the ref below (it equals the library's pin since the bump to 407feda,
# but pinning it here keeps the harness self-contained — it never depends on
# whatever aql is on PATH). Cached under ~/.cache/aql-divergence; needs `go` +
# network for the one-time build, fetched as a source tarball from
# codeload.github.com so it works even where raw `git clone` of aql-lang/aql
# is blocked.
set -uo pipefail

# aql-lang/aql @ main, 2026-06-24 (PR #182, claude/aql-client-issues-6b8new) —
# the same commit the library now pins. It fixes the two regressions this
# library's aql-backend-report.md flagged — the None/type-literal
# template-interpolation break (f247557) and the `convert` return-type /
# fold-carrier `no_signature` check false positives (f247557 / fc47452) — plus
# OpInterp (1b7b9ae) and gradual-Any. All five suites interpret, check (0
# errors), and compile clean. Bump in lockstep with the workflow AQL_REF.
AQL_BYTECODE_REF=407fedad2ea2b30c3dde2f29cfbe60e55f94db4e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CACHE="$HOME/.cache/aql-divergence"
AQL="$CACHE/aql-$AQL_BYTECODE_REF"

SUITES="
test/bloom_unit_test.aql
test/bloom_unit_spec.aql
test/bloom_prop_test.aql
test/bloom_prop_spec.aql
test/bloom_smoke_test.aql
"

log() { echo "[divergence] $*"; }

# --- build aql at the bytecode-capable ref -------------------------------
if [ ! -x "$AQL" ]; then
  command -v go >/dev/null 2>&1 || { echo "error: Go toolchain not found." >&2; exit 1; }
  log "building aql @ $AQL_BYTECODE_REF (one-time; cached) …"
  src="$(mktemp -d)"
  curl -fsSL "https://codeload.github.com/aql-lang/aql/tar.gz/$AQL_BYTECODE_REF" \
    | tar -xz -C "$src" --strip-components=1 || { echo "error: fetch/extract failed." >&2; exit 1; }
  mkdir -p "$CACHE"
  ( cd "$src/cmd/go" && GOFLAGS=-mod=mod go build \
      -ldflags "-X github.com/aql-lang/aql/cmd/go.Version=$AQL_BYTECODE_REF" \
      -o "$AQL" ./aql ) || { echo "error: build failed." >&2; exit 1; }
  rm -rf "$src"
fi
log "aql: $("$AQL" -version)"
echo

cd "$REPO"
fail=0

# --- three modes, per suite ----------------------------------------------
log "interpreter / check / --compile — each must pass with no error or divergence:"
printf '  %-28s  %-12s  %-14s  %s\n' SUITE INTERPRETER CHECK BYTECODE
for s in $SUITES; do
  name="$(basename "$s")"

  interp="$("$AQL" "$s" 2>&1)"; irc=$?
  if [ $irc -eq 0 ]; then i_col="ok"; else i_col="FAIL"; fail=1; fi

  errs="$("$AQL" check "$s" 2>&1 | grep -oE '[0-9]+ error' | grep -oE '[0-9]+' | head -1)"
  errs="${errs:-?}"
  if [ "$errs" = 0 ]; then c_col="ok"; else c_col="FAIL($errs err)"; fail=1; fi

  comp="$("$AQL" --compile "$s" 2>&1)"
  if [ "$interp" = "$comp" ]; then b_col="ok"; else b_col="DIVERGE"; fail=1; fi

  printf '  %-28s  %-12s  %-14s  %s\n' "$name" "$i_col" "$c_col" "$b_col"
  if [ "$b_col" = DIVERGE ]; then
    diff <(printf '%s\n' "$interp") <(printf '%s\n' "$comp") | sed 's/^/      /'
  fi
done

# --- coverage: how much does --force-compile actually lower? --------------
echo
log "--force-compile coverage (refusals are expected gaps, not failures):"
for s in $SUITES; do
  out="$("$AQL" --force-compile "$s" 2>&1)"
  if printf '%s\n' "$out" | grep -q 'force-compile:'; then
    printf '  %-28s  refused  — %s\n' "$(basename "$s")" "$(printf '%s\n' "$out" | grep -o 'force-compile:.*' | head -1)"
  else
    printf '  %-28s  compiled\n' "$(basename "$s")"
  fi
done

echo
if [ "$fail" = 0 ]; then
  log "PASS — every suite runs clean under the interpreter, check, and the byte compiler."
else
  log "FAIL — a suite errored or the byte compiler diverged from the interpreter."
fi
exit $fail

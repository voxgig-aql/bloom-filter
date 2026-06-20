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
# `aql --compile X` and `aql X` fails the script. The --compile/--force-compile
# CLI did not exist at the library's verified pin (7193a7d3), so this harness
# builds a NEWER aql on purpose, pinned below and cached under
# ~/.cache/aql-divergence. Needs `go` + network for the one-time build.
set -uo pipefail

# aql-lang/aql @ main, 2026-06-20: --force-compile plus the bytecode-compiler
# bug fixes (PRs #160/#161), and the check-mode fixes that clear this library's
# old false positives. Bump to re-check against a newer backend.
AQL_BYTECODE_REF=c44d994f33c5cc39b2a1cc4d2f170b3b0aa07431

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
  git clone --quiet https://github.com/aql-lang/aql "$src" || { echo "error: clone failed." >&2; exit 1; }
  git -C "$src" checkout --quiet "$AQL_BYTECODE_REF" || { echo "error: checkout failed." >&2; exit 1; }
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

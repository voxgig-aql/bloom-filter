#!/usr/bin/env bash
# Interpreter-vs-bytecode differential test, driven through the `aql` CLI.
#
# Newer aql exposes the bytecode backend at the command line:
#
#   aql script.aql                 # interpreter (default; what CI/users run)
#   aql --compile script.aql       # bytecode when compilable, else SILENT
#                                   #   fallback to the interpreter — documented
#                                   #   to be IDENTICAL to the interpreter,
#                                   #   "opt-in performance, never semantics"
#   aql --force-compile script.aql # REQUIRE the bytecode path; abort with the
#                                   #   refusal reason instead of falling back
#
# The contract this asserts: `aql --compile X` == `aql X` for every script X.
# A difference is an upstream soundness bug (the compiled path changed a
# result, or TRY mode failed to fall back), not a bloom bug. It also prints a
# `--force-compile` coverage line per script: how much of each program the
# emitter can actually lower today (refusals there are expected, not failures).
#
# Needs `go` + network for a one-time aql build, cached under
# ~/.cache/aql-divergence. The bytecode CLI did not exist at the library's
# verified pin (7193a7d3), so this harness builds a NEWER aql on purpose —
# pinned below, independent of the library's own pin.
set -uo pipefail

# aql-lang/aql @ main, 2026-06-20: first line with --force-compile plus the
# bytecode-compilation-bug fixes (PRs #160/#161). Bump to re-check against a
# newer backend.
AQL_BYTECODE_REF=c44d994f33c5cc39b2a1cc4d2f170b3b0aa07431

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CACHE="$HOME/.cache/aql-divergence"
AQL="$CACHE/aql-$AQL_BYTECODE_REF"

# Scripts known to diverge under --compile because of an upstream bytecode bug
# (not a bloom defect). Listed relative to repo root. Each is asserted to STILL
# diverge — when upstream fixes it the assertion flips and tells us to remove
# it here. See README.md / dx-report.md §3.
QUARANTINE="test/bloom_unit_test.aql"

# Scripts to run both ways. The five suites plus a synthetic loop-free "core
# ops" control (written below) that the emitter CAN fully lower today.
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

# Loop-free positive control: make/add/contains/merge/encode/decode. The
# emitter fully lowers this, so --force-compile must also match.
CORE="$(mktemp --suffix=.aql)"
cat > "$CORE" <<'EOF'
import "./bloom.aql" end
def a ({n: 1000, p: 0.01} Bloom.make end)
def b ({n: 1000, p: 0.01} Bloom.make end)
def _a (a Bloom.add "from-a" end)
def _b (b Bloom.add "from-b" end)
def merged (a Bloom.merge b end)
def back ((merged Bloom.encode end) Bloom.decode end)
print ((back Bloom.contains "from-a" end)) end
print ((back Bloom.contains "from-b" end)) end
print ((back Bloom.contains "absent" end)) end
EOF

cd "$REPO"
fail=0

# --- contract: aql --compile X == aql X ----------------------------------
echo
log "interpreter vs --compile (must be identical — aql's own TRY-mode contract):"
check_pair() {
  local name="$1" script="$2" quarantined="$3"
  local interp comp
  interp="$("$AQL" "$script" 2>&1)"
  comp="$("$AQL" --compile "$script" 2>&1)"
  if [ "$interp" = "$comp" ]; then
    if [ "$quarantined" = yes ]; then
      echo "  UN-QUARANTINE  $name — --compile now matches the interpreter; remove it from QUARANTINE and revisit dx-report.md §3"
      fail=1
    else
      echo "  ok             $name"
    fi
  else
    if [ "$quarantined" = yes ]; then
      echo "  known-diverge  $name (upstream bytecode bug; see dx-report.md §3)"
    else
      echo "  DIVERGE        $name — --compile differs from the interpreter:"
      diff <(printf '%s\n' "$interp") <(printf '%s\n' "$comp") | sed 's/^/                   /'
      fail=1
    fi
  fi
}
check_pair "core-ops (control)" "$CORE" no
for s in $SUITES; do
  q=no; case " $QUARANTINE " in *" $s "*) q=yes;; esac
  check_pair "$s" "$s" "$q"
done

# --- coverage: how much does --force-compile actually lower? --------------
echo
log "--force-compile coverage (refusals are expected gaps, not failures):"
fc_status() {
  local name="$1" script="$2" out
  out="$("$AQL" --force-compile "$script" 2>&1)"
  if printf '%s\n' "$out" | grep -q 'force-compile:'; then
    echo "  refused   $name — $(printf '%s\n' "$out" | grep -o 'force-compile:.*' | head -1)"
  else
    echo "  compiled  $name"
  fi
}
fc_status "core-ops (control)" "$CORE"
for s in $SUITES; do fc_status "$s" "$s"; done

rm -f "$CORE"
echo
if [ "$fail" = 0 ]; then
  log "PASS — no unexpected interpreter/bytecode divergence."
else
  log "FAIL — an unexpected divergence appeared (or a quarantined one cleared)."
fi
exit $fail

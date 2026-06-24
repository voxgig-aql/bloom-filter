# Three-way test check: interpreter · check · byte compiler

This library's `.aql` suites are written once and must mean the same thing
no matter how `aql` runs them. `run.sh` runs every suite through all three
execution surfaces and asserts none errors or disagrees:

```bash
aql X            # interpreter — the default; what CI and users run
aql check X      # static type-check — must report 0 errors
aql --compile X  # byte compiler — bytecode when compilable, else a SILENT
                 #   fallback to the interpreter; documented to be IDENTICAL
                 #   to it ("opt-in performance, never semantics")
```

It also prints an `aql --force-compile X` coverage line per suite — how much
of each program the bytecode emitter can fully lower today. Refusals there
are expected gaps (under `--compile` they fall back to the interpreter), not
failures.

## Running it

```bash
test/divergence/run.sh
```

`run.sh` builds its own aql at a ref pinned in the script (the same `407feda`
the library now pins; pinning it here keeps the harness self-contained, so it
never depends on whatever aql is on `PATH`), then prints a per-suite matrix:

```
  SUITE                         INTERPRETER   CHECK           BYTECODE
  bloom_unit_test.aql           ok            ok              ok
  bloom_unit_spec.aql           ok            ok              ok
  bloom_prop_test.aql           ok            ok              ok
  bloom_prop_spec.aql           ok            ok              ok
  bloom_smoke_test.aql          ok            ok              ok
```

It exits non-zero on any interpreter failure, any check **error**, or any
difference between `aql --compile X` and `aql X`. Needs `go` + network for the
one-time build (cached in `~/.cache/aql-divergence`).

## Background: what this guards against (and the bug it caught)

`aql --compile` is documented to return results identical to the interpreter
(it falls back to the interpreter for anything it can't lower). This harness
exists because that promise has been broken before, and broke again twice on
`main` (the regressions in `../../aql-backend-report.md`).

The original divergence this guard caught: a compiled `each` body **dropped a
block-local binding** from the enclosing block —

```aql
import "aql:test" end
import "./bloom.aql" end
[ def bf ({n: 1000, p: 0.01} Bloom.make end)
  def _ (iota 50 each [ var [[i] bf Bloom.add (convert String i) end 0 ] ])
  def cnt (bf Bloom.count end)
  true (45 lte cnt) Assert.equal end
] "count" Test.test end
# interpreter => passes
# --compile (on the old pin) => each: element 0: undefined word: bf
```

— so `bf Bloom.add …` raised `undefined word: bf` and, because the emitter
believed it could lower the body, `--compile` did **not** fall back and the
wrong result escaped. `test/bloom_unit_test.aql` was restructured to build
its bulk fixture (`_seen`) at **top level** instead of inside the `Test.test`
block, which both keeps it in scope for the compiler and (the underscore)
skips `aql check`'s unused_def false positive for body-only defs.

**Status (aql `407feda`, the current pin): fixed upstream.** The reduced
repro above is now byte-identical between interpreter and `--compile`, and
all five suites are clean across all three surfaces. The `_seen` fixture is
kept anyway — it's harmless and keeps the suite robust on older builds. This
harness stays as the regression guard (it has already caught two transient
`main` regressions; see `../../aql-backend-report.md`).

`--force-compile` now fully compiles `bloom_prop_test.aql`; the rest refuse
on code-body words (`each` / `do` / `test-test`, "Stage 2") and fall back
cleanly under `--compile` — sound by `aql-lang/aql`'s
`design/COMPILABLE-SUBSET.md` ("refusal is always sound; the worst failure
mode is slow, not wrong").

### Wiring it into CI

`run.sh` is self-contained, so a gating job is one block (add it to
`.github/workflows/test.yml` — needs a token with `workflow` scope, which the
agent session that wrote this didn't have):

```yaml
  divergence:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.24'
      - name: interpreter / check / byte-compiler agreement
        run: test/divergence/run.sh
```

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

`run.sh` builds an aql that has the bytecode + modern check passes (pinned in
the script — the `--compile` CLI did **not** exist at the library's verified
pin `7193a7d3`, so this deliberately builds a *newer* aql, independent of the
library's own pin), then prints a per-suite matrix:

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

## Background: the byte-compiler divergence this guards against

`aql --compile` is documented to return results identical to the interpreter
(it falls back to the interpreter for anything it can't lower). One upstream
bug breaks that promise, and the suites are written to stay clear of it.

A compiled `each` body **drops a block-local binding** from the enclosing
block. Reduced repro (passes on the interpreter, wrong under `--compile`):

```aql
import "aql:test" end
import "./bloom.aql" end
[ def bf ({n: 1000, p: 0.01} Bloom.make end)
  def _ (iota 50 each [ var [[i] bf Bloom.add (convert String i) end 0 ] ])
  def cnt (bf Bloom.count end)
  true (45 lte cnt) Assert.equal end
] "count" Test.test end
# interpreter => passes
# --compile   => each: element 0: [aql/undefined_word]: undefined word: bf
```

Inside the `each` the compiled path can't see the block-local `bf`, so
`bf Bloom.add …` raises `undefined word: bf`. The emitter believes it can
lower the body, so `--compile` (TRY) does **not** fall back, and the wrong
result escapes — breaking the "identical, never semantics" contract. The
trigger is narrow: a *block-local* `def` referenced from an `each` body. A
**top-level** binding survives; a single-expression top-level loop is instead
*refused* (`each` Stage 2/3) and falls back cleanly.

So `test/bloom_unit_test.aql` builds its bulk fixture (`_seen`) at **top
level** instead of inside the `Test.test` block — which both keeps it in
scope for the compiler and (the underscore) skips `aql check`'s unused_def
false positive for body-only defs. With that one structural choice every
suite is green under all three surfaces. This is an upstream aql bug, not a
bloom defect; it is recorded in `../../dx-report.md` §3, and this harness is
the regression guard.

Tested against aql `c44d994`. `--force-compile` still refuses `each`/`get`
(emitter coverage, Stage 2/3) — expected, and harmless because `--compile`
falls back.

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

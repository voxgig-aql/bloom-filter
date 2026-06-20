# Interpreter vs. bytecode differential test

Newer `aql` can run a program two ways over the same strict-stack engine,
selectable from the command line:

```bash
aql script.aql                 # interpreter — the default; what CI and users run
aql --compile script.aql       # bytecode when compilable, else a SILENT fallback
                               #   to the interpreter. Documented to be IDENTICAL
                               #   to the interpreter — "opt-in performance, never
                               #   semantics."
aql --force-compile script.aql # REQUIRE the bytecode path; abort with the refusal
                               #   reason instead of falling back.
```

(The `AQL_COMPILE` / `AQL_FORCE_COMPILE` / `AQL_NO_COMPILE` env vars do the
same.) This harness asserts aql's own TRY-mode contract on this library:

```
aql --compile X  ==  aql X     for every script X
```

A difference is an **upstream soundness bug** — the compiled path changed a
result, or TRY mode failed to fall back — not a bloom bug. The library's
`.aql` suites are written once and must mean the same thing on either
backend.

## Running it

```bash
test/divergence/run.sh
```

`run.sh` builds an aql that has the bytecode CLI (pinned in the script —
the flags did **not** exist at the library's verified pin `7193a7d3`, so
this deliberately builds a *newer* aql, independent of the library's own
pin), then for each suite runs it under the interpreter and under
`--compile` and diffs the output. It also prints a `--force-compile`
coverage line per script — how much of each program the emitter can fully
lower today (refusals there are expected gaps, not failures). Needs `go` +
network for the one-time build (cached in `~/.cache/aql-divergence`).

The harness exits non-zero only on an **unexpected** divergence: a script
not in `QUARANTINE` whose `--compile` output differs, or a quarantined
script that has started matching again (time to un-quarantine it).

## The finding (aql @ `c44d994`)

Two headlines, one good and one bad.

**Good — the bytecode backend now runs the bloom core, identically.** At
the library's pin (`7193a7d3`) the bytecode path could not execute the
library at all. On current aql, the loop-free core —
`make` / `add` / `contains` / `merge` / `encode` / `decode` — fully
compiles under `--force-compile` and returns byte-identical results to the
interpreter (the `core-ops (control)` line). The smoke test and
declarative/property suites also match under `--compile`.

**Bad — `--compile` diverges from the interpreter on
`test/bloom_unit_test.aql`,** which violates the "identical, never
semantics" contract. Reduced repro (passes on the interpreter, fails under
`--compile` and `--force-compile`):

```aql
import "aql:test" end
import "./bloom.aql" end
[
  def bf ({n: 1000, p: 0.01} Bloom.make end)
  def _ (iota 50 each [
    var [[i]
      def key (convert String i)
      bf Bloom.add key end
      0
    ]
  ])
  def cnt (bf Bloom.count end)
  true (45 lte cnt) Assert.equal end
  true (cnt lte 55) Assert.equal end
] "count-within-tolerance" Test.test end
```

```
interpreter   => fail count 0   (passes)
--compile     => FAIL count-within-tolerance — each: element 0:
                 [aql/undefined_word]: undefined word: bf
```

Inside the `each` body the compiled path **loses the `bf` binding** from
the enclosing block, so `bf Bloom.add …` raises `undefined word: bf`.
Crucially this surfaces under `--compile` (TRY) too: the emitter believes
it can lower the body, so it does **not** fall back to the interpreter, and
the wrong result escapes. (`--force-compile` reports the suite as
`compiled` rather than refusing — it runs and gets the wrong answer.)

This is narrow: only an `each` body that both references an outer `def` and
carries a multi-statement body (`def key` … `add` … `0`) trips it. A
single-expression `each` body, or the same loop at top level, is instead
*refused* (`each` Stage 2/3, `operand … not statically materialisable`) and
under `--compile` falls back cleanly — no divergence. The other four suites
either compile identically or refuse-and-fall-back.

So today the bloom library is correct on the interpreter (every `.aql`
suite is green, and the `aql` CLI uses the interpreter by default), but it
is **not yet safe to run under `--compile`** — `bloom_unit_test.aql` is
quarantined here until upstream fixes the each-body scope capture. The
harness pins the boundary so the quarantine clears automatically when it
does.

### Wiring it into CI

`run.sh` is self-contained, so a gating job is one block (add it to
`.github/workflows/test.yml` — needs a token with `workflow` scope, which
the agent session that wrote this didn't have):

```yaml
  divergence:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.24'
      - name: Interpreter vs bytecode differential test
        run: test/divergence/run.sh
```

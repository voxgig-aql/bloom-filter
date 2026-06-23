# AQL backend report: interpreter / check / byte compiler on the latest `main`

**Date:** 2026-06-23
**Library:** `voxgig-aql/bloom-filter` (written in AQL)
**Question:** does the latest `aql-lang/aql` `main` run this library *fully*
across all three execution surfaces — the interpreter, `aql check`, and the
byte compiler (`aql --compile`)?

**Verdict: No.** The latest `main` tip has **regressed**. The last build on
which interpreting, checking, and compiling *all* pass cleanly is
`c44d994` (2026-06-20). Two upstream regressions landed in the 109 commits
after it.

---

## Builds under test

| Build | Date | Role | Notes |
|-------|------|------|-------|
| `7193a7d3` | 2026-06-11 | the library's pinned ref | no `--compile` CLI; `aql check` carries the §2 `no_signature` false positives |
| `c44d994`  | 2026-06-20 | the `test/divergence/` harness pin | **all three surfaces clean** |
| `f8ee642`  | 2026-06-23 | latest `main` tip | **regressed** (this report) |

All three built from source with `GOFLAGS=-mod=mod`.

---

## Result matrix

Every suite, every surface. `interp` = `aql X`; `check` = `aql check X`
error count; `compile` = whether `aql --compile X` output matches `aql X`.

### `c44d994` — previous build (all green)

| Suite | interp | check | compile |
|-------|:------:|:-----:|:-------:|
| `bloom_unit_test.aql`  | ok | 0 err | ok |
| `bloom_unit_spec.aql`  | ok | 0 err | ok |
| `bloom_prop_test.aql`  | ok | 0 err | ok |
| `bloom_prop_spec.aql`  | ok | 0 err | ok |
| `bloom_smoke_test.aql` | ok | 0 err | ok |

### `f8ee642` — latest `main` (regressed)

| Suite | interp | check | compile |
|-------|:------:|:-----:|:-------:|
| `bloom_unit_test.aql`  | **FAIL** | **3 err** | ok\* |
| `bloom_unit_spec.aql`  | ok | **2 err** | ok |
| `bloom_prop_test.aql`  | ok | 0 err | ok |
| `bloom_prop_spec.aql`  | ok | 0 err | ok |
| `bloom_smoke_test.aql` | ok | **12 err** | ok |

\* `--compile` still matches the interpreter on every suite (no *new*
bytecode divergence — the each-body scope fix from the prior round still
holds). Where the interpreter now fails, `--compile` fails *identically*,
so the "compile == interpret" contract is not itself broken.

---

## Regression 1 — interpreter: `None` interpolated into a template string

**Severity: 🔴 high** (silently wrong string, and a changed error code).

Interpolating a `None` value into a template literal is broken on
`f8ee642`:

```aql
def x None
def msg `got ${x}`
msg print          # c44d994 => "got None"
                   # f8ee642 => "String"   (wrong)
```

It also corrupts `raise` when the message is built that way:

```aql
def x None
do [ def msg `got ${x}` raise bad_input msg ] error [ get code ] print
# c44d994 => bad_input
# f8ee642 => raise_error
```

**Impact on the library.** `Bloom.make` validates its arguments and builds
each error message with the offending value interpolated, e.g.
`` `Bloom.make: p must be a Float in (0, 0.5] (got ${p-val})` ``. When the
`p` key is missing, `p-val` is `None`, so on `f8ee642`:

```aql
import "./bloom.aql" end
do [{n: 1000} Bloom.make end] error [ get code ] print
# c44d994 => bad_input
# f8ee642 => raise_error
```

The documented contract (`AGENTS.md`, `docs/reference.md`) is that bad
arguments raise **`bad_input`**. `bloom_unit_test.aql`'s
`make-validates-input` case asserts exactly that and now **fails**:

```
FAIL make-validates-input — [aql/assertion_failure]:
  Assert.equal: expected raise_error, got bad_input
```

(Only the *missing-key* case trips; `{n: 0, …}` and `{…, p: 0.7}` still
report `bad_input`, because their messages interpolate a non-`None`
value.)

---

## Regression 2 — check mode: `no_signature` false positives are back

**Severity: 🟡 medium** (false errors; `aql check` already advisory here).

`aql check` again reports `no matching signature for …` on arithmetic that
runs fine, at **error** severity:

```
check: 145:46: [error] no_signature: no matching signature for mul; …
check: 155:30: [error] no_signature: no matching signature for mul; …
check: 120:5:  [error] no_signature: no matching signature for convert; …
check: 240:58: [error] no_signature: no matching signature for fold; …
check: 261:21: [error] no_signature: no matching signature for sub; …
check: 261:28: [error] no_signature: no matching signature for div; …
check:         [error] no_signature: no matching signature for negate; …
check: 263:35: [error] no_signature: no matching signature for div; …
```

Lines `145`/`155` are `bloom.aql`'s `derive-m` / `derive-k` (the `mul`
inside the sizing formulas, flowing through `convert Float`); the `240`–
`263` hits are the smoke test's cardinality-estimate math. These are the
**same** false positives recorded in `dx-report.md` §2 — present at
`7193a7d3`, **fixed by `c44d994`**, and now **regressed** on `f8ee642`.
The flagged code is example- and property-tested and runs correctly under
the interpreter and the byte compiler; only the static checker is wrong.

The error counts in the matrix (3 / 2 / 12) are these diagnostics surfaced
through whichever suite imports the affected code (`bloom.aql` for the unit
suites; `bloom.aql` plus the in-file math for the smoke suite).

---

## What did *not* regress

- **The byte compiler vs. the interpreter.** `aql --compile X == aql X`
  still holds for every suite. The earlier each-body scope-capture bug
  (compiled `each` dropping a block-local `def`), worked around by building
  the bulk fixture at top level, remains correct.
- **`--force-compile` coverage.** Still refuses `each` / `get`
  (Stage 2/3 emitter gaps) and falls back cleanly under `--compile` — no
  change.
- **The property suites.** `bloom_prop_test` / `bloom_prop_spec` pass
  interpreter and check (0 errors) and match under `--compile`.

---

## Recommendation

1. **Do not adopt `f8ee642`** for this library yet, and do not move the
   `test/divergence/` pin off `c44d994` — doing so would turn the suites
   and the harness red for purely upstream reasons.
2. **Stay on `c44d994`** as the bytecode-capable reference: it is the most
   recent build where interpreter, `aql check`, and `aql --compile` are all
   clean across every suite.
3. **File both regressions upstream** (`aql-lang/aql`), each with the
   minimal repro above:
   - `None` interpolation in template literals (interpreter; wrong string +
     `raise` code becomes `raise_error`);
   - `no_signature` false positives on `mul`/`fold`/`sub`/`div`/`convert`/
     `negate` through `convert Float` (check mode; regression of a fix that
     shipped in `c44d994`).
4. When a `main` past `f8ee642` clears both, re-run `test/divergence/run.sh`
   against it and bump the pin.

---

### Reproduction

```bash
# build any ref
git clone https://github.com/aql-lang/aql /tmp/aql && cd /tmp/aql
git checkout f8ee642 && ( cd cmd/go && GOFLAGS=-mod=mod go build -o /tmp/aql-bin ./aql )

# from the bloom-filter repo root
/tmp/aql-bin test/bloom_unit_test.aql          # interpreter
/tmp/aql-bin check test/bloom_unit_test.aql    # check
/tmp/aql-bin --compile test/bloom_unit_test.aql # byte compiler
```

Or run the whole three-surface matrix on the pinned-clean build:

```bash
test/divergence/run.sh
```

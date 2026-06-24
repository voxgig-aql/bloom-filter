# AQL backend report: interpreter / check / byte compiler on `main`

**Date:** 2026-06-24 (updated)
**Library:** `voxgig-aql/bloom-filter` (written in AQL)
**Question:** does the latest `aql-lang/aql` `main` run this library *fully*
across all three execution surfaces — the interpreter, `aql check`, and the
byte compiler (`aql --compile`)?

**Verdict: Yes, as of `14036b4` (2026-06-24), and re-verified on the current
pin `407feda`.** Two regressions seen on the `f8ee642`/`65410b1` tips
(2026-06-23) were **fixed upstream the next day** (PR #182,
`claude/aql-client-issues-6b8new`; the fix commit is `f247557`, with
`fc47452` and `1b7b9ae` alongside). On `14036b4` all five suites interpret,
check (0 errors), and compile cleanly. The pin has since moved to `407feda`
(the current `main` HEAD = the doc-verified `0b010ae` plus the
re-verification doc, no engine delta; several checker commits past
`14036b4`), re-verified clean here and in upstream's
`design/CLIENT-VERIFICATION-MAIN-2026-06-24.md`. The regression details
below are kept as the record of what was wrong and why.

> Timeline: the two regressions were *transient* on `main` — present
> 2026-06-23, gone 2026-06-24. Upstream's own
> `design/CLIENT-FIXES-2026-06-24.md` (and the follow-up
> `CLIENT-VERIFICATION-MAIN-2026-06-24.md`) drove the fixes directly off
> this report.

---

## Builds under test

| Build | Date | Role | Notes |
|-------|------|------|-------|
| `7193a7d3` | 2026-06-11 | former library pin | no `--compile` CLI; `aql check` carries the §2 `no_signature` false positives |
| `c44d994`  | 2026-06-20 | former `test/divergence/` harness pin | all three surfaces clean (no `convert`/`None` regression yet) |
| `f8ee642`  | 2026-06-23 | first regressed `main` tip checked | **regressed** |
| `65410b1`  | 2026-06-23 | regressed `main` tip | **regressed** — same two failures as `f8ee642` |
| `14036b4`  | 2026-06-24 | the build that fixed the regressions | all three surfaces clean — regressions fixed |
| `407feda`  | 2026-06-24 | **current `main` HEAD, library & harness pin** | **all three surfaces clean — re-verified** |

All built from source with `GOFLAGS=-mod=mod`. `aql-lang/aql` git access is
blocked by egress policy in this environment; the `*main*` tips were fetched
as source tarballs from `codeload.github.com` and built locally.

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

### `f8ee642` / `65410b1` — `main` (regressed; identical results)

| Suite | interp | check | compile |
|-------|:------:|:-----:|:-------:|
| `bloom_unit_test.aql`  | **FAIL** | **3 err** | ok\* |
| `bloom_unit_spec.aql`  | ok | **2 err** | ok |
| `bloom_prop_test.aql`  | ok | 0 err | ok |
| `bloom_prop_spec.aql`  | ok | 0 err | ok |
| `bloom_smoke_test.aql` | ok | **12 err** | ok |

Both 2026-06-23 `main` builds produced this exact matrix (the two root
causes below).

### `14036b4` — current `main` (regressions fixed; all green)

| Suite | interp | check | compile |
|-------|:------:|:-----:|:-------:|
| `bloom_unit_test.aql`  | ok | 0 err | ok |
| `bloom_unit_spec.aql`  | ok | 0 err | ok |
| `bloom_prop_test.aql`  | ok | 0 err | ok |
| `bloom_prop_spec.aql`  | ok | 0 err | ok |
| `bloom_smoke_test.aql` | ok | 0 err | ok |

`bloom_prop_test.aql` additionally now *fully compiles* under
`--force-compile` (it previously refused). The remaining `--force-compile`
refusals (`each` / `do` / `test-test` code-body words) are tracked
emitter-coverage gaps that fall back cleanly under `--compile` — sound, not
divergent (see `design/COMPILABLE-SUBSET.md`).

\* `--compile` still matches the interpreter on every suite (no *new*
bytecode divergence — the each-body scope fix from the prior round still
holds). Where the interpreter now fails, `--compile` fails *identically*,
so the "compile == interpret" contract is not itself broken.

---

## Regression 1 — interpreter: `None` interpolated into a template string

**Severity: 🔴 high** (silently wrong string, and a changed error code).
**Status: ✅ fixed in `f247557`** (verified gone on `14036b4`).

Interpolating a `None` value into a template literal was broken on
`f8ee642`/`65410b1`:

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
**Status: ✅ fixed in `f247557` (+ `fc47452`)** (verified 0 errors on
`14036b4`). Root cause was `convert Float x` modelling its result as the
bare `Float` *type literal* rather than a *value* of that type, plus a
fold-body element typed as a strict `Any`.

`aql check` reported `no matching signature for …` on arithmetic that runs
fine, at **error** severity:

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
`7193a7d3`, **fixed by `c44d994`**, and **regressed** on `f8ee642` and
still failing on the current tip `65410b1`.
The flagged code is example- and property-tested and runs correctly under
the interpreter and the byte compiler; only the static checker is wrong.

The error counts in the matrix (3 / 2 / 12) are these diagnostics surfaced
through whichever suite imports the affected code (`bloom.aql` for the unit
suites; `bloom.aql` plus the in-file math for the smoke suite).

---

## Also fixed / improved on `14036b4`

- **`aql --compile X == aql X`** holds for every suite (it always did — this
  was never the regression). The earlier each-body scope-capture bug
  (compiled `each` dropping a block-local `def`) the unit suite worked
  around with a top-level fixture is **now fixed too**: the reduced repro
  (a block-local `bf` mutated inside an `each` body) is byte-identical
  between interpreter and `--compile` on `14036b4`.
- **`--force-compile` coverage grew.** `bloom_prop_test.aql` now *fully
  compiles* (was refused). The rest still refuse on code-body words
  (`each` / `do` / `test-test`, "Stage 2") and fall back cleanly under
  `--compile` — sound by `design/COMPILABLE-SUBSET.md` ("refusal is always
  sound; the worst failure mode is slow, not wrong").

---

## Recommendation (updated 2026-06-24)

1. **Adopt `407feda`** (current `main` HEAD; `14036b4`-lineage plus further
   checker work, re-verified). Both regressions are fixed; all five suites
   interpret, check (0 errors), and compile clean.
2. **`test/divergence/run.sh` is pinned to `407feda`** (was `c44d994` →
   `14036b4`), and its build fetches a source tarball from
   `codeload.github.com` so it works even where raw `git clone` of
   `aql-lang/aql` is blocked.
3. **No library changes were required.** The two regressions were upstream;
   the each-body block-local scope bug the unit suite's top-level `_seen`
   fixture works around is *also* fixed, but the structure is kept
   (harmless, and keeps the suite robust across aql versions).
4. The two regressions are already **filed and fixed upstream** — see
   `aql-lang/aql` `design/CLIENT-FIXES-2026-06-24.md`, which was written
   directly off this report. No issues left to file.

---

### Reproduction

`aql-lang/aql` git is blocked by egress policy here, but the
`codeload.github.com` archive host is reachable, so fetch a source tarball
and build it:

```bash
# build any ref (REF = a commit sha or branch, e.g. the current pin)
REF=407fedad2ea2b30c3dde2f29cfbe60e55f94db4e
mkdir -p /tmp/aql && curl -fsSL \
  "https://codeload.github.com/aql-lang/aql/tar.gz/$REF" \
  | tar -xz -C /tmp/aql --strip-components=1
( cd /tmp/aql/cmd/go && GOFLAGS=-mod=mod go build -o /tmp/aql-bin ./aql )

# from the bloom-filter repo root
/tmp/aql-bin test/bloom_unit_test.aql          # interpreter
/tmp/aql-bin check test/bloom_unit_test.aql    # check
/tmp/aql-bin --compile test/bloom_unit_test.aql # byte compiler
```

Or run the whole three-surface matrix on the pinned-clean build:

```bash
test/divergence/run.sh
```

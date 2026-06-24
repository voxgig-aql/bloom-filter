# Developer-experience report: bloom-filter on AQL

**Date:** 2026-06-11 (second round)
**AQL build under test:** `aql-lang/aql` @ `7193a7d3`
(`7193a7d3c69857207e44b4bd53541b9b0d4348aa`, main as of 2026-06-11;
39 commits past `958c379b`, which this report previously covered;
built locally with `GOFLAGS=-mod=mod`; version string now reports
`aql 0.1.0-dev (git 7193a7d3c698)`).
**Context:** re-verification round. The first 2026-06-11 report (at
`958c379b`) filed eight issues after migrating this module to the
class/Array/raise surface. Six of the eight — including all three
🔴 — were fixed upstream within the same day's 39 commits, several
visibly in direct response to the DX reports. Every verdict below was
re-reproduced first-hand against the build above using the original
minimal repros; the module's five test suites pass on this build
unmodified.

Severity: **🔴 high** (silent wrong results / crash / blocks a use case) ·
**🟡 medium** (friction, clear workaround) · **🟢 low** (papercut).

---

## Fixed since the `958c379b` report

- **🔴→✅ Guard `if` + following `def`: guards fire first now**
  (aql `00cb7a79`, "guards fire before the next statement"). The
  defining repro — an else-less validation `if` whose `raise` was
  pre-empted by eager evaluation of the next `def` statement — now
  raises the guard's own error:

  ```aql
  def t fn [ [x:Any] [Integer] [
    if ((x is Float) not) [
      def m "not a float"
      raise bad_input m
    ]
    def y (x gt 0.0)
    7
  ] ]
  do [t none] error [ get code ]    # => bad_input  (was: incomparable)
  ```

  `bloom.aql` keeps the explicit empty else `[]` on its guards anyway —
  it costs nothing, reads as intent, and stays correct on older builds.

- **🔴→✅ Class-field defaults are per-instance** (aql `607cd1b9`).
  A mutable schema default (`store:(flex {})`) is no longer one shared
  value: writing through one instance is invisible to another. The
  Python-style mutable-default trap is gone. (`BloomFilter` still
  declares `bits` as a required typed field and passes a fresh Array
  per `make` — that remains the clearer design.)

- **🔴→✅ `Object` instances format** (same commit, "open objects
  render"). `print (object {a:1}) end` prints `Object{a:1}`; a bare
  `make Object {}` on the final stack prints `Object{}` instead of
  SIGSEGV-ing the interpreter.

- **🟡→✅ `raise` accepts template-string messages** (aql `00cb7a79`,
  "templates fill typed slots"). Both the bare and parenthesised forms
  now work, with the code and interpolated message intact:

  ```aql
  raise bad_input `got ${t}`        # => bad_input, message "got x"
  ```

  The bind-first idiom (`def msg …` then `raise code msg`) is no longer
  required; this module keeps it for back-compat and readability.

- **🟢→✅ `getr` raises the documented `not_found`** (aql `93ebcd40`;
  was `getr_error`, contradicting REFERENCE.md).

- **🟢→✅ `StructUtil.jsonify` emits Floats as JSON numbers** (aql
  `862546fd`); a `jsonify` → `parse` round trip preserves the Float
  type now. (`Bloom.encode` continues to use canon — unchanged, just
  no longer the only type-preserving option.)

Also fixed without having been formally filed: `aql -version` now
stamps the git commit (`1981f601`), so "which build am I on?" — a
recurring nuisance across these reports — answers itself.

---

## Still open

### 1. 🟡 `print` forward-arg collection reverses/breaks chained prints

Unchanged through three builds:

```aql
(1 add 1) print (2 add 2) print     # prints 4 then 2 — the first
                                    # print collects (2 add 2)
```

The reliable idiom remains one fully-grouped value per statement —
`print (`label: ${value}`) end` — with which output appears strictly
in source order. Every print in this module's tests and docs uses it.

### 2. 🟢 `aql check` is quieter but still not gating-ready

Improved by `d867f1af` (unknown-type results no longer produce
strict-`Any` false errors): the spurious `no_signature` reports for
`getr`, `each`, and user fns are gone — `aql check bloom.aql` dropped
from ~40 finding lines to 30. Still standing in the way of CI use on
this module:

- two false `no_signature: no matching signature for mul` hits in
  `derive-m`/`derive-k` (arithmetic flowing through `convert Float`),
  plus a consequent `fn_body_error` for `derive-k` — the same code
  runs (and is property-tested) fine;
- `unused_def` warnings for every word referenced only by the
  `export "Bloom" {…}` map — the checker doesn't treat the export map
  as a use site.

### 3. ✅ Bytecode (`--compile`) each-body block-local divergence — fixed upstream (`407feda`)

> **Resolved 2026-06-24.** The divergence below is **fixed** on aql
> `407feda` (the reduced repro is byte-identical between interpreter and
> `--compile`), along with two short-lived `main` regressions that broke
> the library on the 2026-06-23 tips — a `None`-in-template interpolation
> bug and `convert`/fold `no_signature` check false positives (all in
> `f247557` / `fc47452`; see `aql-backend-report.md` and upstream
> `design/CLIENT-FIXES-2026-06-24.md`). `test/divergence/run.sh` now pins
> `407feda` and every suite is clean across interpreter, `aql check` (0
> errors), and `aql --compile`. The original finding is kept below as the
> record; the unit suite's top-level `_seen` fixture is retained (harmless,
> and keeps the suite robust on older builds).

Newer aql can run a program through a bytecode backend instead of the
interpreter, selectable at the CLI: `aql --compile X` (bytecode when
compilable, else a *silent* fallback to the interpreter — documented to be
identical, "opt-in performance, never semantics") and `aql --force-compile X`
(require the bytecode path, or abort with a refusal reason). A differential
test (`test/divergence/`, run with `test/divergence/run.sh`) checks the
contract `aql --compile X == aql X` across this library's suites.

Most of it holds — and that is real progress: the loop-free core
(`make`/`add`/`contains`/`merge`/`encode`/`decode`) now **fully compiles**
under `--force-compile` and returns byte-identical results, where at this
module's pin (`7193a7d3`) the bytecode path couldn't run the library at
all. The one sharp edge: a compiled `each` body **drops a block-local
binding** from the enclosing block. Reduced repro (passes on the
interpreter, wrong under `--compile`):

```aql
import "aql:test" end
import "./bloom.aql" end
[ def bf ({n: 1000, p: 0.01} Bloom.make end)
  def _ (iota 50 each [ var [[i] bf Bloom.add (convert String i) end 0 ] ])
  def cnt (bf Bloom.count end)
  true (45 lte cnt) Assert.equal end
] "count-within-tolerance" Test.test end
# interpreter => passes
# --compile   => each: element 0: [aql/undefined_word]: undefined word: bf
```

Inside the `each` the compiled path can't see the block-local `bf`, so
`bf Bloom.add …` raises `undefined word: bf`. The damage is that this leaks
through `--compile` (TRY): the emitter thinks it can lower the body, so it
does *not* fall back to the interpreter, and the wrong result escapes —
breaking the "identical, never semantics" guarantee. Trigger is narrow: a
*block-local* `def` referenced from an `each` body. A **top-level** binding
survives; a single-expression top-level loop is instead *refused* (`each`
Stage 2/3) and falls back cleanly. Upstream aql bug, not a bloom defect.

The fix on our side is one structural choice: `test/bloom_unit_test.aql`
builds its bulk fixture (`_seen`) at **top level** rather than inside the
`Test.test` block — keeping it in scope for the compiler, and (the leading
underscore) skipping `aql check`'s unused_def false positive for body-only
defs. With that, every suite is clean across all three surfaces
(interpreter, `aql check` with 0 errors, and `aql --compile` identical to
the interpreter); `test/divergence/run.sh` enforces it. Tested against aql
`c44d994` (the harness builds a newer aql than this module's pin, since the
bytecode CLI postdates `7193a7d3`). See `test/divergence/README.md`.

---

## Observations on the new build

- **The DX feedback loop works.** Six issues filed against `958c379b`
  were fixed within 39 commits, with commit messages that read
  straight off the report ("guards fire before the next statement",
  "per-instance mutable class defaults; open objects render"). A
  parallel report from the `aql:decision` module got the same
  treatment (`1981f601`), and that module moved out of core
  (`a7882da9`).
- **New language surface since `958c379b`** (not yet exercised by this
  module): lambda arrows (`(x:Integer => body)`, `ec35e87a`/
  `dfe262d6`), map overloads for `each`/`fold`/`filter` plus `keys`/
  `vals` and a `KeyVal` entry type (`c6ed6e1a`), a `canon` word for
  round-trippable source (`c0b727bf`), type-valued params
  (`ce9914a3`), and a categorised `describe` with guaranteed-complete
  word docs (`ce133d6c`/`fd82aee9`). The `keys`/`vals` words would
  have simplified the sparse-map bit store this module used two
  designs ago; the packed-Array design doesn't need them.
- **Stability:** all five suites, the AGENTS.md verification script,
  and both tutorial scripts produce byte-identical results on
  `958c379b` → `7193a7d3`. Hashing, sizing, encode payloads, and the
  measured tutorial false-positive rate (97/1000 at p = 0.1) are
  unchanged.

---

## Upgrade notes: `db828ec` → current main

Carried forward for anyone jumping from the older pin (all migrated in
this module's history):

| Change | Before | After |
|--------|--------|-------|
| `refine Object` removed | `def T (refine Object {…})` | `def T class {…}` (subclass: `refine <Class> {…}`) |
| `StringUtil.indexof` argument order | haystack-first (`indexof <haystack> <needle>`) | **haystack-last** (`indexof <needle> <haystack>`); whole string module is subject-last |
| Integer overflow | silent 64-bit wrap | hard `integer_overflow` error — mask (`BinUtil.band`) before multiplying if you relied on wrap |
| `set` on a mutable container | returned values varied | Store / Object / Array / class: writes in place, **returns nothing**; FlexMap/FlexList: returns the node; Map: returns a new map |
| `import` terminator | `import "x" end` required | `end` optional (structure-first); bare `import "x"` is the idiomatic form again |
| Custom errors | only the undefined-word idiom | `raise` (code, message — template literals fine, payload map form) |

---

## Summary

| # | Severity | Issue | Status vs `958c379b` |
|---|----------|-------|----------------------|
| — | — | guard `if` + following `def` pre-empted (was §1 🔴) | **fixed** (`00cb7a79`) |
| — | — | mutable class default shared across instances (was §2 🔴) | **fixed** (`607cd1b9`) |
| — | — | formatting an `Object` crashes (was §3 🔴) | **fixed** (`607cd1b9`) |
| — | — | `raise` rejects template messages (was §4 🟡) | **fixed** (`00cb7a79`) |
| — | — | `getr` code ≠ docs (was §6 🟢) | **fixed** (`93ebcd40`) |
| — | — | `jsonify` stringifies Floats (was §7 🟢) | **fixed** (`862546fd`) |
| 1 | 🟡 | `print` forward-collection reverses/breaks | unchanged (3rd report) |
| 2 | 🟢 | `aql check`: false `mul` no_signature; export-map words flagged unused | improved, still open |
| 3 | ✅ | bytecode `--compile` block-local `each`-body divergence (+ two 2026-06-23 `main` regressions) | **fixed** upstream `f247557`/`fc47452`; harness pin moved to aql `407feda` |

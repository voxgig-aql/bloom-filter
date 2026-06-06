# Developer-experience report: bloom-filter on AQL

**Date:** 2026-06-06
**AQL build under test:** `aql-lang/aql` @ `db828ec` (built locally from a
source tarball with `GOFLAGS=-mod=mod`; version string reported as
`aql db828ecb6ee1d161ff177134478f42c56484f051`).
**Context:** building, testing, refactoring, and then upgrading this
bloom-filter module from `5b983b6` to `db828ec`. Everything below was
reproduced first-hand against the build above; each item carries a
minimal repro you can paste into a `.aql` file and run.

Severity: **🔴 high** (silent wrong results / blocks a use case) ·
**🟡 medium** (friction, clear workaround) · **🟢 low** (papercut).

---

## Fixed since the `5b983b6` report

Three issues from the previous report are resolved in `db828ec`:

- **Forward `set` now mutates a `refine Object`.** `b set k v` used to be
  a silent no-op through a typed param; it now persists at the top level
  and through ordinary typed-param fns. *(But see §1 — it regresses
  inside a `Test.test` sub-engine, so it isn't fully usable yet.)*

- **A library that uses `export` can be run directly.** `aql bloom.aql`
  now exits `0` instead of `undefined word: export` — `export` is a
  top-level no-op outside an import context. The separate runnable entry
  point (`test/bloom_smoke_test.aql`) is no longer strictly required.

- **A failing `Test.test` names the case.** Output is now
  `FAIL <name> — [aql/assertion_failure]: Assert.equal: expected X, got Y`,
  so you no longer have to bisect to find which case failed.

  ```aql
  import "aql:test" end
  [ true false Assert.equal end ] "my-failing-case" Test.test end
  # FAIL my-failing-case — [aql/assertion_failure]: Assert.equal: expected false, got true
  ```

---

## Still open

### 1. 🟡 Forward `set`/`get` regress inside a `Test.test` sub-engine

Forward-form `set`/`get` on a `refine Object` now work at the top level
and through plain typed-param fns, but **do not persist when the same
code runs inside a `Test.test` body**. Migrating the bit store to the
cleaner forward form (`bits set k 1`, `bits get k`) passed the spec,
property, and smoke suites but failed exactly one example in the
imperative `Test.test` suite — `add` then `contains` returned `false`
for a just-added key. The library therefore keeps the stack form
(`bits 1 k set`, `bits k get`), which is reliable in every context.

- **Impact:** the natural forward style is unusable for mutate-through
  code that must also run under `Test.test`; you need the stack form.
- **Workaround:** use stack-form `get`/`set` for any object you mutate.

### 2. 🟡 `print` forward-arg collection reverses/breaks chained prints

```aql
(1 add 1) print (2 add 2) print     # prints 4 then 2 — the first
                                    # `print` swallowed (2 add 2)
```

A trailing `print` at end-of-input can also fail to find its argument.
Write `print (value) end` (or `(value) print end`), one value per
statement. Unchanged from the previous build.

### 3. 🟡 `def _ (void-returning-call)` corrupts the next dispatch

Binding the result of a word whose signature returns nothing (e.g. a
mutator declared `[…] []`) leaves stack residue that derails the
following word:

```aql
def Bits (refine Object {})
def mark fn [ [i:Integer b:Bits] [] [ b 1 (convert String i) set ] ]   # returns []
def b (make Bits {})
def _ (mark 5 b)
"ok" print            # error: no matching signature for print
```

Give mutators a return value, or call them as bare statements without
`def`. (This is also why the forward-`set` regression in §1 is easy to
misdiagnose — a void-bound mutator looks similar.)

### 4. 🟢 `make Object {}` is rejected without a hint

```aql
def x (make Object {})
# error: make: expected a constructed object type, got Object
```

Use a `def T (refine Object {…})` subtype (or a `{…}` map literal). The
error doesn't suggest the fix.

### 5. 🟢 `indexof` is haystack-first, against the data-last grain

`indexof` moved into the string module in `db828ec`; it still puts the
haystack at `sig[0]`:

```aql
import "aql:string-util" end
(StringUtil.indexof " ABC" "B")   # => 2   (haystack, needle)
(" ABC" StringUtil.indexof "B")   # => -1  (reads as needle=" ABC")
```

The natural data-piped form gives the wrong answer; write it
fully-forward. Worth a one-line note in the string-module reference.

---

## New in `db828ec`

### N1. 🟡 `import` now requires a terminator

`import` gained an optional second (selective-import) argument, so the
forward form **without `end`** greedily swallows a following value:

```aql
import "aql:string-util"
(StringUtil.indexof " ABC" "B") print end   # undefined word: StringUtil
```

`import` collected the `(…)` as its second argument, so the namespace
never bound. Terminate every import — `import "x" end` — which is what
this module now does throughout. (On `5b983b6` the bare `import "x"` form
was fine; this is a behavioural change, not just a style preference.)

### N2. 🟢 Custom error raising is still absent

There is no word to raise a custom error message; `raise`/`fail`/`throw`
are all undefined (`do [raise "x"] error […]` only "works" because it
catches the `undefined_word: raise` error). `error` remains a
*handler* combinator (`do [risky] error [handler]`). This module still
signals `merge` precondition failures by dispatching a descriptively
named undefined word (`bloom-merge-requires-equal-m`) — the only
catchable, self-describing idiom available.

---

## Upgrade notes: `5b983b6` → `db828ec`

A consumer upgrading across these commits hits several breaking changes
(all migrated in this module's history):

| Change | Before | After |
|--------|--------|-------|
| Util module ids gained `-util` | `aql:math`, `aql:array` | `aql:math-util`, `aql:array-util` (and `string-util`, `bin-util`, `time-util`, …) |
| Module namespaces are PascalCase | `math.log`, `array.where`, `test.test`, `assert.equal` | `MathUtil.log`, `ArrayUtil.where`, `Test.test`, `Assert.equal` |
| Decimal type renamed | `Decimal` | `Float` (with a `Number` supertype) |
| `indexof` moved out of core | core `indexof` | `StringUtil.indexof` (`import "aql:string-util" end`) |
| Bitwise ops moved out of core | core `band`/`bor`/`bxor` | `BinUtil.band`/`.bor`/`.bxor` (`import "aql:bin-util" end`) |
| `import` terminator | `import "x"` ok | `import "x" end` required (N1) |
| `base` is now reserved | usable as a local name | rename the local |

`aql:test`, `aql:report`, and `aql:rand` kept their ids; the property
generator binding is still `r` (`r.int`, `r.string`, …). Core
arithmetic/comparison/boolean words (`add`, `sub`, `mul`, `div`, `mod`,
`eq`, `lte`, `gte`, `and`, `not`) and `slice`/`size`/`iota`/`each`/
`fold`/`all`/`convert`/`get`/`set` remain core.

---

## What worked well

- **Static dispatch & types**, the two test surfaces
  (`Test.test`/`Test.check-prop` and `Test.spec`/`Test.prop`), and the
  `fold`/`each`/`iota`/`ArrayUtil.where` data-flow words all behaved
  predictably once the namespace renames were applied.
- **Error messages** are specific and point at the right span — the
  import-terminator hint (N1) and the new named test failures are real
  improvements. The remaining gaps are the *silent* cases (§1, §3).

---

## Summary

| # | Severity | Issue | Status vs `5b983b6` |
|---|----------|-------|---------------------|
| — | — | Forward `set` no-op on `refine Object` | **fixed** (top level) |
| — | — | `export`-using library can't run directly | **fixed** |
| — | — | Failing `Test.test` not named | **fixed** |
| 1 | 🟡 | Forward `set`/`get` regress inside `Test.test` | new caveat |
| 2 | 🟡 | `print` forward-collection reverses/breaks | unchanged |
| 3 | 🟡 | `def _ (void-call)` corrupts next dispatch | unchanged |
| 4 | 🟢 | `make Object {}` rejected without hint | unchanged |
| 5 | 🟢 | `indexof` haystack-first | unchanged (now in `StringUtil`) |
| N1 | 🟡 | `import` now requires `end` | new |
| N2 | 🟢 | No custom error-raising word | unchanged |

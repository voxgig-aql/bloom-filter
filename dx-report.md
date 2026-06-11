# Developer-experience report: bloom-filter on AQL

**Date:** 2026-06-11
**AQL build under test:** `aql-lang/aql` @ `958c379b`
(`958c379b12295652c739a88f2f198726d48897fb`, main as of 2026-06-11; 110
commits past the previously pinned `db828ec`; built locally with
`GOFLAGS=-mod=mod`; version string reported as `aql 0.1.0-dev`).
**Context:** re-verifying every issue from the `db828ec` report against
current main, then migrating and refactoring this module to use the new
language features (`class`, `Array`, `raise`, native FNV hashing,
`StructUtil.parse`). Everything below was reproduced first-hand against
the build above; each item carries a minimal repro you can paste into a
`.aql` file and run.

Severity: **🔴 high** (silent wrong results / crash / blocks a use case) ·
**🟡 medium** (friction, clear workaround) · **🟢 low** (papercut).

---

## Fixed since the `db828ec` report

Five of the seven issues from the previous report are resolved (and one
more is half-resolved — see §1 below):

- **Forward `set`/`get` now persist inside a `Test.test` sub-engine.**
  The `db828ec` regression — mutations through a typed fn param passing
  the spec suites but vanishing inside `Test.test` — is gone. Verified
  for all three mutable stores this module considered (`class`
  instance, `FlexMap`, `Array`), each mutated through a typed-param fn
  inside a `Test.test` body. This module's bit store now uses the
  forward forms throughout.

- **`import` no longer requires a terminator** (was N1). The
  structure-first, lazy argument-resolution engine landed (aql
  `66876387`, which pulled in this repo's
  [`proposals/lazy-arg-resolution.md`](proposals/lazy-arg-resolution.md))
  — `import "aql:math-util"` followed by ordinary code just works; `end`
  is only needed when the next token could itself be an import argument.
  This module dropped the `end` after every import.

- **Custom error raising exists** (was N2). `raise` takes a message, a
  code + message, or a spec map with payload keys; handlers read
  `e.code` / `e.message` and can dispatch on the code with `case`.
  This module's `merge` precondition failures and the new `make`
  validation and `decode` errors all raise coded errors now
  (`incompatible_merge`, `bad_input`, `bad_payload`); the old idiom of
  dispatching a descriptively-named undefined word is retired.

- **`StringUtil.indexof` is haystack-last** (was §5). The whole string
  module was aligned subject-last (aql `ec5aa25d`), so the data-piped
  form and the all-forward form now agree:

  ```aql
  import "aql:string-util"
  print (StringUtil.indexof "ll" "hello") end   # => 2
  print ("hello" StringUtil.indexof "ll") end   # => 2  (same answer now)
  ```

  The old haystack-first spelling silently returns `-1` — flip the
  arguments when migrating (this bit our property suite, P6).

- **`make Object {}` is no longer rejected** (was §4). `Object` is now a
  first-class open mutable container (`object {…}` sugar). But see §3
  below: *formatting* an Object instance crashes this build.

- **`def _ (void-returning-call)` is a loud error** (was §3, "silent
  stack corruption"). Binding a call that produced no value now fails
  with a located error at the `def` instead of silently derailing a
  later dispatch. (The error is a `signature_error` naming the def —
  the documented `def_error` code seems not to be what's actually
  raised — and the engine may still execute the *following* statement
  while hunting for a value before it gives up, so the failure can
  print interleaved output. Loud and findable, so: fixed, with a
  cosmetic caveat.)

---

## Still open / new in `958c379b`

### 1. 🔴 An else-less guard `if` followed by `def` evaluates the `def` eagerly — and can pre-empt the guard

The classic guard shape — check, raise, fall through — miscompiles
when the next statement is a `def`. The `if`'s optional third slot
forward-collects the `def` statement and evaluates it *during argument
collection*, before the branch is taken; if that evaluation errors, the
error surfaces **instead of the guard's raise**, even when the guard
condition is true:

```aql
def t fn [ [x:Any] [Integer] [
  if ((x is Float) not) [
    def m "not a float"
    raise bad_input m
  ]
  def y (x gt 0.0)      # collected + evaluated by the if, eagerly
  7
] ]
do [t none] error [ get code ]    # => incomparable (from `gt`),
                                  #    NOT the guard's bad_input
```

A following `if` (a function word) acts as a collection barrier, so
*chains* of guard `if`s work — it's the `if`-then-`def` adjacency that
breaks. Remove the trailing `def` and the same guard raises correctly.

- **Impact:** silent mis-ordering — the guard you wrote doesn't run
  first; in the happy path the collected `def` often still binds, so
  the bug hides until an input that should have been rejected reaches
  the code below the guard.
- **Workaround:** give every guard an explicit empty else (or close it
  with `end`):

  ```aql
  if ((x is Float) not) [
    def m "not a float"
    raise bad_input m
  ] []
  ```

  `bloom.aql` does this for all six of its guards. This is the same
  eager-collection family the structure-first engine fixed for
  `import`; a `def` after a block argument looks collectable where a
  word would be a barrier.

### 2. 🔴 A mutable class-field default is evaluated once and shared by every instance

A class schema default is evaluated at *class definition* time and the
resulting value — including a mutable container — is the same value in
every instance:

```aql
def Holder class {store:(flex {})}
def h1 (make Holder {})
def h2 (make Holder {})
def _ (h1.store set k 1 end)
print (h2.store get k) end        # => 1  — h2 sees h1's write
```

- **Impact:** silent cross-instance aliasing for any Array / flex /
  Object default — exactly the famous Python mutable-default-argument
  trap, but with no warning.
- **Workaround:** declare such fields by *type* (required field) and
  pass a fresh container at every `make`. This module's `BloomFilter`
  declares `bits: Array` and every constructor call builds the Array
  explicitly.

### 3. 🔴 Formatting an `Object` instance crashes the interpreter

Any attempt to render an Object — `print`, a template `${…}`, or just
leaving one on the final stack — dies in the Go runtime:

```aql
print (object {a:1}) end
# error: [aql/internal_error]: internal engine error:
#        runtime error: invalid memory address or nil pointer dereference
```

A bare `make Object {}` as a script's final stack panics outright
(SIGSEGV in `kernelFormatDefault`, "this is a bug in AQL; please report
it"). The container otherwise *works* — `typeof`, `size`, `get`/`set`
are fine — it's only the formatter. `Array`, `FlexMap`/`FlexList`, and
class instances (including ones holding Arrays) all format fine.

- **Impact:** blocks debugging any code that uses Object; an innocent
  `print` takes down the script.
- **Workaround:** don't print Objects; convert first (`convert Map o`)
  or use a class / FlexMap instead. This module uses `Array` for its
  bit store and is unaffected.

### 4. 🟡 `raise` does not accept a template-string message

`raise code "literal"` works; `raise code `got ${x}`` (and even the
parenthesised form) fails to match a signature, so the *raise itself*
errors as `signature_error` and your intended code/message are lost:

```aql
raise bad_input `got ${x}`       # => signature_error, not bad_input
```

- **Workaround:** bind the message first — this is what `bloom.aql`
  does everywhere:

  ```aql
  def msg `Bloom.make: n must be an Integer >= 1 (got ${n-val})`
  raise bad_input msg
  ```

### 5. 🟡 `print` forward-arg collection still reverses/breaks chained prints

Unchanged from both previous reports:

```aql
(1 add 1) print (2 add 2) print     # the first print collects (2 add 2)
```

A label-then-value pair prints value-first (the label is printed by the
*next* print, or stranded). The reliable idiom — used throughout this
module's tests now — is one value per statement, fully grouped:

```aql
print (`label: ${value}`) end
```

With that spelling, output appears strictly in source order; the
tutorial's old "first printed line appears last" workaround is obsolete.

### 6. 🟢 `getr` raises `getr_error`, but REFERENCE.md says `not_found`

```aql
do [{a:1} !. zzz] error [ get code ]   # => getr_error
```

REFERENCE.md's error-code table documents `not_found` for strict
lookup. One of the two is stale. (Cosmetic — the error is loud and
catchable either way; `Bloom.decode` fences it and re-raises
`bad_payload`.)

### 7. 🟢 `StructUtil.jsonify` renders Floats as JSON strings

```aql
StructUtil.jsonify {p:0.05}     # => { "p": "0.05" }  — a string
```

A `jsonify` → `parse` round trip therefore changes a Float field's
type. The canon template form (`` `${map}` ``) parses back with types
preserved — `Bloom.encode` uses canon for exactly this reason.

### 8. 🟢 `aql check` is too noisy to gate CI yet

The new static checker runs (`aql check bloom.aql`) but on this module
it reports false `no_signature` errors for code that runs fine
(arithmetic through a def'd constant, `getr`, fn calls), a spurious
`fn_body_error` for `derive-k`, and `unused_def` for every word that is
referenced only by the `export` map. Promising — the advisories are
non-gating and exit 0 — but not yet adoptable as a CI step for a
module shaped like this one.

---

## New features this module now uses

The refactor to `958c379b` wasn't just a migration; the new surface
genuinely improved the library:

- **`class`** (replaces the removed `refine Object`): `BloomFilter` is
  a sealed, strictly-typed record — unknown fields and mis-typed
  writes are loud errors at exactly the right place.
- **`Array` + the `aql:bin-util` bit words** (`BinUtil.set`,
  `BinUtil.test`, `BinUtil.popcount`, `BinUtil.bor`): the bit store
  went from a stringified-index sparse map probed bit-by-bit to a
  packed Array of 63-bit words mutated in place. `count` now
  popcounts one word at a time and `merge` is one `bor` per word —
  ~63× fewer iterations, no string keys. The how-to's big example
  (`n: 100000, p: 0.001`, m ≈ 1.4M bits) — make + 1000 adds + counts +
  merge — runs in ~13 s wall clock on this build.
- **Native FNV-1a hashing** (`BinUtil.fnv32` / `fnv64` — the HOWTO
  even suggests them for bloom filters): replaced ~45 lines of
  hand-rolled hashing including the 95-character printable-ASCII
  alphabet workaround. Any string now hashes correctly, not just
  printable ASCII, and the false-positive rate measured in the
  tutorial improved (97/1000 at a target p = 0.1, vs 79/1000 — the
  old hash under-dispersed).
- **`raise` / `error` / `case`**: coded, payload-carrying errors for
  `make` validation, `merge` compatibility, and `decode` parsing.
- **`StructUtil.parse`**: `Bloom.decode` exists now — `encode` is no
  longer one-way, and the suites property-test the round trip.
- **Integer overflow as a hard error** deserves a call-out: it caught
  a real latent bug in this module. The old `hash2` seeded FNV with
  `1099511628211` (the 64-bit FNV prime); its first multiply exceeds
  int64 and had been silently wrapping on `db828ec`. On this build it
  raises `integer_overflow` on first use — the new behaviour turned an
  invisible wrong-ish result into a visible one-line fix.

## What worked well

- **The migration errors are excellent.** `refine Object` removal
  fails with "define a class instead: def Foo class {…}", pointing at
  the exact line. The `set`-needs-a-terminator hint ("group the call
  with parens — (set …) — or end it with `end` or `;`") is similarly
  actionable.
- **`Test.test` / `Test.check-prop` / spec runners** were stable
  through the whole refactor, and the named-failure output from the
  previous build continues to pay for itself.
- **The structure-first engine is a real DX win** beyond imports:
  every probe in this round needed *fewer* defensive `end`s than the
  `db828ec` equivalents (the residual cases are §1 and `set`'s
  receiver slot).

---

## Upgrade notes: `db828ec` → `958c379b`

Breaking changes a consumer of this build actually hits (all migrated
in this module's history):

| Change | Before | After |
|--------|--------|-------|
| `refine Object` removed | `def T (refine Object {…})` | `def T class {…}` (subclass: `refine <Class> {…}`) |
| `StringUtil.indexof` argument order | haystack-first (`indexof <haystack> <needle>`) | **haystack-last** (`indexof <needle> <haystack>`); whole string module is subject-last |
| Integer overflow | silent 64-bit wrap | hard `integer_overflow` error — mask (`BinUtil.band`) before multiplying if you relied on wrap |
| `set` on a mutable container | returned values varied | Store / Object / Array / class: writes in place, **returns nothing** (so `def r (b set k v)` is an error); FlexMap/FlexList: returns the node; Map: returns a new map |
| `import` terminator | `import "x" end` required | `end` optional (structure-first); bare `import "x"` is the idiomatic form again |
| Custom errors | only the undefined-word idiom | `raise` (code, message, payload); undefined-word dispatch still raises `undefined_word` so old call sites stay catchable |

New surface relevant to small libraries: `class` / `object` / `array` /
`flex` containers, generics (`def Box<T> class {…}`), surfaces
(operation contracts), `case`, `BigInteger`/`BigDecimal` (`0d`
literals), IEEE-754 Float words, `BinUtil` second tier (`ord`, `chr`,
`fnv32`, `fnv64`, `popcount`, `mask`, `extract`, …), `StructUtil.items`
/ `parse` / `jsonify` / `reify`, `aql fmt` / `check` / `describe`, and
an in-memory `aql:vm`.

---

## Summary

| # | Severity | Issue | Status vs `db828ec` |
|---|----------|-------|---------------------|
| — | — | Forward `set`/`get` regress inside `Test.test` | **fixed** |
| — | — | `import` requires `end` (N1) | **fixed** (this repo's proposal landed) |
| — | — | No custom error raising (N2) | **fixed** (`raise`) |
| — | — | `indexof` haystack-first (§5) | **fixed** (now haystack-last — flip call sites) |
| — | — | `make Object {}` rejected (§4) | **fixed**, but see crash in §3 |
| — | — | `def _ (void-call)` silent corruption (§3) | **fixed** (loud, located; minor caveat) |
| 1 | 🔴 | guard `if` + following `def`: eager evaluation pre-empts the guard | new |
| 2 | 🔴 | mutable class-field default shared across instances | new |
| 3 | 🔴 | formatting an `Object` instance crashes (SIGSEGV / internal_error) | new |
| 4 | 🟡 | `raise` rejects template-string messages | new |
| 5 | 🟡 | `print` forward-collection reverses/breaks | unchanged |
| 6 | 🟢 | `getr` code is `getr_error`, docs say `not_found` | new (docs mismatch) |
| 7 | 🟢 | `jsonify` stringifies Floats | new |
| 8 | 🟢 | `aql check` noisy on real code | new feature, not gating-ready |

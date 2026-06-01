# Developer-experience report: bloom-filter on AQL

**Date:** 2026-06-01
**AQL build under test:** `aql-lang/aql` @ `5b983b6` (built locally from a
source tarball with `GOFLAGS=-mod=mod`, version string reported as
`aql 5b983b6c0c9f59908ec6d53403c0880b241d64c6`).
**Context:** building, testing, and refactoring this bloom-filter module
(the library, five test suites, and the docs). Everything in this report
was reproduced first-hand against the build above; each item carries a
minimal repro you can paste into a `.aql` file and run.

Severity: **🔴 high** (silent wrong results / blocks a use case) ·
**🟡 medium** (friction, clear workaround) · **🟢 low** (papercut).

---

## 1. 🔴 `set` in forward form silently does not mutate a `refine Object`

The single most expensive issue this session: it produced wrong results
with **no error**, and cost a long bisection to find.

For a `set` whose store is a `refine Object` passed as a typed
parameter, the **stack** arrangement mutates the store in place, but the
**forward** arrangement neither mutates it nor returns an object with
the value set — the write just vanishes.

```aql
def Bits (refine Object {})
def mark-fwd fn [ [i:Integer b:Bits] [Bits] [ def k (convert String i)  b set k 1  b ] ]
def mark-stk fn [ [i:Integer b:Bits] [Bits] [ def k (convert String i)  b 1 k set  b ] ]

def a (make Bits {})  def ar (mark-fwd 5 a)
def b (make Bits {})  def br (mark-stk 5 b)

print (`forward: orig=${(a get "5")} ret=${(ar get "5")}`) end   # forward: orig=None ret=None
print (`stack:   orig=${(b get "5")} ret=${(br get "5")}`) end   # stack:   orig=1    ret=1
```

Both forms name the same `(key, value, store)` triple — `set`'s
signature is `[Key, Any, Store]`, and forward-precedence should bind
`key→sig[0]`, `value→sig[1]`, `store(from stack)→sig[2]` identically in
either arrangement. Instead the forward form behaves as if it matched a
different overload (or dropped the store), leaving the object untouched
**and** returning an object that doesn't carry the write.

- **Expected:** `b set k v` and `b v k set` produce the same store with
  `k → v`.
- **Actual:** only the stack form sets the key; the forward form is a
  silent no-op.
- **Impact:** in this module the bit store is a `refine Object` and
  `add` marks bits through a typed `bits:Bits` param. Writing the mark in
  forward form (`bits set k 1`) made every `add` write to nothing, so the
  filter behaved as saturated — `contains` returned `true` for every key.
  Nothing raised; only an example-based test that asserts a *negative*
  (`contains "absent"` is `false`) caught it. Property tests that only
  assert "added keys are found" stayed green, because that stays true
  under saturation.
- **Workaround (in use):** keep all bit-store `get`/`set` in stack form.
  This is reasonable to treat as data-piping, but the asymmetry should
  not be silent — at minimum the forward form should mutate identically,
  or raise if it genuinely can't.

---

## 2. 🟡 `print` forward-arg collection makes chained and trailing prints fragile

`print` greedily collects a forward argument, so two grouped prints on
one line reverse, and a trailing `print` at end-of-input can fail to find
its argument.

```aql
(1 add 1) print (2 add 2) print
# prints 4 then 2 — the first `print` swallowed `(2 add 2)`,
# leaving 2 (=1 add 1) for the second print
```

```aql
def x 1
(`value ${x}`) print            # at EOF this can raise:
# error: no matching signature for print
#   = forward args for print may have run into the next word;
#     group the call with parens — (print …) — or end it with `end` or `;`
```

- **Impact:** every diagnostic/REPL-style script needs `print (…) end` or
  a trailing `;`/`end`, and the natural `(expr) print (expr) print`
  pattern silently reorders output. Easy to misread results during
  debugging (it sent me chasing phantom failures more than once).
- **Workaround:** always write `print (…) end`, one value per statement.
- **Suggestion:** the error message is excellent; the surprise is that
  `print` collects forward at all when an argument is already on the
  stack. A stack-first `print` (consume TOS, never collect forward) would
  remove the whole class of papercut.

---

## 3. 🟡 `def _ (void-returning-call)` corrupts subsequent dispatch

Binding the result of a word whose signature returns nothing (e.g. a
mutator declared `[…] []`) via `def` leaves stack residue that derails
the *next* word:

```aql
def Bits (refine Object {})
def mark fn [ [i:Integer b:Bits] [] [ b 1 (convert String i) set ] ]   # returns []
def b (make Bits {})
def _ (mark 5 b)
"done" print
# error: no matching signature for print
#   stack: atom(_) word(def) word() >>>word(print)<<<
```

- **Expected:** `def _ (void-call)` is a no-op binding; the next
  statement runs cleanly.
- **Actual:** the empty result leaves `def _` half-applied; the following
  word sees residue and mis-dispatches.
- **Workaround:** give mutators a return value (return the store), or
  invoke them as bare statements without `def`. This module's `bit-mark`
  is only ever called inside an `each` body that yields `0`, so it didn't
  bite in the library — only in scratch scripts.

---

## 4. 🟡 A module that uses `export` cannot be run directly

```bash
$ aql bloom.aql
error: [aql/undefined_word]: undefined word: export
```

`export` is only defined in an import context, so the library file
cannot also serve as a runnable entry point. The module works around
this with a separate `test/bloom_smoke_test.aql` that `import`s the
library. A no-op `export` at top level (or a documented "libraries are
import-only" stance) would remove the surprise.

---

## 5. 🟢 `make Object {}` is rejected; you must pre-declare a subtype

```aql
def x (make Object {})
# error: make: expected a constructed object type, got Object
```

`make` wants a constructed type, so ad-hoc object construction needs
`def T (refine Object {…})` first. Reasonable, but the error doesn't say
"use a `refine Object` subtype, or a `{…}` map literal," which is the fix.

---

## 6. 🟢 `indexof` is haystack-first, against the data-last grain

String `indexof` puts the haystack at `sig[0]`:

```aql
(indexof "ZZBZZ" "B")   # => 2   (forward: haystack, needle)
("ZZBZZ" indexof "B")   # => -1  (reads as needle="ZZBZZ", haystack="B")
```

Elsewhere the language leans "data-last" (the collection/store trails so
it pipes from the left). For `indexof` the string being searched — the
"data" — sits first, so the natural data-piped form `haystack indexof
needle` gives the wrong answer and you must write the fully-forward
`indexof haystack needle`. Minor, but it's an easy off-by-direction bug
and worth a one-line note in the reference.

---

## 7. 🟢 A failing `test.test` case isn't pinpointed

When an assertion inside a `[…] "name" test.test` block fails, the run
increments `test.fail-count` but doesn't name the failing case. With the
common end-of-file pattern `0 test.fail-count end assert.equal`, the only
error printed points at that *summary* line:

```
error: [aql/assertion_failure]: assert.equal: expected 1, got ---
  121 | 0 test.fail-count end assert.equal end
```

So you learn "one case failed" but not which; I had to bisect by hand.
Surfacing the failing case's `name` (and the expected/actual at the
failing assertion) would make `test.test` debugging much faster. The
property drivers do better here — they report a `failing-input`.

---

## What worked well

- **Static dispatch & types.** `refine Object` subtypes, typed `fn`
  signatures, and forward-precedence dispatch all behaved predictably
  once the rules were internalized; the 2×2 of test files all run clean.
- **Two test surfaces.** Both the declarative spec form
  (`test.spec`/`test.case`/`test.run-spec`,
  `test.prop`/`test.run-property`) and the direct form
  (`test.test`, `test.check-prop`) work and compose well. The only snag
  was discoverability — the example-based spec API isn't in the user
  docs; I found it in `design/NATIVE-MODULES.10.md` and
  `modules/decision_spec.aql`. Worth promoting to the public reference.
- **Error messages.** Where errors do fire (signature mismatches, the
  forward-collection hint in §2), they are specific and point at the
  right span. The gap is the *silent* cases (§1), not the loud ones.
- **`fold` / `each` / `iota` / `array.where`** and the math module read
  naturally in data-piped form and gave no trouble.

---

## Summary

| # | Severity | Issue |
|---|----------|-------|
| 1 | 🔴 | Forward `set` silently doesn't mutate a `refine Object` |
| 2 | 🟡 | `print` forward-collection reverses/breaks chained & trailing prints |
| 3 | 🟡 | `def _ (void-call)` leaves stack residue that breaks the next word |
| 4 | 🟡 | `export`-using libraries can't be run directly |
| 5 | 🟢 | `make Object {}` rejected without a hint toward the fix |
| 6 | 🟢 | `indexof` is haystack-first, cutting against data-last |
| 7 | 🟢 | Failing `test.test` case isn't named in output |

The one that matters is **§1**: a silent, arrangement-dependent
divergence in a core mutating word. Everything else has a clean
workaround.

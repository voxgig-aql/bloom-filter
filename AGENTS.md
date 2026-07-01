# AGENTS.md — using the `Bloom` library

Guidance for an AI coding agent calling this bloom-filter library from an
AQL project. Every code block below is verified to run against
`aql-lang/aql` @ `7b1a4fb`. If you read nothing else, read
[The one calling rule](#the-one-calling-rule) and
[Common mistakes](#common-mistakes).

> **Calling convention — forward args, receiver last:** `Bloom.verb …args
> bf`. Piping `bf Bloom.verb …args` also works; only receiver-first
> `Bloom.verb bf …args` misbinds (silently).

## What it is

A probabilistic set: "have I seen this item?" in little memory, with **no
false negatives** and a tunable false-positive rate. The public surface
is the `Bloom` namespace plus the `BloomFilter` type.

## Import

```aql
import "./bloom.aql"
```

- The path is resolved **relative to the working directory the script is
  run from**, not relative to the importing file. Run scripts from the
  directory where that relative path is valid (adjust the path otherwise).
- No `end` is needed after `import` on this build (the structure-first
  engine landed); a trailing `end` still works and is harmless.
- Do **not** import `aql:math-util`, `aql:array-util`, `aql:bin-util`, or
  `aql:struct-util` yourself — `bloom.aql` imports its own dependencies.

## The one calling rule

AQL is not C/Python/JS: there is no `f(a, b)` and no `obj.method(a)`.
Every public `Bloom.*` word takes the **receiver — the `BloomFilter` — as
its LAST argument**. Because the receiver is last, two orders bind
correctly:

```
Bloom.verb arg1 arg2 receiver     # forward form (canonical)
receiver Bloom.verb arg1 arg2     # piping form (also fine)
```

- **Forward form (preferred/canonical):** verb first, every argument
  forward, receiver last — `Bloom.add "x" bf`.
- **Piping form (equally correct):** the receiver flows in from the left /
  off the stack — `bf Bloom.add "x"`.

Group a call in parens to use its result as a value:

```aql
def bf ({n: 1000, p: 0.01} Bloom.make)
def _ (Bloom.add "alice" bf)
print (Bloom.contains "alice" bf)    # => true
print (bf Bloom.contains "alice")    # => true  (piping — same result)
```

**The only wrong order is receiver-*first*, all-forward.** `Bloom.add bf
"x"` binds `bf` as the *item* (the receiver slot goes unfilled), so the
call *silently* returns the filter unchanged — no error, and `contains`
then reads `false`. Never write `Bloom.verb receiver arg`.

**Avoid unnecessary `end`.** On the pinned (structure-first) build a call
is already terminated by the parens around it — or by being the complete
forward argument of `print` / `def` / another verb — so a trailing `end`
*there* is redundant noise. Reach for parens instead, and reserve `end`
only for a **bare, ungrouped** call at statement level that is followed by
more tokens. A stray `end` is harmless — older snippets still carry them —
but the clean form omits it.

**`aql check`'s `mixed_form_call` info is compatible here.** It nudges
toward the all-forward shape; following it while keeping the receiver last
yields the canonical `Bloom.add "x" bf` — that's correct. Just never let it
push the receiver in front of the args (`Bloom.add bf "x"`).

## API reference (exact call shapes)

Call shapes below use the piping form (`receiver Bloom.verb args`); the
forward form `Bloom.verb args receiver` binds identically (e.g. `Bloom.add
item bf`). Group each in parens to use its result as a value.

| Call | Returns | Notes |
|------|---------|-------|
| `{n: Integer, p: Float} Bloom.make` | `BloomFilter` | `n` = expected distinct items; `p` = target false-positive rate in `(0, 0.5]`. Derives `m`, `k`. Bad arguments raise `bad_input`. |
| `bf Bloom.add item` | the **same** `bf` (mutated) | Any value; stringified internally. Sets `k` bits, increments `added`. |
| `bf Bloom.contains item` | `Boolean` | `false` = **definitely never added**. `true` = *probably* added (may be a false positive). |
| `bf Bloom.count` | `Integer` | **Estimate** of distinct items, not an exact tally. Empty filter ⇒ `0`. |
| `bf Bloom.params` | `Map` | `{n, p, m, k}`. |
| `a Bloom.merge b` | the **same** `a` (mutated) | Union of `a` and `b` into `a`. Requires identical `m` and `k`; else raises `incompatible_merge`. |
| `bf Bloom.encode` | `String` | jsonic snapshot: params + set-bit indices. Round-trips through `Bloom.decode`. |
| `text Bloom.decode` | `BloomFilter` | Rebuild a filter from an `encode` snapshot. Malformed text raises `bad_payload`. |

Construct filters **only** through `Bloom.make`. Treat `BloomFilter`
fields as read-only; mutate through the namespace words.

Errors carry a code and message: catch with `do […] error […]` and read
`e get code` / `e get message` in the handler (dispatch on the code with
`case` if you handle several).

## Copy-paste idioms (all verified)

Create, add, query:

```aql
import "./bloom.aql"
def seen ({n: 10000, p: 0.01} Bloom.make)
def _ (seen Bloom.add "ada")
print (seen Bloom.contains "ada")     # => true
print (seen Bloom.contains "linus")   # => false
```

Add many in a loop (`each` body must yield a value — group the call in parens
and push a `0`):

```aql
def bf ({n: 1000, p: 0.01} Bloom.make)
def _ (iota 50 each [
  var [[i] (bf Bloom.add (convert String i)) 0 ]
])
print (bf Bloom.count)          # => ~50 (an estimate)
```

Merge two filters built with the **same `(n, p)`**:

```aql
def a ({n: 1000, p: 0.01} Bloom.make)
def b ({n: 1000, p: 0.01} Bloom.make)
def _a (a Bloom.add "from-a")
def _b (b Bloom.add "from-b")
def merged (a Bloom.merge b)
print (merged Bloom.contains "from-a")   # => true
print (merged Bloom.contains "from-b")   # => true
```

Guard an incompatible merge (mismatched `(n, p)` raises
`incompatible_merge`):

```aql
def a ({n: 1000, p: 0.01} Bloom.make)
def b ({n:  500, p: 0.01} Bloom.make)    # different n ⇒ different m
def result (do [a Bloom.merge b] error [
  get message                            # or: get code, case […]
])
print (result)
```

In a test, assert the failure (or the specific code) instead:

```aql
import "aql:test"
[a Bloom.merge b] Assert.throws
def e (do [a Bloom.merge b])
incompatible_merge/q (e get code) Assert.equal
```

Persist and reload through the snapshot string:

```aql
def snap (bf Bloom.encode)
def back (snap Bloom.decode)
print (back Bloom.contains "ada")        # => true
```

## Common mistakes

| ✗ Don't write | ✓ Write | Why |
|---------------|---------|-----|
| `Bloom.contains(bf, "x")` | `(bf Bloom.contains "x")` | No `f(a,b)` syntax in AQL. |
| `bf.contains("x")` | `(bf Bloom.contains "x")` | No method-call syntax. |
| `Bloom.add bf "x"` (receiver *first*, all-forward) | `Bloom.add "x" bf` (forward, receiver last) or `bf Bloom.add "x"` (piping) | The receiver is the **last** param; putting it first binds it as the *item* and silently misbinds. The `mixed_form_call` nudge is fine — it points at the forward form. |
| `(bf Bloom.contains "x" end)` everywhere | `(bf Bloom.contains "x")` | Parens already terminate the call — the `end` is redundant. Reserve `end` for a bare statement-level call followed by more tokens. |
| `def bf2 (bf Bloom.add "x")` then use `bf` as "before" | `add` mutates in place | `bf` and the returned value are the **same** object; there is no immutable copy. |
| treat `contains ⇒ true` as certain | verify against source of truth | `true` is probabilistic (≈ rate `p`); only `false` is certain. |
| `a Bloom.merge b` with different `(n, p)` | build both with identical `(n, p)` | Mismatched `m`/`k` raises `incompatible_merge` (read `e get message` for which). |
| `make BloomFilter {…}` | `{n, p} Bloom.make` | Construct only via `Bloom.make` (the class has a required internal `bits` field). |
| `(bf Bloom.count)` for an exact count | read `bf.added` (or `added:` in `Bloom.encode`) | `count` is an estimate; `added` is the exact insert count. |
| `import "aql:math-util"` in your script | nothing | `bloom.aql` imports its own deps. |

A note on `print` while debugging: `print` collects its argument *forward*,
so write `print (value)` — verb first, one value per statement — and output
appears in source order. The **postfix** chain `(a) print (b) print` reverses
(the first `print` collects the second group); avoid it. No `end` is needed on
`print (value)`.

## Where to look next

- `docs/reference.md` — full signatures, stack-in columns, complexity.
- `api.json` — the same API as a machine-readable manifest (exact call
  shapes, argument order, return types).
- `docs/how-to.md` — task recipes (sizing, merge, persist, test).
- `test/bloom_smoke_test.aql` — a complete, runnable worked example.
- `dx-report.md` — known AQL-runtime gotchas observed with this build.

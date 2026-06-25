# AGENTS.md — using the `Bloom` library

Guidance for an AI coding agent calling this bloom-filter library from an
AQL project. Every code block below is verified to run against
`aql-lang/aql` @ `407feda`. If you read nothing else, read
[The one calling rule](#the-one-calling-rule) and
[Common mistakes](#common-mistakes).

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

AQL is not C/Python/JS. There is no `f(a, b)` and no `obj.method(a)`.
A call is **receiver-first, arguments forward**:

```
receiver Bloom.verb arg1 arg2
```

— the **receiver/data comes first**, then the verb, then any extra
arguments in the *forward* position (after the verb). **This forward-argument
form is the preferred, idiomatic shape.** To use a call's result as a value,
group it in parens:

```aql
def bf ({n: 1000, p: 0.01} Bloom.make)
def _ (bf Bloom.add "alice")
print (bf Bloom.contains "alice")    # => true
```

**Prefer the forward form; avoid unnecessary `end`.** On the pinned
(structure-first) build, a call is already terminated by the parens around it
— or by being the complete forward argument of `print` / `def` / another verb
— so a trailing `end` *there* is redundant noise. Don't sprinkle `end` on
every call: reach for parens instead, and reserve `end` only for a **bare,
ungrouped** call at statement level that is followed by more tokens (where the
verb would otherwise swallow the next one). A stray `end` is harmless if you
leave one — older snippets still carry them — but the clean form omits it.

**Keep the receiver first — do *not* flip to an all-forward `verb receiver
arg` order.** `bf Bloom.add "x"` is correct; `Bloom.add bf "x"` is **not**:
these words take their arguments as `(item, receiver)`, so moving the receiver
after the verb binds it to the wrong slot and *silently* misbehaves (the
filter comes back unchanged and `contains` reads `false` — no error). `aql
check` may print a `mixed_form_call` **info** nudging you to an all-forward
rewrite — **ignore it for `Bloom.*` calls**; receiver-first is the intended
form and checks at 0 errors.

## API reference (exact call shapes)

Call shapes below are written in the preferred clean form (forward args, no
redundant `end`); group each in parens to use its result as a value.

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
| `Bloom.add bf "x"` (verb-first / all-forward) | `bf Bloom.add "x"` (receiver first) | These words bind `(item, receiver)`; an all-forward order misbinds and **silently** does nothing. Ignore `aql check`'s `mixed_form_call` nudge here. |
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

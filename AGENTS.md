# AGENTS.md — using the `Bloom` library

Guidance for an AI coding agent calling this bloom-filter library from an
AQL project. Every code block below is verified to run against
`aql-lang/aql` @ `db828ec`. If you read nothing else, read
[The one calling rule](#the-one-calling-rule) and
[Common mistakes](#common-mistakes).

## What it is

A probabilistic set: "have I seen this item?" in little memory, with **no
false negatives** and a tunable false-positive rate. The public surface
is the `Bloom` namespace, plus the `BloomFilter` and `Bits` types.

## Import

```aql
import "./bloom.aql" end
```

- The path is resolved **relative to the working directory the script is
  run from**, not relative to the importing file. Run scripts from the
  directory where that relative path is valid (adjust the path otherwise).
- Do **not** import `aql:math-util` or `aql:array-util` yourself — `bloom.aql`
  imports its own dependencies.

## The one calling rule

AQL is not C/Python/JS. There is no `f(a, b)` and no `obj.method(a)`.
A call is written:

```
receiver Bloom.verb arg1 arg2 end
```

— the **receiver/data comes first**, then the verb, then any extra
arguments, and the call is **terminated with `end`** (or wrapped in
parens). Without a terminator the verb swallows whatever token follows it
and you get wrong results or a dispatch error.

```aql
def bf ({n: 1000, p: 0.01} Bloom.make end)
def _ (bf Bloom.add "alice" end)
(bf Bloom.contains "alice" end) print    # => true
```

`(… )` parentheses count as a terminator, so `(bf Bloom.contains "x")` is
fine too; use `end` for top-level statements that aren't already wrapped.

## API reference (exact call shapes)

| Call | Returns | Notes |
|------|---------|-------|
| `{n: Integer, p: Float} Bloom.make end` | `BloomFilter` | `n` = expected distinct items; `p` = target false-positive rate in `(0, 0.5]`. Derives `m`, `k`. |
| `bf Bloom.add item end` | the **same** `bf` (mutated) | Any value; stringified internally. Sets `k` bits, increments `added`. |
| `bf Bloom.contains item end` | `Boolean` | `false` = **definitely never added**. `true` = *probably* added (may be a false positive). |
| `bf Bloom.count end` | `Integer` | **Estimate** of distinct items, not an exact tally. Empty filter ⇒ `0`. `O(m)`. |
| `bf Bloom.params end` | `Map` | `{n, p, m, k}`. |
| `a Bloom.merge b end` | the **same** `a` (mutated) | Union of `a` and `b` into `a`. Requires identical `m` and `k`. `O(m)`. |
| `bf Bloom.encode end` | `String` | jsonic snapshot: params + set-bit indices. One-way (no `decode`). |

Construct filters **only** through `Bloom.make`. Treat `BloomFilter`
fields as read-only; mutate through the namespace words.

## Copy-paste idioms (all verified)

Create, add, query:

```aql
import "./bloom.aql" end
def seen ({n: 10000, p: 0.01} Bloom.make end)
def _ (seen Bloom.add "ada" end)
(seen Bloom.contains "ada"   end) print   # => true
(seen Bloom.contains "linus" end) print   # => false
```

Add many in a loop (`each` body must yield a value — push a `0`):

```aql
def bf ({n: 1000, p: 0.01} Bloom.make end)
def _ (iota 50 each [
  var [[i] bf Bloom.add (convert String i) end 0 ]
])
(bf Bloom.count end) print                # => ~50 (an estimate)
```

Merge two filters built with the **same `(n, p)`**:

```aql
def a ({n: 1000, p: 0.01} Bloom.make end)
def b ({n: 1000, p: 0.01} Bloom.make end)
def _a (a Bloom.add "from-a" end)
def _b (b Bloom.add "from-b" end)
def merged (a Bloom.merge b end)
(merged Bloom.contains "from-a" end) print   # => true
(merged Bloom.contains "from-b" end) print   # => true
```

Guard an incompatible merge (mismatched `(n, p)` raises):

```aql
def a ({n: 1000, p: 0.01} Bloom.make end)
def b ({n:  500, p: 0.01} Bloom.make end)    # different n ⇒ different m
def result (do [a Bloom.merge b end] error [
  var [[e] "incompatible filters — rebuild b with a's (n, p)" ]
])
result print
```

In a test, assert the failure instead:

```aql
import "aql:test" end
[a Bloom.merge b end] Assert.throws end
```

## Common mistakes

| ✗ Don't write | ✓ Write | Why |
|---------------|---------|-----|
| `Bloom.contains(bf, "x")` | `bf Bloom.contains "x" end` | No `f(a,b)` syntax in AQL. |
| `bf.contains("x")` | `bf Bloom.contains "x" end` | No method-call syntax. |
| `bf Bloom.add "x"` (no terminator, mid-expression) | `bf Bloom.add "x" end` | The verb swallows the next token without `end`/parens. |
| `def bf2 (bf Bloom.add "x" end)` then use `bf` as "before" | `add` mutates in place | `bf` and the returned value are the **same** object; there is no immutable copy. |
| treat `contains ⇒ true` as certain | verify against source of truth | `true` is probabilistic (≈ rate `p`); only `false` is certain. |
| `a Bloom.merge b end` with different `(n, p)` | build both with identical `(n, p)` | Mismatched `m`/`k` raises `undefined_word: bloom-merge-requires-equal-m` (or `…-k`). |
| `make BloomFilter {…}` | `{n, p} Bloom.make end` | Construct only via `Bloom.make`. |
| `(bf Bloom.count end)` for an exact count | read `added` via `Bloom.encode`/`bf.added` | `count` is an estimate; `added` is the exact insert count. |
| `import "aql:math-util"` in your script | nothing | `bloom.aql` imports its own deps. |

A note on `print` while debugging: `print` collects a forward argument,
so `(a) print (b) print` reverses and a bare trailing `print` may fail to
find its value. Write `print (value) end` (or `(value) print end`), one
value per statement.

## Where to look next

- `docs/reference.md` — full signatures, stack-in columns, complexity.
- `api.json` — the same API as a machine-readable manifest (exact call
  shapes, argument order, return types).
- `docs/how-to.md` — task recipes (sizing, merge, persist, test).
- `test/bloom_smoke_test.aql` — a complete, runnable worked example.
- `dx-report.md` — known AQL-runtime gotchas observed with this build.

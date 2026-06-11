# AGENTS.md — using the `Bloom` library

Guidance for an AI coding agent calling this bloom-filter library from an
AQL project. Every code block below is verified to run against
`aql-lang/aql` @ `958c379b`. If you read nothing else, read
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
A call is written:

```
receiver Bloom.verb arg1 arg2 end
```

— the **receiver/data comes first**, then the verb, then any extra
arguments, and the call is **terminated with `end`** (or wrapped in
parens). Without a terminator the verb can swallow whatever token
follows it and you get wrong results or a dispatch error.

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
| `{n: Integer, p: Float} Bloom.make end` | `BloomFilter` | `n` = expected distinct items; `p` = target false-positive rate in `(0, 0.5]`. Derives `m`, `k`. Bad arguments raise `bad_input`. |
| `bf Bloom.add item end` | the **same** `bf` (mutated) | Any value; stringified internally. Sets `k` bits, increments `added`. |
| `bf Bloom.contains item end` | `Boolean` | `false` = **definitely never added**. `true` = *probably* added (may be a false positive). |
| `bf Bloom.count end` | `Integer` | **Estimate** of distinct items, not an exact tally. Empty filter ⇒ `0`. |
| `bf Bloom.params end` | `Map` | `{n, p, m, k}`. |
| `a Bloom.merge b end` | the **same** `a` (mutated) | Union of `a` and `b` into `a`. Requires identical `m` and `k`; else raises `incompatible_merge`. |
| `bf Bloom.encode end` | `String` | jsonic snapshot: params + set-bit indices. Round-trips through `Bloom.decode`. |
| `text Bloom.decode end` | `BloomFilter` | Rebuild a filter from an `encode` snapshot. Malformed text raises `bad_payload`. |

Construct filters **only** through `Bloom.make`. Treat `BloomFilter`
fields as read-only; mutate through the namespace words.

Errors carry a code and message: catch with `do […] error […]` and read
`e get code` / `e get message` in the handler (dispatch on the code with
`case` if you handle several).

## Copy-paste idioms (all verified)

Create, add, query:

```aql
import "./bloom.aql"
def seen ({n: 10000, p: 0.01} Bloom.make end)
def _ (seen Bloom.add "ada" end)
print ((seen Bloom.contains "ada"   end)) end   # => true
print ((seen Bloom.contains "linus" end)) end   # => false
```

Add many in a loop (`each` body must yield a value — push a `0`):

```aql
def bf ({n: 1000, p: 0.01} Bloom.make end)
def _ (iota 50 each [
  var [[i] bf Bloom.add (convert String i) end 0 ]
])
print ((bf Bloom.count end)) end          # => ~50 (an estimate)
```

Merge two filters built with the **same `(n, p)`**:

```aql
def a ({n: 1000, p: 0.01} Bloom.make end)
def b ({n: 1000, p: 0.01} Bloom.make end)
def _a (a Bloom.add "from-a" end)
def _b (b Bloom.add "from-b" end)
def merged (a Bloom.merge b end)
print ((merged Bloom.contains "from-a" end)) end   # => true
print ((merged Bloom.contains "from-b" end)) end   # => true
```

Guard an incompatible merge (mismatched `(n, p)` raises
`incompatible_merge`):

```aql
def a ({n: 1000, p: 0.01} Bloom.make end)
def b ({n:  500, p: 0.01} Bloom.make end)    # different n ⇒ different m
def result (do [a Bloom.merge b end] error [
  get message                                # or: get code, case […]
])
print (result) end
```

In a test, assert the failure (or the specific code) instead:

```aql
import "aql:test"
[a Bloom.merge b end] Assert.throws end
def e (do [a Bloom.merge b end])
incompatible_merge/q (e get code) Assert.equal end
```

Persist and reload through the snapshot string:

```aql
def snap (bf Bloom.encode end)
def back (snap Bloom.decode end)
print ((back Bloom.contains "ada" end)) end        # => true
```

## Common mistakes

| ✗ Don't write | ✓ Write | Why |
|---------------|---------|-----|
| `Bloom.contains(bf, "x")` | `bf Bloom.contains "x" end` | No `f(a,b)` syntax in AQL. |
| `bf.contains("x")` | `bf Bloom.contains "x" end` | No method-call syntax. |
| `bf Bloom.add "x"` (no terminator, mid-expression) | `bf Bloom.add "x" end` | The verb swallows the next token without `end`/parens. |
| `def bf2 (bf Bloom.add "x" end)` then use `bf` as "before" | `add` mutates in place | `bf` and the returned value are the **same** object; there is no immutable copy. |
| treat `contains ⇒ true` as certain | verify against source of truth | `true` is probabilistic (≈ rate `p`); only `false` is certain. |
| `a Bloom.merge b end` with different `(n, p)` | build both with identical `(n, p)` | Mismatched `m`/`k` raises `incompatible_merge` (read `e get message` for which). |
| `make BloomFilter {…}` | `{n, p} Bloom.make end` | Construct only via `Bloom.make` (the class has a required internal `bits` field). |
| `(bf Bloom.count end)` for an exact count | read `bf.added` (or `added:` in `Bloom.encode`) | `count` is an estimate; `added` is the exact insert count. |
| `import "aql:math-util"` in your script | nothing | `bloom.aql` imports its own deps. |

A note on `print` while debugging: `print` collects a forward argument,
so `(a) print (b) print` reverses and a bare trailing `print` may fail to
find its value. Write `print (value) end` — one value per statement —
and output appears in source order.

## Where to look next

- `docs/reference.md` — full signatures, stack-in columns, complexity.
- `docs/how-to.md` — task recipes (sizing, merge, persist, test).
- `test/bloom_smoke_test.aql` — a complete, runnable worked example.
- `dx-report.md` — known AQL-runtime gotchas observed with this build.

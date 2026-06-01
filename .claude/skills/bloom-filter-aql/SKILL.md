---
name: bloom-filter-aql
description: Use when writing or editing AQL code that calls the Bloom bloom-filter library — Bloom.make / Bloom.add / Bloom.contains / Bloom.count / Bloom.params / Bloom.merge / Bloom.encode, or any file that does `"./bloom.aql" import`. Provides the exact AQL calling convention (which is not C/Python/JS), the API with mutation and probabilistic semantics, verified copy-paste idioms, and fixes for the mistakes agents most often make (foreign call syntax like `bf.contains(x)`, missing `end` terminators, assuming `add` returns a new filter).
---

# Calling the Bloom bloom-filter library (AQL)

A probabilistic set: "have I seen this item?" in little memory, with **no
false negatives** and a tunable false-positive rate. Public surface = the
`Bloom` namespace. Everything below is verified against `aql @ 5b983b6`.

## Import

```aql
"./bloom.aql" import end
```

- Path resolves relative to the **working directory the script runs
  from**, not the importing file. Adjust the relative path accordingly.
- Do **not** import `aql:math` or `aql:array` — the library does it.

## The one calling rule

AQL has no `f(a, b)` and no `obj.method(a)`. Write:

```
receiver Bloom.verb arg1 arg2 end
```

Receiver/data first, then the verb, then any extra args, **terminated
with `end`** (or wrap the whole call in parentheses). Without a
terminator the verb swallows the following token — wrong result or a
dispatch error.

## API

| Call | Returns | Notes |
|------|---------|-------|
| `{n: Integer, p: Decimal} Bloom.make end` | `BloomFilter` | `n` = expected distinct items; `p` = target false-positive rate in `(0, 0.5]`. |
| `bf Bloom.add item end` | the **same** `bf` (mutated in place) | Any value, stringified internally. |
| `bf Bloom.contains item end` | `Boolean` | `false` = **definitely never added**; `true` = *probably* added (false-positive rate ≈ `p`). |
| `bf Bloom.count end` | `Integer` | **Estimate** of distinct items, not a tally. Empty ⇒ `0`. |
| `bf Bloom.params end` | `Map` | `{n, p, m, k}`. |
| `a Bloom.merge b end` | the **same** `a` (mutated) | Union into `a`. Requires identical `m`/`k` (same `(n, p)`); else raises. |
| `bf Bloom.encode end` | `String` | jsonic snapshot; one-way (no `decode`). |

Construct filters only via `Bloom.make`; treat `BloomFilter` fields as
read-only.

## Idioms (verified)

```aql
"./bloom.aql" import end
def seen ({n: 10000, p: 0.01} Bloom.make end)
def _ (seen Bloom.add "ada" end)
(seen Bloom.contains "ada"   end) print   # => true
(seen Bloom.contains "linus" end) print   # => false
```

Add many (each body must yield a value — push `0`):

```aql
def bf ({n: 1000, p: 0.01} Bloom.make end)
def _ (iota 50 each [
  var [[i] bf Bloom.add (convert String i) end 0 ]
])
```

Merge (both built with the same `(n, p)`); guard the incompatible case:

```aql
def merged (a Bloom.merge b end)
def safe (do [a Bloom.merge b end] error [ var [[e] "incompatible (n, p)" ] ])
```

## Common mistakes

| ✗ Don't | ✓ Do | Why |
|---------|------|-----|
| `Bloom.contains(bf, "x")` / `bf.contains("x")` | `bf Bloom.contains "x" end` | AQL has no call/method syntax. |
| `bf Bloom.add "x"` mid-expression, no terminator | `bf Bloom.add "x" end` | The verb swallows the next token. |
| keep a pre-`add` copy of `bf` | none — `add` mutates in place | The argument and the return value are the same object. |
| trust `contains ⇒ true` | verify against the real store | `true` is probabilistic; only `false` is certain. |
| `a Bloom.merge b end` with different `(n, p)` | same `(n, p)` for both | Mismatch raises `undefined_word: bloom-merge-requires-equal-m`/`-k`. |
| `make BloomFilter {…}` | `{n, p} Bloom.make end` | Construct only via `Bloom.make`. |
| `(bf Bloom.count end)` for an exact count | read `bf.added` / `Bloom.encode` | `count` is an estimate; `added` is exact. |

If the full repo is available, `AGENTS.md` and `docs/reference.md` have
the complete guide; `test/bloom_smoke_test.aql` is a runnable example.

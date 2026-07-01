---
name: bloom-filter-aql
description: Use when writing or editing AQL code that calls the Bloom bloom-filter library — Bloom.make / Bloom.add / Bloom.contains / Bloom.count / Bloom.params / Bloom.merge / Bloom.encode / Bloom.decode, or any file that does `import "./bloom.aql"`. Provides the exact AQL calling convention (which is not C/Python/JS), the API with mutation and probabilistic semantics, verified copy-paste idioms, and fixes for the mistakes agents most often make (foreign call syntax like `bf.contains(x)`, putting the receiver *first* in an all-forward `Bloom.add bf x` order that silently misbinds — the receiver goes LAST, over-using `end`, assuming `add` returns a new filter).
---

# Calling the Bloom bloom-filter library (AQL)

A probabilistic set: "have I seen this item?" in little memory, with **no
false negatives** and a tunable false-positive rate. Public surface = the
`Bloom` namespace. Everything below is verified against `aql @ 7b1a4fb`.

## Import

```aql
import "./bloom.aql"
```

- Path resolves relative to the **working directory the script runs
  from**, not the importing file. Adjust the relative path accordingly.
- No `end` is needed after `import` on this build (a trailing `end` is
  harmless).
- Do **not** import `aql:math-util` / `aql:array-util` / `aql:bin-util` /
  `aql:struct-util` — the library does it.

## The one calling rule

AQL has no `f(a, b)` and no `obj.method(a)`. Every public `Bloom.*` word
takes the **receiver — the `BloomFilter` — as its LAST argument**. Because
the receiver is last, two orders bind correctly:

```
Bloom.verb arg1 arg2 receiver     # forward form (canonical)
receiver Bloom.verb arg1 arg2     # piping form (also fine)
```

- **Forward form (preferred/canonical):** verb first, every argument
  forward, receiver last — `Bloom.add "x" bf`.
- **Piping form (equally correct):** the receiver flows in from the left /
  off the stack — `bf Bloom.add "x"`.

Group the call in parens to use its result as a value:
`(Bloom.contains "x" bf)` or `(bf Bloom.contains "x")`.

- **The only wrong order is receiver-*first*, all-forward.**
  `Bloom.add bf "x"` binds `bf` as the *item* (the receiver slot goes
  unfilled), so the call *silently* returns the filter unchanged — no error.
  Never write `Bloom.verb receiver arg`.
- **Avoid unnecessary `end`.** On this (structure-first) build the parens
  around a call already terminate it — as does being the complete forward
  argument of `print` / `def` / another verb — so a trailing `end` there is
  redundant. Reach for parens; reserve `end` only for a bare statement-level
  call followed by more tokens. (A stray `end` is harmless.)
- **`aql check`'s `mixed_form_call` info is compatible here.** It nudges
  toward the all-forward shape; following it while keeping the receiver last
  yields the canonical `Bloom.add "x" bf` — that's correct. Just never let it
  push the receiver in front of the args (`Bloom.add bf "x"`).

## API

| Call | Returns | Notes |
|------|---------|-------|
| `{n: Integer, p: Float} Bloom.make` | `BloomFilter` | `n` = expected distinct items; `p` = target false-positive rate in `(0, 0.5]`. Bad arguments raise `bad_input`. |
| `bf Bloom.add item` | the **same** `bf` (mutated in place) | Any value, stringified internally. |
| `bf Bloom.contains item` | `Boolean` | `false` = **definitely never added**; `true` = *probably* added (false-positive rate ≈ `p`). |
| `bf Bloom.count` | `Integer` | **Estimate** of distinct items, not a tally. Empty ⇒ `0`. |
| `bf Bloom.params` | `Map` | `{n, p, m, k}`. |
| `a Bloom.merge b` | the **same** `a` (mutated) | Union into `a`. Requires identical `m`/`k` (same `(n, p)`); else raises `incompatible_merge`. |
| `bf Bloom.encode` | `String` | jsonic snapshot; round-trips through `Bloom.decode`. |
| `text Bloom.decode` | `BloomFilter` | Rebuild from a snapshot; malformed text raises `bad_payload`. |

Construct filters only via `Bloom.make`; treat `BloomFilter` fields as
read-only. Catch errors with `do […] error […]`; read `e get code` /
`e get message` in the handler.

By-design notes (AQL semantics that bite here):

- **`eq` is identity, not structural equality.** `Bloom.params` returns a
  fresh `Map`, so comparing two params maps with `eq` is `false` even when
  equal — use `deq` for structural comparison of Maps/Lists.
- **A `BloomFilter` mutates in place** (`add`/`merge`), unlike Maps/Lists,
  which are immutable and copy-return from `set`/`get`. There is no immutable
  filter copy; keep no "before" alias.
- **Integer overflow fails loud.** AQL ints are 63-bit and raise
  `integer_overflow` rather than wrapping — an absurd `n` to `Bloom.make`
  errors, it does not silently truncate.

## Idioms (verified)

```aql
import "./bloom.aql"
def seen ({n: 10000, p: 0.01} Bloom.make)
def _ (seen Bloom.add "ada")
print (seen Bloom.contains "ada")     # => true
print (seen Bloom.contains "linus")   # => false
```

Add many (each body must yield a value — group the call in parens, push `0`):

```aql
def bf ({n: 1000, p: 0.01} Bloom.make)
def _ (iota 50 each [
  var [[i] (bf Bloom.add (convert String i)) 0 ]
])
```

Merge (both built with the same `(n, p)`); guard the incompatible case:

```aql
def merged (a Bloom.merge b)
def safe (do [a Bloom.merge b] error [ get message ])
```

Persist and reload:

```aql
def snap (bf Bloom.encode)
def back (snap Bloom.decode)
```

## Common mistakes

| ✗ Don't | ✓ Do | Why |
|---------|------|-----|
| `Bloom.contains(bf, "x")` / `bf.contains("x")` | `(bf Bloom.contains "x")` | AQL has no call/method syntax. |
| `Bloom.add bf "x"` (receiver *first*, all-forward) | `Bloom.add "x" bf` (forward, receiver last) or `bf Bloom.add "x"` (piping) | The receiver is the **last** param; putting it first binds it as the *item* and silently misbinds. The `mixed_form_call` nudge is fine — it points at the forward form. |
| `(bf Bloom.contains "x" end)` everywhere | `(bf Bloom.contains "x")` | Parens already terminate — the `end` is redundant. |
| keep a pre-`add` copy of `bf` | none — `add` mutates in place | The argument and the return value are the same object. |
| trust `contains ⇒ true` | verify against the real store | `true` is probabilistic; only `false` is certain. |
| `a Bloom.merge b` with different `(n, p)` | same `(n, p)` for both | Mismatch raises `incompatible_merge`. |
| `make BloomFilter {…}` | `{n, p} Bloom.make` | Construct only via `Bloom.make`. |
| `(bf Bloom.count)` for an exact count | read `bf.added` / `Bloom.encode` | `count` is an estimate; `added` is exact. |
| `(v) print (w) print` (postfix chain) | `print (v)`, one per statement | `print` collects forward; the postfix chain prints out of order. |

If the full repo is available, `AGENTS.md`, `api.json` (machine-readable
signatures), and `docs/reference.md` have the complete guide;
`test/bloom_smoke_test.aql` is a runnable example.

# Reference

Technical description of the `bloom-filter` module's public surface.
This page is information-oriented: it states what each word is, its
stack signature, and what it returns. For *why* the filter behaves the
way it does, see [Explanation](explanation.md); for goal-directed
recipes, see the [How-to guides](how-to.md).

The module exports a single namespace, `Bloom`, plus two types. Import
it with:

```aql
"./bloom.aql" import end
```

A consuming script does **not** need to import `aql:math` or
`aql:array` itself — `bloom.aql` imports them internally.

---

## Calling convention

Every operation is a forward-dispatched word and must be terminated
with `end` (or wrapped in parentheses) at the call site, e.g.
`bf Bloom.add "x" end` or `(bf Bloom.add "x")`. Without a terminator
the word collects the following token as an argument. This is general
AQL forward-precedence behaviour, not specific to this module.

Argument order follows the AQL rule "first signature parameter is the
top of the stack". The call-site columns below show the natural
left-to-right order to write.

---

## Types

### `BloomFilter`

A `refine Object` subtype — the filter instance. Fields:

| Field   | Type     | Meaning                                            |
|---------|----------|----------------------------------------------------|
| `n`     | Integer  | Target capacity (expected number of distinct items)|
| `p`     | Decimal  | Target false-positive probability                  |
| `m`     | Integer  | Derived bit-array width                             |
| `k`     | Integer  | Derived number of hash functions                   |
| `added` | Integer  | Count of `add` calls made against this filter      |
| `bits`  | `Bits`   | Sparse bit storage                                 |

Instances are created only through `Bloom.make`. Treat the fields as
read-only; mutate exclusively through the namespace words.

### `Bits`

A `refine Object {}` used as a sparse bit set: a set bit at index `i`
is stored as the field `"<i>": 1`. Indices that were never set are
absent (and read as `0`). Internal to the module; you should not need
to touch it directly.

---

## Words

### `Bloom.make`

Construct a filter sized for a target capacity and false-positive rate.

| | |
|--|--|
| **Call**    | `{n: Integer, p: Decimal} Bloom.make end` |
| **Stack in**| an options Map with keys `n` and `p` |
| **Returns** | `BloomFilter` |

`m` and `k` are derived from `n` and `p` (see
[Explanation §Sizing](explanation.md#sizing-the-filter)). `p` must be
in `(0, 1)`; values `> 0.5` round `k` down toward `0` and are not
useful.

```aql
def bf ({n: 1000, p: 0.01} Bloom.make end)
(bf Bloom.params end) print
# => {"k": 7, "m": 9586, "n": 1000, "p": 0.01}
```

### `Bloom.add`

Insert an item. Any value is accepted; it is stringified internally
before hashing.

| | |
|--|--|
| **Call**    | `bf Bloom.add item end` |
| **Stack in**| `BloomFilter`, then the item (`Any`) |
| **Returns** | the same `BloomFilter`, mutated in place |
| **Effect**  | sets `k` bits; increments `added` by 1 |

`add` mutates the filter it is given and also returns it, so the
return value and the argument are the same object. Adding the same
item twice sets no new bits but still increments `added`.

### `Bloom.contains`

Test membership.

| | |
|--|--|
| **Call**    | `bf Bloom.contains item end` |
| **Stack in**| `BloomFilter`, then the item (`Any`) |
| **Returns** | `Boolean` |

`false` means the item was **definitely never added**. `true` means
the item was **probably added** — it may be a false positive at
approximately rate `p`. There are no false negatives. See
[Explanation §No false negatives](explanation.md#why-there-are-no-false-negatives).

```aql
def _ (bf Bloom.add "alice" end)
(bf Bloom.contains "alice" end) print   # => true
(bf Bloom.contains "carol" end) print   # => false
```

### `Bloom.count`

Estimate the number of distinct items added.

| | |
|--|--|
| **Call**    | `bf Bloom.count end` |
| **Stack in**| `BloomFilter` |
| **Returns** | `Integer` (estimate) |

Uses the Swamidass–Baldi estimator over the set-bit population, with a
guard that returns the exact `added` count when every bit is set. The
result is an **approximation** and typically drifts below the true
insert count as the filter fills (e.g. 100 distinct inserts into a
`{n:1000, p:0.01}` filter estimates ≈ 90). An empty filter counts `0`.
Cost is `O(m)`.

### `Bloom.params`

Return the filter's parameters as a Map.

| | |
|--|--|
| **Call**    | `bf Bloom.params end` |
| **Stack in**| `BloomFilter` |
| **Returns** | `Map` with integer/decimal keys `n`, `p`, `m`, `k` |

```aql
def ps (bf Bloom.params end)
(ps "m" get) print   # => 9586
```

### `Bloom.merge`

Union two filters into the first.

| | |
|--|--|
| **Call**    | `a Bloom.merge b end` |
| **Stack in**| target `BloomFilter` `a`, then source `BloomFilter` `b` |
| **Returns** | `a`, now containing every bit that was set in `a` or `b` |
| **Effect**  | mutates `a` in place; `b` is unchanged; `a.added` becomes `a.added + b.added` |
| **Errors**  | raises if `a` and `b` have different `m` or `k` |

Both filters must have identical `m` and `k`, which happens
automatically when both were built with the same `(n, p)`. After a
merge, every item present in `a` or `b` reads as contained.

On a precondition violation `merge` raises a catchable error —
`undefined_word: bloom-merge-requires-equal-m` (or `…-equal-k`). Trap
it with `do […] error […]` or `assert.throws`. (The unusual error
class is a consequence of aql 5b983b6 removing custom error raising;
see [Explanation §Raising errors](explanation.md#raising-errors-in-aql-5b983b6).)

### `Bloom.encode`

Serialize the filter to a jsonic-style string snapshot.

| | |
|--|--|
| **Call**    | `bf Bloom.encode end` |
| **Stack in**| `BloomFilter` |
| **Returns** | `String` |

The string carries `n`, `p`, `m`, `k`, `added`, and the sorted list of
set bit indices. Cost is `O(m)`.

```aql
(bf Bloom.encode end) print
# => {added:1 k:7 m:9586 n:1000 p:0.01 set:[223 1110 2827 3714 4601 6318 7205]}
```

There is no `decode` word in the public surface today; `encode` is a
one-way snapshot suitable for logging, inspection, or persistence.

---

## Errors at a glance

| Situation                              | Result |
|----------------------------------------|--------|
| `merge` with mismatched `m`            | raises `undefined_word: bloom-merge-requires-equal-m` |
| `merge` with mismatched `k`            | raises `undefined_word: bloom-merge-requires-equal-k` |
| missing `end` after a `Bloom.*` call   | dispatch error on the following word (add `end` or parens) |

## Complexity

| Word       | Cost   |
|------------|--------|
| `make`     | `O(1)` |
| `add`      | `O(k)` |
| `contains` | `O(k)` |
| `count`    | `O(m)` |
| `params`   | `O(1)` |
| `merge`    | `O(m)` |
| `encode`   | `O(m)` |

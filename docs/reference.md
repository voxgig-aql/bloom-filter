# Reference

Technical description of the `bloom-filter` module's public surface.
This page is information-oriented: it states what each word is, its
stack signature, and what it returns. For *why* the filter behaves the
way it does, see [Explanation](explanation.md); for goal-directed
recipes, see the [How-to guides](how-to.md).

> **AI agents:** [AGENTS.md](../AGENTS.md) condenses the calling
> convention, idioms, and common mistakes for machine use.

The module exports a single namespace, `Bloom`, plus the `BloomFilter`
type. Import it with:

```aql
import "./bloom.aql"
```

(No `end` is required after `import` on the pinned build; a trailing
`end` is harmless.) A consuming script does **not** need to import
`aql:math-util`, `aql:array-util`, `aql:bin-util`, or `aql:struct-util`
itself — `bloom.aql` imports them internally.

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

A sealed `class` instance — the filter. Fields:

| Field   | Type     | Meaning                                            |
|---------|----------|----------------------------------------------------|
| `n`     | Integer  | Target capacity (expected number of distinct items)|
| `p`     | Float    | Target false-positive probability                  |
| `m`     | Integer  | Derived bit-array width                             |
| `k`     | Integer  | Derived number of hash functions                   |
| `added` | Integer  | Count of `add` calls made against this filter      |
| `bits`  | Array    | Packed bit storage — 63 bits per integer word      |

Instances are created only through `Bloom.make`. Treat the fields as
read-only; mutate exclusively through the namespace words. (The class
is sealed and strictly typed, so writing an unknown field or a
mis-typed value is a loud error.)

`bits` is internal: an `Array` of `ceil(m / 63)` integer words, bit
`i` living at bit `i mod 63` of word `i div 63`. Bit 63 (the sign
bit) is never used, so every word stays a plain non-negative Integer.

---

## Words

### `Bloom.make`

Construct a filter sized for a target capacity and false-positive rate.

| | |
|--|--|
| **Call**    | `{n: Integer, p: Float} Bloom.make end` |
| **Stack in**| an options Map with keys `n` and `p` |
| **Returns** | `BloomFilter` |
| **Errors**  | raises `bad_input` when `n` is not an Integer ≥ 1 or `p` is not a Float in `(0, 0.5]` |

`m` and `k` are derived from `n` and `p` (see
[Explanation §Sizing](explanation.md#sizing-the-filter)). The bounds
are enforced: a `p` above `0.5` would round `k` toward `0`, so it is
rejected rather than accepted uselessly.

```aql
def bf ({n: 1000, p: 0.01} Bloom.make end)
print ((bf Bloom.params end)) end
# => {k:7 m:9586 n:1000 p:0.01}
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
print ((bf Bloom.contains "alice" end)) end   # => true
print ((bf Bloom.contains "carol" end)) end   # => false
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
insert count as the filter fills. An empty filter counts `0`. Cost is
one native popcount per 63-bit word — `O(m/63)`.

### `Bloom.params`

Return the filter's parameters as a Map.

| | |
|--|--|
| **Call**    | `bf Bloom.params end` |
| **Stack in**| `BloomFilter` |
| **Returns** | `Map` with keys `n`, `p`, `m`, `k` |

```aql
def ps (bf Bloom.params end)
print ((ps "m" get)) end   # => 9586
```

### `Bloom.merge`

Union two filters into the first.

| | |
|--|--|
| **Call**    | `a Bloom.merge b end` |
| **Stack in**| target `BloomFilter` `a`, then source `BloomFilter` `b` |
| **Returns** | `a`, now containing every bit that was set in `a` or `b` |
| **Effect**  | mutates `a` in place; `b` is unchanged; `a.added` becomes `a.added + b.added` |
| **Errors**  | raises `incompatible_merge` if `a` and `b` differ on `m` or `k` |

Both filters must have identical `m` and `k`, which happens
automatically when both were built with the same `(n, p)`. After a
merge, every item present in `a` or `b` reads as contained. The union
itself is one bitwise OR per 63-bit word.

The error message names the mismatched parameter and both values, e.g.
`Bloom.merge: filters disagree on m (9586 vs 4793); build both with
the same (n, p)`. Trap it with `do […] error […]` (read `e get code` /
`e get message`) or assert it with `Assert.throws`.

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
print ((bf Bloom.encode end)) end
# => {added:1 k:7 m:9586 n:1000 p:0.01 set:[223 1110 2827 3714 4601 6318 7205]}
```

The snapshot round-trips through `Bloom.decode`. (Exact bit indices
depend on the module's hash functions, so snapshots are portable
across processes running the *same* module version, not across
versions that changed the hashing.)

### `Bloom.decode`

Rebuild a filter from a `Bloom.encode` snapshot.

| | |
|--|--|
| **Call**    | `text Bloom.decode end` |
| **Stack in**| the snapshot `String` |
| **Returns** | a fresh `BloomFilter` |
| **Errors**  | raises `bad_payload` when the text is not parseable jsonic or lacks the required fields |

The payload's own `m` and `k` are trusted (not re-derived from `n` and
`p`), so a snapshot survives changes to the sizing formulas. The
rebuilt filter is independent of the original — mutating one does not
affect the other.

```aql
def snap (bf Bloom.encode end)
def back (snap Bloom.decode end)
print ((back Bloom.contains "alice" end)) end   # => true
```

---

## Errors at a glance

All failures raise coded errors; catch with `do […] error […]` and
read `e get code` / `e get message` (dispatch on several codes with
`case`).

| Code | Raised by | Situation |
|------|-----------|-----------|
| `bad_input` | `make` | `n` not an Integer ≥ 1, or `p` not a Float in `(0, 0.5]` |
| `incompatible_merge` | `merge` | the filters disagree on `m` or `k` |
| `bad_payload` | `decode` | text is not parseable jsonic, or is missing/mis-typing `n p m k added set` |

A missing `end` after a `Bloom.*` call is not a module error but a
general AQL dispatch problem — the word collects the following token
(add `end` or parens).

## Complexity

| Word       | Cost      |
|------------|-----------|
| `make`     | `O(m/63)` (allocates the word Array) |
| `add`      | `O(k)`    |
| `contains` | `O(k)`    |
| `count`    | `O(m/63)` |
| `params`   | `O(1)`    |
| `merge`    | `O(m/63)` |
| `encode`   | `O(m)`    |
| `decode`   | `O(m/63 + s)` for `s` set bits |

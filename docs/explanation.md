# Explanation

Understanding-oriented discussion of how this bloom filter works and
why it is built the way it is. Read this when you want the *why*; for
the *what*, see the [Reference](reference.md), and for *how to get a
job done*, the [How-to guides](how-to.md).

---

## What a bloom filter is for

A bloom filter answers one question — *"have I seen this item?"* — using
far less memory than storing the items themselves. It trades exactness
for size: it will never miss an item it has seen (no false negatives),
but it will occasionally claim to have seen an item it hasn't (a false
positive). You choose the false-positive rate up front, and the filter
sizes itself to meet it.

This is the right tool when:

- the set is large and you only need membership, not the items;
- an occasional false positive is acceptable (you can re-check against
  the real store on a hit);
- you want cheap unions of independently-built sets (see
  [Merging](#merging-filters)).

It is the wrong tool when you need to enumerate members, delete them,
or get an exact answer.

---

## How membership works

The filter is a bit array of width `m`, all zero to start. Each item is
run through `k` hash functions, each producing an index in `[0, m)`.
`add` sets the bits at those `k` indices. `contains` checks whether
*all* `k` bits for an item are set.

```
add "alice"      → bits {h1, h2, … hk} set to 1
contains "alice" → are bits {h1, h2, … hk} all 1?  → yes
contains "carol" → are bits {g1, g2, … gk} all 1?  → some 0 → no
```

### Why there are no false negatives

`add` only ever turns bits *on*; nothing turns them off. So once an
item's `k` bits are set, they stay set, and a later `contains` for that
same item must find all of them set. A "definitely not present" answer
(`false`) is therefore always trustworthy.

### Why there are false positives

Different items can hash to overlapping bits. If items you *did* add
happen to collectively set all `k` bits that some *un-added* item maps
to, `contains` returns `true` for that un-added item. The chance of this
rises as the filter fills, which is exactly what the sizing math
controls.

---

## Sizing the filter

`make` takes a target capacity `n` (how many distinct items you expect)
and a target false-positive rate `p`, and derives the two structural
parameters:

- **`m`, the bit width** — `m = ceil( -n · ln(p) / (ln 2)² )`. Smaller
  `p` or larger `n` means more bits.
- **`k`, the hash count** — `k = round( (m / n) · ln 2 )`, the value
  that minimises the false-positive rate for the chosen `m` and `n`.

For `{n: 1000, p: 0.01}` this yields `m = 9586`, `k = 7`. The
[Reference](reference.md#bloommake) lists more worked values. Because
`k = round(log₂(1/p))`, a `p` above `0.5` rounds `k` to `0` and is
meaningless — keep `p` in `(0, 0.5]`, and in practice well below it.

The filter stores `n` and `p` alongside `m` and `k` so it can report
its own configuration via `params` and so `merge` can check
compatibility.

---

## Hashing: double hashing from two FNV variants

The module needs `k` independent-looking hash functions but computes
only two real hashes. It derives index `i` as:

```
index_i = (h1 + i · h2) mod m        for i in 0 … k-1
```

`h1` and `h2` come from the native FNV-1a words in `aql:bin-util`:
`h1` is `BinUtil.fnv32` of the stringified item, and `h2` is the high
32 bits of `BinUtil.fnv64`, OR'd with 1 so the stride is odd and
covers all residues mod `m`. This "double hashing" gives `k`
well-spread indices at the cost of two hashes rather than `k`, a
standard bloom-filter technique. (Earlier versions of this module
hand-rolled FNV over a 95-character printable-ASCII lookup table
because the runtime exposed no character-code or hash words; the
native words handle any string and disperse better.) FNV is not a
security-grade hash — the filter is for membership, not cryptography.

---

## Estimating cardinality

`count` estimates how many distinct items were added, using the
Swamidass–Baldi estimator:

```
n_est = -(m / k) · ln(1 - X/m)
```

where `X` is the number of set bits. The intuition: a fuller bit array
implies more inserts, but with diminishing returns as collisions
accumulate. The implementation guards the saturated case (`X = m`,
where the logarithm would blow up) by returning the raw `added` counter
instead.

This is why `count` is an *estimate* and generally reads a little below
the true insert count as the filter fills. If you need the exact
number of `add` calls, read the `added` field instead (`bf.added`,
also carried in the [`encode`](reference.md#bloomencode) snapshot).
An empty filter estimates exactly `0`.

---

## Merging filters

Two filters built with the same `(n, p)` share the same `m` and `k`,
which means their bit arrays are positionally comparable: bit `i` means
the same thing in both. `merge` ORs the source's bits into the target,
so the result contains every item either filter held. This is what
makes bloom filters attractive for distributed counting — workers each
build a filter, and a coordinator unions them with no re-hashing.

`merge` insists on matching `m` and `k` because OR-ing arrays of
different widths, or built with different hash counts, would be
meaningless. The check is a guard against silently-wrong results.

---

## Design choices specific to this library

### Packed bit storage

Bits are packed into an `Array` of integer words, 63 bits per word
(bit 63 is the sign bit; staying out of it keeps every word a plain
non-negative Integer). The Array is fixed-extent and mutated in place
through `set`, and the word-level operations come from `aql:bin-util`:
`BinUtil.set`/`BinUtil.test` for single bits, `BinUtil.popcount` for
`count`, and `BinUtil.bor` for `merge` — so the formerly per-bit
`O(m)` walks now touch one word per 63 bits. Memory is `O(m/63)`
regardless of load.

Earlier versions used a sparse map keyed by stringified bit index,
because the runtime then had no mutable indexed container and no
bitwise words outside core. With `Array` and the `bin-util` second
tier, the packed layout is both the simpler and the faster choice.

One subtlety: the `bits` field is declared by *type* (`bits: Array`)
rather than given a schema default, and every constructor passes a
fresh Array. A class-field default is evaluated once, at class
definition, and that single value would be shared by every instance —
a mutable default would silently alias all filters together (see
`dx-report.md` §2).

### Mutation in place

`add` and `merge` mutate the filter instance in place (and also return
it). This is deliberate: a filter is a large accumulator, and copying it
on every insert would be wasteful. Callers that want an independent copy
should round-trip through `encode`/`decode` or build a fresh filter.

### Raising errors

Failures raise coded errors with `raise`: `bad_input` from `make`,
`incompatible_merge` from `merge`, `bad_payload` from `decode`.
Handlers catch them with `do […] error […]` and read `code`/`message`
(plus any payload fields) off the Error value.

Two defensive idioms in `bloom.aql` date from runtime sharp edges that
have since been fixed upstream (both documented with repros in
[`dx-report.md`](../dx-report.md)): the raise *message* is bound with
`def` first (older builds' `raise` did not collect a template-string
literal), and every guard `if` carries an explicit empty else `[]`
(older builds eagerly forward-collected a `def` statement following an
else-less `if`, which could pre-empt the guard). Both spellings remain
correct on every build, so they are kept.

Historical note: on aql `db828ec` there was no way to raise a custom
error at all, and this module signalled merge mismatches by
dispatching a descriptively-named undefined word
(`bloom-merge-requires-equal-m`). The `raise` word landed after that
build and the workaround is retired.

### `if` is always written all-forward

Throughout `bloom.aql`, `if` is written `if cond [then] [else]` with
every argument forward of the word. Both the all-forward and the
all-stack forms select the correct branch; only the *mixed* form, with
`if` between the condition and its branches (`cond if […] […]`),
silently takes the else branch. Keeping `if` and its operands on the
same side sidesteps that trap — and as noted above, an `if` used as a
statement always gets an explicit else, even an empty one. This is
otherwise invisible to callers.

---

## Further reading

- [Tutorial](tutorial.md) — build your first filter step by step.
- [How-to guides](how-to.md) — task-focused recipes.
- [Reference](reference.md) — the exact API.

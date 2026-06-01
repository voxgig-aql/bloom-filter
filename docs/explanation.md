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

`h1` and `h2` are FNV-1a-style hashes of the stringified item, seeded
differently; `h2` is forced odd (OR'd with 1) so the stride covers all
residues mod `m`. This "double hashing" gives `k` well-spread indices at
the cost of two hashes rather than `k`, a standard bloom-filter
technique.

Because AQL does not expose a character-to-code primitive, the module
maps each character to a code via lookup in a fixed 95-character
printable-ASCII alphabet (non-printable input collapses to space). This
is a workaround, not a security-grade hash — the filter is for
membership, not cryptography.

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
the true insert count as the filter fills — 100 distinct inserts into a
`{n:1000, p:0.01}` filter estimate around 90. If you need the exact
number of `add` calls, read the `added` field via
[`params`](reference.md#bloomparams)-adjacent access rather than
`count`. An empty filter estimates exactly `0`.

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

## Design choices specific to this module

### Sparse bit storage

Instead of a packed bit vector, bits live in a `Bits` Object keyed by
stringified index (`"4601": 1`). This suits AQL's data model — there is
no native fixed-width bit array — and keeps storage proportional to the
number of *set* bits rather than `m`. The trade-off is that the `O(m)`
operations (`count`, `merge`, `encode`) walk all `m` indices probing
this map, which is the dominant cost in the
[property tests](how-to.md#run-the-tests).

### Mutation in place

`add` and `merge` mutate the filter Object in place (and also return
it). This is deliberate: a filter is a large accumulator, and copying it
on every insert would be wasteful. Callers that want an independent copy
should build a fresh filter.

### Raising errors in aql 5b983b6

`merge`'s precondition check raises by dispatching an undefined,
descriptively-named word (`bloom-merge-requires-equal-m`). That looks
odd, and it is a workaround: aql 5b983b6 redefined `error` as an
error-*handling* combinator (`do [risky] error [handler]`) and removed
the older string-raising form, leaving no word to raise a custom
message. Dispatching a word that isn't defined is the remaining way to
produce a *catchable* failure whose text names the problem. The full
story is in `dx-report.md` §9.10. If a future aql restores custom
raising, this is the first thing to clean up.

### `if` is forward-only

Throughout `bloom.aql`, `if` is always written `if cond [then] [else]`
with every argument forward of the word. On aql 5b983b6 that is the only
form that selects the correct branch — the mixed `cond if […] […]` form
silently takes the else branch and the postfix form no longer
dispatches. See `dx-report.md` §6.2. This constrains how conditionals
read but is otherwise invisible to callers.

---

## Further reading

- [Tutorial](tutorial.md) — build your first filter step by step.
- [How-to guides](how-to.md) — task-focused recipes.
- [Reference](reference.md) — the exact API.
- `dx-report.md` — the developer-experience log behind these design
  workarounds.

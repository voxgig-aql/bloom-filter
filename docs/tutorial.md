# Tutorial: your first bloom filter

This is a hands-on lesson. By the end you will have built a small AQL
script that tracks which usernames it has seen, queried it, and watched
a false positive appear. You need no prior knowledge of bloom filters —
just a working `aql` binary (see
[How-to → Install and run](how-to.md#install-and-run-aql)) and this
repository checked out.

> **AI agents:** for the calling convention and a verified cheat-sheet,
> see [AGENTS.md](../AGENTS.md).

Follow along by typing the script into a file as we grow it. We will
build it up in pieces and run it after each step.

---

## Step 1 — import the module and make a filter

Create a file `seen.aql` next to `bloom.aql` with this content:

```aql
import "./bloom.aql"

# Print one value per statement, fully grouped — `print (value) end` —
# and output appears in source order. (Chained `(a) print (b) print`
# pairs print out of order, because print collects a forward argument.)

def seen ({n: 10000, p: 0.01} Bloom.make end)
print (`params:      ${(seen Bloom.params end)}`) end
```

`Bloom.make` takes an options map: `n` is how many distinct items you
expect (10 000), and `p` is the false-positive rate you will tolerate
(1 %). Run it:

```console
$ aql seen.aql
params:      {k:7 m:95851 n:10000 p:0.01}
```

The filter computed two values for you: `m`, the number of bits it will
use (95 851), and `k`, the number of hash functions (7). You never set
those directly — they fall out of `n` and `p`. (Curious how? See
[Explanation → Sizing](explanation.md#sizing-the-filter).)

---

## Step 2 — add some items

Add three usernames. Each `add` call mutates the filter in place; we
bind the returned filter to throwaway names (`_1`, `_2`, `_3`) just to
keep the stack clean. Append below the `params:` line:

```aql
def _1 (seen Bloom.add "ada" end)
def _2 (seen Bloom.add "grace" end)
def _3 (seen Bloom.add "alan" end)
```

Nothing prints yet — `add` just records the items. Note the `end` after
each call: AQL words look ahead for arguments, and `end` marks where the
call stops. Forget it and the next token gets swallowed as an argument.

---

## Step 3 — ask what the filter has seen

Now query it. `Bloom.contains` returns a Boolean:

```aql
print (`ada seen?    ${(seen Bloom.contains "ada" end)}`) end
print (`grace seen?  ${(seen Bloom.contains "grace" end)}`) end
print (`linus seen?  ${(seen Bloom.contains "linus" end)}`) end
```

Run the whole file:

```console
$ aql seen.aql
params:      {k:7 m:95851 n:10000 p:0.01}
ada seen?    true
grace seen?  true
linus seen?  false
```

`ada` and `grace` were added, so they read `true`. `linus` was not, and
reads `false`. That `false` is a *guarantee*: a bloom filter never
forgets something you added, so a "no" is always correct.

---

## Step 4 — estimate how many items you've added

The filter can estimate its own cardinality without storing the items.
Add:

```aql
print (`distinct ~   ${(seen Bloom.count end)}`) end
```

```console
$ aql seen.aql
...
distinct ~   3
```

We added three distinct items and the estimate is `3`. `count` is an
*approximation* (it reads the bit pattern, not a stored list), so on a
fuller filter expect it to drift a little — see
[Explanation → Estimating cardinality](explanation.md#estimating-cardinality).

---

## Step 5 — watch false positives, and see that they track `p`

This is the defining behaviour of a bloom filter, and it is worth seeing
once. A false positive is an item you never added that nonetheless reads
`true`, because other items happened to set all of its bits. The whole
point of `p` is that you get to choose how often this happens.

Let's measure it. Create a second file `falsepos.aql` that sizes a
filter for 50 items at a 10 % rate, fills it with exactly those 50
items, then queries 1 000 keys that were never added:

```aql
import "./bloom.aql"

def bf ({n: 50, p: 0.1} Bloom.make end)
print (`params: ${(bf Bloom.params end)}`) end

# add exactly the 50 items it was sized for
def _ (iota 50 each [ var [[i] bf Bloom.add `item-${i}` end 0 ] ])

# query 1000 keys that were never added
def hits (iota 1000 each [
  var [[i]
    def key `absent-${i}`
    if (bf Bloom.contains key end) [1] [0]
  ]
])
print (`false positives among 1000 un-added keys: ${(0 hits [add end] fold)}`) end
```

```console
$ aql falsepos.aql
params: {k:3 m:240 n:50 p:0.1}
false positives among 1000 un-added keys: 97
```

Of the 1 000 keys we never added, 903 correctly read `false` and only
97 — about 10 % — were false positives, right at the 10 % we asked
for. Loaded to the capacity it was built for, the filter delivers the
error rate you specified. Size it for fewer items (smaller `n`) or
overfill it and that rate climbs; the math behind the trade-off is in
[Explanation → Sizing](explanation.md#sizing-the-filter).

---

## What you've learned

- `Bloom.make` sizes a filter from a target `n` and `p`.
- `Bloom.add` records items; `Bloom.contains` queries them.
- A `false` from `contains` is always correct; a `true` is "probably,"
  with a tunable false-positive rate.
- `Bloom.count` estimates how many distinct items you added.
- Under-sizing a filter produces false positives — by design.

## Where to go next

- Solve specific problems with the [How-to guides](how-to.md) — sizing,
  merging, persistence, running the tests.
- Look up exact signatures in the [Reference](reference.md).
- Understand the machinery in the [Explanation](explanation.md).

# How-to guides

Task-oriented recipes. Each one assumes you already know roughly what a
bloom filter is; if not, start with the [Tutorial](tutorial.md). For the
*why* behind any of these, follow the links into the
[Explanation](explanation.md); for exact signatures, the
[Reference](reference.md).

- [Install and run aql](#install-and-run-aql)
- [Size a filter for a target false-positive rate](#size-a-filter-for-a-target-false-positive-rate)
- [Add and query items](#add-and-query-items)
- [Estimate how many distinct items you've added](#estimate-how-many-distinct-items-youve-added)
- [Merge two filters](#merge-two-filters)
- [Handle an incompatible merge](#handle-an-incompatible-merge)
- [Serialize a filter](#serialize-a-filter)
- [Reload a serialized filter](#reload-a-serialized-filter)
- [Use the filter from your own script](#use-the-filter-from-your-own-script)
- [Run the tests](#run-the-tests)

---

## Install and run aql

The module is written in AQL, which has no tagged release yet, so build
the interpreter from source (the documented `go install …/aql@latest`
fails on the repo's replace directives):

```bash
git clone https://github.com/aql-lang/aql /tmp/aql-source
cd /tmp/aql-source
git checkout 407fedad2ea2b30c3dde2f29cfbe60e55f94db4e   # the commit CI pins (ci/test.yml AQL_REF)
cd cmd/go
GOFLAGS=-mod=mod go build -o "$HOME/.local/bin/aql" ./aql
```

Make sure `$HOME/.local/bin` is on your `PATH`, then check it:

```bash
aql -version
```

Run any script in this repo by passing its path:

```bash
aql test/bloom_smoke_test.aql
```

This module is verified against aql commit `407feda`; the CI workflow
(`ci/test.yml`, pending promotion to `.github/workflows/`) pins the same
commit.

---

## Size a filter for a target false-positive rate

Pick `n` (how many distinct items you expect) and `p` (the
false-positive rate you'll tolerate, in `(0, 0.5]`), and hand them to
`Bloom.make`:

```aql
import "./bloom.aql"
def bf ({n: 100000, p: 0.001} Bloom.make end)
(bf Bloom.params end) print
# => {"k": 10, "m": 1437759, "n": 100000, "p": 0.001}
```

You do not choose the bit width or hash count — `m` and `k` are derived
to meet your `p` at load `n`. Smaller `p` costs more bits. Inspect the
result with `Bloom.params`. Out-of-range arguments (a non-integer or
non-positive `n`, a `p` outside `(0, 0.5]`, or a missing key) raise a
`bad_input` error rather than building a useless filter. (How the
numbers are derived: [Explanation → Sizing](explanation.md#sizing-the-filter).)

---

## Add and query items

`Bloom.add` records an item (any value — it is stringified internally);
`Bloom.contains` tests membership and returns a Boolean:

```aql
def _ (bf Bloom.add "user@example.com" end)

print ((bf Bloom.contains "user@example.com" end)) end   # => true
print ((bf Bloom.contains "nobody@example.com" end)) end # => false  (guaranteed correct)
```

A `false` is always correct. A `true` means "probably present" — verify
against your real store if a false positive would be costly.

To add many items, loop with `each` (push a sentinel `0` so the loop
body yields a value):

```aql
def _ (iota 1000 each [
  var [[i] bf Bloom.add `key-${i}` end 0 ]
])
```

---

## Estimate how many distinct items you've added

```aql
print ((bf Bloom.count end)) end
```

`count` returns an **estimate** derived from the bit pattern, not a
stored tally, so it drifts a little as the filter fills. If you need the
*exact* number of `add` calls instead, read the `added` field — it is
accessible directly as `bf.added` and is also carried in the
`Bloom.encode` snapshot. (Background:
[Explanation → Estimating cardinality](explanation.md#estimating-cardinality).)

---

## Merge two filters

Two filters built with the **same `(n, p)`** can be unioned. `merge`
folds the second into the first and returns the first:

```aql
def a ({n: 1000, p: 0.01} Bloom.make end)
def b ({n: 1000, p: 0.01} Bloom.make end)
def _a (a Bloom.add "from-a" end)
def _b (b Bloom.add "from-b" end)

def merged (a Bloom.merge b end)
print ((merged Bloom.contains "from-a" end)) end   # => true
print ((merged Bloom.contains "from-b" end)) end   # => true
```

`merge` mutates the first filter (`a`) in place, so `a` and `merged` are
the same object. `b` is left untouched. This is the basis for
distributed counting — build filters independently, then union them.

---

## Handle an incompatible merge

`merge` requires both filters to share `m` and `k`; otherwise it raises
an `incompatible_merge` error whose message names the mismatched
parameter. Wrap the call in `do … error …` to recover; inside the
handler the Error value is on the stack, with `code` and `message`
fields:

```aql
def a ({n: 1000, p: 0.01} Bloom.make end)
def b ({n:  500, p: 0.01} Bloom.make end)   # different n → different m

def result (do [a Bloom.merge b end] error [
  get message
])
result print
# => Bloom.merge: filters disagree on m (9586 vs 4793); build both with the same (n, p)
```

To branch on the code instead, dispatch with `case` —
`get code case [incompatible_merge/q "rebuild b" "unexpected"]`. In a
test, assert the failure (or its exact code):

```aql
import "aql:test"
[a Bloom.merge b end] Assert.throws end
def e (do [a Bloom.merge b end])
incompatible_merge/q (e get code) Assert.equal end
```

(Why the module raises coded errors:
[Explanation → Raising errors](explanation.md#raising-errors).)

---

## Serialize a filter

`Bloom.encode` produces a jsonic-style string snapshot — parameters plus
the set bit indices — suitable for logging or persistence:

```aql
def snap ({n: 1000, p: 0.01} Bloom.make end)
def _ (snap Bloom.add "x" end)
print ((snap Bloom.encode end)) end
# => {added:1 k:7 m:9586 n:1000 p:0.01 set:[603 2193 2602 4192 4601 6191 8190]}
```

---

## Reload a serialized filter

`Bloom.decode` rebuilds a filter from an encode snapshot — the round
trip preserves the parameters, the exact `added` count, and every set
bit:

```aql
def text (snap Bloom.encode end)
def back (text Bloom.decode end)
print ((back Bloom.contains "x" end)) end   # => true
```

The rebuilt filter is independent of the original (mutating one does
not touch the other). Malformed input — unparseable text, or a payload
missing any of `n p m k added set` — raises a `bad_payload` error.

One caveat: the bit indices are produced by this module's hash
functions, so a snapshot is portable across processes running the
*same* module version, not across versions that changed the hashing.

---

## Use the filter from your own script

Import the library by relative path; you do **not** need to import
`aql:math-util`, `aql:array-util`, `aql:bin-util`, or `aql:struct-util`
yourself — `bloom.aql` pulls in its own dependencies:

```aql
import "./bloom.aql"

def bf ({n: 1000, p: 0.01} Bloom.make end)
# … use the Bloom namespace …
```

(No `end` is needed after `import` on the pinned build.) Every
`Bloom.*` call must end with `end` (or be wrapped in parens) so the
word doesn't swallow the following token. `test/bloom_smoke_test.aql`
is a complete worked example you can copy from.

---

## Run the tests

Five suites ship with the module. Run them with `aql`:

```bash
aql test/bloom_unit_test.aql   # example-based unit tests — direct (aql:test)
aql test/bloom_unit_spec.aql   # example-based unit tests — declarative spec format
aql test/bloom_prop_test.aql   # property tests — direct Test.check-prop form
aql test/bloom_prop_spec.aql   # property tests — declarative spec format
aql test/bloom_smoke_test.aql  # end-to-end walk-through over every public word
```

The file names follow a consistent convention: `_test.aql` is a direct
suite (assertions or `Test.check-prop` calls written out in code), and
`_spec.aql` is a declarative suite (cases or properties built as data
and handed to a runner). Both the unit and property layers ship in both
forms.

The two unit suites express the same example checks two ways:
`bloom_unit_test.aql` asserts imperatively with `Test.test` /
`Assert.equal`, while `bloom_unit_spec.aql` builds each check as a
`TestSpec` (`Test.spec` / `Test.case`) that `Test.run-spec` dispatches.

The two property suites are likewise split: `bloom_prop_spec.aql` builds
each property as a declarative `PropertySpec` (`Test.prop`) and runs it
with `Test.run-property` at the default 100 iterations — clean, but the
run count is fixed. `bloom_prop_test.aql` calls the imperative
`Test.check-prop` driver directly, passing `runs`/`seed`/`max-shrinks`
explicitly, which is why it carries the expensive O(m) properties
(merge, encode, decode) at a smaller run budget.

Each test file ends by asserting `Test.fail-count` is `0`, so a failure
makes `aql` exit non-zero — which is exactly what the
[CI workflow](../.github/workflows/test.yml) checks on every push and pull request.

One more check sits outside this set. `test/divergence/` runs every suite
through all three of aql's execution surfaces — the interpreter, `aql
check` (static type-check), and the byte compiler (`aql --compile`) — and
asserts none errors or disagrees. Run it with:

```bash
test/divergence/run.sh
```

It builds a newer aql (the `--compile` CLI postdates this module's pin) and
prints a per-suite interpreter/check/bytecode matrix. All five suites are
green on all three. See [`test/divergence/README.md`](../test/divergence/README.md)
for the one upstream byte-compiler bug this guards against (a compiled
`each` body drops a *block-local* binding) and the one-line structural
choice — building a bulk fixture at top level — that keeps the suites clear
of it.

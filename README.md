# bloom-filter

A small, dependency-light **bloom filter** implemented in
[AQL](https://github.com/aql-lang/aql) — a probabilistic set that
answers *"have I seen this item?"* in far less memory than storing the
items, with no false negatives and a false-positive rate you choose up
front.

```aql
"./bloom.aql" import end

def seen ({n: 10000, p: 0.01} Bloom.make end)
def _ (seen "ada" Bloom.add end)

(seen "ada"   Bloom.contains end) print   # => true
(seen "linus" Bloom.contains end) print   # => false
```

## Documentation

The docs follow the [Diátaxis](https://diataxis.fr) framework — four
modes, each serving a different need. Start wherever your need is:

| | Mode | Read this when you want to… |
|--|------|----------------------------|
| 🎓 | **[Tutorial](docs/tutorial.md)** | learn by building your first filter step by step |
| 🔧 | **[How-to guides](docs/how-to.md)** | accomplish a specific task (size, merge, persist, test…) |
| 📖 | **[Reference](docs/reference.md)** | look up exact words, signatures, and return types |
| 💡 | **[Explanation](docs/explanation.md)** | understand how it works and why it's built this way |

New here? Read the [Tutorial](docs/tutorial.md). Already know bloom
filters and just want the API? Jump to the [Reference](docs/reference.md).

## The `Bloom` API at a glance

| Word | Purpose |
|------|---------|
| `{n, p} Bloom.make`      | build a filter sized for capacity `n` at false-positive rate `p` |
| `bf item Bloom.add`      | insert an item (mutates `bf`) |
| `bf item Bloom.contains` | test membership → Boolean |
| `bf Bloom.count`         | estimate distinct items added |
| `bf Bloom.params`        | report `{n, p, m, k}` |
| `a b Bloom.merge`        | union two filters with matching `(m, k)` |
| `bf Bloom.encode`        | serialize to a snapshot string |

Full details, including the calling convention (every call ends with
`end`), are in the [Reference](docs/reference.md).

## Project layout

```
bloom.aql                 the library (the Bloom namespace)
smoke.aql                 smoke demo / worked example
test/bloom_test.aql       example-based unit tests
test/bloom_prop_spec.aql  property-based tests — declarative spec format
test/bloom_pbt.aql        property-based tests — direct test.check-prop form
docs/                     Diátaxis documentation (above)
dx-report.md              developer-experience log against aql commits
dx-remaining.md           focused list of open / partial DX items
```

## Running it

Build the `aql` interpreter, then run any script or test — see
[How-to → Install and run](docs/how-to.md#install-and-run-aql) and
[Run the tests](docs/how-to.md#run-the-tests):

```bash
aql smoke.aql                  # smoke demo
aql test/bloom_test.aql        # unit tests
aql test/bloom_prop_spec.aql   # property tests — declarative spec format
aql test/bloom_pbt.aql         # property tests — direct test.check-prop form
```

A GitHub Actions workflow ([`ci/test.yml`](ci/test.yml)) builds aql from
a pinned commit and runs every suite on each push and pull request. It
is staged under `ci/` rather than `.github/workflows/` because the token
that created this branch lacked GitHub `workflow` scope; move it into
place to activate it — see [`ci/README.md`](ci/README.md).

## License

See [LICENSE](LICENSE).

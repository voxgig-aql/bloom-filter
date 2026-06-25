# bloom-filter

A small, dependency-light **bloom filter** implemented in
[AQL](https://github.com/aql-lang/aql) — a probabilistic set that
answers *"have I seen this item?"* in far less memory than storing the
items, with no false negatives and a false-positive rate you choose up
front.

```aql
import "./bloom.aql"

def seen ({n: 10000, p: 0.01} Bloom.make)
def _ (seen Bloom.add "ada")

print (seen Bloom.contains "ada")     # => true
print (seen Bloom.contains "linus")   # => false
```

> **Forking this to build a new AQL library?** This repo is a GitHub
> template — read **[TEMPLATE.md](TEMPLATE.md)** for the instantiation
> checklist, then delete it.

> **Calling this library from an AI coding agent?** Read
> **[AGENTS.md](AGENTS.md)** first — the exact AQL calling convention,
> verified idioms, and common mistakes. (Claude Code auto-loads it via
> `CLAUDE.md`; a portable skill lives in
> [`.claude/skills/bloom-filter-aql`](.claude/skills/bloom-filter-aql/SKILL.md).)

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
| `bf Bloom.add item`      | insert an item (mutates `bf`) |
| `bf Bloom.contains item` | test membership → Boolean |
| `bf Bloom.count`         | estimate distinct items added |
| `bf Bloom.params`        | report `{n, p, m, k}` |
| `a Bloom.merge b`        | union two filters with matching `(m, k)` |
| `bf Bloom.encode`        | serialize to a snapshot string |
| `text Bloom.decode`      | rebuild a filter from a snapshot string |

Full details, including the calling convention (every call ends with
`end`), are in the [Reference](docs/reference.md).

## For AI coding agents

If an agent will call this library, point it at **[AGENTS.md](AGENTS.md)**
— the exact AQL calling convention, verified idioms, and the common
mistakes to avoid.

To make that guidance available in *another* project that uses this
library, install the bundled skill either way:

- **Copy the skill** — drop
  [`.claude/skills/bloom-filter-aql/`](.claude/skills/bloom-filter-aql/SKILL.md)
  into that project's `.claude/skills/` (or your `~/.claude/skills/`). It
  loads on demand whenever Bloom calls appear.
- **Install the plugin** — this repo is also a plugin marketplace:

  ```
  /plugin marketplace add voxgig-aql/bloom-filter
  /plugin install bloom-filter-aql@voxgig-aql
  ```

Working inside *this* repo, Claude Code picks the guidance up
automatically via `CLAUDE.md` (which imports `AGENTS.md`) and the bundled
skill.

## Project layout

```
bloom.aql                  the library (the Bloom namespace)
AGENTS.md                  agent guide: how to call this library correctly
test/bloom_unit_test.aql   example-based unit tests — direct (Test.test)
test/bloom_unit_spec.aql   example-based unit tests — declarative spec format
test/bloom_prop_test.aql   property-based tests — direct (Test.check-prop)
test/bloom_prop_spec.aql   property-based tests — declarative spec format
test/bloom_smoke_test.aql  end-to-end smoke run over every public word
docs/                      Diátaxis documentation (above)
dx-report.md               developer-experience notes (current pin: aql @ 407feda)
proposals/                 language proposals raised from this module's DX
```

Test files follow a consistent naming convention: `_test.aql` for
direct tests (unit or property), `_spec.aql` for declarative specs (unit
or property).

## Running it

Build the `aql` interpreter, then run any script or test — see
[How-to → Install and run](docs/how-to.md#install-and-run-aql) and
[Run the tests](docs/how-to.md#run-the-tests):

```bash
aql test/bloom_unit_test.aql   # unit tests — direct
aql test/bloom_unit_spec.aql   # unit tests — declarative spec format
aql test/bloom_prop_test.aql   # property tests — direct
aql test/bloom_prop_spec.aql   # property tests — declarative spec format
aql test/bloom_smoke_test.aql  # end-to-end smoke run
```

A GitHub Actions workflow
([`.github/workflows/test.yml`](.github/workflows/test.yml)) builds aql from a
pinned commit and runs every suite — plus a `consistency` job (agent-skill
drift, JSON manifests, and a pinned-ref guard) — on each push and pull request.

## License

See [LICENSE](LICENSE).

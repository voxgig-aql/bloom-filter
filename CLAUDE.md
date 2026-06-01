# CLAUDE.md

This repository is the `Bloom` bloom-filter library, written in AQL.

## Using the library

See @AGENTS.md for how to call the `Bloom` API correctly from AQL — the
calling convention, the full API, copy-paste idioms, and the common
mistakes to avoid. Every example there is verified against the pinned
`aql` build.

## Working on this repository

- Build the `aql` interpreter from source (there is no tagged release and
  `go install …/aql@latest` is blocked by replace directives) and run the
  suites — see [docs/how-to.md](docs/how-to.md#install-and-run-aql).
- Tests live in `test/`: `_test.aql` = direct, `_spec.aql` = declarative.
  Each suite ends by asserting `test.fail-count` is `0`.
- Known AQL-runtime gotchas observed with the pinned build are in
  `dx-report.md`.

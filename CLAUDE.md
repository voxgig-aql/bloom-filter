# CLAUDE.md

This repository is the `Bloom` bloom-filter library, written in AQL.

## Using the library

See @AGENTS.md for how to call the `Bloom` API correctly from AQL — the
calling convention, the full API, copy-paste idioms, and the common
mistakes to avoid. Every example there is verified against the pinned
`aql` build.

## Working on this repository

- A SessionStart hook (`.claude/settings.json` →
  `.claude/hooks/session-start.sh`) builds `aql` from the pinned commit in
  remote sessions, so a fresh session can run the suites. Locally, build it
  once from source (there is no tagged release and `go install …/aql@latest`
  is blocked by replace directives) — see
  [docs/how-to.md](docs/how-to.md#install-and-run-aql).
- Tests live in `test/`, named `<subject>_<unit|prop>_<test|spec>.aql` plus a
  `bloom_smoke_test.aql`: `_test` = imperative (`Test.test`/`Test.check-prop`),
  `_spec` = declarative spec; `unit` = example-based, `prop` = property-based.
  Each assertion-bearing suite ends by asserting `Test.fail-count` is `0` and
  prints `all green`.
- `test/divergence/run.sh` runs every suite through all three aql surfaces —
  interpreter, `aql check`, and the byte compiler (`aql --compile`) — and
  asserts none errors or disagrees. It builds a newer aql than this module's
  pin, since the `--compile` CLI postdates it. See its `README.md`; the
  byte-compiler bug it guards against is `dx-report.md` §3.
- Known AQL-runtime gotchas observed with the pinned build are in
  `dx-report.md`. The pinned aql commit is single-sourced in the CI workflow's
  `AQL_REF`; a CI job fails if the hook or `api.json` drift from it. The
  workflow currently lives in `ci/test.yml` pending promotion to
  `.github/workflows/` (this session can't push workflow files — see
  `ci/README.md`); the stale `.github/workflows/test.yml` still on `main` is
  superseded by it.
- Forking this repo to start a new AQL library? See `TEMPLATE.md`.

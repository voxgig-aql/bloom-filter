# ci/ — staged GitHub Actions workflow

GitHub blocks pushes that **create or update files under
`.github/workflows/`** unless the pushing token carries the `workflow` OAuth
scope. The automation that maintains this repo doesn't have that scope, so
workflow changes are staged here and a maintainer promotes them.

## What's here

- **`test.yml`** — the intended `.github/workflows/test.yml`. It is the
  canonical, up-to-date workflow; the copy currently under
  `.github/workflows/` is **stale** (it pins an older, drifted `AQL_REF`) and
  is superseded by this one.

### What changed vs the live `.github/workflows/test.yml`

1. **`AQL_REF` bumped to `407feda…`** — the commit this library is now
   verified against (interpreter, `aql check`, and `aql --compile` all clean
   across every suite). The live file still pins `db828ec…`, which also
   resolves the long-standing pin drift between it and the hook / `api.json`.
2. **New gating `divergence` job** — runs `test/divergence/run.sh`, which
   asserts every suite interprets, checks (0 errors), and matches under the
   byte compiler. Self-contained (builds its own aql via a `codeload` tarball).
3. **`consistency` job** also checks `test/divergence/run.sh`'s
   `AQL_BYTECODE_REF` against `AQL_REF`, and references `ci/test.yml` as the
   single source of truth.

## Promoting it (maintainer, one-time)

From a clone with `workflow` scope (e.g. a local checkout authenticated with a
PAT that has `workflow`, or the GitHub web UI):

```bash
git mv ci/test.yml .github/workflows/test.yml
git commit -m "ci: adopt aql 407feda; add gating divergence job"
git push
```

(Or copy the contents over the existing file in the GitHub web editor.) Once
promoted, the `ci/` folder can be removed. Until then, treat `ci/test.yml` as
the source of truth; the consistency check inside it reads its own `env.AQL_REF`,
so it is correct the moment it lands under `.github/workflows/`.

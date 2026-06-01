# CI workflow (staging)

`test.yml` is the GitHub Actions workflow for this module. It builds the
`aql` interpreter from a pinned `aql-lang/aql` commit (cached) and runs
the unit suite, property suite, and smoke test on every push and pull
request. A second, lightweight `consistency` job (no `aql` needed)
checks that the bundled agent skill hasn't drifted from its canonical
copy and that the plugin manifests are valid JSON.

**It lives here, not in `.github/workflows/`, only because the
automation token that created this branch lacked the GitHub `workflow`
OAuth scope and could not write under `.github/workflows/`.** GitHub
only runs workflows from `.github/workflows/`, so the file must be moved
there to take effect.

## Activate it

From a checkout, with a token/credential that has `workflow` scope:

```bash
mkdir -p .github/workflows
git mv ci/test.yml .github/workflows/test.yml
git rmdir ci 2>/dev/null || rmdir ci
git commit -m "Activate CI workflow"
git push
```

The file itself needs no edits — it is ready to run as-is.

# Using this template

**Forking `bloom-filter` to start a new AQL library? Read this first, then
delete it.**

This repo is a GitHub *template* for a small, single-purpose **AQL library**.
It is also a real, runnable library (a bloom filter), so everything here —
tests, docs, CI, and the agent configuration — is a working example you adapt
rather than a skeleton you fill in. Clone it with **“Use this template”**, then
walk the checklist below.

The pair repo [`trie`](https://github.com/voxgig-aql/trie) follows the same
structure for a *multi-module* library; look there if your library ships
several modules/namespaces.

---

## The shape you’re inheriting

```
<lib>.aql                     the library — one module exporting one namespace
aql.jsonic                    package manifest (name, main, files)
api.json                      machine-readable API manifest (for agents)
AGENTS.md                     the canonical agent/human calling guide
CLAUDE.md                     Claude Code entrypoint; @-imports AGENTS.md
README.md                     human landing page
TEMPLATE.md                   this file — delete after instantiation
LICENSE                       MIT
dx-report.md                  AQL-runtime gotchas hit while building THIS library
.gitignore
.claude/
  settings.json               registers the SessionStart hook
  hooks/session-start.sh      builds aql @ the pinned ref in remote sessions
  skills/<lib>-aql/SKILL.md   portable, auto-loaded agent skill (canonical copy)
.claude-plugin/
  marketplace.json            this repo is also a plugin marketplace
plugins/<lib>-aql/
  .claude-plugin/plugin.json  plugin manifest
  skills/<lib>-aql/SKILL.md   BUNDLED copy of the skill (must equal the canonical one)
proposals/
  README.md                   slot for upstream-language RFCs (see the file)
.github/workflows/
  test.yml                    GitHub Actions: build aql, run every suite + consistency job
docs/                         Diátaxis docs: tutorial, how-to, reference, explanation
test/
  <lib>_unit_test.aql         example-based unit tests — imperative (Test.test)
  <lib>_unit_spec.aql         example-based unit tests — declarative spec
  <lib>_prop_test.aql         property tests — imperative (Test.check-prop)
  <lib>_prop_spec.aql         property tests — declarative spec
  <lib>_smoke_test.aql        end-to-end smoke run over every public word
```

---

## Conventions this template encodes

- **Test naming:** `<subject>_<unit|prop>_<test|spec>.aql`, plus one
  `<project>_smoke_test.aql`. `unit` vs `prop` is the *what*; `test` =
  imperative surface (`Test.test` / `Test.check-prop`), `spec` = declarative
  data surface (`Test.run-spec` / `Test.run-property`). `<subject>` is the
  library name for a single-module library, or the variant name for a
  multi-module one (e.g. `radix_unit_test.aql`). Every assertion-bearing suite
  ends with the same tail and prints `all green`; smoke suites carry no
  assertion (pass = no error).
- **Single source of truth for the pinned aql commit:**
  `.github/workflows/test.yml`’s `env.AQL_REF` (full 40-char SHA). The
  `consistency` CI job fails if `.claude/hooks/session-start.sh`’s `AQL_REF` or
  `api.json`’s `aql_ref` prefix drift from it. Bump the ref in the workflow,
  then update those two and re-run the suites.
- **Agent docs, layered (kept self-contained, guarded against drift):**
  `AGENTS.md` is the canonical prose guide; `CLAUDE.md` `@`-imports it;
  `.claude/skills/<lib>-aql/SKILL.md` is a strict condensation that auto-loads;
  `api.json` is the machine-readable signature source; `docs/reference.md` is
  the prose signature source. The bundled plugin SKILL.md must stay byte-equal
  to the canonical one (CI checks this).
- **Docs follow Diátaxis** (tutorial / how-to / reference / explanation), with
  `docs/how-to.md#install-and-run-aql` as the canonical install anchor.
- **`.aql` module header** opens with: one-line summary, the exported
  namespace(s), a `# --- representation ---` block, a `Calling convention:`
  paragraph, and the `# Imported via …` line.

---

## Instantiation checklist

Replace `<lib>` with your library name (kebab-case, e.g. `skip-list`) and
`<Ns>` with your namespace (PascalCase, e.g. `SkipList`).

1. **Rename the module.** `git mv bloom.aql <lib>.aql`; rewrite it for your
   data structure, exporting one `<Ns>` namespace. Keep the header shape.
2. **`aql.jsonic`** — set `name`, `main: <lib>.aql`, `files: [<lib>.aql]`.
3. **Tests.** `git mv` the five `bloom_*` files to `<lib>_*`; rewrite their
   bodies. Keep the standard tail + `all green`.
4. **`api.json`** — set `name`, `description`, the `Bloom` → `<Ns>` namespace,
   and `word_specs` with your exact call shapes, arg order, and return types.
   Leave `aql_ref` as the short prefix of the pinned commit.
5. **`AGENTS.md`** — rewrite the calling convention, API table, idioms, and
   common mistakes for `<Ns>`. This is the single source agents read.
6. **`CLAUDE.md`** — update the one-line description; it `@`-imports `AGENTS.md`
   so it needs no API content of its own.
7. **Skill + plugin.** `git mv .claude/skills/bloom-filter-aql
   .claude/skills/<lib>-aql` and `plugins/bloom-filter-aql plugins/<lib>-aql`;
   rewrite both `SKILL.md` copies (keep them identical) and update
   `marketplace.json` + `plugin.json` (name, source, description,
   homepage/repository).
8. **SessionStart hook** — in `.claude/hooks/session-start.sh`, set the smoke
   path to `test/<lib>_smoke_test.aql`. Set `AQL_REF` to your pinned commit
   (same value as `.github/workflows/test.yml`).
9. **CI** — in `.github/workflows/test.yml`, set `env.AQL_REF`, list your suites with clear
   step labels, point the advisory check at `<lib>.aql`, and update the
   `consistency` job’s plugin paths.
10. **Docs** — rewrite `docs/*` for your domain; keep the four-mode structure
    and the install anchor.
11. **`dx-report.md`** — clear it and record the AQL-runtime gotchas *you* hit;
    they are project-specific.
12. **`README.md`** — rewrite for your library (drop the “Using this as a
    template” pointer).
13. **`proposals/`** — leave empty apart from its `README.md` until you have an
    upstream-language RFC to file.
14. **Delete `TEMPLATE.md`** (this file).
15. **CI is already live** at `.github/workflows/test.yml` — a repo created with
    “Use this template” inherits it and runs it on the first push/PR (just enable
    Actions for the new repo).

When the rename is done, `for f in test/*.aql; do aql "$f"; done` should end
every suite with `all green`.

# proposals/

Upstream **AQL-language** design proposals (RFCs) discovered while building
*this* library — changes to the `aql` interpreter itself, not to this library’s
API. They live here so the idea is captured next to the code that motivated it.

- One proposal per file, kebab-case (`lazy-arg-resolution.md`).
- Link each one from the relevant gotcha in [`dx-report.md`](../dx-report.md),
  and record its provenance (the line of work that surfaced it) at the top.
- These are **project-specific**: they are *not* carried into projects derived
  from this template. A fresh clone starts with an empty `proposals/` (just this
  file).

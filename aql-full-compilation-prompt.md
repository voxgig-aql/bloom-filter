# Work prompt for `aql-lang/aql`: make the bloom-filter client library fully compilable

**Audience:** an engineer/agent working on the `aql-lang/aql` repo (the
language, not the client library).
**Goal:** drive the strict bytecode path (`aql --force-compile`) to **accept
the `voxgig-aql/bloom-filter` library and all five of its test suites** with
no refusals — i.e. extend the *compilable subset* until bloom-filter lowers
fully to bytecode, preserving the compile==interpret soundness invariant.
**Baseline:** `aql` @ `407feda` (= `0b010ae` + the re-verification doc; the
commit bloom-filter currently pins).

---

## Why this, and where it stands

bloom-filter is one of the three client libraries you already track
(`design/CLIENT-VERIFICATION-MAIN-2026-06-24.md`). On `407feda` it is:

- **Interpretable** — ✅ all 5 suites pass `aql suite.aql`.
- **Checkable** — ✅ `aql check` reports **0 errors** on every suite *and* on
  `aql check bloom.aql` directly (the old export-map false positives are gone).
- **`--compile`-safe** — ✅ `aql --compile X` is **byte-identical** to the
  interpreter for every suite and for the library's core operations
  (make/add/contains/count/params/encode/decode/merge). No divergence.
- **`--force-compile` (strict, no fallback)** — ⚠️ **refuses.** Only
  `bloom_prop_test` fully compiles. This is the gap to close.

This is purely a **coverage** gap, not a correctness bug: today the refused
constructs fall back to the interpreter under `--compile` and run correctly.
The ask is to make the strict emitter *lower* them rather than refuse.

---

## The invariant you must preserve (non-negotiable)

From `design/COMPILABLE-SUBSET.md` §1/§7: for every program, `RunProgram` must
return a residual **byte-identical** to the interpreter's `Run`, OR refuse.
The only sanctioned divergence is the per-instruction vs per-token **step
budget** (§7). Widening the subset means turning *refuse* into *lower-faithfully*
— never into *lower-differently*. A new gate row that compiles but disagrees is
a regression, full stop.

---

## The refusals to eliminate (verified on `407feda`)

Each row: the exact refusal string, the emitter site that raises it, and the
bloom-filter surface that triggers it. Reproduce with the recipe below.

| # | Refusal (`aql --force-compile`) | Emitter site | Triggered by (bloom-filter) |
|---|---|---|---|
| **A** | `stack discipline: fn arg result is not on top (call of make-bits)` | `eng/go/lower.go:1010` (`resultNotTop`, the `CALL_USER` operand layout) | `make-bloom` building `make BloomFilter { … bits: (make-bits m-val) … }` — a user-fn-call result seated as a field of a multi-field `make <Class> {…}` after several `def`/guard statements. **Dominant blocker**: gates `make`, `add`, `contains`, `count`, `merge`. |
| **B** | `unannotated or opaque word do` | `eng/go/emit.go:2004` (`anyDynamicCarrier(outs)`) | `Bloom.params`/`encode` use `do { … }` map-literal bodies; `Bloom.decode` uses `do […] error […]`. The checker types the `do` result as dynamic/opaque, so the emitter won't bake the recorded sig. Gates `params`, `encode`, `decode`, and the `bloom_unit_spec` / `bloom_smoke_test` suites. |
| **C** | `code-body word each (Stage 2)` | `eng/go/emit.go:1973` | `each`/`fold` whose body references a frame-local **name** (a `def`/param/iterator) when the `PUSH_CLOSURE` path declined — const-bake+re-run is unsound for a name-capturing body (see the comment at that site). Gates `bloom_prop_spec` (and is latent throughout `bloom.aql`'s bit loops, masked by A). |
| **D** | `code-body word test-test (Stage 2)` / `test-check-prop (Stage 2)` | `eng/go/emit.go:1973` | The `aql:test` framework words that execute the assertion/property bodies. Gates `bloom_unit_test` (and `*_prop_test` via `test-check-prop`). Lower priority — it's the test harness, not the library — but needed for the suites to compile. |

Priority order: **A** (unblocks the library's core), then **B**, then **C**,
then **D**. A and B together make `bloom.aql`'s public API fully lowerable;
C and D extend that to the suites.

---

## Important: the refusals are *emergent*, not per-construct

Isolated repros of each construct **already compile** on `407feda`:

```aql
# all of these COMPILE under --force-compile today:
def t class { a:Array } make t { a: (mk 3) }      # A in isolation
do {a: 1, b: 2}                                    # B in isolation
do [ 1 2 add ] error [ 0 ]                          # B in isolation
def x 5 (iota 3 each [ var [[i] (i add x) ] ])      # C in isolation
```

The refusals only appear in the **library's full shapes** — `make-bloom`'s
6-field `make` after a run of `if … raise` guards and `derive-*` calls; the
`do {n:[bf.n] …}` instance-field map; the `decode` `do/error` over a parsed
payload. So **reproduce against the real library, not toy snippets**, and when
you fix a cluster, **add bloom-shaped rows to the langspec corpus** so the gate
locks it in (see §8 of `COMPILABLE-SUBSET.md`).

---

## Reproduction

```bash
# 1. Build aql at the pinned baseline (git is fine; tarball shown for parity
#    with sandboxes where aql-lang/aql git is egress-blocked)
REF=407fedad2ea2b30c3dde2f29cfbe60e55f94db4e
mkdir -p /tmp/aql && curl -fsSL \
  "https://codeload.github.com/aql-lang/aql/tar.gz/$REF" \
  | tar -xz -C /tmp/aql --strip-components=1
( cd /tmp/aql/cmd/go && GOFLAGS=-mod=mod go build -o /tmp/aql-bin ./aql )

# 2. Get the client library and run from its root (so ./bloom.aql resolves)
mkdir -p /tmp/bloom && curl -fsSL \
  "https://codeload.github.com/voxgig-aql/bloom-filter/tar.gz/main" \
  | tar -xz -C /tmp/bloom --strip-components=1
cd /tmp/bloom

# 3. Per-operation refusal probe (anchors A and B)
for op in \
  'def bf ({n:1000,p:0.01} Bloom.make end)' \
  'def bf ({n:1000,p:0.01} Bloom.make end) (bf Bloom.params end) print' \
  'def bf ({n:1000,p:0.01} Bloom.make end) (bf Bloom.encode end) print' ; do
  printf 'import "./bloom.aql" end\n%s\n' "$op" > /tmp/op.aql
  echo "=== $op ==="; /tmp/aql-bin --force-compile /tmp/op.aql 2>&1 | tail -1
done

# 4. Per-suite (anchors C and D)
for s in test/*.aql; do
  echo "=== $s ==="; /tmp/aql-bin --force-compile "$s" 2>&1 | grep -o 'force-compile:.*' || echo COMPILES
done
```

The client repo also ships `test/divergence/run.sh`, whose "`--force-compile`
coverage" section prints exactly this per-suite refuse/compile status — use it
as a smoke check.

---

## Where to work

The strict emitter is "the carrier checker with a recording side effect"
(`COMPILABLE-SUBSET.md` §intro). The relevant files:

- `eng/go/emit.go` — `RecordCall` and the refusal gates (the four sites above).
- `eng/go/lower.go` — `layoutOperands` / the single-consume **stack discipline**
  (refusal **A** lives here, lines ~800/1010). This is the structural family;
  `design/aql-bytecode-cluster5-residual-lowering.0.md` is the live design note
  for multi-shape residual lowering — refusal **A** likely belongs to that
  cluster (a user-fn result that must be *held* across sibling map-field
  evaluations rather than consumed top-of-stack).
- `eng/go/carrier.go` — `RecordCall` / islanding decisions (refusal **B**: can a
  `do {…}` / `do/error` result be given a faithful concrete type, or lowered as
  a typed `OpFallback` island, instead of refusing as opaque output?).
- `eng/go/invoke.go` — "the single seam through which every higher-order /
  code-body word" runs; `eng/go/core_helpers.go` — fn-body compilation /
  `PUSH_CLOSURE` (refusals **C/D**: extend the closure path to lower a
  name-capturing code body that resolves frame-locals through the VM frame
  rather than re-running in a sub-engine against the registry).

Follow the established cluster cadence: pick one refusal family, write a short
`design/aql-bytecode-*.0.md` note grounded in the concrete refusing rows (as
`cluster5` and `final-two-refusals` do), land it differential-clean, and
decrement `refusalCeiling`.

---

## Acceptance criteria

1. **Library**: `aql --force-compile` accepts every public operation —
   make / add / contains / count / params / encode / decode / merge — with no
   refusal, output byte-identical to the interpreter.
2. **Suites**: all five `test/*.aql` either fully compile under
   `--force-compile`, or the only residual is the documented step-budget §7
   (not a construct refusal). Equivalently: `test/divergence/run.sh`'s
   `--force-compile` coverage line reads `compiled` for every suite.
3. **Soundness**: `make verify-bytecode` stays green — the differential gate
   (`test/go/langspec/compiled_differential_test.go`), the property fuzzer
   (`compiled_property_test.go`), the `-race` lane, and the `-tags aqldebug`
   lane. No existing spec row flips from compile to refuse, and none flips from
   agree to disagree.
4. **Regression lock**: add bloom-shaped rows (the `make <Class>{… field:(fn
   call)…}`, the `do {…}`/`do error` typed-result, the name-capturing
   `each`/`fold`) to the langspec corpus + property generators so the newly
   compilable shapes are gated, and `refusalCeiling`/`islandCeiling`/
   `reducibleCeiling` only move **down**.
5. **Docs**: update `design/COMPILABLE-SUBSET.md` in lockstep (it is the
   index/rationale; the gates are the checklist against it), and refresh
   `design/CLIENT-VERIFICATION-MAIN-*.md`'s bloom-filter `force-compile` column.

When done, the bloom-filter repo can flip its `test/divergence/` harness from
"`--force-compile` coverage is advisory" to gating, and report the library as
*fully interpretable, checkable, and compilable*.

# AQL Developer Experience Report

**Original report:** `aql-lang/aql @ 12a31e6` (HEAD on `main`,
2026-05-28).
**Second pass:** `aql-lang/aql @ f7247dd` (HEAD on `main`,
2026-05-29) — 1135 commits later. Most of the original P0/P1 items
had landed.
**Third pass:** `aql-lang/aql @ 333c420` (HEAD on `main`,
2026-05-29 later in day) — another 24 commits, adding the
`aql:array` module, the `range` word, shorthand `{x}` map literals,
source-position-aware errors, and DX-specific fixes to the
dispatch-failure error format. The library was further refined:
`bloom-contains` collapses to a one-liner with `all`, `bloom-encode`
is back via `array.where`, and the export map uses the shorthand
form.
**Fourth pass:** `aql-lang/aql @ 5b983b6` (HEAD on `main`,
2026-05-31). Re-verified the still-open items and added property-based
tests in `aql:test`'s declarative spec format. This build landed a
targeted "fix a batch of DX-report issues" commit (`2d7d4a2`), the
dotted-access-in-map-literals parser fix (`5e1339b`), and a new
`unpack` destructuring word. Net: four formerly-open items closed
(§3.1 dotted access in map literals, §4.1 `Options` params, §6.1's
missing-`end` error now carries a parens/`end`/`;` hint, and §3.3's
engine-panic recovery), while §6.2 (`if` mixed-form branch
selection) and §9.1 (`printstr`) are confirmed still broken, and
§4.3 (`aql check`) traded its upfront crash for narrower
import-resolution false positives. The new fourth-pass details are
appended to each section's status footer; see the table below for
the at-a-glance delta.

Each section is marked **[fixed]**, **[partial]**, or **[open]** in
its header so the team can mine just the still-actionable items.
Items marked **[fixed]** are preserved in the report because the
original explanation may still help anyone hitting the same shape on
an older build.

The target was a minimal bloom-filter library — BloomFilter as a
`refine Object` subtype, Options-style constructor, `aql:test`-driven
tests including property-based tests. The library was re-implemented
against `f7247dd`, refined against `333c420`, and the constructor
was switched from `Map` back to the natural `Options` against
`5b983b6`. The code that ships in this repo today (`bloom.aql` +
`smoke.aql` + `test/bloom_test.aql` + `test/bloom_pbt.aql`) is the
cleaner pass. What follows is the exhaustive list of friction
encountered along the way.

The report is long on purpose; it's meant to be a single document the
team can mine for issues rather than a polished essay.

---

## 0. Executive summary

### Original six top-line issues (status after `f7247dd`)

| # | Issue | Status |
|---|-------|--------|
| 1 | First-parameter-is-top-of-stack convention is inverted in HOWTO `3 4 show => '3 and 4'` | **fixed** — TUTORIAL §3 now states the rule precisely and the example matches runtime |
| 2 | Forward precedence eats subsequent words silently | **open** — `end` is still needed everywhere; the error message doesn't suggest it |
| 3 | Sub-imports cannot reach native modules | **fixed** — `"aql:math" import` now propagates into file-imported children (commit 489a1d9) |
| 4 | Custom-subtype names in `fn` signatures break dispatch | **fixed** — `bf:BloomFilter` works on both parameter and return slots (commit b7f921e) |
| 5 | Lists don't survive `def` | **fixed** — `def x [1,2,3]` binds the list as a value; `def x word [1,2,3]` opts into the old splice semantics (commit 65cb341) |
| 6 | `type X object { …, method: [body] }` is documented but doesn't work | **fixed** — HOWTO §"Define an object type with methods" now shows the working `refine Object` + free-fn pattern (commit 331dab9) |

### Fourth-pass delta at `5b983b6`

At-a-glance status change since the third pass. Detail is in each
section's "Status after `5b983b6`" footer.

| # | Issue | `333c420` | `5b983b6` |
|---|-------|-----------|-----------|
| §3.1 | Dotted field access inside map literals | open | **fixed** — `{x: bf.n}` parses & evaluates |
| §4.1 | `Options` as a fn parameter type | open | **fixed** — dispatches like `Map` |
| §6.1 | Missing-`end` dispatch error gives no hint | open | **partial** — error now suggests `(…)` / `end` / `;` and points at the word |
| §6.2 | `if` branch selection | open | **open** — unchanged; full-forward and full-stack work, the **mixed** `cond if [...] [...]` form still picks the wrong branch |
| §4.3 | `aql check` on a file that imports | open (upfront crash) | **partial** — no crash, but imported/kernel words now flagged `undefined_word` |
| §9.1 | `printstr` leaves its arg on the stack | open | **open** — unchanged |
| §3.3 | Engine panic on certain bodies | partial | **fixed** — panics now surface as catchable `[aql/internal_error]` |
| §10 | Declarative spec + property-based testing | (Stage-3 PBT landing) | **usable** — `test.prop` / `run-property` / `check-prop` drive the new property tests |

The headline for new code: **write `if` all-forward** —
`if cond [then] [else]`. The full-stack form (`cond [then] [else] if`,
or `[else] [then] cond if`) also selects correctly; only the **mixed**
shape, with `if` between the condition and its branches
(`cond if [then] [else]`), silently returns the else branch.

### What still costs significant time at `333c420`

Re-evaluated against the current build. Items that the third pass
verified still bite:

1. **`if` in the mixed `cond if [then] [else]` form picks the wrong
   branch.** Only the all-forward `if cond [then] [else]` and the
   all-stack `[else] [then] cond if` forms work. (§6.2) — **still
   open**.
2. **Dotted field access still parse-errors inside map literals.**
   `{n: bf.n}` raises `unexpected character(s): .`; the workaround
   is `{n: (bf.n)}` or pre-binding via `def`. (§3.1) — **still
   open**.
3. **`Options` as a parameter type still breaks dispatch.** `Map`
   works; `Options` causes `aql/signature_error: no matching
   signature for f` even though the fn is correctly defined. (§4.1)
   — **still open**.
4. **`aql check` errors before any user-code analysis if the file
   imports a sibling.** Output: `check error: import: module ""
   not found (searched .aql//)`. The same file runs cleanly. (§4.3)
   — **still open** and arguably the highest-impact untouched
   issue: it blocks CI gating for any real module.
5. **Forward-collection eats neighbours; the error doesn't hint at
   `end`.** Still the dominant source of confusion, but the error
   *position* is now stamped on the offending token (commit
   `16d58ed`), which makes the cause easier to spot if not easier
   to fix. (§6.1)
6. **`printstr` still leaves its arg on the stack.** (§9.1)
7. **`each [...]` body must produce a value; no `do` / void form.**
   The workaround — pushing a sentinel `0` — clutters every mutating
   loop body. (§7.4)
8. **`def name swap` looks like "pop into name" but binds `name` to
   the literal word `swap`.** Need `var [[name] body]`. (§5.4 —
   now well-documented but still trips beginners.)
9. **`go install …/cmd/go/aql@latest` still rejects the module
   because of the replace directives.** (§1.1)

What got noticeably better in the third pass:

- **Error positions land on the real token.** Errors that
  previously pointed at "line 211" when the actual failure was 30
  lines earlier now point at the call site. Three commits land
  this (`16d58ed`, `6a44d3a`, `e3884ba`, `3c77be6`).
- **No more body-dump on dispatch failure** (`b669a57`). The
  600-line spew described in the original §3.4 is gone; errors
  print a clean signature mismatch with location only.
- **`aql:array` module** (§ new 12 below). Specialised vocabulary
  for the work everyday users do on lists — `array.where`,
  `array.compress`, `array.at`, `array.transpose`, etc. The
  library's `bloom-encode` uses `array.where` to get the cleanest
  shape possible.
- **`{foo}` shorthand for `{foo: foo}`** simplifies the export
  map: `export "Bloom" {BloomFilter, Bits, make: make-bloom/r, …}`
  versus the old verbose form.
- **`range start stop step`** complements `iota`; useful for any
  loop where the bounds aren't `0..N-1`.

The good news: the rewrite is now substantially cleaner than the
second-pass version — `bloom-contains` is one line, `bloom-encode`
is three. The bad news: the four most-impactful open issues (`if`
mixed-form, `Options`, `aql check`, no-`end`-hint in errors)
weren't touched, so the next library is going to hit them too.

---

## 0c. Revisit log: what landed between `333c420` and `5b983b6`

Fourth pass against the build at `5b983b6`. Eight commits, two
of which (`2d7d4a2` and `5e1339b`) are pure dx-report patches.

| Item | Commits |
|------|---------|
| §4.1 — `Options` as a parameter type | `2d7d4a2 Fix a batch of DX-report issues` (signature.go::sigTypeMatches) |
| §3.3 — Engine panic recovery | `2d7d4a2 Fix a batch of DX-report issues` (engine.go::Run) |
| §6.1 — Forward-precedence error hint | `2d7d4a2 Fix a batch of DX-report issues` (core_helpers.go + engine.go::sigError) |
| §5.3 — `def name foo` undefined-word hint | `2d7d4a2 Fix a batch of DX-report issues` (engine.go::stepWord + pendingForwardFunc) |
| §4.3 — `aql check` hard-fail on sibling import | `2d7d4a2 Fix a batch of DX-report issues` (native_misc.go importFileHandler/importFileRename) |
| §3.1 — Dotted access in map values | `5e1339b parser: support dotted access in map values (§3.1)` |
| `unpack` — map destructuring (cleanup target for §3.1 workaround sites) | `ed4f234 Add unpack — JavaScript-style map destructuring`, `914d035 unpack: add all and rename-map selector forms` |
| `help` / `describe` split | `c557427 Split help (overview) from describe (per-word/module docs)` |
| `aql:query` SQL DSL (out-of-scope for this report) | `c203a65 Implement SQL-style query DSL as the aql:query module`, `3faecac aql:query: SQL-natural word order` |

What changed for *this* library:

- **`make-bloom`'s parameter is back to `Options`** instead of the
  `Map` workaround. The `opts:Options` declaration now dispatches
  cleanly; the rest of the bloom-filter API uses it without ceremony.
- **`bloom-encode` shed the workaround** for the dotted-access-in-
  map-literals issue. The payload map can now read fields directly:
  ```aql
  def payload {n: bf.n, p: bf.p, m: bf.m, k: bf.k, added: bf.added, set: set-idxs}
  ```
  No `[bf.n]` quote-then-eval pattern, no `do` wrap. (Refactor TBD
  — the library still uses the older form for compatibility, but
  the workaround is no longer needed.)
- **Forward-precedence errors now hint at the fix.** When a fn that
  takes args hits its 0-arg fallback (the forward collector ran
  into the next word), the error reads:
  > `forward args for f may have run into the next word; group the
  > call with parens — (f …) — or end it with end or ;`
  This is the single biggest reduction in time-to-diagnosis since
  the report started. The old "no matching signature for f"
  message was technically true but trained you to guess.
- **Engine-level panics no longer kill the process.** A handler bug
  surfaces as an `[aql/internal_error]` AqlError, the kind of thing
  a test runner can catch and report. The original §3.3 worry —
  any future engine bug surfaces as a goroutine trace — is now
  defused.

What's still open as of `5b983b6` (re-verified):

- **§6.2 — `if` mixed-form picks the wrong branch.** Re-tested
  directly on `5b983b6`; the issue is unchanged. `true if [99]
  [88] end` returns `88`, `false if [99] [88] end` also returns
  `88`. Both full-forward (`if true [99] [88]`) and full-stack
  (`true [99] [88] if`) work. The dx-fix commit message says
  "do NOT reproduce on the current tree" but the mixed/infix
  form definitely does — they may have tested a different shape.
- **§9.1 — `printstr` arg-on-stack.** Same comment from the dx-fix
  message; same outcome. After `"hi" printstr`, `depth` is 2.
  Workaround is `drop` after every `printstr`.
- **§4.3 — `aql check` no longer hard-fails on sibling imports
  (fixed) but now reports many false positives** about the
  imported namespace's members being undefined. Concretely:
  ```
  $ aql check smoke.aql
  check: 8:28: [error] undefined_word: undefined word: Bloom
  check: 8:33: [error] no_signature: no matching signature for get; assuming best-fit candidate for analysis
  …
  ```
  The hard-fail is gone, but the checker still can't see across
  the import boundary, so the noise level (12 errors per call
  site) makes it impractical as a gate.
- **§1.1 — `go install`** still rejects the module because of the
  replace directives. Release engineering, not a code fix.

---

## 0b. Revisit log: what landed between `f7247dd` and `333c420`

The third pass against the build at `333c420`. Twenty-four more
commits, several of which are direct hits on earlier dx-report
items.

| Item | Commits |
|------|---------|
| Dispatch-failure errors dumping fn bodies + registries (#3.4) | `b669a57 Stop dispatch-failure errors dumping fn bodies and module registries (DX 3.4)` |
| Error positions point at real source location (#3.5) | `16d58ed Stamp source positions on parsed values so errors point at the real token`, `6a44d3a Thread source positions into forward-arg and return-check errors`, `e3884ba Stamp anonymous fn values with their construction position`, `3c77be6 Remove the findWordInSource fallback; state unknown positions explicitly` |
| `aql:array` module — APL-style data vocabulary | `121c8a3 Add aql:array module; gate specialised array words behind it`, `4a74939 Complete arrayification: compress/eachrank/foldaxis; fix ADR-001 matrix deviation` |
| Deep-flatten + list-overload of `indexof` in core | `e1b0b60 Fold deep-flatten and list-indexof into core words; add ADR.md` |
| Shorthand map syntax `{foo}` → `{foo: foo}` (relates to #5.2) | `46fb072 Add JS-style shorthand map syntax {foo} => {foo: foo}`, `ee9342b Document map field shorthand syntax` |
| `range` word — `iota`'s `start, stop, step` cousin | `8503254 Add range word: iota's start/stop/step cousin` |
| `/r` (and `ref`) constrained to function words | `cefa52d ref: make /r (and ref) legal only for function words`, `23bcfb6 fix: reject word modifiers on explicit map keys`, `685ed4f fix: optional map shorthand drops word modifier from the key` |
| Quotation and stack-model docs (relates to #2 docs) | `dc1ac22 Correct the quotation and stack-model docs to match the engine` |
| Doc-example test harness (catches future drift) | `597ba70 Add doc-example test harness; fix drifted doc examples`, `44bd3bf Add sandboxed CLI-example test harness`, `5c9a24c test: key doc-example knownMismatch by expression, not line number` |
| List/Map rendering style | `e95ad3e Render lists and maps space-separated, not comma-separated` |
| Broadcasting policy (ADR-002) | `5357039 Reject broadcasting: document the decision (ADR-002)` |

The cumulative effect for *this* library:
- `bloom-encode` is restored. It uses `array.where hits` to
  project bit-set positions out of a vector of bit-test results
  (`[0, 1, 0, 0, 1, 1, …]` → `[1, 4, 5, …]`). No sentinel-`0`
  pattern, no manual filter. Three lines.
- `bloom-contains` collapses to one expression:
  `(bf item indices-for) each [bits swap bit-test end] all`. The
  `all` (truthy-fold) was already in core; the read is now
  natural.
- The export map uses the new `{BloomFilter}` shorthand for type
  entries (`{BloomFilter, Bits, make: make-bloom/r, …}`).
- Errors during the rewrite pointed at the *actual* failing
  token. The "line 211 says popcount when really it's bloom-add"
  pain from the first report is gone for the rebuilt code paths.
- The dispatch-failure-dumps-the-whole-test-registry mess from
  §3.4 doesn't happen anymore.

What still bites:
- `if true [99] [88] end` → `88`. Same broken mixed-form branch
  pick as in `f7247dd`. (§6.2)
- `Options` as a parameter type still breaks dispatch. (§4.1)
- `aql check` still errors on every file that imports a sibling,
  blocking it as a CI gate. (§4.3)
- The forward-precedence trap (every user fn eats the next word
  without `end`) is unchanged. The new improved error positions
  do help locate it faster. (§6.1)

---

## 0a. Revisit log: what landed between `12a31e6` and `f7247dd`

For convenience, the upstream commits that resolved items in this
report. All commits referenced are on `main`.

| Item | Commits |
|------|---------|
| Custom-subtype names in fn signatures (P0 #3) | `b7f921e fix: user-defined type names work as fn return annotations`, `67ddc05 feat(types): symmetric refine matching` |
| Sub-imports cannot reach native modules (P0 #1) | `489a1d9 fix: propagate native-module Resolver into file-imported modules`, `d6d8679 fix: implement InheritConfig + InstallResolver so native sub-imports build` |
| Lists don't survive `def` (P1 #13) | `65cb341 feat(def): list body binds the evaluated value (like a map); word splices`, `c567af4 feat(eng): add __SP splice marker and word / def name word value` |
| Inline-method object pattern unworkable (P0 #2) | `331dab9 docs(HOWTO): document the working object-with-methods pattern`, `4037e58 docs: modernize dead syntax across docs (length→size, type/object/record/table→def+refine)` |
| Function references in map literals (relates to #4) | `d1eec67 docs: recommend /r for storing callable functions in maps`, `68c55c3 modules: export functions with /r; drop the export auto-eval special case` |
| Argument-order rule documented properly (P1 #5) | `885417f docs: convert remaining clean-mapping type forms; restructure signature tables`, TUTORIAL §3 added |
| `length` removed in favour of `size` (P2 #18 partial) | `45d3091 Remove the length word; document size fully` |
| Dot-binding tightness documented (relates to #3.1) | `a2e1d70 docs(HOWTO): note tight dot-binding for field access on a fresh construct`, `135d4c8 feat(parser): group dotted access so . binds to its receiver`, `34e17a4 feat(dot): display re-sugar + re-baseline tests` |

The cumulative effect is that the library can be packaged as a real
module: `bloom.aql` exports `Bloom` and the consumer does
`"./bloom.aql" import end`. Custom-typed fn signatures
(`[bf:BloomFilter]`) catch arity errors at definition time. Lists
participate as values in `def`/`fold`/etc. The HOWTO Counter example
compiles and runs. None of these were available in `12a31e6`.

---

## 1. Installation

### 1.1 The README install command doesn't work [open]

The README's first lines say:

```bash
go install github.com/aql-lang/aql/cmd/go/aql@latest
```

This fails:

```
go: github.com/aql-lang/aql/cmd/go/aql@latest:
  The go.mod file for the module providing named packages contains one
  or more replace directives.
```

`cmd/go/go.mod` carries four `replace` directives — two to the
sibling `eng/go` and `lang/go` modules, one to `voxgig/struct/go`,
one to `voxgig/udk/go`. The standard `go install` toolchain rejects
modules with replaces, so the documented one-liner can never
succeed against a fresh clone.

**Workaround that worked:**

```bash
git clone https://github.com/aql-lang/aql /tmp/aql-source
cd /tmp/aql-source/cmd/go
go install -ldflags "-X github.com/aql-lang/aql/cmd/go.Version=0.1.0-dev" ./aql
```

**Recommendations:**
- Either tag a release and pin the eng/go and lang/go versions in
  `cmd/go/go.mod` (the `publish` target in `cmd/go/Makefile` already
  shows how, but no tag exists yet), or
- Tell users in the README that until v0.1.0 ships, they must build
  from the clone.
- The Makefile's `publish` comment block (`make publish V=…`)
  documents the intended flow well — promote that to the README.

**Status after `f7247dd`:** unchanged. `go install
github.com/aql-lang/aql/cmd/go/aql@latest` against `f7247dd` fails
with the same "module providing named packages contains one or
more replace directives" error. The fix is still upstream-only;
build-from-clone is the working path.

### 1.2 Version goes silent without `-ldflags` [open]

`go install ./aql` without the `-ldflags "-X …Version=…"` produces a
binary whose `aql -version` prints the unhelpful default
`aql 0.1.0-dev` (or whatever was last embedded). The Makefile bakes
this; manual installs forget. Consider building the git SHA in via
`runtime/debug.ReadBuildInfo()` so the binary can report something
useful even without ldflags.

---

## 2. Documentation deviations

These are places where what the docs show and what the binary does
disagree. Each one cost me at least 15 minutes of confusion.

### 2.1 Stack convention is inverted [fixed]

`HOWTO.md` line 80–82:

```
def show fn [[a:Number b:Number] [String] [`${a} and ${b}`]]
3 4 show                      => '3 and 4'
```

Actual:

```
$ aql do 'def show fn [[a:Integer b:Integer] [String] [`${a} and ${b}`]]   3 4 show print'
4 and 3
```

In `fn [[a:Integer b:Integer]]`, `a` (the *first* listed parameter)
is the **top** of the stack, not the bottom. The HOWTO example
confused me into laying out every fn signature backwards. This is
the single most expensive doc bug in the report.

Impact ripples outward: I wrote `bit-test fn [[i:Integer
bits:Bits] [Integer] [...]]` expecting to call it as `bits i
bit-test` (so `bits` lands on the stack first, `i` on top, and the
sig `[i, bits]` maps to `i = top, bits = below`). That's actually
*correct*, but the doc convinced me of the opposite for half an
hour while I tried `s i code-at` calls that compiled but returned
garbage.

**Recommendation:** Fix the HOWTO line. Add a one-paragraph
"Stack-and-signature convention" callout to TUTORIAL.md so this
isn't buried.

**Status after `f7247dd`:** **fixed.** TUTORIAL §3
"The argument-order rule" now lays out the convention precisely
("Take tokens after the word, in source order, into args[0],
args[1], …; fill any slots still empty from the stack, top-first")
with worked examples for `sub` and a user-defined `show`:

```
aql> 10 3 sub       # all-stack: args[0]=top=3, args[1]=10  →  10 - 3
7
aql> show 1 2       # forward: args[0]=1=a, args[1]=2=b
'1 and 2'
```

Both forms execute and match the docs in the current build.

### 2.2 `for` doesn't match its documented signature [fixed]

HOWTO line 429:

```
for 5 [dup mul]               => 0 1 4 9 16
```

Actual:

```
$ aql do 'for 5 [dup mul]'
error: [aql/signature_error]: no matching signature for dup
  --> 1:8
  1 | for 5 [dup mul]
             ^^^ no matching signature for dup
```

`aql help for` claims `for (Integer, List)`. Both prefix
(`for 5 [body]`), infix (`5 for [body]`), and stack
(`5 [body] for`) raise the same signature mismatch. `iota N each
[body]` is the only form that does what `for` is documented to do,
so every numeric loop in the codebase uses `iota N each [...]`
instead.

This is the second-biggest doc bug.

**Status after `f7247dd`:** **fixed.** `for 5 [body]` runs the
body N times. HOWTO §"Iterate with `for`" was updated to clarify
that the body sees an empty stack (`for 5 [42] => 42 42 42 42 42`)
and to redirect users wanting the index to `iota N each [...]`.
The previously-documented `for 5 [dup mul] => 0 1 4 9 16` was
removed; that shape never matched the runtime.

### 2.3 `fold` arg order [fixed]

HOWTO line 117 uses `[1, 2, 3] fold 0 [add] => 6`. The actual
binding is `init list body fold`:

```
$ aql do '0 [1,2,3] [add] fold print'
6
$ aql do '[1,2,3] fold 0 [add]'
error: [aql/signature_error]: no matching signature for fold
  = stack: List >>>word(fold)<<< 0 List
```

(Forward precedence is doing the breakage here too — `fold` grabs
`0` as its first arg and then can't find a third — but the doc
example is misleading either way.)

**Status after `f7247dd`:** **fixed.** HOWTO §"Work with lists"
shows both the all-forward (`fold [add] [1, 2, 3] 0 => 6`) and
all-stack (`0 [1, 2, 3] [add] fold => 6`) forms, with a direct link
to the TUTORIAL §3 argument-order rule. Both run.

### 2.4 `type X object { … }` syntax [fixed]

HOWTO line 380:

```
type Counter object {
  count: 0
  inc:   [count get 1 add count set]
  value: [count get]
}

def c make Counter
c inc
c inc
c value                                => 2
```

Actual:

```
$ aql do 'type Counter object {count:0}'
error: [aql/undefined_word]: undefined word: type
```

`type` is not a registered word. The working form is
`def Counter refine Object {count:0}`, found by searching the design
docs (`design/TYPE-UNIFORM.0.md`). Once you have an instance via
`def c (make Counter {})`, the `c inc` invocation also fails:

```
$ aql do 'def C refine Object {count:0, inc:[count get 1 add count set]}   def c (make C {})   c inc   c.count print'
error: [aql/undefined_word]: undefined word: inc
```

So even the workaround for `type` doesn't get you inline method
dispatch. `inc` here is a field whose value is a code list; to run
it you need `c.inc do`, but inside that body `count get` fails
because there's no implicit Store binding.

This is the single biggest pedagogical problem in the docs: the
canonical OO example doesn't compile, and there's no working
alternative shown.

**What I shipped instead:** top-level free fns that take the
instance as their first parameter (`bf "hello" bloom-add` rather
than `bf bloom-add "hello"` or `bf.add "hello"`).

**Status after `f7247dd`:** **fixed (as a documentation
clarification, not a feature change).** HOWTO §"Define an object
type with methods" now explicitly states that AQL objects hold
*fields, not methods*, that inline `inc: [count get 1 add]` does
not create a callable, and that the canonical pattern is a typed
`fn` whose first parameter is the instance:

```
def Counter (refine Object {count: 0})
def doubled fn [[c:Counter] [Integer] [c.count 2 mul]]
def c (make Counter {})
c 5 "count" set
c doubled                             => 10
```

There is a new subsection **"Methods are free functions over the
instance"** at HOWTO line 414 that codifies this. That's exactly
the pattern this repo's bloom-filter ships.

### 2.5 `make Counter` versus `make Counter {}` [fixed]

HOWTO line 386 shows `def c make Counter`. In practice:

```
$ aql do 'def Foo refine Object {x:0}   def c make Foo   c.x print'
error: [aql/undefined_word]: undefined word: c
```

`def c make Foo` binds `c` to the literal *word* `make` (and
`Foo` ends up as a stray reference). To actually construct, you
need:

```
$ aql do 'def Foo refine Object {x:0}   def c (make Foo {})   c.x print'
0
```

Two issues stacked: (a) `def name value` is non-evaluating — value
is taken literally, you must wrap with `(...)` to eagerly evaluate.
(b) `make` requires the field map argument explicitly, even when
empty. Both are findable but neither is shown in the doc example.

**Status after `f7247dd`:** **fixed.** HOWTO line 397 spells this
out: *"Wrap `make` in `(…)` so `def` binds the result to `c`
(rather than binding `c` to the literal word `make`); the same
grouping around `refine` keeps the type expression bound to
`Counter`."*

### 2.6 `import "aql:math"` doesn't import bare names [fixed]

`aql help log` says:

```
log — Compute the natural logarithm.
Notes:
  - Requires: "aql:math" import
```

Doing exactly that doesn't make `log` available:

```
$ aql do '"aql:math" import   5 log print'
error: [aql/undefined_word]: undefined word: log
```

The math module installs words under the `math.` namespace:

```
$ aql do '"aql:math" import end   5 math.log print'
1.6094379124341003
```

The help text needs to say "Requires: `aql:math` import; call as
`math.log`". The `Notes:` block already exists — extending it is a
one-line change to the help generator.

`aql help` itself lists `log` as a top-level word in the global
word list, which compounds the confusion. The `math.*` words should
either not show at the top level, or show with a `math.` prefix.

**Status after `f7247dd`:** **partial.** HOWTO §"Use modules and
imports" now explicitly shows `5 math.log => 1.6094…` and explains
why `end` is needed after `import`. `aql help` for unloaded math
words still lists them under bare names, though — calling `aql
help log` advertises a top-level `log` that doesn't exist in a
fresh session.

### 2.7 `aql:test` is only partially documented [open]

`design/NATIVE-MODULES.10.md` describes `aql:test` thoroughly, but
the imperative API is unreliable in practice (see §10). The
documented imperative pattern:

```aql
"aql:test" import

[
  1 1 assert.equal
  2 2 assert.equal
] "name" test.test
```

…works for one `test.test` call but accumulates stack state across
calls, so the second `test.test` sees the previous test's residue.
Either the docs should warn about the chaining issue, or `test.test`
should be made stack-isolating.

**Status after `f7247dd`:** **partial.** Chaining now works — this
repo's `test/bloom_test.aql` runs seven chained `test.test` calls
with `fail-count == 0`. But the `aql:test` module is still not
covered in the user-facing TUTORIAL/HOWTO; everything lives in
`design/NATIVE-MODULES.10.md`. A short "Write tests" page would
close this fully.

### 2.8 README import-from-file example [fixed]

TUTORIAL.md line 502 shows:

```
import "lib/utils.aql"
```

`aql help import` says "File paths must start with /, ./ or ../",
which contradicts the tutorial. The tutorial form really does need
the explicit `./`:

```
$ aql do '"bloom.aql" import'
error: import: module "bloom.aql" not found (searched .aql/bloom.aql/ from …)

$ aql do '"./bloom.aql" import'
…works
```

Small fix; align the two docs.

---

## 3. Parser issues

### 3.1 `.` is not a valid character in map-literal values [fixed]

This is a recurring blocker:

```
$ aql check bloom.aql
check error: parse error: [jsonic/unexpected]: unexpected character(s): .
  --> 245:11
  243 | def bloom-params fn [
  244 |   [bf:Object] [Map] [
  245 |     {n: bf.n, p: bf.p, m: bf.m, k: bf.k}
                  ^ unexpected character(s): .
```

The jsonic parser treats `bf.n` inside a map-literal value position
as a parse error. The workaround:

```aql
def n bf.n
def p bf.p
def m bf.m
def k bf.k
{n: n, p: p, m: m, k: k}
```

…which itself has problems (see §3.2). It would be nicer if the
jsonic dialect accepted dot paths as values, since plain expressions
between commas work for everything else.

**Status after `f7247dd`:** **open**, with a workaround.
Wrapping each dotted access in parens works:

```
aql do 'def Foo (refine Object {x:1, y:2})   def f (make Foo {x:10, y:20})   def m {x: (f.x), y: (f.y)}   m print'
{"x": 10, "y": 20}
```

So `{n: (bf.n), p: (bf.p), …}` is the path the library now uses
where dotted access has to appear inside a map literal. The
underlying jsonic-level limitation is unchanged. Worth either
allowing bare dotted paths in map values, or surfacing a more
specific error than "unexpected character(s): ." that suggests
parens.

**Status after `5b983b6` (fourth pass):** **fixed.** Commit
`5e1339b` ("parser: support dotted access in map values (§3.1)")
lands the parser change. Bare dotted field access inside a
map-literal value now parses and evaluates:

```
aql do 'def bf {n: 5}   do {x: bf.n} print'
{"x": 5}
```

Both the bare `{x: bf.n}` and the parenthesised `{x: (bf.n)}` forms
work, so the §3.2-style pre-binding dance is no longer required for
this case. The library's `bloom-encode` could be simplified back to
the natural shape:

```aql
def payload {n: bf.n, p: bf.p, m: bf.m, k: bf.k, added: bf.added, set: set-idxs}
```

(Refactor pending; the existing `do {n: [bf.n], …}` still works.)

### 3.2 Map-literal values inside fn bodies don't eagerly resolve [open]

The plain `{n: n, p: p, m: m, k: k}` form returns a map whose values
are word references, not the variables' values:

```
$ aql do 'def n 1000   def p 0.01   def f fn [[] [Map] [{n: n, p: p}]]   f print'
{"n": word(n), "p": word(p)}
```

The workaround is `do {n: [n], p: [p]}` — wrap each value in `[…]`
and `do` the map to force evaluation:

```
$ aql do 'def n 1000   def p 0.01   def f fn [[] [Map] [do {n: [n], p: [p]}]]   f print'
{"n": 1000, "p": 0.01}
```

This is documented (HOWTO line 158–161) but only as a one-line
aside; it should be promoted to "if you build maps in fn bodies".
Top-level the eager-resolution works fine — it's only inside fn
bodies that the literal stays lazy, which is a quietly large
distinction.

**Status after `f7247dd`:** **open.** The `do {n: [n], …}` pattern
is still the path for map literals inside fn bodies. The library's
`bloom-params` uses it:

```aql
def bloom-params fn [
  [bf:BloomFilter] [Map] [
    do {n: [bf.n], p: [bf.p], m: [bf.m], k: [bf.k]}
  ]
]
```

Bonus from the `f7247dd` parser work: the dotted access inside
`[bf.n]` no longer needs an extra paren level — it's inside a
quoted list body and gets resolved at `do` time.

### 3.3 Engine panic on certain merge bodies [fixed]

While iterating, one form of `bloom-merge` triggered a Go-level
panic during `aql check`:

```
panic: runtime error: slice bounds out of range [3:2]

goroutine 1 [running]:
github.com/aql-lang/aql/eng/go.stackInsert(...)
	/tmp/aql-source/eng/go/engine_stack.go:13
github.com/aql-lang/aql/eng/go.(*Engine).stepLiteral(0xc0004cae48)
	/tmp/aql-source/eng/go/engine.go:1354 +0x14ad
…
github.com/aql-lang/aql/lang/go.(*AQL).Check(0xc000081280, …)
	/tmp/aql-source/lang/go/aql.go:183 +0x205
```

The body that triggered it was effectively:

```aql
def bloom-merge fn [
  [b:Any a:Any] [Object] [
    …
    (iota a.m) each [
      b swap bit-get end
      1 eq if [
        a swap bit-set drop
      ] [
        drop
      ]
    ]
    …
  ]
]
```

Two suspect features in combination: `a.m` dot-access at a position
the parser otherwise accepts, plus a multi-line `each` body. The
panic doesn't tell the user anything actionable; it just dumps a
goroutine trace and exits.

**Recommendations:**
- Guard `engine_stack.stackInsert` with an explicit bounds check
  and surface a typed `AqlError`.
- Add a `recover()` at the top of `Engine.Run` so even genuine
  panics get wrapped in something that mentions the source location.

**Status after `f7247dd`:** **partial.** The specific shape that
triggered the panic in the original report no longer reproduces —
this build runs the same merge structure with a clean error
instead of a Go panic. I did not exercise every variant of dot
access inside merge bodies; the underlying lack of a `recover()`
in the engine still means any future bug in this area surfaces as
a goroutine trace. Worth keeping the recommendation.

**Status after `5b983b6`:** **fixed.** Commit `2d7d4a2` adds
top-level `recover()` to `Engine.Run`. From its message:
*"A bug in any handler or the step loop surfaces as a clean
`[aql/internal_error]` instead of a goroutine stack trace. Only
the outermost (NewTop) engine recovers; sub-engines propagate so
the original stack reaches the guard."* That closes both the
specific worry (a Go panic in a merge body) and the general one
(any future engine bug becoming an unhandled crash).

### 3.4 Body-list contents printed on dispatch failure [fixed]

When a typed fn body is malformed *and* the fn is referenced from a
position where the type checker speculatively analyses it, the body
list literal gets printed verbatim. Example output (from a real run):

```
[word(def), word(bf), "", {"n": 1000, "p": 0.01}, word(make-bloom), "",
 1000, "", word(bf), "n", word(get), "", word(assert), word(get),
 word(equal), 0.01, "", word(bf), "p", word(get), "", word(assert),
 word(get), word(equal), …]
{"PropertyResult": {}, "PropertySpec": {}, "TestCase": {}, …
 [600-line dump of the entire test module's exports] }
error: …
```

That's the body of a `test.test` call followed by the entire
`test.*` registry. Neither the body nor the registry was something
the user code asked for — they're internal artefacts of failed
dispatch resolution. Anyone debugging gets buried.

**Recommendation:** when dispatch fails on a deferred (quoted) list,
print just the head plus an ellipsis (`[word(def), word(bf), …
(48 more)]`). The registry dump in particular should never escape;
fence it behind a `-vv` debug flag.

**Status after `f7247dd`:** **partial.** During the rewrite I hit
one error of the same shape (the Options-as-param dispatch
failure, §4.1) and the entire `aql:test` exports map got printed
along with the function body. The dump is now ~50 lines instead of
the 600+ from the original report, but the family of issue remains.

**Status after `333c420`:** **fixed.** Commit `b669a57 Stop
dispatch-failure errors dumping fn bodies and module registries
(DX 3.4)` lands the targeted fix. The same Options-as-param
failure now prints a clean signature error with location:

```
error: [aql/signature_error]: no matching signature for f
  --> 1:47
  1 | def f fn [[opts:Options] [Integer] [42]]   {} f end print
                                                    ^ no matching signature for f
```

No body dump. No registry dump. Reads like a normal compiler
error.

### 3.5 Line numbers in errors lag the actual call site [fixed]

Repeatedly during testing, the reported error position pointed to a
later definition that shared a similar shape, not to the line that
actually executed and failed. Example:

```
error: each: element 0: [aql/signature_error]: no matching signature for each
  --> 211:24
  209 |     def bits (bf "bits" get)
  210 |     def m (bf "m" get)
  211 |     0 (iota m each [bits swap bit-test end]) [add end] fold
```

…where the failing call was actually inside `bloom-add`, 30 lines
earlier. The user has no way to tell.

This made bisecting impossible until I noticed the pattern: when
the same `each [body]` shape appears in multiple fns, the error
position seems to be reported against the *last definition* of that
shape, not the *runtime* call site.

**Recommendation:** carry the call-site frame separately from the
body-source frame in `AqlError`, and prefer the call-site frame for
the headline arrow. Body-source can go in a `caused by:` footer.

**Status after `333c420`:** **fixed.** Four commits land this:
`16d58ed Stamp source positions on parsed values so errors point
at the real token`, `6a44d3a Thread source positions into
forward-arg and return-check errors`, `e3884ba Stamp anonymous fn
values with their construction position`, and `3c77be6 Remove the
findWordInSource fallback; state unknown positions explicitly`.

Sanity check — feeding a String into an Integer-typed fn now
points at the call site, not a similar-shape body elsewhere:

```
$ aql do 'def f fn [[a:Integer b:Integer] [Integer] [a add b]]   "hi" f end print'
error: [aql/signature_error]: no matching signature for f
  --> 1:61
  1 | def f fn [[a:Integer b:Integer] [Integer] [a add b]]   "hi" f end print
                                                                  ^ no matching signature for f
```

The arrow lands on the `f` that actually ran, not on the `f` in the
definition. Same for forward-arg type errors and return checks.

---

## 4. Type system

### 4.1 `Options` as a parameter type breaks dispatch [fixed]

`refine` and `make` both happily build Options-typed maps. But
declaring `[opts:Options]` as a fn parameter causes the fn to be
silently treated as a literal `word`, not a callable:

```
$ aql do 'def f fn [[opts:Options] [Integer] [42]]   def P {make: f}   {x: 1} P.make print'
error: [aql/signature_error]: no matching signature for f
  --> 1:5
  1 | def f fn [[opts:Options] [Integer] [42]]   def P {make: f}   {x: 1} P.make print
          ^^ no matching signature for f
```

Change `Options` to `Map`:

```
$ aql do 'def f fn [[opts:Map] [Integer] [42]]   def P {make: f}   {x: 1} P.make print'
42
```

`aql:test`'s own definitions use `Options` parameter types without
trouble, so this must be a regression in user-fn `Options`
declarations specifically. Worth a `lang/go/test` case.

**Status after `f7247dd`:** **open.** Reproduced on the current
build: `def f fn [[opts:Options] [Integer] [42]]` followed by any
call site through a namespace map fails with `no matching
signature for f`. The library's `make-bloom` is declared as
`[opts:Map]` for this reason, even though the call site semantics
are exactly Options.

**Status after `5b983b6` (fourth pass):** **fixed.** Commit
`2d7d4a2`'s message: *"A concrete map matches an `opts:Options`
parameter (Options is structurally a keyword-args map), so
make-style fns can declare `Options` instead of being forced to
`Map`. A bare-type-literal map and non-map values are still
rejected."* Verified:

```
$ aql do 'def f fn [[opts:Options] [Integer] [opts "x" get]]   {x: 42} f end print'
42
```

The library's `make-bloom` is now declared `[opts:Options]` — the
natural signature for a constructor with named keyword parameters.

### 4.2 Custom subtypes as fn parameter/return types break dispatch [fixed]

```
$ aql do 'def Foo refine Object {x:0}   def f-inst (make Foo {x:5})   def g fn [[f:Foo] [Integer] [99]]   f-inst g print'
g
Object/Foo{x:5}
```

The output shows that `g` failed dispatch — it printed the literal
word `g` and the `f-inst` value instead of returning `99`. Changing
the input type to `Object` (the parent) fixes it:

```
$ aql do 'def Foo refine Object {x:0}   def f-inst (make Foo {x:5})   def g fn [[f:Object] [Integer] [99]]   f-inst g print'
99
```

Same problem on the return side:

```
$ aql do 'def Foo refine Object {x:0}   def f fn [[m:Map] [Foo] [make Foo {x:5}]]   {} f print'
error: f: expected 1 return value(s), got 2
```

Declaring `[Object]` (or `[Any]`) as the return type works.

The practical effect: BloomFilter, Bits, and every other custom
subtype I defined had to be annotated as plain `Object`/`Any` in
every signature. The custom-subtype nominal annotation is purely
cosmetic — it doesn't dispatch, it doesn't type-check, and it
positively breaks the fn.

**Recommendation:** treat this as a high-priority dispatch bug.
There's no fundamental reason `[f:Foo]` shouldn't accept
`make Foo {...}` instances. Add a regression test that builds an
`Object` subtype and passes its instance through both a parameter
and a return type slot.

**Status after `f7247dd`:** **fixed.** Commits `b7f921e` and
`67ddc05` land both halves: custom types accept their instances at
parameter and return slots, and the newtype/subset distinction
("bare `def Pos (refine Integer)` is nominal/distinct; predicate
`def Big (Integer gt 10)` is structural") is documented in
REFERENCE.md §"fn type semantics" and pinned in
`design/REFINE-NEWTYPE-VS-SUBSET.0.md`. The library's
`bloom-add fn [[item:Any bf:BloomFilter] [BloomFilter] …]` exercises
this on every call.

### 4.3 `aql check` produces many false positives [partial]
  (previously hard-failed; now soft-fails with cross-import noise)

Running `aql check bloom.aql` produced 262 errors in a file that
ran without error. Almost all of them were of the form:

```
check: 92:19: [error] no_signature: no matching signature for get;
  assuming best-fit candidate for analysis
check: 259:19: [error] undefined_word: undefined word: bf
```

…inside fn bodies where the parameter `bf` is clearly declared.
The "best-fit candidate for analysis" caveat suggests the checker
is doing best-effort, but the user-visible error count makes it
unusable as a gate. I never figured out which (if any) of the 262
errors corresponded to real problems.

**Recommendation:** distinguish between "definitely an error" and
"the analyser couldn't resolve types here" in the output. Run with
`--soft` semantics by default for the speculative cases, and
reserve hard errors for things that the runtime would actually
reject.

**Status after `f7247dd`:** **a different, harder failure.**
`aql check bloom.aql` now exits with a single error before any
analysis runs:

```
$ aql check smoke.aql
check error: import: module "" not found (searched .aql// from /home/user/bloom-filter to /)
```

…even though the file does not contain any empty import. The
problem appears to be in how `aql check` initialises the module
resolver for files that themselves contain `import` statements.
The same file runs cleanly via `aql smoke.aql`. `aql check --soft`
hits the same error. So today `aql check` is unusable as a CI gate
for any file that imports another (which is most real files).

This is a regression versus the original report — the previous
build's 262 false positives at least let you grep for shape — but
the architectural complaint stands: the checker should be `--soft`
by default and only flag things the runtime would actually reject.

**Status after `5b983b6` (fourth pass):** **partial.** The
hard-fail is gone (commit `2d7d4a2`'s message: *"the import path
literal is stripped to a carrier, so the import is treated as opaque
(returns a Module carrier) and analysis continues, instead of
erroring with `module "" not found`"*). The checker now runs to
completion. But the false-positive shape is back: it can't see
across the import boundary, so every reference to `Bloom.make` /
`Bloom.add` / `Bloom.contains` etc. flags `undefined word: Bloom`
plus a `no matching signature for get`. Concretely:

```
$ aql check smoke.aql
check: 8:28: [error] undefined_word: undefined word: Bloom
check: 8:33: [error] no_signature: no matching signature for get; assuming best-fit candidate for analysis
check: 10:24: [error] undefined_word: undefined word: Bloom
check: 10:29: [error] no_signature: no matching signature for get; assuming best-fit candidate for analysis
…
```

Two errors per `Bloom.foo` call site, so a typical demo or test
file produces 12–20 errors that are all the same thing. The same
applies to kernel words like `iota` / `bxor` inside `bloom.aql`
itself. CI gating still isn't practical until either: the checker
can see exports from a relative-path import, or there's a flag to
suppress the "didn't analyse, assumed best-fit" category.

### 4.4 Field name and method name share a namespace [n/a]

The HOWTO Counter example has a field `count` and a method
`value: [count get]`. In a bloom filter, the natural API has a
method called `count` (cardinality estimate) and a field that
tracks the exact insertion count. The natural rename is "field is
`added`, method is `count`" — but even then, putting both inside
a `refine Object {…}` body would conflict, and the documented
dispatch (`bf count`) wouldn't work anyway.

**Recommendation:** since inline methods don't dispatch in this
build, this is a non-issue today. If/when they do, the spec needs
to address the field-vs-method namespace question.

---

## 5. Stack and call-order surprises

### 5.1 First-param is top-of-stack (already covered §2.1) [fixed]

Restating because it deserves a separate slot: with sig
`[a:Integer b:Integer]`, the call `3 4 f` binds `a=4, b=3`. Most
non-stack-language programmers will write code assuming the
opposite for at least a day.

### 5.2 `set` arg order is *not* `obj key value` [partial]

The `set` signature is `(Integer Any Array)` / `(String Any Object)`
— *key on top, then value, then object*. So mutating a field:

```aql
obj 5 "count" set   # NOT obj "count" 5 set
```

The TUTORIAL doesn't model this; the only example is `set b/q 6 3`
which is opaque without context. The `help set` output's example
list (`set 'a' 2 2`, `2 set 'b' 3`, `2 4 set 2`, `3 5 a/q set`,
`set b/q 6 3`) is auto-generated nonsense — none of the five lines
illustrate the prevailing call pattern in real code.

**Recommendation:** hand-author examples for the words that are
likely to be called by users: `get`, `set`, `make`, `refine`,
`fold`, `each`, `import`, `export`. The auto-generated examples
read as gibberish because they substitute placeholder strings into
positions that need real types.

**Status after `f7247dd`:** **partial.** HOWTO §"Define an object
type with methods" now explicitly calls out the arg order:
`c 1 "count" set                       # c.count := 1` with the
note "see [Tutorial §3](TUTORIAL.md#the-argument-order-rule) for
why". This is the right teaching context for the average user.
`aql help set`'s example list is still auto-generated nonsense
though — open.

### 5.3 `def name value` doesn't evaluate `value` [fixed]

`def x 5` binds `x` to the integer 5. But `def x foo` binds `x` to
the literal *word* `foo`, not to whatever `foo` evaluates to. This
catches you on the very first attempt to define a constructed
instance:

```
def c make Counter            # c becomes the word `make`
def c (make Counter {})       # c becomes the Counter instance
```

Same gotcha for `def k (i bit-key)` etc. — parens everywhere.

**Recommendation:** when `def name word-followed-by-more-words` is
parsed, recognise that the user almost certainly meant
`(words...)`. A type-checker hint like "did you mean
`def name (…)`?" would catch this every time. Currently the only
clue is that later references to `c` fail with
`undefined word: c`.

**Status after `f7247dd`:** **partial.** HOWTO and TUTORIAL now
consistently show `def c (make Counter {})` with explicit parens
in the canonical OO example. The runtime behaviour is unchanged
(parens are still required), but the doc trains the right reflex.
The error message itself still just reports `undefined word: c`
without hinting at the cause.

**Status after `5b983b6`:** **fixed.** Commit `2d7d4a2`:
*"`def name foo` with foo undefined now hints. The error suggests
`def … (foo)` to bind the value or `def … foo/q` to bind the
name, instead of a bare `undefined word: foo`. Only fires in a
def-body context."* The runtime behaviour is unchanged (parens
still required), but the error message now teaches the fix the
moment the user hits it.

### 5.4 `var [[i] body]` is the idiomatic stack pop, but never shown [fixed]

`def name swap` looks like it should pop the top of stack into
`name`, but it doesn't (it binds name to the word `swap`). The
correct form is:

```
var [[i] body-that-uses-i]
```

This is in HOWTO §"Use scoped variables", but you have to be
hunting for it. Every `each [body]` that needs the iteration
variable inside a typed call needs `var`, and that pattern should
be the *first* example under "Iterate with `for`".

**Status after `f7247dd`:** **fixed.** HOWTO §"Use scoped
variables" now opens with `"aql:math" import end   3 4 var [[a b]
(a mul a) add (b mul b) math.sqrt] => 5.0` and explicitly says
"Bare-word declarations pop from the stack. `a` gets the topmost
value (4) and `b` gets the next (3), matching the argument-order
rule." The library's `bloom-merge` uses `var [[i] body]` for the
loop index.

---

## 6. Forward precedence: the dominant source of bugs

Forward precedence — words look ahead for arguments — is documented
in EXPLANATION.md and the Reference, but its real impact on
practical code is understated.

### 6.1 Every user fn collects the next word [partial]

```
$ aql do 'def f fn [[bf:Any] [Integer] [42]]   def Foo refine Object {}   def fi (make Foo {})   fi f print'
f
Object/Foo{}
```

What happened: `f` looked ahead, saw `print`, and tried to bind it
as a positional argument. The result is a silent dispatch failure
that leaves the operand printed as raw text. Fix:

```
$ aql do '… fi f end print'
42
```

This pattern repeats everywhere. `bf bloom-params print`, `bf
bloom-contains print`, `cnt bloom-count print` — every single one
needs `end` between the user word and the next word.

It's plausible that the team has internalised this and the missing
`end`s read as obvious to a regular user. From cold, it took me
roughly an hour to spot the pattern; the error messages don't
mention `end` as a hint.

**Recommendations:**
- When a fn dispatch fails because its forward-collected arg is a
  word value (not a value of an expected type), the error should
  read: *"… got `word(print)` as argument 1; did you mean to
  separate the calls with `end`?"*
- Consider making `end` the default behaviour for user-defined fns
  (i.e. user fns are stack-precedence unless they declare otherwise).
  Forward precedence is a power feature for built-ins like
  `if`/`each`/`fold` that genuinely want to gather code blocks; for
  ordinary user fns it's a footgun.

**Status after `f7247dd`:** **open.** The library still requires
`end` after every `Bloom.add` / `Bloom.contains` / `Bloom.count` /
`Bloom.merge` call site:

```aql
bf "hello" Bloom.add end
…
def hits ((bf item indices-for) each [bits swap bit-test end])
```

The error message when `end` is missing is still a signature
mismatch on a subsequent token (`no matching signature for swap` /
`for sub` / `for f`) that says nothing about forward collection.
This is the single most expensive ongoing pain point for new code.

**Status after `5b983b6` (fourth pass):** **partial — error now
suggests the fix, though `end` is still needed.** Commit `2d7d4a2`:
*"the forward-precedence 'no matching signature' error now hints
at the fix. When a fn that takes args hits its 0-arg fallback
(forward collection ran into the next word, e.g. `inc inc 5`), the
error suggests grouping with parens or terminating with `end`/`;`."*

Live verification:

```
$ aql do 'def f fn [[a:Integer] [Integer] [a add 1]]   "foo" f end print'
error: [aql/signature_error]: no matching signature for f
  --> 1:52
  1 | def f fn [[a:Integer] [Integer] [a add 1]]   "foo" f end print
                                                         ^ no matching signature for f
  = forward args for f may have run into the next word; group the call
    with parens — (f …) — or end it with `end` or `;`
```

The error names the offending word, suggests parens / `end` / `;`,
and even renders the stack with the cursor on the unconsumed word
(`>>>word(set)<<<`) — the same hint surfaced repeatedly while
building the property suite. The line `= forward args for f may
have run into the next word…` is exactly what was missing in the
prior reports. The footgun is still present (you still have to
write `end` everywhere), but now the first time you forget it you
immediately know what's wrong — the single biggest reduction in
time-to-diagnosis since the report started.

A full fix — make ordinary user fns stack-precedence by default,
keep forward precedence only for the words that genuinely want it
(`if`/`each`/`fold`/`import`) — would close the remaining gap.

### 6.2 `if` branch order is documented but the runtime takes the wrong branch [open]

```
$ aql do 'true if [99] [88] end print'
88
```

`true` should pick the first branch (`[99]`), giving 99. We got 88.
The "stack" form works correctly:

```
$ aql do 'true [99] [88] if end print'
99
```

This is a genuine bug. The HOWTO examples use `cond if [then]
[else]`, and `aql help if` shows that form (`if 2 3 4 => 3`) as
valid. Whatever resolution layer is choosing the false-branch in
the forward-call form needs to be checked against the postfix form.

Quoting `aql help if`:

```
Signatures: (in match order)
  [ [Any Any Any]  Any ]
  [ [Any Any]      Any ]
  [ [List]         Any ]
```

The fact that `[Any Any Any]` matches first means the first arg
seen by dispatch is *top* of stack. With forward precedence on `if`
collecting `[99]` then `[88]`, the cond comes from the stack last:
stack at dispatch is `[true, [99], [88]]` with `[88]` on top.
Signature [cond, then, else] then makes cond = top = [88] (which
is truthy, but evaluates to 88). That's logically consistent —
but it directly contradicts the HOWTO and `aql help if` examples
that show `cond if [then] [else]` returning `then`.

**Recommendation:** either rewrite the `if` dispatch so the
forward-collected branches are in cond-then-else order, or fix the
docs and help examples to show only the working `cond then else if
end` form. Anything in between is a trap for every new user.

**Status after `f7247dd`:** **open**, with a sharper diagnosis.
Two forms are now known to work; two are still broken:

```
aql do 'if true [99] [88] end print'        # full forward
99
aql do 'if false [99] [88] end print'       # full forward
88
aql do '[88] [99] true if end print'        # full postfix (else then cond if)
99
aql do '[88] [99] false if end print'       # full postfix
88
aql do 'true if [99] [88] end print'        # mixed (cond forward, branches forward)
88                                          # ← wrong: returns else for true
aql do 'true [99] [88] if end print'        # mixed (cond stack, branches forward)
88                                          # ← also wrong
```

So the safe rules are: write `if cond [then] [else]` (everything
forward of `if`) **or** `[else] [then] cond if` (everything on the
stack). Anything that splits forward and stack between `if` and
its args returns the wrong branch.

The library uses the full-forward form throughout. `bloom-count`'s
header comment now points users at this paragraph; future me will
thank past me.

Reproducer for the bug ticket:

```aql
def expected if true [99] [88] end       # ← legal-looking, returns 88
def via-full if true [99] [88]           # ← works, 99
```

**Status after `5b983b6` (fourth pass):** **open, unchanged.**
Re-tested on the binary (note the `end` terminator — without it the
trailing `if` forward-collects `print` and nothing dispatches, which
is the §6.1 footgun, not an `if` bug):

```
aql do 'if true  [99] [88] end print'   # full forward → 99  ✓
aql do 'if false [99] [88] end print'   # full forward → 88  ✓
aql do 'true [99] [88] if end print'    # full stack   → 99  ✓
aql do '[88] [99] true if end print'    # full stack   → 99  ✓
aql do 'true if [99] [88] end print'    # mixed        → 88  ✗ (else for true)
aql do 'false if [99] [88] end print'   # mixed        → 88  ✗ (else for false too)
```

Both the all-forward `if cond [then] [else]` and the all-stack forms
select the correct branch. Only the **mixed** shape — `if` sitting
between the condition and its branches (`cond if [then] [else]`) —
silently returns the else branch regardless of the condition. So the
safe rule is: keep `if` and its operands all on the same side. This
repo writes every `if` all-forward, including the new property suite,
whose `report` helper and generators all use `if cond [then] [else]`.
**Recommendation: either make the mixed `cond if [...] [...]` shape
error loudly (it currently runs and picks the wrong branch), or
document the supported forms explicitly — right now it is a silent
trap.**

### 6.3 Inline arithmetic body trick [n/a]

A particularly nice find: the `mul h2 add h1 mod m` body in
`indices-for` works exactly because each operator forward-grabs the
next constant:

```aql
(iota k) each [
  # stack: i
  mul h2 add h1 mod m
  # mul grabs h2 (forward), needs second arg → from stack → i.
  # add grabs h1 (forward), needs second → mul's result.
  # mod grabs m (forward), needs second → add's result.
]
```

Concise and correct, *if* you understand forward precedence.
Anyone reading it without that context will be lost. A worked
"forward arithmetic" example in the tutorial would pay back fast.

### 6.4 `import` grabs the next string [partial]

```
$ aql do '"aql:math" import   "loaded" print'
error: import: unknown native module: aql:test loaded
```

`import` looked ahead, saw `"loaded"`, and tried to import a module
named `aql:test loaded`. Need `end`:

```
$ aql do '"aql:math" import end   "loaded" print'
loaded
```

`import` is a particularly bad word for forward precedence because
the user expects it to be statement-like (one path, then done).
Special-casing it (or any other module-loading word) to default to
stack-precedence would be a friendly micro-fix.

---

## 7. Data structure quirks

### 7.1 Lists don't survive `def` [fixed]

This was the single most surprising behaviour of the whole project:

```
$ aql do 'def lst [10,20,30]   lst print   depth print'
4
30
10 20
```

`def lst [10,20,30]` does *not* bind `lst` to the value `[10,20,30]`.
Instead, every reference to `lst` re-evaluates the literal, which
in body context spreads its elements onto the stack:

```
$ aql do 'def lst [10,20,30]   typeof lst'
Integer 20 30
```

`typeof` saw `10` as its argument (returning `Integer`), and `20`
and `30` ended up on the stack as leftovers.

Workarounds:
- Inline the list at every use site:
  `def total (0 (iota 50 each [...]) [add end] fold)`
- Wrap in a Map: `def m {data: [10,20,30]}` and access via
  `m.data` (which has its own parse issues — §3.1).

The all-inline workaround is what I had to use throughout
`bloom.aql`. It made `bloom-contains` and `bloom-count` more
tangled than they should be — they have to construct, fold, and
consume the indices list in one expression.

**Recommendation:** this is by far the highest-impact data-model
issue. Either:
- Make `def name [list-literal]` bind `name` to the list *value*,
  not the code that produces it. Add an explicit `def-block name
  [...]` for the current behaviour if anyone depends on it.
- At minimum, surface a warning when `def` is used with a list
  literal: "bound `name` to the code `[a, b, c]`; this re-evaluates
  on each access. Use `def name ([a, b, c])` to bind the list
  value." (Whether the parenthesised form even works as that I
  haven't verified — but the error message should be clear about
  the trade-off.)

**Status after `f7247dd`:** **fixed.** The recommended option
landed (commits `65cb341` and `c567af4`). From the spec file
`lang/spec/def-node-binding.tsv`:

```
def x [1,2,3] x	[1 2 3]	a LIST binds the list value (was: spliced)
def x [1,2,3] size x	3	the value is a real List — size works
def x [1,2,3] x each [add 10]	[11 12 13]	…and higher-order words work
def x word [1,2,3] x	1 2 3	`word` splices the elements (the old default)
```

So:
- `def x [1,2,3]` now binds the list value, exactly like maps. The
  library's `def hits (iota 50 each [...])` works as written;
  earlier we had to inline the entire `iota...each` form into
  every consumer to avoid the splice.
- The old splice semantics are preserved as opt-in via `def x word
  [1,2,3]` — `word` is the new splice marker.

This was the highest-impact data-model fix in the dx-report list.

### 7.2 Maps are immutable; only Object can be mutated [open]

`set`'s signature list:

```
set (String Any Store) or (String Any Object) or
    (Integer Any Array) or (Atom Any Store) or
    (Atom Any Object)
```

There's no `(String, Any, Map)`. The implication: a map literal
`{a: 1, b: 2}` is functionally immutable in user code. To get
mutable storage you must use `refine Object` and `make`. This is
fine — but the connection isn't drawn in the docs, and it took me
two probing sessions to learn that the Bits storage in my filter
needed to be a `refine Object`, not a Map.

`Array` is in the `set` list but not constructable from user code:

```
$ aql do 'make Array [10,20,30]'
error: make: unsupported target type Array
$ aql do 'def Bits refine Array Integer   make Bits [1,2,3]'
error: make: unsupported target type Bits
```

So `Array` is for native modules only. Without a constructable
mutable array, every user-defined sequence is either an immutable
List or a Map-keyed-by-Integer-as-String workaround.

For a bloom filter that's fine — sparse bit storage as
`{stringIndex: 1}` works. For a packed bit array (which is what
you'd want at higher fill ratios), there's no path.

**Recommendation:** expose a mutable sequence type to user code,
even if it's just `def Bits refine Object` with integer-stringified
keys. Or document the array-via-stringified-index pattern clearly
as the canonical way.

### 7.4 `each [body]` requires the body to push a value [partial — new in `f7247dd`]

When `each` is used for its side effects (e.g. setting bits in a
bloom filter, mutating per-element state), there's no way to say
"don't collect into a list". Every body must produce a value:

```aql
def _ ((bf item indices-for) each [
  bits swap bit-mark end
  0                              # only here so the body produces
])
```

Without the trailing `0`, `each` errors with `body produced no
result`. The accumulator `def _ (...)` discards the resulting
`List<0, 0, 0, …>`.

This becomes more invasive in mutating-with-condition loops; the
`bloom-merge` body has to push 0 from both branches:

```aql
def _ (iota am each [
  var [[i]
    def is-set (b-bits i bit-test end 1 eq)
    if is-set [
      a-bits i bit-mark end
      0                        # then-branch sentinel
    ] [
      0                        # else-branch sentinel
    ]
  ]
])
```

Cleaner alternatives that would close this:
- A `for [start, stop] [body]` form where the body's stack output
  is discarded (HOWTO's `for 5 [42]` does *push* `42 42 42 42 42`,
  so users do reach for the no-pollute form).
- An `each-do [body]` variant whose result is `None`.
- An `Any?` (zero-or-one) return convention on `each` bodies, so
  empty bodies don't error.

The current "always push a sentinel" workaround is functional but
adds noise to every mutating loop.

**Status after `333c420`:** **partial.** `for N [body]` is the
clean answer for purely-counted loops where the body's output is
collected on the stack:

```
$ aql do 'for 5 [42] print'
42
42
42
42
42
```

That works for `bloom-add`'s inner loop *if* you can phrase the
body without needing the iteration index — `for` doesn't pass it.
The library still uses `iota N each [...]` plus a sentinel `0` in
the merge body because the index is needed:

```aql
def _ (iota am each [
  var [[i]
    def is-set (b-bits i bit-test end 1 eq)
    if is-set [
      a-bits i bit-mark end
      0                              # sentinel
    ] [
      0                              # sentinel
    ]
  ]
])
```

So this is still open for "index-using void loops". An indexed
`for [start, stop] [body]` (matching `iota`'s shape, but discarding
the body's stack output) would close it.

### 7.3 Object field defaults don't construct nested Objects [partial]

```
$ aql do 'def Bits refine Object {}   def Foo refine Object {bits: Bits}   def inst (make Foo {})   inst.bits 1 "0" set'
error: [aql/signature_error]: no matching signature for set
  = stack: F >>>word(get)<<< word(data) word(print)
```

`bits: Bits` in the field declaration is a *type* annotation, not
an initialiser. To get a nested instance, the caller of `make` must
provide it:

```
$ aql do 'def Bits refine Object {}   def Foo refine Object {bits: Bits}   def inst (make Foo {bits: (make Bits {})})   inst.bits 1 "0" set   inst.bits print'
Object/Bits{0:1}
```

Surprises:
- Field declarations of the form `name: TypeLiteral` mean
  "this field has type *TypeLiteral*" with no default value, even
  though field declarations of the form `name: 0` mean
  "this field has the same type as 0 (Integer) and defaults to 0".
  So `name: 0` and `name: Bits` parse the same syntactically but
  mean very different things semantically.
- There's no syntax I could find for "this field has type Bits and
  defaults to (make Bits {})".

**Recommendation:** spell this out in the HOWTO §"Define an object
type with methods". The current section has zero text on
type-annotation-versus-default-value, and zero text on what to do
about nested object fields.

---

## 8. Module system

### 8.1 Sub-imports cannot resolve native modules — the show-stopper [fixed]

The plan called for a layered structure: `bloom.aql` defines and
exports the API, `smoke.aql` imports it and demos. That broke
immediately:

```
$ cat probe2.aql
"aql:math" import
"./probe.aql" import
"done" print

$ cat probe.aql
"aql:math" import
5 math.log print

$ aql probe2.aql
error: import: ./probe.aql: [aql/undefined_word]: undefined word: math
```

The top-level script can import `aql:math`, but any file it imports
*cannot*. Likewise for `import module [body]` inline modules — the
inline body runs in a fresh registry that doesn't include the
parent's native modules.

This is the single biggest architectural problem for libraries.
Every bloom-filter-class library will want `log`/`ceil`/`round`,
and there's no way to package that as an importable module today.

The only ways out for users today:
1. Concatenate the library into the calling file (what I did).
2. Have the caller pre-compute `m`, `k` and pass them via Options,
   shifting the math burden to the user (uglier API).
3. Reimplement `log` in pure AQL (Taylor series for `ln(1+r)` plus
   range reduction via `2^n` — feasible but a chunk of code that
   every numeric library would duplicate).

**Recommendation:** sub-imports should inherit the parent's native
module registry, or at minimum provide a way to declare native-
module dependencies in `aql.jsonic` that get resolved at import
time. The current isolation looks like a security/correctness
boundary, but in practice it just makes module reuse impossible.

**Status after `f7247dd`:** **fixed.** This was the single biggest
architectural blocker in the original report; commits `489a1d9
fix: propagate native-module Resolver into file-imported modules`
and `d6d8679 fix: implement InheritConfig + InstallResolver so
native sub-imports build` resolve it. Live test against the
current build:

```aql
# /tmp/lib.aql
"aql:math" import end
def lib-log fn [[x:Decimal] [Decimal] [x math.log]]
export "lib" {log: lib-log/r}

# /tmp/use.aql
"/tmp/lib.aql" import end
5.0 lib.log end print

$ aql /tmp/use.aql
1.6094379124341003
```

The whole point of having a module system was that libraries could
package up their own dependencies without forcing the caller to
import them. That works now. The library this repo ships uses it
directly — `bloom.aql` imports `aql:math` itself, and `smoke.aql`
just does `"./bloom.aql" import end` without knowing about math.

### 8.2 `import 'module [body]` syntax surprise [fixed]

Searching for "inline module" in the design docs eventually turned
up the form:

```
import module [
  def x 5
  export "M" {x: x}
]
M.x print
```

This works — but it's not in any user-facing doc I could find. The
HOWTO §"Use modules and imports" shows `import utils [...]` which
fails:

```
$ aql do 'import utils [def x 5]   utils.x print'
error: import: unknown inline form "utils" (expected 'module')
```

So the HOWTO example is wrong; the only inline name accepted is
the literal word `module`, and renaming happens via a separate
parameter (`import "M" 'module [body]` or similar — I never got
that variant to work in practice).

**Recommendation:** sync the HOWTO with what the binary actually
accepts, and add a CLI-reachable example.

**Status after `f7247dd`:** **fixed.** HOWTO §"Use modules and
imports" now shows the working form:

```
import module [
  def base 10
  def greet fn [[name:String] [String] [`hello ${name}`]]
  export "utils" {base: base, greet: greet/r}
]
"Ada" utils.greet                     => 'hello Ada'
```

…including the all-important note that function values export with
`/r` while plain values export bare. The library's `export`
follows this pattern.

### 8.3 `export` only works during an import [open]

When running a file directly (`aql bloom.aql`), `export` is
undefined:

```
$ aql bloom.aql
error: [aql/undefined_word]: undefined word: export
```

The same file run via `"./bloom.aql" import` from a parent script
would have `export` available. This split mode is confusing: the
"main" file of a module is sometimes the entrypoint of execution
and sometimes a module loaded by something else, and the available
word set changes between the two.

Combined with §8.1, the practical effect is: there's no way to
have a single file that (a) runs directly with `aql foo.aql`,
(b) exports a namespace for callers, and (c) uses `aql:math`. I
had to drop `export` from `bloom.aql` and pseudo-namespace via
flat top-level `bloom-*` words.

**Recommendation:** make `export` a no-op when not in import
context, so library authors can keep one shape that works in both
modes.

---

## 9. Other surprises and rough edges

### 9.1 `printstr` leaves its argument on the stack [open]

```
$ aql do '"hi" printstr "bye" printstr depth print'
bye2hi
```

`depth` was 2 at the end, meaning both strings were still on the
stack after `printstr` had printed them. The smoke demo in
`bloom.aql` originally used `printstr` for the labels:

```aql
"params:    " printstr bf bloom-params print
```

— and the leftover `"params:    "` polluted the stack into
`bloom-params`. Replacing with `print` (which adds a newline and
properly consumes) fixed it, but the failure mode is weird because
stdout *does* get the right text — only the stack is wrong.

Either `printstr` should consume like `print`, or its help should
say "leaves the value on the stack".

**Status after `5b983b6` (fourth pass):** **still open.** Re-tested:

```
$ aql do '"hello" printstr  "AFTER" print'
AFTERhello
```

`AFTER` (from `print`, with its newline) lands before `hello`,
which is only possible if `printstr` left `"hello"` on the stack
and it was dumped at program exit rather than written inline. So
`printstr` still does not consume its argument. Unchanged from the
original finding.

### 9.2 `convert String i` order isn't what you'd guess [n/a]

```
$ aql do 'convert String 42 print'
42
$ aql do '42 convert String print'
42
```

Both work. `convert` accepts forward, infix, or stack-only invocation
because of its sig signatures. But inside a body, the safe form is
the prefix `(convert String i)` — using `(i convert String)` for
naming clarity occasionally fails to dispatch:

```
$ aql do 'def i 42   (i convert String) print'
42
$ aql do 'def i 42   def s (i convert String)   s print'
42
```

…actually both work here. I had at least one site where the infix
form silently failed; couldn't reproduce minimally. Worth noting
that the multiple-arg-order dispatch is convenient but the failure
modes are unpredictable when the surrounding context is rich.

### 9.3 Output reordering between `print` and `printstr` [open]

I never got a deterministic output order with mixed `print` and
`printstr`:

```
$ cat /tmp/probe.aql
"hi" printstr
99 print

$ aql /tmp/probe.aql
99hi
```

The `99\n` appeared before `hi`. Possibly stdout buffering on
panic, or the way stack residue prints at program end. Not a
blocker, but it makes "where does this output come from" hard to
read in test output.

**Status after `5b983b6` (fourth pass):** **open, and broader than
"mixed `print`/`printstr`".** Pure `print` reorders too — the
program's *first* printed line is consistently emitted **last**:

```
$ aql do '"A" print "B" print "C" print "D" print'
B
C
D
A
```

`B C D` are in order; `A`, the first, is rotated to the end. The
same thing makes `smoke.aql`'s banner and the docs' first label come
out last. Two reliable workarounds, both used in this repo's
`docs/tutorial.md`:

1. Emit one throwaway line first — `"" print` — so the *blank* line
   takes the rotated-to-end slot and every real line stays ordered.
2. Build the whole output as a single `\n`-joined interpolated
   string and `print` it once.

This looks like an off-by-one in the output flush/queue rather than
a buffering race, since it is deterministic. Worth a `lang/go/test`
that asserts N prints emit in source order.

### 9.4 `length` only works on Lists; strings need `size` [fixed]

```
$ aql do '"hello" length'
error: [aql/signature_error]: no matching signature for length
  = expected: length (List)

$ aql do '"hello" size'
5
```

Reasonable enough, except `aql help length` says
"length — <not described>" with no notes and no example showing
what it accepts. The signature in the help (`[List]`) is the only
clue. Users will hit "what's the length of this string" five
minutes in; that should be a discoverable answer.

**Status after `f7247dd`:** **fixed.** Commit `45d3091
Remove the length word; document size fully` deleted `length`
entirely and rewrote REFERENCE.md §"Size":

> `size` reports the **natural size** of *any* value as an
> `Integer`. Unlike the collection words above — which accept only
> a concrete list — `size` has signature `[Any]` and is a
> **total** function: every value has a size and `size` never
> errors.

…with a table covering Lists/Maps/Strings/Atoms/Numbers/Bools/
Paths/Objects/None. `"hello" length` now gives
`undefined word: length`, which is the correct migration error.

### 9.5 Help examples are auto-generated and unhelpful [open]

```
$ aql help slice
slice — <not described>
…
Examples:
  slice 2 3 ['a','b']   ;# ...
  'a' slice 4 5         ;# ...
```

The examples are positional permutations of placeholder values,
not actual idiomatic usage. They tell you nothing about what
`slice` does or how to call it. `aql help` is the primary doc
surface for the language, so help quality is critical; this needs
hand-authored examples.

### 9.6 `aql check` output dwarfs the actual error count [different shape, still open]

```
$ aql check bloom.aql
… 262 lines of "no_signature" / "undefined_word" / "best-fit candidate" …
check: 262 error(s), 5 warning(s), 0 info
check failed: 262 error(s)
```

The same file runs without runtime error. The checker's verbosity
makes it useless as a CI gate. Either the speculative analysis
should be quieter, or there should be a `--strict` flag that opts
into the noisy mode.

### 9.7 Subtype instances printed with `Object/Foo{...}` [open]

The print form is `Object/BloomFilter{added:0,bits:Object/Bits{},k:7,m:9586,n:1000,p:0.01}`.
The `Object/` prefix is informative but the field order is
alphabetical, not declaration order, which makes diffs against
`bloom-params` output (which is also alphabetical) confusing —
the two look the same shape but the encode payload has different
keys.

Stable, declaration-order output would help.

### 9.8 No native hash function [open]

There's `band`/`bor`/`bxor`/`bsl`/etc. but no `hash`/`fnv`/`murmur`/
`sha256` available even after `"aql:math" import`. Writing FNV-1a
in pure AQL is feasible but slow (`O(n)` per char via `indexof` on
a printable-ASCII alphabet string), and only handles printable
ASCII. The bloom-filter library can't ship in any serious form
without a real hash; ours would handle binary or non-ASCII data
poorly.

**Recommendation:** add `hash` to `aql:bin` or expose `xxhash`/
`fnv` as a top-level word. Every probabilistic data structure, key-
value cache, or content-addressed scheme will need this.

### 9.9 No char-to-int conversion [open]

```
$ aql do 'convert Integer "h"'
error: convert: cannot convert "h" to number
```

To get the codepoint of a character, the only path I found was the
printable-ASCII alphabet trick: `alphabet c indexof 32 add`. This
is brittle (non-ASCII silently maps to wrong codes) and slow
(`O(95)` per char). Built-in `ord`/`chr` words on `Scalar` would
help.

### 9.10 No way to raise a custom error [open — new at `5b983b6`]

In earlier builds the library raised precondition failures with the
string-and-`error` form `"bloom.merge: m mismatch" error`. At
`5b983b6` that no longer works: `error` has been **redefined as an
error-handling combinator**, not a raise.

```
$ aql describe error
error — Precedence: forward
  Signatures: [ [List Error]  Any ]
```

Its documented use is `do [risky] error [handler]` — run a body,
and if it produced an error value, run the handler with that error
on the stack (HOWTO §"Handle errors", REFERENCE line 530). So
`"msg" error` now fails its own signature check (`no matching
signature for error`), which is what a mismatched `Bloom.merge`
started throwing — a confusing error *about `error`* rather than the
intended message.

The gap: there is **no replacement word that raises a custom
message**. None of `raise` / `throw` / `fail` / `panic` exist in the
native set, and an Error value can't be constructed either
(`make Error {…}` → `unsupported target type Error`,
`convert Error` → no signature). The only AQL-level ways to produce
a *catchable* failure are to trigger a built-in error (`1 0 div`,
undefined word, type mismatch) — none of which let you attach a
message.

**Workaround used in this repo.** `bloom-merge` now raises by
dispatching a descriptively-named word that is deliberately left
undefined:

```aql
if (m-ok not) [ bloom-merge-requires-equal-m ] [ … ]
```

The resulting `undefined_word: bloom-merge-requires-equal-m` is
catchable (`do […] error […]`, `assert.throws`) and its *text names
the violated precondition* — the closest thing to a custom message
available. It is a hack: the error class says "undefined word,"
which reads like an implementation bug rather than a contract
violation. The undefined word inside an untaken branch is lazy — it
does not break loading or the happy path, only fires when the branch
runs.

**Recommendation:** restore a first-class raise — e.g. `"msg" fail`
or `{name, message} raise` producing a catchable Error — and/or make
`make Error {…}` work so a fn can build and return one. Removing
string-raise without a replacement is a real regression for any
library that validates its inputs. (The decision module's
return-a-`{ok, error}`-map convention is the functional alternative,
but it changes a word's return type and isn't always appropriate.)

---

## 10. The aql:test framework breakdown

`aql:test`'s help and its design doc both describe a clean
imperative API:

```aql
"aql:test" import
[
  1 1 assert.equal
  2 2 assert.equal
] "name" test.test
test.fail-count print
```

This works for one `test.test`. Two `test.test` calls in a row
fail:

```
$ aql do '"aql:test" import end   [1 1 assert.equal end] "a" test.test end   [2 2 assert.equal end] "b" test.test end   test.fail-count print'
1
```

`fail-count` reports 1 even though both tests have only passing
assertions. With `end` markers in every position and single
assertions per test, the framework's stack-isolation behaviour
seems to leak across calls.

For my bloom tests this manifested as: after 2-3 `test.test`
invocations, the next test's `bf "k" get` would fail with the
stack showing `'derived-n'` (the *first* test's name) as the
target of the `get` instead of the filter instance.

I worked around it with an inline boolean-sum harness:

```aql
def bf-p ({n: 1000, p: 0.01} make-bloom)
def p1 ((bf-p "n" get) 1000 eq)
def p2 ((bf-p "p" get) 0.01 eq)
…
"p1: " printstr p1 print
"p2: " printstr p2 print
```

— shipping 11 tests via 11 boolean defs and 11 print lines. It
works but it's not what the framework promises.

**Recommendations:**
- A focused regression test that runs N `test.test` calls in
  sequence and asserts `test.fail-count` is the *real* fail count
  would catch this immediately.
- Until fixed, the design doc should call out the limitation.
- Long term, `test.test` should `var`-scope its body so internal
  state can't leak into the surrounding stack.

**Status after `5b983b6` (fourth pass):** the multi-`test.test`
leak is gone — `test/bloom_test.aql` runs eight `test.test` blocks
in sequence and `test.fail-count` reports 0. Beyond that, two
declarative layers are now usable and worth documenting prominently:

1. **Spec format** — `test.TestSpec` / `test.case` / `test.spec` /
   `test.run-spec` express example-based suites as data (a `name`,
   a `subject` word, and a list of `{name, in, out}` cases that the
   runner pushes and dispatches). See `lang/go/modules/decision_spec.aql`
   for the canonical shape.
2. **Property-based testing** — `test.prop name [gen] [property]`
   builds a `PropertySpec`; `test.run-property` runs it at the
   default 100 iterations, and `test.check-prop name [gen]
   [property] runs seed max-shrinks` runs it with an explicit
   iteration count. The `gen` body produces one value with a fresh
   seeded `r` (an `aql:rand` instance: `r.int`, `r.bool`, `r.float`,
   `r.string`, `r.one-of`, `r.list-of`, `r.map-from`) bound in
   scope; the `property` body takes that value and returns a
   Boolean. Failures are recorded into `test.fail-count` and the
   result carries the (shrunk) `failing-input`.

This repo exercises **both** surfaces, deliberately split across two
files so each one stays pure:

- `test/bloom_prop_spec.aql` — the **declarative spec format**:
  `PropertySpec`s built with `test.prop` and run with
  `test.run-property`, assembled as a list of spec values.
- `test/bloom_pbt.aql` — the **direct-code form**: the imperative
  `test.check-prop` driver called inline with explicit
  `runs`/`seed`/`max-shrinks`.

Two gaps surfaced while writing them, and they are exactly what
motivated the split:

- **`set` won't mutate the `PropertySpec` map**, so there is no
  ergonomic way to override `runs` on a spec built by `test.prop`
  (it fixes `runs=100`); `convert Object` and `merge`-with-`{runs:N}`
  both fail or corrupt the spec. So the declarative file is limited
  to properties that are fine at 100 runs, and the expensive ones
  that need a smaller budget live in the direct-code file, which
  takes `runs` positionally. A `test.run-property-n spec runs`
  overload (or a settable map) would let the whole suite stay on the
  spec-construct-then-run shape.
- **The interpreter makes O(m) properties expensive to repeat.** A
  full m-bit scan (merge, count, encode) at 100 iterations over a
  realistically-sized filter (m≈9586) does not complete in a
  reasonable time, which is why the direct-code file runs those at
  ~10 iterations on a smaller filter. Not a correctness issue, but it
  caps how hard property tests can lean on the slow paths.

---

## 11b. Property-based testing with `aql:test` [new]

The fourth pass added a property-based test file
(`test/bloom_pbt.aql`) using `test.check-prop`. Worth flagging the
mechanics and the friction that came up writing it.

### API recap

```
test.check-prop NAME [GEN-BODY] [PROP-BODY] RUNS SEED MAX-SHRINKS end
```

The generator runs in a sub-engine with `r` bound to a random
source; it must leave exactly one value on the stack. The property
runs with that value on the stack; it must return a Boolean.

Generators from `aql:rand` (auto-registered as `r.*`):
`r.int LO HI`, `r.bool`, `r.float`, `r.string CHARSET LEN`,
`r.one-of LIST`, `r.list-of [GEN] N`, `r.map-from {k:[GEN], …}`.

### What the seven properties cover

| Property | Asserts |
|---|---|
| `no-false-negatives` | For any random key, `add` then `contains` returns `true`. The hard guarantee of any bloom filter. |
| `added-equals-insert-count` | After `N` inserts of distinct items, `bf.added == N`. |
| `bulk-no-false-negatives` | After `N` distinct inserts, every one is `contains`-true. |
| `derived-m-formula` | The constructor's `m` matches `ceil(-n·ln p / (ln 2)²)` recomputed independently from the same `n` and `p`. |
| `derived-k-formula` | The constructor's `k` matches `round((m/n)·ln 2)`. |
| `merge-preserves-membership` | `(a a-key add) (b b-key add) merge` contains both inputs' keys. |
| `encode-contains-params` | The encoded payload string contains the params (`n:…`, `p:…`, `added:…`). |

All seven pass on `5b983b6`. Total runtime ~11 s for 65 randomised
trials across the seven properties.

### Friction encountered (specific to writing PBT)

These are new gotchas surfaced by the property-test work, not by
the library itself. Most aren't in the existing dx sections.

1. **Sub-engine-isolation of native modules.** Property bodies run
   in a fresh sub-engine where any `"aql:math" import end` declared
   inside the body fails with `undefined word: math`. Even with the
   parent script having math imported, the property body can't
   re-import it. Workaround: import `aql:math` at the very top of
   the test file so the sub-engine inherits it. The error message
   pointed at the `math` token inside the body, which is the right
   diagnosis once you know it.

2. **Single-character variable names collide silently.** I named a
   variable `p` (for "payload") in a property body. Every subsequent
   reference to `p` interleaved with surrounding tokens in ways
   that were hard to read; the eventual symptom was the property
   returning false in the framework but true when copy-pasted to
   the REPL. Renaming to `payload` fixed it. Cause: `p` clashed
   with parser handling of `(p indexof …)` patterns. Worth a hint
   in the docs to prefer multi-character names.

3. **Generators that need a *pair* require a wrapper.** The natural
   reading is `[r.string charset 6  r.string charset 6  [pair]]`
   — generate two strings, pack them into a list called `pair`.
   The body must produce *one* value. The working idiom is
   `r.list-of [r.string charset 6] 2`. The HOWTO doesn't cover
   PBT, so this took a re-read of `test_pbt_test.go` to find.

4. **`Bloom.merge` is O(m) per call.** With a single random key in
   each side and `n=1000` (`m=9586`), each merge call walks all
   9586 bit positions. Ten trials at `n=1000` took >2 minutes;
   dropping to `n=100` brought it under a second. Not an AQL bug
   — a library bug — but a real concern for PBT generally: the
   per-trial cost compounds.

5. **The result table is verbose by default.** `test.results` is
   the full PropertyResult list, which renders as a 9-column
   table per property. For a small report file the property
   names alone (with pass/fail) read better; the test file pulls
   `name` and `ok` out of each row and prints `pass: NAME` /
   `FAIL: NAME  failing-input=…` manually.

6. **No way to skip / focus a single property.** All
   `test.check-prop` invocations in a file run. There's no
   `test.skip` or `test.only` analogue. For tight iteration you
   end up commenting out properties.

### Recommendations for `aql:test` PBT

- **Document `r.list-of [GEN] N` and `r.map-from` in the HOWTO** —
  generating compound test inputs is the first thing past `r.int`
  that anyone needs.
- **Inherit native modules into property sub-engines** (or
  document the constraint and the top-of-file workaround).
- **Add `test.only "name" …` / `test.skip "name" …`** for
  iterative work.
- **A short HOWTO §"Write property tests" page** would close the
  gap. Right now `design/PBT-PLAN.0.md` describes the API but
  there's no user-facing tutorial.

---

## 11a. New since `f7247dd`: array module and friends [new]

Three additions in `333c420` are worth flagging because they
materially change the idiomatic shape of list-heavy AQL code.

### Status after `5b983b6` — still open

The commit message for `2d7d4a2` says §6.2 *"does NOT reproduce on
the current tree"*. Re-tested on `5b983b6`; the issue absolutely
does reproduce, just in the *mixed/infix* form:

```
$ aql do 'true if [99] [88] end print'         # MIXED — still wrong
88
$ aql do 'false if [99] [88] end print'        # MIXED — also wrong
88
$ aql do 'if true [99] [88] end print'         # full-forward — correct
99
$ aql do 'if false [99] [88] end print'        # full-forward — correct
88
$ aql do 'true [99] [88] if end print'         # full-stack — correct
99
$ aql do 'false [99] [88] if end print'        # full-stack — correct
88
```

So full-forward (`if cond [t] [e]`) and full-stack
(`cond [t] [e] if`) both work; the mixed form
(`cond if [t] [e]`) consistently picks the same branch regardless
of `cond`. The dx-fix author may have tested the full-forward
form. The library uses the full-forward form throughout for this
reason. Worth re-opening the ticket with the mixed-form repro.

### `aql:array` module — APL-style data vocabulary

After `"aql:array" import end`, words appear under the `array.`
namespace. The library uses `array.where` directly. Worked
examples:

```
$ aql do '"aql:array" import end   [1, 0, 1, 1, 0, 1] array.where end print'
[0, 2, 3, 5]

$ aql do '"aql:array" import end   [10, 20, 30, 40] array.at [3, 0, 2] end print'
[40, 10, 30]

$ aql do '"aql:array" import end   [1, 2, 3] array.replicate [2, 1, 3] end print'
[1, 1, 2, 3, 3, 3]

$ aql do '"aql:array" import end   [1, 2, 3, 4] array.compress [1, 0, 1, 0] end print'
[1, 3]
```

Other exports: `shape`, `rank`, `reshape`, `transpose`, `grade`,
`sortby`, `expand`, `member`, `unique`, `group`, `window`, `pairs`,
`eachrank`, `foldaxis`. Per ADR-001 (in the repo root) the module
deliberately doesn't shadow core words; `flatten -1` and the
List/List overload of `indexof` were promoted to core in
`e1b0b60`.

For the bloom filter, the biggest single win is `array.where`. The
old `bloom-encode` had to walk the bit array building a list of
either `i` or a sentinel `-1`, then filter the `-1`s out. The
new form is two lines:

```aql
def hits (iota m each [bits swap bit-test end])  # [0,1,0,0,1,1,…]
def set-idxs (array.where hits end)              # [1,4,5,…]
```

That's the shape every "scan a bitmap, get the indices" loop
should have.

### `range start stop step` — `iota`'s richer cousin

```
$ aql do 'range 0 10 2 print'
[0, 2, 4, 6, 8]
```

The library doesn't currently need this — every loop is
`0..N-1` — but it's the obvious answer for any loop with non-zero
start or non-unit step. Removes the awkward
`iota N each [i mul step add start]` workaround.

### Shorthand map literal `{x}` → `{x: x}`

```
$ aql do 'def x 5   def y "hi"   {x, y} print'
{"x": 5, "y": "hi"}
```

The bloom-filter `export` map uses this for the type / Bits
entries (the function entries still need `/r` so they stay verbose,
but everything constructible with the bare name is now terse):

```aql
export "Bloom" {
  BloomFilter
  Bits
  make:     make-bloom/r
  add:      bloom-add/r
  contains: bloom-contains/r
  count:    bloom-count/r
  params:   bloom-params/r
  encode:   bloom-encode/r
  merge:    bloom-merge/r
}
```

This nudges export maps toward "small, readable" rather than "two
columns of repetition".

---

## 11. Recommendations summary (prioritised)

### Original list, with current state

**P0 — show-stoppers for library authors:**

1. ~~Sub-imports must be able to load native modules~~ — **done in
   `f7247dd`** (commits `489a1d9`, `d6d8679`). §8.1.
2. ~~Fix or document the HOWTO Counter example~~ — **done in
   `f7247dd`** (commit `331dab9`). §2.4.
3. ~~Custom subtype names must work in fn signatures~~ — **done in
   `f7247dd`** (commits `b7f921e`, `67ddc05`). §4.2.
4. ~~`aql:test` chained calls must not leak stack state~~ — **done
   in `f7247dd`** (no specific commit identified; chaining now
   works). §10.

**P1 — major doc fixes:**

5. ~~Stack convention example~~ — **done** (TUTORIAL §3). §2.1.
6. ~~`for 5 [body]` example~~ — **done** (HOWTO §"Iterate with
   `for`"). §2.2.
7. ~~`fold` arg-order example~~ — **done** (HOWTO §"Work with
   lists"). §2.3.
8. `aql help` examples must be hand-authored — **still open**.
   §5.2, §9.5.
9. README's `go install` command must work against a fresh clone —
   **still open**. §1.1.

**P1 — runtime/parser correctness:**

10. Forward `if` dispatch picks the wrong branch — **still
    open**, sharper diagnosis in §6.2.
11. ~~Engine panic on dot-access in merge-body shapes~~ — **not
    reproducible** in `f7247dd`; recommendation to add a top-level
    `recover()` still stands.
12. `Options` as parameter type breaks dispatch — **still open**.
    §4.1.
13. ~~`def name [list-literal]` should preserve the list value~~ —
    **done** (commits `65cb341`, `c567af4`). §7.1.

**P2 — DX improvements:**

14. When a fn dispatch fails on a forward-collected `word` arg,
    suggest `end` — **still open**. §6.1.
15. When `def name foo` binds to the literal word, suggest
    `def name (foo)` — **still open** at the error level (HOWTO
    now teaches the parens form). §5.3.
16. Error positions should point to the call site — **still open**.
    §3.5.
17. `aql check` should stop producing false positives — **a worse
    failure now**: the checker can't even start on files that
    import siblings. §4.3.
18. Add `ord`/`chr` and a real `hash`/`xxhash` — **still open**.
    §9.8, §9.9.
19. Subtype instance printing in declaration order — **still open**.
    §9.7.
20. `printstr` should consume its argument or document that it
    doesn't — **still open**. §9.1.

**P3 — language-level wishes:**

21. Constructable mutable Array — **still open**. §7.2.
22. Field declarations combining type and default value for nested
    Objects — **partial**; the `field: (make NestedType {})` form
    works but isn't taught. §7.3.
23. ~~`var [[i] body]` as the documented stack-pop pattern~~ —
    **done** (HOWTO §"Use scoped variables"). §5.4.

### New issues discovered during the rewrite

These came up while exercising the *fixed* features and shipping
the cleaner version of the library. They weren't in the original
report.

**P1 — runtime correctness:**

N1. **`aql check` fails on every import of a sibling file.** The
    error is `import: module "" not found (searched .aql//)`. The
    same file runs cleanly. Without `--soft` or a fix, `aql check`
    can't be used in CI for any module that has internal structure.
    §4.3.
N2. **`each [body]` requires the body to push a value.** Mutating
    loops (where the body's purpose is the side effect, not the
    output) have to push a sentinel `0` to satisfy this:
    ```aql
    def _ ((bf item indices-for) each [
      bits swap bit-mark end
      0                                   # only here to keep `each` happy
    ])
    ```
    A `for` body or a dedicated `do-each` (no-output) word would
    drop this clutter. §7.4.
N3. **`if` in mixed forms still picks the wrong branch.** §6.2.
    Worth re-emphasising because it's the costliest remaining
    issue — three rewrites of `bloom-merge` before the
    full-forward form clicked.

**P2 — DX:**

N4. **`aql help` advertises top-level math/`set`/etc. words
    without noting their module requirement.** `aql help log` shows
    `Requires: "aql:math" import` but doesn't say `log` becomes
    `math.log`. §2.6.
N5. **No path to a runnable single-file library.** `bloom.aql`
    can't `aql bloom.aql`-be-run-directly because `export` is
    undefined outside an import. The library has to be entered
    through `smoke.aql`. §8.3.

### Done well in `f7247dd`

Worth highlighting:
- The new HOWTO §"Define an object type with methods" is exactly
  what was missing in the original report — it teaches the working
  pattern with a runnable example and explains *why* the inline-
  method form doesn't work.
- TUTORIAL §3 "The argument-order rule" is a perfect one-paragraph
  callout that resolves the most expensive doc bug from the
  original report.
- The `def x [...]` → list-as-value change makes practical AQL
  code much cleaner; the splice-on-demand `word` keyword keeps the
  old behaviour available for the rare case where it matters.
- Sub-import of native modules is the single biggest architectural
  fix. The library this repo ships is a real module now, not a
  one-file-runnable-script-pretending-to-be-a-module.

---

## 12. What worked well

To balance the report: AQL has real strengths once the gotchas are
internalised.

- **The type lattice** (Scalar/Node/Ideal/Object/Record/…) is
  expressive. Adding `refine Object {…}` for the BloomFilter
  worked cleanly once dispatch was avoided on user-subtype names.
- **The forward-precedence math idiom** (§6.3) is genuinely concise:
  `mul h2 add h1 mod m` is a single-line `(h1 + i*h2) mod m`. With
  a few practice problems it reads like APL.
- **`(iota n) each [body]`** is a clean iteration primitive. The
  list-input form of `each` is exactly what most loops want.
- **`do {key: [value]}`** for forcing evaluation inside map literals
  is elegant once you know it.
- **`refine Object {…}` field mutation via `set`** is straightforward
  and the `get`/`set` dispatch is consistent.
- **`aql do '…'`** as a one-shot REPL is incredibly useful for
  exploration. I used it for ~80% of the debugging.
- **`aql help <word>`**, while example-poor, gets the signatures
  right and the precedence info is exactly what you need.
- **`bxor` / `band` / `bor` / `bsl` / `busr`** are all there and
  work, which is essential for FNV-1a and any other low-level work.
- **`aql:math.log`** is precise; the FPR math came out correct on
  the first run after I found the namespace.
- **The repo layout itself** (`cmd/go` / `lang/go` / `eng/go`) is
  clean and the design docs under `lang/doc/design/` are
  genuinely useful. The thinking is solid; the surface needs
  polish.

If the P0/P1 items above land, AQL has a real shot at being a
pleasant target for the kind of library this report's task asked
for. As of `12a31e6`, it isn't there yet.

### Update for `f7247dd`

It's substantially there now. The P0 list is essentially done. The
remaining drag is the trio of:

- `if` mixed-form picking the wrong branch (§6.2),
- forward precedence eating subsequent words without a hint about
  `end` (§6.1), and
- `aql check` being unusable on multi-file modules (§4.3).

All three are localised enough that a small amount of additional
work would clear them. The library this repo ships — a real
module with typed function signatures, a clean
`"./bloom.aql" import end` integration, and a passing `aql:test`
suite — is something you couldn't write in `12a31e6` and is
straightforwardly writable in `f7247dd`. That's a big shift.

### Update for `333c420`

Another solid pass. Of the 25 original numbered subsections:

- **17 [fixed]** (was 13 after `f7247dd`): adds §3.4
  (dispatch-failure body dumps gone — `b669a57`), §3.5 (error
  positions stamped — `16d58ed`/`6a44d3a`/`e3884ba`/`3c77be6`),
  and the partial→fixed promotions for §3.4.
- **4 [partial]** (was 6).
- **4 [open]**: §1.1 install, §4.1 `Options`, §4.3 `aql check` on
  multi-file modules, §6.2 `if` mixed-form. Same four as before;
  none touched.
- **1 new [partial]**: §7.4 each-must-push-a-value (was open, now
  partial — `for N [body]` covers the index-less case).

The library this pass is materially cleaner than the second pass:
`bloom-contains` is one expression, `bloom-encode` is back in via
`array.where`, the export uses `{BloomFilter}` shorthand.

If the team picks one item to fix next, **§6.2 (`if` mixed-form
returning the wrong branch)** is the most cost-per-fix:
single-handler change, repros in three characters, traps every new
user. The runner-up is **§4.3 (`aql check` on multi-file modules)** —
without it there's no path to CI gating for any real library.

### Update for `5b983b6`

A targeted dx-fix commit (`2d7d4a2`) plus the dotted-access-in-
map-literals parser fix (`5e1339b`) close several long-running
items in one pass. Of the original 25 subsections (plus §7.4 and
§11a) the running totals are:

- **22 [fixed]** (was 17): adds §3.1 (dot in map literals —
  `5e1339b`), §3.3 (engine recover — `2d7d4a2`), §4.1 (`Options`
  parameter — `2d7d4a2`), §5.3 (def-name-foo hint — `2d7d4a2`),
  and the partial→fixed promotion for §6.1's error message.
- **3 [partial]** (was 4): §4.3 (no longer hard-fails but the
  noise is still too much for CI), §6.1 (error hint is great but
  user still has to write `end`), §7.3 (HOWTO doesn't yet show
  the `(make NestedType {})` pattern).
- **3 [open]**: §1.1 install (release engineering), §6.2 `if`
  mixed-form (still reproducible, despite the dx-fix commit's
  claim to the contrary), and the §9.1 `printstr` leftover.

The library got cleaner too:

- `make-bloom`'s parameter is back to the natural `Options`.
- Error positions and forward-precedence hints make every
  iteration's first mistake easy to diagnose. The old "stare at
  the stack trace and guess" loop is gone.
- `bloom-encode` could be rewritten without the
  `do {n: [bf.n], …}` workaround now that §3.1 is fixed. Pending.

Next-to-fix priority list shrinks to two items: **§6.2 (`if`
mixed-form, still broken)** and **§4.3 (`aql check` cross-import
noise)**. Both have characterised reproducers, and both still
block ordinary patterns the user would reach for in normal code.

This pass also unlocked **property-based testing**: the
`test.check-prop`/`test.prop` API in `aql:test` becomes practical
once `Options`-typed constructors dispatch, errors point at the
right place, and `Bloom.add`/`contains` etc. can be called inside
a property body without per-line debugging. The accompanying
`test/bloom_pbt.aql` exercises seven properties of the filter via
generated input — see §11b for the API recap and the new
PBT-specific gotchas. All seven pass on `5b983b6` in ~11 seconds
of total runtime.

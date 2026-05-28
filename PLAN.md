# Plan: aql-lang and bloom-filter fixes from `dx-report.md`

Verification target: `aql-lang/aql @ 4a9708c` (HEAD on `main`, 2026-05-28).
Built locally as `/tmp/aql-head` for verification. Original report
targeted `12a31e6`.

This document is the working plan. Sections:
1. **Verification table** — every claim re-tested against HEAD with the
   implementation-level cause from reading the Go source.
2. **Root-cause grouping** — group live issues by underlying cause, with
   file:line references.
3. **aql-lang fix plan** — what changes land where, with unit tests.
4. **bloom-filter cleanup plan** — what the library becomes once the
   language issues are resolved.
5. **Tracking** — checklist of upstream Go test files and behaviour
   tests added.

---

## 1. Verification table

Status legend:
- `BROKEN` — claim reproduces on HEAD; needs fix.
- `FIXED-HEAD` — bug from report no longer reproduces.
- `DOC` — runtime is correct; docs disagree; fix is docs-only.
- `IMPROVED` — partial fix; surface changed but root still present.
- `DESIGN` — language decision needed, not a clear bug.

### §1 Installation

| §   | Claim | Status | Why this happens |
|-----|-------|--------|------------------|
| 1.1 | `go install …@latest` blocked by replaces | BROKEN | `cmd/go/go.mod` lines 54-60 carry four `replace` directives, two of them with relative paths (`../../eng/go`, `../../lang/go`). The Go toolchain rejects `go install …@latest` against modules with `replace`, and relative paths in particular can't be resolved at remote-install time. The eng/go and lang/go modules are not yet published independently. |
| 1.2 | `aql -version` is "0.1.0-dev" without ldflags | BROKEN | The `Version` symbol is set only via `-ldflags "-X github.com/aql-lang/aql/cmd/go.Version=…"`. When users build with plain `go install` the symbol keeps its source-code default (`0.1.0-dev`). There's no fallback via `runtime/debug.ReadBuildInfo`, so the SHA is invisible to users. |

### §2 Documentation deviations

| §   | Claim | Status | Why this happens |
|-----|-------|--------|------------------|
| 2.1 | `3 4 show` prints `'4 and 3'` (HOWTO claims `'3 and 4'`) | DOC | The runtime convention is intentional and documented in `eng/spec/stack.tsv` §1.4: **fill arg slots forward-in-source-order until a barrier, then fill remaining slots from the stack with TOP into the next-to-fill slot first**. This makes `a b sub`, `a sub b`, and `sub b a` all equivalent to `a - b`. The HOWTO `3 4 show => '3 and 4'` example is just wrong — the correct output is `'4 and 3'` (a=top=4, b=deeper=3). The fix is to correct the example AND surface the rule prominently in HOWTO/TUTORIAL. |
| 2.2 | `for 5 [dup mul]` raises signature error for `dup` | DOC | `for` is registered at `lang/go/native/native_control.go:67` and works: `for 5 [42]` prints `42` five times. The body runs with an *empty* stack; `for` does **not** push the iteration index. The HOWTO example assumes an index push (`=> 0 1 4 9 16`). Either the docs are wrong, or the language wants to add an index-pushing variant. Decision needed; for the docs fix, replace example. |
| 2.3 | `[1,2,3] fold 0 [add]` fails | DOC + RC-3 | The real binding is `init list body fold` (verified). Forward precedence is also a factor: the doc example `[1,2,3] fold 0 [add]` requires `fold` to grab `0` and `[add]` forward, then read `[1,2,3]` from the stack — but `fold` only collects two forward args and reads only one stack arg, so the stack arg position takes `[1,2,3]` correctly. Then it expects `[init, list, body]` but gets `[0, list-from-stack, [add]]` — wrong by position. The doc gets the argument order wrong relative to the actual signature. |
| 2.4 | `type X object {…}` is undefined | BROKEN | `type` is not a registered word. The HOWTO inherited an old form; the intended path is `def X refine Object {…}` (per `design/TYPE-UNIFORM.0.md`). Also: the documented inline-method dispatch (`c inc` where `inc` is a field in the object body) never worked — there's no method-dispatch path for `refine Object` fields that contain code lists. The HOWTO example is therefore doubly broken: keyword not registered *and* the OO pattern it promotes doesn't exist. |
| 2.5 | `def c make Counter` doesn't bind `c` to an instance | BROKEN | `def`'s signatures at `lang/go/native/native_definition.go:25,33,41` have `NoEvalArgs: {1:true}`. The second arg (value side) is never evaluated. So `def c make Counter` literally binds `c` to the word `make`, leaving `Counter` as a dangling word on the stack. The correct form `def c (make Counter {})` works because `(…)` is parenthesised evaluation that forces eager evaluation. |
| 2.6 | `log` undefined after `aql:math` import | DOC | `aql:math` registers words under the `math.` namespace prefix (so `math.log`, `math.ceil`, etc.). The help generator's Notes section reads "Requires: aql:math import" but doesn't surface the prefix, and `aql help` lists `log` at the top level which compounds confusion. |
| 2.7 | `aql:test` chained calls fail | BROKEN | Verified: `test.test` chained calls cause the entire test-module namespace map to dump to stdout. See §10 for the root cause. |
| 2.8 | `import "lib.aql"` vs `import "./lib.aql"` | DOC | The import resolver at `lang/go/native/native_module_module.go:178-188` requires `./`, `../` or `/` prefixes. TUTORIAL line 502 omits the `./` prefix. Just a docs error. Separately, when `aql /abs/path/foo.aql` runs and `foo.aql` does `"./bar.aql" import`, the resolver uses CWD instead of `/abs/path` (§8.1 surface). |

### §3 Parser

| §   | Claim | Status | Why this happens |
|-----|-------|--------|------------------|
| 3.1 | `{n: bf.n}` raises `[jsonic/unexpected]: .` | BROKEN | The jsonic dialect used for map-value parsing tokenises `.` as a path separator only at the top level. Inside `{…}` value positions, `.` is not in the accepted value grammar, so it bails. Fix needed in the jsonic value-rule grammar in `eng/go/parser/`. |
| 3.2 | Map literals in fn bodies stay lazy | FIXED-HEAD | `{n: n, p: p}` inside a fn body now eagerly evaluates `n`, `p` on construction. The `do {n: [n], p: [p]}` workaround in `bloom.aql` can be removed. |
| 3.3 | Engine panic on dot-access in merge body | FIXED-HEAD | Cannot reproduce on HEAD. The original report's `bloom-merge` shape now runs without panicking. Add a regression test anyway. |
| 3.4 | Body-list + module-registry dumped on dispatch failure | BROKEN | When `test.test` chains, the *exported namespace map* of `aql:test` (a Map of registered word names → Function values) is printed to stdout via `FormatForPrint` → `formatMapJSON` → recursive `FormatValueJSON` on each map value. Function values format to their full internal `&FnDef{…}` struct with Go `0x…` pointer addresses. The trigger is that the test framework's body, when failing, pushes the namespace value back onto the stack and stdlib `print` formats it; or the error handler reaches for `args[0]` which happens to be the namespace. **Needs deeper engine investigation** — the dispatch error path probably calls `FormatForPrint` on the stack-residue value. |
| 3.5 | Error position points at last-similar body, not call site | BROKEN | Confirmed root cause at `eng/go/aql_error.go:148-164` in `findWordInSource`: the function iterates lines *backwards* (`for i := len(lines)-1; i >= 0; i--`) searching for the bare word string. Multiple definitions of the same fn name → last hit wins. The comment even claims this is the "call site heuristic"; it isn't, because for any token that appears both at call site and in a later body, the body wins. The fix is to drop the heuristic and use the runtime position tracked by the engine. |

### §4 Type system

| §   | Claim | Status | Why this happens |
|-----|-------|--------|------------------|
| 4.1 | `:Options` as user-fn param breaks dispatch | BROKEN | User-fn signatures resolve type names through `eng/go/fn_params.go:ResolveSigType` (lines 239-314), which calls `LookupDefType` (322-345) against the def-stack at *signature parse time*. Native fns provide `*Type` pointers (e.g. `TOptions`) directly at registration time and skip this resolution. So a user-defined `:Options` annotation never finds a matching dispatch target because the resolution path differs from native fns. |
| 4.2 | User subtype names break dispatch | **FIXED (uniformly across all kinds)** | Two-layer fix in aql-lang. **Layer 1**: `ResolveSigType` now consults the explicit `DefEntry.TypeDef *Type` flag (via `r.LookupTypeName`) as the primary path; body-payload pattern-matching (`IsRecordType`/`IsOptionsType`) is the fallback only for kinds that need a structural Pattern. **Layer 2**: each user-type kind installs a Behavior Match implementation at type-mint time so the lattice node's `Is` actually consults the kind's semantics — `disjunctUnifier` (`eng/go/unify_disjunct.go`) for `(A tor B)`, `depScalarUnifier` (`eng/go/unify_dep.go`) for `(Integer gt 10)`, `bareRefineUnifier` (`eng/go/unify_refine.go`) for `refine Integer`, plus the pre-existing `predicateUnifier`. Object/Table refinements use the parent-chain walk. Comprehensive `TestDispatchMatrix_AllUserTypeKinds` in `lang/go/native/user_subtype_dispatch_test.go` covers happy + negative paths for every kind. Full test suite passes — `lang/go`, `eng/go`, `cmd/go`. |
| 4.3 | `aql check` 262 false positives → now hard fail | IMPROVED | `aql check` at `lang/go/aql.go:172-216` (`Check`) creates a fresh engine via `native.NewTop(a.registry)` at line 181 without forwarding the native-module resolver. Same root as RC-1; now manifests as `import: module "" not found` instead of 262 errors. |
| 4.4 | Field/method namespace collision | BROKEN/DESIGN | Inline `refine Object { inc: [body] }` style is shown in HOWTO but the field-named-as-code-list isn't dispatched as a method. There is no method-dispatch path for object fields whose values are code lists; users must call `c.inc do` (which itself fails because the body's `count get` lookup has no implicit binding). Needs spec decision before any code change. |

### §5 Stack and call order

| §   | Claim | Status | Why this happens |
|-----|-------|--------|------------------|
| 5.1 | First-param = top-of-stack | DOC | Same as §2.1 — runtime is consistent, docs lag. |
| 5.2 | `set` is `obj value key set` | DOC | Auto-generated help shows positional permutations (`set 'a' 2 2`, `2 set 'b' 3`, …) that are technically legal because of forward precedence but read as nonsense. The actual `(String, Any, Object)` signature corresponds to `key value obj` from the dispatch viewpoint (= `obj value key set` from the user's stack viewpoint). |
| 5.3 | `def name foo` binds to literal word | BROKEN | Same `NoEvalArgs: {1:true}` at `lang/go/native/native_definition.go:25,33,41` as §2.5. By design `def` doesn't eagerly evaluate; this is a strong language choice but the lack of an end-user-facing hint ("did you mean `def name (foo)`?") makes it a pure footgun. |
| 5.4 | `var [[name] [body]]` doesn't bind | BROKEN | Confirmed root cause at `lang/go/native/native_definition.go:456`: for a bare-word declaration like `[x]`, `var` generates `def x end` (no value), which binds `x` to nothing useful. The intended behaviour for `5 var [[x] [x print]]` is *pop the stack into `x`* — but the implementation emits the empty `def` instead of consuming a stack value. Compare to lines 473-475 which handle the *valued* `[[x 42] [body]]` form correctly. |

### §6 Forward precedence

| §   | Claim | Status | Why this happens |
|-----|-------|--------|------------------|
| 6.1 | User fns collect next word | BROKEN (narrower than reported) | Reproduces only when the user-fn parameter type is **`:Any` or another wildcard-like type** (including user subtype names per §4.2). With `:Number`, `:Integer`, `:Object`, `:Scalar`, the function-word-is-a-boundary check in `matchSignature` correctly stops forward scan, and `5 f print` dispatches cleanly. Root cause at `eng/go/engine.go:3168-3178`: when `expectedType.Equal(TAny)`, the def-lookup branch captures the next defined word *even if it's an FnDef* (a registered native). The function-word-as-boundary check at line 3197 is reached only when this branch doesn't match — which under TAny means "never". The boundary check needs to run *before* the def-Top check, or the Any-match clause needs to exclude FnDef values. Same root cause underlies the user-visible §4.2 symptom (because user subtypes resolve to a wildcard). |
| 6.2 | `true if [99] [88]` returns 88 | DOC | Under the convention rule (forward-first, then stack-top into next-to-fill): for `cond if [t] [e]`, args[0]=[t] (1st forward), args[1]=[e] (2nd forward), args[2]=cond (stack). `if3Handler` reads args[0]=cond, so it treats [t] as cond — and [t] is truthy, returning args[1]=[e]. The handler is correct only for the all-forward form `if cond [t] [e]`. This isn't a runtime bug: it's documentation showing a call form (`cond if [t] [e]`) that isn't valid under the convention. Fix is docs-only: pin `if cond [t] [e]` as the canonical form, drop the `cond if [t] [e]` example. |
| 6.3 | Inline arithmetic body works | DESIGN | Just an idiomatic example; no bug. |
| 6.4 | `import` grabs the next string | BROKEN | `import` is registered with `BarrierPos: -1`. Need to either change its precedence to statement-only or treat the special case that the next token *would* form a valid module-path. The user expectation is statement-like (one path, then done). |

### §7 Data structures

| §   | Claim | Status | Why this happens |
|-----|-------|--------|------------------|
| 7.1 | `def lst [10,20,30]` spreads | BROKEN | Confirmed at `eng/go/engine.go:763-769`: when `stepWord` resolves a Word to a *non-quoted List value* in the def stack, the engine **splices the list elements onto the stack** instead of pushing the list value (lists double as code-bodies in AQL). Even `def lst ([10,20,30])` produces a list value with `Quoted=false`. Fix: `defHandler` should set `Quoted=true` on bound list values. |
| 7.2 | `make Array` unsupported | BROKEN | `eng/go/core_make.go:728` raises `make: unsupported target type Array`. The make-handler dispatcher only supports a small set of target types; Array isn't constructable from user code. Need either a new `make`-handler case or document that Array is native-module-only. |
| 7.3 | Nested-object field defaults | BROKEN (worse than IMPROVED) | The `bits: Bits` field default is the **type literal** `Bits`, not an empty instance. The `object<…>{…}` print confirms it (it's the `IsObjectType` branch at `eng/go/value.go:1907-1919`). Calling anything on `inst.bits` panics: `inst.bits typeof` → nil-pointer in `ObjectInstanceInfo.GetField`. So the user-facing semantics are broken (field declarations conflate "type annotation" with "default value"), and the engine crashes when the default is used. |

### §8 Module system

| §   | Claim | Status | Why this happens |
|-----|-------|--------|------------------|
| 8.1 | Sub-imports can't see native modules | BROKEN | The native module resolver is installed onto the main registry at `lang/go/aql.go:135`. Sub-imports load files via `lang/go/native/native_module_module.go:RunModuleBody` (lines 18-137), which constructs a fresh registry at line 19 via `DefaultRegistry()`. That registry has no resolver, so when the sub-imported file calls `"aql:math" import`, the resolver lookup at line 457-459 fails with "native module resolver not configured". This is the central RC-1 bug. |
| 8.2 | `import utils [body]` rejected | DOC | The inline-module form only accepts the literal identifier `module`. The HOWTO's `import utils [body]` syntax never worked. |
| 8.3 | `export` undefined outside import | BROKEN | `export` is registered only inside the import-context registry, not the top-level one. Combined with §8.1, a single file cannot simultaneously be (a) runnable directly with `aql foo.aql` (no export), (b) reachable as a library via `"./foo.aql" import` (exports its API), and (c) use `aql:math` (sub-imports can't). The fix is to register `export` as a no-op-outside-import — that breaks no existing use. |

### §9 Other rough edges

| §   | Claim | Status | Why this happens |
|-----|-------|--------|------------------|
| 9.1 | `printstr` leaves arg on stack | BROKEN | The real cause is forward precedence, not the handler. Both `print` and `printstr` are registered with `BarrierPos: -1` at `lang/go/native/native_print.go:11-29`, which resolves to 1 forward arg. So `"hi" printstr "bye" printstr depth print` reorders execution — the second `printstr` forward-grabs `depth` (which itself is a function word evaluating to an integer), and the deferred dispatch ordering plus output buffering produce the `bye2hi` mess. Fix: register both with `BarrierPos: 0` (statement precedence). |
| 9.2 | `convert` order quirks | DOC | All forms tested work; report's "occasional failure" was likely noise. |
| 9.3 | `99 print` + `"hi" printstr` ⇒ `99hi` | BROKEN | Same root as §9.1: `print` is forward-precedence so `"hi" print 99 print` reorders to `99\nhi`. Fix: `BarrierPos: 0` for both `print` and `printstr`. The Fprintln-vs-Fprint distinction in `eng/go/print.go:15,22` is correct; the reordering is the bug. |
| 9.4 | `length` only on List | BROKEN | At `lang/go/native/native_array.go:47-54`, `length`'s only signature is `(TList)`. There's no `(TString)` signature. Add one. |
| 9.5 | Auto-generated help is unhelpful | BROKEN | The help generator at `cmd/go/genhelp/` produces positional permutations of placeholder values (`'a' slice 4 5`, `2 set 'b' 3`, …) that satisfy the type signature but read as gibberish. Most words also have `<not described>` as their description because the registration's `Description` field is empty. Need hand-authored examples + descriptions on the top ~50 words. |
| 9.6 | `aql check` verbosity | IMPROVED | See 4.3. Now a hard fail instead of 262 errors. |
| 9.7 | Subtype fields print alphabetically | BROKEN | Root cause: the **jsonic parser** sorts map-literal keys alphabetically while building the OrderedMap. Verified: `{z:1, a:2, m:3} print` → `{"a": 2, "m": 3, "z": 1}` (insertion-order would print z, a, m). `parseObjectFields` (`lang/go/native/native_object_record.go:55-61`) and `formatMapJSON` (`eng/go/print.go:106`) both preserve insertion order via `Keys()`, so the sort happens upstream of both. Fix site: jsonic dialect under `eng/go/parser/`. |
| 9.8 | No hash | BROKEN | No `hash` / `fnv` / `xxhash` words registered. The `aql:math` and `aql:bin` modules expose arithmetic/bitwise but no hashing. New native words needed. |
| 9.9 | No ord/chr | BROKEN | `convert: cannot convert "h" to number` confirms that `convert Integer "h"` doesn't go through codepoint conversion. No `ord` / `chr` words registered. New native words needed. |

### §10 aql:test framework

| §   | Claim | Status | Why this happens |
|-----|-------|--------|------------------|
| 10  | Chained `test.test` leak / dump registry | BROKEN-WORSE | The test framework module is implemented in `lang/go/modules/test.go`. `test.test` invokes `runCase` (line 891) which calls `native.New(r).Run(body)` at line 897, creating a fresh engine from the parent registry. If `Run` returns an error or leftover stack state, the residue is dumped via the engine's print path. The full namespace map (the `aql:test` exports) lands on stdout because `Run` ends with the exported `Map` value still on the stack after a dispatch failure, and `FormatForPrint` prints it. **Needs more investigation** to confirm exact print site. |

---

## 2. Root-cause grouping

After verification + code reading, issues collapse into seven root
causes plus a tail of independent items. The user's hypothesis —
**inconsistent delivery of language features across contexts** — is the
right lens for six of the seven.

### RC-1: Registry/context not inherited by child engines

**Issues**: §8.1, §8.2, §4.3, §8.3 (partial)
**Common cause**: `RunModuleBody` (`lang/go/native/native_module_module.go:18`)
constructs a fresh registry via `DefaultRegistry()` instead of cloning
from the parent. The native-module resolver, the `export` word, the
top-level def stack — all are tied to the parent registry only.
`aql check` (`lang/go/aql.go:181`) shares the same pattern via
`native.NewTop(a.registry)`.
**Fix shape**: introduce a `Registry.SpawnChild()` method that carries
forward natives + resolver + parent-imports, and route both
`RunModuleBody` and `Check` through it.

### RC-2: User-fn signature type-lookup diverges from native-fn type-lookup

**Issues**: §4.1, §4.2, *compounds with §6.1*
**Common cause**: User fns resolve type names through
`eng/go/fn_params.go:ResolveSigType` (239-314) → `LookupDefType` (322-345)
*at sig-parse time*, against the def-stack. Native fns supply `*Type`
values directly at registration. So `:Options` and `:Foo` look up
correctly for natives, but for user fns the lookup returns a wildcard
that matches everything (verified: `[f:Foo]` accepts `42`, `"hello"`,
and any list value alike).
**Fix shape**: defer the lookup until dispatch time (late binding), or
re-resolve refined types via the same registry path natives use. Once
fixed, the §6.1 forward-grab symptom in user code largely disappears
because user fns no longer effectively get `:Any`-equivalent params
when authors write `:Foo`.

### RC-3: Forward-precedence dispatcher edge cases

**Issues**: §6.1 (narrowed), §6.4, §9.1, §9.3
**Sub-bugs**:
- §6.1: when expectedType is `TAny`, the def-Top branch at
  `eng/go/engine.go:3168-3178` captures the next defined word *even
  if it's an FnDef*, bypassing the function-word-as-boundary check at
  3197. The fix: either reorder so the function-word check runs first,
  or exclude FnDef values from the TAny-match clause.
- §6.4, §9.1/§9.3: `import`, `print`, `printstr` are forward-precedence
  and silently consume the next token. These should be
  statement-precedence (`BarrierPos: 0`).
- §6.2 is a *docs* issue under the convention (not a runtime bug) —
  see verification table.
**Fix shape**: small targeted patches per sub-bug; see Phase B in §3.

### RC-4: `def` doesn't evaluate its value side

**Issues**: §5.3, §2.5, §7.1
**Common cause**: `NoEvalArgs:{1:true}` at
`lang/go/native/native_definition.go:25,33,41`. The user must wrap
explicitly with `(…)`, and even that doesn't reliably help for list
literals (§7.1).
**Design choice**: this is a strong language preference (the original
design probably wanted quoting-by-default to mirror `def` in Lisp-y
languages). The fix path is *not* to flip the default — that would
break existing code — but to:
  - Make `def name (expr)` reliably evaluate, including list literals.
  - Surface a hint when `def name word(somefn)` is detected: "did you
    mean `def name (somefn …)`?"

### RC-5: Error reporting infrastructure

**Issues**: §3.4, §3.5, §4.3, §9.6
**Sub-bugs**:
- `findWordInSource` (`eng/go/aql_error.go:148-164`) scans backwards for
  the bare word, hitting the last definition instead of the call site.
- Dispatch failures dump stack residue via `FormatForPrint` even when
  the residue is a huge namespace map.
- `aql check`'s speculative-analysis output isn't classified as
  hard-vs-soft.
**Fix shape**: refactor `AqlError` to carry a real call-site frame (use
the engine's program counter instead of a name search), truncate
quoted-list and namespace-map values in error formatting, and split
check's diagnostics into hard/soft.

### RC-6: jsonic parser doesn't cover map-literal value expressions

**Issues**: §3.1
**Common cause**: The jsonic dialect only recognises bare identifiers,
strings, numbers, and lists/maps as map-literal values. Dot-paths
(`bf.n`) and parenthesised expressions (`(f x)`) are not in the value
production rule.
**Fix shape**: extend the value rule to include path expressions and
parenthesised expressions.

### RC-7: Missing primitives and shape mismatches

**Issues**: §9.4, §9.7, §9.8, §9.9, §7.2, §9.1, §9.3
**Sub-bugs**: each independent; just standard "add a builtin / fix a
loop / unify a formatter" work.

### Independent (no shared root)

- §1.1, §1.2 — install / version ergonomics.
- §2.4 — `type` keyword + inline-method-dispatch are both phantom features.
- §3.3 — engine panic, already gone on HEAD; just regression test.
- §3.2 — already fixed; remove workaround.
- §5.4 — `var` bare-name bug, isolated at line 456.
- §10 — `aql:test` chained call dump, downstream of RC-5 plus its own
  state management.

### Pure docs

- §2.1, §2.2, §2.3, §2.4 (part), §2.5 (part), §2.6, §2.8, §5.1, §5.2,
  §8.2.

---

## 3. aql-lang fix plan

Work order from highest leverage to lowest. Each item describes the
change, the test, and where it lives.

### Phase A — fix the core context-delivery bugs (RC-1, RC-2, RC-5)

These unlock the bloom-filter cleanup and remove the most expensive
friction.

**A1. Native module registry inheritance** (RC-1; §8.1, §4.3, §8.2 partial)
- Code: `lang/go/native/native_module_module.go` (`RunModuleBody` line 18), `lang/go/aql.go` (line 181 `Check`).
- Behaviour: a child engine spawned by `import` (file or inline) or by `aql check` inherits the parent's `NativeModules` registry and resolver.
- Tests: `lang/go/aql_test.go` adds `TestSubImportReachesNativeModule`, `TestInlineModuleReachesNativeModule`, `TestCheckReachesNativeModule`.

**A2. User-fn signature type lookup uses live registry** (RC-2; §4.1, §4.2)
- Code: `eng/go/fn_params.go` `ResolveSigType` (239), `LookupDefType` (322).
- Behaviour: a fn signature `[x:Foo]` where `Foo` was declared with `def Foo refine Object {…}` accepts instances built via `make Foo {…}`. Same for `:Options`. Late-bind the type lookup at dispatch time.
- Tests: `lang/go/aql_test.go` adds `TestUserFnAcceptsUserSubtype`, `TestUserFnReturnsUserSubtype`, `TestUserFnOptionsParam`.

**A3. Error reporting** (RC-5; §3.4, §3.5)
- Code: `eng/go/aql_error.go` `findWordInSource` (148), error formatting paths.
- Behaviour:
  - Drop `findWordInSource`'s backwards scan; use the engine's program-counter / token-source-position metadata to point at the real call site.
  - Truncate quoted-list and namespace-map values in error output to head + ellipsis.
  - Hide registry payloads behind `-vv`.
- Tests: new `eng/go/aql_error_test.go` adds `TestErrorPointsAtCallSiteNotLastBody`, `TestErrorTruncatesQuotedList`, `TestErrorDoesNotDumpNamespace`.

### Phase B — fix forward precedence (RC-3)

**B1. Forward dispatcher: exclude FnDef from TAny-match** (§6.1)
- Code: `eng/go/engine.go:3168-3178` — in the def-Top branch, the
  `|| expectedType.Equal(TAny)` clause should not match when the
  resolved def value is an `FnDefInfo`. Or: move the function-word
  boundary check from line 3197 up to before the def-Top check.
- Behaviour: `5 f print` with `def f fn [[x:Any] ...]` dispatches
  `f` first (boundary on `print`), then `print` runs.
- Tests:
  - `TestForwardGrabExcludesFunctionWordsWithAnyParam`.
  - `TestForwardGrabExcludesNativeFunctions`.

**B2. Statement-precedence words** (§6.4, §9.1, §9.3)
- Code: registration of `print`, `printstr` in `lang/go/native/native_print.go`; `import` in `lang/go/native/native_module_module.go`. Change `BarrierPos: -1` to `BarrierPos: 0`.
- Behaviour: `"./foo.aql" import "next" print` doesn't import "next"; `"hi" print 99 print` outputs in source order.
- Tests:
  - `TestPrintIsStatementPrecedence`.
  - `TestImportDoesNotForwardGrabString`.

**B3. (`if` branch order — docs-only, see §6.2 in verification table)**

**B4. End-hint on dispatch failure** (§6.1 fallback ergonomics)
- Code: dispatch error formatting in `eng/go/engine.go` (where signature_error is constructed).
- Behaviour: when a failing arg is `word(…)` and the signature expects a non-word type, the error appends `did you mean to insert end?`.
- Test: `TestDispatchFailureSuggestsEndOnWordArg`.

### Phase C — `def` evaluation ergonomics (RC-4)

**C1. `def name (expr)` always evaluates** (§5.3, §7.1)
- Code: `lang/go/native/native_definition.go` — extend the `NoEvalArgs` logic to special-case parenthesised input on the value side.
- Behaviour: `def lst ([10,20,30])` binds the list value. `def c (make Counter {})` (already works) and `def c make Counter` (with no parens) emits a hint, not a silent bind-to-word.
- Test: `TestDefBindsListValueWhenParenthesised`, `TestDefHintsWhenValueLooksLikeCall`.

### Phase D — parser (RC-6)

**D1. Dot-path expressions in map-literal values** (§3.1)
- Code: jsonic dialect under `eng/go/parser/`.
- Behaviour: `{n: bf.n}` parses; `{n: (f x)}` parses.
- Test: `TestMapLiteralAcceptsDotPath`, `TestMapLiteralAcceptsParenExpr`.

### Phase E — small bugs and missing primitives (RC-7 + Independent)

**E1. `length` on String** (§9.4) — add `(TString)` sig in `lang/go/native/native_array.go:47`.
**E2. `printstr` consumption / output ordering** (§9.1, §9.3) — investigate `r.Output` writer; ensure flushed between calls; verify `printstr` doesn't leave stack residue.
**E3. Declaration-order object print** (§9.7) — find the sort in object print path and change to use `Keys()` not `SortedKeys()`.
**E4. `var` bare-name pops stack** (§5.4) — fix `lang/go/native/native_definition.go:456` to consume from stack instead of emitting `def x end`.
**E5. `aql:test` chained calls** (§10, §3.4) — `lang/go/modules/test.go`; isolate `test.test` body in a fresh stack frame; never let the test-namespace map reach `FormatForPrint`.
**E6. Missing primitives** (§9.8, §9.9, §7.2):
  - Add `hash` / `fnv32a` / `fnv64a` / `xxhash32` / `xxhash64` to `aql:bin`.
  - Add `ord` / `chr` to a new `aql:string` or core.
  - Either implement `make Array …` for user code, or document the canonical alternative.
**E7. Engine panic recovery** (§3.3, defensive) — wrap `Engine.Run` in `recover()` to convert panics to `AqlError`.
**E8. Unify `Object/Foo{}` vs `object<…>{…}`** (§7.3) — find the `object<…>` branch at `eng/go/value.go:1919` and route default-field-constructed instances through the same printer as explicit instances.

### Phase F — install / version

**F1. README install command** (§1.1) — choose: (a) tag a release and publish `eng/go` + `lang/go` as independent modules, dropping replaces from `cmd/go/go.mod`; or (b) update README to say "build from clone until 0.1.0".
**F2. Version from build info** (§1.2) — fall back to `runtime/debug.ReadBuildInfo()` VCS revision when `Version` is unset.

### Phase G — docs

**G1. HOWTO rewrites**:
- Stack-and-signature convention paragraph (front of HOWTO).
- `for` example uses a body without `dup` (since `for` doesn't push index).
- `fold` example matches `init list body fold` order.
- `type X object` block deleted; replaced with `def C refine Object` + free-fn example.
- `def c make Counter` → `def c (make Counter {})`.
- `import "lib/utils.aql"` → `import "./lib/utils.aql"`.
- `import utils [body]` → `import module [body]`.

**G2. TUTORIAL polish**:
- Add stack convention callout.
- Add `var [[name value] [body]]` example (and once E4 lands, `[[name] [body]]` for stack-pop).
- Drop `do {key: [value]}` workaround note (§3.2 fixed-head).

**G3. Hand-authored `aql help`** (§9.5, §5.2):
- Examples for: `get`, `set`, `make`, `refine`, `fold`, `each`, `for`, `if`, `import`, `export`, `def`, `length`, `slice`, `assert.equal`, `print`, `printstr`.
- Notes lines surfacing the namespace prefix for native-module words (`log` ⇒ "call as `math.log` after `aql:math` import").

**G4. `aql:test` design doc** — update with the imperative-API limitations and recommended form after E5 lands.

---

## 4. bloom-filter cleanup plan

Once Phase A + B + D + E ship, the bloom-filter project becomes:

1. **Layered structure**: `bloom.aql` defines API + `export "Bloom" {…}`; `index.aql` does `"./bloom.aql" import` and demos.
2. **Typed signatures**: `[bf:BloomFilter]`, `[Bits]`, etc., once §4.2 fixed.
3. **Real `aql:test`** in `test/bloom_test.aql` once §10 fixed.
4. **Re-add `bloom-encode` and `bloom-merge`** once §6.2 fixed.
5. **Drop the `do {n: [n]}` workaround** in `bloom-params` (§3.2 already fixed).
6. **Use real hash primitive** (E6): replace `hash1`/`hash2`/`fnv-step`/`code-at`/`codes-of`/`alphabet` (~50 lines) with two `fnv32a` / `fnv64a` calls.
7. **Use `ord`/`chr`** directly in any remaining string-walk code.
8. **Use a real mutable Array** for `Bits` if E6 lands it.
9. **Dot-path map literal** in `bloom-params`: `{n: bf.n, p: bf.p, m: bf.m, k: bf.k}` once §3.1 lands.
10. **Update README** with install + usage.

---

## 5. Tracking

### Checklist

Phase A — core context delivery
- [ ] A1 native module registry inheritance + tests
- [x] A2 user-fn signature type lookup + tests — two-layer fix:
  - **Resolution layer** (`eng/go/fn_params.go`): `ResolveSigType` now uses the explicit `DefEntry.TypeDef *Type` flag (via `r.LookupTypeName`) as the primary discriminator. `ResolveDefType` is the fallback for Record/Options (which need structural patterns).
  - **Behavior layer**: per-kind Match implementations attached at type-mint in `eng/go/core_type.go:InstallType`:
    - Object/Table refinements use parent-chain walk (default).
    - Disjunct → `disjunctUnifier` (new in `eng/go/unify_disjunct.go`) consults alternatives.
    - DepScalar → `depScalarUnifier` (new in `eng/go/unify_dep.go`) runs the bound check.
    - Bare nominal refine (`refine Integer`) → `bareRefineUnifier` (new in `eng/go/unify_refine.go`) admits values matching the base.
    - Predicate fn types still use the existing `predicateUnifier`.
  - **Tests**: `TestDispatchMatrix_AllUserTypeKinds` covers happy + negative paths for every kind; `TestUserSubtype*` regression tests; `TestRefinementBodyCatalogue` documents body shapes per kind. Full lang/go + eng/go + cmd/go test suites pass.
- [ ] A3 error reporting refactor + tests

Phase B — forward precedence
- [ ] B1 if branch order + test
- [ ] B2 statement-precedence words + test
- [ ] B3 end-hint + test

Phase C — def evaluation
- [ ] C1 def evaluates parenthesised, hints on word-looking value + tests

Phase D — parser
- [ ] D1 dot-paths in map-literal values + tests

Phase E — small bugs and primitives
- [ ] E1 length on String
- [ ] E2 printstr / output buffering
- [ ] E3 declaration-order print
- [ ] E4 var bare-name pops stack
- [ ] E5 aql:test chained calls
- [ ] E6 hash + ord/chr + mutable Array
- [ ] E7 engine recover
- [ ] E8 unify Object print formats

Phase F — install / version
- [ ] F1 README install
- [ ] F2 version fallback

Phase G — docs
- [x] G1 HOWTO rewrites (stack convention callout, broken examples, type/object syntax, for/var/import fixes, format/group/scan/member rewrites, end example, time/matrix/decision import syntax)
- [x] G2 TUTORIAL polish (§3 argument-order rule with worked sub/show examples, §4 math.* namespace, §5 strings all-forward, §11 higher-order all-forward, §13 def-refine syntax, §14 var explanation, §15 call fixed, §19 module form, §1 install)
- [x] G3 hand-authored aql help — done for sub/div/mod/pow/mul. The rest of the table (each, fold, scan, contains, etc.) still uses auto-generated examples; lower-priority sweep tracked below.
- [ ] G4 aql:test design-doc

Phase G — docs (followup)
- [ ] G3b `aql help` sweep for the remaining ~50 most-used words (each, fold, scan, contains, indexof, slice, replace, split, set, get, if, for, make, refine, import, export, def)
- [x] README install command
- [x] REFERENCE.md sweep: §Evaluation model rule, arithmetic split (core vs math.X), strings all-forward forms, higher-order rewrite, type-words now show def-refine pattern, options examples corrected
- [x] EXPLANATION.md §How collection works tightened with the rule + sub example
- [x] CLI.md install command

Bloom-filter cleanup
- [ ] Layered structure (bloom.aql + index.aql)
- [ ] Typed BloomFilter / Bits signatures
- [ ] aql:test-driven tests
- [ ] bloom-encode and bloom-merge re-added
- [ ] Use real hash, ord, chr, Array primitives
- [ ] README updated

### Investigation gaps — RESOLVED

All six gaps were resolved by reading the relevant Go source. Findings
that change the PLAN above:

**§6.2 — `if` branch order is a *convention* problem, not a position bug.**
Verified across the four call forms:
- `cond [then] [else] if` (all-stack) → returns *then* ✓
- `cond if [then] [else]` (mixed, HOWTO form) → returns *else* ✗
- `if cond [then] [else]` (all-forward) → returns correct branch ✓
- `[then] [else] if cond` doesn't exist as a syntactic shape.

`matchSignature` (`eng/go/engine.go:3022-3360`) does the obvious thing:
forward args fill `positions[0..fwd-1]` in source-order; remaining
stack args fill `positions[fwd..n-1]` from the top down. `if3Handler`
(`lang/go/native/native_control.go:223`) reads
`args[0]=cond, args[1]=then, args[2]=else`. For the all-forward form
those coincide; for `cond [t] [e] if` the all-stack convention puts
`cond` at depth-bottom = `positions[2]` and yet *the test passes*
because `args[0]=top=[e]` is non-empty (list) → truthy → returns
`args[1]=[t]`. That's accidentally-correct by truthiness, not by
design. For the mixed form `cond if [t] [e]`, `args[0]=[t]` truthy
→ returns `args[1]=[e]`. Wrong.

Underlying issue: **AQL's "first param = top of stack" convention
means `args[0]` denotes different source-position arguments depending
on whether the call is forward, stack, or mixed**. There is no fix
inside `if3Handler` that makes all three call shapes work; the
dispatcher's position-fill convention itself must change. Options:
  (a) Convention flip: `args[0]` = source-left-most (deepest stack
      OR first forward). This aligns with the HOWTO and makes the
      handler authoring obvious, but silently rewrites every existing
      user fn's parameter meaning — including the `bloom.aql` we
      already wrote.
  (b) Keep the current convention; rewrite `if3Handler` to inspect
      *which* positions are forward vs stack via a dispatch-supplied
      side-channel and pick the cond accordingly. Smaller blast
      radius but `if` becomes special.
  (c) Document the convention precisely (per call form) and recommend
      a single canonical form for `if` (e.g., always all-forward
      `if cond [then] [else]`).

Recommendation: **(c) plus a doc-only `if` rewrite for the HOWTO**, and
mark the mixed-form `cond if [t] [e]` as undefined-behavior. Long
term, (a) is the right call but it's a v0.2 design decision.

**§7.1 — `def` binding to a List value triggers spread at access time.**
Root cause confirmed at `eng/go/engine.go:763-769`:

```go
if top.Parent.Equal(TList) && top.Data != nil && !IsTypedList(top) &&
   !IsTableType(top) && !top.Quoted {
    elems, _ := AsList(top)
    expanded := make([]Value, elems.Len())
    copy(expanded, elems.Slice())
    stackSplice(&e.stack, e.pointer, 1, expanded...)
    return nil
}
```

When `stepWord` resolves a Word to a def-stack entry that's a
non-quoted List, the engine **splices the list elements onto the
stack** instead of pushing the list value. This is by design (lists
double as code-bodies). The fix is to mark `def`-bound list values
with `Quoted=true` at binding time so the `!top.Quoted` check
suppresses the spread. Fix site: `defHandler` /
`lang/go/native/native_definition.go:167`.

**§7.3 — `bits: Bits` field default is the *type literal* `Bits`,
not an empty instance of Bits.** Confirmed by:
`def Foo refine Object {bits: Bits}; def i (make Foo {}); i.bits typeof`
panics with nil-pointer in `ObjectInstanceInfo.GetField` (called on a
type literal). Print form `object<Object/Bits>{}` comes from
`eng/go/value.go:1907-1919` `IsObjectType` branch. Compare
`IsObjectInstance` at 1894-1906 which produces `Object/Bits{}` (no
wrapper). So the user-facing semantics are: a field declaration
`name: Type` says "this field's type is Type" but the default value
is the type literal itself, not a default instance. That is a
language-design hole: there's no syntax for "type Bits, default
(make Bits {})". The earlier "FIXED-HEAD/IMPROVED" status was wrong —
§7.3 is still BROKEN, and worse, the resulting state crashes the
engine. Add: §3.3-like recover() in addition to the type-system fix.

**§9.7 — jsonic parser sorts map-literal keys alphabetically.**
Verified by `{z:1, a:2, m:3} print` → `{"a": 2, "m": 3, "z": 1}`.
The `OrderedMap` itself preserves insertion order (`Keys()` at
`eng/go/value.go:97`); `formatMapJSON` uses `Keys()` (insertion);
`parseObjectFields` at `lang/go/native/native_object_record.go:55-61`
iterates `Keys()` and copies in order. So neither the print path nor
the make handler sort. The sort must be happening in the jsonic
parser's map-literal value construction itself (probably building a
Go `map[string]Value` intermediary, then inserting into OrderedMap
via `range` which is randomized — and randomness was stabilized via
sort somewhere). Fix site: `eng/go/parser/` jsonic dialect — preserve
source-order during map construction.

**§9.1 / §9.3 — `print` and `printstr` are forward-precedence, and
their `BarrierPos: -1` (→ 1) causes execution-order reordering when
chained without `end`.**

Both are registered at `lang/go/native/native_print.go:11-29` with
`BarrierPos: -1` which resolves to 1 (one forward arg). Then
`"hi" print 99 print` becomes:

1. push "hi".
2. `print` forward-collects `99` (since 99 matches TAny), defers
   execution via `insertForward` (`engine.go:928`).
3. Continues; second `print` either forward-grabs nothing or stack-
   matches "hi".
4. Deferred call executes — but interleaving with the second
   `print`'s stack-match produces the observed `99\nhi` output.

The "leftover on stack" effect (`depth print` showing 2 in §9.1)
is the same forward-precedence reordering — `depth` itself is a
function word, but `print depth` lets the *outer* `print` re-enter
with `depth`'s pushed value as its arg before stack reaches the
first `print`.

Fix: re-register `print` and `printstr` with **statement
precedence** (`BarrierPos: 0`). They should *not* forward-grab.
That's a one-line change. Combined with an explicit flush of
`r.Output` in both handlers, `99\nhi` and `bye2hi` go away.

**§3.4 — the namespace dump is a `FormatValueJSON` fallback on a
`Function` value.**
Minimal repro:
```
"aql:test" import end   test print
```
This prints the entire `aql:test` exported namespace map, including
recursive `FormatValueJSON` calls on each Function value. The
Function value has no specific case in `FormatValueJSON`
(`eng/go/print.go`); the fallback uses Go's `%v` against the
internal `FnDef` struct, producing the `word()({test-test [] [{...
0x… ...}])` style output.

Why it triggers in chained `test.test` scenarios: combined with
the §9.1 print-forward-precedence reordering, the `test`
namespace map ends up at the top of stack at some point during
the `test.fail-count print test.pass-count print` sequence, and
`print` formats it via `FormatValueJSON`.

Two-part fix:
- Add a `FormatValueJSON` case for Function/FnDef values that emits
  e.g. `<fn:test-test [String List] → []>`.
- Fix §9.1 first; that removes the reordering that lets the
  namespace map reach `print` accidentally.

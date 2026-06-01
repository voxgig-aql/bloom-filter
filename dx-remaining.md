# Remaining DX issues — `aql @ 5b983b6`

For each: description, reproducer, expected vs. actual, workaround, and
suggested fix. Items marked **[open]** are unchanged; **[partial]** means
the upstream fix landed something but the user still hits the issue.

---

## §6.2 — `if` mixed-form picks the wrong branch [open]

The single highest-priority bug. The `2d7d4a2` dx-fix message says it
"doesn't reproduce on the current tree" but it reproduces in three
characters in the mixed/infix form.

**Reproducer:**

```
$ aql do 'true if [99] [88] end print'
88
$ aql do 'false if [99] [88] end print'
88
$ aql do 'true [99] [88] if end print'
99      # full-stack works
$ aql do 'if true [99] [88] end print'
99      # full-forward works
```

**Expected:** `true if [99] [88]` should evaluate the `[99]` branch and
produce `99`. **Actual:** always `88` regardless of the condition. Only
the full-forward (`if cond [t] [e]`) and full-stack (`cond [t] [e] if`)
forms behave correctly.

**Workaround:** rewrite every `cond if [t] [e]` as `if cond [t] [e]`.
The library uses this convention throughout `bloom-count` and
`bloom-merge`.

**Suggested fix:** when `if` is encountered, the order in which
forward-collected and stack-filled args populate slots must match how
the handler indexes them. The current handler appears to be reading
`cond` from the wrong slot when only some args came from forward
collection.

---

## §4.3 — `aql check` produces false positives across imports [partial]

The hard-fail (`module "" not found`) was fixed in `2d7d4a2` but the
checker still can't see across import boundaries, so every cross-module
call site flags 1–2 spurious errors. Blocks CI gating.

**Reproducer (against the library in this repo):**

```
$ aql check smoke.aql
check: 8:28: [error] undefined_word: undefined word: Bloom
check: 8:33: [error] no_signature: no matching signature for get; assuming best-fit candidate for analysis
check: 10:24: [error] undefined_word: undefined word: Bloom
check: 10:33: [error] no_signature: no matching signature for get; assuming best-fit candidate for analysis
check: 12:28: [error] undefined_word: undefined word: Bloom
...12 errors total for 7 call sites...
```

The same file runs cleanly via `aql smoke.aql`.

**Expected:** the checker should either resolve the exports of
`"./bloom.aql"` (which it can read), or treat unresolved names from an
imported module as analysis-passes rather than errors.

**Workaround:** none for CI gating; ignore the errors manually. A
`--soft` flag exists but doesn't suppress this category.

**Suggested fix:** when `import "<relative-path>"` is encountered, run
the imported file's `export` statement under the checker to populate
the namespace symbol table. If full analysis is too expensive, at least
register the export keys as opaque values so cross-module `.foo` access
doesn't raise `undefined`.

---

## §6.1 — Forward-precedence eats the next word; `end` still required [partial]

The error message now hints at the fix (`2d7d4a2`), but every user-fn
call site still needs an `end` when followed by another word. The hint
reduces time-to-diagnosis but doesn't eliminate the footgun.

**Reproducer:**

```
$ aql do 'def f fn [[a:Integer] [Integer] [a add 1]]   "hi" f end print'
error: [aql/signature_error]: no matching signature for f
  --> 1:52
  1 | def f fn [[a:Integer] [Integer] [a add 1]]   "hi" f end print
                                                         ^ no matching signature for f
  = forward args for f may have run into the next word; group the call
    with parens — (f …) — or end it with `end` or `;`
```

The hint is great. But the user still has to remember to write `end`
after every dispatch like `bf "hello" Bloom.add end` in normal code.

**Library impact (count of `end` markers needed):**

```
$ grep -c " end " bloom.aql smoke.aql test/bloom_test.aql
bloom.aql:24
smoke.aql:13
test/bloom_test.aql:43
```

80 `end` markers across three small files.

**Expected:** ordinary user fns shouldn't eat the next word. Forward
precedence is genuinely useful for `if`/`each`/`fold`/`import` — words
that gather code blocks — but for an arithmetic-style fn it's a
footgun.

**Workaround:** sprinkle `end` after every call.

**Suggested fix:** make user-defined `fn` words stack-precedence by
default. Keep forward precedence as an opt-in via a modifier (the `/f`
/ `/s` modifiers exist; reverse the default). Built-ins that want
forward (`if`, `each`, `import`) keep their current behaviour.

---

## §7.4 — `each [body]` requires the body to push a value [partial]

`for N [body]` covers the index-less case (`333c420`), but every
indexed mutating loop still has to push a sentinel.

**Reproducer (extracted from `bloom-merge`):**

```aql
def _ (iota am each [
  var [[i]
    def is-set (b-bits i bit-test end 1 eq)
    if is-set [
      a-bits i bit-mark end
      0                        # sentinel — only here so the body produces
    ] [
      0                        # sentinel
    ]
  ]
])
```

Without the `0` at the end of each branch, `each` errors with `body
produced no result`. The accumulator `def _ (...)` discards the
resulting `List<0, 0, 0, …>`.

**Expected:** an indexed `for-do` form that doesn't collect, or `each`
accepting a `None`-returning body.

**Workaround:** push a sentinel `0` from every branch; discard the
list. Adds noise to every mutating loop.

**Suggested fix:** add `for [0, N] [body]` (range form that runs the
body N times without collecting) or `do-each [body]` (each that
discards body output). Either closes the gap.

---

## §9.1 — `printstr` leaves its argument on the stack [open]

The `2d7d4a2` message claims `printstr` "does NOT reproduce on the
current tree". It does.

**Reproducer:**

```
$ aql do '"hi" printstr depth end print'
2hi      # depth printed 2 (or two stack values), meaning "hi" is still on the stack
```

For comparison, `print` does consume:

```
$ aql do '"hi" print depth end print'
hi
0        # stack empty after print
```

**Expected:** `printstr` consumes its arg the same way `print` does —
only the newline behaviour differs.

**Workaround:** `"hi" printstr drop` after every `printstr` to clear
the stack.

**Suggested fix:** make `printstr`'s handler call the same `pop` path
as `print` after writing to stdout.

---

## §1.1 — `go install …/cmd/go/aql@latest` is rejected [open]

The documented quick-start in the README still fails.

**Reproducer:**

```
$ go install github.com/aql-lang/aql/cmd/go/aql@latest
go: github.com/aql-lang/aql/cmd/go/aql@latest (in github.com/aql-lang/aql/cmd/go@v0.0.0-20260531...):
  The go.mod file for the module providing named packages contains one or
  more replace directives. It must not contain directives that would cause
  it to be interpreted differently than if it were the main module.
```

`cmd/go/go.mod` has four `replace` directives (to `eng/go`, `lang/go`,
`voxgig/struct/go`, `voxgig/udk/go`); `go install` against an
unreleased module rejects this.

**Workaround:** clone and `cd cmd/go && go install ./aql`.

**Suggested fix:** release engineering — tag `cmd/go/v0.1.0` (the
Makefile already documents how) so the published module has resolved
dependency versions instead of relying on local replacements.

---

## §7.3 — Nested-object field defaults need explicit construction [partial]

HOWTO doesn't yet teach the `field: (make NestedType {})` pattern.
Users naturally try `field: NestedType` (a type literal) and hit a
confusing error.

**Reproducer:**

```
$ aql do 'def Bits (refine Object {})   def Foo (refine Object {bits: Bits})   def inst (make Foo {})   inst.bits 1 "0" set   inst.bits print'
error: ...
$ aql do 'def Bits (refine Object {})   def Foo (refine Object {bits: (make Bits {})})   def inst (make Foo {})   inst.bits 1 "0" set   inst.bits print'
Object/Bits{0:1}
```

The first form looks reasonable (declare the field's type) but doesn't
initialise an instance; `inst.bits` is the bare type literal `Bits`.
The working form `bits: (make Bits {})` constructs an empty Bits at
field-default time.

**Expected:** docs cover the construction pattern for nested objects.

**Workaround:** use `(make NestedType {})` as the field default.

**Suggested fix:** add the worked example to HOWTO §"Define an object
type with methods". One paragraph.

---

## §8.3 — `export` is undefined when running a file directly [open]

There's no way to write a single file that both runs standalone and
exports a namespace when imported.

**Reproducer:**

```
$ aql /home/user/bloom-filter/bloom.aql
error: [aql/undefined_word]: undefined word: export
$ aql /home/user/bloom-filter/smoke.aql   # imports bloom.aql — works
params:   ...
```

**Expected:** `export` is a no-op at the top level (i.e., when not in
an import context), so the same file can serve both modes.

**Workaround:** have a separate `smoke.aql` for direct execution; keep
`bloom.aql` import-only.

**Suggested fix:** in `Engine.Run` at the top-level, register `export`
as a no-op handler; it only gets the real handler in import contexts.

---

## §11b — Property-based testing gotchas [new]

These came up writing `test/bloom_pbt.aql`.

### §11b.1 — Sub-engine native-module isolation [open]

Property bodies run in a sub-engine where `"aql:math" import` fails.

**Reproducer:**

```
$ aql do '"aql:test" import end   test.check-prop "p" [r.int 1 10] [var [[n] "aql:math" import end   def x (n math.log)   true]] 3 1 0 end   test.fail-count end print'
1
{name:'p' ok:false runs:1 ... error:error(CallAQL: [aql/undefined_word]: undefined word: math)}
```

`5b983b6`'s commit `489a1d9` ("propagate native-module Resolver into
file-imported modules") fixed this for *file* sub-imports, but the
property body's sub-engine doesn't inherit either.

**Workaround:** import `aql:math` at the top of the test file, before
`test.check-prop`.

**Suggested fix:** the same fix that landed for file imports —
`InheritConfig` / `InstallResolver` — applied to the sub-engine that
`test.check-prop` constructs for the gen/property bodies.

---

### §11b.2 — Single-character variable names collide in property bodies [open]

Naming a variable `p` inside a property body caused the property to
fail under the framework but pass when copy-pasted to the REPL.
Renaming to `payload` fixed it.

**Reproducer (within a property body):**

```aql
[var [[s]
  def bf ({n: 100, p: 0.05} Bloom.make end)
  def _ (bf s Bloom.add end)
  def p (bf Bloom.encode end)            # <-- single-char name
  "n:100" p indexof 0 gte                # <-- returns wrong result
]]
```

Rename `p → payload` and the same property passes.

**Expected:** any non-keyword identifier should work.

**Workaround:** prefer multi-character variable names in property
bodies. The library's tests use `payload`, `n-val`, `m-val`,
`bf-params`, etc.

**Suggested fix:** characterise the collision properly; it may be
related to how `p:` keys in the encoded string interact with parser
lookahead inside a quoted body.

---

### §11b.3 — Pair generators require `r.list-of`, not adjacent calls [partial]

The natural reading "generate two strings, pack into a pair" doesn't
work because the gen body must leave one value.

**Reproducer (wrong):**

```aql
test.check-prop "p"
  [r.string "abc" 6  r.string "abc" 6]   # leaves two values on stack
  [drop drop true]
  10 1 0 end
```

The framework reports `gen produced N values, expected 1`.

**Working form:**

```aql
test.check-prop "p"
  [r.list-of [r.string "abc" 6] 2]       # one List value
  [var [[pair] ...]]
  10 1 0 end
```

**Expected:** HOWTO covers PBT (it doesn't), and shows `r.list-of` /
`r.map-from` for compound inputs.

**Workaround:** read `lang/go/modules/test_pbt_test.go` for examples.

**Suggested fix:** add a HOWTO §"Write property tests" page covering
the gen/property convention, the `r.*` generators, and `r.list-of` /
`r.map-from`.

---

### §11b.4 — No `test.only` / `test.skip` for iterative work [open]

When iterating on one property, you have to comment out the other
six. There's no focus-or-skip mechanism.

**Reproducer:** look at the workflow — every iteration of
`test/bloom_pbt.aql` runs all seven properties even if you're
debugging one.

**Expected:** `test.only "name" …` runs only the named property;
`test.skip "name" …` excludes it.

**Workaround:** comment out properties.

**Suggested fix:** add `test.only` / `test.skip` as drop-in
replacements for `test.check-prop` that update the framework's filter
list.

---

### §11b.5 — `test.results` table is verbose [partial]

The default `test.results` rendering is 9 columns × N properties of
`name | path | ok | expected | actual | error | duration-ms` plus the
full `PropertyResult` map dump. Hard to read in CI logs.

**Reproducer:** see the `--- results ---` section of any
`aql test/bloom_pbt.aql` run.

**Expected:** a one-line-per-property pass/fail summary by default;
verbose output behind a flag.

**Workaround:** extract `name` and `ok` manually:

```aql
test.results end each [
  var [[r]
    if (r "ok" get) [
      `  pass: ${r "name" get}` print
    ] [
      `  FAIL: ${r "name" get}` print
    ]
    0
  ]
]
```

**Suggested fix:** add `test.summary` (or change `test.results`'s
default rendering) to a one-line-per-property format.

---

## §5.2 / §9.5 — `aql help` examples are auto-generated permutations [open]

The examples shown by `aql describe <word>` for non-trivial words are
auto-generated positional permutations that teach nothing.

**Reproducer:**

```
$ aql describe set | grep -A 6 "Examples:"
Examples:
  set 'a' 2 2   ;# ...
  2 set 'b' 3   ;# ...
  2 4 set 2     ;# ...
  3 5 a/q set   ;# ...
  set b/q 6 3   ;# ...
```

None of these illustrate the canonical `obj value key set` pattern
that the library and HOWTO actually use.

**Expected:** for `set`/`get`/`make`/`fold`/`each`/`import`/`export`,
the examples are hand-authored against realistic operands.

**Workaround:** ignore the examples; read HOWTO and
`lang/go/test/check_fixtures/*.aql` instead.

**Suggested fix:** in the `Examples:` slot of each registered word,
allow an opt-in hand-authored list that wins over the auto-generated
one. Start with the ~20 most-called words.

---

## §9.7 — Subtype instances print fields in alphabetical order [open]

`Bloom.params` and the rendered BloomFilter look almost identical;
only field-presence distinguishes them. Diffing two `print` outputs is
harder than necessary.

**Reproducer:**

```
$ aql /home/user/bloom-filter/smoke.aql 2>&1 | grep -E "(params|Object)" | head -2
params:   {"k": 7, "m": 9586, "n": 1000, "p": 0.01}
# elsewhere: Object/BloomFilter{added:2 k:7 m:9586 n:1000 p:0.01 set:[...]}
```

Both alphabetical (`k, m, n, p`). The Object/BloomFilter's `added` and
`bits` fields, declared *first* in `refine Object`, render *last*.

**Expected:** declaration order. Users laying out fields in a
meaningful sequence shouldn't have that sequence lost at print time.

**Workaround:** none for `print`. Users have to write a custom
formatter.

**Suggested fix:** in the Object pretty-printer, walk fields in
`Type.Fields` order (which is declaration order) instead of
`oi.AllFields()` sorted.

---

## §9.8 / §9.9 — No native `hash` / `xxhash` / `ord` / `chr` [open]

Every probabilistic-data-structure library has to roll its own
char-code-via-`indexof` plus a pure-AQL hash. Slow and ASCII-only.

**Reproducer (current library workaround):**

```aql
def alphabet " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

def code-at fn [
  [i:Integer s:String] [Integer] [
    def c (s slice i (i add 1))
    def idx (c alphabet indexof)
    idx 32 add
  ]
]
```

`O(95)` per char lookup, ASCII-only, breaks on any non-printable
input.

**Expected:** `convert Integer "A"` returns the codepoint, or
`aql:bin` exports `ord` / `chr`. Likewise `aql:bin` or `aql:hash`
exports `fnv32` / `fnv64` / `xxhash64`.

**Workaround:** the printable-ASCII alphabet trick (above) plus an
FNV-1a polyfill (`bloom.aql`'s `fnv-step`).

**Suggested fix:** extend `aql:bin` with `ord`, `chr`, and one good
non-cryptographic 64-bit hash. Every cache/dedup/sketch library will
need them.

---

## §9.3 — `print`/`printstr` output order is non-deterministic [open]

Mixed `print` + `printstr` produces output that doesn't always match
source order, presumably due to stdout buffering or eval-order quirks.

**Reproducer:**

```
$ aql do '"hi" printstr 99 print'
99hi     # 99 appears before "hi" even though "hi" was pushed first
```

**Expected:** stdout reflects evaluation order.

**Workaround:** stick to `print`-only output (each line gets a
newline); avoid `printstr` for anything that matters.

**Suggested fix:** unbuffer stdout in interactive/script modes, or
share a single `bufio.Writer` so the two words don't interleave
through different buffer paths.

---

## Priority order (recap)

1. **§6.2** — `if` mixed-form (three-character repro, traps every new
   user; single-handler fix)
2. **§4.3** — `aql check` cross-import noise (blocks CI gating)
3. **§6.1** — full fix (stack-precedence default for user fns) so
   `end` isn't needed everywhere
4. **§1.1** — `go install` (release engineering)
5. **§9.1** — `printstr` consumes its arg
6. **§11b.1** — propagate native modules into `test.check-prop`
   sub-engines
7. **§7.4** — indexed `for-do` (closes the each-must-push-a-value
   workaround)
8. **§7.3** / **§5.2** / **§9.5** — doc + hand-authored help examples
9. **§8.3** — `export` as a top-level no-op
10. **§9.7** — declaration-order field rendering
11. **§9.8** / **§9.9** — `aql:bin` extensions
12. **§9.3** — output ordering
13. **§11b.2** / **§11b.3** / **§11b.4** / **§11b.5** — PBT polish

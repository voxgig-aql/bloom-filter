# AQL Developer Experience Report

Built against `aql-lang/aql @ 12a31e6` (HEAD on `main`, 2026-05-28),
installed via `go install … /cmd/go/aql` from the cloned source. The
target was a minimal bloom-filter library — BloomFilter as a subtype
of `Object`, Options-style constructor, `aql:test`-driven tests. What
follows is an exhaustive list of the friction encountered, with
reproducible examples and concrete recommendations.

The report is long on purpose; it's meant to be a single document the
team can mine for issues rather than a polished essay.

---

## 0. Executive summary

The biggest pain points, ranked by how much time they cost:

1. **First-parameter-is-top-of-stack convention is inverted in the
   docs.** `HOWTO.md` line 80 shows `3 4 show => '3 and 4'`. Real
   output is `'4 and 3'`. Every fn signature has to be flipped from
   the documented intuition.
2. **Forward precedence eats subsequent words silently.** Any time a
   user-defined word is followed by another word (including
   `print`, `assert.equal`, `if`, `def`, …) the first word collects
   the second as a positional arg. The fix is `end`, which has to be
   sprinkled on virtually every call.
3. **Sub-imports cannot reach native modules.** `"aql:math" import`
   only works from the top-level script. A file imported via
   `"./lib.aql" import` cannot itself import `aql:math`, so any
   library that wants `log`/`ceil`/`round`/etc. has to live in the
   same file as its caller. This collapses the whole module story.
4. **Custom-subtype names in `fn` signatures break dispatch.** Type
   annotations like `bf:BloomFilter` (where `BloomFilter` is a
   user-defined `refine Object` type) fail to accept their own
   instances; the only working annotations are `Any`, `Object`,
   `Map`, primitives. So the type system contributes no static
   safety on top of `Any` for user types — but it does contribute
   silent dispatch failures that look like syntax errors.
5. **Lists don't survive `def`.** `def xs [1,2,3]` doesn't bind `xs`
   to the list value; every later reference to `xs` re-evaluates the
   literal and pushes its elements *individually* onto the stack.
   Folds, prints, and pretty much everything that wants a List value
   then fail with confusing signature errors.
6. **`type X object { …, method: [body] }` is shown as the
   primary OO pattern in HOWTO** but neither `type` (it's undefined)
   nor inline method dispatch (`c inc` with `inc` declared inside
   the object body) works in this build. The closest path that
   compiles is `def C refine Object { … }` plus a free `fn` that
   takes the instance as a parameter.

The good news: once you've internalized these six gotchas, AQL is
expressive enough to write the library. The bad news: every one of
those gotchas is invisible from the docs and surfaces as an opaque
signature error in a fn body deep inside the file.

---

## 1. Installation

### 1.1 The README install command doesn't work

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

### 1.2 Version goes silent without `-ldflags`

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

### 2.1 Stack convention is inverted

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

### 2.2 `for` doesn't match its documented signature

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

### 2.3 `fold` arg order

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

### 2.4 `type X object { … }` syntax

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

### 2.5 `make Counter` versus `make Counter {}`

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

### 2.6 `import "aql:math"` doesn't import bare names

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

### 2.7 `aql:test` is only partially documented

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

### 2.8 README import-from-file example

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

### 3.1 `.` is not a valid character in map-literal values

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

### 3.2 Map-literal values inside fn bodies don't eagerly resolve

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

### 3.3 Engine panic on certain merge bodies

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

### 3.4 Body-list contents printed on dispatch failure

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

### 3.5 Line numbers in errors lag the actual call site

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

---

## 4. Type system

### 4.1 `Options` as a parameter type breaks dispatch

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

### 4.2 Custom subtypes as fn parameter/return types break dispatch

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

### 4.3 `aql check` produces many false positives

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

### 4.4 Field name and method name share a namespace

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

### 5.1 First-param is top-of-stack (already covered §2.1)

Restating because it deserves a separate slot: with sig
`[a:Integer b:Integer]`, the call `3 4 f` binds `a=4, b=3`. Most
non-stack-language programmers will write code assuming the
opposite for at least a day.

### 5.2 `set` arg order is *not* `obj key value`

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

### 5.3 `def name value` doesn't evaluate `value`

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

### 5.4 `var [[i] body]` is the idiomatic stack pop, but never shown

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

---

## 6. Forward precedence: the dominant source of bugs

Forward precedence — words look ahead for arguments — is documented
in EXPLANATION.md and the Reference, but its real impact on
practical code is understated.

### 6.1 Every user fn collects the next word

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

### 6.2 `if` branch order is documented but the runtime takes the wrong branch

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

### 6.3 Inline arithmetic body trick

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

### 6.4 `import` grabs the next string

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

### 7.1 Lists don't survive `def`

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

### 7.2 Maps are immutable; only Object can be mutated

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

### 7.3 Object field defaults don't construct nested Objects

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

### 8.1 Sub-imports cannot resolve native modules — the show-stopper

The plan called for a layered structure: `bloom.aql` defines and
exports the API, `index.aql` imports it and demos. That broke
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

### 8.2 `import 'module [body]` syntax surprise

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

### 8.3 `export` only works during an import

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

### 9.1 `printstr` leaves its argument on the stack

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

### 9.2 `convert String i` order isn't what you'd guess

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

### 9.3 Output reordering between `print` and `printstr`

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

### 9.4 `length` only works on Lists; strings need `size`

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

### 9.5 Help examples are auto-generated and unhelpful

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

### 9.6 `aql check` output dwarfs the actual error count

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

### 9.7 Subtype instances printed with `Object/Foo{...}`

The print form is `Object/BloomFilter{added:0,bits:Object/Bits{},k:7,m:9586,n:1000,p:0.01}`.
The `Object/` prefix is informative but the field order is
alphabetical, not declaration order, which makes diffs against
`bloom-params` output (which is also alphabetical) confusing —
the two look the same shape but the encode payload has different
keys.

Stable, declaration-order output would help.

### 9.8 No native hash function

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

### 9.9 No char-to-int conversion

```
$ aql do 'convert Integer "h"'
error: convert: cannot convert "h" to number
```

To get the codepoint of a character, the only path I found was the
printable-ASCII alphabet trick: `alphabet c indexof 32 add`. This
is brittle (non-ASCII silently maps to wrong codes) and slow
(`O(95)` per char). Built-in `ord`/`chr` words on `Scalar` would
help.

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

---

## 11. Recommendations summary (prioritised)

**P0 — show-stoppers for library authors:**

1. Sub-imports must be able to load native modules (`aql:math` etc.)
   §8.1.
2. Fix or document the HOWTO Counter example: either `type X object`
   needs to compile and `c inc` needs to dispatch, or the example
   needs replacing with a `def C refine Object` + free-fn pattern
   that actually runs. §2.4.
3. Custom subtype names must work in fn signatures. The current
   silent dispatch failure (§4.2) makes user types useless for
   anything beyond pretty-printing.
4. `aql:test` chained calls must not leak stack state. §10.

**P1 — major doc fixes:**

5. Stack convention example in HOWTO §"Write a typed function" must
   match runtime behaviour. §2.1.
6. `for 5 [dup mul]` must work, or the HOWTO example must change.
   §2.2.
7. `fold` arg-order example must work as written. §2.3.
8. `aql help` examples must be hand-authored, not auto-permutations.
   §5.2, §9.5.
9. README's `go install` command must work against a fresh clone.
   §1.1.

**P1 — runtime/parser correctness:**

10. Forward `if` dispatch picks the wrong branch. §6.2.
11. Engine panic on dot-access in merge-body shapes — recover and
    surface a typed error. §3.3.
12. `Options` as parameter type breaks dispatch. §4.1.
13. `def name [list-literal]` should preserve the list value or
    warn clearly. §7.1.

**P2 — DX improvements:**

14. When a fn dispatch fails on a forward-collected `word` arg,
    suggest `end`. §6.1.
15. When `def name foo` binds to the literal word, suggest
    `def name (foo)`. §5.3.
16. Error positions should point to the call site, not the last
    similar-shaped body. §3.5.
17. `aql check` should stop producing 262 errors on a passing file.
    §4.3, §9.6.
18. Add `ord`/`chr` and a real `hash`/`xxhash`. §9.8, §9.9.
19. Subtype instance printing in declaration order. §9.7.
20. `printstr` should consume its argument or document that it
    doesn't. §9.1.

**P3 — language-level wishes:**

21. A constructable mutable Array, so bit arrays and similar can
    be packed instead of sparse-mapped. §7.2.
22. Field declarations that combine type and default value cleanly
    for nested Objects. §7.3.
23. `var [[i] body]` as the documented stack-pop pattern in
    iteration. §5.4.

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

# JS Roadmap: test262 at 100%

Part 9 left lib/js as a working engine with a test262 floor. This document
plans the path from there to **every test262 test passing**, with nothing
skipped. It sits beside ROADMAP.md (Part 9 history, design decisions) and
uses the same rules: phases land one at a time, each phase raises floors,
and a floor is never lowered without a reason in the commit.

Numbers below are from `./run.sh --test262` on 2026-11-25: commit 0549197
plus the uncommitted Iterator work, test262 pinned at 2e58f87 (2026-11-11).

---

# What "100%" means

**Target (the gate):** every ECMA-262 test of the pinned test262 commit
passes in every mode its flags ask for (sloppy and strict, `module`, `raw`,
`async`): `test/built-ins`, `test/language`, `test/annexB` and
`test/harness`, **48 914 files**. A test counts once, as test262-harness
counts files. Nothing is in the skip list.

- **Proposals count.** test262 carries tests for proposals that aren't
  finished yet (Temporal, ShadowRealm, import-defer, decorators and others)
  behind `features:` tags. At a pinned commit their tests are fixed, so the
  cost is only implementing them, plus rework if a proposal changes before
  it's finished. They're in the gate, scheduled after the finished features.
  T13 sets the policy for new tags when the pin moves.
- **Hosts count.** Tests that need `$262.agent` (threads), `$262.createRealm`
  (more than one realm) or `$262.IsHTMLDDA` are in the target too. The runner
  has to provide those hooks.
- **Everything once "not planned" is now planned** (decided 2026-11-25):
  the "Not planned for Wiffer" block in `lib/js/tests/jstest262_skip.swift`
  goes. Tail calls, IsHTMLDDA, decorators, ShadowRealm, Atomics/SAB,
  Temporal and the rest each have a phase below.

**Tracked, not gated: `test/intl402`** (3 394 files). ECMA-402 is a
separate spec, and getting all of it to 100% is the most expensive part of
the suite: about 2 040 of the files are Temporal with non-ISO calendars
(Hebrew, Chinese, Islamic, ...) and named time zones, and the rest want a
large share of CLDR. Intl gets a web-shaped goal instead (T12): the
constructors sites use, with CLDR data for about 20 common locales. intl402
has its own floors that only rise, but it isn't part of "100%".

**Excluded: `test/staging`** (1 487 files, 1 409 of them SpiderMonkey
imports). test262 says those tests aren't reviewed yet, so no engine is
scored on them. T13 runs it for information only.

---

# Where we are

| Scope | Files | Pass | Fail | Skip |
|---|---:|---:|---:|---:|
| built-ins + language + annexB (run today) | 48 797 | 38 849 | 1 525 | 8 423 |
| harness (not run) | 117 | — | — | — |
| **Gate total** | **48 914** | **38 849 (79.4%)** | | |
| intl402 (not run; tracked, not gated) | 3 394 | — | — | — |

Against the files the runner already covers, that's 79.6% passing, 3.1%
failing and 17.3% skipped. Parse-only runs are clean: language parse is
23 785 pass, 0 fail. The RegExp parse run has 46 failures, all properties
of strings in `v`-mode (`\p{RGI_Emoji}` and similar).

**Where the 1 525 failures are:**

| Bucket | Failures | Phase |
|---|---:|---|
| Runner has no module loader for scripts (`import()` from a script test) | ~263 | T0 |
| Annex B function-in-block semantics (B.3.2) in eval, global and function code | ~485 | T1 |
| Scope and references: default-param scopes, `with`, compound assignment, completion values, global declaration errors | ~240 | T2 |
| Classes: fields, private names, `super` in initializers, subclassing | ~175 | T3 |
| `Function.prototype.toString` source text | 32 | T3 |
| `Error.prototype.stack` accessor (`error-stack-accessor`, not skipped) | 33 | T4 |
| Destructuring iterator protocol (`dstr`) | ~44 | T2 |
| Small built-in tail (bind, %ThrowTypeError%, JSON, Array, Math.f16round, AsyncFromSyncIterator, TypedArray `with`, ...) | ~60 | T4 |
| Other language odds and ends | ~190 | T2/T3 |

**Where the 8 423 skips are** (by the first matching reason):

| Skip reason | Tests | Phase |
|---|---:|---|
| Temporal | 4 624 | T11 |
| slow: code point sweep (`regExpUtils.js`) | 586 | T0 |
| explicit-resource-management | 426 | T6 |
| iterator-helpers (in progress, uncommitted) | 410 | T5 |
| Atomics, SharedArrayBuffer, Atomics.waitAsync, Atomics.pause | 607 | T9 |
| import-defer, source-phase-imports | 503 | T7 |
| regexp-modifiers, regexp-duplicate-named-groups, legacy-regexp, RegExp.escape | 292 | T5 |
| cross-realm, `$262.createRealm` | 177 | T8 |
| import-attributes | 100 | T7 |
| Array.fromAsync, await-dictionary | 184 | T6 |
| joint-iteration, iterator-sequencing, upsert | 194 | T5 |
| uint8array-base64, immutable-arraybuffer | 117 | T5 |
| ShadowRealm | 64 | T8 |
| tail-call-optimization | 35 | T10 |
| IsHTMLDDA | 35 | T12 |
| decorators | 24 | T12 |
| json-parse-with-source, Error.isError, Math.sumPrecise, nonextensible-applies-to-private | 45 | T5 |

---

# Ground rules

- **The skip list only shrinks.** Every phase ends by deleting its tags from
  `jstest262_skip.swift`. A skip is not a pass: the results report it as
  "not yet", and the phase isn't done while any of its tests are skipped.
- **Floors and ceilings.** `test262-floor.txt` keeps pass floors. T0 adds a
  skip *ceiling* per directory, so a test can't quietly move from fail to
  skip.
- **Fix the engine, not the test.** No per-test special cases. When a
  failure is really a runner bug, fix the runner and say so in the commit.
- **Hostile-input rules stay.** Nothing in this plan relaxes JSLimits, the
  "no Swift recursion per JS call" rule, the interrupt budget or the
  no-trap rule. New features get the same fuzz and gc-stress coverage as
  9J. Each phase adds its directories to the gc-stress sample.
- **Performance stays.** `jsbench_tests.swift` and the 9J perf numbers are
  checked at the end of every phase. A conformance fix that costs more than
  5% on the benchmarks needs a note in the commit.
- **Embedded Swift.** Everything has to build for the kernel/user target,
  not just hosttest. Large data (Unicode, CLDR, tzdata) is generated into
  tables by Python scripts in `lib/js/tools`, like the existing
  `js*tables.swift`.

---

# Phases

```
T0 runner: whole suite, honest counts
 ├─→ T1 Annex B functions in blocks ─┐
 ├─→ T2 scopes, references, completions ─→ T3 classes, toString
 ├─→ T4 built-in tail                │
 ├─→ T5 small finished features ─────┤
 │      └─→ T6 resource mgmt, async iteration
 ├─→ T7 module proposals             │
 ├─→ T8 realms (one heap, many realms) ─→ ShadowRealm
 ├─→ T9 agents and shared memory     │
 ├─→ T10 proper tail calls           │
 ├─→ T11 Temporal ───────────────────┼─→ T12 host hooks, decorators; Intl for the web
 └───────────────────────────────────┴─→ T13 100%, staying there
```

T1–T4 are mostly fixes inside the existing design. T8, T9 and T11–T12
are the big architectural or data-heavy pieces. Start them early in
parallel if more than one person is working on this.

## Phase T0: the runner covers everything

**Status: complete (2026-11-25).** The expanded pinned suite reports all
48,914 gated files: **39,757 pass / 1,318 fail / 7,839 skip**. Intl is tracked
separately: **691 pass / 2,703 fail / 0 skip**. Staging is opt-in and excluded
from both totals. Floors and full-run skip ceilings are recorded; no pass
floor was lowered.

Script imports now use a file-backed loader, including eval-relative imports;
real host time lets import evaluation timing tests finish. There are no
missing-loader errors or timeouts. Ten dynamic-import namespace failures
remain engine semantics scheduled for T7, rather than loader failures.
Negative tests check both phase and exact constructor name. Runner selftests
cover raw, async imports, resolution errors, negative-phase/type spoofing,
CanBlock capability selection and non-deterministic failures. CanBlock is
explicit host state ready for T9's Atomics implementation; T0 does not add
threads or shared memory. T8/T9 hooks throw explicit Test262Errors.

Results include directory timings, scoped feature counts, gated skips by
phase, and Intl failure reasons. Unicode sweeps run under the normal budget:
with the existing -Osize binary, full-range buildString took 85 ms;
construction plus ten property matches took 145–161 ms. All twelve
CharacterClassEscapes subgroup tests passed in 1,563 ms, so no blanket slow
override is justified by these measurements.

Validation: freestanding Embedded build; host sample **4,487 checks, zero
failures**; full run **4,493 checks, zero failures**; floors/ceilings;
GC stress (391 tests, zero differences); and full benchmarks
(Richards 113 ms, DeltaBlue 231 ms, JSON 58 ms, regex 91 ms, strings 33 ms).
These benchmark times are below the recorded 9J host timings, but the hardware
is different, so they are not a controlled performance comparison. T0 changes
only the host runner, reporting and fetch configuration. The existing engine
and Iterator work is preserved. Optional staging discovery was checked with a
filtered Temporal staging test and kept outside the gate.

**Goal:** one command reports pass/fail for all 48 914 gated files plus
intl402, and the counts are honest.

- **Fetch more.** `fetch_test262.sh` adds `/test/intl402/`, `/test/harness/`
  and `/test/staging/` to the sparse set (bump the `SET` suffix). The runner
  picks up `intl402` and `harness` (`staging` only with
  `WIFFER_TEST262_STAGING=1`).
- **A module loader for script tests.** Script tests that call `import()`
  fail with "no module loader": about 263 failures, most of
  `language/expressions/dynamic-import` and `language/module-code`. Give the
  runner a file-backed loader, resolving relative to the test's directory,
  for scripts as well as modules. Fixture files with syntax errors must
  reject with SyntaxError (32 of those failures are TypeError vs SyntaxError).
- **Slow tests run.** 586 tests skipped as "slow: code point sweep" (the
  `regExpUtils.js` include) must run. First profile `buildString` and the
  `\p` matching path under `-Osize`. If a test still takes over a second,
  give it a per-test budget override (a `slow` list with a bigger
  timeout), not a skip. Keep the per-directory timing in the results file.
- **Flags complete.** Check `raw`, `CanBlockIsFalse`/`CanBlockIsTrue`,
  `non-deterministic` and `negative.phase: resolution` handling against
  test262's INTERPRETING.md. Add a selftest per flag.
- **Reporting.** Results by feature tag as well as by directory
  (`test262-features.txt`), so each phase can see its own number. Add a
  skip ceiling column to `test262-floor.txt` (`<dir> <full> <sample>
  <skip-ceiling>`).
- **Stubs for later hooks.** `$262.agent` and `$262.createRealm` exist and
  throw a clear "not yet: T8/T9" Test262Error, so those tests fail visibly
  instead of being skipped. (Keep the skips in place until T8/T9, but count
  them by phase.)

**Done when:** `./run.sh --test262` runs built-ins, language, annexB,
intl402 and harness; slow tests are not skipped; the ~263 loader failures
pass; floors and skip ceilings are recorded. Expect about +700 passes.

## Phase T1: Annex B functions in blocks

**Status: complete (2026-11-26).** `annexB/language/*` has 0 failures (was
423) and `language/global-code` has 0. Full run: **40,259 pass / 816 fail /
7,839 skip** (+437 passes, no directory regressed). Floors raised.

- The parser wraps a clause function (`if (x) function f() {}`) in a
  synthetic block, so it gets its own scope like any block function.
- Switch cases instantiate their functions before any case selector runs.
  (They used to be emitted after the dispatch jump, so they never ran.)
- The var binding is skipped for `arguments` in function code. A simple catch
  parameter does not block it (B.3.5).
- Script and eval code run every declaration check before creating
  anything, via the `checkDeclare` op: lexical conflicts,
  CanDeclareGlobalFunction / CanDeclareGlobalVar, and eval's walk up to the
  variable environment, which skips catch parameters (B.3.4).
- In script and eval code, the Annex B var is created at run time
  (`declareAnnexB`) only if no enclosing environment or global lexical
  binding has the name and the global can take it. A flag guards the copy,
  and in eval the copy goes to the variable environment (`putVarName`).
- `f() = x`, `f() += x` and `for (f() in o)` call `f`, then throw a
  ReferenceError before the right side is evaluated.

The 10 `language/eval-code` failures left are not var hoisting. Eight are
eval inside arrow-function parameters declaring `arguments` (parameter
scopes, T2). The other two are `new.target` and `super` in direct eval.

**Goal:** B.3.2 (block-level function declarations web legacy semantics)
right in all three places: function code, global code and eval code
(direct and indirect).

- About 485 failures in `annexB/language/{eval-code,global-code,function-code}`,
  plus some of `language/eval-code`. The typical messages are "An initialized
  binding is not created prior to evaluation", `f is not defined`,
  "binding value is updated following evaluation" and
  `typeof f === "undefined"`.
- The spec work, in the compiler's scope analysis (`jsscope.swift`):
  - For each block-level function in sloppy code, decide whether replacing
    it with `var F` would cause an early error: a conflict with a lexical
    binding, a parameter name (functions), or `arguments`. The "skip-early-err"
    tests cover each kind (for, for-in, for-of, switch, try/catch).
  - If not, create the var binding (initialized to `undefined`) at function,
    global or eval entry, and copy the block's function value into it when
    the declaration is evaluated.
  - Global code: B.3.2.2 changes to GlobalDeclarationInstantiation
    (CanDeclareGlobalFunction / CanDeclareGlobalVar, configurable globals).
  - Eval code: B.3.2.3 changes to EvalDeclarationInstantiation, including the
    walk up the variable environments for lexical conflicts. Direct eval inside
    functions is the hard case: the var lands in the function's variable
    environment, which the compiler has to make dynamic when there's a
    direct eval.
- Also `if (x) function f() {}` (B.3.3, FunctionDeclarations in IfStatement
  clauses) and the `switch` case/default versions.

**Done when:** `annexB/language/*` has 0 failures, and `language/eval-code`
has none left that come from var hoisting.

## Phase T2: scopes, references and completion values

**Goal:** the remaining runtime-semantics failures in `language/` that come
from environments and references.

- **Parameter scopes** (about 80: `dflt-params-ref`, `*-paramsbody-var`,
  `scope-head-lex`, `scope-body-lex`): a function with parameter
  expressions gets a separate var environment for its body (FunctionDeclarationInstantiation
  step 28). Parameters are in TDZ while their initializers run
  (`dflt-params-ref-later`, `-self`). A closure in a default value sees the
  parameter scope, not the body's `var`s. Same for methods, generators,
  async functions, arrows and class methods.
- **Named function expressions:** the name binding is immutable. Assigning
  to it in strict code throws TypeError and is ignored in sloppy code
  (`named-strict-error-reassign-fn-name-in-body*`).
- **References evaluated once and in order** (about 90, mostly
  `compound-assignment`, `logical-assignment` and `++`/`--`): `o[k] op= v`
  must call ToPropertyKey(k) once
  (`left-hand-side-property-reference-topropertykey-once`), and must resolve
  the binding before evaluating the right side, then use that same
  reference even if a `with` object or the global loses the binding
  (`S11.13.2_A5.*`, "Expected a TypeError but got a Test262Error"). That
  probably needs a "resolved reference" bytecode pair (resolve, then get/put
  through the saved base) used by every compound form.
- **`with` and object environments** (12): `Symbol.unscopables` read once per
  lookup in the right order, HasBinding re-checked at set time, the
  proxy-environment trap order tests.
- **Completion values** (about 54 `cptn-*`): `eval` of `while`, `do`,
  `for`, `switch`, `if`, `try`, `with` and blocks returns the spec's
  UpdateEmpty result. The compiler keeps a completion register only for
  code whose value is observable (eval and script top level).
- **Global declarations** (`script-decl-*`, `assign-to-global-undefined`):
  GlobalDeclarationInstantiation's TypeError/SyntaxError checks against
  non-configurable globals and existing lexical declarations across
  scripts (`$262.evalScript`).
- **Destructuring** (about 44 `dstr`): IteratorClose on abrupt completion
  and on early stop, `next` cached once (`iterator.next is not a
  function`), elision and rest stepping counts, and the
  `assignment/destructuring` order of evaluation.
- **`for-in`/`for-of` heads:** `head-let-bound-names-fordecl`,
  `head-const-bound-names-fordecl` early errors, and the TDZ scope for the
  head expression.
- **Annex B `f() = 1`** (`assignmenttargettype/callexpression*`): in sloppy
  code a call expression as an assignment target is a runtime
  ReferenceError, not an early error.

**Done when:** `language/expressions` and `language/statements` have no
failures outside class/function-toString tests (left to T3).

## Phase T3: classes, private names and `Function.prototype.toString`

**Goal:** every class and function-source failure fixed.

- **Fields** (about 150 in `class/elements`): computed field keys evaluated
  once at class definition time and turned into own properties
  ("Symbol() should be an own property", "not initialized should be an own
  property"). `super` property access is allowed in field initializers and
  static blocks. `arguments` in an initializer is an early error. Field
  initializers run with the right `this` and home object.
- **Private names:** private names visible inside direct `eval` in a class
  body ("private name '#m' outside a class"), early errors for undeclared
  names that also cover nested classes and `eval`, `#x in obj`, private
  methods not writable, private accessors without a setter throw TypeError.
- **Class scoping:** the class binding is immutable inside the class
  ("inside" vs "outside" tests), in TDZ during `extends`, and the heritage
  expression is evaluated in the class scope.
- **Subclassing:** `super()` called twice throws ReferenceError after the
  second construction. `this` is in TDZ before `super()`. Derived
  constructors that return a non-object throw. `new.target` flows through.
- **Method `name` values:** names for symbol keys, getters and setters
  (`get foo`), and anonymous functions assigned to computed keys
  (`expressions/object/method-definition`).
- **`Function.prototype.toString`** (32): keep the exact source slice for
  every function form (methods, getters, setters, async, generators, class
  bodies, computed keys, comments between tokens). The parser already has
  source positions; the function object needs (start, end) into a kept copy
  of the source. Make that copy cheap (share the script's byte buffer, don't
  copy per function). Native functions must match the NativeFunction
  grammar.

**Done when:** `language/{statements,expressions}/class` and
`built-ins/Function/prototype/toString` have 0 failures.

## Phase T4: built-in tail

**Goal:** every failure under `built-ins/` and `annexB/built-ins/` that
isn't a missing feature.

- **`Error.prototype.stack`** (33, tag `error-stack-accessor`): a
  getter/setter pair on Error.prototype, with the stack string kept in an
  internal slot. The getter for non-Error receivers, the setter round trip,
  and own-property shadowing. Use the VM's existing frame information.
- **`Function.prototype.bind`** (7): TypeError for non-callable targets, and
  length/name read through getters in order.
- **%ThrowTypeError%** (5): one frozen intrinsic per realm, with non-configurable
  `length` and `name`, used for `arguments.callee` in strict functions and
  for `caller`/`arguments` on Function.prototype.
- **JSON** (9): `parse` reviver ordering with Proxy holders, errors thrown
  from `toJSON` or getters propagating, `stringify` with Proxy objects
  (`{"a":1,"b":1}`).
- **Array** (8): `length` define-own-property coercion order (ToNumber
  twice, per spec), `concat` with a revoked proxy, `splice` and `unshift`
  past 2^53-1 and their species trap order, `toString` when `join` isn't
  callable.
- **Math.f16round and Float16Array** (5): finish binary16 (round half to even
  through double, not float) and the `Math` property.
- **AsyncFromSyncIteratorPrototype** (8): close the sync iterator when
  `next`/`throw` produce a rejected promise.
- **Small items:** TypedArray `with` shrink coercion (2, noted as a 9E
  gap), `Object.freeze` on TypedArrays with elements, `Promise.try`,
  `Symbol` and `GeneratorFunction` misc, and annexB RegExp
  `source` escaping of lone surrogates (`\ud800`, not U+FFFD: a
  string-conversion bug at the edge).

**Done when:** `built-ins/*` and `annexB/built-ins/*` have 0 failures
(skips aside). With T1–T3 that makes the "fail" column 0 everywhere in the
current scope.

## Phase T5: small finished features

**Goal:** delete the skip tags for library features that need no new
architecture. Work in this order, each its own commit with floors:

1. **iterator-helpers** (410 skipped, in progress in the working tree):
   finish `map`/`filter`/`take`/`drop`/`flatMap`/`reduce`/`toArray`/
   `forEach`/`some`/`every`/`find`, `Iterator.from`, the
   `%WrapForValidIteratorPrototype%`, and `return()` forwarding. Then
   delete the tag.
2. **RegExp:** `regexp-modifiers` (230: `(?i:...)`, `(?-m:...)`, scoped flags
   in the compiler), `regexp-duplicate-named-groups` (16: same name in
   different alternatives, `groups` picks the one that matched),
   `RegExp.escape` (20), `legacy-regexp` (26: `RegExp.$1`–`$9`, `lastMatch`
   and friends with the subclass/realm restrictions). Plus properties of
   strings in `v` mode (`\p{RGI_Emoji}`, `Basic_Emoji`, ...: the 46 RegExp
   parse failures). That needs emoji sequence tables generated from
   `emoji-sequences.txt` and `emoji-zwj-sequences.txt`, at the same Unicode
   version as the existing tables.
3. **Small built-ins:** `Error.isError` (12), `Math.sumPrecise` (10, exact
   summation, Shewchuk or a fixed-size bigint accumulator),
   `json-parse-with-source` (21, `context.source` in the reviver and
   `JSON.rawJSON`/`isRawJSON`), `uint8array-base64` (70, `toBase64`/
   `fromBase64`/`toHex`/`fromHex`/`setFrom*`; lib/crypto may already have
   codecs worth sharing), `upsert` (72, `getOrInsert`/`getOrInsertComputed`
   on Map/WeakMap), `immutable-arraybuffer` (47, `transferToImmutable` and
   checks in every TypedArray/DataView writer), `iterator-sequencing` (40,
   `Iterator.concat`), `joint-iteration` (82, `Iterator.zip`/`zipKeyed`),
   `nonextensible-applies-to-private` (2).

Before each item, check its tag's status in test262's `features.txt` and
the proposal's spec text at the pinned commit. Implement what the tests
test, not an older draft.

**Done when:** none of these tags is in the skip list, and the RegExp parse
run is 0 fail.

## Phase T6: resource management and async iteration

**Goal:** `explicit-resource-management` (426 plus 53 in staging),
`Array.fromAsync` (95), `await-dictionary` (89).

- **`using` and `await using` declarations:** parser (`using` is
  contextual: `using [x]` is not a declaration; no `using` at the top of a
  script), early errors, and the compiler lowering each block with `using`
  into try/finally with a DisposeResources step that builds a
  `SuppressedError` chain. `for (using x of ...)` and `await using` in
  async functions and modules.
- **Built-ins:** `DisposableStack`, `AsyncDisposableStack`,
  `SuppressedError`, `Symbol.dispose`, `Symbol.asyncDispose`, `[Symbol.dispose]`
  on the iterator prototypes (`%IteratorPrototype%`,
  `%AsyncIteratorPrototype%`).
- **`Array.fromAsync`:** async iteration with the sync-iterable fallback,
  awaiting each value, and closing on error.
- **`await-dictionary`:** read the tests and the proposal at the pinned
  commit first (`Promise.allKeyed`-style combinators). Sized by the tests.
- The `finally`-path code must keep the interrupt rule: termination still
  skips disposers, as it skips `finally`.

## Phase T7: module proposals

**Goal:** `import-attributes` (100), `json-modules`, `import-defer` (252),
`source-phase-imports` (251) and `AbstractModuleSource` (8), plus the 12
`module-code` failures.

- **Import attributes:** `with { type: "json" }` in static and dynamic
  imports, attribute validation (unknown keys are a SyntaxError, which the
  host decides), the attributes passed to the host loader hook, and the
  module map keyed by (specifier, type). **JSON modules** on top.
  `import-text` and `import-bytes` if the pinned commit has tests for them.
- **`import defer * as ns`:** a deferred namespace object that evaluates the
  module (and its async dependencies, eagerly) on first property access. That
  touches the namespace exotic object and the module evaluation state machine
  in `jsmodule.swift`.
- **`import source x from`:** source-phase imports, `%AbstractModuleSource%`,
  and the host hook returning a source object. With no WebAssembly, test262
  only checks the syntax and the errors, so this is mostly the parser and
  error paths.
- **module-code failures:** star-export conflict resolution
  (`namespace-unambiguous-if-import-star-as-and-export`), namespace object
  internals (`[[DefineOwnProperty]]`, `[[Set]]`, `Symbol.toStringTag`), and
  TDZ ReferenceErrors through namespaces.
- **lib/browser:** `type: "json"` should also work in the browser's module
  loader (fetch with JSON MIME check). Small, and keeps the engine and the
  browser in step.

## Phase T8: realms

**Goal:** `$262.createRealm`, `cross-realm` (175 tests) and `ShadowRealm`
(64).

This is the first architectural change. **Today a realm owns its heap**
(`JSRealm.heap`), so two realms can't share values. The spec model is one
agent (one heap, one job queue) with many realms.

- **Split heap from realm.** `JSHeap` moves to the runtime/agent. A realm
  becomes intrinsics + global object + global environment + template map,
  all in that heap. Every function object gets a [[Realm]] slot, and every
  native function knows its realm (today it's implicit).
- **Audit every "current realm" use:** `GetFunctionRealm` for
  `GetPrototypeFromConstructor` (cross-realm `new`), `ArraySpeciesCreate`'s
  realm check, errors thrown in the callee's realm vs the caller's,
  `Function`/`eval` in another realm, `Symbol.for` (agent-wide registry),
  the `%ThrowTypeError%` per realm, `Array.isArray` on other realms'
  proxies, and `instanceof` across realms.
- **Limits and GC:** heap byte limits move per runtime. The GC roots all
  realms of the heap. Browser behavior stays the same, still one realm per
  document, so the browser isn't affected except through the API move.
- **`$262.createRealm()`** returns the new realm's `$262` (with
  `evalScript`, `global`).
- **ShadowRealm:** `new ShadowRealm()`, `evaluate`, `importValue`, and the
  callable boundary (wrapped functions, only primitives and callables cross,
  TypeError otherwise, errors re-thrown as fresh TypeErrors in the caller
  realm).

**Done when:** `cross-realm` and `ShadowRealm` are gone from the skip list;
the 9J perf numbers hold (the realm lookup must not cost a hash per call).

## Phase T9: agents and shared memory

**Goal:** `SharedArrayBuffer`, `Atomics` (including `wait`, `notify`,
`waitAsync`, `pause`) and `$262.agent`: about 600 skipped tests plus the
`built-ins/{Atomics,SharedArrayBuffer}` directories (about 500).

- **SharedArrayBuffer:** a backing store outside any heap, reference-counted
  across agents, with growable SABs (`grow`, `maxByteLength`,
  `growable`). TypedArrays and DataView over SAB, and every TypedArray
  method's SAB paths (test262 runs much of `TypedArray` again over SAB).
- **Atomics:** `add`/`and`/`compareExchange`/`exchange`/`isLockFree`/
  `load`/`or`/`store`/`sub`/`xor` on all integer types and BigInt64, as
  real atomics (Swift Synchronization, or small asm helpers on x86-64, as the
  kernel already does). `wait`/`notify` with a per-address waiter list,
  `waitAsync` with promise resolution through the agent's job queue,
  `Atomics.pause`.
- **Agents:** `$262.agent.start/broadcast/receiveBroadcast/report/
  getReport/sleep/monotonicNow/leaving`. Each agent is its own JSRuntime on
  its own thread. In hosttest that's pthreads (host test-only C, allowed by
  Decision 5). `CanBlockIsFalse` for the main agent vs `CanBlockIsTrue` for
  workers.
- **The engine has to be thread-safe at the runtime boundary.** No globals
  shared between runtimes. Audit `nonisolated(unsafe)` statics in lib/js
  (atom tables, caches, `jsTest262DrainJobs`), and make them per-runtime or
  immutable.
- **On Wiffer itself:** there are no user-space threads yet ("After Part 9"
  in ROADMAP.md). The engine work doesn't depend on them, but running these
  tests on the OS, and `Worker` in the browser, do. Decide (below) whether
  "100%" means on hosttest or also in QEMU.

## Phase T10: proper tail calls

**Goal:** `tail-call-optimization` (35 tests).

- In strict code, a call in tail position (`return f(x)`, the last operand
  of `&&`/`||`/`??`/comma/conditional in a return, arrow concise bodies)
  replaces the current VM frame instead of pushing one. The tests make
  100 000 nested tail calls, far past the call depth cap.
- The VM doesn't recurse in Swift for JS calls, so this is a new `TAILCALL`
  opcode plus compiler tail-position marking. The work is in the details:
  `finally` blocks, `try`, generators and async functions (no TCO
  inside), native callees, construct vs call, and `arguments`/`caller`
  semantics.
- The JS call-depth limit still applies to non-tail calls. Error stacks
  (T4) show the frames that remain, as JSC does.
- Only JSC ships this. It's in the spec, so it's in the target.

## Phase T11: Temporal

**Goal:** `test/built-ins/Temporal` (4 624 tests) and the `Temporal`
feature tag elsewhere (Date, `toTemporalInstant`). The largest single
phase.

- **Types:** `Instant`, `ZonedDateTime`, `PlainDateTime`, `PlainDate`,
  `PlainTime`, `PlainYearMonth`, `PlainMonthDay`, `Duration`, and
  `Temporal.Now`. Each has `from`, `compare`, `with`, `add`/`subtract`,
  `until`/`since`, `round`, `equals`, `toString` and `toJSON`, with the
  spec's option bags read in alphabetical order (test262 checks the
  observable order with Proxies).
- **Arithmetic:** epoch nanoseconds as exact integers (reuse lib/js BigInt
  internally, or a 128-bit fixed type), the duration normalization and
  rounding algorithms, and balancing exactly as in the spec. Write these
  straight from the spec text, step by step; test262 tests every branch.
- **Parsing:** the ISO 8601 / RFC 9557 grammar (annotations,
  `[u-ca=...]`, `[!...]` critical flags, offsets with sub-minute precision).
- **Time zones:** `UTC` and fixed offsets (`+05:30`) are all the gated tests
  need: at the pinned commit only 2 files in `built-ins/Temporal` name an
  IANA zone. Build the time zone layer behind one interface
  (offset-for-instant, possible-instants-for-local) with the 9E "common
  zones" table behind it for now. T12 plugs full tzdata in.
- **Calendars:** `iso8601` only. No gated test uses another calendar.

## Phase T12: host hooks, decorators, and Intl for the web

**Gated goal:** `IsHTMLDDA` (35) and `decorators` (24), the last gated
skips. **Tracked goal:** Intl good enough for real sites, measured by
intl402 floors (3 394 files: about 2 040 Temporal, about 1 350 other). The
target is that intl402 outside non-ISO calendars and locales beyond the
chosen set passes. All of intl402 at 100% is not a goal of this plan.

Do the two gated items first, then Intl:

- **`IsHTMLDDA`:** an object kind with the [[IsHTMLDDA]] slot (`typeof` is
  `"undefined"`, ToBoolean false, `== null` true, callable, returns null).
  `$262.IsHTMLDDA` makes one. The browser's `document.all` can use the
  same kind.
- **decorators:** class and member decorators, `accessor` fields,
  `addInitializer` and metadata (`Symbol.metadata`). Check what the pinned
  commit tests (24 files in `test/`, more in staging) before sizing.

Intl, in order of how much the web uses it:

- **CLDR data for about 20 locales.** Replace the en-US-only data with
  data generated from CLDR (pin a version) for a fixed set: en, en-GB, de,
  fr, es, it, pt, pt-BR, nl, sv, pl, ru, uk, tr, ar, he, hi, ja, ko, zh-Hans,
  zh-Hant (adjust to the target sites). en-US stays built in; the rest is
  one generated file on the rootfs, loaded on demand, so the binary
  doesn't grow per locale. Unsupported locales fall back through
  negotiation, as the spec allows. Locale
  negotiation (`BestFit` can equal `Lookup`), Unicode extension keys
  (`-u-nu-`, `-u-ca-`, `-u-co-`, `-u-hc-`, `-u-kn-`...), and canonicalization
  (`Intl.getCanonicalLocales`, aliases from CLDR's supplemental data).
- **Constructors sites use, to full spec, first:** NumberFormat,
  DateTimeFormat, PluralRules, RelativeTimeFormat, ListFormat, Collator,
  `Intl.Locale` (full, not the 9E stub) and `Intl.Segmenter`. The rest
  after.
- **Missing constructors:** `Intl.Locale`,
  `Intl.Segmenter` (UAX #29 grapheme/word/sentence, with tables generated
  from the Unicode data already used for RegExp), `Intl.DisplayNames`,
  `Intl.DurationFormat`, `Intl.supportedValuesOf` (`Intl-enumeration`).
- **Existing constructors to full spec:** NumberFormat (every numbering
  system, `roundingIncrement`/`roundingPriority`/`trailingZeroDisplay`,
  formatRange approximately), DateTimeFormat (era, dayPeriod,
  `fractionalSecondDigits`, non-Gregorian calendars, Temporal objects),
  Collator (CLDR root collation via the DUCET plus tailorings for the
  chosen locales, `-u-co-`), PluralRules (`selectRange`, ordinals for
  the chosen locales), RelativeTimeFormat, ListFormat.
- **Time zones:** full IANA tzdata, compiled by a script in `lib/js/tools`
  into compact transition tables (in the same rootfs data file), with
  `canonical-tz` (link resolution, case-insensitive IDs). It goes behind
  T11's time zone interface and replaces the 9E "common zones" table for
  Date, Intl.DateTimeFormat and Temporal alike. Pin the tzdata version next
  to the test262 commit. This one is worth it beyond the tests: real sites
  show dates in the user's zone.
- **`intl-normative-optional`:** implement the optional behaviors where
  they're cheap.
- **Out of scope for now:** non-ISO calendars (`chinese`, `hebrew`,
  `islamic-*`, `japanese` and the rest, most of intl402/Temporal) and
  locales outside the set. Their intl402 tests stay failing and are
  listed by reason in the results, not skipped.

**Done when:** the gated skip list is empty except `regExpUtils.js`-style
speed overrides, which are timeouts, not skips. intl402 reaches its target
above and its floors are recorded.

## Phase T13: 100%, and staying there

- **The bar:** `./run.sh --test262` reports 48 914 passed, 0 failed, 0
  skipped across built-ins, language, annexB and harness (or whatever the
  pinned commit's file count is). The floor file becomes one line per gated
  directory equal to its total, and any failure there fails the run.
  intl402 keeps ordinary floors.
- **hosttest:** keep the 1/16 sample in `--hosttest js`, now at 100% too,
  so ordinary work can't regress it.
- **In QEMU:** run a sample in the OS too (a `/bin/js test262` mode reading
  a tarball of tests from /disk), so Embedded Swift differences
  (`-Osize`, no `description`, the 512 KB stack) are covered. T9's agent
  tests need user threads, or are marked hosttest-only by that decision.
- **Bumping the pin:** move the test262 commit once a month. Each bump is one
  commit: update `fetch_test262.sh`, run, fix anything new or add the new
  feature tag to the skip list *with a phase number*, and record the new
  totals here. New proposal tags get a short phase entry before they're
  skipped.
- **staging:** run `test/staging` monthly and report the results only; fix
  what's cheap.
- **Write it up** in ROADMAP.md's Part 9 summary, with the final numbers
  and lines of code per phase.

---

# Milestones

| After | Gated passing (of 48 914) | What it shows |
|---|---:|---|
| today | 38 849 (79%) | |
| T0 | ~39 600 | runner honest, slow tests and `import()` from scripts run |
| T1–T4 | ~41 000 | current-scope fail column at 0 |
| T5–T7 | ~43 300 | every finished ECMAScript feature in |
| T8–T10 | ~44 200 | realms, agents, tail calls |
| T11 | ~48 850 | Temporal |
| T12 | 48 914 | host hooks and decorators: **100%** |

intl402 is reported beside this, starting at whatever T0 measures (the 9E
en-US Intl should pass a few hundred).

The counts are rough (tests carry several feature tags, so a skip moves only
when its last tag goes). T0's per-feature report makes them exact.

---

# Decisions

Decided on 2026-11-25:

- **Everything once "not planned" is now planned** (tail calls,
  `IsHTMLDDA`, decorators, ShadowRealm, Atomics/SAB, Temporal and the rest).
- **Proposals are in the gate**, scheduled after finished features.
- **"100%" is ECMA-262** (built-ins, language, annexB, harness). intl402 is
  tracked with floors; Intl aims at what the web uses (T12).

Still open:

1. **The locale set and data file** (T12): which ~20 locales, and the
   rootfs data file's size budget. Measure CLDR + tzdata output first.
2. **Where agents run.** Proposed: T9's `$262.agent` tests pass on
   hosttest (pthreads), and in QEMU once user-space threads exist (a
   separate Part, not part of this plan).
3. **Engine size.** This plan adds a lot of lib/js (Temporal and Intl are
   each the size of a 9C). The 2026-11-19 decision was "split when it
   starts to hurt". T11 is the likely point: plan for `lib/js-intl` (Intl +
   Temporal + generated data) as its own module, depending on lib/js.
